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

# Find control-plane container (must be RUNNING, not just stopped)
CONTAINER_ID=$(docker ps \
  --filter "name=${CLUSTER_NAME}-control-plane" \
  --filter "status=running" \
  --format "{{.ID}}" | head -1)

if [[ -z "${CONTAINER_ID}" ]]; then
  # Check if it exists but is stopped
  STOPPED_ID=$(docker ps -a \
    --filter "name=${CLUSTER_NAME}-control-plane" \
    --format "{{.ID}}" | head -1)
  if [[ -n "${STOPPED_ID}" ]]; then
    echo ""
    warn "Cluster '${CLUSTER_NAME}' container exists but is STOPPED."
    echo ""
    echo "  Start it with:"
    echo "    docker start ${CLUSTER_NAME}-control-plane"
    echo "    sleep 20 && kubectl get nodes --context kind-${CLUSTER_NAME}"
    echo ""
    error "Start the cluster first, then re-run this backup script."
  else
    error "Control-plane container for '${CLUSTER_NAME}' not found. Is the cluster running?"
  fi
fi
success "Control-plane container: ${CONTAINER_ID} (running)"

# ── Step 2: Auto-detect operator and version ──────────────────────────────────
step "Step 2 · Auto-detecting operator (CNPG / EDB CNP / PGD4K)"

CNPG_VERSION=""
OPERATOR_NS=""
OPERATOR_TYPE=""
OPERATOR_IMAGE=""

# ── Method 1: CRD-based detection (most reliable — CRDs always present) ──────
info "Detecting operator type via CRDs..."

if kubectl get crd clusters.postgresql.cnpg.io --context "${CONTEXT}" &>/dev/null 2>&1; then
  OPERATOR_NS="cnpg-system"
  OPERATOR_TYPE="Community CloudNativePG"
elif kubectl get crd clusters.postgresql.k8s.enterprisedb.io --context "${CONTEXT}" &>/dev/null 2>&1; then
  OPERATOR_NS="postgresql-operator-system"
  OPERATOR_TYPE="EDB Postgres for CloudNativePG (CNP)"
elif kubectl get crd pgdgroups.pgd.k8s.enterprisedb.io --context "${CONTEXT}" &>/dev/null 2>&1; then
  OPERATOR_NS="pgd-operator-system"
  OPERATOR_TYPE="EDB Postgres Distributed (PGD4K)"
fi

# ── Method 2: Extract version from operator pod images ────────────────────────
if [[ -n "${OPERATOR_NS}" ]]; then
  info "Operator namespace detected: ${OPERATOR_NS}"
  info "Extracting version from operator pods..."

  # Get all images from pods in the operator namespace (one image per line)
  ALL_IMAGES=$(kubectl get pods -n "${OPERATOR_NS}" --context "${CONTEXT}" \
    -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
    2>/dev/null | grep -v "^$" || true)

  # Prefer the operator-specific image (skip sidecars like kube-rbac-proxy)
  OPERATOR_IMAGE=$(echo "${ALL_IMAGES}" \
    | grep -i -E "edb-postgres-for-cloudnativepg|cloudnative-pg|cloud-native-pg|cnpg|pgd|enterprisedb" \
    | head -1 || true)

  # Fallback: use any image that has a semver tag
  if [[ -z "${OPERATOR_IMAGE}" ]]; then
    OPERATOR_IMAGE=$(echo "${ALL_IMAGES}" \
      | grep -oE '^[^:]+:[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  fi

  # Extract version from the chosen image
  if [[ -n "${OPERATOR_IMAGE}" ]]; then
    CNPG_VERSION=$(echo "${OPERATOR_IMAGE}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  fi

  # If pods gave nothing, try deployment spec (image may not be running yet)
  if [[ -z "${CNPG_VERSION}" ]]; then
    info "No running pods found — checking deployment spec..."
    ALL_IMAGES=$(kubectl get deployment -n "${OPERATOR_NS}" --context "${CONTEXT}" \
      -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}' \
      2>/dev/null | grep -v "^$" || true)
    OPERATOR_IMAGE=$(echo "${ALL_IMAGES}" \
      | grep -i -E "edb-postgres-for-cloudnativepg|cloudnative-pg|cloud-native-pg|cnpg|pgd|enterprisedb" \
      | head -1 || true)
    if [[ -z "${OPERATOR_IMAGE}" ]]; then
      OPERATOR_IMAGE=$(echo "${ALL_IMAGES}" | head -1 || true)
    fi
    [[ -n "${OPERATOR_IMAGE}" ]] && \
      CNPG_VERSION=$(echo "${OPERATOR_IMAGE}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  fi
fi

# ── Method 3: Fallback — scan all namespaces if CRD detection missed ──────────
if [[ -z "${OPERATOR_NS}" ]]; then
  info "CRD check inconclusive — scanning all namespaces..."
  while IFS= read -r line; do
    ns=$(echo "${line}" | awk '{print $1}')
    img=$(echo "${line}" | awk '{print $2}')
    ver=$(echo "${img}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    if [[ -n "${ver}" ]]; then
      CNPG_VERSION="${ver}"
      OPERATOR_NS="${ns}"
      OPERATOR_IMAGE="${img}"
      break
    fi
  done < <(kubectl get pods --all-namespaces --context "${CONTEXT}" \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.spec.containers[*].image}{"\n"}{end}' \
    2>/dev/null \
    | grep -i -E "cloudnative-pg|cloud-native-pg|edb-postgres-for-cloudnativepg|edb-postgres-for-cloudnativepg-global-cluster|enterprisedb|cnpg|pgd|barman" \
    || true)
  if [[ -n "${OPERATOR_NS}" ]]; then
    case "${OPERATOR_NS}" in
      "cnpg-system")                 OPERATOR_TYPE="Community CloudNativePG" ;;
      "postgresql-operator-system")  OPERATOR_TYPE="EDB Postgres for CloudNativePG (CNP)" ;;
      "pgd-operator-system")         OPERATOR_TYPE="EDB Postgres Distributed (PGD4K)" ;;
      *)                             OPERATOR_TYPE="Unknown operator" ;;
    esac
  fi
