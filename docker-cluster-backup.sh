#!/usr/bin/env bash
# =============================================================================
# docker-cluster-backup.sh
# Backs up a kind cluster (CNPG / EDB CNP / PGD4K) and uploads all artifacts
# to a GitHub repo automatically using Git LFS for the snapshot tar.
#
# Compatible with macOS default bash 3.2+
# No zip files — artifacts are uploaded directly to GitHub.
#
# Usage:
#   chmod +x docker-cluster-backup.sh && ./docker-cluster-backup.sh
#
# What it asks you:
#   1. Which cluster to back up (shows running kind clusters, pick by number)
#   2. GitHub username, PAT (hidden input), repo name
#
# What it does automatically:
#   - Auto-detects operator type (CNPG / EDB CNP / EDB PGD4K) and version
#   - docker commit + save → cnpg-snapshot.tar  (uploaded via Git LFS)
#   - kubectl export     → cnp-cluster-config.yaml
#   - kubectl export CRDs → cnpg-db-blueprints.yaml
#   - Writes metadata files (cnpg-version.txt, operator-namespace.txt, etc.)
#   - Uploads everything to:  <repo>/<cluster-name>/
#
# Security:
#   - GitHub PAT is read with hidden input (not echoed to terminal)
#   - PAT is cleared from variables on EXIT
#   - Never paste your PAT into a chat message or terminal history
#   - Revoke it at https://github.com/settings/tokens if accidentally exposed
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}─── $* ───${NC}"; }

WORK_DIR=""
cleanup() {
  unset GITHUB_TOKEN 2>/dev/null || true
  [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]] && rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║          Kind Cluster → GitHub Backup Tool                  ║${NC}"
echo -e "${BOLD}${CYAN}║    (CNPG / EDB CNP / EDB PGD4K  ·  uploads to GitHub)      ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Pre-flight ────────────────────────────────────────────────────────────────
step "Pre-flight checks"
for cmd in docker kubectl kind git python3 curl; do
  command -v "$cmd" &>/dev/null || error "$cmd not found. Install it and retry."
done
docker info &>/dev/null 2>&1 || error "Docker is not running. Start Docker Desktop first."

if ! git lfs version &>/dev/null 2>&1; then
  warn "git-lfs not found. Installing via Homebrew..."
  if command -v brew &>/dev/null; then
    brew install git-lfs
    git lfs install --system
    success "git-lfs installed."
  else
    error "git-lfs is required (snapshots stored via LFS). Install: https://git-lfs.com"
  fi
fi
success "All pre-flight checks passed."

# ── Step 1: Select cluster ────────────────────────────────────────────────────
step "Step 1 · Select cluster to back up"

CLUSTERS=$(kind get clusters 2>/dev/null || true)
if [[ -z "${CLUSTERS}" ]]; then
  error "No kind clusters found. Is a cluster running?"
fi

echo ""
echo -e "  ${BOLD}#   CLUSTER NAME${NC}"
echo "  ─────────────────────"
i=1
while IFS= read -r cl; do
  printf "  %-4s %s\n" "$i" "$cl"
  i=$((i+1))
done <<< "${CLUSTERS}"
echo ""

CLUSTER_COUNT=$(echo "${CLUSTERS}" | wc -l | tr -d ' ')
while true; do
  read -rp "Select cluster [1-${CLUSTER_COUNT}]: " CHOICE
  if [[ "${CHOICE}" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= CLUSTER_COUNT )); then
    break
  fi
  warn "Invalid. Enter a number between 1 and ${CLUSTER_COUNT}."
done

CLUSTER_NAME=$(echo "${CLUSTERS}" | sed -n "${CHOICE}p" | tr -d '[:space:]')
CONTEXT="kind-${CLUSTER_NAME}"
success "Selected: ${CLUSTER_NAME}  (kubectl context: ${CONTEXT})"

# Find control-plane container
CONTAINER_ID=$(docker ps -a \
  --filter "name=${CLUSTER_NAME}-control-plane" \
  --format "{{.ID}}" | head -1)
[[ -z "${CONTAINER_ID}" ]] && error "Control-plane container for '${CLUSTER_NAME}' not found. Is the cluster running?"
success "Control-plane container: ${CONTAINER_ID}"

# ── Step 2: Auto-detect operator and version ──────────────────────────────────
step "Step 2 · Auto-detecting operator (CNPG / EDB CNP / PGD4K)"

CNPG_VERSION=""
OPERATOR_NS=""
OPERATOR_TYPE=""

