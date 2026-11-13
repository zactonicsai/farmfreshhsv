#!/usr/bin/env bash
# =============================================================================
#  destroy-aks.sh
#
#  WHAT THIS DOES (in plain words)
#    It takes down what create-aks.sh built, in this order:
#
#      1. The cluster, with its worker computers and its disks
#      2. The folder that holds the network, the public address and the
#         cluster's ID badge          (skip this part with --keep-network)
#      3. The saved login for the cluster on this computer
#
#  THERE IS NO UNDO
#    Disks hold your data, for example the Postgres database. Azure keeps
#    them inside the cluster's own folder, so when the cluster goes, they go.
#    Back up anything you need BEFORE you run this.
#
#  SAFETY BELTS
#    * It first shows everything it found, then asks you to type the
#      cluster's name. Anything else stops it.
#    * It only deletes things that carry the label create-aks.sh puts on
#      them. Anything else needs --force.
#    * --dry-run prints the commands and deletes nothing.
#
#  EXAMPLES
#    ./destroy-aks.sh --name shop --dry-run
#    ./destroy-aks.sh --name shop
#    ./destroy-aks.sh --name shop --env prod --keep-network
#
#  Runs on Linux, macOS (even its old bash 3.2), WSL and Azure Cloud Shell.
# =============================================================================

# Stop at the first error. For a script that deletes things this matters even
# more: if a check fails, we must not carry on to the deleting part.
#   -e  stop when a command fails
#   -E  make our "something went wrong" message work inside functions too
#   -u  stop if we use a variable we never set (an empty name must never
#       reach a delete command)
#   -o pipefail  a chain of commands fails if ANY link fails
set -Eeuo pipefail

# Git Bash on Windows tries to "fix" anything that starts with a slash.
export MSYS_NO_PATHCONV=1
# Hide Azure CLI chatter such as "this command is in preview". Real errors still show.
export AZURE_CORE_ONLY_SHOW_ERRORS=true

# -----------------------------------------------------------------------------
# The label create-aks.sh sticks on everything it makes. It is our proof that
# a thing belongs to this kit. No label, no delete (unless you say --force).
# -----------------------------------------------------------------------------
MADE_BY_KEY="created-by"
MADE_BY_VALUE="create-aks.sh"

# -----------------------------------------------------------------------------
# INPUTS. Empty means "not chosen yet".
# -----------------------------------------------------------------------------
NAME=""; ENV_NAME=""; SUBSCRIPTION=""
KEEP_NETWORK=false; FORCE=false; DRY_RUN=false; ASSUME_YES=false

# Things the script works out as it goes.
STEP_NO=0; STEP_TOTAL=3; STEP_TITLE=""
SUBSCRIPTION_ID=""; SUBSCRIPTION_NAME=""
RG_EXISTS=false; CLUSTER_EXISTS=false
NODE_RG_LIVE=""      # the folder AKS manages by itself (asked from the real cluster)
INVENTORY=""         # everything found in the resource group: "type<TAB>name" lines
DISKS=""             # app disks found: "disk<TAB>size<TAB>namespace<TAB>claim" lines
DISKS_KNOWN=false    # true once the disk list was read without trouble
EXTRAS=""            # things in the resource group that create-aks.sh did NOT make
KEPT_IP=""

# =============================================================================
#  Small helpers (the same ones create-aks.sh uses)
# =============================================================================

# Use colors only when a person is looking at a terminal.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_OFF=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_OFF=""
fi

info() { printf '%s\n' "  $*"; }
# ok: a green tick for something that really happened (so it stays quiet in a dry run).
ok() {
  if [[ "$DRY_RUN" == true ]]; then return 0; fi
  printf '%s\n' "  ${C_GREEN}ok${C_OFF}    $*"
}
note() { printf '%s\n' "  ${C_YELLOW}note${C_OFF}  $*"; }
die()  { printf '\n%s\n\n' "${C_RED}STOP:${C_OFF} $*" >&2; exit 1; }

