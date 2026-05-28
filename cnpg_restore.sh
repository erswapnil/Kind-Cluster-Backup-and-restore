#!/usr/bin/env bash
# =============================================================================
# cnpg_restore.sh
# CloudNativePG (kind) Cluster Restore Script
#
# Repo structure expected:
#   cnpg-migration/
#   ├── cnpg_restore.sh          ← this script
#   ├── cnpg/                    ← artifacts for the 'cnpg' cluster
#   │   ├── cnpg-snapshot.tar
#   │   ├── cnp-cluster-config.yaml
#   │   └── cnpg-db-blueprints.yaml
#   ├── klio/                    ← artifacts for the 'klio' cluster
#   │   └── ...
#   └── ...
#
# Usage:
#   ./cnpg_restore.sh \
#     --git-repo     https://github.com/<username>/cnpg-migration.git \
#     --cluster-name <cluster-name> \
#     --cnpg-version <version>
#
# Optional:
#   --git-branch <branch>   default: main
#
# Examples:
#   ./cnpg_restore.sh --git-repo https://github.com/erswapnil/cnpg-migration.git \
#                     --cluster-name klio --cnpg-version 1.29.1
#
#   ./cnpg_restore.sh --git-repo https://github.com/erswapnil/cnpg-migration.git \
#                     --cluster-name cnpg --cnpg-version 1.28.1
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

# ─── Defaults ─────────────────────────────────────────────────────────────────
GIT_REPO="${GIT_REPO:-https://github.com/erswapnil/Kind-Cluster-Backup-and-restore.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"
CLUSTER_NAME="${CLUSTER_NAME:-}"
CNPG_VERSION="${CNPG_VERSION:-}"      # optional — auto-detected from repo if not provided
OPERATOR_NS="${OPERATOR_NS:-}"        # optional — auto-detected from repo if not provided

# Artifact filenames (always the same, inside the cluster subfolder)
SNAPSHOT_TAR="cnpg-snapshot.tar"
CLUSTER_CONFIG_YAML="cnp-cluster-config.yaml"
DB_BLUEPRINTS_YAML="cnpg-db-blueprints.yaml"

# ─── Parse CLI arguments ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --git-repo)        GIT_REPO="$2";      shift 2 ;;
    --git-branch)      GIT_BRANCH="$2";    shift 2 ;;
    --cluster-name)    CLUSTER_NAME="$2";  shift 2 ;;
    --cnpg-version)    CNPG_VERSION="$2";  shift 2 ;;
    --operator-ns)     OPERATOR_NS="$2";   shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) error "Unknown argument: $1. Use --help for usage." ;;
  esac
done

# ─── Require cluster-name ─────────────────────────────────────────────────────
if [[ -z "${CLUSTER_NAME}" ]]; then
  error "--cluster-name is required. Example: --cluster-name klio"
fi
# --cnpg-version is now optional; auto-detected from repo after clone if not supplied

# ─── PHASE 0: Pre-flight checks ───────────────────────────────────────────────
step "PHASE 0 — Pre-flight checks"

info "Checking for Docker binary..."
if ! command -v docker &>/dev/null; then
  error "Docker is not installed or not on PATH. Install Docker Desktop and retry."
fi
success "Docker binary found: $(command -v docker)"

info "Checking Docker daemon is running..."
if ! docker info &>/dev/null 2>&1; then
  error "Docker daemon is not running. Start Docker Desktop and retry."
fi
success "Docker daemon is up."

info "Checking for kind CLI..."
if ! command -v kind &>/dev/null; then
  error "'kind' CLI not found. Install it: brew install kind"
fi
success "kind found: $(kind version)"

info "Checking for kubectl..."
if ! command -v kubectl &>/dev/null; then
  error "'kubectl' not found. Install it: brew install kubectl"
fi
success "kubectl found: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"

info "Checking for git..."
if ! command -v git &>/dev/null; then
  error "'git' not found. Install it: brew install git"
fi
success "git found: $(git --version)"

# ─── PHASE 1: Fetch artifacts from git ───────────────────────────────────────
step "PHASE 1 — Fetch artifacts for cluster '${CLUSTER_NAME}' from git"

