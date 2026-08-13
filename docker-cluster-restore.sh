#!/usr/bin/env bash
# =============================================================================
# docker-cluster-restore.sh
# Restores a kind cluster (CNPG / EDB CNP / EDB PGD4K) from a GitHub Release.
#
# Compatible with macOS default bash 3.2+
# No GitHub token required for public repos.
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
#   2. Which cluster to restore — shows live list from GitHub Releases
#
# What it does automatically:
#   - Lists all backup releases in the GitHub repo via API
#   - Shows table: cluster name, snapshot status, K8s config, DB blueprints
#   - Downloads snapshot (single file or reassembles chunks)
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
for cmd in curl python3 docker kind kubectl; do
  command -v "$cmd" &>/dev/null || error "$cmd not found. Install it first."
done
docker info &>/dev/null 2>&1 || error "Docker Desktop is not running. Start it first."
success "All pre-flight checks passed."

# ── Step 1: GitHub repo details ───────────────────────────────────────────────
step "Step 1 · GitHub repo details"

read -rp "GitHub username (repo owner) [erswapnil]: " GITHUB_USER
GITHUB_USER="${GITHUB_USER:-erswapnil}"
read -rp "GitHub repo name [Kind-Cluster-Backup-and-restore]: " GITHUB_REPO
GITHUB_REPO="${GITHUB_REPO:-Kind-Cluster-Backup-and-restore}"

# Use GITHUB_TOKEN if set — raises rate limit from 60/hr to 5000/hr
# Set it with: export GITHUB_TOKEN=ghp_your_token
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  GH_AUTH_HEADER="Authorization: token ${GITHUB_TOKEN}"
  info "Using GitHub token for API calls (5000 req/hr limit)."
else
  GH_AUTH_HEADER="Accept: application/vnd.github+json"
  info "No GITHUB_TOKEN set — using unauthenticated API (60 req/hr limit)."
  info "To avoid rate limits: export GITHUB_TOKEN=ghp_your_token"
fi

echo ""
info "Verifying repo is accessible..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Accept: application/vnd.github+json" \
  -H "${GH_AUTH_HEADER}" \
  "https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}")
if [[ "${HTTP_CODE}" != "200" ]]; then
  error "Repo '${GITHUB_USER}/${GITHUB_REPO}' not found or not public (HTTP ${HTTP_CODE}). If rate limited (403), set GITHUB_TOKEN env var or wait 1 hour."
fi
success "Repo ${GITHUB_USER}/${GITHUB_REPO} is accessible."

# ── Step 2: List available backups from GitHub Releases ───────────────────────
step "Step 2 · Available cluster backups (GitHub Releases)"

WORK_DIR="$(mktemp -d -t kind-restore-XXXXXX)"

LIST_PY="${WORK_DIR}/list_releases.py"
cat > "${LIST_PY}" << 'PYEOF'
import sys, json, re
try:
    from urllib.request import urlopen, Request
    from urllib.error import HTTPError
except ImportError:
    sys.exit(1)

owner = sys.argv[1]
repo  = sys.argv[2]
token = sys.argv[3] if len(sys.argv) > 3 else ""

url = f"https://api.github.com/repos/{owner}/{repo}/releases?per_page=100"
headers = {"Accept": "application/vnd.github+json"}
if token:
    headers["Authorization"] = f"token {token}"

try:
    with urlopen(Request(url, headers=headers)) as r:
        releases = json.load(r)
except HTTPError as e:
    sys.stderr.write(f"HTTP {e.code}\n")
    sys.exit(1)