# step "Title" "one plain sentence about what happens"
step() {
  STEP_NO=$((STEP_NO + 1)); STEP_TITLE="$1"
  printf '\n%s\n' "${C_BOLD}Step ${STEP_NO} of ${STEP_TOTAL}: $1${C_OFF}"
  printf '%s\n' "  ${C_DIM}$2${C_OFF}"
}

# If any command fails, say so in plain words. (Skip the message inside
# sub-shells, otherwise the same failure would be announced twice.)
on_error() {
  local exit_code=$? line="$1"
  if [[ "${BASH_SUBSHELL}" -eq 0 ]]; then
    if [[ "$STEP_NO" -gt 0 ]]; then
      printf '\n%s\n' "${C_RED}Step ${STEP_NO} did not finish:${C_OFF} ${STEP_TITLE}  (script line ${line}, exit code ${exit_code})" >&2
    else
      printf '\n%s\n' "${C_RED}Something went wrong${C_OFF} before anything was deleted (script line ${line}, exit code ${exit_code})." >&2
    fi
    printf '%s\n' "The script has stopped and will not delete anything more. Read the message" >&2
    printf '%s\n\n' "just above. Once it is fixed, run the same command again to finish the job." >&2
  fi
}
trap 'on_error "$LINENO"' ERR

# Put quotes around a word only when it needs them, so printed commands
# look like something a person would type.
quote_arg() {
  local safe_re='^[A-Za-z0-9_./:=@%+,-]+$'
  if [[ "$1" =~ $safe_re ]]; then
    printf '%s' "$1"
  elif [[ "$1" == *"'"* ]]; then
    printf '%q' "$1"
  else
    printf "'%s'" "$1"
  fi
}

# Print a command the way you could type it, one option per line.
print_cmd() {
  local out="" arg quoted
  for arg in "$@"; do
    quoted="$(quote_arg "$arg")"
    if [[ -z "$out" ]]; then
      out="$quoted"
    elif [[ "$arg" == --* ]]; then
      out="${out} \\"$'\n'"        ${quoted}"
    else
      out="${out} ${quoted}"
    fi
  done
  printf '%s\n' "${C_DIM}    \$ ${out}${C_OFF}"
}

# run: show a command, then do it. In a dry run we only show it.
run() {
  print_cmd "$@"
  if [[ "$DRY_RUN" == true ]]; then return 0; fi
  "$@"
}

# az_do: run an Azure command that CHANGES something, in the chosen subscription.
az_do() { run az "$@" --subscription "$SUBSCRIPTION_ID" --output none; }

# az_get <pretend-answer> <az args...>: ask Azure for a value.
# In a dry run we do not talk to Azure, so we hand back the pretend answer.
az_get() {
  local pretend="$1"
  shift
  if [[ "$DRY_RUN" == true ]]; then printf '%s' "$pretend"; return 0; fi
  # tr removes the stray "\r" that Windows adds to the end of lines.
  az "$@" --subscription "$SUBSCRIPTION_ID" --output tsv | tr -d '\r'
}

# az_exists <az show ...>: "yes" if the thing exists, "no" if Azure says
# "not found". Any other problem (no internet, expired login) stops the script,
# so we never mistake "could not look" for "it is gone".
az_exists() {
  local out
  if [[ "$DRY_RUN" == true ]]; then return 0; fi
  if out="$(az "$@" --subscription "$SUBSCRIPTION_ID" --output none 2>&1)"; then return 0; fi
  if printf '%s' "$out" | grep -qiE 'not ?found|not be found|does not exist'; then return 1; fi
  die "I could not check Azure for: az $1 $2 $3
Azure said: ${out}"
}

# lower: small letters only, so "ManagedClusters" and "managedClusters" compare equal.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