WORK_DIR="$(mktemp -d -t cnpg-restore-XXXXXX)"
info "Working directory: ${WORK_DIR}"
trap 'info "Cleaning up working directory..."; rm -rf "${WORK_DIR}"' EXIT

info "Cloning ${GIT_REPO} (branch: ${GIT_BRANCH})..."
if ! git clone --depth 1 --branch "${GIT_BRANCH}" "${GIT_REPO}" "${WORK_DIR}/repo" 2>&1; then
  warn "Branch clone failed, retrying without --branch flag..."
  git clone --depth 1 "${GIT_REPO}" "${WORK_DIR}/repo" \
    || error "Failed to clone repository: ${GIT_REPO}"
fi
success "Repository cloned."

REPO_DIR="${WORK_DIR}/repo"
CLUSTER_DIR="${REPO_DIR}/${CLUSTER_NAME}"

# Verify cluster subfolder exists
if [[ ! -d "${CLUSTER_DIR}" ]]; then
  error "Cluster folder '${CLUSTER_NAME}/' not found in repo.
Available folders: $(ls -1 "${REPO_DIR}" | grep -v '^\.' | tr '\n' ' ')"
fi
success "Found cluster folder: ${CLUSTER_NAME}/"

# Verify all artifact files exist inside the cluster folder
for f in "${SNAPSHOT_TAR}" "${CLUSTER_CONFIG_YAML}" "${DB_BLUEPRINTS_YAML}"; do
  if [[ ! -f "${CLUSTER_DIR}/${f}" ]]; then
    error "Expected artifact '${CLUSTER_NAME}/${f}' not found in repo."
  fi
  success "Found: ${CLUSTER_NAME}/${f}"
done

# ─── Auto-detect operator version and namespace from committed files ──────────
step "PHASE 1b — Detect operator version and namespace"

# ── Operator namespace ────────────────────────────────────────────────────────
if [[ -z "${OPERATOR_NS}" ]]; then
  if [[ -f "${CLUSTER_DIR}/operator-namespace.txt" ]]; then
    OPERATOR_NS=$(cat "${CLUSTER_DIR}/operator-namespace.txt" | tr -d '[:space:]')
    success "Operator namespace: ${OPERATOR_NS}  (from operator-namespace.txt)"
  else
    # Infer from the cluster config YAML — look for the known operator namespaces
    for ns_candidate in "postgresql-operator-system" "pgd-operator-system" "cnpg-system"; do
      if grep -q "namespace: ${ns_candidate}" "${CLUSTER_DIR}/${CLUSTER_CONFIG_YAML}" 2>/dev/null; then
        OPERATOR_NS="${ns_candidate}"
        info "Operator namespace inferred from YAML: ${OPERATOR_NS}"
        break
      fi
    done
    # Final fallback
    OPERATOR_NS="${OPERATOR_NS:-cnpg-system}"
    info "Operator namespace fallback: ${OPERATOR_NS}"
  fi
else
  info "Operator namespace: ${OPERATOR_NS}  (from --operator-ns flag)"
fi

