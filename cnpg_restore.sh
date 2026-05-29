#!/usr/bin/env bash
# =============================================================================
# cnpg_restore.sh
# CloudNativePG (kind) Cluster Restore Script
#
# Repo structure expected:
#   cnpg-migration/
#   âââ cnpg_restore.sh          â this script
#   âââ cnpg/                    â artifacts for the 'cnpg' cluster
#   â   âââ cnpg-snapshot.tar
#   â   âââ cnp-cluster-config.yaml
#   â   âââ cnpg-db-blueprints.yaml
#   âââ klio/                    â artifacts for the 'klio' cluster
#   â   âââ ...
#   âââ ...
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
CNPG_VERSION="${CNPG_VERSION:-}"      # optional â auto-detected from repo if not provided
OPERATOR_NS="${OPERATOR_NS:-}"        # optional â auto-detected from repo if not provided

# Artifact filenames (always the same, inside the cluster subfolder)
SNAPSHOT_TAR="cnpg-snapshot.tar"
CLUSTER_CONFIG_YAML="cnp-cluster-config.yaml"
DB_BLUEPRINTS_YAML="cnpg-db-blueprints.yaml"

# âââ Parse CLI arguments ââââââââââââââââââââââââââââââââââââââââââââââââââââââ
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

# âââ Require cluster-name âââââââââââââââââââââââââââââââââââââââââââââââââââââ
if [[ -z "${CLUSTER_NAME}" ]]; then
  error "--cluster-name is required. Example: --cluster-name klio"
fi
# --cnpg-version is now optional; auto-detected from repo after clone if not supplied

# âââ PHASE 0: Pre-flight checks âââââââââââââââââââââââââââââââââââââââââââââââ
step "PHASE 0 â Pre-flight checks"

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

# âââ PHASE 1: Fetch artifacts from git âââââââââââââââââââââââââââââââââââââââ
step "PHASE 1 â Fetch artifacts for cluster '${CLUSTER_NAME}' from git"

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

# âââ Auto-detect operator version and namespace from committed files ââââââââââ
step "PHASE 1b â Detect operator version and namespace"

# ââ Operator namespace ââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
if [[ -z "${OPERATOR_NS}" ]]; then
  if [[ -f "${CLUSTER_DIR}/operator-namespace.txt" ]]; then
    OPERATOR_NS=$(cat "${CLUSTER_DIR}/operator-namespace.txt" | tr -d '[:space:]')
    success "Operator namespace: ${OPERATOR_NS}  (from operator-namespace.txt)"
  else
    # Infer from the cluster config YAML â look for the known operator namespaces
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

# ââ Operator version âââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
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

# Determine operator type and version label for display
case "${OPERATOR_NS}" in
  "cnpg-system")                OPERATOR_TYPE="Community CloudNativePG"        ; VERSION_LABEL="CNPG" ;;
  "postgresql-operator-system") OPERATOR_TYPE="EDB Postgres for CloudNativePG" ; VERSION_LABEL="CNP"  ;;
  "pgd-operator-system")        OPERATOR_TYPE="EDB PGD4K"                      ; VERSION_LABEL="PGD4K" ;;
  *)                            OPERATOR_TYPE="Unknown operator"                ; VERSION_LABEL="Operator" ;;
esac
success "Operator:  ${OPERATOR_TYPE} (${VERSION_LABEL} v${CNPG_VERSION})"
success "Namespace: ${OPERATOR_NS}"

# Read cert-manager version from repo (written by backup; defaults to v1.16.2 for PGD runbook)
CERT_MANAGER_VERSION="v1.16.2"
if [[ -f "${CLUSTER_DIR}/cert-manager-version.txt" ]]; then
  _cm=$(cat "${CLUSTER_DIR}/cert-manager-version.txt" | tr -d '[:space:]')
  if [[ -n "${_cm}" ]]; then
    [[ "${_cm}" =~ ^v ]] && CERT_MANAGER_VERSION="${_cm}" || CERT_MANAGER_VERSION="v${_cm}"
    info "cert-manager version: ${CERT_MANAGER_VERSION}  (from repo)"
  fi