usage() {
  cat <<EOF
${C_BOLD}destroy-aks.sh${C_OFF} - take down what create-aks.sh built

${C_BOLD}USAGE${C_OFF}
  ./destroy-aks.sh --name NAME [options]

${C_BOLD}YOU MUST GIVE${C_OFF}
  -n, --name NAME          The same name you gave create-aks.sh. Example: shop

${C_BOLD}CHOICES${C_OFF}
  -e, --env ENV            The same label you gave create-aks.sh   (default: dev)
  -s, --subscription ID    Azure subscription name or ID
                           (default: the one "az" is using now)
      --keep-network       Delete only the cluster. Keep the network, the public
                           address and the ID badge. Run create-aks.sh again
                           later and the new cluster gets the same address.
      --force              Also delete things that create-aks.sh did not make:
                           a cluster or resource group without its label, or
                           extra things someone added to the resource group.
      --dry-run            Show the commands. Delete nothing. Does not even
                           look at Azure.
  -y, --yes                Do not ask for the cluster's name. For robots only.
  -h, --help               Show this help

${C_BOLD}WHAT GETS DELETED${C_OFF}
                                    normal      with --keep-network
  cluster, its nodes and disks      deleted     deleted
  network, public address, badge    deleted     kept
  the resource group itself         deleted     kept
  saved kubectl login               removed     removed

${C_BOLD}THERE IS NO UNDO.${C_OFF} Disks with your data are deleted with the cluster.

${C_BOLD}EXAMPLES${C_OFF}
  ./destroy-aks.sh --name shop --dry-run
  ./destroy-aks.sh --name shop
  ./destroy-aks.sh --name shop --env prod --keep-network
EOF
}

# =============================================================================
#  Reading and checking what you typed
# =============================================================================

need_value() {
  if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
    die "The option $1 needs a value right after it. Example: $1 something"
  fi
}

parse_args() {
  # Let people write --name=shop as well as --name shop.
  local -a args=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      --*=*) args+=("${arg%%=*}" "${arg#*=}") ;;
      *)     args+=("$arg") ;;
    esac
  done
  set -- ${args[@]+"${args[@]}"}

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--name)            need_value "$@"; NAME="$2"; shift 2 ;;
      -e|--env)             need_value "$@"; ENV_NAME="$2"; shift 2 ;;
      -s|--subscription)    need_value "$@"; SUBSCRIPTION="$2"; shift 2 ;;
      --keep-network)       KEEP_NETWORK=true; shift ;;
      --force)              FORCE=true; shift ;;
      --dry-run)            DRY_RUN=true; shift ;;
      -y|--yes)             ASSUME_YES=true; shift ;;
      -h|--help)            usage; exit 0 ;;
      # People often reuse the line they typed for create-aks.sh. These three
      # options mean nothing here, so we accept them and move on.
      -i|--ip-base|-l|--location|-p|--profile)
                            need_value "$@"; shift 2 ;;
      -*) die "I don't know the option '$1'. Run ./destroy-aks.sh --help to see the list." ;;
      *)  die "I did not expect the word '$1' here. If a value has spaces, put it in quotes.
Options such as --dry-run and --yes take no value. Run ./destroy-aks.sh --help to see the list." ;;
    esac
  done
}

validate_inputs() {
  local re
  : "${ENV_NAME:=dev}"

  # The same rules as create-aks.sh. They also make sure a strange or empty
  # name can never end up inside a delete command.
  if [[ -z "$NAME" ]]; then die "Please say which project to take down. Example: --name shop   (see --help)"; fi
  re='^[a-z][a-z0-9-]{1,18}[a-z0-9]$'
  if [[ ! "$NAME" =~ $re || "$NAME" == *--* ]]; then
    die "--name must be 3-20 characters: small letters, numbers and single dashes.
It must start with a letter and may not end with a dash. You gave: ${NAME}"
  fi
  re='^[a-z0-9]{2,10}$'
  if [[ ! "$ENV_NAME" =~ $re ]]; then
    die "--env must be 2-10 small letters or numbers, like dev or prod. You gave: ${ENV_NAME}"
  fi
}

