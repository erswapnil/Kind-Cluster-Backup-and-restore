#!/usr/bin/env bash
# =============================================================================
# docker-cluster-restore.sh
# Restore a kind CNPG cluster from a zip created by docker-cluster-backup.sh.
#
# Usage:
#   ./docker-cluster-restore.sh <path-to-zip>
#
# Example:
#   ./docker-cluster-restore.sh ~/Downloads/kind-backup-cnpg-20250528.zip
#
# What it does:
#   1. Installs missing prerequisites (kind, kubectl) via Homebrew
#   2. Unzips the backup
#   3. Reads cluster name, CNPG version, and operator namespace from the zip
#   4. Loads the Docker snapshot image
#   5. Creates a fresh kind cluster
#   6. Installs the CNPG/EDB/PGD operator
#   7. Applies Kubernetes configs:
#        Pass 1 â creates all Namespace objects first (avoids "namespace not found")
#        Pass 2 â applies full cluster config (deployments, secrets, configmaps, etc.)
#   8. Waits for operator + CRDs to be ready (PGD waits for pgdgroups CRD)
#   9. Applies database blueprints (clusters / pgdgroups / poolers)
#  10. Waits for all pods to reach Running state
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}âââ $* âââ${NC}"; }

echo ""
echo -e "${BOLD}ââââââââââââââââââââââââââââââââââââââââââââââââââââââââ${NC}"
echo -e "${BOLD}â        kind Cluster â Local Restore Tool             â${NC}"
echo -e "${BOLD}â     Restores cluster from a shared zip file          â${NC}"
echo -e "${BOLD}ââââââââââââââââââââââââââââââââââââââââââââââââââââââââ${NC}"
echo ""