# ── Operator version ──────────────────────────────────────────────────────────
if [[ -z "${CNPG_VERSION}" ]]; then
  # Priority 1: cnpg-version.txt committed alongside artifacts
  if [[ -f "${CLUSTER_DIR}/cnpg-version.txt" ]]; then
    CNPG_VERSION=$(cat "${CLUSTER_DIR}/cnpg-version.txt" | tr -d '[:space:]')
    success "Version: ${CNPG_VERSION}  (from cnpg-version.txt)"
  fi

  # Priority 2: extract from known operator image tags inside the cluster config YAML
  # Covers:  ghcr.io/cloudnative-pg/cloudnative-pg:VERSION
  #          docker.enterprisedb.com/k8s/edb-postgres-for-cloudnativepg:VERSION
  #          docker.enterprisedb.com/k8s/edb-postgres-for-cloudnativepg-global-cluster:VERSION
  if [[ -z "${CNPG_VERSION}" ]]; then
    CNPG_VERSION=$(grep -hE "cloudnative-pg|edb-postgres|cnpg|pgd-operator|barman" \
      "${CLUSTER_DIR}/${CLUSTER_CONFIG_YAML}" \
      "${CLUSTER_DIR}/${DB_BLUEPRINTS_YAML}" 2>/dev/null \
      | grep -oE ':[0-9]+\.[0-9]+\.[0-9]+' | tr -d ':' | head -1 || true)
    [[ -n "${CNPG_VERSION}" ]] && info "Version: ${CNPG_VERSION}  (extracted from YAML image tags)"
  fi

  # Priority 3: any semver image tag in the YAML files
  if [[ -z "${CNPG_VERSION}" ]]; then
    CNPG_VERSION=$(grep -h "image:" \
      "${CLUSTER_DIR}/${CLUSTER_CONFIG_YAML}" \
      "${CLUSTER_DIR}/${DB_BLUEPRINTS_YAML}" 2>/dev/null \
      | grep -oE ':[0-9]+\.[0-9]+\.[0-9]+' | tr -d ':' | head -1 || true)
    [[ -n "${CNPG_VERSION}" ]] && info "Version: ${CNPG_VERSION}  (extracted from YAML image tags, generic)"
  fi

  if [[ -z "${CNPG_VERSION}" ]]; then
    warn "Could not auto-detect operator version from committed files."
    read -rp "Enter operator version manually (e.g. 1.28.0): " CNPG_VERSION
    [[ -z "${CNPG_VERSION}" ]] && error "Operator version is required."
  fi
else
  info "Version: ${CNPG_VERSION}  (from --cnpg-version flag)"
fi

# Determine operator type for informational output
case "${OPERATOR_NS}" in
  "cnpg-system")                OPERATOR_TYPE="Community CloudNativePG" ;;
  "postgresql-operator-system") OPERATOR_TYPE="EDB Postgres for CloudNativePG" ;;
  "pgd-operator-system")        OPERATOR_TYPE="EDB Postgres Distributed (PGD)" ;;
  *)                            OPERATOR_TYPE="Unknown operator" ;;
esac
success "Operator type: ${OPERATOR_TYPE}  |  Namespace: ${OPERATOR_NS}  |  Version: ${CNPG_VERSION}"

CNPG_RELEASE="release-${CNPG_VERSION%.*}"   # e.g. 1.29.1 → release-1.29

# ─── Detect Git LFS pointer file ──────────────────────────────────────────────
SNAPSHOT_PATH="${CLUSTER_DIR}/${SNAPSHOT_TAR}"
SNAPSHOT_SIZE=$(wc -c < "${SNAPSHOT_PATH}" | tr -d ' ')
if [[ "${SNAPSHOT_SIZE}" -lt 10000 ]]; then
  error "${CLUSTER_NAME}/${SNAPSHOT_TAR} is only ${SNAPSHOT_SIZE} bytes — it is a Git LFS pointer, not the real archive.
git-lfs is not installed on this machine.

Fix:
  brew install git-lfs
  git lfs install

Then re-run this script."
fi
info "Snapshot size: $(( SNAPSHOT_SIZE / 1024 / 1024 )) MB — looks like the real binary."

# ─── PHASE 2: Restore ─────────────────────────────────────────────────────────
step "PHASE 2 — Restore kind cluster '${CLUSTER_NAME}'"

step "Step 1 — Load Docker image from snapshot"
info "Loading ${CLUSTER_NAME}/${SNAPSHOT_TAR} into Docker (this may take a moment)..."
docker load -i "${CLUSTER_DIR}/${SNAPSHOT_TAR}"
success "Docker image loaded."

step "Step 2 — Write kind cluster config"
KIND_CONFIG="${WORK_DIR}/kind-config.yaml"
cat <<EOF > "${KIND_CONFIG}"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
EOF
success "kind-config.yaml written."
warn "If this cluster had 0 or more than 1 worker, edit the nodes section above before re-running."

step "Step 3 — Create kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  warn "Cluster '${CLUSTER_NAME}' already exists. Deleting it first..."
  kind delete cluster --name "${CLUSTER_NAME}"
fi
kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
success "kind cluster '${CLUSTER_NAME}' created."

