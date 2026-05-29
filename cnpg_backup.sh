#!/usr/bin/env bash
# =============================================================================
# cnpg_backup.sh
# CloudNativePG (kind) Cluster Backup Script
#
# Repo structure created:
#   <git-repo>/
#   âââ cnpg_restore.sh               â restore script (already in repo)
#   âââ <cluster-name>/               â one subfolder per cluster
#   â   âââ cnpg-snapshot.tar         â Docker image snapshot (via Git LFS)
#   â   âââ cnp-cluster-config.yaml   â all K8s resources
#   â   âââ cnpg-db-blueprints.yaml   â DB CRD objects (Cluster / PGDGroup)
#   â   âââ cnpg-version.txt          â operator version
#   â   âââ operator-namespace.txt    â operator namespace
#   â   âââ cert-manager-version.txt  â cert-manager version (PGD only)
#
# Usage:
#   ./cnpg_backup.sh \
#     --git-repo     https://github.com/<username>/<repo>.git \
#     --cluster-name <kind-cluster-name> \
#     --git-branch   <branch>   (default: main)
#
# Examples:
#   ./cnpg_backup.sh --git-repo https://github.com/erswapnil/Kind-Cluster-Backup-and-restore.git \
#                    --cluster-name cnpg
#
#   ./cnpg_backup.sh --git-repo https://github.com/erswapnil/Kind-Cluster-Backup-and-restore.git \
#                    --cluster-name klio --git-branch main
# =============================================================================

set -euo pipefail

# âââ Colours ââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}âââ $* âââ${NC}"; }

# âââ Defaults âââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
GIT_REPO="${GIT_REPO:-https://github.com/erswapnil/Kind-Cluster-Backup-and-restore.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"
CLUSTER_NAME="${CLUSTER_NAME:-}"

# Artifact filenames (fixed â restore script expects exactly these names)
SNAPSHOT_TAR="cnpg-snapshot.tar"
CLUSTER_CONFIG_YAML="cnp-cluster-config.yaml"
DB_BLUEPRINTS_YAML="cnpg-db-blueprints.yaml"

# âââ Parse CLI arguments âââââââââââââââââââââââââââââââââââââââââââââââââââââââ
while [[ $# -gt 0 ]]; do
  case "$1" in
    --git-repo)     GIT_REPO="$2";     shift 2 ;;
    --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    --git-branch)   GIT_BRANCH="$2";   shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) error "Unknown argument: $1. Use --help for usage." ;;
  esac
done

# âââ Require cluster-name âââââââââââââââââââââââââââââââââââââââââââââââââââââ
if [[ -z "${CLUSTER_NAME}" ]]; then
  error "--cluster-name is required. Example: --cluster-name klio"
fi

# âââ PHASE 0: Pre-flight checks âââââââââââââââââââââââââââââââââââââââââââââââ
step "PHASE 0 â Pre-flight checks"

info "Checking for Docker binary..."
command -v docker &>/dev/null || error "Docker is not installed or not on PATH."
docker info &>/dev/null 2>&1  || error "Docker daemon is not running. Start Docker Desktop and retry."
success "Docker is up."

info "Checking for kind CLI..."
command -v kind &>/dev/null || error "'kind' CLI not found. Install it: brew install kind"
success "kind found: $(kind version)"

info "Checking for kubectl..."
command -v kubectl &>/dev/null || error "'kubectl' not found. Install it: brew install kubectl"
success "kubectl found."

info "Checking for git..."
command -v git &>/dev/null || error "'git' not found. Install it: brew install git"
success "git found: $(git --version)"

info "Checking for git-lfs..."
if ! command -v git-lfs &>/dev/null; then
  error "'git-lfs' not found. Install it:
  brew install git-lfs
  git lfs install"
fi
success "git-lfs found: $(git-lfs version)"

# âââ Verify kind cluster exists âââââââââââââââââââââââââââââââââââââââââââââââ
info "Checking kind cluster '${CLUSTER_NAME}' exists..."
if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  error "Kind cluster '${CLUSTER_NAME}' not found.
Available clusters: $(kind get clusters 2>/dev/null | tr '\n' ' ')"
fi
success "Kind cluster '${CLUSTER_NAME}' is present."

KUBE_CTX="kind-${CLUSTER_NAME}"

# âââ PHASE 1: Detect operator âââââââââââââââââââââââââââââââââââââââââââââââââ
step "PHASE 1 â Detect operator namespace and version"

