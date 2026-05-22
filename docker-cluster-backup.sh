#!/usr/bin/env bash
# =============================================================================
# docker-cluster-backup.sh
# Backs up any kind cluster and uploads all artifacts to GitHub automatically.
#
# Compatible with macOS default bash 3.2+
#
# What it asks you:
#   1. Which cluster to back up  (shows live Docker list, you pick by number)
#   2. GitHub username
#   3. GitHub PAT (hidden input)
#   4. GitHub repo name
#
# What it does automatically:
#   - docker commit + save  → <cluster>-snapshot.tar  (Git LFS)
#   - kubectl export        → cnp-cluster-config.yaml
#   - kubectl export CNPG   → cnpg-db-blueprints.yaml
#   - Creates <cluster>/ folder in GitHub and uploads all three files
#
# Usage:
#   chmod +x docker-cluster-backup.sh && ./docker-cluster-backup.sh
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

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║        Kind Cluster → GitHub Backup Tool             ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""

# ── Pre-flight ────────────────────────────────────────────────────────────────
for cmd in docker kubectl git python3 curl; do
    command -v "$cmd" &>/dev/null || { error "$cmd not found. Install it and retry."; exit 1; }
done
docker info &>/dev/null 2>&1 || { error "Docker is not running. Start Docker Desktop first."; exit 1; }
git lfs version &>/dev/null || { error "git-lfs not found. Run: brew install git-lfs && git lfs install"; exit 1; }

# ── Step 1: Show available kind clusters from Docker ─────────────────────────
header "Step 1 · Select a cluster to back up"

echo -e "Scanning Docker for kind control-plane containers...\n"

# Use tab as separator (macOS bash 3.2 compatible — no mapfile, no ||| regex issues)
CONTAINER_IDS=()
CONTAINER_NAMES=()
CLUSTER_NAMES=()
CONTAINER_STATUS=()

while IFS=$'\t' read -r cid cname cluster; do
    case "$cname" in
        *-control-plane)
            CONTAINER_IDS+=("$cid")
            CONTAINER_NAMES+=("$cname")
            CLUSTER_NAMES+=("$cluster")
            ;;
    esac
done < <(docker ps -a --format $'{{.ID}}\t{{.Names}}\t{{.Label "io.x-k8s.kind.cluster"}}')

# Get status separately (avoid multi-field join issues)
while IFS=$'\t' read -r cid cname status; do
    case "$cname" in
        *-control-plane)
            CONTAINER_STATUS+=("$status")
            ;;
    esac
done < <(docker ps -a --format $'{{.ID}}\t{{.Names}}\t{{.Status}}')

