Building an **Azure Kubernetes Service (AKS)** cluster with **Istio** and **Persistent Volumes** is like building a high-security digital shopping mall. Before we write the code, let's break down how all the pieces fit together using that mall analogy:

* **The AKS Cluster (The Mall Building):** This is the land, the power grid, and the concrete building in the cloud where all your apps will live.
* **Cluster Base IP / CIDR (Internal Room Numbers):** Every shop and hallway inside the mall needs an internal extension number (like `10.240.x.x`) so workers can talk to each other privately without customers listening in.
* **Node Pools (Two Different Wings):** Best practice is to split your mall into two wings: a **System Wing** (only for mall security, electricity, and plumbing) and a **User Wing** (where actual stores like **Keycloak** and **PostgreSQL** open up). That way, a busy store never accidentally knocks out the mall's electricity.
* **Istio Gateway (The Front Security Desk & Directory):** Instead of letting visitors wander into back doors, Istio is the single guarded front entrance. It checks everyone's ID, encrypts traffic, and directs visitors to the exact store they asked for.
* **StorageClasses & Persistent Volumes (Fireproof Vaults):** Normally, cloud containers are like pop-up tents—if they restart, everything inside disappears! For **PostgreSQL** (your database ledger) and **Keycloak** (your ID badge maker), you need permanent, fireproof vaults bolted to the floor (`Retain` policy) so your data stays safe even if a container restarts.

---

## 1. Project Folder Structure

Create a folder called `aks-foundation` and organize your files like this:

```text
aks-foundation/
├── provision-aks.sh
└── helm/
    ├── istio-gateway-values.yaml
    └── cluster-foundation/
        ├── Chart.yaml
        ├── values.yaml
        └── templates/
            ├── namespaces.yaml
            ├── storageclass.yaml
            ├── pvcs.yaml
            └── gateway.yaml

```

---

## 2. The Master Provisioning Script (`provision-aks.sh`)

### How This Script Works (Step-by-Step)

1. **Reads Your Arguments:** It accepts your custom cluster name (`-n`), your internal IP range (`-c`), your Azure location (`-l`), and your resource group (`-g`).
2. **Validates Your Tools:** It makes sure `az`, `kubectl`, and `helm` are installed on your machine before doing any work.
3. **Builds the Private Network (VNet):** It carves out a private neighborhood in Azure using your custom IP base so your cluster isn't cramped.
4. **Creates a Permanent Public IP:** It reserves a static street address in Azure so your Istio front door never changes its address if the cluster reboots.
5. **Stands Up the AKS Cluster with Best Practices:**
* **Azure CNI Overlay:** Gives pods fast, clean networking without eating up all your VNet IPs.
* **OIDC & Workload Identity:** Lets apps prove who they are to Azure without hiding secret passwords in code.
* **System + User Node Pools:** Keeps cluster brains separate from your databases and apps.


6. **Installs Istio & Your Foundation Helm Chart:** It installs the Istio brains (`istiod`), the front door (`istio-ingressgateway`), and the permanent storage vaults for Keycloak and Postgres.

