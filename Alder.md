# AKS starter kit: a cluster, a front door, and storage

Two scripts and a few Helm files. Together they build a Kubernetes cluster on
Azure, put a guarded front door on it, and get storage ready for apps you will
add later, such as Keycloak (logins) and Postgres (a database). When you are
done, one command takes it all down again.

## Start here

```bash
unzip aks-platform.zip && cd aks-platform
chmod +x create-aks.sh destroy-aks.sh   # allow the scripts to run (needed once)
az login

# 1. Practice. Shows the plan and every command. Changes nothing.
./create-aks.sh --name shop --ip-base 10.40 --dry-run

# 2. The real thing. Takes about 15 to 20 minutes.
./create-aks.sh --name shop --ip-base 10.40

# 3. Look at what you built.
kubectl --context aks-shop-dev get nodes

# 4. Take it all down when you are done, so it stops costing money.
./destroy-aks.sh --name shop
```

> **Please read:** this kit was checked in many ways, but it has not been run
> against a live Azure account. See [How this was checked](#how-this-was-checked).
> Do the dry run first, and start with the small size.

### What is in the box

| File | What it is for |
|---|---|
| `create-aks.sh` | Builds everything |
| `destroy-aks.sh` | Takes it down again |
| `helm/` | Settings for Istio, plus our own small chart |
| `README.md` | This guide |

---

## The big picture

```
                    Internet
                       |
              fixed public address            (step 4)
                       |
              Azure load balancer
                       |
  +--------------------|--------------------------------+
  |  AKS cluster       v                                |
  |            Istio gateway  = the front door  (step 8)|
  |               |                                     |
  |      +--------+---------+                           |
  |      v                  v                           |
  |   room: keycloak     room: postgres         (step 9)|
  |   locker: 4 GB       locker: 32 GB                  |
  |                                                     |
  |   system nodes          app nodes       (steps 5, 6)|
  |   (Kubernetes helpers)  (your apps)                 |
  +-----------------------------------------------------+
     your private network, for example 10.40.0.0/16  (step 2)
```

### Think of it like a school

| The real word | Picture it as |
|---|---|
| Cluster | The whole school building |
| Node | One classroom. It is really one computer. |
| Pod | A student doing one job. It is one running copy of an app. |
| Namespace | A room with a name on the door, so each club keeps its things apart |
| Gateway | The front door, with a guard who checks who comes in |
| Public IP | The school's street address |
| Volume (disk) | A locker. Things stay in it after the student goes home. |
| Storage class | The order form for buying lockers |
| Volume claim | A slip that says "save me a locker this big" |
| Helm chart | A recipe card |
| Values file | Your choices on the recipe, like "extra cheese" |
| Istio | The hall monitors. They direct traffic and keep it safe. |

---

## What you need first

1. **An Azure subscription where you are an Owner.** (Contributor plus
   "User Access Administrator" also works.) The script hands out two
   permission slips, and only those roles are allowed to do that.
2. **Four tools:** `az` (the Azure CLI, a recent version), `kubectl`,
   `kubelogin` and `helm` (version 3 or 4).
3. **To be signed in:** run `az login`.

**The easy way:** open [Azure Cloud Shell](https://shell.azure.com). It is a
terminal in your browser that already has all four tools. Upload this folder
there and run the script.

**On your own computer:** install the Azure CLI and Helm from their websites.
Then `az aks install-cli` adds `kubectl` and `kubelogin` for you. The script
is written for Linux, macOS and WSL. It should also run in Git Bash on
Windows, but that was not tried.

---

## The two things you must choose

### `--name`

A short name for your project, like `shop`. Every Azure name is built from it,
so things are easy to find. With `--name shop --env dev` you get:

| What | Name |
|---|---|
| Resource group (the folder) | `rg-shop-dev` |
| Cluster | `aks-shop-dev` |
| Network | `vnet-shop-dev` |
| Public IP | `pip-shop-dev-ingress` |
| Identity (the ID badge) | `id-shop-dev-aks` |
| Folder AKS manages by itself | `rg-shop-dev-nodes` |

### `--ip-base`

Every computer on a network needs an address, like every house on a street.
You pick the first two numbers. The script plans the rest.

With `--ip-base 10.40`:

| Range | Used for |
|---|---|
| `10.40.0.0/16` | Your whole private network (65,536 addresses) |
| `10.40.0.0/20` | The node computers (4,096 addresses) |
| `10.40.16.0` and up | Empty. Saved for things you add later. |
| `10.244.0.0/16` | Pods. These addresses exist only inside the cluster. |
| `10.0.0.0/16` | Services. Also only inside the cluster. |

Rules for picking:

- It must be a **private** range: `10.0` to `10.255`, `172.16` to `172.29`,
  or `192.168`. Private addresses never clash with the real internet.
- Pick one that **no other network of yours uses** (your office, or another
  cluster). Two networks with the same addresses can never be joined later.
  That is why this is a choice and not a fixed number.
- If you pick `10.0` or `10.244`, the script moves the service or pod range
  out of the way by itself.
- The pod and service ranges are set near the top of the `derive_names` part
  of the script. Change them there if a network your apps must reach already
  uses `10.244.x.x` or `10.0.x.x`.

---

## Two sizes: `small` and `ha`

"ha" means *high availability*: it keeps working when one part breaks.

| | `small` (practice) | `ha` (real users) |
|---|---|---|
| When it is used | The default | When `--env prod`, or `--profile ha` |
| Tier | free | standard (adds an uptime promise) |
| Zones (separate data centers) | none | 1, 2 and 3 |
| System nodes | 1 x Standard_D2ds_v5 | 3 x Standard_D4ds_v5 |
| App nodes | 1 to 3 x Standard_D4ds_v5 | 3 to 6 x Standard_D4ds_v5 |
| Disk type | Premium_LRS | Premium_ZRS |
| Rough cost to start | about $270 a month | about $1,100 a month |

**About the cost.** These are rough numbers for the East US regions in late
2026. The node computers are almost the whole bill. A Standard_D4ds_v5 costs
about $165 a month, and a D2ds_v5 about half of that. The standard tier adds
about $73 a month. Check your own numbers in the
[Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/)
before you build. **Take the cluster down when you are done practicing**
(`./destroy-aks.sh --name shop`), or it keeps charging you.

---

## All the options of `create-aks.sh`

| Option | What it does | Default |
|---|---|---|
| `-n, --name` | Project name. **Required.** | |
| `-i, --ip-base` | First two numbers of your network. **Required.** | |
| `-e, --env` | A label such as `dev`, `test` or `prod` | `dev` |
| `-l, --location` | Azure region | `eastus2` |
| `-p, --profile` | `small` or `ha` | `small` (`ha` for prod) |
| `-s, --subscription` | Which Azure subscription to use | the one `az` uses now |
| `--node-size` | VM size for app nodes | `Standard_D4ds_v5` |
| `--system-node-size` | VM size for system nodes | from the profile |
| `--system-nodes` | How many system nodes | from the profile |
| `--user-nodes-min` | Fewest app nodes | from the profile |
| `--user-nodes-max` | Most app nodes | from the profile |
| `--zones` | `"1 2 3"` or `none` | from the profile |
| `--tier` | `free` or `standard` | from the profile |
| `--disk-sku` | Disk type for the storage class | ZRS with zones, LRS without |
| `--kubernetes-version` | Kubernetes version | `1.36` |
| `--istio-version` | Istio version | `1.31.4` |
| `--admin-group-id` | A Microsoft Entra group whose members become admins | only you |
| `--api-allowed-ips` | Only these addresses may reach the cluster's control desk | anywhere |
| `--tags` | Extra labels for billing, like `"owner=zac"` | |
| `--dry-run` | Show everything, change nothing | |
| `-y, --yes` | Do not ask "are you sure?" | |
| `-h, --help` | Show the help | |

Examples:

```bash
# A cheaper practice cluster in Europe
./create-aks.sh --name shop --ip-base 10.40 --location westeurope --node-size Standard_D2ds_v5

# A production cluster, with a group of admins
./create-aks.sh --name shop --ip-base 10.41 --env prod \
  --admin-group-id 1a2b3c4d-1111-2222-3333-1a2b3c4d5e6f
```

---

## What `create-aks.sh` does, step by step

The script is safe to run again. Before it makes anything, it checks whether
that thing already exists. If it does, the script leaves it alone and moves on.
So if a step fails, fix the problem and run the same command again.

### Getting ready

The script checks that your tools are installed and that you are signed in.
Then it shows you the plan and asks you to type `yes`, because the next steps
cost money. Nothing in Azure is touched before you say yes.

### Step 1. Make the resource group

A resource group is a folder in Azure. Everything this script makes goes in
one folder.

*Why:* you can see the cost of the whole project in one place. And when you
are done, deleting the folder removes everything in it.

### Step 2. Build the private network

A virtual network is like the hallways inside a school. Computers inside can
reach each other. Strangers outside cannot walk in.

*Why make our own?* AKS can make a network for you, but then AKS picks the
addresses. By making it first, you choose them, and you can connect this
network to others later.

### Step 3. Give the cluster an ID badge

The cluster needs permission to plug into the network and to use the public
address. We make a *managed identity*. It is like an ID badge that Azure looks
after for you.

*Why:* a badge has no password, so there is nothing to leak or forget to
change. The badge only has power inside this project's own folders. Giving
only the access that is needed is called *least privilege*.

### Step 4. Reserve a public address that never changes

This is your street address on the internet.

*Why reserve it?* If you let Azure pick one, it can change when the front door
is rebuilt. Then your website name would point at the wrong place. A reserved
address stays yours until you delete it.

### Step 5. Create the AKS cluster

Azure runs the "brain" of Kubernetes for you. This is the slow step. Here is
what the settings mean:

| Setting | In plain words | Why |
|---|---|---|
| `--kubernetes-version 1.36` | Which Kubernetes to install | A known version, so you get the same cluster every time |
| `--network-plugin azure`, `--network-plugin-mode overlay` | Nodes get addresses from your network. Pods get cluster-only addresses. | Pods do not use up the addresses in your network, so you will not run short |
| `--network-dataplane cilium`, `--network-policy cilium` | Cilium is the engine that moves traffic between pods | It is fast, and it lets you write rules about which pods may talk to each other |
| `--nodepool-taints CriticalAddonsOnly=true:NoSchedule` | A "staff only" sign on the system nodes | Your apps cannot crowd out the helpers Kubernetes needs |
| `--enable-aad`, `--enable-azure-rbac` | People log in with their own Microsoft account | You can see who did what, and remove one person without changing a shared password |
| `--disable-local-accounts` | Turn off the built-in master key | A master key that never expires is a gift to a thief |
| `--no-ssh-key` | Do not create remote-login keys for the nodes | One less key to lose |
| `--enable-oidc-issuer`, `--enable-workload-identity` | Lets an app prove who it is to Azure | Later, apps can read secrets without a password saved in a file |
| `--auto-upgrade-channel patch` | Install small safety fixes automatically | Many break-ins use holes that already had a fix |
| `--node-os-upgrade-channel NodeImage` | Keep the nodes' operating system fresh | Same reason |
| `--zones 1 2 3` (ha only) | Spread nodes over three data centers | One building can lose power and you stay up |
| `--tier standard` (ha only) | Pay for an uptime promise | Azure gives money back if the control desk is down too much |

### Step 6. Add worker nodes for your apps

A second group of computers, called `apps`, just for your apps. It grows when
apps need more room and shrinks when they do not. That is the *autoscaler*.

*Why two groups?* If an app goes wild and uses all the memory, the system
helpers on their own nodes are not hurt.

### Step 7. Get you a key to the cluster

Because we turned off the master key in step 5, nobody can log in yet. The
script gives your account (or your group) the admin role. Then it saves the
login settings so `kubectl` and `helm` can connect.

Every `kubectl` and `helm` command in the script names this cluster on
purpose. That way it can never change a different cluster by accident.

### Step 8. Install Istio and its gateway

Three Helm installs, in this order:

1. **base** teaches Kubernetes the new words Istio uses, like "Gateway".
2. **istiod** is the brain of Istio. It hands out the traffic rules.
3. **gateway** is the front door itself. Azure connects it to the public
   address from step 4.

*Why a gateway?* One guarded door is easier to protect than many. Every app
you add later shares this door and this address.

### Step 9. Add rooms and storage for future apps

Our own small chart, in `helm/platform`. It makes:

- a **Gateway** object: the sign on the door that says which website names
  may come in
- two **namespaces**: `keycloak` and `postgres`
- a **storage class**: an order form for fast disks that are *kept* when
  their claim is deleted
- two **volume claims**: `postgres-data` (32 GB) and `keycloak-data` (4 GB)

The claims will say `Pending`. That is correct. Azure makes the real disk, and
starts charging for it, only when the first app uses the claim.

---

## The Helm files

| File | What it is |
|---|---|
| `helm/istio/istiod-values.yaml` | Settings for the Istio brain: two copies, log format, where images come from |
| `helm/istio/gateway-values.yaml` | Settings for the front door: two copies, only ports 80 and 443 open, keep visitors' real addresses |
| `helm/platform/Chart.yaml` | The title card of our own chart |
| `helm/platform/values.yaml` | **The file you will edit most.** Hosts, HTTPS, rooms and volumes. |
| `helm/platform/values.schema.json` | A spell-checker for `values.yaml`. A typo gives a clear error. |
| `helm/platform/templates/` | The recipe steps. Each file makes one kind of thing. |

Every file has comments in plain words next to each setting.

Three safety belts protect your data:

1. Namespaces are marked "keep", so `helm uninstall` cannot delete a room.
2. Volume claims are marked "keep" too.
3. The storage class says `Retain`, so the real disk stays even if someone
   deletes a claim.

**One thing these belts do not cover:** Azure keeps the disks in the folder
that AKS manages (`rg-shop-dev-nodes`). If you delete the *whole cluster*, the
disks go with it. Back up anything you care about first.

---

## Adding your apps later

### Give an app its storage

There are two ways. Which one depends on the app's own chart.

**Way A: the chart can use a claim that already exists.** Many charts have a
setting called `existingClaim`. Give it the name of the claim:

```yaml
persistence:
  existingClaim: postgres-data
```

**Way B: the app makes its own claims.** Database operators usually work this
way. Give them the name of the storage class instead. For example, with the
CloudNativePG operator:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg
  namespace: postgres
spec:
  instances: 1
  storage:
    size: 32Gi
    storageClass: platform-premium-retain
```

If you use Way B, delete the matching entry under `volumes:` in
`helm/platform/values.yaml`, since nothing will use it.

### Let an app in through the front door

Each app adds a *VirtualService*. It says "requests for my name go to my
service". Use your app's real service name and port.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: keycloak
  namespace: keycloak
spec:
  hosts:
    - "login.example.com"
  gateways:
    - istio-ingress/public-gateway
  http:
    - route:
        - destination:
            host: keycloak.keycloak.svc.cluster.local
            port:
              number: 8080
```

### Point a website name at the door

At the company where you bought your website name, add an **A record** that
points the name at your front door address. The script prints the address at
the end. You can also ask for it:

```bash
az network public-ip show -g rg-shop-dev -n pip-shop-dev-ingress --query ipAddress -o tsv
```

### Turn on HTTPS (do this before real users arrive)

Until you do this, the door only speaks plain HTTP, and passwords could be
read on the way.

1. Get a certificate for your website name. You can buy one, or get a free
   one from Let's Encrypt with a tool called cert-manager.
2. Put it in the cluster, in the door's namespace:
   ```bash
   kubectl create secret tls public-gateway-tls -n istio-ingress \
     --cert=fullchain.pem --key=privkey.pem
   ```
3. In `helm/platform/values.yaml`, set `gateway.tls.enabled: true` and list
   your names under `gateway.hosts`.
4. Run `create-aks.sh` again with the same options.

---

## Changing things later

- **Change a setting in a Helm file:** edit it, then run the script again
  with the same options. It skips what exists and applies your change.
- **Make a volume bigger:** raise its `size` in `values.yaml` and run the
  script again. Volumes can grow but never shrink.
- **Change the number of nodes:** the script never changes a cluster that
  already exists. Use Azure directly:
  ```bash
  az aks nodepool update -g rg-shop-dev --cluster-name aks-shop-dev --name apps \
    --update-cluster-autoscaler --min-count 2 --max-count 6
  ```
- **Upgrade Kubernetes:** small fixes install themselves. To move to a new
  version such as 1.37, first check that your Istio version supports it. Then:
  ```bash
  az aks upgrade -g rg-shop-dev -n aks-shop-dev --kubernetes-version 1.37
  ```
- **Upgrade Istio:** run the script again with `--istio-version` and the new
  number. Go up one step at a time (1.31, then 1.32). Then restart the door
  and your apps so they pick up the new helpers:
  ```bash
  kubectl rollout restart deployment -n istio-ingress istio-ingressgateway
  ```

## Taking it down

```bash
./destroy-aks.sh --name shop --dry-run        # practice: shows the commands, deletes nothing
./destroy-aks.sh --name shop                  # the cluster and everything else
./destroy-aks.sh --name shop --keep-network   # only the cluster
```

Use the same `--name` and `--env` you gave `create-aks.sh`. That is how the
script finds the right things. You can even paste the same line you used
before: `--ip-base`, `--location` and `--profile` are accepted and skipped.

### What it does

1. **Looks around.** It lists what is really there, including any disks that
   hold data. Nothing is changed yet.
2. **Asks you to type the cluster's name.** Anything else stops it.
3. **Deletes the cluster.** Its worker computers, its load balancer and its
   disks go with it. This takes about 5 to 10 minutes.
4. **Deletes the resource group**, and with it the network, the public
   address and the ID badge.
5. **Tidies your computer.** It removes the saved login, so `kubectl` does
   not keep pointing at a cluster that is gone.

If a step fails, fix the cause and run the same command again. It carries on
from where it stopped.

> **There is no undo.** Azure keeps the disks your apps use inside the
> cluster's own folder (`rg-shop-dev-nodes`). When the cluster is deleted, the
> disks and the data on them are deleted too. Back up anything you need first.

### Safety belts

`create-aks.sh` sticks a label on everything it makes:
`created-by=create-aks.sh`. The destroy script uses that label as proof.

- **The label check.** A cluster or resource group without the label is left
  alone. Maybe it was made by hand, or maybe the name is a mix-up.
- **The stranger check.** If the resource group holds anything this kit did
  not make, such as a key vault you added later, the script stops and shows
  you the list.

In both cases the script names your choices: `--keep-network` deletes only
the cluster, and `--force` deletes everything anyway.

### `--keep-network`: start over, keep your address

This deletes only the cluster. The network, the public address and the ID
badge stay. Run `create-aks.sh` again with the same `--name`, `--env` and
`--ip-base`, and the new cluster gets the **same public address**. Your
website name keeps pointing at the right place.

The network and the ID badge cost nothing. A reserved public address has a
small monthly cost. To remove what is left, run `destroy-aks.sh` once more
without `--keep-network`.

### All the options of `destroy-aks.sh`

| Option | What it does | Default |
|---|---|---|
| `-n, --name` | The project name you gave `create-aks.sh`. **Required.** | |
| `-e, --env` | The label you gave `create-aks.sh` | `dev` |
| `-s, --subscription` | Which Azure subscription to use | the one `az` uses now |
| `--keep-network` | Delete only the cluster | off |
| `--force` | Also delete things this kit did not make | off |
| `--dry-run` | Show the commands, delete nothing | |
| `-y, --yes` | Do not ask for the cluster's name. For automation only. | |
| `-h, --help` | Show the help | |

---

## Left for later

This kit is a foundation. These things are worth adding before real users
depend on it:

1. **HTTPS.** See the steps above.
2. **Backups.** Azure has a service called AKS Backup. For Postgres, also keep
   regular database dumps somewhere outside the cluster.
3. **Monitoring.** The cluster does not send logs or alerts anywhere yet.
   Azure Monitor can collect both.
4. **Lock the control desk.** Use `--api-allowed-ips` so only your office or
   home address can reach the Kubernetes API.
5. **Strict mutual TLS.** A switch in `helm/platform/values.yaml`
   (`mesh.strictMtls`) makes meshed apps refuse callers that skip Istio's
   secret handshake.
6. **Your own image store.** Istio's images now come only from Docker Hub,
   which limits how often you may download. For busy clusters, copy the
   images into an Azure Container Registry and set `global.hub` in
   `istiod-values.yaml`.
7. **A vault for passwords.** Azure Key Vault can hold the Postgres and
   Keycloak passwords. The workload identity setting from step 5 lets apps
   read them without a saved password.

---

## If something goes wrong

| What you see | What it means | What to do |
|---|---|---|
| `does not have authorization to perform action 'Microsoft.Authorization/roleAssignments/write'` | You may not hand out permission slips | Ask to be made Owner of the subscription, or Contributor plus User Access Administrator |
| A message about `quota` or `cores` | Your subscription may not run that many computers yet | Use the small profile or a smaller `--node-size`, or ask for more quota in the Azure portal |
| `The VM size ... is not allowed` | That computer size is not sold in your region | Pick another with `--node-size`. List them: `az vm list-skus -l eastus2 --size Standard_D -o table` |
| An error that mentions `zone` | Your region has no separate zones | Add `--zones none` |
| An error about the Kubernetes version | That version is not offered in your region | See the list: `az aks get-versions -l eastus2 -o table`. Then pass `--kubernetes-version`. |
| `The cluster still says no` | Your login is not accepted yet | Check you are in the admin group, and that your address is in `--api-allowed-ips`. In Cloud Shell it can also help to run `az login` once and try again. |
| The gateway has no address | Azure could not attach the public IP | Run `kubectl -n istio-ingress describe service istio-ingressgateway` and read the last lines |
| A claim stays `Pending` | Nothing uses it yet | Normal. It fills in when an app starts. |
| A claim stays `Pending` *after* an app starts, with an error about `ZRS` | Your region does not sell zone-copied disks | Run `kubectl delete storageclass platform-premium-retain`, then run the script again with `--disk-sku Premium_LRS`. Deleting the order form does not touch any disk. |
| `exists and cannot be imported` | A namespace was made by hand before | Remove it from `namespaces:` in `values.yaml` |
| `does not carry the label created-by=create-aks.sh` (destroy) | The cluster or group was not made by this kit, or its labels were changed | Check `--name` and `--env`. If it really is yours, add `--force`, or use `--keep-network` to leave the group alone. |
| `also holds things that create-aks.sh did not make` (destroy) | Something else is in the resource group. Maybe someone added it, or you turned on an Azure feature, such as monitoring, that keeps its parts there. | Read the list. Move or delete those things yourself, or use `--keep-network`, or add `--force` to delete them too. |
| `ScopeLocked` (destroy) | Someone put a "do not delete" lock on the group | Remove the lock in the Azure portal, then run the same command again |

If a step fails, the script tells you which step. Fix the cause, then run the
same command again.

---

## Versions

Checked on 12 November 2026. Treat them as a matched set.

| Part | Version | Notes |
|---|---|---|
| Kubernetes | 1.36 | AKS supports 1.35, 1.36 and 1.37 today |
| Istio | 1.31.4 | Supports Kubernetes 1.32 to 1.37. The Istio project lists 1.31.4 and newer as free of known security holes. |
| Istio 1.32.0 | optional | Came out on 9 November 2026. These files were checked with it too: add `--istio-version 1.32.0`. |
| Azure CLI | 2.92.0 | The version the commands were checked with |
| Helm | 3.19 and 4.0 | Both produce the same result with these files |

Istio moved its downloads in 2026. Charts now come from
`https://blob.istio.io/istio-release/charts` and images from Docker Hub. The
old Google addresses switch off in December 2026. This kit already uses the
new ones.

---

## How this was checked

No Azure subscription was available while this kit was written, so nothing was
built for real. Here is what *was* done:

- **Both scripts** pass ShellCheck with no warnings. They were run in dry-run
  mode, and in full against stand-in versions of `az`, `kubectl`, `helm` and
  `kubelogin`.
- **For `create-aks.sh`** that covered a fresh build, a second run, a failed
  run that was then resumed, wrong inputs, and slow permissions.
- **For `destroy-aks.sh`** it covered a full delete, a cluster-only delete, a
  build, take-down and rebuild in a row, a wrong or missing confirmation,
  missing labels, things the kit did not make, and failures part-way through.
  A separate check confirmed both scripts work out the same names.
- **Every `az` command** the scripts produce was handed to the real Azure CLI
  2.92.0 to confirm each option exists and is spelled right.
- **Old and new bash.** The scripts give the same output in bash 3.2 (the one
  on a Mac) and bash 5.2.
- **The Helm files** were rendered against the official Istio 1.31.4 and
  1.32.0 charts with both Helm 3 and Helm 4. The results were checked against
  the Kubernetes 1.36 rules and Istio's own definitions.

What that does **not** prove: that Azure accepts every setting together, that
your subscription has enough quota, or that your region sells these sizes.
That is why the first real run should be the small profile.

---

## Where the facts came from

- [AKS supported Kubernetes versions](https://learn.microsoft.com/azure/aks/supported-kubernetes-versions)
- [AKS pricing tiers](https://learn.microsoft.com/azure/aks/free-standard-pricing-tiers)
- [Use a static public IP with the AKS load balancer](https://learn.microsoft.com/azure/aks/static-ip)
- [Azure Disk CSI driver on AKS](https://learn.microsoft.com/azure/aks/azure-disk-csi)
- [Availability zones in AKS](https://learn.microsoft.com/azure/aks/availability-zones)
- [Azure CNI Powered by Cilium](https://learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium)
- [kubelogin authentication in AKS](https://learn.microsoft.com/azure/aks/kubelogin-authentication)
- [Disks are deleted with the cluster (Microsoft Q&A)](https://learn.microsoft.com/en-au/answers/questions/385555/azure-managed-disks-are-getting-deleted-when-the-a)
- [Istio supported releases](https://istio.io/latest/about/supported-releases)
- [Istio 1.31 announcement](https://istio.io/news/releases/1.31.x/announcing-1.31/)
- [Istio's move off Google Cloud](https://istio.io/latest/blog/2026/retirement-of-gcp/)
- [Upgrade Istio with Helm](https://istio.io/latest/docs/setup/upgrade/helm)