# Work out the names exactly the way create-aks.sh does.
# IMPORTANT: if you ever change the names in one script, change the other too.
derive_names() {
  local base="${NAME}-${ENV_NAME}"

  RG="rg-${base}"                       # the resource group (the folder)
  NODE_RG="rg-${base}-nodes"            # the folder AKS manages by itself
  CLUSTER="aks-${base}"                 # the cluster
  VNET="vnet-${base}"                   # the private network
  IDENTITY="id-${base}-aks"             # the cluster's ID badge
  PIP="pip-${base}-ingress"             # the public address
  KUBE_CONTEXT="${CLUSTER}"             # the name kubectl uses for this cluster

  if [[ "$KEEP_NETWORK" == true ]]; then STEP_TOTAL=2; fi
}

# =============================================================================
#  Getting ready and looking around
# =============================================================================

preflight() {
  printf '\n%s\n' "${C_BOLD}Getting ready${C_OFF}"

  # ---- dry run: do not talk to Azure at all ----
  if [[ "$DRY_RUN" == true ]]; then
    local guid_re='^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
    SUBSCRIPTION_ID="YOUR-SUBSCRIPTION-ID"
    if [[ "$SUBSCRIPTION" =~ $guid_re ]]; then SUBSCRIPTION_ID="$SUBSCRIPTION"; fi
    SUBSCRIPTION_NAME="${SUBSCRIPTION:-(not checked in a dry run)}"
    info "Dry run: nothing is checked and nothing is deleted."
    return 0
  fi

  if ! command -v az >/dev/null 2>&1; then
    die "The Azure CLI (az) is not installed here.
The easy fix: run this script in Azure Cloud Shell (https://shell.azure.com)."
  fi

  # ---- are you signed in, and to which subscription? ----
  if ! az account show --output none 2>/dev/null; then
    die "You are not signed in to Azure. Run this first:  az login"
  fi
  if [[ -n "$SUBSCRIPTION" ]]; then
    SUBSCRIPTION_ID="$(az account show --subscription "$SUBSCRIPTION" --query id --output tsv 2>/dev/null | tr -d '\r' || true)"
    if [[ -z "$SUBSCRIPTION_ID" ]]; then
      die "I can't find the subscription '${SUBSCRIPTION}'. See yours with: az account list -o table"
    fi
  else
    SUBSCRIPTION_ID="$(az account show --query id --output tsv | tr -d '\r')"
  fi
  SUBSCRIPTION_NAME="$(az account show --subscription "$SUBSCRIPTION_ID" --query name --output tsv | tr -d '\r')"
  ok "Signed in. Using subscription: ${SUBSCRIPTION_NAME}"
}

# Look at what is really there. Nothing is changed in this part.
look_around() {
  if [[ "$DRY_RUN" == true ]]; then
    # Pretend everything still exists, so every command is shown.
    RG_EXISTS=true; CLUSTER_EXISTS=true; NODE_RG_LIVE="$NODE_RG"
    return 0
  fi

  if az_exists group show --name "$RG"; then RG_EXISTS=true; fi
  if [[ "$RG_EXISTS" != true ]]; then return 0; fi
  if az_exists aks show --resource-group "$RG" --name "$CLUSTER"; then CLUSTER_EXISTS=true; fi

  local label

  if [[ "$CLUSTER_EXISTS" == true ]]; then
    # ---- safety belt: is this cluster one that create-aks.sh made? ----
    label="$(az_get "" aks show --resource-group "$RG" --name "$CLUSTER" --query "tags.\"${MADE_BY_KEY}\"")"
    if [[ "$label" != "$MADE_BY_VALUE" && "$FORCE" != true ]]; then
      die "The cluster ${CLUSTER} does not carry the label ${MADE_BY_KEY}=${MADE_BY_VALUE}.
That label is how I know create-aks.sh made it, and I only delete what it made.
If you are sure this is the right cluster, run again with --force."
    fi

    # Ask the cluster where it keeps its machines and disks.
    NODE_RG_LIVE="$(az_get "" aks show --resource-group "$RG" --name "$CLUSTER" --query nodeResourceGroup)"

    # Find the disks that apps created through volume claims. Their names start
    # with "pvc-". This is only for showing you. If the list cannot be read we
    # carry on, but we say so instead of claiming there are none.
    local disk_list
    if [[ -n "$NODE_RG_LIVE" ]] && disk_list="$(az disk list --resource-group "$NODE_RG_LIVE" --subscription "$SUBSCRIPTION_ID" \
        --query "[?starts_with(name, 'pvc-')].[name, to_string(diskSizeGB || diskSizeGb), tags.\"kubernetes.io-created-for-pvc-namespace\", tags.\"kubernetes.io-created-for-pvc-name\"]" \
        --output tsv 2>/dev/null)"; then
      DISKS="$(printf '%s' "$disk_list" | tr -d '\r')"
      DISKS_KNOWN=true
    fi
  fi

  if [[ "$KEEP_NETWORK" != true ]]; then
    # ---- safety belt: is this resource group one that create-aks.sh made? ----
    label="$(az_get "" group show --name "$RG" --query "tags.\"${MADE_BY_KEY}\"")"
    if [[ "$label" != "$MADE_BY_VALUE" && "$FORCE" != true ]]; then
      die "The resource group ${RG} does not carry the label ${MADE_BY_KEY}=${MADE_BY_VALUE}.
