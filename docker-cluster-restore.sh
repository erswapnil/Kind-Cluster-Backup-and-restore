#!/usr/bin/env bash
# =============================================================================
# docker-cluster-restore.sh
# Restores a kind cluster (CNPG / EDB CNP / EDB PGD4K) from a PUBLIC GitHub repo.
#
# Compatible with macOS default bash 3.2+
# No GitHub token required — reads from any public repo.
#
# Cluster types supported:
#   cnpg-system               → Community CloudNativePG (CNPG)
#   postgresql-operator-system → EDB Postgres for CloudNativePG (CNP)
#   pgd-operator-system       → EDB Postgres Distributed (PGD4K / Global Cluster)
#
# Usage:
#   chmod +x docker-cluster-restore.sh && ./docker-cluster-restore.sh
#
# What it asks you:
#   1. GitHub username + repo name (defaults pre-filled, just press Enter)
#   2. Which cluster to restore — shows live list of folders from GitHub
#
# What it does automatically:
#   - Lists all cluster backup folders in the GitHub repo via API
#   - Shows table: cluster name, snapshot status, K8s config, DB blueprints
#   - Clones the repo with git-lfs (downloads the snapshot tar)
#   - Auto-detects operator type + version from backup metadata
#   - Loads Docker snapshot, creates fresh kind cluster
#   - Installs the correct operator (CNPG / CNP / PGD4K)
#   - Applies K8s configs and DB blueprints
#   - Waits for all pods to be Running
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
  [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]] && { info "Cleaning up working directory..."; rm -rf "${WORK_DIR}"; }
}
trap cleanup EXIT

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║       GitHub → Kind Cluster Restore Tool                    ║${NC}"
echo -e "${BOLD}${CYAN}║    (CNPG / EDB CNP / EDB PGD4K  ·  no token required)      ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Pre-flight ────────────────────────────────────────────────────────────────
step "Pre-flight checks"
for cmd in curl python3 docker kind kubectl git; do
  command -v "$cmd" &>/dev/null || error "$cmd not found. Install it first."
done
docker info &>/dev/null 2>&1 || error "Docker Desktop is not running. Start it first."

# Install git-lfs if needed (required to download snapshot tar from LFS)
if ! git lfs version &>/dev/null 2>&1; then
  warn "git-lfs not found. Installing via Homebrew..."
  if command -v brew &>/dev/null; then
    brew install git-lfs
    git lfs install --system
    success "git-lfs installed."
  else
    error "git-lfs is required but not installed. Install it from: https://git-lfs.com"
  fi
fi
success "All pre-flight checks passed."

# ── Step 1: GitHub repo details ───────────────────────────────────────────────
step "Step 1 · GitHub repo details"

read -rp "GitHub username (repo owner) [erswapnil]: " GITHUB_USER
GITHUB_USER="${GITHUB_USER:-erswapnil}"
read -rp "GitHub repo name [Kind-Cluster-Backup-and-restore]: " GITHUB_REPO
GITHUB_REPO="${GITHUB_REPO:-Kind-Cluster-Backup-and-restore}"

echo ""
info "Verifying repo is accessible..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}")
if [[ "${HTTP_CODE}" != "200" ]]; then
  error "Repo '${GITHUB_USER}/${GITHUB_REPO}' not found or not public (HTTP ${HTTP_CODE})."
fi
success "Repo ${GITHUB_USER}/${GITHUB_REPO} is accessible."

# ── Step 2: List available clusters from GitHub ───────────────────────────────
step "Step 2 · Available clusters in GitHub repo"

info "Fetching cluster folder list..."
CONTENTS=$(curl -s \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}/contents/")

