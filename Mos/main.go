package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
)

const storeFile = "mosan-state.json"

type Goal struct {
	ID          string  `json:"id"`
	Description string  `json:"description"`
	Priority    int     `json:"priority"` // 1-10
	Weight      float64 `json:"weight"`   // relative importance
}

type Action struct {
	ID          string         `json:"id"`
	Description string         `json:"description"`
	Scores      map[string]int `json:"scores"` // goalID -> 1-10 score
	Pros        []string       `json:"pros"`
	Cons        []string       `json:"cons"`
	Notes       string         `json:"notes,omitempty"`
}

type Situation struct {
	ID                string    `json:"id"`
	Timestamp         time.Time `json:"timestamp"`
	Description       string    `json:"description"`
	CurrentState      string    `json:"current_state"`
	ActionsConsidered []Action  `json:"actions_considered"`
	ChosenActionID    string    `json:"chosen_action_id,omitempty"`
	Outcome           string    `json:"outcome,omitempty"`
}

type Context struct {
	ID         string      `json:"id"`
	Name       string      `json:"name"`
	Topic      string      `json:"topic"` // k8s | keycloak | python | java | general
	Goals      []Goal      `json:"goals"`
	Situations []Situation `json:"situations"`
	Notes      string      `json:"notes,omitempty"`
	CreatedAt  time.Time   `json:"created_at"`
	UpdatedAt  time.Time   `json:"updated_at"`
}

type Store struct {
	Contexts []Context `json:"contexts"`
}

func loadStore() (*Store, error) {
	data, err := os.ReadFile(storeFile)
	if os.IsNotExist(err) {
		return &Store{Contexts: []Context{}}, nil
	}
	if err != nil {
		return nil, err
	}
	var s Store
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, err
	}
	return &s, nil
}

func saveStore(s *Store) error {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(storeFile, data, 0644)
}

func main() {
	if len(os.Args) < 2 {
		printUsage()
		return
	}

	store, err := loadStore()
	if err != nil {
		fmt.Printf("Error loading store: %v\n", err)
		os.Exit(1)
	}

	cmd := os.Args[1]
	switch cmd {
	case "new":
		cmdNew(store)
	case "list":
		cmdList(store)
	case "show":
		cmdShow(store)
	case "goal":
		cmdGoal(store)
	case "situation":
		cmdSituation(store)
	case "score":
		cmdScore(store)
	case "choose":
		cmdChoose(store)
	case "prompt":
		cmdPrompt(store)
	case "template":
		cmdTemplate()
	case "help":
		printUsage()
	default:
		fmt.Println("Unknown command:", cmd)
		printUsage()
	}
}

func printUsage() {
	fmt.Println(`MOSAN K8s/Keycloak/Python/Java Helper
A decision-making tool that stores context, goals, and situations.
Balances multiple objectives instead of chasing one goal.

Usage:
  mosan new <name> <topic>          Create new context (topic: k8s|keycloak|python|java|general)
  mosan list                        List all contexts
  mosan show <id-or-name>           Show full context
  mosan goal add <ctx> <desc> <pri> Add a goal (priority 1-10)
  mosan situation <ctx>             Start interactive situation recording
  mosan score <ctx> <sit> <act>     Score an action against goals
  mosan choose <ctx> <sit> <act>    Mark an action as chosen
  mosan prompt <ctx>                Generate a balanced MOSAN-style prompt
  mosan template <type>             Show template (k8s-keycloak, python-sso, java-sso, etc.)
  mosan help

Data is stored in mosan-state.json`)
}

func cmdNew(store *Store) {
	if len(os.Args) < 4 {
		fmt.Println("Usage: mosan new <name> <topic>")
		return
	}
	name := os.Args[2]
	topic := strings.ToLower(os.Args[3])
	valid := map[string]bool{"k8s": true, "keycloak": true, "python": true, "java": true, "general": true}
	if !valid[topic] {
		fmt.Println("Topic must be: k8s, keycloak, python, java, or general")
		return
	}

	ctx := Context{
		ID:        uuid.New().String()[:8],
		Name:      name,
		Topic:     topic,
		Goals:     []Goal{},
		Situations: []Situation{},
		CreatedAt: time.Now(),
		UpdatedAt: time.Now(),
	}
	store.Contexts = append(store.Contexts, ctx)
	if err := saveStore(store); err != nil {
		fmt.Printf("Error saving: %v\n", err)
		return
	}
	fmt.Printf("Created context '%s' (ID: %s) for topic: %s\n", name, ctx.ID, topic)
}