fi

# ── Results ───────────────────────────────────────────────────────────────────
if [[ -n "${OPERATOR_NS}" && -n "${CNPG_VERSION}" ]]; then
  success "Operator   : ${OPERATOR_TYPE}"
  success "Namespace  : ${OPERATOR_NS}"
  success "Version    : ${CNPG_VERSION}"
  [[ -n "${OPERATOR_IMAGE}" ]] && info "Image      : ${OPERATOR_IMAGE}"
elif [[ -n "${OPERATOR_NS}" && -z "${CNPG_VERSION}" ]]; then
  # Operator type known but version not found — just ask for version
  success "Operator   : ${OPERATOR_TYPE}"
  success "Namespace  : ${OPERATOR_NS}"
  warn "Could not extract version from operator images."
  echo ""
  read -rp "  Enter operator version (e.g. 1.28.0): " CNPG_VERSION
  [[ -z "${CNPG_VERSION}" ]] && error "Operator version is required."
  success "Version    : ${CNPG_VERSION}"
else
  # Nothing found at all — ask for everything
  warn "Could not auto-detect operator. Manual input required."
  echo ""
  echo "  Select operator type:"
  echo "    1) Community CloudNativePG         (namespace: cnpg-system)"
  echo "    2) EDB Postgres for Kubernetes/CNP (namespace: postgresql-operator-system)"
  echo "    3) EDB Postgres Distributed PGD4K  (namespace: pgd-operator-system)"
  echo ""
  while true; do
    read -rp "  Enter 1, 2, or 3: " OP_CHOICE
    case "${OP_CHOICE}" in
      1) OPERATOR_NS="cnpg-system";               OPERATOR_TYPE="Community CloudNativePG";               break ;;
      2) OPERATOR_NS="postgresql-operator-system"; OPERATOR_TYPE="EDB Postgres for CloudNativePG (CNP)"; break ;;
      3) OPERATOR_NS="pgd-operator-system";        OPERATOR_TYPE="EDB Postgres Distributed (PGD4K)";     break ;;
      *) warn "Enter 1, 2, or 3." ;;
    esac
  done
  echo ""
  read -rp "  Enter operator version (e.g. 1.28.0): " CNPG_VERSION
  [[ -z "${CNPG_VERSION}" ]] && error "Operator version is required."
  success "Operator   : ${OPERATOR_TYPE}"
  success "Namespace  : ${OPERATOR_NS}"
  success "Version    : ${CNPG_VERSION}"
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
# --pause=false keeps the API server running during commit so Step 5 kubectl works
docker commit --pause=false "${CONTAINER_ID}" "${CLUSTER_NAME}-snapshot:v1"
info "docker save → cnpg-snapshot.tar.gz  (compressing with gzip — may take a few minutes)..."
docker save "${CLUSTER_NAME}-snapshot:v1" | gzip > "${WORK_DIR}/cnpg-snapshot.tar.gz"
success "Snapshot saved: $(du -sh "${WORK_DIR}/cnpg-snapshot.tar.gz" | cut -f1)  (compressed)"

# Wait for API server to be responsive before kubectl export
info "Waiting for Kubernetes API server to be ready..."
API_READY=0
for i in $(seq 1 30); do
  if kubectl --context "${CONTEXT}" get nodes &>/dev/null 2>&1; then
    API_READY=1
    break
  fi
  sleep 2
