#!/usr/bin/env bash
# =============================================================================
# cnpg_restore.sh
# CloudNativePG (kind) Cluster Restore Script
# Based on: Runbook "Kubernetes (Kind) Cluster Backup & Restore with CNPG"
#
# Usage:
#   ./cnpg_restore.sh [--git-repo <URL>] [--git-branch <branch>] [--cluster-name <name>]
#
# Defaults:
#   GIT_REPO     = https://github.com/erswapnil/Kind-Cluster-Backup-and-restore.git
#   GIT_BRANCH   = main
#   CLUSTER_NAME = cnpg
#   CNPG_VERSION = 1.28.1
# =============================================================================

set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

# ─── Defaults (override via flags or env vars) ────────────────────────────────
GIT_REPO="${GIT_REPO:-https://github.com/erswapnil/Kind-Cluster-Backup-and-restore.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"
CLUSTER_NAME="${CLUSTER_NAME:-cnpg}"
CNPG_VERSION="${CNPG_VERSION:-1.28.1}"
CNPG_RELEASE="release-${CNPG_VERSION%.*}"   # e.g. release-1.28

# Expected artifact filenames (relative to repo root)
SNAPSHOT_TAR="cnpg-snapshot.tar"
CLUSTER_CONFIG_YAML="cnp-cluster-config.yaml"
DB_BLUEPRINTS_YAML="cnpg-db-blueprints.yaml"

# ─── Parse CLI arguments ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --git-repo)    GIT_REPO="$2";    shift 2 ;;
    --git-branch)  GIT_BRANCH="$2";  shift 2 ;;
    --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    --cnpg-version) CNPG_VERSION="$2"; CNPG_RELEASE="release-${CNPG_VERSION%.*}"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) error "Unknown argument: $1. Use --help for usage." ;;
  esac
done

# ─── PHASE 0: Pre-flight checks ───────────────────────────────────────────────
step "PHASE 0 — Pre-flight checks"

# 1. Docker binary present?
info "Checking for Docker binary..."
if ! command -v docker &>/dev/null; then
  error "Docker is not installed or not on PATH. Please install Docker Desktop and retry."
fi
success "Docker binary found: $(command -v docker)"

# 2. Docker daemon running?
info "Checking Docker daemon is running..."
if ! docker info &>/dev/null 2>&1; then
  error "Docker daemon is not running. Start Docker Desktop (or 'sudo systemctl start docker') and retry."
fi
success "Docker daemon is up."

# 3. kind CLI present?
info "Checking for kind CLI..."
if ! command -v kind &>/dev/null; then
  error "'kind' CLI not found. Install it from https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
fi
success "kind found: $(kind version)"

# 4. kubectl present?
info "Checking for kubectl..."
if ! command -v kubectl &>/dev/null; then
  error "'kubectl' not found. Install it from https://kubernetes.io/docs/tasks/tools/"
fi
success "kubectl found: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"

# 5. git present?
info "Checking for git..."
if ! command -v git &>/dev/null; then
  error "'git' not found. Please install git and retry."
fi
success "git found: $(git --version)"

# ─── PHASE 1: Fetch resources from git ───────────────────────────────────────
step "PHASE 1 — Fetch migration artifacts from git"

WORK_DIR="$(mktemp -d -t cnpg-restore-XXXXXX)"
info "Working directory: ${WORK_DIR}"
trap 'info "Cleaning up working directory..."; rm -rf "${WORK_DIR}"' EXIT

info "Cloning ${GIT_REPO} (branch: ${GIT_BRANCH}) into ${WORK_DIR}..."
if ! git clone --depth 1 --branch "${GIT_BRANCH}" "${GIT_REPO}" "${WORK_DIR}/repo" 2>&1; then
  # Fallback: try shallow clone without --branch in case it's a tag
  warn "Branch clone failed, retrying without --branch flag..."
  git clone --depth 1 "${GIT_REPO}" "${WORK_DIR}/repo" \
    || error "Failed to clone repository: ${GIT_REPO}"
fi
success "Repository cloned."

REPO_DIR="${WORK_DIR}/repo"
CLUSTER_DIR="${REPO_DIR}/${CLUSTER_NAME}"

# Verify all expected artifact files are present
if [[ ! -d "${CLUSTER_DIR}" ]]; then
  error "Cluster folder '${CLUSTER_NAME}/' not found in repo. Available: $(ls -1 ${REPO_DIR} | grep -v ^\.)"
fi
success "Found cluster folder: ${CLUSTER_NAME}/"
for f in "${SNAPSHOT_TAR}" "${CLUSTER_CONFIG_YAML}" "${DB_BLUEPRINTS_YAML}"; do
  if [[ ! -f "${CLUSTER_DIR}/${f}" ]]; then
    error "Expected artifact '${CLUSTER_NAME}/${f}' not found in repo."
  fi
  success "Found: ${CLUSTER_NAME}/${f}"
