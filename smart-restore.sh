#!/usr/bin/env bash
# =============================================================================
# smart-restore.sh
# Restores any kind cluster backed up to GitHub.
#
# What it asks you:
#   1. GitHub username + PAT + repo  (to fetch the list of available clusters)
#   2. Which cluster to restore      (shows live list from GitHub, pick by number)
#   3. CNPG operator version         (e.g. 1.29.1)
#
# What it does automatically:
#   - Runs cnpg_prereqs.sh          (installs kind/kubectl/git-lfs)
#   - Runs cnpg_restore.sh          (clones repo, loads image, creates kind cluster)
#   - Installs CNPG operator        (exact version you specified)
#   - Runs cnpg_verify.sh           (confirms cluster is healthy)
#
# Usage:
#   chmod +x smart-restore.sh && ./smart-restore.sh
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}═══ $* ═══${RESET}\n"; }
divider() { echo "────────────────────────────────────────────────────────"; }

cleanup() { unset GITHUB_TOKEN 2>/dev/null || true; }
trap cleanup EXIT

# ── Install CNPG operator at exact version ────────────────────────────────────
install_cnpg_operator() {
    local version="$1"
    local cluster="$2"
    local context="kind-${cluster}"
    local major minor branch manifest_url

    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)
    branch="release-${major}.${minor}"
    manifest_url="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${branch}/releases/cnpg-${version}.yaml"

    info "Installing CNPG operator v${version} (branch: ${branch})..."
    info "Manifest: ${manifest_url}"

    if kubectl apply --server-side --context "${context}" -f "${manifest_url}" 2>&1; then
        success "CNPG operator v${version} applied."
    else
        warn "Retrying without --server-side..."
        kubectl apply --context "${context}" -f "${manifest_url}" 2>&1
        success "CNPG operator v${version} applied (fallback)."
    fi

    info "Waiting for operator to be ready (up to 3 minutes)..."
    kubectl rollout status deployment \
        --context "${context}" \
        -n cnpg-system \
        --timeout=180s 2>/dev/null \
        && success "CNPG operator is ready." \
        || warn "Operator not ready yet — re-run cnpg_verify.sh in a few minutes."
}

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║        GitHub → Kind Cluster Restore Tool            ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""

# ── Pre-flight ────────────────────────────────────────────────────────────────
for cmd in curl python3; do
    command -v "$cmd" &>/dev/null || { error "$cmd not found."; exit 1; }
done

docker info &>/dev/null 2>&1 || {
    error "Docker Desktop is not running. Start it and wait for the whale icon to go solid."
    exit 1
}

# ── Step 1: GitHub credentials ────────────────────────────────────────────────
header "Step 1 · GitHub credentials"

read -rp "$(echo -e "${BOLD}GitHub username: ${RESET}")" GITHUB_USER

echo -e "${YELLOW}GitHub Personal Access Token (input hidden — needs 'repo' scope):${RESET}"
echo -e "  Create one at: ${CYAN}https://github.com/settings/tokens${RESET}"
echo ""
read -rsp "$(echo -e "${BOLD}GitHub PAT: ${RESET}")" GITHUB_TOKEN
echo ""

read -rp "$(echo -e "${BOLD}GitHub repo name (e.g. Kind-Cluster-Backup-and-restore): ${RESET}")" GITHUB_REPO

echo ""
info "Verifying credentials..."
LOGIN=$(curl -s \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/user" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('login','ERROR'))" 2>/dev/null)

[[ "$LOGIN" == "ERROR" || -z "$LOGIN" ]] && { error "Invalid token."; exit 1; }
success "Authenticated as: ${LOGIN}"

# ── Step 2: Fetch available clusters from GitHub ──────────────────────────────
header "Step 2 · Available clusters in GitHub repo"

info "Fetching folder list from ${GITHUB_USER}/${GITHUB_REPO}..."

CONTENTS=$(curl -s \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}/contents/")