done
if [[ "${API_READY}" -eq 0 ]]; then
  warn "API server not responding after 60s — trying to restart kind cluster networking..."
  docker restart "${CONTAINER_ID}" &>/dev/null || true
  sleep 10
  for i in $(seq 1 15); do
    if kubectl --context "${CONTEXT}" get nodes &>/dev/null 2>&1; then
      API_READY=1
      break
    fi
    sleep 4
  done
  [[ "${API_READY}" -eq 0 ]] && error "Kubernetes API server is unreachable. Try: kubectl cluster-info --context ${CONTEXT}"
fi
success "API server is responsive."

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
echo "${CNPG_VERSION}"   > "${WORK_DIR}/cnpg-version.txt"
echo "${CLUSTER_NAME}"  > "${WORK_DIR}/cluster-name.txt"
echo "${OPERATOR_NS}"   > "${WORK_DIR}/operator-namespace.txt"
echo "${OPERATOR_TYPE}" > "${WORK_DIR}/operator-type.txt"
[[ -n "${OPERATOR_IMAGE}" ]]       && echo "${OPERATOR_IMAGE}"       > "${WORK_DIR}/operator-image.txt"
[[ -n "${CERT_MANAGER_VERSION}" ]] && echo "${CERT_MANAGER_VERSION}" > "${WORK_DIR}/cert-manager-version.txt"
success "Metadata files written."

# ── Step 7: Upload to GitHub Release (no Git LFS — no bandwidth limits) ──────
step "Step 7 · Upload to GitHub Release  (${GITHUB_USER}/${GITHUB_REPO})"

RELEASE_TAG="backup-${CLUSTER_NAME}-$(date +%Y%m%d-%H%M%S)"
RELEASE_NAME="${CLUSTER_NAME} · ${OPERATOR_TYPE} v${CNPG_VERSION} · $(date +%Y-%m-%d)"

# Python helper: create release and return ID + upload base URL
CREATE_PY="${WORK_DIR}/create_release.py"
cat > "${CREATE_PY}" << 'PYEOF'
import sys, json
try:
    from urllib.request import urlopen, Request
    from urllib.error import HTTPError
except ImportError:
    sys.exit(1)

token, owner, repo, tag, name = sys.argv[1:6]
url  = f"https://api.github.com/repos/{owner}/{repo}/releases"
body = json.dumps({"tag_name": tag, "name": name,
                   "body": "Automated backup by docker-cluster-backup.sh",
                   "draft": False, "prerelease": False}).encode()
req = Request(url, data=body, headers={
    "Authorization": f"token {token}",
    "Accept": "application/vnd.github+json",
    "Content-Type": "application/json"}, method="POST")
try:
    with urlopen(req) as r:
        d = json.load(r)
        print(d["id"])
        print(d["upload_url"].split("{")[0])
except HTTPError as e:
    sys.stderr.write(f"HTTP {e.code}: {e.read().decode()}\n")
    sys.exit(1)
PYEOF

info "Creating GitHub Release: ${RELEASE_TAG}..."
REL_OUT=$(python3 "${CREATE_PY}" "${GITHUB_TOKEN}" "${LOGIN}" \
  "${GITHUB_REPO}" "${RELEASE_TAG}" "${RELEASE_NAME}" 2>/dev/null || true)
[[ -z "${REL_OUT}" ]] && error "Failed to create GitHub Release. Check PAT has 'repo' scope."

RELEASE_ID=$(echo "${REL_OUT}" | head -1)
UPLOAD_BASE=$(echo "${REL_OUT}" | tail -1)
success "Release created: ${RELEASE_TAG} (ID: ${RELEASE_ID})"
info "View at: https://github.com/${GITHUB_USER}/${GITHUB_REPO}/releases/tag/${RELEASE_TAG}"

# ── Upload helper (with retry + live progress bar) ───────────────────────────
upload_asset() {
  local file="$1" name="$2"
  local size_bytes size_mb
  size_bytes=$(wc -c < "${file}" | tr -d ' ')
  size_mb=$(( size_bytes / 1024 / 1024 ))
  local RESP_FILE="${WORK_DIR}/.upload_resp"

  for attempt in 1 2 3; do
    info "Uploading ${name} (${size_mb} MB, attempt ${attempt}/3)..."
    echo ""
    # -#  → progress bar goes to stderr (terminal directly via 2>/dev/tty)
    # -o  → response body saved to file (not mixed with HTTP code)
    # -w  → HTTP code captured to stdout only
    HTTP=$(curl -# \
      -o "${RESP_FILE}" \
      -w "%{http_code}" \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      --max-time 7200 \
      --data-binary @"${file}" \
      "${UPLOAD_BASE}?name=${name}" 2>/dev/tty) || HTTP="000"
    echo ""
    if [[ "${HTTP}" == "201" ]]; then
      success "${name} uploaded successfully."
      rm -f "${RESP_FILE}"
      return 0
    elif [[ "${HTTP}" == "422" ]]; then
      warn "${name} already exists in this release — skipping."
      rm -f "${RESP_FILE}"
      return 0
    fi
    warn "Attempt ${attempt}/3 failed (HTTP ${HTTP}). Retrying in 15s..."
    sleep 15
  done
  error "Failed to upload ${name} after 3 attempts."
}