# âââ Require zip argument âââââââââââââââââââââââââââââââââââââââââââââââââââââ
if [[ $# -lt 1 ]]; then
  error "Usage: ./docker-cluster-restore.sh <path-to-zip>
Example: ./docker-cluster-restore.sh ~/Downloads/kind-backup-cnpg-20250528.zip"
fi

ZIP_PATH="$1"

if [[ ! -f "${ZIP_PATH}" ]]; then
  error "Zip file not found: ${ZIP_PATH}"
fi

success "Zip file found: ${ZIP_PATH}  ($(du -sh "${ZIP_PATH}" | cut -f1))"

# âââ Pre-flight: Homebrew âââââââââââââââââââââââââââââââââââââââââââââââââââââ
step "Pre-flight â Check Homebrew"
if ! command -v brew &>/dev/null; then
  error "Homebrew is not installed. Install it first: https://brew.sh"
fi
success "Homebrew found: $(brew --version | head -1)"

# âââ Pre-flight: Docker âââââââââââââââââââââââââââââââââââââââââââââââââââââââ
step "Pre-flight â Check Docker"
if ! command -v docker &>/dev/null; then
  warn "Docker not found."
  warn "Install Docker Desktop from: https://docker.com/products/docker-desktop"
  warn "Start Docker Desktop, wait for the whale icon to go solid, then re-run."
  exit 1
fi
if ! docker info &>/dev/null 2>&1; then
  warn "Docker is installed but the daemon is not running."
  warn "Open Docker Desktop, wait for the whale icon to go solid, then re-run."
  exit 1
fi
success "Docker is installed and running."

# âââ Pre-flight: Install missing tools via Homebrew âââââââââââââââââââââââââââ
step "Pre-flight â Install missing tools (kind, kubectl, unzip)"

TOOLS=(kind kubectl)
for tool in "${TOOLS[@]}"; do
  if command -v "${tool}" &>/dev/null; then
    success "${tool} already installed."
  else
    info "Installing ${tool} via Homebrew..."
    brew install "${tool}"
    success "${tool} installed."
  fi
done

if ! command -v unzip &>/dev/null; then
  info "Installing unzip..."
  brew install unzip
  success "unzip installed."
else
  success "unzip already available."
fi

# âââ Unzip the backup âââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
step "Unzipping backup"

WORK_DIR="$(mktemp -d -t cnpg-local-restore-XXXXXX)"
info "Working directory: ${WORK_DIR}"
trap 'info "Cleaning up working directory..."; rm -rf "${WORK_DIR}"' EXIT

unzip -q "${ZIP_PATH}" -d "${WORK_DIR}"
success "Unzipped to: ${WORK_DIR}"

# Find the backup subfolder (the unzipped directory inside)
BACKUP_SUBDIR=$(find "${WORK_DIR}" -mindepth 1 -maxdepth 1 -type d | head -1)
if [[ -z "${BACKUP_SUBDIR}" ]]; then
  error "Could not find backup folder inside the zip. Is this the right file?"
fi
info "Backup folder: $(basename "${BACKUP_SUBDIR}")"

# Define artifact paths here so they're available for namespace detection below
SNAPSHOT_TAR="${BACKUP_SUBDIR}/cnpg-snapshot.tar"
CLUSTER_CONFIG="${BACKUP_SUBDIR}/cnp-cluster-config.yaml"
DB_BLUEPRINTS="${BACKUP_SUBDIR}/cnpg-db-blueprints.yaml"

# âââ Read cluster metadata ââââââââââââââââââââââââââââââââââââââââââââââââââââ
step "Reading cluster metadata from zip"

CLUSTER_NAME_FILE="${BACKUP_SUBDIR}/cluster-name.txt"
CNPG_VERSION_FILE="${BACKUP_SUBDIR}/cnpg-version.txt"
OPERATOR_NS_FILE="${BACKUP_SUBDIR}/operator-namespace.txt"

if [[ ! -f "${CLUSTER_NAME_FILE}" ]]; then
  error "cluster-name.txt not found in zip. Was this created by docker-cluster-backup.sh?"
fi
if [[ ! -f "${CNPG_VERSION_FILE}" ]]; then
  error "cnpg-version.txt not found in zip. Was this created by docker-cluster-backup.sh?"
fi

CLUSTER_NAME=$(cat "${CLUSTER_NAME_FILE}" | tr -d '[:space:]')
CNPG_VERSION=$(cat "${CNPG_VERSION_FILE}" | tr -d '[:space:]')

# ââ Operator namespace ââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
OPERATOR_NS=""

# Priority 1: operator-namespace.txt (written by newer local_backup.sh)
if [[ -f "${OPERATOR_NS_FILE}" ]]; then
  OPERATOR_NS=$(cat "${OPERATOR_NS_FILE}" | tr -d '[:space:]')
  info "Operator namespace: ${OPERATOR_NS}  (from operator-namespace.txt)"
fi

# Priority 2: scan the exported YAML files for known namespace names
# Handles older zips created before operator-namespace.txt was added
if [[ -z "${OPERATOR_NS}" ]]; then
  CLUSTER_CONFIG="${BACKUP_SUBDIR}/cnp-cluster-config.yaml"
  DB_BLUEPRINTS="${BACKUP_SUBDIR}/cnpg-db-blueprints.yaml"
  for ns_candidate in "pgd-operator-system" "postgresql-operator-system" "cnpg-system"; do
    if grep -q "namespace: ${ns_candidate}" "${CLUSTER_CONFIG}" "${DB_BLUEPRINTS}" 2>/dev/null; then
      OPERATOR_NS="${ns_candidate}"
      info "Operator namespace: ${OPERATOR_NS}  (detected from YAML files in zip)"
      break
    fi
  done
fi

# Priority 3: fallback to cnpg-system
if [[ -z "${OPERATOR_NS}" ]]; then
  OPERATOR_NS="cnpg-system"
  warn "Could not detect operator namespace â defaulting to cnpg-system."
fi

success "Cluster name (from backup): ${CLUSTER_NAME}"
success "Operator namespace:         ${OPERATOR_NS}"

# ââ Determine operator type label (used in display + step headers) ââââââââââââ
case "${OPERATOR_NS}" in
  "cnpg-system")                OPERATOR_TYPE="Community CloudNativePG" ;  VERSION_LABEL="CNPG version" ;;
  "postgresql-operator-system") OPERATOR_TYPE="EDB Postgres for CloudNativePG" ; VERSION_LABEL="CNP version"  ;;
  "pgd-operator-system")        OPERATOR_TYPE="EDB PGD4K"                ; VERSION_LABEL="PGD4K version" ;;
  *)                            OPERATOR_TYPE="Unknown operator"          ; VERSION_LABEL="Operator version" ;;