func findContext(store *Store, idOrName string) *Context {
	for i := range store.Contexts {
		c := &store.Contexts[i]
		if c.ID == idOrName || strings.EqualFold(c.Name, idOrName) {
			return c
		}
	}
	return nil
}

func cmdList(store *Store) {
	if len(store.Contexts) == 0 {
		fmt.Println("No contexts yet. Create one with: mosan new <name> <topic>")
		return
	}
	fmt.Println("Contexts:")
	for _, c := range store.Contexts {
		fmt.Printf("  [%s] %s  (topic: %s, goals: %d, situations: %d, updated: %s)\n",
			c.ID, c.Name, c.Topic, len(c.Goals), len(c.Situations), c.UpdatedAt.Format("2006-01-02 15:04"))
	}
}

func cmdShow(store *Store) {
	if len(os.Args) < 3 {
		fmt.Println("Usage: mosan show <id-or-name>")
		return
	}
	c := findContext(store, os.Args[2])
	if c == nil {
		fmt.Println("Context not found")
		return
	}
	data, _ := json.MarshalIndent(c, "", "  ")
	fmt.Println(string(data))
}

func cmdGoal(store *Store) {
	if len(os.Args) < 6 || os.Args[2] != "add" {
		fmt.Println("Usage: mosan goal add <ctx> <description> <priority 1-10>")
		return
	}
	c := findContext(store, os.Args[3])
	if c == nil {
		fmt.Println("Context not found")
		return
	}
	desc := os.Args[4]
	pri, err := strconv.Atoi(os.Args[5])
	if err != nil || pri < 1 || pri > 10 {
		fmt.Println("Priority must be 1-10")
		return
	}
	g := Goal{
		ID:          uuid.New().String()[:6],
		Description: desc,
		Priority:    pri,
		Weight:      float64(pri) / 10.0,
	}
	c.Goals = append(c.Goals, g)
	c.UpdatedAt = time.Now()
	if err := saveStore(store); err != nil {
		fmt.Printf("Error: %v\n", err)
		return
	}
	fmt.Printf("Added goal [%s]: %s (priority %d)\n", g.ID, desc, pri)
}

func cmdSituation(store *Store) {
	if len(os.Args) < 3 {
		fmt.Println("Usage: mosan situation <ctx>")
		return
	}
	c := findContext(store, os.Args[2])
	if c == nil {
		fmt.Println("Context not found")
		return
	}

	reader := bufio.NewReader(os.Stdin)
	fmt.Println("--- New Situation (MOSAN style) ---")
	fmt.Print("Short description of the decision/situation: ")
	desc, _ := reader.ReadString('\n')
	desc = strings.TrimSpace(desc)

	fmt.Print("Current state (what's happening now with K8s/Keycloak/app): ")
	state, _ := reader.ReadString('\n')
	state = strings.TrimSpace(state)

	sit := Situation{
		ID:           uuid.New().String()[:8],
		Timestamp:    time.Now(),
		Description:  desc,
		CurrentState: state,
		ActionsConsidered: []Action{},
	}

	fmt.Println("\nNow add possible actions/moves (empty line to finish):")
	for {
		fmt.Print("Action description: ")
		actDesc, _ := reader.ReadString('\n')
		actDesc = strings.TrimSpace(actDesc)
		if actDesc == "" {
			break
		}
		a := Action{
			ID:          uuid.New().String()[:6],
			Description: actDesc,
			Scores:      make(map[string]int),
			Pros:        []string{},
			Cons:        []string{},
		}
		sit.ActionsConsidered = append(sit.ActionsConsidered, a)
		fmt.Printf("  Added action [%s]\n", a.ID)
	}

	c.Situations = append(c.Situations, sit)
	c.UpdatedAt = time.Now()
	if err := saveStore(store); err != nil {
		fmt.Printf("Error saving: %v\n", err)
		return
	}
	fmt.Printf("\nSituation recorded (ID: %s). Now score actions with: mosan score ...\n", sit.ID)
}