# ── Upload snapshot (split into 1.8 GB chunks if > 1.9 GB) ──────────────────
SNAPSHOT_FILE="${WORK_DIR}/cnpg-snapshot.tar.gz"
SNAPSHOT_BYTES=$(wc -c < "${SNAPSHOT_FILE}" | tr -d ' ')
MAX_BYTES=1900000000

if [[ ${SNAPSHOT_BYTES} -le ${MAX_BYTES} ]]; then
  upload_asset "${SNAPSHOT_FILE}" "cnpg-snapshot.tar.gz"
else
  SNAP_GB=$(( SNAPSHOT_BYTES / 1024 / 1024 / 1024 ))
  info "Snapshot is ${SNAP_GB} GB — splitting into 1.8 GB chunks for upload..."
  SPLIT_DIR="${WORK_DIR}/parts"
  mkdir -p "${SPLIT_DIR}"
  split -b 1800000000 "${SNAPSHOT_FILE}" "${SPLIT_DIR}/cnpg-snapshot.part."
  PARTS=()
  while IFS= read -r p; do PARTS+=("${p}"); done < <(find "${SPLIT_DIR}" -name "cnpg-snapshot.part.*" | sort)
  TOTAL_PARTS=${#PARTS[@]}
  success "Split into ${TOTAL_PARTS} parts."
  for i in "${!PARTS[@]}"; do
    SUFFIX="${PARTS[$i]##*.}"
    upload_asset "${PARTS[$i]}" "cnpg-snapshot.part.${SUFFIX}"
  done
  printf '%d' "${TOTAL_PARTS}" > "${WORK_DIR}/snapshot-parts.txt"
  upload_asset "${WORK_DIR}/snapshot-parts.txt" "snapshot-parts.txt"
fi

# ── Upload metadata files ────────────────────────────────────────────────────
for f in cnp-cluster-config.yaml cnpg-db-blueprints.yaml cnpg-version.txt \
          cluster-name.txt operator-namespace.txt operator-type.txt \
          operator-image.txt cert-manager-version.txt; do
  [[ -f "${WORK_DIR}/${f}" ]] && upload_asset "${WORK_DIR}/${f}" "${f}"
done

# ── Done ─────────────────────────────────────────────────────────────────────
TAR_SIZE=$(du -sh "${SNAPSHOT_FILE}" | cut -f1)
CFG_SIZE=$(du -sh "${WORK_DIR}/cnp-cluster-config.yaml" | cut -f1)
BP_SIZE=$(du -sh  "${WORK_DIR}/cnpg-db-blueprints.yaml" | cut -f1)

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║  Backup complete!                                            ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}https://github.com/${GITHUB_USER}/${GITHUB_REPO}/releases/tag/${RELEASE_TAG}${NC}"
echo ""
echo -e "  ${BOLD}Files uploaded to GitHub Release:${NC}"
echo -e "  ${GREEN}✓${NC}  cnpg-snapshot.tar.gz      ${TAR_SIZE}"
echo -e "  ${GREEN}✓${NC}  cnp-cluster-config.yaml   ${CFG_SIZE}"
echo -e "  ${GREEN}✓${NC}  cnpg-db-blueprints.yaml   ${BP_SIZE}"
echo -e "  ${GREEN}✓${NC}  cnpg-version.txt          (${CNPG_VERSION})"
echo -e "  ${GREEN}✓${NC}  operator-namespace.txt    (${OPERATOR_NS})"
echo -e "  ${GREEN}✓${NC}  operator-type.txt         (${OPERATOR_TYPE})"
[[ -n "${OPERATOR_IMAGE}" ]] && \
  echo -e "  ${GREEN}✓${NC}  operator-image.txt        (${OPERATOR_IMAGE})"
[[ -n "${CERT_MANAGER_VERSION}" ]] && \
  echo -e "  ${GREEN}✓${NC}  cert-manager-version.txt  (${CERT_MANAGER_VERSION})"
echo ""
echo -e "  ${BOLD}To restore this cluster on any machine:${NC}"
echo -e "  ${YELLOW}curl -fsSL https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/main/docker-cluster-restore.sh \\"
echo -e "    -o docker-cluster-restore.sh && chmod +x docker-cluster-restore.sh && ./docker-cluster-restore.sh${NC}"
echo ""
