# MOSAN K8s / Keycloak / Python / Java Helper

A small Golang CLI that applies **MOSAN-style thinking** (Multi-Objective State Action Network) to work on:

- Kubernetes (k8s)
- Keycloak single sign-on
- Python applications
- Java applications

It stores **context**, **goals**, and **situations considered** in a flat JSON file (`mosan-state.json`) so you can balance multiple objectives instead of chasing only one.

## Build

```bash
go mod tidy
go build -o mosan .
```

## Quick Start

```bash
# Create a context
./mosan new "prod-keycloak" keycloak

# Add multiple goals (priority 1-10)
./mosan goal add prod-keycloak "High security (OIDC best practices)" 9
./mosan goal add prod-keycloak "Easy for developers to integrate" 7
./mosan goal add prod-keycloak "Low operational overhead" 6

# Record a situation and possible actions
./mosan situation prod-keycloak
# (interactive prompts)

# Score an action against the goals
./mosan score prod-keycloak <situation-id> <action-id>

# Generate a balanced prompt you can paste into an LLM
./mosan prompt prod-keycloak

# Useful templates
./mosan template k8s-keycloak
./mosan template python-sso
./mosan template java-sso
```

## Commands

| Command | Description |
|---------|-------------|
| `new <name> <topic>` | Create context (`k8s`, `keycloak`, `python`, `java`, `general`) |
| `list` | List all saved contexts |
| `show <id-or-name>` | Print full JSON of a context |
| `goal add <ctx> <desc> <priority>` | Add a goal to balance |
| `situation <ctx>` | Interactively record a situation + possible actions |
| `score <ctx> <sit> <act>` | Score an action against every goal |
| `choose <ctx> <sit> <act>` | Mark which action you selected |
| `prompt <ctx>` | Emit a ready-to-use multi-objective prompt |
| `template <type>` | Show starter YAML / code (`k8s-keycloak`, `k8s-python`, `k8s-java`, `python-sso`, `java-sso`) |

All data lives in `mosan-state.json` in the current directory.