```bash
#!/usr/bin/env bash
# ==============================================================================
# Script Name: provision-aks.sh
# Description: Provisions an enterprise-grade AKS cluster with Azure CNI,
#              split System/User node pools, a static IP Istio Ingress Gateway,
#              and retained Premium SSD volumes for PostgreSQL and Keycloak.
# ==============================================================================

set -euo pipefail

# --- Default Values (Can be overridden via CLI arguments) ---
CLUSTER_NAME="zactonics-aks"
RESOURCE_GROUP="rg-zactonics-aks"
LOCATION="eastus2"
VNET_CIDR="10.200.0.0/16"
NODE_SUBNET_CIDR="10.200.1.0/24"
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.0.0.0/16"
DNS_SERVICE_IP="10.0.0.10"
SYSTEM_VM_SIZE="Standard_D2s_v5"
USER_VM_SIZE="Standard_D4s_v5"
ISTIO_VERSION="1.23.2"
DRY_RUN=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required / Core Options:
  -n, --name <string>          AKS Cluster Name (default: $CLUSTER_NAME)
  -c, --cluster-cidr <cidr>    VNet Base IP CIDR (default: $VNET_CIDR)
  -s, --subnet-cidr <cidr>     AKS Node Subnet CIDR (default: $NODE_SUBNET_CIDR)
  -p, --pod-cidr <cidr>        Internal Pod CIDR (default: $POD_CIDR)
  -v, --service-cidr <cidr>    Internal K8s Service CIDR (default: $SERVICE_CIDR)
  -d, --dns-ip <ip>            Internal K8s DNS IP inside Service CIDR (default: $DNS_SERVICE_IP)
  -g, --resource-group <name>  Azure Resource Group (default: $RESOURCE_GROUP)
  -l, --location <region>      Azure Region (default: $LOCATION)
  --dry-run                    Print configuration without executing Azure changes
  -h, --help                   Show this help message

Example:
  ./provision-aks.sh -n my-prod-aks -g rg-my-prod -l eastus2 \\
    -c 10.150.0.0/16 -s 10.150.1.0/24 -p 10.244.0.0/16 -v 10.10.0.0/16 -d 10.10.0.10
EOF
  exit 1
}

# --- Parse Command-Line Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name) CLUSTER_NAME="$2"; shift 2 ;;
    -c|--cluster-cidr) VNET_CIDR="$2"; shift 2 ;;
    -s|--subnet-cidr) NODE_SUBNET_CIDR="$2"; shift 2 ;;
    -p|--pod-cidr) POD_CIDR="$2"; shift 2 ;;
    -v|--service-cidr) SERVICE_CIDR="$2"; shift 2 ;;
    -d|--dns-ip) DNS_SERVICE_IP="$2"; shift 2 ;;
    -g|--resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    -l|--location) LOCATION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift 1 ;;
    -h|--help) usage ;;
    *) echo "Unknown parameter passed: $1"; usage ;;
  esac
done

# --- Pre-Flight Dependency Check ---
for cmd in az kubectl helm; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[ERROR] Required command '$cmd' is not installed. Please install it first." >&2
    exit 1
  fi
done

echo "=================================================================="
echo " Starting AKS + Istio + Storage Provisioning"
echo "=================================================================="
echo " Cluster Name      : $CLUSTER_NAME"
echo " Resource Group    : $RESOURCE_GROUP"
echo " Location          : $LOCATION"
echo " VNet Base CIDR    : $VNET_CIDR"
echo " Node Subnet CIDR  : $NODE_SUBNET_CIDR"
echo " Pod CIDR          : $POD_CIDR"
echo " Service CIDR      : $SERVICE_CIDR"
echo " DNS Service IP    : $DNS_SERVICE_IP"
echo "=================================================================="

if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY-RUN] Exiting before making Azure API calls."
  exit 0
fi

# 1. Create Resource Group
echo "--> [1/7] Creating Resource Group '$RESOURCE_GROUP'..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

# 2. Create Custom Virtual Network & Subnet
VNET_NAME="${CLUSTER_NAME}-vnet"
SUBNET_NAME="${CLUSTER_NAME}-nodes-subnet"

echo "--> [2/7] Creating Virtual Network ($VNET_CIDR) and Node Subnet ($NODE_SUBNET_CIDR)..."
az network vnet create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VNET_NAME" \
  --address-prefixes "$VNET_CIDR" \
  --subnet-name "$SUBNET_NAME" \
  --subnet-prefix "$NODE_SUBNET_CIDR" \
  --output none

SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --name "$SUBNET_NAME" \
  --query id -o tsv)

# 3. Create AKS Cluster with Best Practices
#    - System Node Pool tainted so only K8s system pods run on it
#    - Azure CNI Overlay for scalable pod networking
#    - OIDC Issuer & Workload Identity enabled for secretless auth
echo "--> [3/7] Creating AKS Cluster '$CLUSTER_NAME' (this takes a few minutes)..."
az aks create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --location "$LOCATION" \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --network-policy cilium \
  --vnet-subnet-id "$SUBNET_ID" \
  --pod-cidr "$POD_CIDR" \
  --service-cidr "$SERVICE_CIDR" \
  --dns-service-ip "$DNS_SERVICE_IP" \
  --nodepool-name systempool \
  --node-count 2 \
  --node-vm-size "$SYSTEM_VM_SIZE" \
  --nodepool-taints CriticalAddonsOnly=true:NoSchedule \
  --enable-cluster-autoscaler \
  --min-count 2 \
  --max-count 4 \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --enable-managed-identity \
  --generate-ssh-keys \
  --output none

# 4. Add Dedicated User Node Pool for Stateful & App Workloads (Keycloak, Postgres)
echo "--> [4/7] Adding dedicated User Node Pool ('userpool') for apps and databases..."
az aks nodepool add \
  --resource-group "$RESOURCE_GROUP" \
  --cluster-name "$CLUSTER_NAME" \
  --name userpool \
  --mode User \
  --node-count 2 \
  --node-vm-size "$USER_VM_SIZE" \
  --enable-cluster-autoscaler \
  --min-count 2 \
  --max-count 6 \
  --labels workload=applications storage-tier=premium \
  --output none

# 5. Reserve a Static Public IP inside the AKS Managed Node Resource Group
echo "--> [5/7] Allocating a static Public IP for the Istio Ingress Gateway..."
NODE_RG=$(az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query nodeResourceGroup -o tsv)

PUBLIC_IP_NAME="${CLUSTER_NAME}-istio-pip"
az network public-ip create \
  --resource-group "$NODE_RG" \
  --name "$PUBLIC_IP_NAME" \
  --sku Standard \
  --allocation-method Static \
  --output none

STATIC_IP=$(az network public-ip show \
  --resource-group "$NODE_RG" \
  --name "$PUBLIC_IP_NAME" \
  --query ipAddress -o tsv)

echo "    Allocated Static Public IP: $STATIC_IP"

# Grant the AKS Control Plane Identity permission to use the Node Resource Group network
 PRINCIPAL_ID=$(az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query identity.principalId -o tsv)

NODE_RG_ID=$(az group show --name "$NODE_RG" --query id -o tsv)

az role assignment create \
  --assignee "$PRINCIPAL_ID" \
  --role "Network Contributor" \
  --scope "$NODE_RG_ID" \
  --output none

# 6. Fetch Cluster Credentials & Install Istio via Official Helm Charts
echo "--> [6/7] Fetching Kubeconfig and installing Istio ($ISTIO_VERSION)..."
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --overwrite-existing

helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

# Install Istio Base CRDs and Istiod Control Plane
helm upgrade --install istio-base istio/base \
  --namespace istio-system \
  --create-namespace \
  --version "$ISTIO_VERSION" \
  --wait

helm upgrade --install istiod istio/istiod \
  --namespace istio-system \
  --version "$ISTIO_VERSION" \
  --set meshConfig.accessLogFile=/dev/stdout \
  --wait

# Install Istio Ingress Gateway bound to our Static IP
helm upgrade --install istio-ingressgateway istio/gateway \
  --namespace istio-ingress \
  --create-namespace \
  --version "$ISTIO_VERSION" \
  --values ./helm/istio-gateway-values.yaml \
  --set service.loadBalancerIP="$STATIC_IP" \
  --set "service.annotations.service\.beta\.kubernetes\.io/azure-load-balancer-resource-group=$NODE_RG" \
  --wait

# 7. Deploy Custom Foundation Chart (StorageClasses, PVCs for Keycloak/Postgres, Gateway)
echo "--> [7/7] Deploying Cluster Foundation Helm Chart (Volumes & Gateway routing)..."
helm upgrade --install cluster-foundation ./helm/cluster-foundation \
  --namespace platform-foundation \
  --create-namespace \
  --set gateway.publicIp="$STATIC_IP" \
  --wait

echo "=================================================================="
echo " Provisioning Complete!"
echo "=================================================================="
echo " Istio Gateway Public IP : $STATIC_IP"
echo " Verify Gateway          : kubectl get svc -n istio-ingress"
echo " Verify Reserved Volumes : kubectl get pvc -A"
echo "=================================================================="

```