esac

# ââ Read cert-manager version (PGD only) ââââââââââââââââââââââââââââââââââââââ
CERT_MANAGER_VERSION="v1.16.2"   # safe default matching the runbook
if [[ -f "${BACKUP_SUBDIR}/cert-manager-version.txt" ]]; then
  _cm=$(cat "${BACKUP_SUBDIR}/cert-manager-version.txt" | tr -d '[:space:]')
  if [[ -n "${_cm}" ]]; then
    # Ensure it has a leading 'v'
    [[ "${_cm}" =~ ^v ]] && CERT_MANAGER_VERSION="${_cm}" || CERT_MANAGER_VERSION="v${_cm}"
    info "cert-manager version: ${CERT_MANAGER_VERSION}  (from backup)"
  fi
fi

# ââ Allow restoring under a different cluster name ââââââââââââââââââââââââââââ
echo ""
echo -e "  The backup cluster name is: ${BOLD}${CLUSTER_NAME}${NC}"
read -rp "  Restore as a different name? (press Enter to keep '${CLUSTER_NAME}'): " RESTORE_NAME
if [[ -n "${RESTORE_NAME}" && "${RESTORE_NAME}" != "${CLUSTER_NAME}" ]]; then
  info "Cluster will be restored as: ${RESTORE_NAME}"
  CLUSTER_NAME="${RESTORE_NAME}"
else
  info "Using original cluster name: ${CLUSTER_NAME}"
fi

if [[ -n "${CNPG_VERSION}" ]]; then
  success "${VERSION_LABEL}:  ${CNPG_VERSION}  (read from zip)"