# Auto-detect operator namespace
OPERATOR_NS=""
for ns_candidate in "pgd-operator-system" "postgresql-operator-system" "cnpg-system"; do
  if kubectl get namespace "${ns_candidate}" --context "${KUBE_CTX}" &>/dev/null 2>&1; then
    OPERATOR_NS="${ns_candidate}"
    success "Operator namespace detected: ${OPERATOR_NS}"
    break
  fi
done

if [[ -z "${OPERATOR_NS}" ]]; then
  warn "Could not auto-detect operator namespace."
  read -rp "Enter operator namespace (e.g. cnpg-system): " OPERATOR_NS
  [[ -z "${OPERATOR_NS}" ]] && error "Operator namespace is required."
fi

# Determine operator type and label
case "${OPERATOR_NS}" in
  "cnpg-system")                  OPERATOR_TYPE="Community CloudNativePG";        VERSION_LABEL="CNPG"  ;;
  "postgresql-operator-system")   OPERATOR_TYPE="EDB Postgres for CloudNativePG"; VERSION_LABEL="CNP"   ;;
  "pgd-operator-system")          OPERATOR_TYPE="EDB PGD4K";                      VERSION_LABEL="PGD4K" ;;
  *)                              OPERATOR_TYPE="Unknown operator";                VERSION_LABEL="Operator" ;;
esac
info "Operator type: ${OPERATOR_TYPE} (${VERSION_LABEL})"

# Auto-detect operator version from the running deployment image
CNPG_VERSION=""

# Try image tag from operator deployment
CNPG_VERSION=$(kubectl get deployment \
  -n "${OPERATOR_NS}" --context "${KUBE_CTX}" \
  -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}' \
  2>/dev/null \
  | grep -oE ':[0-9]+\.[0-9]+\.[0-9]+' | tr -d ':' | head -1 || true)

if [[ -z "${CNPG_VERSION}" ]]; then
  # Fallback: check all pods in operator namespace
  CNPG_VERSION=$(kubectl get pods -n "${OPERATOR_NS}" --context "${KUBE_CTX}" \
    -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
    2>/dev/null \
    | grep -oE ':[0-9]+\.[0-9]+\.[0-9]+' | tr -d ':' | head -1 || true)
fi

if [[ -z "${CNPG_VERSION}" ]]; then
  warn "Could not auto-detect operator version from running pods."
  read -rp "Enter operator version (e.g. 1.29.1): " CNPG_VERSION
  [[ -z "${CNPG_VERSION}" ]] && error "Operator version is required."
fi
success "Operator version: ${VERSION_LABEL} v${CNPG_VERSION}"

# Detect cert-manager version (written only for PGD clusters)
CERT_MANAGER_VERSION=""
if [[ "${OPERATOR_NS}" == "pgd-operator-system" ]]; then
  CERT_MANAGER_VERSION=$(kubectl get deployment \
    -n cert-manager --context "${KUBE_CTX}" \
    -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}' \
    2>/dev/null \
    | grep -oE ':[0-9]+\.[0-9]+\.[0-9]+' | tr -d ':' | head -1 || true)
  [[ -n "${CERT_MANAGER_VERSION}" ]] && success "cert-manager version: v${CERT_MANAGER_VERSION}" \
    || warn "cert-manager version not detected â will default to v1.16.2 during restore."
fi

# âââ PHASE 2: Export Kubernetes resources âââââââââââââââââââââââââââââââââââââ
step "PHASE 2 â Export Kubernetes resources"

WORK_DIR="$(mktemp -d -t cnpg-backup-XXXXXX)"
info "Working directory: ${WORK_DIR}"
trap 'info "Cleaning up working directory..."; rm -rf "${WORK_DIR}"' EXIT

ARTIFACTS_DIR="${WORK_DIR}/artifacts"
mkdir -p "${ARTIFACTS_DIR}"

info "Exporting all resources to ${CLUSTER_CONFIG_YAML}..."
kubectl get \
  --context "${KUBE_CTX}" \
  --all-namespaces \
  -o yaml \
  all,configmaps,secrets,storageclasses,namespaces,clusterroles,clusterrolebindings,serviceaccounts \
  > "${ARTIFACTS_DIR}/${CLUSTER_CONFIG_YAML}" 2>/dev/null \
  || warn "Some resource types may not have been exported (normal if not present)."
success "Cluster config exported: ${CLUSTER_CONFIG_YAML}"

info "Exporting database CRD objects to ${DB_BLUEPRINTS_YAML}..."
DB_EXPORTS=""