# Extract folders that contain cnpg-snapshot.tar (i.e. valid cluster backups)
CLUSTER_LIST=$(echo "$CONTENTS" | python3 -c "
import sys, json
items = json.load(sys.stdin)
folders = [i['name'] for i in items if i['type'] == 'dir']
for f in folders:
    print(f)
" 2>/dev/null || true)

if [[ -z "$CLUSTER_LIST" ]]; then
    error "No cluster folders found in ${GITHUB_USER}/${GITHUB_REPO}."
    echo "  Make sure you have run smart-backup.sh first to upload cluster artifacts."
    exit 1
fi

# Verify each folder has the required files and get snapshot size
echo ""
printf "  ${BOLD}%-4s  %-20s  %-16s  %-16s  %s${RESET}\n" "#" "CLUSTER NAME" "SNAPSHOT" "K8S CONFIG" "CNPG BLUEPRINTS"
divider

mapfile -t CLUSTERS <<< "$CLUSTER_LIST"
VALID_CLUSTERS=()

for i in "${!CLUSTERS[@]}"; do
    FOLDER="${CLUSTERS[$i]}"

    # Check for the three required files via GitHub API
    FILES=$(curl -s \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}/contents/${FOLDER}" \
        | python3 -c "
import sys, json
try:
    items = json.load(sys.stdin)
    files = {i['name']: i.get('size', 0) for i in items if i['type'] == 'file'}
    tar  = '✓ ' + str(round(files.get('cnpg-snapshot.tar', 0)/(1024*1024), 0)).rstrip('0').rstrip('.') + ' MB' if 'cnpg-snapshot.tar' in files else '✗ missing'
    cfg  = '✓ ' + str(round(files.get('cnp-cluster-config.yaml', 0)/1024, 0)).rstrip('0').rstrip('.') + ' KB'  if 'cnp-cluster-config.yaml' in files else '✗ missing'
    bp   = '✓ ' + str(round(files.get('cnpg-db-blueprints.yaml', 0)/1024, 0)).rstrip('0').rstrip('.') + ' KB'  if 'cnpg-db-blueprints.yaml' in files else '✗ missing'
    print(tar + '|' + cfg + '|' + bp)
except Exception as e:
    print('error|error|error')
" 2>/dev/null)

    TAR_STATUS=$(echo "$FILES" | cut -d'|' -f1)
    CFG_STATUS=$(echo "$FILES" | cut -d'|' -f2)
    BP_STATUS=$(echo "$FILES"  | cut -d'|' -f3)

    if [[ "$TAR_STATUS" == ✓* ]]; then
        VALID_CLUSTERS+=("$FOLDER")
        NUM="${#VALID_CLUSTERS[@]}"
        printf "  ${BOLD}%-4s${RESET}  ${GREEN}%-20s${RESET}  %-16s  %-16s  %s\n" \
            "$NUM" "$FOLDER" "$TAR_STATUS" "$CFG_STATUS" "$BP_STATUS"
    else
        printf "  ${BOLD}%-4s${RESET}  ${YELLOW}%-20s${RESET}  %-16s  %-16s  %s ${RED}(incomplete — skipped)${RESET}\n" \
            "-" "$FOLDER" "$TAR_STATUS" "$CFG_STATUS" "$BP_STATUS"
    fi
done
echo ""

if [[ ${#VALID_CLUSTERS[@]} -eq 0 ]]; then
    error "No valid cluster backups found (missing cnpg-snapshot.tar)."
    exit 1
fi

# ── Pick cluster ──────────────────────────────────────────────────────────────
while true; do
    read -rp "$(echo -e "${BOLD}Select cluster to restore [1-${#VALID_CLUSTERS[@]}]: ${RESET}")" PICK
    if [[ "$PICK" =~ ^[0-9]+$ ]] && (( PICK >= 1 && PICK <= ${#VALID_CLUSTERS[@]} )); then
        CLUSTER_NAME="${VALID_CLUSTERS[$((PICK-1))]}"
        break
    fi
    warn "Invalid. Enter a number between 1 and ${#VALID_CLUSTERS[@]}."
done

GIT_REPO="https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git"

echo ""
success "Selected cluster: ${BOLD}${CLUSTER_NAME}${RESET}"
info "Artifacts will be pulled from: ${GIT_REPO}"

# ── Step 3: CNPG version ──────────────────────────────────────────────────────
header "Step 3 · CNPG operator version"

echo -e "${CYAN}Tip:${RESET} Find your version by running on the source machine:"
echo -e "  kubectl get pods -n cnpg-system --context kind-${CLUSTER_NAME} \\"
echo -e "    -o jsonpath='{range .items[*]}{.spec.containers[*].image}{\"\n\"}{end}'"
echo ""

while true; do
    read -rp "$(echo -e "${BOLD}CNPG operator version to install (e.g. 1.29.1): ${RESET}")" CNPG_VERSION
    if [[ "$CNPG_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
    fi
    warn "Format must be X.Y.Z (e.g. 1.29.1). Try again."
done

# ── Step 4: Confirm ───────────────────────────────────────────────────────────
header "Step 4 · Confirm restore"

echo -e "  Cluster to restore : ${BOLD}${CLUSTER_NAME}${RESET}"
echo -e "  Source repo        : ${BOLD}${GITHUB_USER}/${GITHUB_REPO}${RESET}"
echo -e "  CNPG version       : ${BOLD}${CNPG_VERSION}${RESET}"
echo -e "  kind context       : ${BOLD}kind-${CLUSTER_NAME}${RESET}"
echo ""

# Check if a kind cluster with this name already exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    warn "A kind cluster named '${CLUSTER_NAME}' already exists on this machine!"
    echo ""
    echo -e "  Options:"
    echo -e "    ${BOLD}1${RESET}  Delete it and restore fresh"
    echo -e "    ${BOLD}2${RESET}  Abort and keep existing cluster"
    echo ""
    read -rp "$(echo -e "${YELLOW}Choose [1/2]: ${RESET}")" CONFLICT_CHOICE
    case "$CONFLICT_CHOICE" in
        1)
            info "Deleting existing kind cluster '${CLUSTER_NAME}'..."
            kind delete cluster --name "${CLUSTER_NAME}"
            success "Deleted."
            ;;
        *)
            info "Aborted. Existing cluster preserved."
            exit 0
            ;;
    esac
fi

read -rp "$(echo -e "${YELLOW}Start restore? [Y/n]: ${RESET}")" GO
GO="${GO:-Y}"
[[ "$GO" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

# ── Step 5: Install prerequisites ─────────────────────────────────────────────
header "Step 5 · Install prerequisites (cnpg_prereqs.sh)"

PREREQS_URL="https://raw.githubusercontent.com/erswapnil/Kind-Cluster-Backup-and-restore/main/cnpg_prereqs.sh"

info "Downloading cnpg_prereqs.sh..."
curl -fsSL "${PREREQS_URL}" -o cnpg_prereqs.sh && chmod +x cnpg_prereqs.sh
success "Downloaded."

divider
./cnpg_prereqs.sh
divider
success "Prerequisites installed."

# ── Step 6: Download restore script ───────────────────────────────────────────
header "Step 6 · Prepare cnpg_restore.sh"

RESTORE_URL="https://raw.githubusercontent.com/erswapnil/Kind-Cluster-Backup-and-restore/main/cnpg_restore.sh"

if [[ ! -f "cnpg_restore.sh" ]]; then
    info "Downloading cnpg_restore.sh..."
    curl -fsSL "${RESTORE_URL}" -o cnpg_restore.sh
fi
chmod +x cnpg_restore.sh
success "cnpg_restore.sh is ready."

# ── Step 7: Run restore ───────────────────────────────────────────────────────
header "Step 7 · Restore cluster '${CLUSTER_NAME}'"

# Build the authenticated repo URL for restore script
AUTH_REPO_URL="https://${LOGIN}:${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${GITHUB_REPO}.git"

info "Running: ./cnpg_restore.sh --git-repo <repo> --cluster-name ${CLUSTER_NAME} --cnpg-version ${CNPG_VERSION}"
divider
if ./cnpg_restore.sh \
    --git-repo     "${AUTH_REPO_URL}" \
    --cluster-name "${CLUSTER_NAME}" \
    --cnpg-version "${CNPG_VERSION}"; then
    divider
    success "Cluster restored."
else
    divider
    error "Restore script failed."
    echo ""
    echo "  Common causes:"
    echo "  • Snapshot tar not found — check ${CLUSTER_NAME}/ folder in the repo"
    echo "  • Cluster name conflict  — try option 1 (delete) when prompted above"
    echo "  • Worker node mismatch   — edit cnpg_restore.sh to match source cluster"
    exit 1
fi

# ── Step 8: Install CNPG operator at exact version ────────────────────────────
header "Step 8 · Install CNPG operator v${CNPG_VERSION}"

install_cnpg_operator "${CNPG_VERSION}" "${CLUSTER_NAME}"

# ── Step 9: Verify ────────────────────────────────────────────────────────────
header "Step 9 · Verify cluster health (cnpg_verify.sh)"

VERIFY_URL="https://raw.githubusercontent.com/erswapnil/Kind-Cluster-Backup-and-restore/main/cnpg_verify.sh"

if [[ ! -f "cnpg_verify.sh" ]]; then
    info "Downloading cnpg_verify.sh..."
    curl -fsSL "${VERIFY_URL}" -o cnpg_verify.sh
fi
chmod +x cnpg_verify.sh

divider
if ./cnpg_verify.sh --cluster-name "${CLUSTER_NAME}"; then
    divider
    success "Cluster '${CLUSTER_NAME}' is healthy."
else
    divider
    warn "Verify reported issues. If pods are in PodInitializing, wait 5–10 minutes and re-run:"
    echo ""
    echo "  ./cnpg_verify.sh --cluster-name ${CLUSTER_NAME}"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║  ✅  Restore complete!                                       ║${RESET}"
echo -e "${BOLD}${GREEN}║                                                              ║${RESET}"
echo -e "${BOLD}${GREEN}║  Cluster  : ${CLUSTER_NAME}$(printf '%*s' $((44 - ${#CLUSTER_NAME})) '')║${RESET}"
echo -e "${BOLD}${GREEN}║  Operator : CNPG v${CNPG_VERSION}$(printf '%*s' $((43 - ${#CNPG_VERSION})) '')║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  kubectl context: ${CYAN}kind-${CLUSTER_NAME}${RESET}"
echo -e "  Check pods    : ${CYAN}kubectl get pods -A --context kind-${CLUSTER_NAME}${RESET}"
echo ""