---

## 3. Helm Files for Istio & Persistent Volumes

### A. Istio Ingress Gateway Values (`helm/istio-gateway-values.yaml`)

**What this does in plain English:** When Azure sets up a Load Balancer outside your mall, it needs to know how to pass the visitor's real home IP address inside (`externalTrafficPolicy: Local`) and which doors to open (port `80` for regular web traffic and port `443` for encrypted HTTPS traffic).

```yaml
# helm/istio-gateway-values.yaml
replicaCount: 2

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 75

service:
  type: LoadBalancer
  # Preserves the client's original IP address (crucial for Keycloak audit logs)
  externalTrafficPolicy: Local
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: /healthz/ready
  ports:
    - name: status-port
      port: 15021
      targetPort: 15021
      protocol: TCP
    - name: http2
      port: 80
      targetPort: 8080
      protocol: TCP
    - name: https
      port: 443
      targetPort: 8443
      protocol: TCP

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 1000m
    memory: 1024Mi

```

---

### B. Foundation Chart Metadata (`helm/cluster-foundation/Chart.yaml`)

**What this does in plain English:** This is the packing slip for your custom Helm package so Helm knows its name and version.

```yaml
# helm/cluster-foundation/Chart.yaml
apiVersion: v2
name: cluster-foundation
description: Base AKS namespaces, retained Premium SSD StorageClass, pre-provisioned PVCs for Postgres & Keycloak, and Istio Gateway rules.
type: application
version: 1.0.0
appVersion: "1.0.0"

```