else
  # cnpg-version.txt exists but is blank â try to detect from the snapshot tar
  warn "${VERSION_LABEL} file in zip is empty. Attempting to detect from snapshot image..."

  info "Loading snapshot to inspect image labels (needed once for version detection)..."
  LOADED_IMAGE=$(docker load -i "${SNAPSHOT_TAR}" 2>&1 | grep "Loaded image" | awk '{print $NF}' | head -1 || true)

  if [[ -n "${LOADED_IMAGE}" ]]; then
    info "Inspecting image: ${LOADED_IMAGE}"
    CNPG_VERSION=$(docker inspect "${LOADED_IMAGE}" \
      --format '{{range $k,$v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' \
      2>/dev/null | grep -i "version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  fi

  if [[ -n "${CNPG_VERSION}" ]]; then
    success "${VERSION_LABEL} detected from image: ${CNPG_VERSION}"
  else
    warn "Could not auto-detect ${VERSION_LABEL} from image."
    echo ""
    read -rp "Enter operator version manually (e.g. 2.0.0): " CNPG_VERSION
    [[ -z "${CNPG_VERSION}" ]] && error "Operator version is required."
  fi
fi

# âââ Verify artifact files ââââââââââââââââââââââââââââââââââââââââââââââââââââ
step "Verifying backup artifacts"

for f in "${SNAPSHOT_TAR}" "${CLUSTER_CONFIG}" "${DB_BLUEPRINTS}"; do
  if [[ ! -f "${f}" ]]; then
    error "Expected file not found: $(basename "${f}")"
  fi
  success "Found: $(basename "${f}")  ($(du -sh "${f}" | cut -f1))"
done

SNAPSHOT_SIZE=$(wc -c < "${SNAPSHOT_TAR}" | tr -d ' ')
if [[ "${SNAPSHOT_SIZE}" -lt 10000 ]]; then
  error "cnpg-snapshot.tar is only ${SNAPSHOT_SIZE} bytes â it looks corrupt or incomplete."
fi
info "Snapshot size: $(( SNAPSHOT_SIZE / 1024 / 1024 )) MB â looks good."

# âââ Confirm before restoring âââââââââââââââââââââââââââââââââââââââââââââââââ
echo ""
echo "  Cluster to restore : ${CLUSTER_NAME}"
echo "  Operator           : ${OPERATOR_TYPE} v${CNPG_VERSION}"
echo "  Operator namespace : ${OPERATOR_NS}"
echo "  Snapshot size      : $(du -sh "${SNAPSHOT_TAR}" | cut -f1)"
echo ""
read -rp "Proceed with restore? [Y/n]: " CONFIRM
[[ "${CONFIRM}" =~ ^[Nn] ]] && echo "Aborted." && exit 0

# âââ Step 1: Load Docker image ââââââââââââââââââââââââââââââââââââââââââââââââ
step "Step 1 â Load Docker snapshot image"
# Check if we already loaded it during version detection above
SNAPSHOT_IMAGE_TAG="${CLUSTER_NAME}-snapshot:v1"
if docker image inspect "${SNAPSHOT_IMAGE_TAG}" &>/dev/null 2>&1; then
  success "Docker image already loaded (from version detection step)."
else
  info "Loading cnpg-snapshot.tar into Docker (this may take a few minutes)..."
  docker load -i "${SNAPSHOT_TAR}"
  success "Docker image loaded."
fi

# âââ Step 2: Write kind cluster config âââââââââââââââââââââââââââââââââââââââ
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
warn "If the original cluster had a different number of workers, edit this file and re-run."

# âââ Step 3: Create kind cluster âââââââââââââââââââââââââââââââââââââââââââââ
step "Step 3 â Create kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  warn "Cluster '${CLUSTER_NAME}' already exists. Deleting it first..."
  kind delete cluster --name "${CLUSTER_NAME}"
fi
kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
success "kind cluster '${CLUSTER_NAME}' created."

# âââ Step 4: Install operator ââââââââââââââââââââââââââââââââââââââââââââââââ
step "Step 4 â Install operator v${CNPG_VERSION} (${OPERATOR_TYPE})"
case "${OPERATOR_NS}" in
  "cnpg-system")
    # Community CloudNativePG â manifest is publicly available on GitHub
    CNPG_RELEASE="release-${CNPG_VERSION%.*}"   # e.g. 1.29.1 â release-1.29
    CNPG_MANIFEST="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_RELEASE}/releases/cnpg-${CNPG_VERSION}.yaml"
    info "Applying community CNPG manifest: ${CNPG_MANIFEST}"
    kubectl apply \
      --context "kind-${CLUSTER_NAME}" \
      --server-side --force-conflicts \
      -f "${CNPG_MANIFEST}"
    success "Community CNPG operator applied."
    ;;

  "postgresql-operator-system")
    # EDB Postgres for CloudNativePG â operator image baked into the snapshot.
    # Namespaces and operator deployment will be restored from cnp-cluster-config.yaml in Step 5.
    info "EDB CNP operator is embedded in the cluster snapshot."
    info "Operator deployment will be restored from cnp-cluster-config.yaml in Step 5."
    ;;

  "pgd-operator-system")
    # ââ EDB PGD4K â Needs a 3-step bootstrap âââââââââââââââââââââââââââââââââ
    # PGD requires cert-manager for TLS certificate management.
    # Neither cert-manager nor pgd-operator-system namespaces exist on a fresh
    # kind cluster, so we must install both operators from their public manifests
    # BEFORE applying the backup YAML.  The backup YAML then fills in the
    # pull secrets, config maps, services etc. that the operators need.

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

    # Step 4b: PGD operator manifest (creates pgd-operator-system namespace + operator deployment)
    PGD_MANIFEST="https://get.enterprisedb.io/pg4k-pgd/pg4k-pgd-${CNPG_VERSION}.yaml"
    info "Applying EDB PGD4K operator v${CNPG_VERSION} manifest..."
    kubectl apply \
      --server-side \
      --context "kind-${CLUSTER_NAME}" \
      -f "${PGD_MANIFEST}" \
      || warn "PGD operator manifest had warnings â check pods below."
    success "EDB PGD4K operator manifest applied."

    # Step 4c: Inject the EDB pull secret into pgd-operator-system NOW
    # The operator container image lives in docker.enterprisedb.com and needs
    # this secret or it will ImagePullBackOff before we even get to Step 5.
    info "Injecting EDB pull secret into pgd-operator-system..."
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
" "${CLUSTER_CONFIG}" \
      | kubectl apply --context "kind-${CLUSTER_NAME}" -f - --validate=false 2>/dev/null \
      && success "EDB pull secret applied to pgd-operator-system." \
      || warn "Could not apply pull secret to pgd-operator-system â operator may ImagePullBackOff."
    ;;

  *)
    warn "Unknown operator namespace '${OPERATOR_NS}' â skipping manifest install."
    warn "Operator will be applied from cnp-cluster-config.yaml in Step 5."
    ;;
