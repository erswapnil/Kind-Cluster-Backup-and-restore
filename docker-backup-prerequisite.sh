#!/usr/bin/env bash
# =============================================================================
# docker-backup-prerequisite.sh
# Run this ONCE on the source machine before running docker-cluster-backup.sh.
#
# What it checks / installs:
#   â Homebrew
#   â Docker Desktop (installed + daemon running)
#   â kind       (installs via brew if missing)
#   â kubectl    (installs via brew if missing)
#   â zip        (installs via brew if missing)
#   â At least one kind cluster exists
#   â Enough free disk space (warns if < 5 GB)
#
# Usage:
#   chmod +x prereqs_before_backup.sh
#   ./prereqs_before_backup.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}âââ $* âââ${NC}"; }

ERRORS=0
flag_error() { warn "$*"; ERRORS=$(( ERRORS + 1 )); }

echo ""
echo -e "${BOLD}ââââââââââââââââââââââââââââââââââââââââââââââââââââââââ${NC}"
echo -e "${BOLD}â     kind CNPG â Pre-Backup Prerequisite Check        â${NC}"
echo -e "${BOLD}â  Run before docker-cluster-backup.sh on source Mac   â${NC}"
echo -e "${BOLD}ââââââââââââââââââââââââââââââââââââââââââââââââââââââââ${NC}"
echo ""

# âââ Step 1: Homebrew âââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
step "Step 1 â Homebrew"
if command -v brew &>/dev/null; then
  success "Homebrew found: $(brew --version | head -1)"
else
  error "Homebrew is not installed.
Install it from https://brew.sh and re-run this script."
fi

# âââ Step 2: Docker Desktop âââââââââââââââââââââââââââââââââââââââââââââââââââ
step "Step 2 â Docker Desktop"
if ! command -v docker &>/dev/null; then
  echo ""
  echo -e "  ${RED}Docker Desktop is not installed.${NC}"
  echo ""
  echo "  Install it from: https://docker.com/products/docker-desktop"
  echo "  After installing, open Docker Desktop and wait for the whale"
  echo "  icon in the menu bar to become steady, then re-run this script."
  echo ""
  error "Docker Desktop required."
fi
success "Docker binary found: $(command -v docker)"

if ! docker info &>/dev/null 2>&1; then
  echo ""
  echo -e "  ${YELLOW}Docker Desktop is installed but not running.${NC}"
  echo ""
  echo "  â Open Docker Desktop from Applications"
  echo "  â Wait for the whale icon in the menu bar to go solid (not spinning)"
  echo "  â Then re-run this script"
  echo ""
  error "Docker daemon must be running."
fi
success "Docker daemon is running."
info "Docker version: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'unknown')"

# âââ Step 3: Install kind âââââââââââââââââââââââââââââââââââââââââââââââââââââ
step "Step 3 â kind"
if command -v kind &>/dev/null; then
  success "kind already installed: $(kind version)"
else
  info "Installing kind via Homebrew..."
  brew install kind
  success "kind installed: $(kind version)"
fi

# âââ Step 4: Install kubectl ââââââââââââââââââââââââââââââââââââââââââââââââââ
step "Step 4 â kubectl"
if command -v kubectl &>/dev/null; then
  success "kubectl already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client | head -1)"
else
  info "Installing kubectl via Homebrew..."
  brew install kubectl
  success "kubectl installed."
fi

# âââ Step 5: Install zip ââââââââââââââââââââââââââââââââââââââââââââââââââââââ
step "Step 5 â zip"
if command -v zip &>/dev/null; then
  success "zip already available."
else
  info "Installing zip via Homebrew..."
  brew install zip
  success "zip installed."
fi

# âââ Step 6: Verify kind cluster exists âââââââââââââââââââââââââââââââââââââââ
step "Step 6 â kind cluster check"
CLUSTERS=$(kind get clusters 2>/dev/null || true)
if [[ -z "${CLUSTERS}" ]]; then
  flag_error "No kind clusters found. You need a running cluster to back up."
  echo ""
  echo "  Create one with:"
  echo "  kind create cluster --name my-cluster"
  echo ""
else
  CLUSTER_COUNT=$(echo "${CLUSTERS}" | wc -l | tr -d ' ')
  success "${CLUSTER_COUNT} kind cluster(s) found:"
  echo ""
  i=1
  while IFS= read -r cl; do
    printf "    %-3s %s\n" "$i." "$cl"
    ((i++))
  done <<< "${CLUSTERS}"
  echo ""
fi

# âââ Step 7: Disk space check âââââââââââââââââââââââââââââââââââââââââââââââââ
step "Step 7 â Disk space"
FREE_KB=$(df -k . | tail -1 | awk '{print $4}')
FREE_GB=$(( FREE_KB / 1024 / 1024 ))
info "Free disk space in current directory: ~${FREE_GB} GB"

if [[ "${FREE_GB}" -lt 3 ]]; then
  flag_error "Low disk space: ${FREE_GB} GB free. A CNPG snapshot can be 500 MB â 1 GB; you need ~3Ã that. Free up space and re-run."
elif [[ "${FREE_GB}" -lt 5 ]]; then
  warn "Disk space is tight: ${FREE_GB} GB free. Backup will likely still fit but it is close."
else
  success "Disk space is sufficient: ${FREE_GB} GB free."
fi

# âââ Summary ââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
echo ""
echo -e "${BOLD}âââ Pre-backup check complete âââ${NC}"
echo ""

if [[ "${ERRORS}" -gt 0 ]]; then
  echo -e "  ${RED}${ERRORS} issue(s) found â fix the errors above before running docker-cluster-backup.sh.${NC}"
  echo ""
  exit 1
else
  echo -e "  ${GREEN}All checks passed â you are ready to run docker-cluster-backup.sh${NC}"
  echo ""
  echo -e "  ${BOLD}Next step:${NC}"
  echo "  ./docker-cluster-backup.sh"
  echo ""
fi