# Community CNPG / EDB CNP: Cluster CRD
if kubectl api-resources --context "${KUBE_CTX}" 2>/dev/null \
    | grep -q 'clusters.*postgresql.cnpg.io'; then
  kubectl get clusters.postgresql.cnpg.io \
    --context "${KUBE_CTX}" \
    --all-namespaces -o yaml >> "${ARTIFACTS_DIR}/${DB_BLUEPRINTS_YAML}" 2>/dev/null && DB_EXPORTS="clusters"
fi

# EDB PGD4K: PGDGroup CRD
if kubectl api-resources --context "${KUBE_CTX}" 2>/dev/null \
    | grep -q 'pgdgroups.*pgd.k8s.enterprisedb.io'; then
  kubectl get pgdgroups.pgd.k8s.enterprisedb.io \
    --context "${KUBE_CTX}" \
    --all-namespaces -o yaml >> "${ARTIFACTS_DIR}/${DB_BLUEPRINTS_YAML}" 2>/dev/null && DB_EXPORTS="${DB_EXPORTS} pgdgroups"
fi

# Barman object stores (if present)
if kubectl api-resources --context "${KUBE_CTX}" 2>/dev/null \
    | grep -q 'objectstores'; then
  kubectl get objectstores \
    --context "${KUBE_CTX}" \
    --all-namespaces -o yaml >> "${ARTIFACTS_DIR}/${DB_BLUEPRINTS_YAML}" 2>/dev/null || true
fi

if [[ ! -s "${ARTIFACTS_DIR}/${DB_BLUEPRINTS_YAML}" ]]; then
  echo "# No database CRD objects found" > "${ARTIFACTS_DIR}/${DB_BLUEPRINTS_YAML}"
  warn "No database CRD objects found (Cluster / PGDGroup). File created as placeholder."
else
  success "Database blueprints exported: ${DB_BLUEPRINTS_YAML} (${DB_EXPORTS})"
fi

# âââ PHASE 3: Snapshot Docker image âââââââââââââââââââââââââââââââââââââââââââ
step "PHASE 3 â Snapshot kind control-plane container"

CONTAINER_NAME="${CLUSTER_NAME}-control-plane"
info "Checking container '${CONTAINER_NAME}'..."
if ! docker inspect "${CONTAINER_NAME}" &>/dev/null; then
  error "Container '${CONTAINER_NAME}' not found. Is kind cluster '${CLUSTER_NAME}' running?"
fi

IMAGE_TAG="kind-snapshot/${CLUSTER_NAME}:$(date +%Y%m%d-%H%M%S)"
info "Committing container to image '${IMAGE_TAG}'..."
docker commit "${CONTAINER_NAME}" "${IMAGE_TAG}"
success "Image committed: ${IMAGE_TAG}"

info "Saving image to ${SNAPSHOT_TAR} (this may take a few minutes)..."
docker save "${IMAGE_TAG}" -o "${ARTIFACTS_DIR}/${SNAPSHOT_TAR}"
success "Snapshot saved: ${SNAPSHOT_TAR} ($(( $(wc -c < "${ARTIFACTS_DIR}/${SNAPSHOT_TAR}") / 1024 / 1024 )) MB)"

# Clean up local image after saving
docker rmi "${IMAGE_TAG}" &>/dev/null || true

# âââ PHASE 4: Write version/metadata files ââââââââââââââââââââââââââââââââââââ
step "PHASE 4 â Write metadata files"

echo "${CNPG_VERSION}" > "${ARTIFACTS_DIR}/cnpg-version.txt"
success "cnpg-version.txt: ${CNPG_VERSION}"

echo "${CLUSTER_NAME}" > "${ARTIFACTS_DIR}/cluster-name.txt"
success "cluster-name.txt: ${CLUSTER_NAME}"

echo "${OPERATOR_NS}" > "${ARTIFACTS_DIR}/operator-namespace.txt"
success "operator-namespace.txt: ${OPERATOR_NS}"

if [[ -n "${CERT_MANAGER_VERSION}" ]]; then
  echo "${CERT_MANAGER_VERSION}" > "${ARTIFACTS_DIR}/cert-manager-version.txt"
  success "cert-manager-version.txt: ${CERT_MANAGER_VERSION}"
fi

# âââ PHASE 5: Push artifacts to GitHub ââââââââââââââââââââââââââââââââââââââââ
step "PHASE 5 â Push artifacts to GitHub repo (cluster subfolder: ${CLUSTER_NAME}/)"