if [[ ${#CONTAINER_IDS[@]} -eq 0 ]]; then
    error "No kind control-plane containers found. Is any kind cluster running?"
    exit 1
fi

# Print table header
printf "  ${BOLD}%-4s  %-14s  %-36s  %-16s  %s${RESET}\n" \
    "#" "CONTAINER ID" "CONTAINER NAME" "CLUSTER" "STATUS"
divider

for i in "${!CONTAINER_IDS[@]}"; do
    STATUS="${CONTAINER_STATUS[$i]:-unknown}"
    if [[ "$STATUS" == Up* ]]; then
        STATUS_COL="${GREEN}${STATUS}${RESET}"
    else
        STATUS_COL="${YELLOW}${STATUS}${RESET}"
    fi
    printf "  ${BOLD}%-4s${RESET}  %-14s  %-36s  %-16s  " \
        "$((i+1))" "${CONTAINER_IDS[$i]}" "${CONTAINER_NAMES[$i]}" "${CLUSTER_NAMES[$i]}"
    echo -e "${STATUS_COL}"
done
echo ""

# Pick cluster
COUNT="${#CONTAINER_IDS[@]}"
while true; do
    read -rp "$(echo -e "${BOLD}Enter number to select cluster [1-${COUNT}]: ${RESET}")" PICK
    if [[ "$PICK" =~ ^[0-9]+$ ]] && [ "$PICK" -ge 1 ] && [ "$PICK" -le "$COUNT" ]; then
        IDX=$((PICK - 1))
        break
    fi
    warn "Invalid. Enter a number between 1 and ${COUNT}."
done

CONTAINER_ID="${CONTAINER_IDS[$IDX]}"
CLUSTER_NAME="${CLUSTER_NAMES[$IDX]}"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"

echo ""
echo -e "  Selected cluster : ${BOLD}${CLUSTER_NAME}${RESET}"
echo -e "  Container ID     : ${BOLD}${CONTAINER_ID}${RESET}"
echo -e "  kubectl context  : ${BOLD}${KUBE_CONTEXT}${RESET}"
echo ""

# Verify kubectl context exists
if ! kubectl config get-contexts "${KUBE_CONTEXT}" &>/dev/null; then
    warn "kubectl context '${KUBE_CONTEXT}' not found. Available contexts:"
    kubectl config get-contexts | sed 's/^/  /'
    read -rp "$(echo -e "${YELLOW}Enter the correct context name: ${RESET}")" KUBE_CONTEXT
fi

# ── Step 2: GitHub credentials ────────────────────────────────────────────────
header "Step 2 · GitHub credentials"

read -rp "$(echo -e "${BOLD}GitHub username: ${RESET}")" GITHUB_USER

echo -e "${YELLOW}GitHub Personal Access Token (input hidden — needs 'repo' scope):${RESET}"
echo -e "  Create one at: ${CYAN}https://github.com/settings/tokens${RESET}"
echo ""
read -rsp "$(echo -e "${BOLD}GitHub PAT: ${RESET}")" GITHUB_TOKEN
echo ""

read -rp "$(echo -e "${BOLD}GitHub repo name (e.g. Kind-Cluster-Backup-and-restore): ${RESET}")" GITHUB_REPO

echo ""
info "Verifying GitHub credentials..."
LOGIN=$(curl -s \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/user" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('login','ERROR'))" 2>/dev/null)

if [[ "$LOGIN" == "ERROR" || -z "$LOGIN" ]]; then
    error "Token is invalid or expired."; exit 1
fi
success "Authenticated as: ${LOGIN}"

# Verify repo exists
REPO_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}")

if [[ "$REPO_CHECK" != "200" ]]; then
    error "Repo '${GITHUB_USER}/${GITHUB_REPO}' not found (HTTP ${REPO_CHECK})."; exit 1
fi
success "Repo ${GITHUB_USER}/${GITHUB_REPO} is accessible."

# Check if cluster folder already exists
FOLDER_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}/contents/${CLUSTER_NAME}")

if [[ "$FOLDER_CHECK" == "200" ]]; then
    echo ""
    warn "A folder named '${CLUSTER_NAME}/' already exists in the repo."
    read -rp "$(echo -e "${YELLOW}Overwrite existing files? [Y/n]: ${RESET}")" OVERWRITE
    OVERWRITE="${OVERWRITE:-Y}"
    if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
        info "Aborted."; exit 0
    fi
fi

# ── Step 3: Confirm and start ─────────────────────────────────────────────────
header "Step 3 · Confirm"

echo -e "  Cluster to back up : ${BOLD}${CLUSTER_NAME}${RESET}  (container: ${CONTAINER_ID})"
echo -e "  kubectl context    : ${BOLD}${KUBE_CONTEXT}${RESET}"
echo -e "  GitHub target      : ${BOLD}${GITHUB_USER}/${GITHUB_REPO}/${CLUSTER_NAME}/${RESET}"
echo ""
read -rp "$(echo -e "${YELLOW}Start backup? [Y/n]: ${RESET}")" GO
GO="${GO:-Y}"
[[ "$GO" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

# ── Working dir ───────────────────────────────────────────────────────────────
WORK_DIR="$(mktemp -d /tmp/kind-backup-XXXXXX)"
info "Working directory: ${WORK_DIR}"
TAR_FILE="${CLUSTER_NAME}-snapshot.tar"
CONFIG_FILE="cnp-cluster-config.yaml"
BLUEPRINTS_FILE="cnpg-db-blueprints.yaml"

# ── Step 4: docker commit + save ─────────────────────────────────────────────
header "Step 4 · Snapshot control plane"

info "Committing container ${CONTAINER_ID} → ${CLUSTER_NAME}-snapshot:v1 ..."
docker commit "${CONTAINER_ID}" "${CLUSTER_NAME}-snapshot:v1"
success "Image committed."

info "Saving image → ${TAR_FILE} (may take a few minutes)..."
docker save -o "${WORK_DIR}/${TAR_FILE}" "${CLUSTER_NAME}-snapshot:v1"
TAR_SIZE=$(du -sh "${WORK_DIR}/${TAR_FILE}" | cut -f1)
success "Saved: ${TAR_FILE} (${TAR_SIZE})"

# ── Step 5: Export K8s resources ─────────────────────────────────────────────
header "Step 5 · Export Kubernetes resources"

info "Exporting all K8s resources → ${CONFIG_FILE} ..."
kubectl --context "${KUBE_CONTEXT}" \
    get all,configmaps,secrets,storageclasses \
    --all-namespaces -o yaml > "${WORK_DIR}/${CONFIG_FILE}"
CONFIG_SIZE=$(du -sh "${WORK_DIR}/${CONFIG_FILE}" | cut -f1)
success "Exported: ${CONFIG_FILE} (${CONFIG_SIZE})"

# ── Step 6: Export CNPG blueprints ────────────────────────────────────────────
header "Step 6 · Export CNPG database blueprints"

info "Exporting CNPG clusters + poolers → ${BLUEPRINTS_FILE} ..."
if kubectl --context "${KUBE_CONTEXT}" \
    get clusters.postgresql.cnpg.io,poolers.postgresql.cnpg.io \
    --all-namespaces -o yaml > "${WORK_DIR}/${BLUEPRINTS_FILE}" 2>/dev/null; then
    BP_SIZE=$(du -sh "${WORK_DIR}/${BLUEPRINTS_FILE}" | cut -f1)
    success "Exported: ${BLUEPRINTS_FILE} (${BP_SIZE})"
else
    warn "No CNPG CRDs found — writing placeholder."
    echo "# No CNPG clusters found in context ${KUBE_CONTEXT}" > "${WORK_DIR}/${BLUEPRINTS_FILE}"
    BP_SIZE="tiny"
fi

# ── Step 7: Clone repo and push via Git LFS ───────────────────────────────────
header "Step 7 · Upload to GitHub (${GITHUB_USER}/${GITHUB_REPO}/${CLUSTER_NAME}/)"

REPO_DIR="${WORK_DIR}/repo"
REPO_URL="https://${LOGIN}:${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${GITHUB_REPO}.git"

info "Cloning repo..."
git clone --depth 1 "${REPO_URL}" "${REPO_DIR}"
cd "${REPO_DIR}"

git config user.name  "${LOGIN}"
git config user.email "${LOGIN}@users.noreply.github.com"
git config http.postBuffer 1073741824

# LFS setup
git lfs install
git lfs track "*.tar"
git add .gitattributes 2>/dev/null || true
success "Git LFS configured."

# Create cluster subfolder and copy files
mkdir -p "${REPO_DIR}/${CLUSTER_NAME}"
info "Copying artifacts into ${CLUSTER_NAME}/ ..."
cp "${WORK_DIR}/${TAR_FILE}"        "${REPO_DIR}/${CLUSTER_NAME}/cnpg-snapshot.tar"
cp "${WORK_DIR}/${CONFIG_FILE}"     "${REPO_DIR}/${CLUSTER_NAME}/cnp-cluster-config.yaml"
cp "${WORK_DIR}/${BLUEPRINTS_FILE}" "${REPO_DIR}/${CLUSTER_NAME}/cnpg-db-blueprints.yaml"
success "Files staged in ${CLUSTER_NAME}/."

git add "${CLUSTER_NAME}/"

info "Committing..."
git commit -m "Add ${CLUSTER_NAME} cluster artifacts (snapshot + K8s config + CNPG blueprints)"

info "Pushing to GitHub — LFS will upload the tar separately (this may take a few minutes)..."
git push origin main

# ── Done ──────────────────────────────────────────────────────────────────────
cd /tmp
rm -rf "${WORK_DIR}"

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║  ✅  Backup complete!                                        ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  📁 ${CYAN}https://github.com/${GITHUB_USER}/${GITHUB_REPO}/tree/main/${CLUSTER_NAME}${RESET}"
echo ""
echo -e "  ${BOLD}Files uploaded:${RESET}"
echo -e "    ${GREEN}✓${RESET}  ${CLUSTER_NAME}/cnpg-snapshot.tar          ${YELLOW}(${TAR_SIZE} — via Git LFS)${RESET}"
echo -e "    ${GREEN}✓${RESET}  ${CLUSTER_NAME}/cnp-cluster-config.yaml    (${CONFIG_SIZE})"
echo -e "    ${GREEN}✓${RESET}  ${CLUSTER_NAME}/cnpg-db-blueprints.yaml    (${BP_SIZE})"
echo ""
echo -e "  ${BOLD}To restore this cluster on another machine:${RESET}"
echo -e "  ${YELLOW}curl -fsSL https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/main/docker-cluster-restore.sh \\${RESET}"
echo -e "  ${YELLOW}  -o docker-cluster-restore.sh && chmod +x docker-cluster-restore.sh && ./docker-cluster-restore.sh${RESET}"
echo ""