CLUSTER_LIST=$(echo "${CONTENTS}" | python3 -c "
import sys, json
items = json.load(sys.stdin)
folders = [i['name'] for i in items if i['type'] == 'dir']
for f in folders:
    print(f)
" 2>/dev/null || true)

if [[ -z "${CLUSTER_LIST}" ]]; then
  error "No cluster folders found in ${GITHUB_USER}/${GITHUB_REPO}. Run docker-cluster-backup.sh first."
fi

echo ""
printf "  ${BOLD}%-4s %-25s %-12s %-22s %s${NC}\n" "#" "CLUSTER NAME" "SNAPSHOT" "K8S CONFIG" "DB BLUEPRINTS"
echo "  ─────────────────────────────────────────────────────────────────────────────"

# macOS bash 3.2 compatible — no mapfile
CLUSTERS=()
while IFS= read -r line; do
  [[ -n "${line}" ]] && CLUSTERS+=("${line}")
done <<< "${CLUSTER_LIST}"

VALID_CLUSTERS=()

for i in "${!CLUSTERS[@]}"; do
  FOLDER="${CLUSTERS[$i]}"
  FILES=$(curl -s \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}/contents/${FOLDER}" \
    | python3 -c "
import sys, json
try:
    items = json.load(sys.stdin)
    names = {i['name'] for i in items if i['type'] == 'file'}
    # Also detect operator type from operator-namespace.txt if present
    op = ''
    for item in items:
        if item['name'] == 'operator-namespace.txt':
            import urllib.request
            try:
                url = item.get('download_url', '')
                if url:
                    resp = urllib.request.urlopen(url, timeout=5)
                    op = resp.read().decode().strip()
            except:
                pass
    op_label = {'cnpg-system': 'CNPG', 'postgresql-operator-system': 'EDB-CNP', 'pgd-operator-system': 'PGD4K'}.get(op, op or '?')
    tar = 'yes' if 'cnpg-snapshot.tar.gz' in names else 'missing'
    cfg = 'yes (' + op_label + ')' if 'cnp-cluster-config.yaml' in names else 'missing'
    bp  = 'yes' if 'cnpg-db-blueprints.yaml' in names else 'missing'
    print(tar + '|' + cfg + '|' + bp)
except:
    print('error|error|error')
" 2>/dev/null)

  TAR_STATUS=$(echo "${FILES}" | cut -d'|' -f1)
  CFG_STATUS=$(echo "${FILES}" | cut -d'|' -f2)
  BP_STATUS=$(echo "${FILES}"  | cut -d'|' -f3)

  if [[ "${TAR_STATUS}" == "yes" ]]; then
    VALID_CLUSTERS+=("${FOLDER}")
    NUM="${#VALID_CLUSTERS[@]}"
    printf "  ${BOLD}%-4s${NC} ${GREEN}%-25s${NC} %-12s %-22s %s\n" \
      "${NUM}" "${FOLDER}" "${TAR_STATUS}" "${CFG_STATUS}" "${BP_STATUS}"
  else
    printf "  ${BOLD}%-4s${NC} ${YELLOW}%-25s${NC} %-12s %-22s %s ${RED}(incomplete — skipped)${NC}\n" \
      "-" "${FOLDER}" "${TAR_STATUS}" "${CFG_STATUS}" "${BP_STATUS}"
  fi
done
echo ""

if [[ ${#VALID_CLUSTERS[@]} -eq 0 ]]; then
  error "No valid cluster backups found (cnpg-snapshot.tar.gz missing in all folders)."
fi

while true; do
  read -rp "$(echo -e "${BOLD}Select cluster to restore [1-${#VALID_CLUSTERS[@]}]: ${NC}")" PICK
  if [[ "${PICK}" =~ ^[0-9]+$ ]] && (( PICK >= 1 && PICK <= ${#VALID_CLUSTERS[@]} )); then
    CLUSTER_FOLDER="${VALID_CLUSTERS[$((PICK-1))]}"
    break
  fi
  warn "Invalid. Enter a number between 1 and ${#VALID_CLUSTERS[@]}."
done

success "Selected: ${CLUSTER_FOLDER}"

# ── Step 3: Clone repo to download backup files ───────────────────────────────
step "Step 3 · Download backup files from GitHub  (git clone + LFS)"

GIT_REPO="https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git"
WORK_DIR="$(mktemp -d -t kind-restore-XXXXXX)"

info "Cloning repo (skipping LFS for speed)..."
GIT_LFS_SKIP_SMUDGE=1 git clone --depth=1 "${GIT_REPO}" "${WORK_DIR}/repo"
success "Repo cloned."

info "Downloading snapshot file via LFS (${CLUSTER_FOLDER}/cnpg-snapshot.tar.gz — may take several minutes)..."
git -C "${WORK_DIR}/repo" config lfs.fetchrecentrefsdays 0
git -C "${WORK_DIR}/repo" config http.lowSpeedLimit 1000
git -C "${WORK_DIR}/repo" config http.lowSpeedTime 600

LFS_OK=false
for lfs_attempt in 1 2 3; do
  if git -C "${WORK_DIR}/repo" lfs pull --include="${CLUSTER_FOLDER}/cnpg-snapshot.tar.gz" 2>&1; then
    LFS_OK=true
    break
  fi
  warn "LFS download attempt ${lfs_attempt}/3 failed. Retrying in 10s..."
  sleep 10
done
[[ "${LFS_OK}" == "true" ]] || error "Failed to download snapshot after 3 attempts. Check your network connection."
success "Snapshot downloaded."

BACKUP_SUBDIR="${WORK_DIR}/repo/${CLUSTER_FOLDER}"
if [[ ! -d "${BACKUP_SUBDIR}" ]]; then
  error "Folder '${CLUSTER_FOLDER}' not found after clone — unexpected error."
fi

# Artifact file paths
SNAPSHOT_TAR="${BACKUP_SUBDIR}/cnpg-snapshot.tar.gz"
CLUSTER_CONFIG="${BACKUP_SUBDIR}/cnp-cluster-config.yaml"
DB_BLUEPRINTS="${BACKUP_SUBDIR}/cnpg-db-blueprints.yaml"

# ── Step 4: Read cluster metadata ─────────────────────────────────────────────
step "Step 4 · Reading cluster metadata"

# Cluster name defaults to folder name
CLUSTER_NAME="${CLUSTER_FOLDER}"
CNPG_VERSION=""
OPERATOR_NS=""

# Priority 1: metadata files written by docker-cluster-backup.sh
if [[ -f "${BACKUP_SUBDIR}/cnpg-version.txt" ]]; then
  CNPG_VERSION=$(cat "${BACKUP_SUBDIR}/cnpg-version.txt" | tr -d '[:space:]')
fi
if [[ -f "${BACKUP_SUBDIR}/operator-namespace.txt" ]]; then
  OPERATOR_NS=$(cat "${BACKUP_SUBDIR}/operator-namespace.txt" | tr -d '[:space:]')
  info "Operator namespace: ${OPERATOR_NS} (from operator-namespace.txt)"
fi

# Priority 2: scan YAML files for known operator namespaces (for older backups without metadata)
if [[ -z "${OPERATOR_NS}" ]]; then
  # Check PGD first (most specific), then EDB CNP, then community CNPG
  for ns_candidate in "pgd-operator-system" "postgresql-operator-system" "cnpg-system"; do
    if grep -q "namespace: ${ns_candidate}" "${CLUSTER_CONFIG}" "${DB_BLUEPRINTS}" 2>/dev/null; then
      OPERATOR_NS="${ns_candidate}"
      info "Operator namespace: ${OPERATOR_NS} (detected from YAML files)"
      break
    fi
  done
fi

# Priority 3: fallback default
if [[ -z "${OPERATOR_NS}" ]]; then
  OPERATOR_NS="cnpg-system"
  warn "Could not detect operator namespace — defaulting to cnpg-system."
fi

# Determine operator type and version label for display messages
case "${OPERATOR_NS}" in
  "cnpg-system")
    OPERATOR_TYPE="Community CloudNativePG (CNPG)"
    VERSION_LABEL="CNPG version"
    ;;
  "postgresql-operator-system")
    OPERATOR_TYPE="EDB Postgres for CloudNativePG (CNP)"
    VERSION_LABEL="CNP version"
    ;;
  "pgd-operator-system")
    OPERATOR_TYPE="EDB Postgres Distributed / Global Cluster (PGD4K)"
    VERSION_LABEL="PGD4K version"
    ;;
  *)
    OPERATOR_TYPE="Unknown operator"
    VERSION_LABEL="Operator version"
    ;;
esac

# cert-manager version (only matters for PGD4K; safe default used if not in metadata)
CERT_MANAGER_VERSION="v1.16.2"
if [[ -f "${BACKUP_SUBDIR}/cert-manager-version.txt" ]]; then
  _cm=$(cat "${BACKUP_SUBDIR}/cert-manager-version.txt" | tr -d '[:space:]')
  if [[ -n "${_cm}" ]]; then
    [[ "${_cm}" =~ ^v ]] && CERT_MANAGER_VERSION="${_cm}" || CERT_MANAGER_VERSION="v${_cm}"
    info "cert-manager version: ${CERT_MANAGER_VERSION} (from backup)"
  fi
fi

success "Cluster name  : ${CLUSTER_NAME}"
success "Operator      : ${OPERATOR_TYPE}"
success "Op namespace  : ${OPERATOR_NS}"

# Allow restoring under a different cluster name
echo ""
echo -e "  The backup cluster name is: ${BOLD}${CLUSTER_NAME}${NC}"
read -rp "  Restore as a different name? (press Enter to keep '${CLUSTER_NAME}'): " RESTORE_NAME
if [[ -n "${RESTORE_NAME}" && "${RESTORE_NAME}" != "${CLUSTER_NAME}" ]]; then
  info "Cluster will be restored as: ${RESTORE_NAME}"
  CLUSTER_NAME="${RESTORE_NAME}"
else
  info "Using cluster name: ${CLUSTER_NAME}"
fi

# Handle operator version
if [[ -n "${CNPG_VERSION}" ]]; then
  success "${VERSION_LABEL}: ${CNPG_VERSION} (from backup metadata)"
else
  warn "${VERSION_LABEL} not found in backup metadata. Attempting detection from snapshot image..."
  info "Loading snapshot to inspect image labels..."
  LOADED_IMAGE=$(gzip -dc "${SNAPSHOT_TAR}" | docker load 2>&1 | grep "Loaded image" | awk '{print $NF}' | head -1 || true)
  if [[ -n "${LOADED_IMAGE}" ]]; then
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

# ── Verify artifacts ──────────────────────────────────────────────────────────
step "Verifying backup artifacts"
for f in "${SNAPSHOT_TAR}" "${CLUSTER_CONFIG}" "${DB_BLUEPRINTS}"; do
  if [[ ! -f "${f}" ]]; then
    error "Expected file not found: $(basename "${f}")"
  fi
  success "Found: $(basename "${f}")  ($(du -sh "${f}" | cut -f1))"
done

SNAPSHOT_SIZE=$(wc -c < "${SNAPSHOT_TAR}" | tr -d ' ')
if [[ "${SNAPSHOT_SIZE}" -lt 10000 ]]; then
  error "cnpg-snapshot.tar.gz is only ${SNAPSHOT_SIZE} bytes — looks corrupt or a bare LFS pointer (git-lfs may not have run)."
fi
info "Snapshot size: $(( SNAPSHOT_SIZE / 1024 / 1024 )) MB — looks good."

# ── Confirm ───────────────────────────────────────────────────────────────────
echo ""
echo -e "  Cluster to restore : ${BOLD}${CLUSTER_NAME}${NC}"
echo -e "  Operator           : ${OPERATOR_TYPE}"
echo -e "  Version            : v${CNPG_VERSION}"
echo -e "  Operator namespace : ${OPERATOR_NS}"
echo -e "  Snapshot size      : $(du -sh "${SNAPSHOT_TAR}" | cut -f1)"
echo ""

# Check for existing kind cluster with same name
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  warn "A kind cluster named '${CLUSTER_NAME}' already exists on this machine!"
  echo ""
  echo -e "  ${BOLD}1${NC} Delete it and restore fresh"
  echo -e "  ${BOLD}2${NC} Abort and keep existing cluster"
  echo ""
  read -rp "Choose [1/2]: " CONFLICT_CHOICE
  case "${CONFLICT_CHOICE}" in
    1)
      info "Deleting existing cluster '${CLUSTER_NAME}'..."
      kind delete cluster --name "${CLUSTER_NAME}"
      success "Deleted."
      ;;
    *)
      info "Aborted. Existing cluster preserved."
      exit 0
      ;;
  esac
fi

read -rp "Start restore? [Y/n]: " GO
GO="${GO:-Y}"
[[ "${GO}" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

# ── Step 5: Load Docker image ─────────────────────────────────────────────────
step "Step 5 · Load Docker snapshot image"
SNAPSHOT_IMAGE_TAG="${CLUSTER_NAME}-snapshot:v1"
if docker image inspect "${SNAPSHOT_IMAGE_TAG}" &>/dev/null 2>&1; then
  success "Docker image already loaded (from version detection step)."
else
  info "Loading cnpg-snapshot.tar.gz into Docker (decompressing + loading, may take a few minutes)..."
  gzip -dc "${SNAPSHOT_TAR}" | docker load
  success "Docker image loaded."
fi

# ── Step 6: Create kind cluster ───────────────────────────────────────────────
step "Step 6 · Create kind cluster '${CLUSTER_NAME}'"
KIND_CONFIG="${WORK_DIR}/kind-config.yaml"
cat <<EOF > "${KIND_CONFIG}"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
EOF
success "kind-config.yaml written."
warn "If the original cluster had a different number of workers, edit kind-config.yaml and re-run."

kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
CONTEXT="kind-${CLUSTER_NAME}"
success "kind cluster '${CLUSTER_NAME}' created."

# ── Step 7: Install operator ──────────────────────────────────────────────────
step "Step 7 · Install operator v${CNPG_VERSION}  (${OPERATOR_TYPE})"

case "${OPERATOR_NS}" in

  "cnpg-system")
    # ── Community CloudNativePG ───────────────────────────────────────────────
    # Manifest is publicly available on GitHub. We derive the release branch
    # from the major.minor part of the version (e.g. 1.29.1 → release-1.29).
    CNPG_RELEASE="release-${CNPG_VERSION%.*}"
    CNPG_MANIFEST="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_RELEASE}/releases/cnpg-${CNPG_VERSION}.yaml"
    info "Applying community CNPG manifest: ${CNPG_MANIFEST}"
    kubectl apply \
      --context "kind-${CLUSTER_NAME}" \
      --server-side --force-conflicts \
      -f "${CNPG_MANIFEST}"
    success "Community CNPG operator v${CNPG_VERSION} applied."
    ;;

  "postgresql-operator-system")
    # ── EDB Postgres for CloudNativePG (CNP) ─────────────────────────────────
    # The EDB CNP operator image is baked into the Docker snapshot (containerd cache).
    # We create the namespace first so that when cnp-cluster-config.yaml is applied
    # in Step 8, the operator deployment can be created successfully.
    info "Creating postgresql-operator-system namespace..."
    kubectl create namespace postgresql-operator-system \
      --context "${CONTEXT}" 2>/dev/null || true
    success "Namespace postgresql-operator-system ready."
    info "EDB CNP operator deployment will be restored from cnp-cluster-config.yaml in Step 8."
    ;;

  "pgd-operator-system")
    # ── EDB Postgres Distributed / Global Cluster (PGD4K) ────────────────────
    # PGD requires cert-manager for TLS + the PGD operator manifest bootstrapped
    # BEFORE the backup YAML is applied. The backup YAML then fills in pull secrets,
    # config maps, services etc. that the operators need to function.

    # Step 7a: cert-manager (creates cert-manager namespace + CRDs)
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
      2>/dev/null || warn "cert-manager pods not fully Ready yet — continuing anyway."
    success "cert-manager ${CERT_MANAGER_VERSION} installed."

    # Step 7b: PGD operator manifest (creates pgd-operator-system namespace + operator deployment)
    PGD_MANIFEST="https://get.enterprisedb.io/pg4k-pgd/pg4k-pgd-${CNPG_VERSION}.yaml"
    info "Applying EDB PGD4K operator v${CNPG_VERSION} manifest: ${PGD_MANIFEST}"
    kubectl apply \
      --server-side \
      --context "kind-${CLUSTER_NAME}" \
      -f "${PGD_MANIFEST}" \
      || warn "PGD operator manifest had warnings — check pods below."
    success "EDB PGD4K operator manifest applied."

    # Step 7c: Inject EDB pull secret into pgd-operator-system NOW so the operator
    # container can pull its image from docker.enterprisedb.com without ImagePullBackOff.
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
    || warn "Could not apply pull secret — operator may ImagePullBackOff."
    ;;

  *)
    warn "Unknown operator namespace '${OPERATOR_NS}' — skipping manifest install."
    warn "Operator will be restored from cnp-cluster-config.yaml in Step 8."
    ;;
esac

# ── Step 8: Apply Kubernetes resources ───────────────────────────────────────
step "Step 8 · Apply Kubernetes configs  (Namespaces first → full cluster config)"

# Pass 1: Create all Namespace objects first.
# A fresh kind cluster has no user namespaces. Resources inside a namespace
# fail with "namespaces not found" if that namespace does not exist yet.
info "Pass 1: Creating all Namespace resources from backup..."
python3 -c "
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
parts = re.split(r'(?m)^---[ \t]*$', content)
ns_docs = []
for part in parts:
    if re.search(r'^kind:\s+Namespace\s*$', part, re.MULTILINE):
        ns_docs.append(part.strip())
if ns_docs:
    print('---\n' + '\n---\n'.join(ns_docs))
" "${CLUSTER_CONFIG}" \
| kubectl apply --context "kind-${CLUSTER_NAME}" -f - --validate=false 2>/dev/null \
&& success "Namespaces created." \
|| warn "Namespace creation had warnings (may be OK if they already exist)."

# Pass 2: Apply full cluster configuration (namespaces now exist)
info "Pass 2: Applying full cluster configuration..."
kubectl apply \
  --context "kind-${CLUSTER_NAME}" \
  -f "${CLUSTER_CONFIG}" \
  --validate=false || warn "Some conflicts above are expected and safe to ignore."
success "Kubernetes configs applied."

# ── Step 9: Wait for operator ─────────────────────────────────────────────────
step "Step 9 · Wait for ${OPERATOR_TYPE} to be ready  (${OPERATOR_NS})"

kubectl delete pod \
  --context "kind-${CLUSTER_NAME}" \
  -n "${OPERATOR_NS}" --all --ignore-not-found=true 2>/dev/null || true
success "Ghost pods cleared."

info "Waiting 30 s for operator deployment to start..."
sleep 30

# Find controller-manager / operator deployment dynamically
CTRL_DEPLOY=$(kubectl get deployment -n "${OPERATOR_NS}" \
  --context "kind-${CLUSTER_NAME}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -i -E "controller-manager|operator" | head -1 || true)

if [[ -n "${CTRL_DEPLOY}" ]]; then
  kubectl rollout status "deployment/${CTRL_DEPLOY}" \
    --context "kind-${CLUSTER_NAME}" \
    -n "${OPERATOR_NS}" \
    --timeout=180s \
    || warn "Operator rollout timeout — check: kubectl get pods -n ${OPERATOR_NS} --context kind-${CLUSTER_NAME}"
else
  warn "Could not find controller deployment — skipping rollout check."
  warn "Verify manually: kubectl get pods --context kind-${CLUSTER_NAME} -n ${OPERATOR_NS}"
fi

# PGD4K: wait for CRDs to be registered before applying blueprints.
# The PGD operator registers pgdgroups.pgd.k8s.enterprisedb.io only after startup.
# Applying PGDGroup objects before the CRD exists causes "no matches for kind PGDGroup".
if [[ "${OPERATOR_NS}" == "pgd-operator-system" ]]; then
  info "PGD4K cluster — waiting for PGD CRDs to be registered (up to 120 s)..."
  CRD_DEADLINE=$(( $(date +%s) + 120 ))
  while true; do
    if kubectl get crd pgdgroups.pgd.k8s.enterprisedb.io \
      --context "kind-${CLUSTER_NAME}" &>/dev/null 2>&1; then
      success "PGD CRDs registered — ready to apply blueprints."
      break
    fi
    if [[ $(date +%s) -gt ${CRD_DEADLINE} ]]; then
      warn "Timed out waiting for PGD CRDs. Attempting Step 10 anyway..."
      break
    fi
    info "PGD CRDs not yet registered — retrying in 10 s..."
    sleep 10
  done
fi

# ── Step 10: Apply database blueprints ────────────────────────────────────────
step "Step 10 · Apply database blueprints  (${OPERATOR_TYPE})"

# PGD4K: cert-manager Issuers must exist before PGDGroups can provision TLS.
# Blueprints file contains Issuers exported by docker-cluster-backup.sh.
if [[ "${OPERATOR_NS}" == "pgd-operator-system" ]]; then
  info "Applying cert-manager Issuers/Certificates first (PGD4K requires TLS)..."
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
  || warn "Issuer apply had warnings — may be OK if backup predates Issuer export."
fi

kubectl apply \
  --context "kind-${CLUSTER_NAME}" \
  -f "${DB_BLUEPRINTS}" \
  || warn "Some blueprint errors may be expected — check pod status below."
success "Database blueprints applied."

# ── Health check ──────────────────────────────────────────────────────────────
step "Health check — Waiting for database pods"
info "Waiting up to 3 minutes for pods in 'default' namespace to reach Running state..."
info "(First-time restore may pull PostgreSQL images — this can take 5-10 min. Re-run if needed.)"

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
    warn "Timeout — pods may still be pulling images. Re-run in a few minutes."
    break
  fi
  info "Pods not yet ready — retrying in 10 s..."
  sleep 10
done

# ── Final state ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}─── Final cluster state ───${NC}"
kubectl get pods --context "kind-${CLUSTER_NAME}" -n default 2>/dev/null || true
echo ""
kubectl get pods --context "kind-${CLUSTER_NAME}" -n "${OPERATOR_NS}" 2>/dev/null || true
echo ""

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║  Restore complete!                                           ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
success "Cluster '${CLUSTER_NAME}' is up and running."
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo "  kubectl get pods --context kind-${CLUSTER_NAME} -n default"
echo "  kubectl get pods --context kind-${CLUSTER_NAME} -n ${OPERATOR_NS}"
echo "  kubectl get clusters.postgresql.cnpg.io --context kind-${CLUSTER_NAME} -n default"
echo ""
