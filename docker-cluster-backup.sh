#!/usr/bin/env bash
# =============================================================================
# docker-cluster-backup.sh
# Snapshot a kind cluster and package it as a zip ready to share via Drive.
#
# Usage:
#   ./docker-cluster-backup.sh
#
# Output:
#   kind-backup-<cluster>-<date>.zip   (share this file with your colleague)
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
echo -e "${BOLD}â        kind Cluster â Local Backup Tool              â${NC}"
echo -e "${BOLD}â     Packages cluster into a zip for sharing          â${NC}"
echo -e "${BOLD}ââââââââââââââââââââââââââââââââââââââââââââââââââââââââ${NC}"
echo ""

# âââ Pre-flight checks ââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
step "Pre-flight checks"

command -v docker &>/dev/null || error "Docker not found. Install Docker Desktop first."
docker info &>/dev/null 2>&1  || error "Docker daemon not running. Start Docker Desktop."
command -v kind    &>/dev/null || error "'kind' not found. Run: brew install kind"
command -v kubectl &>/dev/null || error "'kubectl' not found. Run: brew install kubectl"
command -v zip     &>/dev/null || error "'zip' not found. Run: brew install zip"
success "All tools found."

# âââ Show available clusters ââââââââââââââââââââââââââââââââââââââââââââââââââ
step "Available kind clusters"

CLUSTERS=$(kind get clusters 2>/dev/null || true)
if [[ -z "${CLUSTERS}" ]]; then
  error "No kind clusters found. Is a cluster running?"
fi

echo ""
echo "  #   CLUSTER NAME"
echo "  ââââââââââââââââââ"
i=1
while IFS= read -r cl; do
  printf "  %-3s %s\n" "$i" "$cl"
  ((i++))
done <<< "${CLUSTERS}"
echo ""

CLUSTER_COUNT=$(echo "${CLUSTERS}" | wc -l | tr -d ' ')

read -rp "Select cluster to back up [1-${CLUSTER_COUNT}]: " CHOICE
CLUSTER_NAME=$(echo "${CLUSTERS}" | sed -n "${CHOICE}p")
[[ -z "${CLUSTER_NAME}" ]] && error "Invalid selection."
success "Selected cluster: ${CLUSTER_NAME}"

CONTEXT="kind-${CLUSTER_NAME}"

# âââ Auto-detect CNPG / EDB / PGD operator version âââââââââââââââââââââââââââ
step "Operator version (auto-detecting)"

CNPG_VERSION=""
OPERATOR_NS=""
OPERATOR_TYPE=""

# ââ Known operator namespaces, checked in priority order ââââââââââââââââââââââ
#   cnpg-system                  â Community CloudNativePG
#                                  image: ghcr.io/cloudnative-pg/cloudnative-pg:<version>
#   postgresql-operator-system   â EDB Postgres for CloudNativePG (standard EDB)
#                                  image: docker.enterprisedb.com/k8s/edb-postgres-for-cloudnativepg:<version>
#   pgd-operator-system          â EDB Postgres Distributed (PGD)
#                                  image: docker.enterprisedb.com/k8s/edb-postgres-for-cloudnativepg-global-cluster:<version>

detect_version_from_ns() {
  local ns="$1"
  # Check if namespace exists and has at least one deployment
  local deploy_count
  deploy_count=$(kubectl get deployment -n "${ns}" --context "${CONTEXT}" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [[ "${deploy_count}" -eq 0 ]] && return

  # Extract version from the operator deployment's container image tag
  # The version is always the tag at the end of the image string, e.g. :1.28.0
  local ver
  ver=$(kubectl get deployment -n "${ns}" --context "${CONTEXT}" \
    -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' \
    2>/dev/null \
    | grep -i -E "cloudnative-pg|edb-postgres|cnpg|pgd|barman" \
    | grep -oE ':[0-9]+\.[0-9]+\.[0-9]+' \
    | tr -d ':' | head -1 || true)

  # Fallback: any semver tag from any image in this namespace
  if [[ -z "${ver}" ]]; then
    ver=$(kubectl get deployment -n "${ns}" --context "${CONTEXT}" \
      -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' \
      2>/dev/null | grep -oE ':[0-9]+\.[0-9]+\.[0-9]+' | tr -d ':' | head -1 || true)
  fi

  echo "${ver}"
}

# Check each known namespace in order
for ns_candidate in "cnpg-system" "postgresql-operator-system" "pgd-operator-system"; do
  info "Checking ${ns_candidate}..."
  detected=$(detect_version_from_ns "${ns_candidate}")
  if [[ -n "${detected}" ]]; then
    CNPG_VERSION="${detected}"
    OPERATOR_NS="${ns_candidate}"
    break
  fi
done

# ââ If still not found, scan ALL namespaces for any operator deployment ââââââââ
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
    2>/dev/null \
    | grep -i -E "cloudnative-pg|edb-postgres|cnpg|pgd|barman|operator" || true)
fi

if [[ -n "${CNPG_VERSION}" ]]; then
  # Determine operator type for display
  case "${OPERATOR_NS}" in
    "cnpg-system")                 OPERATOR_TYPE="Community CloudNativePG" ;;
    "postgresql-operator-system")  OPERATOR_TYPE="EDB Postgres for CloudNativePG" ;;
    "pgd-operator-system")         OPERATOR_TYPE="EDB Postgres Distributed (PGD)" ;;
    *)                             OPERATOR_TYPE="Unknown operator" ;;
  esac
  success "Operator:  ${OPERATOR_TYPE}"
  success "Namespace: ${OPERATOR_NS}"
  success "Version:   ${CNPG_VERSION}"