func cmdScore(store *Store) {
	if len(os.Args) < 5 {
		fmt.Println("Usage: mosan score <ctx> <situation-id> <action-id>")
		return
	}
	c := findContext(store, os.Args[2])
	if c == nil {
		fmt.Println("Context not found")
		return
	}
	sitID := os.Args[3]
	actID := os.Args[4]

	var sit *Situation
	var act *Action
	for i := range c.Situations {
		if c.Situations[i].ID == sitID {
			sit = &c.Situations[i]
			for j := range sit.ActionsConsidered {
				if sit.ActionsConsidered[j].ID == actID {
					act = &sit.ActionsConsidered[j]
					break
				}
			}
			break
		}
	}
	if sit == nil || act == nil {
		fmt.Println("Situation or action not found")
		return
	}

	reader := bufio.NewReader(os.Stdin)
	fmt.Printf("Scoring action: %s\n", act.Description)
	for _, g := range c.Goals {
		fmt.Printf("Score for goal '%s' (1-10, how well this action serves it): ", g.Description)
		line, _ := reader.ReadString('\n')
		score, _ := strconv.Atoi(strings.TrimSpace(line))
		if score < 1 || score > 10 {
			score = 5
		}
		act.Scores[g.ID] = score
	}

	fmt.Print("Pros (comma separated): ")
	pros, _ := reader.ReadString('\n')
	for _, p := range strings.Split(strings.TrimSpace(pros), ",") {
		if t := strings.TrimSpace(p); t != "" {
			act.Pros = append(act.Pros, t)
		}
	}
	fmt.Print("Cons (comma separated): ")
	cons, _ := reader.ReadString('\n')
	for _, p := range strings.Split(strings.TrimSpace(cons), ",") {
		if t := strings.TrimSpace(p); t != "" {
			act.Cons = append(act.Cons, t)
		}
	}

	c.UpdatedAt = time.Now()
	if err := saveStore(store); err != nil {
		fmt.Printf("Error: %v\n", err)
		return
	}
	fmt.Println("Scores saved.")
}

func cmdChoose(store *Store) {
	if len(os.Args) < 5 {
		fmt.Println("Usage: mosan choose <ctx> <situation-id> <action-id>")
		return
	}
	c := findContext(store, os.Args[2])
	if c == nil {
		fmt.Println("Context not found")
		return
	}
	sitID, actID := os.Args[3], os.Args[4]
	for i := range c.Situations {
		if c.Situations[i].ID == sitID {
			c.Situations[i].ChosenActionID = actID
			c.UpdatedAt = time.Now()
			if err := saveStore(store); err != nil {
				fmt.Printf("Error: %v\n", err)
				return
			}
			fmt.Println("Action chosen and saved.")
			return
		}
	}
	fmt.Println("Situation not found")
}

func cmdPrompt(store *Store) {
	if len(os.Args) < 3 {
		fmt.Println("Usage: mosan prompt <ctx>")
		return
	}
	c := findContext(store, os.Args[2])
	if c == nil {
		fmt.Println("Context not found")
		return
	}

	var b strings.Builder
	b.WriteString(fmt.Sprintf("You are an expert assistant focused ONLY on Kubernetes, Keycloak SSO, and Python/Java applications.\n"))
	b.WriteString(fmt.Sprintf("Context: %s (topic: %s)\n\n", c.Name, c.Topic))

	b.WriteString("## Multiple Goals (balance these, do not chase only one):\n")
	for _, g := range c.Goals {
		b.WriteString(fmt.Sprintf("- [Priority %d] %s\n", g.Priority, g.Description))
	}

	if len(c.Situations) > 0 {
		latest := c.Situations[len(c.Situations)-1]
		b.WriteString(fmt.Sprintf("\n## Current Situation:\n%s\nState: %s\n", latest.Description, latest.CurrentState))
		b.WriteString("\n## Actions already considered:\n")
		for _, a := range latest.ActionsConsidered {
			b.WriteString(fmt.Sprintf("- %s\n", a.Description))
			if len(a.Scores) > 0 {
				b.WriteString("  Scores: ")
				for gid, sc := range a.Scores {
					for _, g := range c.Goals {
						if g.ID == gid {
							b.WriteString(fmt.Sprintf("%s=%d ", g.Description, sc))
						}
					}
				}
				b.WriteString("\n")
			}
		}
		if latest.ChosenActionID != "" {
			b.WriteString(fmt.Sprintf("\nChosen action ID: %s\n", latest.ChosenActionID))
		}
	}

	b.WriteString("\n## Task:\nProvide concrete, balanced recommendations, YAML snippets, code examples, or configuration that best trade off the goals above. Stay strictly within K8s, Keycloak SSO, Python apps, and Java apps. Prefer practical, secure, production-ready patterns.\n")

	fmt.Println(b.String())
}