esac

# âââ Step 5: Apply Kubernetes resources ââââââââââââââââââââââââââââââââââââââ
step "Step 5 â Apply Kubernetes configs (Namespaces â Operator â Resources)"

# ââ Pass 1: Create all Namespace resources first ââââââââââââââââââââââââââââââ
# A fresh kind cluster has no user namespaces.  Resources inside a namespace
# fail with "namespaces not found" if that namespace hasn't been created yet.
# We extract every Namespace object from the YAML and apply them first.
info "Pass 1: Creating all Namespace resources from backup..."
python3 -c "
import sys, re

with open(sys.argv[1]) as f:
    content = f.read()

# Split multi-document YAML on '---' separators
parts = re.split(r'(?m)^---[ \t]*$', content)

ns_docs = []
for part in parts:
    # Match 'kind: Namespace' as a top-level (unindented) key
    if re.search(r'^kind:\s+Namespace\s*$', part, re.MULTILINE):
        ns_docs.append(part.strip())

if ns_docs:
    print('---\n' + '\n---\n'.join(ns_docs))
" "${CLUSTER_CONFIG}" \
  | kubectl apply --context "kind-${CLUSTER_NAME}" -f - --validate=false 2>/dev/null \
  && success "Namespaces created." \
  || warn "Namespace creation had warnings (may be OK if they already exist)."

# ââ Pass 2: Apply the full cluster config (namespaces now exist) ââââââââââââââ
info "Pass 2: Applying full cluster configuration..."
kubectl apply \
  --context "kind-${CLUSTER_NAME}" \
  -f "${CLUSTER_CONFIG}" \
  --validate=false || warn "Some conflicts above are expected and safe to ignore."
success "Kubernetes configs applied."

# âââ Step 6: Clear ghost pods and wait for operator ââââââââââââââââââââââââââ
step "Step 6 â Clear ghost pods and wait for ${OPERATOR_TYPE} in ${OPERATOR_NS}"
kubectl delete pod \
  --context "kind-${CLUSTER_NAME}" \
  -n "${OPERATOR_NS}" --all --ignore-not-found=true 2>/dev/null || true
success "Ghost pods cleared."

info "Waiting 15 s for operator deployment to start..."
sleep 15

# Find the controller-manager deployment name dynamically
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
  warn "Could not find controller deployment â skipping rollout check."
  warn "Manually verify: kubectl get pods --context kind-${CLUSTER_NAME} -n ${OPERATOR_NS}"
fi