fi

CNPG_RELEASE="release-${CNPG_VERSION%.*}"   # e.g. 1.29.1 â release-1.29

# âââ Detect Git LFS pointer file ââââââââââââââââââââââââââââââââââââââââââââââ
SNAPSHOT_PATH="${CLUSTER_DIR}/${SNAPSHOT_TAR}"
SNAPSHOT_SIZE=$(wc -c < "${SNAPSHOT_PATH}" | tr -d ' ')
if [[ "${SNAPSHOT_SIZE}" -lt 10000 ]]; then
  error "${CLUSTER_NAME}/${SNAPSHOT_TAR} is only ${SNAPSHOT_SIZE} bytes â it is a Git LFS pointer, not the real archive.
git-lfs is not installed on this machine.

Fix:
  brew install git-lfs
  git lfs install

Then re-run this script."
fi
info "Snapshot size: $(( SNAPSHOT_SIZE / 1024 / 1024 )) MB â looks like the real binary."

# âââ PHASE 2: Restore âââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
step "PHASE 2 â Restore kind cluster '${CLUSTER_NAME}'"

step "Step 1 â Load Docker image from snapshot"
info "Loading ${CLUSTER_NAME}/${SNAPSHOT_TAR} into Docker (this may take a moment)..."
docker load -i "${CLUSTER_DIR}/${SNAPSHOT_TAR}"
success "Docker image loaded."

step "Step 2 â Write kind cluster config"
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

step "Step 3 â Create kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  warn "Cluster '${CLUSTER_NAME}' already exists. Deleting it first..."
  kind delete cluster --name "${CLUSTER_NAME}"
fi
kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
success "kind cluster '${CLUSTER_NAME}' created."

step "Step 4 â Install ${VERSION_LABEL} operator v${CNPG_VERSION} (${OPERATOR_TYPE})"
case "${OPERATOR_NS}" in
  "cnpg-system")
    # Community CloudNativePG â manifest available publicly on GitHub
    CNPG_MANIFEST="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_RELEASE}/releases/cnpg-${CNPG_VERSION}.yaml"
    info "Applying community CNPG manifest: ${CNPG_MANIFEST}"
    kubectl apply \
      --context "kind-${CLUSTER_NAME}" \
      --server-side --force-conflicts \
      -f "${CNPG_MANIFEST}"
    success "Community CNPG operator applied."
    ;;

  "postgresql-operator-system")
    # EDB Postgres for CloudNativePG â operator baked in snapshot; applied via Step 5 YAML.
    info "EDB CNP operator is embedded in the cluster snapshot."
    info "Operator deployment will be restored via cnp-cluster-config.yaml in Step 5."
    ;;

  "pgd-operator-system")
    # ââ EDB PGD4K â requires cert-manager + PGD operator installed first âââââââââ
    # A fresh kind cluster has no cert-manager or pgd-operator-system namespaces.
    # Both must be bootstrapped from their public manifests before the backup YAML
    # is applied, otherwise "namespace not found" errors cascade through Step 5.

    # Step 4a: cert-manager (creates cert-manager namespace + CRDs)
    info "Installing cert-manager ${CERT_MANAGER_VERSION}..."
    kubectl apply \
      --context "kind-${CLUSTER_NAME}" \
      --validate=false \
      -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

    info "Waiting for cert-manager webhook pods to be Ready (up to 90 s)..."
    kubectl wait pod \
      --for=condition=ready \
      --selector app.kubernetes.io/instance=cert-manager \
      --namespace cert-manager \
      --context "kind-${CLUSTER_NAME}" \
      --timeout=90s \
      2>/dev/null || warn "cert-manager pods not fully Ready yet â continuing anyway."
    success "cert-manager ${CERT_MANAGER_VERSION} installed."

    # Step 4b: PGD operator manifest (creates pgd-operator-system namespace + deployment)
    PGD_MANIFEST="https://get.enterprisedb.io/pg4k-pgd/pg4k-pgd-${CNPG_VERSION}.yaml"
    info "Applying EDB PGD4K operator v${CNPG_VERSION} manifest..."
    kubectl apply \
      --server-side \
      --context "kind-${CLUSTER_NAME}" \
      -f "${PGD_MANIFEST}" \
      || warn "PGD operator manifest had warnings â check pods below."
    success "EDB PGD4K operator manifest applied."

    # Step 4c: Inject EDB pull secret into pgd-operator-system immediately
    # The operator image lives at docker.enterprisedb.com and needs this secret
    # or the pod will stay in ImagePullBackOff before Step 5 even runs.
    info "Injecting EDB pull secret into pgd-operator-system from backup YAML..."
    python3 -c "
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
parts = re.split(r'(?m)^---[ \t]*$', content)
for part in parts:
    if (re.search(r'namespace:\s+pgd-operator-system', part) and
        re.search(r'name:\s+edb-pull-secret', part) and
        re.search(r'^kind:\s+Secret', part, re.MULTILINE)):
        print('---')
        print(part.strip())