It was probably made by hand before create-aks.sh ran, so it may hold other things.
Your choices:
  --keep-network   delete only the cluster and leave the group alone
  --force          delete the whole group anyway"
    fi

    # ---- safety belt: is there anything in the group that we did not make? ----
    INVENTORY="$(az_get "" resource list --resource-group "$RG" --query "[].[type, name]")"
    local kind item
    while IFS=$'\t' read -r kind item; do
      if [[ -z "$kind" ]]; then continue; fi
      if [[ "$(friendly_name "$kind" "$item")" == "" ]]; then
        EXTRAS="${EXTRAS}      ${item}   (${kind})"$'\n'
      fi
    done <<< "$INVENTORY"
    if [[ -n "$EXTRAS" && "$FORCE" != true ]]; then
      die "The resource group ${RG} also holds things that create-aks.sh did not make:
${EXTRAS}Deleting the group would delete them too, so I stopped.
Your choices:
  --keep-network   delete only the cluster and leave the rest alone
  --force          delete everything in the group, these included"
    fi
  fi
}

# friendly_name <azure type> <name>: a plain-words name for the four things
# create-aks.sh puts in the resource group. Prints nothing for anything else.
friendly_name() {
  case "$(lower "$1")|$2" in
    "microsoft.containerservice/managedclusters|${CLUSTER}")           printf '%s' "the cluster" ;;
    "microsoft.network/virtualnetworks|${VNET}")                       printf '%s' "the private network" ;;
    "microsoft.network/publicipaddresses|${PIP}")                      printf '%s' "the public address" ;;
    "microsoft.managedidentity/userassignedidentities|${IDENTITY}")    printf '%s' "the cluster's ID badge" ;;
    *) ;;
  esac
}