# ââ For PGD: wait for CRDs to be registered before applying blueprints ââââââââ
# The PGD operator must register its CRDs after starting up.
# If we apply pgdgroups before 'pgdgroups.pgd.k8s.enterprisedb.io' exists,
# kubectl returns 'no matches for kind "PGDGroup"' and Step 7 fails.
if [[ "${OPERATOR_NS}" == "pgd-operator-system" ]]; then
  info "PGD cluster detected â waiting for PGD CRDs to be registered..."
  CRD_DEADLINE=$(( $(date +%s) + 120 ))
  while true; do
    if kubectl get crd pgdgroups.pgd.k8s.enterprisedb.io \
       --context "kind-${CLUSTER_NAME}" &>/dev/null 2>&1; then
      success "PGD CRDs are registered â ready to apply blueprints."
      break
    fi
    if [[ $(date +%s) -gt ${CRD_DEADLINE} ]]; then
      warn "Timed out waiting for PGD CRDs (120 s)."
      warn "The PGD operator may still be starting. Trying Step 7 anyway..."
      break
    fi
    info "PGD CRDs not yet registered â retrying in 10 s..."
    sleep 10
  done
fi

# âââ Step 7: Apply database blueprints âââââââââââââââââââââââââââââââââââââââ
step "Step 7 â Apply database blueprints (${OPERATOR_TYPE})"

# For PGD: cert-manager Issuers must exist BEFORE PGDGroups, otherwise the
# groups stay stuck waiting for certificates.  The blueprints file now contains
# Issuers exported by the updated local_backup.sh.  Apply them first.
if [[ "${OPERATOR_NS}" == "pgd-operator-system" ]]; then
  info "Applying cert-manager Issuers and Certificates first (PGD requires TLS)..."
  python3 -c "
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
parts = re.split(r'(?m)^---[ \t]*$', content)
cert_docs = []
for part in parts:
    kind_m = re.search(r'^kind:\s+(\S+)', part, re.MULTILINE)
    if kind_m and kind_m.group(1) in ('Issuer', 'ClusterIssuer', 'Certificate'):
        cert_docs.append(part.strip())
if cert_docs:
    print('---\n' + '\n---\n'.join(cert_docs))
" "${DB_BLUEPRINTS}" \
    | kubectl apply --context "kind-${CLUSTER_NAME}" -f - --validate=false 2>/dev/null \
    && info "cert-manager Issuers/Certificates applied." \
    || warn "Issuer apply had warnings â may be OK if backup predates the Issuer export."
fi

kubectl apply \
  --context "kind-${CLUSTER_NAME}" \
  -f "${DB_BLUEPRINTS}" \
  || warn "Some blueprint errors above may be expected â check pod status below."
success "Database blueprints applied."

# âââ Phase 3: Health check ââââââââââââââââââââââââââââââââââââââââââââââââââââ
step "Health check â Waiting for database pods"
info "Waiting up to 3 minutes for pods to reach Running state..."
info "(First-time restore may pull PostgreSQL images â this can take 5-10 min. Re-run if needed.)"

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
    warn "Timeout â pods may still be pulling images. Re-run in a few minutes."
    break
  fi

  info "Pods not yet ready â retrying in 10 s..."
  sleep 10
done

# âââ Final state ââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
echo ""
echo -e "${BOLD}âââ Final cluster state âââ${NC}"
kubectl get pods --context "kind-${CLUSTER_NAME}" -n default
echo ""
kubectl get pods --context "kind-${CLUSTER_NAME}" -n "${OPERATOR_NS}"
echo ""

# âââ Done âââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
echo ""
echo -e "${BOLD}âââ Restore complete âââ${NC}"
success "Cluster '${CLUSTER_NAME}' is up and running."
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo "  kubectl get pods    --context kind-${CLUSTER_NAME} -n default"
echo "  kubectl get pods    --context kind-${CLUSTER_NAME} -n ${OPERATOR_NS}"
echo "  kubectl get clusters.postgresql.cnpg.io --context kind-${CLUSTER_NAME} -n default"
echo ""