rows = []
for rel in releases:
    tag = rel.get("tag_name", "")
    if not tag.startswith("backup-"):
        continue
    assets = {a["name"]: a["browser_download_url"] for a in rel.get("assets", [])}
    has_snap = (
        "cnpg-snapshot.tar.gz" in assets
        or any(n.startswith("cnpg-snapshot.part.") for n in assets)
    )
    has_cfg  = "cnp-cluster-config.yaml" in assets
    has_bp   = "cnpg-db-blueprints.yaml" in assets
    if not has_snap:
        continue

    # Operator label from namespace file
    ns_url = assets.get("operator-namespace.txt", "")
    op = ""
    if ns_url:
        try:
            with urlopen(ns_url, timeout=5) as r2:
                ns = r2.read().decode().strip()
            op = {"cnpg-system":"CNPG","postgresql-operator-system":"EDB-CNP","pgd-operator-system":"PGD4K"}.get(ns, ns)
        except:
            pass

    # Cluster name: strip backup- prefix and YYYYMMDD-HHMMSS suffix
    cluster = tag[len("backup-"):]
    m = re.match(r"^(.*)-(\d{8})-(\d{6})$", cluster)
    if m:
        cluster = m.group(1)

    cfg_str = f"yes ({op})" if has_cfg else "missing"
    bp_str  = "yes" if has_bp else "missing"
    rows.append(f"{tag}|{cluster}|yes|{cfg_str}|{bp_str}")

print("\n".join(rows))
PYEOF

info "Fetching backup list from GitHub Releases..."
RELEASE_ROWS=$(python3 "${LIST_PY}" "${GITHUB_USER}" "${GITHUB_REPO}" "${GITHUB_TOKEN:-}" 2>/dev/null || true)

if [[ -z "${RELEASE_ROWS}" ]]; then
  error "No backups found in GitHub Releases for ${GITHUB_USER}/${GITHUB_REPO}. Run docker-cluster-backup.sh first."
fi

echo ""
printf "  ${BOLD}%-4s %-25s %-12s %-22s %s${NC}\n" "#" "CLUSTER NAME" "SNAPSHOT" "K8S CONFIG" "DB BLUEPRINTS"
echo "  ─────────────────────────────────────────────────────────────────────────────"