func cmdTemplate() {
	if len(os.Args) < 3 {
		fmt.Println("Available templates: k8s-keycloak, k8s-python, k8s-java, python-sso, java-sso")
		return
	}
	t := os.Args[2]
	switch t {
	case "k8s-keycloak":
		fmt.Println(k8sKeycloakTemplate)
	case "k8s-python":
		fmt.Println(k8sPythonTemplate)
	case "k8s-java":
		fmt.Println(k8sJavaTemplate)
	case "python-sso":
		fmt.Println(pythonSSOTemplate)
	case "java-sso":
		fmt.Println(javaSSOTemplate)
	default:
		fmt.Println("Unknown template")
	}
}

const k8sKeycloakTemplate = `# Example Keycloak Deployment + Service (simplified)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
      - name: keycloak
        image: quay.io/keycloak/keycloak:24.0
        args: ["start-dev"]
        env:
        - name: KEYCLOAK_ADMIN
          value: "admin"
        - name: KEYCLOAK_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: keycloak-secret
              key: password
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
spec:
  selector:
    app: keycloak
  ports:
  - port: 8080
    targetPort: 8080
`

const k8sPythonTemplate = `# Python app Deployment example
apiVersion: apps/v1
kind: Deployment
metadata:
  name: python-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: python-app
  template:
    metadata:
      labels:
        app: python-app
    spec:
      containers:
      - name: app
        image: your-registry/python-app:latest
        ports:
        - containerPort: 8000
        env:
        - name: KEYCLOAK_URL
          value: "http://keycloak:8080"
        - name: KEYCLOAK_REALM
          value: "myrealm"
`

const k8sJavaTemplate = `# Java/Spring Boot app Deployment example
apiVersion: apps/v1
kind: Deployment
metadata:
  name: java-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: java-app
  template:
    metadata:
      labels:
        app: java-app
    spec:
      containers:
      - name: app
        image: your-registry/java-app:latest
        ports:
        - containerPort: 8080
        env:
        - name: SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI
          value: "http://keycloak:8080/realms/myrealm"
`

const pythonSSOTemplate = `# FastAPI + Keycloak (python-jose / authlib style outline)
# pip install fastapi uvicorn python-jose[cryptography] httpx

from fastapi import FastAPI, Depends, HTTPException
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
import httpx
from jose import jwt

app = FastAPI()
security = HTTPBearer()

KEYCLOAK_URL = "http://keycloak:8080"
REALM = "myrealm"
JWKS_URL = f"{KEYCLOAK_URL}/realms/{REALM}/protocol/openid-connect/certs"

async def get_public_key():
    async with httpx.AsyncClient() as client:
        r = await client.get(JWKS_URL)
        return r.json()

async def verify_token(credentials: HTTPAuthorizationCredentials = Depends(security)):
    token = credentials.credentials
    # Decode and verify JWT against Keycloak JWKS
    # (full verification omitted for brevity - use python-jose properly)
    try:
        claims = jwt.get_unverified_claims(token)
        return claims
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid token")

@app.get("/protected")
async def protected(claims=Depends(verify_token)):
    return {"message": "Hello", "user": claims.get("preferred_username")}
`

const javaSSOTemplate = `# Spring Boot Keycloak Resource Server (application.yml snippet)
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          issuer-uri: http://keycloak:8080/realms/myrealm

# Java config (SecurityFilterChain)
@Bean
public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
    http
        .authorizeHttpRequests(auth -> auth
            .requestMatchers("/public/**").permitAll()
            .anyRequest().authenticated()
        )
        .oauth2ResourceServer(oauth2 -> oauth2.jwt(Customizer.withDefaults()));
    return http.build();
}
`
