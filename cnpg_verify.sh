#!/usr/bin/env bash
# =============================================================================
# cnpg_verify.sh
# Verifies the health of a restored CloudNativePG kind cluster.
#
# Usage:
#   ./cnpg_verify.sh [--cluster-name <name>]
#
# If --cluster-name is not provided, the script auto-detects the running
# kind cluster. If multiple clusters are found, it lists them and uses the
# first one alphabetically.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

CLUSTER_NAME=""

# ─── Parse CLI arguments ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) error "Unknown argument: $1. Use --cluster-name <name> or omit to auto-detect." ;;
  esac
done

# ─── Auto-detect cluster if not provided ──────────────────────────────────────
if [[ -z "${CLUSTER_NAME}" ]]; then
  step "Auto-detecting kind cluster"

  if ! command -v kind &>/dev/null; then
    error "'kind' CLI not found. Install it: brew install kind"
  fi

  CLUSTERS=$(kind get clusters 2>/dev/null || true)

  if [[ -z "${CLUSTERS}" ]]; then
    error "No kind clusters found. Run cnpg_restore.sh first."
  fi

  CLUSTER_COUNT=$(echo "${CLUSTERS}" | wc -l | tr -d ' ')

  if [[ "${CLUSTER_COUNT}" -eq 1 ]]; then
    CLUSTER_NAME="${CLUSTERS}"
    success "Auto-detected cluster: ${CLUSTER_NAME}"
  else
    info "Multiple kind clusters found:"
    echo "${CLUSTERS}" | nl -w2 -s'. '
    echo ""
    CLUSTER_NAME=$(echo "${CLUSTERS}" | head -1)
    warn "Using first cluster: ${CLUSTER_NAME}"
    warn "To check a different cluster, run: ./cnpg_verify.sh --cluster-name <name>"
  fi
fi

CONTEXT="kind-${CLUSTER_NAME}"
info "Using kubectl context: ${CONTEXT}"

# ─── Verify kubectl can reach the cluster ─────────────────────────────────────
step "Check 1 — Cluster connectivity"
if ! kubectl cluster-info --context "${CONTEXT}" &>/dev/null; then
  error "Cannot reach cluster '${CLUSTER_NAME}'. Is kind running? Try: kind get clusters"
fi
success "Cluster '${CLUSTER_NAME}' is reachable."

# ─── Check operator pods ───────────────────────────────────────────────────────
step "Check 2 — CNPG operator (cnpg-system namespace)"
echo ""
kubectl get pods --context "${CONTEXT}" -n cnpg-system
echo ""

OPERATOR_NOT_RUNNING=$(kubectl get pods --context "${CONTEXT}" -n cnpg-system \
  --no-headers 2>/dev/null | grep -v "Running" | grep -v "Completed" || true)

if [[ -z "${OPERATOR_NOT_RUNNING}" ]]; then
  success "CNPG operator pods are Running."
else
  warn "Some operator pods are not in Running state — they may still be starting up."
fi

# ─── Check database pods ──────────────────────────────────────────────────────
step "Check 3 — Database pods (default namespace)"
echo ""
kubectl get pods --context "${CONTEXT}" -n default
echo ""

DB_NOT_RUNNING=$(kubectl get pods --context "${CONTEXT}" -n default \
  --no-headers 2>/dev/null | grep -v "Running" | grep -v "Completed" || true)

if [[ -z "${DB_NOT_RUNNING}" ]]; then
  success "All database pods are Running."
else
  warn "Some pods are not yet Running. They may still be pulling images (can take 5-10 min)."
  warn "Re-run this script in a few minutes to check again."
fi

# ─── Check CNPG cluster resources ─────────────────────────────────────────────
step "Check 4 — CNPG cluster resources"
echo ""
CNPG_CLUSTERS=$(kubectl get clusters.postgresql.cnpg.io \
  --context "${CONTEXT}" -n default 2>/dev/null || true)

if [[ -z "${CNPG_CLUSTERS}" ]]; then
  warn "No CNPG cluster resources found in the default namespace."
  warn "If restore just completed, wait 1-2 minutes and re-run this script."
  warn "If it persists, check that cnpg-db-blueprints.yaml was exported and pushed to git."
else
  echo "${CNPG_CLUSTERS}"
  echo ""

  HEALTHY=$(echo "${CNPG_CLUSTERS}" | grep -c "healthy" || true)
  if [[ "${HEALTHY}" -gt 0 ]]; then
    success "CNPG cluster is in healthy state."
  else
    warn "CNPG cluster not yet healthy — it may still be initialising. Re-run in a minute."
  fi
fi

# ─── Optional: kubectl cnpg status ────────────────────────────────────────────
step "Check 5 — CNPG status (kubectl cnpg plugin)"
if command -v kubectl &>/dev/null && kubectl cnpg --help &>/dev/null 2>&1; then
  DB_CLUSTER_NAMES=$(kubectl get clusters.postgresql.cnpg.io \
    --context "${CONTEXT}" -n default \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

  if [[ -n "${DB_CLUSTER_NAMES}" ]]; then
    for db_cluster in ${DB_CLUSTER_NAMES}; do
      info "Running: kubectl cnpg status ${db_cluster}"
      kubectl cnpg status "${db_cluster}" \
        --context "${CONTEXT}" -n default 2>/dev/null || \
        warn "kubectl cnpg status failed for ${db_cluster} — cluster may still be starting."
      echo ""
    done
  else
    info "No CNPG clusters found to run status check on."
  fi
else
  info "kubectl cnpg plugin not installed — skipping status check."
  info "To install: kubectl krew install cnpg"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ Verification summary ━━━${NC}"
info "Cluster:  ${CLUSTER_NAME}"
info "Context:  ${CONTEXT}"
echo ""
success "Verification complete. Check output above for any warnings."
echo ""
echo "Useful commands:"
echo "  kubectl get pods    --context ${CONTEXT} -n default"
echo "  kubectl get pods    --context ${CONTEXT} -n cnpg-system"
echo "  kubectl get clusters.postgresql.cnpg.io --context ${CONTEXT} -n default"
echo ""