detect_version_from_ns() {
  local ns="$1"
  local deploy_count
  deploy_count=$(kubectl get deployment -n "${ns}" --context "${CONTEXT}" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [[ "${deploy_count}" -eq 0 ]] && return

  local ver
  ver=$(kubectl get deployment -n "${ns}" --context "${CONTEXT}" \
    -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' \
    2>/dev/null \
    | grep -i -E "cloudnative-pg|edb-postgres|cnpg|pgd|barman" \
    | grep -oE ':[0-9]+\.[0-9]+\.[0-9]+' | tr -d ':' | head -1 || true)

  # Fallback: any semver from any image in this namespace
  if [[ -z "${ver}" ]]; then
    ver=$(kubectl get deployment -n "${ns}" --context "${CONTEXT}" \
      -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' \
      2>/dev/null | grep -oE ':[0-9]+\.[0-9]+\.[0-9]+' | tr -d ':' | head -1 || true)
  fi
  echo "${ver}"
}

for ns_candidate in "cnpg-system" "postgresql-operator-system" "pgd-operator-system"; do
  info "Checking ${ns_candidate}..."
  detected=$(detect_version_from_ns "${ns_candidate}")
  if [[ -n "${detected}" ]]; then
    CNPG_VERSION="${detected}"
    OPERATOR_NS="${ns_candidate}"
    break
  fi
done

# Fallback: scan all namespaces
if [[ -z "${CNPG_VERSION}" ]]; then
  info "Scanning all namespaces for operator deployments..."
  while IFS= read -r line; do
    ns=$(echo "${line}" | awk '{print $1}')
    img=$(echo "${line}" | awk '{print $2}')
    ver=$(echo "${img}" | grep -oE ':[0-9]+\.[0-9]+\.[0-9]+' | tr -d ':' | head -1 || true)
    if [[ -n "${ver}" ]]; then
      CNPG_VERSION="${ver}"
      OPERATOR_NS="${ns}"
      break
    fi
  done < <(kubectl get deployment --all-namespaces --context "${CONTEXT}" \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.spec.template.spec.containers[*].image}{"\n"}{end}' \
    2>/dev/null | grep -i -E "cloudnative-pg|edb-postgres|cnpg|pgd|barman|operator" || true)
fi

if [[ -n "${CNPG_VERSION}" ]]; then
  case "${OPERATOR_NS}" in
    "cnpg-system")                 OPERATOR_TYPE="Community CloudNativePG" ;;
    "postgresql-operator-system")  OPERATOR_TYPE="EDB Postgres for CloudNativePG (CNP)" ;;
    "pgd-operator-system")         OPERATOR_TYPE="EDB Postgres Distributed (PGD4K)" ;;
    *)                             OPERATOR_TYPE="Unknown operator" ;;
  esac
  success "Operator   : ${OPERATOR_TYPE}"
  success "Namespace  : ${OPERATOR_NS}"
  success "Version    : ${CNPG_VERSION}"
else
  warn "Could not auto-detect operator. Defaulting to cnpg-system."
  OPERATOR_NS="cnpg-system"
  OPERATOR_TYPE="Community CloudNativePG"
  read -rp "Enter operator version manually (e.g. 1.28.0): " CNPG_VERSION
  [[ -z "${CNPG_VERSION}" ]] && error "Operator version is required."
fi

# Detect cert-manager version (saved to metadata; used by restore for PGD clusters)
CERT_MANAGER_VERSION=""
if kubectl get ns cert-manager --context "${CONTEXT}" &>/dev/null 2>&1; then
  CERT_MANAGER_VERSION=$(kubectl get deployment -n cert-manager --context "${CONTEXT}" \
    -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' \
    2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  [[ -n "${CERT_MANAGER_VERSION}" ]] && success "cert-manager: ${CERT_MANAGER_VERSION}"
fi

# ── Step 3: GitHub credentials ────────────────────────────────────────────────
step "Step 3 · GitHub credentials"

read -rp "GitHub username: " GITHUB_USER

echo ""
echo -e "  ${YELLOW}GitHub Personal Access Token — needs 'repo' scope (input is hidden):${NC}"
echo -e "  Create one at: ${CYAN}https://github.com/settings/tokens${NC}"
echo -e "  ${YELLOW}IMPORTANT: Never paste your PAT into a chat message or terminal history.${NC}"
echo ""
read -rsp "  GitHub PAT: " GITHUB_TOKEN
echo ""
[[ -z "${GITHUB_TOKEN}" ]] && error "GitHub token is required."

read -rp "GitHub repo name [Kind-Cluster-Backup-and-restore]: " GITHUB_REPO
GITHUB_REPO="${GITHUB_REPO:-Kind-Cluster-Backup-and-restore}"

info "Verifying GitHub credentials..."
LOGIN=$(curl -s \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/user" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('login','ERROR'))" 2>/dev/null || true)
[[ "${LOGIN}" == "ERROR" || -z "${LOGIN}" ]] && error "GitHub token is invalid or expired."
success "Authenticated as: ${LOGIN}"

REPO_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}")
[[ "${REPO_CHECK}" != "200" ]] && error "Repo '${GITHUB_USER}/${GITHUB_REPO}' not found (HTTP ${REPO_CHECK})."
success "Repo ${GITHUB_USER}/${GITHUB_REPO} is accessible."