---

### C. Foundation Chart Settings (`helm/cluster-foundation/values.yaml`)

**What this does in plain English:** Instead of hardcoding disk sizes or domain names deep inside complicated templates, we put all the knobs and dials in one easy-to-read settings file.

```yaml
# helm/cluster-foundation/values.yaml
namespaces:
  identity:
    name: identity
    istioInjection: true
  data:
    name: data
    istioInjection: true

storageClass:
  name: managed-csi-premium-retain
  skuName: Premium_LRS
  reclaimPolicy: Retain
  allowVolumeExpansion: true

volumes:
  # Primary database vault for PostgreSQL
  postgresData:
    name: pvc-postgres-data
    namespace: data
    size: 64Gi
  # Write-Ahead Log (WAL) vault for fast transaction recovery
  postgresWal:
    name: pvc-postgres-wal
    namespace: data
    size: 16Gi
  # Persistent vault for Keycloak themes, extensions, and local caches
  keycloakData:
    name: pvc-keycloak-data
    namespace: identity
    size: 10Gi

gateway:
  name: main-aks-gateway
  namespace: istio-ingress
  publicIp: ""
  hosts:
    keycloak: "auth.example.com"
    app: "app.example.com"

```

---

### D. Namespaces Template (`helm/cluster-foundation/templates/namespaces.yaml`)

**What this does in plain English:** Namespaces are like separate floors in our mall—one floor (`identity`) for **Keycloak** and one floor (`data`) for **PostgreSQL**. Adding `istio-injection: enabled` tells Istio to automatically assign a personal security guard (called a sidecar proxy) to every pod that moves onto these floors.

```yaml
# helm/cluster-foundation/templates/namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Values.namespaces.identity.name }}
  labels:
    name: {{ .Values.namespaces.identity.name }}
    {{- if .Values.namespaces.identity.istioInjection }}
    istio-injection: enabled
    {{- end }}
---
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Values.namespaces.data.name }}
  labels:
    name: {{ .Values.namespaces.data.name }}
    {{- if .Values.namespaces.data.istioInjection }}
    istio-injection: enabled
    {{- end }}

```

---

### E. Fireproof StorageClass Template (`helm/cluster-foundation/templates/storageclass.yaml`)

**What this does in plain English:** A `StorageClass` is a blueprint for creating Azure hard drives. Two best practices here are critical for databases:

1. **`reclaimPolicy: Retain`**: If someone accidentally deletes a Helm release or a claim, Azure **will not erase the hard drive**. Your database stays safe in Azure until a human decides what to do.
2. **`volumeBindingMode: WaitForFirstConsumer`**: Azure waits to see which physical server your Postgres pod lands on *before* plugging in the hard drive, making sure the drive and the server are in the exact same building (Availability Zone).

```yaml
# helm/cluster-foundation/templates/storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: {{ .Values.storageClass.name }}
provisioner: disk.csi.azure.com
parameters:
  skuName: {{ .Values.storageClass.skuName }}
  cachingmode: None # Best practice for PostgreSQL to prevent host-cache corruption
reclaimPolicy: {{ .Values.storageClass.reclaimPolicy }}
allowVolumeExpansion: {{ .Values.storageClass.allowVolumeExpansion }}
volumeBindingMode: WaitForFirstConsumer

```

---

### F. Reserved Persistent Volume Claims (`helm/cluster-foundation/templates/pvcs.yaml`)

**What this does in plain English:** A **PersistentVolumeClaim (PVC)** is a reservation ticket for a vault. We create three reservation tickets right now:

* `pvc-postgres-data` (64 GB): Where Postgres stores all its tables and rows.
* `pvc-postgres-wal` (16 GB): Where Postgres writes its fast safety journal (Write-Ahead Log) so it never loses a transaction during a power blip.
* `pvc-keycloak-data` (10 GB): Where Keycloak stores custom login page themes, providers, or export files.
* Note the `helm.sh/resource-policy: keep` annotation—this is a safety lock that stops Helm from ever deleting these claims if you uninstall the chart!