REPO_DIR="${WORK_DIR}/repo"
info "Cloning ${GIT_REPO} (branch: ${GIT_BRANCH})..."
if ! git clone --depth 1 --branch "${GIT_BRANCH}" "${GIT_REPO}" "${REPO_DIR}" 2>&1; then
  warn "Branch clone failed, retrying without --branch flag..."
  git clone --depth 1 "${GIT_REPO}" "${REPO_DIR}" \
    || error "Failed to clone repository: ${GIT_REPO}"
fi
success "Repository cloned."

# Ensure Git LFS is enabled in the repo
cd "${REPO_DIR}"
git lfs install --local &>/dev/null || true

# Track snapshot tar with Git LFS
if ! grep -q "${SNAPSHOT_TAR}" .gitattributes 2>/dev/null; then
  git lfs track "${SNAPSHOT_TAR}" &>/dev/null || true
  success "Git LFS tracking configured for ${SNAPSHOT_TAR}"
fi

# Create cluster subfolder and copy artifacts
CLUSTER_DIR="${REPO_DIR}/${CLUSTER_NAME}"
mkdir -p "${CLUSTER_DIR}"
info "Copying artifacts to ${CLUSTER_NAME}/..."
cp "${ARTIFACTS_DIR}/${SNAPSHOT_TAR}"         "${CLUSTER_DIR}/"
cp "${ARTIFACTS_DIR}/${CLUSTER_CONFIG_YAML}"  "${CLUSTER_DIR}/"
cp "${ARTIFACTS_DIR}/${DB_BLUEPRINTS_YAML}"   "${CLUSTER_DIR}/"
cp "${ARTIFACTS_DIR}/cnpg-version.txt"        "${CLUSTER_DIR}/"
cp "${ARTIFACTS_DIR}/cluster-name.txt"        "${CLUSTER_DIR}/"
cp "${ARTIFACTS_DIR}/operator-namespace.txt"  "${CLUSTER_DIR}/"
[[ -f "${ARTIFACTS_DIR}/cert-manager-version.txt" ]] && \
  cp "${ARTIFACTS_DIR}/cert-manager-version.txt" "${CLUSTER_DIR}/"

success "Artifacts copied to ${CLUSTER_NAME}/"

# Stage and commit
info "Staging changes..."
git add "${CLUSTER_NAME}/" .gitattributes 2>/dev/null || git add "${CLUSTER_NAME}/"
git add -A

COMMIT_MSG="Backup ${CLUSTER_NAME}: ${OPERATOR_TYPE} v${CNPG_VERSION} ($(date '+%Y-%m-%d %H:%M'))"
info "Committing: ${COMMIT_MSG}"
git -c user.name="cnpg-backup" -c user.email="cnpg-backup@local" \
  commit -m "${COMMIT_MSG}" \
  || warn "Nothing new to commit â artifacts are already up to date."

info "Pushing to ${GIT_BRANCH}..."
git push origin "${GIT_BRANCH}" \
  || error "Push failed. Ensure you have write access to ${GIT_REPO}.
Hint: set GIT_REPO to include credentials, e.g.:
  https://<token>@github.com/<user>/<repo>.git"

success "Artifacts pushed to GitHub under '${CLUSTER_NAME}/' subfolder."

# âââ Summary ââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
echo ""
echo -e "${BOLD}âââ Backup complete âââ${NC}"
success "Cluster:          ${CLUSTER_NAME}"
success "Operator:         ${OPERATOR_TYPE} (${VERSION_LABEL} v${CNPG_VERSION})"
success "Operator ns:      ${OPERATOR_NS}"
success "Repo branch:      ${GIT_BRANCH}"
success "Subfolder:        ${CLUSTER_NAME}/"
info    "Artifacts saved:"
info    "  ${CLUSTER_NAME}/${SNAPSHOT_TAR}"
info    "  ${CLUSTER_NAME}/${CLUSTER_CONFIG_YAML}"
info    "  ${CLUSTER_NAME}/${DB_BLUEPRINTS_YAML}"
info    "  ${CLUSTER_NAME}/cnpg-version.txt"
info    "  ${CLUSTER_NAME}/operator-namespace.txt"
[[ -f "${ARTIFACTS_DIR}/cert-manager-version.txt" ]] && \
  info  "  ${CLUSTER_NAME}/cert-manager-version.txt"
echo ""
info    "To restore: ./cnpg_restore.sh --git-repo ${GIT_REPO} --cluster-name ${CLUSTER_NAME}"