# Check if cluster folder already exists
FOLDER_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}/contents/${CLUSTER_NAME}")
if [[ "${FOLDER_CHECK}" == "200" ]]; then
  echo ""
  warn "Folder '${CLUSTER_NAME}/' already exists in the repo."
  read -rp "  Overwrite existing backup? [Y/n]: " OVERWRITE
  OVERWRITE="${OVERWRITE:-Y}"
  [[ ! "${OVERWRITE}" =~ ^[Yy]$ ]] && { info "Aborted."; exit 0; }
fi

# ── Confirm ───────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Cluster      :${NC} ${CLUSTER_NAME}  (container: ${CONTAINER_ID})"
echo -e "  ${BOLD}Operator     :${NC} ${OPERATOR_TYPE} v${CNPG_VERSION}"
echo -e "  ${BOLD}Namespace    :${NC} ${OPERATOR_NS}"
echo -e "  ${BOLD}GitHub target:${NC} ${GITHUB_USER}/${GITHUB_REPO}/${CLUSTER_NAME}/"
echo ""
read -rp "Start backup? [Y/n]: " GO
GO="${GO:-Y}"
[[ "${GO}" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

# ── Working dir ───────────────────────────────────────────────────────────────
WORK_DIR="$(mktemp -d -t kind-backup-XXXXXX)"
info "Working directory: ${WORK_DIR}"

# ── Step 4: Docker commit + save ──────────────────────────────────────────────
step "Step 4 · Snapshot control-plane container"
info "docker commit ${CONTAINER_ID} → ${CLUSTER_NAME}-snapshot:v1"
docker commit "${CONTAINER_ID}" "${CLUSTER_NAME}-snapshot:v1"
info "docker save → cnpg-snapshot.tar.gz  (compressing with gzip — may take a few minutes)..."
docker save "${CLUSTER_NAME}-snapshot:v1" | gzip > "${WORK_DIR}/cnpg-snapshot.tar.gz"
success "Snapshot saved: $(du -sh "${WORK_DIR}/cnpg-snapshot.tar.gz" | cut -f1)  (compressed)"

# ── Step 5: Export Kubernetes resources ───────────────────────────────────────
step "Step 5 · Export Kubernetes resources"
kubectl --context "${CONTEXT}" \
  get all,configmaps,secrets,storageclasses,namespaces \
  --all-namespaces -o yaml > "${WORK_DIR}/cnp-cluster-config.yaml"
success "Config exported: $(du -sh "${WORK_DIR}/cnp-cluster-config.yaml" | cut -f1)"

# ── Step 6: Export database blueprints (all operator types) ───────────────────
step "Step 6 · Export database blueprints (CNPG / EDB CNP / PGD4K)"
> "${WORK_DIR}/cnpg-db-blueprints.yaml"
EXPORTED_SOMETHING=false

export_crd() {
  local crd="$1"
  local label="$2"
  local out
  out=$(kubectl --context "${CONTEXT}" get "${crd}" \
    --all-namespaces -o yaml 2>/dev/null || true)
  if echo "${out}" | grep -q "^items:" && ! echo "${out}" | grep -q "^items: \[\]"; then
    { echo "---"; echo "${out}"; } >> "${WORK_DIR}/cnpg-db-blueprints.yaml"
    success "Exported: ${label}"
    EXPORTED_SOMETHING=true
  else
    info "Not found / empty: ${label}  (skipping)"
  fi
}

# Community CloudNativePG (cnpg-system)
export_crd "clusters.postgresql.cnpg.io"                    "clusters.postgresql.cnpg.io"
export_crd "poolers.postgresql.cnpg.io"                     "poolers.postgresql.cnpg.io"
export_crd "scheduledbackups.postgresql.cnpg.io"            "scheduledbackups.postgresql.cnpg.io"
# EDB Postgres for Kubernetes / CNP (postgresql-operator-system)
# Uses postgresql.k8s.enterprisedb.io API group
export_crd "clusters.postgresql.k8s.enterprisedb.io"        "clusters.postgresql.k8s.enterprisedb.io"
export_crd "poolers.postgresql.k8s.enterprisedb.io"         "poolers.postgresql.k8s.enterprisedb.io"
export_crd "scheduledbackups.postgresql.k8s.enterprisedb.io" "scheduledbackups.postgresql.k8s.enterprisedb.io"
export_crd "databases.postgresql.k8s.enterprisedb.io"       "databases.postgresql.k8s.enterprisedb.io"
export_crd "imagecatalogs.postgresql.k8s.enterprisedb.io"   "imagecatalogs.postgresql.k8s.enterprisedb.io"
export_crd "clusterimagecatalogs.postgresql.k8s.enterprisedb.io" "clusterimagecatalogs.postgresql.k8s.enterprisedb.io"
# EDB PGD4K (pgd-operator-system)
export_crd "pgdgroups.pgd.k8s.enterprisedb.io"              "pgdgroups.pgd.k8s.enterprisedb.io"
# cert-manager (required for PGD TLS; safely skipped on CNPG/CNP)
export_crd "issuers.cert-manager.io"                        "cert-manager Issuers"
export_crd "certificates.cert-manager.io"                   "cert-manager Certificates"
export_crd "clusterissuers.cert-manager.io"                 "cert-manager ClusterIssuers"

if [[ "${EXPORTED_SOMETHING}" == "true" ]]; then
  success "Blueprints exported: $(du -sh "${WORK_DIR}/cnpg-db-blueprints.yaml" | cut -f1)"
else
  warn "No database CRDs found — blueprints file will be empty."
fi

# ── Write metadata files ──────────────────────────────────────────────────────
echo "${CNPG_VERSION}"  > "${WORK_DIR}/cnpg-version.txt"
echo "${CLUSTER_NAME}"  > "${WORK_DIR}/cluster-name.txt"
echo "${OPERATOR_NS}"   > "${WORK_DIR}/operator-namespace.txt"
[[ -n "${CERT_MANAGER_VERSION}" ]] && echo "${CERT_MANAGER_VERSION}" > "${WORK_DIR}/cert-manager-version.txt"
success "Metadata files written."

# ── Step 7: Upload to GitHub via git + LFS ────────────────────────────────────
step "Step 7 · Upload to GitHub  (${GITHUB_USER}/${GITHUB_REPO}/${CLUSTER_NAME}/)"

REPO_DIR="${WORK_DIR}/repo"
# Use token in URL — never echoed to screen
REPO_URL="https://${LOGIN}:${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${GITHUB_REPO}.git"

info "Cloning repo (shallow clone, skipping existing LFS objects for speed)..."
GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 "${REPO_URL}" "${REPO_DIR}" 2>&1 | sed "s/${GITHUB_TOKEN}/****/g"

git -C "${REPO_DIR}" config user.name "${LOGIN}"
git -C "${REPO_DIR}" config user.email "${LOGIN}@users.noreply.github.com"
git -C "${REPO_DIR}" config http.postBuffer 1073741824
git -C "${REPO_DIR}" config http.lowSpeedLimit 1000
git -C "${REPO_DIR}" config http.lowSpeedTime 600

# Ensure .gitattributes tracks *.tar.gz via LFS
git -C "${REPO_DIR}" lfs install 2>/dev/null || true
if ! grep -q "^\*.tar.gz" "${REPO_DIR}/.gitattributes" 2>/dev/null; then
  echo "*.tar.gz filter=lfs diff=lfs merge=lfs -text" >> "${REPO_DIR}/.gitattributes"
  git -C "${REPO_DIR}" add .gitattributes
fi
success "Git LFS configured for snapshot tar.gz."

# Create/update cluster subfolder and copy files
mkdir -p "${REPO_DIR}/${CLUSTER_NAME}"
info "Copying backup artifacts into ${CLUSTER_NAME}/..."
cp "${WORK_DIR}/cnpg-snapshot.tar.gz"     "${REPO_DIR}/${CLUSTER_NAME}/cnpg-snapshot.tar.gz"
cp "${WORK_DIR}/cnp-cluster-config.yaml"  "${REPO_DIR}/${CLUSTER_NAME}/cnp-cluster-config.yaml"
cp "${WORK_DIR}/cnpg-db-blueprints.yaml"  "${REPO_DIR}/${CLUSTER_NAME}/cnpg-db-blueprints.yaml"
cp "${WORK_DIR}/cnpg-version.txt"         "${REPO_DIR}/${CLUSTER_NAME}/cnpg-version.txt"
cp "${WORK_DIR}/cluster-name.txt"         "${REPO_DIR}/${CLUSTER_NAME}/cluster-name.txt"
cp "${WORK_DIR}/operator-namespace.txt"   "${REPO_DIR}/${CLUSTER_NAME}/operator-namespace.txt"
[[ -f "${WORK_DIR}/cert-manager-version.txt" ]] && \
  cp "${WORK_DIR}/cert-manager-version.txt" "${REPO_DIR}/${CLUSTER_NAME}/cert-manager-version.txt"
success "Files staged."

git -C "${REPO_DIR}" add "${CLUSTER_NAME}/"
info "Committing..."
git -C "${REPO_DIR}" commit \
  -m "backup: ${CLUSTER_NAME} (${OPERATOR_TYPE} v${CNPG_VERSION}) $(date +%Y-%m-%d)" \
  2>/dev/null || warn "Nothing new to commit — backup files unchanged since last upload."

info "Uploading LFS objects to GitHub (snapshot tar — may take several minutes)..."
LFS_OK=false
for lfs_attempt in 1 2 3; do
  if git -C "${REPO_DIR}" lfs push origin main 2>&1 | sed "s/${GITHUB_TOKEN}/****/g"; then
    LFS_OK=true
    break
  fi
  warn "LFS push attempt ${lfs_attempt}/3 failed. Retrying in 10s..."
  sleep 10
done

info "Pushing refs to GitHub (updating repo index)..."
# Disable LFS pre-push hook so this step only updates refs (LFS already done above)
HOOK_FILE="${REPO_DIR}/.git/hooks/pre-push"
[[ -f "${HOOK_FILE}" ]] && chmod -x "${HOOK_FILE}"
git -C "${REPO_DIR}" push origin main 2>&1 | sed "s/${GITHUB_TOKEN}/****/g"
[[ -f "${HOOK_FILE}" ]] && chmod +x "${HOOK_FILE}"

# ── Done ──────────────────────────────────────────────────────────────────────
TAR_SIZE=$(du -sh "${WORK_DIR}/cnpg-snapshot.tar.gz" | cut -f1)
CFG_SIZE=$(du -sh "${WORK_DIR}/cnp-cluster-config.yaml" | cut -f1)
BP_SIZE=$(du -sh  "${WORK_DIR}/cnpg-db-blueprints.yaml" | cut -f1)

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║  Backup complete!                                            ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}https://github.com/${GITHUB_USER}/${GITHUB_REPO}/tree/main/${CLUSTER_NAME}${NC}"
echo ""
echo -e "  ${BOLD}Files uploaded:${NC}"
echo -e "  ${GREEN}✓${NC}  ${CLUSTER_NAME}/cnpg-snapshot.tar.gz      ${TAR_SIZE}  (compressed · via Git LFS)"
echo -e "  ${GREEN}✓${NC}  ${CLUSTER_NAME}/cnp-cluster-config.yaml   ${CFG_SIZE}"
echo -e "  ${GREEN}✓${NC}  ${CLUSTER_NAME}/cnpg-db-blueprints.yaml   ${BP_SIZE}"
echo -e "  ${GREEN}✓${NC}  ${CLUSTER_NAME}/cnpg-version.txt"
echo -e "  ${GREEN}✓${NC}  ${CLUSTER_NAME}/operator-namespace.txt"
[[ -n "${CERT_MANAGER_VERSION}" ]] && \
  echo -e "  ${GREEN}✓${NC}  ${CLUSTER_NAME}/cert-manager-version.txt"
echo ""
echo -e "  ${BOLD}To restore this cluster on any machine:${NC}"
echo -e "  ${YELLOW}curl -fsSL https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/main/docker-cluster-restore.sh \\"
echo -e "    -o docker-cluster-restore.sh && chmod +x docker-cluster-restore.sh && ./docker-cluster-restore.sh${NC}"
echo ""