```yaml
# helm/cluster-foundation/templates/pvcs.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .Values.volumes.postgresData.name }}
  namespace: {{ .Values.volumes.postgresData.namespace }}
  annotations:
    "helm.sh/resource-policy": keep
  labels:
    app.kubernetes.io/part-of: postgresql
    volume-role: data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: {{ .Values.storageClass.name }}
  resources:
    requests:
      storage: {{ .Values.volumes.postgresData.size }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .Values.volumes.postgresWal.name }}
  namespace: {{ .Values.volumes.postgresWal.namespace }}
  annotations:
    "helm.sh/resource-policy": keep
  labels:
    app.kubernetes.io/part-of: postgresql
    volume-role: wal
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: {{ .Values.storageClass.name }}
  resources:
    requests:
      storage: {{ .Values.volumes.postgresWal.size }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .Values.volumes.keycloakData.name }}
  namespace: {{ .Values.volumes.keycloakData.namespace }}
  annotations:
    "helm.sh/resource-policy": keep
  labels:
    app.kubernetes.io/part-of: keycloak
    volume-role: extensions-and-themes
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: {{ .Values.storageClass.name }}
  resources:
    requests:
      storage: {{ .Values.volumes.keycloakData.size }}

```

---

### G. Istio Gateway & Mutual TLS Rule (`helm/cluster-foundation/templates/gateway.yaml`)

**What this does in plain English:**

* **The `Gateway**` tells the front security desk which web addresses (`auth.example.com` for Keycloak, `app.example.com` for your apps) are allowed inside.
* **The `PeerAuthentication` (`STRICT` mTLS)** is a rule that says: *"Once inside the mall, every single worker must show a cryptographic badge and talk in secret code whenever they pass messages to another worker."* That way, Keycloak and Postgres traffic is encrypted automatically.

```yaml
# helm/cluster-foundation/templates/gateway.yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: {{ .Values.gateway.name }}
  namespace: {{ .Values.gateway.namespace }}
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - {{ .Values.gateway.hosts.keycloak | quote }}
        - {{ .Values.gateway.hosts.app | quote }}
        {{- if .Values.gateway.publicIp }}
        - {{ .Values.gateway.publicIp | quote }}
        {{- end }}
---
# Enforce STRICT Mutual TLS (mTLS) across the data and identity namespaces
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default-strict-mtls
  namespace: {{ .Values.namespaces.data.name }}
spec:
  mtls:
    mode: STRICT
---
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default-strict-mtls
  namespace: {{ .Values.namespaces.identity.name }}
spec:
  mtls:
    mode: STRICT

```

---

## 4. How to Run It & How Future Services Plug In

### Running the Script

Make the script executable and pass your cluster name and base IP ranges:

```bash
chmod +x provision-aks.sh

./provision-aks.sh \
  --name "zactonics-core-aks" \
  --resource-group "rg-zactonics-core" \
  --location "eastus2" \
  --cluster-cidr "10.180.0.0/16" \
  --subnet-cidr "10.180.1.0/24" \
  --pod-cidr "10.244.0.0/16" \
  --service-cidr "10.20.0.0/16" \
  --dns-ip "10.20.0.10"

```

### How Postgres & Keycloak Will Claim These Volumes Later

Because we set `volumeBindingMode: WaitForFirstConsumer`, when you run `kubectl get pvc -A` right after the script finishes, the status will say **`Pending`**. That is completely normal—Azure is waiting for your Postgres or Keycloak pod to show up so it builds the disk in the exact same data center rack!

When you deploy **PostgreSQL** or **Keycloak** later (via Helm or YAML), you simply hand them the reservation ticket name (`existingClaim`):

| Future Service | Namespace | Volume Claim Name to Pass | What It Stores |
| --- | --- | --- | --- |
| **PostgreSQL** | `data` | `pvc-postgres-data` | Main database tables (including Keycloak's realm database) |
| **PostgreSQL** | `data` | `pvc-postgres-wal` | High-speed transaction logs (`pg_wal`) for zero-data-loss recovery |
| **Keycloak** | `identity` | `pvc-keycloak-data` | Custom login themes, JAR plugins, and realm import/export files |
