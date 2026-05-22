#!/usr/bin/env bash
# =============================================================================
# restore-and-verify.sh
# Automates Part 3 (Restore) and Part 4 (Verify) of the
# Kind Cluster Backup & Restore Runbook.
#
# Usage:
#   ./restore-and-verify.sh
#
# The script will prompt you for:
#   - Git repo URL   (e.g. https://github.com/erswapnil/Kind-Cluster-Backup-and-restore.git)
#   - Cluster name   (e.g. klio, cnpg, pgconf)
#   - CNPG version   (e.g. 1.29.1)
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}\n"; }

# ── Helpers ───────────────────────────────────────────────────────────────────
check_command() {
    if ! command -v "$1" &>/dev/null; then
        error "Required command '$1' not found. Please install it and retry."
        exit 1
    fi
}

# ── Pre-flight: Docker Desktop must be running ─────────────────────────────────
check_docker_running() {
    info "Checking Docker Desktop is running..."
    if ! docker info &>/dev/null 2>&1; then
        error "Docker Desktop is not running."
        echo ""
        echo "  Install from: https://docker.com/products/docker-desktop"
        echo "  Start it, wait for the whale icon to go solid, then re-run this script."
        exit 1
    fi
    success "Docker Desktop is running."
}

# ── Install CNPG operator at exact version ─────────────────────────────────────
install_cnpg_operator() {
    local version="$1"
    local context="kind-${2}"

    # Derive the minor release branch (e.g. 1.28.1 → release-1.28)
    local major minor
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)
    local branch="release-${major}.${minor}"
    local manifest_url="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${branch}/releases/cnpg-${version}.yaml"

    info "Installing CNPG operator v${version} from branch ${branch}..."
    info "Manifest: ${manifest_url}"

    if kubectl apply --server-side \
        --context "${context}" \
        -f "${manifest_url}" 2>&1; then
        success "CNPG operator v${version} applied."
    else
        warn "kubectl apply returned an error — trying without --server-side..."
        if kubectl apply \
            --context "${context}" \
            -f "${manifest_url}" 2>&1; then
            success "CNPG operator v${version} applied (fallback mode)."
        else
            error "Failed to install CNPG operator v${version}."
            echo ""
            echo "  Check that this version exists:"
            echo "    ${manifest_url}"
            return 1
        fi
    fi

    info "Waiting for CNPG operator pods to become ready (up to 3 minutes)..."
    if kubectl rollout status deployment \
        --context "${context}" \
        -n cnpg-system \
        --timeout=180s 2>/dev/null; then
        success "CNPG operator is ready."
    else
        warn "Operator pods not ready within 3 minutes — continuing anyway."
        warn "Re-run cnpg_verify.sh once pods settle."
    fi
}

# ── Banner ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Kind Cluster — Automated Restore & Verify${RESET}"
echo -e "Covers Part 3 (Restore) and Part 4 (Verify) of the runbook."
echo "────────────────────────────────────────────────────────"

# ── Step 0: Collect inputs ────────────────────────────────────────────────────
header "Step 0: Gather inputs"