else
  warn "Could not auto-detect operator version."
  echo ""
  echo "  All deployment images found across namespaces:"
  kubectl get deployment --all-namespaces --context "${CONTEXT}" \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}' \
    2>/dev/null | grep -v "^$" | sort -u | sed 's/^/    /' \
    || echo "    (none found)"
  echo ""
  OPERATOR_NS="cnpg-system"
  read -rp "Enter operator version manually (e.g. 1.28.0): " CNPG_VERSION
  [[ -z "${CNPG_VERSION}" ]] && error "Operator version is required."
fi

# âââ Find control-plane container ââââââââââââââââââââââââââââââââââââââââââââ
step "Finding control-plane container"

CONTAINER_ID=$(docker ps -a \
  --filter "name=${CLUSTER_NAME}-control-plane" \
  --format "{{.ID}}" | head -1)

[[ -z "${CONTAINER_ID}" ]] && error "Control-plane container for '${CLUSTER_NAME}' not found. Is the cluster running?"
success "Control-plane container: ${CONTAINER_ID} (${CLUSTER_NAME}-control-plane)"

# âââ Confirm ââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
echo ""
echo "  Cluster name    : ${CLUSTER_NAME}"
echo "  Container ID    : ${CONTAINER_ID}"
echo "  CNPG version    : ${CNPG_VERSION}"
echo "  Output zip      : kind-backup-${CLUSTER_NAME}-$(date +%Y%m%d).zip"
echo ""
read -rp "Start backup? [Y/n]: " CONFIRM
[[ "${CONFIRM}" =~ ^[Nn] ]] && echo "Aborted." && exit 0

# âââ Create working folder ââââââââââââââââââââââââââââââââââââââââââââââââââââ
BACKUP_DIR="kind-backup-${CLUSTER_NAME}-$(date +%Y%m%d)"
mkdir -p "${BACKUP_DIR}"
info "Backup folder: ${BACKUP_DIR}/"

# Write metadata into the folder so restore script can read it automatically
echo "${CNPG_VERSION}"  > "${BACKUP_DIR}/cnpg-version.txt"
echo "${CLUSTER_NAME}"  > "${BACKUP_DIR}/cluster-name.txt"
echo "${OPERATOR_NS:-cnpg-system}" > "${BACKUP_DIR}/operator-namespace.txt"