show_plan() {
  printf '\n%s\n' "${C_BOLD}What will be deleted${C_OFF}"
  info "Subscription       ${SUBSCRIPTION_NAME}"

  if [[ "$DRY_RUN" == true ]]; then
    cat <<EOF
  Cluster            ${CLUSTER}   (with its nodes, load balancer and disks)
EOF
    if [[ "$KEEP_NETWORK" == true ]]; then
      info "Kept               ${VNET}, ${PIP} and ${IDENTITY} in ${RG}"
    else
      info "Resource group     ${RG}   (with the network, public address and ID badge)"
    fi
    info "On this computer   the saved kubectl login named ${KUBE_CONTEXT}"
    printf '\n%s\n' "${C_YELLOW}DRY RUN:${C_OFF} nothing will be deleted. A dry run does not look at Azure, so below are"
    printf '%s\n' "the commands a real run would use, shown as if everything still existed."
    return 0
  fi

  # ---- the cluster ----
  if [[ "$CLUSTER_EXISTS" == true ]]; then
    info "Cluster            ${CLUSTER}"
    info "  and its folder   ${NODE_RG_LIVE:-$NODE_RG}   (nodes, load balancer, disks)"
  else
    info "Cluster            ${CLUSTER} is already gone"
  fi

  # ---- disks with data ----
  if [[ -n "$DISKS" ]]; then
    printf '%s\n' "  ${C_RED}Disks with data${C_OFF}    Everything on these is erased for good:"
    local disk size ns claim
    while IFS=$'\t' read -r disk size ns claim; do
      if [[ -z "$disk" ]]; then continue; fi
      if [[ "$ns" == "None" || -z "$ns" ]]; then ns="?"; fi
      if [[ "$claim" == "None" || -z "$claim" ]]; then claim="$disk"; fi
      if [[ "$size" == "null" || "$size" == "None" || -z "$size" ]]; then size="?"; fi
      info "    ${ns}/${claim}   ${size} GB"
    done <<< "$DISKS"
  elif [[ "$CLUSTER_EXISTS" == true && "$DISKS_KNOWN" == true ]]; then
    info "Disks with data    none found (no app has used a volume claim yet)"
  elif [[ "$CLUSTER_EXISTS" == true ]]; then
    printf '%s\n' "  ${C_RED}Disks with data${C_OFF}    I could not read the list. Assume there are some: they will be erased."
  fi

  # ---- the resource group ----
  if [[ "$KEEP_NETWORK" == true ]]; then
    printf '\n%s\n' "${C_BOLD}What stays${C_OFF} (because of --keep-network)"
    info "In ${RG}: the network ${VNET}, the public address ${PIP}"
    info "and the ID badge ${IDENTITY}"
  else
    info "Resource group     ${RG}   and everything in it:"
    local kind item label
    while IFS=$'\t' read -r kind item; do
      if [[ -z "$kind" ]]; then continue; fi
      label="$(friendly_name "$kind" "$item")"
      if [[ "$label" == "the cluster" ]]; then
        continue      # already shown above
      elif [[ -n "$label" ]]; then
        info "    ${label}: ${item}"
      else
        printf '%s\n' "      ${C_YELLOW}NOT made by create-aks.sh${C_OFF}: ${item}   (${kind})"
      fi
    done <<< "$INVENTORY"
  fi

  printf '\n'
  info "On this computer   the saved kubectl login named ${KUBE_CONTEXT}"
  printf '\n%s\n' "  ${C_RED}${C_BOLD}There is no undo.${C_OFF}"
}

confirm() {
  if [[ "$DRY_RUN" == true || "$ASSUME_YES" == true ]]; then return 0; fi
  if [[ ! -t 0 ]]; then
    die "This deletes things for good, and nobody is at the keyboard to confirm.
Add --yes if you really want to delete without being asked."
  fi
  local answer=""
  printf '\n%s' "To go ahead, type the cluster's name (${C_BOLD}${CLUSTER}${C_OFF}): "
  read -r answer
  if [[ "$answer" != "$CLUSTER" ]]; then die "That did not match, so I stopped. Nothing was deleted."; fi
}

# =============================================================================
#  The steps
# =============================================================================

step_delete_cluster() {
  step "Delete the cluster" \
       "Azure removes the cluster, its worker computers, its load balancer and its disks. About 5 to 10 minutes."

  if [[ "$CLUSTER_EXISTS" == true ]]; then
    az_do aks delete --resource-group "$RG" --name "$CLUSTER" --yes
    ok "Cluster ${CLUSTER} deleted"
  else
    ok "Cluster ${CLUSTER} was already gone"
  fi
}

step_delete_group() {
  step "Delete the resource group" \
       "The folder goes, and with it the network, the public address and the ID badge."

  az_do group delete --name "$RG" --yes
  ok "Resource group ${RG} deleted"
}