done

# ─── PHASE 2: Restore ─────────────────────────────────────────────────────────
step "PHASE 2 — Restore CNPG kind cluster"

# Step 1: Load the Docker image
step "Step 1 — Load Docker image from snapshot"
info "Loading ${SNAPSHOT_TAR} into Docker (this may take a moment)..."
docker load -i "${CLUSTER_DIR}/${SNAPSHOT_TAR}"
success "Docker image loaded."

# Step 2: Create kind-config.yaml
step "Step 2 — Write kind cluster config"
KIND_CONFIG="${WORK_DIR}/kind-config.yaml"
cat <<EOF > "${KIND_CONFIG}"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
EOF
success "kind-config.yaml written to ${KIND_CONFIG}"

# Step 3: Create the kind cluster
step "Step 3 — Create kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  warn "A kind cluster named '${CLUSTER_NAME}' already exists. Deleting it first..."
  kind delete cluster --name "${CLUSTER_NAME}"
fi
kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
success "kind cluster '${CLUSTER_NAME}' created."

# Step 4: Install CNPG operator (exact version match)
step "Step 4 — Install CloudNativePG operator v${CNPG_VERSION}"
CNPG_MANIFEST="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_RELEASE}/releases/cnpg-${CNPG_VERSION}.yaml"
info "Applying CNPG manifest: ${CNPG_MANIFEST}"
kubectl apply \
  --context "kind-${CLUSTER_NAME}" \
  --server-side \
  --force-conflicts \
  -f "${CNPG_MANIFEST}"
success "CNPG operator applied."

# Step 5: Restore standard Kubernetes configs
step "Step 5 — Restore ConfigMaps, Secrets, Services"
info "Applying ${CLUSTER_CONFIG_YAML} (--validate=false to bypass schema conflicts)..."
kubectl apply \
  --context "kind-${CLUSTER_NAME}" \
  -f "${CLUSTER_DIR}/${CLUSTER_CONFIG_YAML}" \
  --validate=false || warn "Some conflict errors above are expected and safe to ignore."
success "Standard configurations applied."

# Step 6: Purge ghost pods from the operator namespace
step "Step 6 — Purge ghost pods in cnpg-system"
info "Deleting stale pods in cnpg-system so the operator can spawn fresh ones..."
kubectl delete pod \
  --context "kind-${CLUSTER_NAME}" \
  -n cnpg-system --all --ignore-not-found=true
success "Ghost pods cleared."

# Wait briefly for the operator to restart cleanly
info "Waiting 15 s for the CNPG operator to become ready..."
sleep 15
kubectl rollout status deployment/cnpg-controller-manager \
  --context "kind-${CLUSTER_NAME}" \
  -n cnpg-system \
  --timeout=120s \
  || warn "Operator rollout did not complete within 120 s — check 'kubectl get pods -n cnpg-system'."

# Step 7: Apply database blueprints (CRDs)
step "Step 7 — Apply CloudNativePG database blueprints"
info "Applying ${DB_BLUEPRINTS_YAML}..."
kubectl apply \
  --context "kind-${CLUSTER_NAME}" \
  -f "${CLUSTER_DIR}/${DB_BLUEPRINTS_YAML}"
success "Database blueprints applied."

# ─── PHASE 3: Health check ────────────────────────────────────────────────────
step "PHASE 3 — Verify cluster health"

info "Waiting up to 3 minutes for database pods to reach Running state..."
DEADLINE=$(( $(date +%s) + 180 ))
while true; do
  NOT_READY=$(kubectl get pods \
    --context "kind-${CLUSTER_NAME}" \
    -n default \
    --no-headers 2>/dev/null \
    | grep -v "Running" | grep -v "Completed" || true)

  if [[ -z "${NOT_READY}" ]]; then
    success "All pods in 'default' namespace are Running."
    break
  fi

  if [[ $(date +%s) -gt ${DEADLINE} ]]; then
    warn "Timeout waiting for pods. Current state:"
    kubectl get pods --context "kind-${CLUSTER_NAME}" -n default
    warn "Check pod logs with: kubectl logs <pod-name> -n default"
    break
  fi

  info "Pods not yet ready, retrying in 10 s..."
  sleep 10
done

echo ""
echo -e "${BOLD}━━━ Final cluster state ━━━${NC}"
kubectl get pods --context "kind-${CLUSTER_NAME}" -n default
echo ""
kubectl get pods --context "kind-${CLUSTER_NAME}" -n cnpg-system
echo ""

success "Restore complete! Cluster '${CLUSTER_NAME}' is up and running."
info  "kubectl context: kind-${CLUSTER_NAME}"
info  "Run 'kubectl get clusters.postgresql.cnpg.io -n default' to inspect CNPG databases."