# Git repo URL
while true; do
    read -rp "$(echo -e "${BOLD}Git repo URL${RESET} (e.g. https://github.com/erswapnil/Kind-Cluster-Backup-and-restore.git): ")" GIT_REPO
    if [[ "$GIT_REPO" =~ ^https?:// ]]; then
        break
    fi
    warn "Please enter a valid https:// URL. Try again."
done

# Cluster name
while true; do
    read -rp "$(echo -e "${BOLD}Cluster name${RESET} (e.g. klio, cnpg, pgconf): ")" CLUSTER_NAME
    [[ -n "$CLUSTER_NAME" ]] && break
    warn "Cluster name cannot be empty. Please try again."
done

# CNPG version
while true; do
    read -rp "$(echo -e "${BOLD}CNPG operator version${RESET} (e.g. 1.29.1): ")" CNPG_VERSION
    if [[ "$CNPG_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
    fi
    warn "Version must be in the format X.Y.Z (e.g. 1.29.1). Please try again."
done

echo ""
echo -e "  Git repo     : ${BOLD}${GIT_REPO}${RESET}"
echo -e "  Cluster name : ${BOLD}${CLUSTER_NAME}${RESET}"
echo -e "  CNPG version : ${BOLD}${CNPG_VERSION}${RESET}"
echo ""
read -rp "$(echo -e "${YELLOW}Proceed with these values? [Y/n]: ${RESET}")" CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    info "Aborted by user."
    exit 0
fi

# ── Step 1: Pre-flight checks ─────────────────────────────────────────────────
header "Step 1: Pre-flight checks"

check_command curl
check_command chmod
check_docker_running

# ── Step 2: Download and run cnpg_prereqs.sh (Step 9 in runbook) ─────────────
header "Step 2: Install prerequisites (cnpg_prereqs.sh)"

PREREQS_SCRIPT="cnpg_prereqs.sh"
PREREQS_URL="https://raw.githubusercontent.com/erswapnil/Kind-Cluster-Backup-and-restore/main/cnpg_prereqs.sh"

info "Downloading ${PREREQS_SCRIPT}..."
if curl -fsSL "${PREREQS_URL}" -o "${PREREQS_SCRIPT}"; then
    success "Downloaded ${PREREQS_SCRIPT}"
else
    error "Failed to download ${PREREQS_SCRIPT} from ${PREREQS_URL}"
    exit 1
fi

chmod +x "${PREREQS_SCRIPT}"
info "Running ${PREREQS_SCRIPT}..."
echo "────────────────────────────────────────────────────────"
./"${PREREQS_SCRIPT}"
echo "────────────────────────────────────────────────────────"
success "Prerequisites installed."

# ── Step 3: Verify cnpg_restore.sh is present ────────────────────────────────
header "Step 3: Check restore script is ready"

RESTORE_SCRIPT="cnpg_restore.sh"

if [[ ! -f "${RESTORE_SCRIPT}" ]]; then
    warn "${RESTORE_SCRIPT} not found in current directory — downloading it now..."
    RESTORE_URL="https://raw.githubusercontent.com/erswapnil/Kind-Cluster-Backup-and-restore/main/cnpg_restore.sh"
    if curl -fsSL "${RESTORE_URL}" -o "${RESTORE_SCRIPT}"; then
        chmod +x "${RESTORE_SCRIPT}"
        success "Downloaded ${RESTORE_SCRIPT}"
    else
        error "Failed to download ${RESTORE_SCRIPT}."
        exit 1
    fi
else
    success "${RESTORE_SCRIPT} is already present."
    chmod +x "${RESTORE_SCRIPT}"
fi

# ── Step 4: Run cnpg_restore.sh (Step 10 in runbook) ─────────────────────────
header "Step 4: Restore cluster '${CLUSTER_NAME}' (cnpg_restore.sh)"

info "Running: ./${RESTORE_SCRIPT} --git-repo ${GIT_REPO} --cluster-name ${CLUSTER_NAME} --cnpg-version ${CNPG_VERSION}"
echo "────────────────────────────────────────────────────────"
if ./"${RESTORE_SCRIPT}" \
    --git-repo     "${GIT_REPO}" \
    --cluster-name "${CLUSTER_NAME}" \
    --cnpg-version "${CNPG_VERSION}"; then
    echo "────────────────────────────────────────────────────────"
    success "Restore completed for cluster '${CLUSTER_NAME}'."
else
    echo "────────────────────────────────────────────────────────"
    error "Restore script exited with an error."
    echo ""
    echo "  Common causes:"
    echo "  • Snapshot tar missing — ensure <cluster>/<cluster>-snapshot.tar exists in the repo"
    echo "  • kind cluster name conflict — run: kind delete cluster --name ${CLUSTER_NAME}"
    echo "  • Worker node count mismatch — edit ${RESTORE_SCRIPT} to match your source cluster"
    echo "  • Wrong git repo — double-check the repo URL contains the cluster subfolder"
    exit 1
fi

# ── Step 5: Install CNPG operator at exact user-specified version ─────────────
header "Step 5: Install CNPG operator v${CNPG_VERSION}"

install_cnpg_operator "${CNPG_VERSION}" "${CLUSTER_NAME}"

# ── Step 6: Download and run cnpg_verify.sh (Step 11 in runbook) ─────────────
header "Step 6: Verify cluster health (cnpg_verify.sh)"

VERIFY_SCRIPT="cnpg_verify.sh"
VERIFY_URL="https://raw.githubusercontent.com/erswapnil/Kind-Cluster-Backup-and-restore/main/cnpg_verify.sh"

if [[ ! -f "${VERIFY_SCRIPT}" ]]; then
    info "Downloading ${VERIFY_SCRIPT}..."
    if curl -fsSL "${VERIFY_URL}" -o "${VERIFY_SCRIPT}"; then
        success "Downloaded ${VERIFY_SCRIPT}"
    else
        error "Failed to download ${VERIFY_SCRIPT}."
        exit 1
    fi
else
    success "${VERIFY_SCRIPT} already present."
fi

chmod +x "${VERIFY_SCRIPT}"

info "Running: ./${VERIFY_SCRIPT} --cluster-name ${CLUSTER_NAME}"
echo "────────────────────────────────────────────────────────"
if ./"${VERIFY_SCRIPT}" --cluster-name "${CLUSTER_NAME}"; then
    echo "────────────────────────────────────────────────────────"
    success "Cluster '${CLUSTER_NAME}' verified successfully."
else
    echo "────────────────────────────────────────────────────────"
    warn "Verify script reported issues."
    echo ""
    echo "  If pods are in PodInitializing, wait 5–10 minutes for the PostgreSQL"
    echo "  image to pull from ghcr.io, then re-run:"
    echo ""
    echo "    ./${VERIFY_SCRIPT} --cluster-name ${CLUSTER_NAME}"
    echo ""
    echo "  Expected healthy output:"
    echo "    klio-server-klio-0      1/1  Running"
    echo "    my-postgres-cluster-1   2/2  Running"
    echo "    my-postgres-cluster-2   2/2  Running"
    echo "    STATUS: Cluster in healthy state."
    exit 1
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║  All done! Cluster '${CLUSTER_NAME}' is restored and healthy.  ║${RESET}"
echo -e "${BOLD}${GREEN}║  CNPG operator v${CNPG_VERSION} is installed and running.       ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