step_forget_login() {
  step "Tidy up this computer" \
       "Remove the saved login, so kubectl does not keep pointing at a cluster that is gone."

  # These are the three entries 'az aks get-credentials' wrote for this cluster.
  local user_entry="clusterUser_${RG}_${CLUSTER}"

  if [[ "$DRY_RUN" == true ]]; then
    print_cmd kubectl config delete-context "$KUBE_CONTEXT"
    print_cmd kubectl config delete-cluster "$CLUSTER"
    print_cmd kubectl config delete-user "$user_entry"
    return 0
  fi
  if ! command -v kubectl >/dev/null 2>&1; then
    info "kubectl is not installed here, so there is no saved login to remove."
    return 0
  fi

  # Each delete fails harmlessly when the entry is not there. That is fine.
  local removed=false current=""
  current="$(kubectl config current-context 2>/dev/null || true)"
  if kubectl config delete-context "$KUBE_CONTEXT" >/dev/null 2>&1; then removed=true; fi
  if kubectl config delete-cluster "$CLUSTER" >/dev/null 2>&1; then removed=true; fi
  if kubectl config delete-user "$user_entry" >/dev/null 2>&1; then removed=true; fi
  # If kubectl was pointed at this cluster, point it at nothing.
  if [[ "$current" == "$KUBE_CONTEXT" ]]; then
    kubectl config unset current-context >/dev/null 2>&1 || true
  fi

  if [[ "$removed" == true ]]; then
    ok "Removed the saved kubectl login for ${KUBE_CONTEXT}"
  else
    ok "No saved kubectl login for ${KUBE_CONTEXT} was found"
  fi
}

show_summary() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '\n%s\n' "${C_BOLD}End of dry run.${C_OFF} Nothing was deleted. Remove --dry-run to do it for real."
    return 0
  fi

  if [[ "$KEEP_NETWORK" == true ]]; then
    printf '\n%s\n' "${C_GREEN}${C_BOLD}The cluster is gone.${C_OFF}"
    cat <<EOF

  Kept in ${RG}:
    the network          ${VNET}
    the public address   ${PIP}${KEPT_IP:+   (${KEPT_IP})}
    the ID badge         ${IDENTITY}

  The network and the ID badge cost nothing. A reserved public address has a
  small monthly cost.

  To rebuild on the same address, run create-aks.sh again with the same
  --name, --env and --ip-base as before.
  To remove what is left:  ./destroy-aks.sh --name ${NAME} --env ${ENV_NAME}
EOF
  else
    printf '\n%s\n' "${C_GREEN}${C_BOLD}All gone.${C_OFF}"
    cat <<EOF

  Deleted: the cluster ${CLUSTER} and the resource group ${RG} with
  everything in it. Nothing from this project is left in Azure to pay for.
EOF
  fi
}

# =============================================================================
#  Run it
# =============================================================================

main() {
  parse_args "$@"
  validate_inputs
  derive_names
  preflight
  look_around

  # ---- nothing there? then there is nothing to delete ----
  if [[ "$RG_EXISTS" != true ]]; then
    printf '\n%s\n' "${C_BOLD}Nothing to delete in Azure.${C_OFF}"
    info "There is no resource group named ${RG} in the subscription ${SUBSCRIPTION_NAME}."
    info "Check --name and --env. They must match what you gave create-aks.sh."
    STEP_TOTAL=1
    step_forget_login
    return 0
  fi
  if [[ "$KEEP_NETWORK" == true && "$CLUSTER_EXISTS" != true ]]; then
    printf '\n%s\n' "${C_BOLD}Nothing to delete in Azure.${C_OFF}"
    info "The cluster ${CLUSTER} is already gone, and --keep-network leaves the rest alone."
    STEP_TOTAL=1
    step_forget_login
    return 0
  fi

  show_plan
  confirm

  step_delete_cluster
  if [[ "$KEEP_NETWORK" != true ]]; then
    step_delete_group
  elif [[ "$DRY_RUN" != true ]]; then
    # Look up the address we kept, just to show it. Not finding it is harmless.
    KEPT_IP="$(az network public-ip show --resource-group "$RG" --name "$PIP" --subscription "$SUBSCRIPTION_ID" \
      --query ipAddress --output tsv 2>/dev/null | tr -d '\r' || true)"
  fi
  step_forget_login
  show_summary
}

main "$@"