VALID_TAGS=()
VALID_CLUSTERS=()
while IFS= read -r row; do
  [[ -z "${row}" ]] && continue
  TAG=$(echo "${row}"    | cut -d'|' -f1)
  CLUSTER=$(echo "${row}" | cut -d'|' -f2)
  SNAP=$(echo "${row}"   | cut -d'|' -f3)
  CFG=$(echo "${row}"    | cut -d'|' -f4)
  BP=$(echo "${row}"     | cut -d'|' -f5)
  VALID_TAGS+=("${TAG}")
  VALID_CLUSTERS+=("${CLUSTER}")
  NUM=${#VALID_CLUSTERS[@]}
  printf "  ${BOLD}%-4s${NC} ${GREEN}%-25s${NC} %-12s %-22s %s\n" "${NUM}" "${CLUSTER}" "${SNAP}" "${CFG}" "${BP}"
done <<< "${RELEASE_ROWS}"
echo ""

if [[ ${#VALID_CLUSTERS[@]} -eq 0 ]]; then
  error "No valid backups found."
fi

while true; do
  read -rp "$(echo -e "${BOLD}Select cluster to restore [1-${#VALID_CLUSTERS[@]}]: ${NC}")" PICK
  if [[ "${PICK}" =~ ^[0-9]+$ ]] && (( PICK >= 1 && PICK <= ${#VALID_CLUSTERS[@]} )); then
    CLUSTER_FOLDER="${VALID_CLUSTERS[$((PICK-1))]}"
    SELECTED_TAG="${VALID_TAGS[$((PICK-1))]}"
    break
  fi
  warn "Invalid selection."
done
success "Selected: ${CLUSTER_FOLDER} (release: ${SELECTED_TAG})"

# ── Step 3: Download backup files from GitHub Release ────────────────────────
step "Step 3 · Download backup files from GitHub Release"

# Python helper: get all asset URLs for a release tag
GET_ASSETS_PY="${WORK_DIR}/get_assets.py"
cat > "${GET_ASSETS_PY}" << 'PYEOF'
import sys, json
try:
    from urllib.request import urlopen, Request
except ImportError:
    sys.exit(1)

owner = sys.argv[1]
repo  = sys.argv[2]
tag   = sys.argv[3]
token = sys.argv[4] if len(sys.argv) > 4 else ""

url = f"https://api.github.com/repos/{owner}/{repo}/releases/tags/{tag}"
headers = {"Accept": "application/vnd.github+json"}
if token:
    headers["Authorization"] = f"token {token}"

with urlopen(Request(url, headers=headers)) as r:
    data = json.load(r)

for a in data.get("assets", []):
    print(a["name"] + "|" + a["browser_download_url"])
PYEOF

ASSETS=$(python3 "${GET_ASSETS_PY}" "${GITHUB_USER}" "${GITHUB_REPO}" \
  "${SELECTED_TAG}" "${GITHUB_TOKEN:-}" 2>/dev/null || true)

[[ -z "${ASSETS}" ]] && error "Could not fetch assets for release ${SELECTED_TAG}."

# Build asset URL map — bash 3.2 compatible (no declare -A / associative arrays)
# Each line in the map file: "asset-name|download-url"
ASSET_MAP_FILE="${WORK_DIR}/.asset_map"
> "${ASSET_MAP_FILE}"
while IFS='|' read -r aname aurl; do
  [[ -z "${aname}" ]] && continue
  printf '%s|%s\n' "${aname}" "${aurl}" >> "${ASSET_MAP_FILE}"
done <<< "${ASSETS}"

# Helper: return the download URL for a named asset (empty string if not found)
asset_url() {
  grep "^${1}|" "${ASSET_MAP_FILE}" 2>/dev/null | head -1 | cut -d'|' -f2-
}

# Download helper
download_asset() {
  local name="$1" dest="$2"
  local url
  url=$(asset_url "${name}")
  [[ -z "${url}" ]] && return 1
  for attempt in 1 2 3; do
    info "Downloading ${name} (attempt ${attempt}/3)..."
    if curl -L --max-time 7200 -# -o "${dest}" "${url}" 2>/dev/tty; then
      echo ""
      success "${name} downloaded: $(du -sh "${dest}" | cut -f1)"
      return 0
    fi
    warn "Download attempt ${attempt}/3 failed. Retrying in 10s..."
    sleep 10
  done
  return 1
}

# Download snapshot — handle single file or split chunks
SNAPSHOT_DEST="${WORK_DIR}/snapshot.tar.gz"

if [[ -n "$(asset_url "cnpg-snapshot.tar.gz")" ]]; then
  # Single file (small snapshot that fit in one chunk)
  download_asset "cnpg-snapshot.tar.gz" "${SNAPSHOT_DEST}" || error "Failed to download snapshot."
else
  # Split parts — find and download all chunks in order
  PARTS_COUNT_URL=$(asset_url "snapshot-parts.txt")
  if [[ -z "${PARTS_COUNT_URL}" ]]; then
    error "No snapshot found in release ${SELECTED_TAG}. Backup may be incomplete."
  fi
  TOTAL_PARTS=$(curl -sfL "${PARTS_COUNT_URL}" | tr -d '[:space:]' || echo "0")
  if [[ -z "${TOTAL_PARTS}" || "${TOTAL_PARTS}" -eq 0 ]]; then
    # Fallback: count the part files directly from the asset map
    TOTAL_PARTS=$(grep -c "^cnpg-snapshot\.part\." "${ASSET_MAP_FILE}" 2>/dev/null || echo "0")
  fi
  [[ "${TOTAL_PARTS}" -eq 0 ]] && error "Could not determine snapshot part count."

  info "Snapshot was split into ${TOTAL_PARTS} chunks — downloading each chunk..."
  PARTS_DIR="${WORK_DIR}/parts"
  mkdir -p "${PARTS_DIR}"

  # Collect part names from the map file (cnpg-snapshot.part.aa, ab, ac, ...)
  PART_FILES=()
  while IFS='|' read -r aname aurl; do
    case "${aname}" in cnpg-snapshot.part.*) PART_FILES+=("${aname}") ;; esac
  done < "${ASSET_MAP_FILE}"

  # Sort part files alphabetically (preserves split order: aa, ab, ac, ...)
  IFS=$'\n' PART_FILES=($(printf '%s\n' "${PART_FILES[@]}" | sort)); unset IFS

  PART_NUM=0
  for pf in "${PART_FILES[@]}"; do
    PART_NUM=$(( PART_NUM + 1 ))
    echo -e "  ${BOLD}── Chunk ${PART_NUM} / ${TOTAL_PARTS} ──${NC}"
    download_asset "${pf}" "${PARTS_DIR}/${pf}" || error "Failed to download chunk ${pf}."
    echo ""
  done

  # Reassemble all chunks in order
  PART_COUNT=${#PART_FILES[@]}
  info "Reassembling snapshot from ${PART_COUNT} chunks..."
  cat "${PARTS_DIR}"/cnpg-snapshot.part.* > "${SNAPSHOT_DEST}"
  success "Snapshot reassembled: $(du -sh "${SNAPSHOT_DEST}" | cut -f1)"
fi

# Download metadata files
BACKUP_DIR="${WORK_DIR}/backup"
mkdir -p "${BACKUP_DIR}"
cp "${SNAPSHOT_DEST}" "${BACKUP_DIR}/cnpg-snapshot.tar.gz"

for f in cnp-cluster-config.yaml cnpg-db-blueprints.yaml cnpg-version.txt \
          cluster-name.txt operator-namespace.txt operator-type.txt \
          operator-image.txt cert-manager-version.txt \
          pgd-cnp-image.txt pgd-cnp-version.txt; do
  if [[ -n "$(asset_url "${f}")" ]]; then
    download_asset "${f}" "${BACKUP_DIR}/${f}" || warn "Could not download ${f} (non-fatal)."
  fi
done
success "All backup files downloaded."

# ── Artifact paths ────────────────────────────────────────────────────────────
BACKUP_SUBDIR="${BACKUP_DIR}"
SNAPSHOT_TAR="${BACKUP_SUBDIR}/cnpg-snapshot.tar.gz"
CLUSTER_CONFIG="${BACKUP_SUBDIR}/cnp-cluster-config.yaml"
DB_BLUEPRINTS="${BACKUP_SUBDIR}/cnpg-db-blueprints.yaml"

# ── Step 4: Read cluster metadata ─────────────────────────────────────────────
step "Step 4 · Reading cluster metadata"

# Cluster name defaults to folder name
CLUSTER_NAME="${CLUSTER_FOLDER}"
CNPG_VERSION=""
OPERATOR_NS=""
OPERATOR_TYPE=""
OPERATOR_IMAGE=""

# Priority 1: metadata files written by docker-cluster-backup.sh
if [[ -f "${BACKUP_SUBDIR}/cnpg-version.txt" ]]; then
  CNPG_VERSION=$(cat "${BACKUP_SUBDIR}/cnpg-version.txt" | tr -d '[:space:]')
fi
if [[ -f "${BACKUP_SUBDIR}/operator-namespace.txt" ]]; then
  OPERATOR_NS=$(cat "${BACKUP_SUBDIR}/operator-namespace.txt" | tr -d '[:space:]')
  info "Operator namespace : ${OPERATOR_NS} (from metadata)"
fi
if [[ -f "${BACKUP_SUBDIR}/operator-type.txt" ]]; then
  OPERATOR_TYPE=$(cat "${BACKUP_SUBDIR}/operator-type.txt" | tr -d '\n')
  info "Operator type      : ${OPERATOR_TYPE} (from metadata)"
fi
if [[ -f "${BACKUP_SUBDIR}/operator-image.txt" ]]; then
  OPERATOR_IMAGE=$(cat "${BACKUP_SUBDIR}/operator-image.txt" | tr -d '[:space:]')
  info "Operator image     : ${OPERATOR_IMAGE} (from metadata)"
fi

# PGD4K sub-operator info (only present for PGD4K backups)
PGD_CNP_IMAGE=""
PGD_CNP_VERSION=""
if [[ -f "${BACKUP_SUBDIR}/pgd-cnp-image.txt" ]]; then
  PGD_CNP_IMAGE=$(cat "${BACKUP_SUBDIR}/pgd-cnp-image.txt" | tr -d '[:space:]')
  info "CNP backend image  : ${PGD_CNP_IMAGE} (from metadata)"
fi
if [[ -f "${BACKUP_SUBDIR}/pgd-cnp-version.txt" ]]; then
  PGD_CNP_VERSION=$(cat "${BACKUP_SUBDIR}/pgd-cnp-version.txt" | tr -d '[:space:]')
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
    [[ -z "${OPERATOR_TYPE}" ]] && OPERATOR_TYPE="Community CloudNativePG (CNPG)"
    VERSION_LABEL="CNPG version"
    ;;
  "postgresql-operator-system")
    [[ -z "${OPERATOR_TYPE}" ]] && OPERATOR_TYPE="EDB Postgres for CloudNativePG (CNP)"
    VERSION_LABEL="CNP version"
    ;;
  "pgd-operator-system")
    [[ -z "${OPERATOR_TYPE}" ]] && OPERATOR_TYPE="EDB Postgres Distributed / Global Cluster (PGD4K)"
    VERSION_LABEL="PGD4K version"
    ;;
  *)
    [[ -z "${OPERATOR_TYPE}" ]] && OPERATOR_TYPE="Unknown operator"
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
  error "cnpg-snapshot.tar.gz is only ${SNAPSHOT_SIZE} bytes — looks corrupt or incomplete."
fi
info "Snapshot size: $(( SNAPSHOT_SIZE / 1024 / 1024 )) MB — looks good."

# ── Confirm ───────────────────────────────────────────────────────────────────
echo ""
echo -e "  Cluster to restore : ${BOLD}${CLUSTER_NAME}${NC}"
echo -e "  Operator           : ${OPERATOR_TYPE}"
echo -e "  Version            : v${CNPG_VERSION}"
echo -e "  Operator namespace : ${OPERATOR_NS}"
[[ -n "${OPERATOR_IMAGE}" ]] && \
echo -e "  Operator image     : ${OPERATOR_IMAGE}"
[[ -n "${PGD_CNP_IMAGE}" ]] && \
echo -e "  CNP backend        : ${PGD_CNP_IMAGE}"
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

# ── Step 5: Load Docker snapshot image ───────────────────────────────────────
step "Step 5 · Load Docker snapshot image"

# Load snapshot into Docker's image cache.
# Docker Desktop shares its image store with kind nodes, so all images
# embedded in the snapshot (postgres, operator) become available to pods
# without needing registry credentials.
ORIG_CLUSTER_NAME=$(cat "${BACKUP_SUBDIR}/cluster-name.txt" 2>/dev/null | tr -d '[:space:]' || echo "${CLUSTER_NAME}")
ORIG_SNAPSHOT_TAG="${ORIG_CLUSTER_NAME}-snapshot:v1"

if docker image inspect "${ORIG_SNAPSHOT_TAG}" &>/dev/null 2>&1; then
  success "Docker image already loaded: ${ORIG_SNAPSHOT_TAG}"
else
  info "Loading cnpg-snapshot.tar.gz into Docker (decompressing + loading, may take a few minutes)..."
  LOADED_TAG=$(gzip -dc "${SNAPSHOT_TAR}" | docker load 2>&1 | grep "Loaded image" | awk '{print $NF}' | head -1 || true)
  success "Docker image loaded: ${LOADED_TAG:-${ORIG_SNAPSHOT_TAG}}"
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

kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
CONTEXT="kind-${CLUSTER_NAME}"
success "kind cluster '${CLUSTER_NAME}' created."

# ── EDB registry pull secret (EDB CNP / PGD4K only) ──────────────────────────
# EDB operator images are hosted on docker.enterprisedb.com and require auth.
# Create the pull secret now so operator pods can pull images without error.
EDB_PULL_SECRET_PASS=""
if [[ "${OPERATOR_NS}" != "cnpg-system" ]]; then
  echo ""
  echo -e "  ${BOLD}EDB registry credentials${NC}"
  echo "  Operator images are hosted on docker.enterprisedb.com and require auth."
  echo "  Provide credentials to create the pull secret automatically."
  echo "  (Press Enter to skip — you can create it manually if pods fail.)"
  echo ""
  read -rp "  EDB registry username [k8s]: " EDB_PULL_USER
  EDB_PULL_USER="${EDB_PULL_USER:-k8s}"
  read -rsp "  EDB registry token/password (hidden, Enter to skip): " EDB_PULL_SECRET_PASS
  echo ""
fi

# ── Step 7: Install operator ──────────────────────────────────────────────────
step "Step 7 · Install operator v${CNPG_VERSION}  (${OPERATOR_TYPE})"

case "${OPERATOR_NS}" in

  "cnpg-system")
    # ── Community CloudNativePG ───────────────────────────────────────────────
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
    info "Creating postgresql-operator-system namespace..."
    kubectl create namespace postgresql-operator-system \
      --context "${CONTEXT}" 2>/dev/null || true
    if [[ -n "${EDB_PULL_SECRET_PASS}" ]]; then
      for _ns in postgresql-operator-system default; do
        kubectl create secret docker-registry edb-pull-secret \
          --docker-server=docker.enterprisedb.com \
          --docker-username="${EDB_PULL_USER}" \
          --docker-password="${EDB_PULL_SECRET_PASS}" \
          -n "${_ns}" --context "${CONTEXT}" \
          --dry-run=client -o yaml \
          | kubectl apply --context "${CONTEXT}" -f - 2>/dev/null || true
      done
      success "EDB pull secret created in postgresql-operator-system + default."
    else
      warn "No EDB credentials provided — operator may ImagePullBackOff."
      warn "If so, run: kubectl create secret docker-registry edb-pull-secret \\"
      warn "  --docker-server=docker.enterprisedb.com --docker-username=k8s \\"
      warn "  --docker-password=<token> -n postgresql-operator-system"
    fi
    info "EDB CNP operator deployment will be restored from cnp-cluster-config.yaml in Step 8."
    ;;

  "pgd-operator-system")
    # ── EDB Postgres Distributed / Global Cluster (PGD4K) ────────────────────
    # PGD requires cert-manager for TLS + the PGD operator manifest bootstrapped
    # BEFORE the backup YAML is applied.

    # Step 7a: cert-manager (creates cert-manager namespace + CRDs)
    info "Installing cert-manager ${CERT_MANAGER_VERSION}..."
    kubectl apply \
      --context "kind-${CLUSTER_NAME}" \
      --validate=false \
      -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
    info "Waiting for cert-manager pods to be Ready (up to 120 s)..."
    kubectl wait pod \
      --for=condition=ready \
      --selector app.kubernetes.io/instance=cert-manager \
      --namespace cert-manager \
      --context "kind-${CLUSTER_NAME}" \
      --timeout=120s \
      2>/dev/null || warn "cert-manager pods not fully Ready yet — continuing anyway."

    # Extra wait for the webhook endpoint to register and become reachable
    info "Waiting 30 s for cert-manager webhook endpoint to register..."
    sleep 30
    kubectl rollout restart deployment/cert-manager-webhook \
      -n cert-manager --context "kind-${CLUSTER_NAME}" &>/dev/null || true
    kubectl rollout status deployment/cert-manager-webhook \
      -n cert-manager --context "kind-${CLUSTER_NAME}" \
      --timeout=60s &>/dev/null || true
    success "cert-manager ${CERT_MANAGER_VERSION} installed and webhook ready."

    # Step 7b: PGD operator manifest
    PGD_MANIFEST="https://get.enterprisedb.io/pg4k-pgd/pg4k-pgd-${CNPG_VERSION}.yaml"
    info "Applying EDB PGD4K operator v${CNPG_VERSION} manifest: ${PGD_MANIFEST}"
    kubectl apply \
      --server-side \
      --context "kind-${CLUSTER_NAME}" \
      -f "${PGD_MANIFEST}" \
      || warn "PGD operator manifest had warnings — check pods below."
    success "EDB PGD4K operator manifest applied."

    # Step 7c: Create EDB pull secret in pgd-operator-system and default
    if [[ -n "${EDB_PULL_SECRET_PASS}" ]]; then
      info "Creating EDB pull secret in pgd-operator-system + default..."
      for _ns in pgd-operator-system default; do
        kubectl create namespace "${_ns}" --context "${CONTEXT}" 2>/dev/null || true
        kubectl create secret docker-registry edb-pull-secret \
          --docker-server=docker.enterprisedb.com \
          --docker-username="${EDB_PULL_USER}" \
          --docker-password="${EDB_PULL_SECRET_PASS}" \
          -n "${_ns}" --context "${CONTEXT}" \
          --dry-run=client -o yaml \
          | kubectl apply --context "${CONTEXT}" -f - 2>/dev/null || true
      done
      success "EDB pull secret created in pgd-operator-system + default."
    else
      # Fall back to extracting from backup YAML (may have stale token)
      info "No credentials provided — extracting pull secret from backup (token may be stale)..."
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
      && success "EDB pull secret applied from backup." \
      || warn "Could not apply pull secret — operator may ImagePullBackOff."
    fi
    ;;

  *)
    warn "Unknown operator namespace '${OPERATOR_NS}' — skipping manifest install."
    warn "Operator will be restored from cnp-cluster-config.yaml in Step 8."
    ;;
esac

# ── Step 8: Apply Kubernetes resources ───────────────────────────────────────
step "Step 8 · Apply Kubernetes configs  (Namespaces first → full cluster config)"

# Pass 1: Create all Namespace objects first.
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

# Pass 2: Apply full cluster configuration
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

# PGD4K: wait for CRDs to be registered before applying blueprints
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

# PGD4K: cert-manager Issuers must exist before PGDGroups can provision TLS
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
info "Waiting up to 5 minutes for all pods across all namespaces to reach Running state..."
info "(First-time restore may pull PostgreSQL images — this can take 5-10 min. Re-run if needed.)"

DEADLINE=$(( $(date +%s) + 300 ))
while true; do
  NOT_READY=$(kubectl get pods \
    --context "kind-${CLUSTER_NAME}" \
    --all-namespaces --no-headers 2>/dev/null \
    | grep -v "Running" | grep -v "Completed" \
    | grep -v "kube-system" | grep -v "local-path-storage" || true)
  if [[ -z "${NOT_READY}" ]]; then
    success "All database and operator pods are Running."
    break
  fi
  if [[ $(date +%s) -gt ${DEADLINE} ]]; then
    warn "Timeout — some pods may still be starting. Check status below."
    break
  fi
  info "Pods not yet ready — retrying in 10 s..."
  sleep 10
done

# ── Final state ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}─── Final cluster state ───${NC}"
echo ""
echo -e "  ${BOLD}All namespaces:${NC}"
kubectl get pods --context "kind-${CLUSTER_NAME}" --all-namespaces 2>/dev/null || true
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
echo "  kubectl get pods --context kind-${CLUSTER_NAME} --all-namespaces"
echo "  kubectl get pods --context kind-${CLUSTER_NAME} -n ${OPERATOR_NS}"
echo "  kubectl get clusters.postgresql.cnpg.io --context kind-${CLUSTER_NAME} --all-namespaces"
echo "  kubectl get pgdgroups --context kind-${CLUSTER_NAME} --all-namespaces"
echo ""