" "${CLUSTER_DIR}/${CLUSTER_CONFIG_YAML}" \
      | kubectl apply --context "kind-${CLUSTER_NAME}" -f - --validate=false 2>/dev/null \
      && success "EDB pull secret applied to pgd-operator-system." \
      || warn "Could not apply pull secret â eoperator may ImagePullBackOff."
    ;;

  *)
    warn "Unknown operator namespace '${OPERATOR_NS}' â skipping manifest install."
    warn "Operator deployment will be applied from cnp-cluster-config.yaml in Step 5."
    ;;
esac

step "Step 5 â Restore Kubernetes configs (Namespaces â Operator â Resources)"

# Pass 1: create any remaining namespace objects from the YAML first.
# (For PGD, cert-manager and pgd-operator-system are already created by Step 4.
#  For CNP/CNPG this is a safety net in case other namespaces are missing.)
info "Pass 1: Creating Namespace resources from backup YAML..."
python3 -c "
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
parts = re.split(r'(?m)^---[ \t]*$', content)
ns_docs = [p.strip() for p in parts if re.search(r'^kind:\s+Namespace\s*$', p, re.MULTIL"NENE)]
if ns_docs:
    print('---\n' + '\n---\n'.join(ns_docs))
" "${CLUSTER_DIR}/${CLUSTER_CONFIG_YAML}" \
  | kubectl apply --context "kind-${CLUSTER_NAME}" -f - --validate=false 2>/dev/null \
  && info "Namespaces applied." \
  || warn "Namespace pass had warnings (OK if already exist)."

# Pass 2: apply the full cluster config
info "Pass 2: Applying full cluster configuration..."
kubectl apply \
  --context "kind-${CLUSTER_NAME}" \
  -f "${CLUSTER_DIR}/${CLUSTER_CONFIG_YAML}" \
  --validate=false || warn "Conflict errors above are expected and safe to ignore."
success "Kubernetes configs applied."

step "Step 6 â Clear ghost pods and wait for ${OPERATOR_TYPE} in ${OPERATOR_NS}"
kubectl delete pod \
  --context "kind-${CLUSTER_NAME}" \
  -n "${OPERATOR_NS}" --all --ignore-not-found=true 2>/dev/null || true
success "Ghost pods cleared."

info "Waiting 15 s for operator deployment to start..."
sleep 15

# Detect controller deployment name dynamically
CTRL_DEPLOY=$(kubectl get deployment -n "${OPERATOR_NS}" \
  --context "kind-${CLUSTER_NAME}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -i -E "controller-manager|operator" | head -1 || true)

if [[ -n "${CTRL_DEPLOY}" ]]; then
  kubectl rollout status "deployment/${CTRL_DEPLOY}" \
    --context "kind-${CLUSTER_NAME}" \
    -n "${OPERATOR_NS}" \
    --timeout=180s \
    || warn "Operator rollout timeout â check 'kubectl get pods -n ${OPERATOR_NS}'."
else
  warn "No controller deployment found in ${OPERATOR_NS} â skipping rollout check."
  warn "Manually verify: kubectl get pods --context kind-${CLUSTER_NAME} -n ${OPERATOR_NS}"
fi

# For PGD: wait for CRDs to register before applying blueprints
if [[ "${OPERATOR_NS}" == "pgd-operator-system" ]]; then
  info "Waiting for PGD CRDs to be registered (up to 120 s)..."
  CRD_DEADLINE=$(( $(date +%s) + 120 ))
  while true; do
    if kubectl get crd pgdgroups.pgd.k8s.enterprisedb.io \
       --context "kind-${CLUSTER_NAME}" &>/dev/null 2>&1; then
      success "PGD CRDs registered â ready to apply blueprints."
      break
    fi
    [[ $(date +%s) -gt ${CRD_DEADLINE} ]] && \
      warn "PGD CRD wait timed out â proceeding anyway." && break
    info "PGD CRDs not yet registered â retrying in 10 s..."
    sleep 10
  done
fi

step "Step 7 â Apply database blueprints (${OPERATOR_TYPE})"

# For PGD: cert-manager Issuers must exist before PGDGroups (TLS prerequisite)
if [[ "${OPERATOR_NS}" == "pgd-operator-system" ]]; then
  info "Applying cert-manager Issuers and Certificates first..."
  python3 -c "
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
parts = re.split(r'(?m)^---[ \t]*$', content)
cert_docs = [p.strip() for p in parts
             if re.search(r'^kind:\s+(Issuer|ClusterIssuer|Certificate)\s*$', p, re.MULTILINE)]
if cert_docs:
    print('---\n' + '\n---\n'.join(cert_docs))
" "${CLUSTER_DIR}/${DB_BLUEPRINTS_YAML}" \
    | kubectl apply --context "kind-${CLUSTER_NAME}" -f - --validate=false 2>/dev/null \
    && info "cert-manager Issuers/Certificates applied." \
    || warn "Issuer apply had warnings (OK if backup predates Issuer export)."
fi

kubectl apply \
  --context "kind-${CLUSTER_NAME}" \
  -f "${CLUSTER_DIR}/${DB_BLUEPRINTS_YAML}" \
  || warn "Some blueprint errors may be expected â check pod status below."
success "Database blueprints applied."

# âââ PHASE 3: Health check ââââââââââââââââââââââââââââââââââââââââââââââââââââ
step "PHASE 3 â Verify cluster health"

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
echo -e "${BOLD}âââ Final cluster state âââ${NC}"
kubectl get pods --context "kind-${CLUSTER_NAME}" -n default
echo ""
kubectl get pods --context "kind-${CLUSTER_NAME}" -n "${OPERATOR_NS}"
echo ""

success "Restore complete! Cluster '${CLUSTER_NAME}' is up and running."
info  "Operator:        ${OPERATOR_TYPE} (${VERSION_LABEL} v${CNPG_VERSION})"
info  "Operator ns:     ${OPERATOR_NS}"
info  "kubectl context: kind-${CLUSTER_NAME}"
info  "Run cnpg_verify.sh to do a full health check."
case "${OPERATOR_NS}" in
  "pgd-operator-system")
    info  "Run 'kubectl get pgdgroups -n default' to inspect PGD databases."
    info  "Run 'kubectl get pods -n default' to see all region pods."
    ;;
  *)
    info  "Run 'kubectl get clusters.postgresql.cnpg.io -n default' to inspect databases."
    ;;
esac