# Detect and save cert-manager version (needed by restore for PGD clusters)
CERT_MANAGER_VERSION=""
if kubectl get ns cert-manager --context "${CONTEXT}" &>/dev/null 2>&1; then
  CERT_MANAGER_VERSION=$(kubectl get deployment -n cert-manager --context "${CONTEXT}" \
    -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' \
    2>/dev/null \
    | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
fi
if [[ -n "${CERT_MANAGER_VERSION}" ]]; then
  echo "${CERT_MANAGER_VERSION}" > "${BACKUP_DIR}/cert-manager-version.txt"
  success "cert-manager version: ${CERT_MANAGER_VERSION}"
else
  info "cert-manager not found in this cluster (not required for community CNPG / EDB CNP)."
fi

# âââ Step 1: Docker commit + save ââââââââââââââââââââââââââââââââââââââââââââ
step "Step 1 â Snapshot control-plane container"
info "docker commit ${CONTAINER_ID} â ${CLUSTER_NAME}-snapshot:v1"
docker commit "${CONTAINER_ID}" "${CLUSTER_NAME}-snapshot:v1"
info "docker save â ${BACKUP_DIR}/cnpg-snapshot.tar  (this may take a few minutes)"
docker save -o "${BACKUP_DIR}/cnpg-snapshot.tar" "${CLUSTER_NAME}-snapshot:v1"
success "Snapshot saved: $(du -sh "${BACKUP_DIR}/cnpg-snapshot.tar" | cut -f1)"

# âââ Step 2: Export Kubernetes resources âââââââââââââââââââââââââââââââââââââ
step "Step 2 â Export Kubernetes resources"
kubectl --context "${CONTEXT}" \
  get all,configmaps,secrets,storageclasses \
  --all-namespaces -o yaml > "${BACKUP_DIR}/cnp-cluster-config.yaml"
success "Config exported: $(du -sh "${BACKUP_DIR}/cnp-cluster-config.yaml" | cut -f1)"

# âââ Step 3: Export CNPG / EDB / PGD database blueprints ââââââââââââââââââââ
step "Step 3 â Export database blueprints"

# Export each CRD type separately so a missing CRD doesn't zero out the file.
# Covers: community CNPG, EDB CNP, and EDB PGD (pgdgroups + individual clusters).
BLUEPRINTS_FILE="${BACKUP_DIR}/cnpg-db-blueprints.yaml"
> "${BLUEPRINTS_FILE}"   # create empty file

EXPORTED_SOMETHING=false

export_crd() {
  local crd="$1"
  local label="$2"
  local out
  out=$(kubectl --context "${CONTEXT}" get "${crd}" \
    --all-namespaces -o yaml 2>/dev/null || true)
  # Skip if empty or just a blank list
  if echo "${out}" | grep -q "^items:" && ! echo "${out}" | grep -q "^items: \[\]"; then
    echo "---" >> "${BLUEPRINTS_FILE}"
    echo "${out}" >> "${BLUEPRINTS_FILE}"
    success "Exported: ${label}"
    EXPORTED_SOMETHING=true
  else
    info "Not found / empty: ${label} (skipping)"
  fi
}

# CNPG / EDB clusters and poolers
export_crd "clusters.postgresql.cnpg.io"        "clusters.postgresql.cnpg.io"
export_crd "poolers.postgresql.cnpg.io"          "poolers.postgresql.cnpg.io"

# PGD-specific resources
export_crd "pgdgroups.pgd.k8s.enterprisedb.io"  "pgdgroups.pgd.k8s.enterprisedb.io"

# Scheduled backups and backup configs
export_crd "scheduledbackups.postgresql.cnpg.io" "scheduledbackups.postgresql.cnpg.io"

# cert-manager resources (Issuers must exist before PGDGroups can provision TLS)
# Only present on PGD clusters; safely skipped on community CNPG / EDB CNP.
export_crd "issuers.cert-manager.io"             "cert-manager Issuers"
export_crd "certificates.cert-manager.io"         "cert-manager Certificates"
export_crd "clusterissuers.cert-manager.io"       "cert-manager ClusterIssuers"

if [[ "${EXPORTED_SOMETHING}" == "true" ]]; then
  success "Blueprints exported: $(du -sh "${BLUEPRINTS_FILE}" | cut -f1)"
else
  warn "No database blueprint resources found. The cluster may have no databases yet."
  warn "cnpg-db-blueprints.yaml will be empty â databases won't appear after restore."
fi

# âââ Step 4: Zip the backup folder âââââââââââââââââââââââââââââââââââââââââââ
step "Step 4 â Create zip file"
ZIP_NAME="${BACKUP_DIR}.zip"
zip -r "${ZIP_NAME}" "${BACKUP_DIR}/" > /dev/null
success "Zip created: ${ZIP_NAME}  ($(du -sh "${ZIP_NAME}" | cut -f1))"

# Clean up the unzipped folder (keep only the zip)
rm -rf "${BACKUP_DIR}"

# âââ Done âââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
echo ""
echo -e "${BOLD}âââ Backup complete âââ${NC}"
success "File: $(pwd)/${ZIP_NAME}"
echo ""
echo -e "  ${BOLD}Operator version:${NC} ${CNPG_VERSION}   (${OPERATOR_TYPE})"
echo -e "  ${BOLD}Cluster name:${NC} ${CLUSTER_NAME}   â tell your colleague when they restore"
echo ""
echo -e "  ${BOLD}Next step:${NC}"
echo -e "  Upload ${ZIP_NAME} to Google Drive (or AirDrop / USB)"
echo -e "  Share with your colleague along with:"
echo -e "    â¢ Cluster name: ${CLUSTER_NAME}"
echo -e "    â¢ CNPG version: ${CNPG_VERSION}"
echo ""