step "Step 4 — Install operator v${CNPG_VERSION} (${OPERATOR_TYPE})"
case "${OPERATOR_NS}" in
  "cnpg-system")
    # Community CloudNativePG — manifest available publicly on GitHub
    CNPG_MANIFEST="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_RELEASE}/releases/cnpg-${CNPG_VERSION}.yaml"
    info "Applying community CNPG manifest: ${CNPG_MANIFEST}"
    kubectl apply \
      --context "kind-${CLUSTER_NAME}" \
      --server-side --force-conflicts \
      -f "${CNPG_MANIFEST}"
    success "Community CNPG operator applied."
    ;;
  "postgresql-operator-system"|"pgd-operator-system")
    # EDB operator — manifest is already baked into the cluster snapshot.
    # The config YAML exported during backup contains the operator deployment,
    # so it will be applied in Step 5 below. Nothing extra to download here.
    info "EDB operator (${OPERATOR_TYPE}) is embedded in the cluster snapshot."
    info "Operator deployment will be restored via cnp-cluster-config.yaml in Step 5."
    ;;
  *)
    warn "Unknown operator namespace '${OPERATOR_NS}' — skipping manifest install."
    warn "Operator deployment will be applied from cnp-cluster-config.yaml in Step 5."
    ;;
esac

step "Step 5 — Restore ConfigMaps, Secrets, Services"
kubectl apply \
  --context "kind-${CLUSTER_NAME}" \
  -f "${CLUSTER_DIR}/${CLUSTER_CONFIG_YAML}" \
  --validate=false || warn "Conflict errors above are expected and safe to ignore."
success "Standard configurations applied."

step "Step 6 — Purge ghost pods in ${OPERATOR_NS}"
kubectl delete pod \
  --context "kind-${CLUSTER_NAME}" \
  -n "${OPERATOR_NS}" --all --ignore-not-found=true
success "Ghost pods cleared."

info "Waiting 15 s for the operator to become ready..."
sleep 15

# Detect controller deployment name dynamically — works for cnpg-controller-manager,
# pgd-operator-controller-manager, edb-postgres-operator, etc.
CTRL_DEPLOY=$(kubectl get deployment -n "${OPERATOR_NS}" \
  --context "kind-${CLUSTER_NAME}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -i -E "controller-manager|operator" | head -1 || true)

if [[ -n "${CTRL_DEPLOY}" ]]; then
  kubectl rollout status "deployment/${CTRL_DEPLOY}" \
    --context "kind-${CLUSTER_NAME}" \
    -n "${OPERATOR_NS}" \
    --timeout=120s \
    || warn "Operator rollout timeout — check 'kubectl get pods -n ${OPERATOR_NS}'."
else
  warn "No controller deployment found in ${OPERATOR_NS} — skipping rollout check."
fi

step "Step 7 — Apply CloudNativePG database blueprints"
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
    -n default --no-headers 2>/dev/null \
    | grep -v "Running" | grep -v "Completed" || true)

  if [[ -z "${NOT_READY}" ]]; then
    success "All pods in 'default' namespace are Running."
    break
  fi

  if [[ $(date +%s) -gt ${DEADLINE} ]]; then
    warn "Timeout waiting for pods. Current state:"
    kubectl get pods --context "kind-${CLUSTER_NAME}" -n default
    warn "Pods may still be pulling images. Run cnpg_verify.sh in a few minutes."
    break
  fi

  info "Pods not yet ready, retrying in 10 s..."
  sleep 10
done

echo ""
echo -e "${BOLD}━━━ Final cluster state ━━━${NC}"
kubectl get pods --context "kind-${CLUSTER_NAME}" -n default
echo ""
kubectl get pods --context "kind-${CLUSTER_NAME}" -n "${OPERATOR_NS}"
echo ""

success "Restore complete! Cluster '${CLUSTER_NAME}' is up and running."
info  "Operator:       ${OPERATOR_TYPE} v${CNPG_VERSION}"
info  "Operator ns:    ${OPERATOR_NS}"
info  "kubectl context: kind-${CLUSTER_NAME}"
info  "Run cnpg_verify.sh to do a full health check."
info  "Run 'kubectl get clusters.postgresql.cnpg.io -n default' to inspect CNPG databases."
