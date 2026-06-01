#!/usr/bin/env bash
# =============================================================================
# docker-restore-prerequisite.sh
# Run this ONCE on the destination machine before running docker-cluster-restore.sh.
#
# What it checks / installs:
#   - Homebrew
#   - Docker Desktop (installed + daemon running)
#   - kind       (installs via brew if missing)
#   - kubectl    (installs via brew if missing)
#   - git        (installs via brew if missing)
#   - git-lfs    (installs via brew if missing)
#   - python3    (installs via brew if missing)
#   - curl       (built-in on macOS, verified)
#   - Internet connectivity (needed for CNPG operator download)
#   - Enough free disk space (warns if < 5 GB)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}--- $* ---${NC}"; }

ERRORS=0
flag_error() { warn "$*"; ERRORS=$(( ERRORS + 1 )); }

echo ""
echo -e "${BOLD}=======================================================${NC}"
echo -e "${BOLD}   kind CNPG - Pre-Restore Prerequisite Check          ${NC}"
echo -e "${BOLD}   Run before docker-cluster-restore.sh on target Mac  ${NC}"
echo -e "${BOLD}=======================================================${NC}"
echo ""

# --- Step 1: Homebrew ---
step "Step 1 - Homebrew"
if command -v brew &>/dev/null; then
  success "Homebrew found: $(brew --version | head -1)"
else
  echo ""
  echo -e "  ${RED}Homebrew is not installed.${NC}"
  echo ""
  echo "  Install it by running this command in Terminal:"
  echo ""
  echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  echo ""
  echo "  Then re-run this script."
  error "Homebrew is required."
fi

# --- Step 2: Docker Desktop ---
step "Step 2 - Docker Desktop"
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
  echo "  -> Open Docker Desktop from Applications"
  echo "  -> Wait for the whale icon in the menu bar to go solid (not spinning)"
  echo "  -> Then re-run this script"
  echo ""
  error "Docker daemon must be running."
fi
success "Docker daemon is running."
info "Docker version: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'unknown')"

# --- Step 3: kind ---
step "Step 3 - kind"
if command -v kind &>/dev/null; then
  success "kind already installed: $(kind version)"
else
  info "Installing kind via Homebrew..."
  brew install kind
  success "kind installed: $(kind version)"
fi

# --- Step 4: kubectl ---
step "Step 4 - kubectl"
if command -v kubectl &>/dev/null; then
  success "kubectl already installed: $(kubectl version --client 2>/dev/null | head -1)"
else
  info "Installing kubectl via Homebrew..."
  brew install kubectl
  success "kubectl installed."
fi

# --- Step 5: git ---
step "Step 5 - git"
if command -v git &>/dev/null; then
  success "git already installed: $(git --version)"
else
  info "Installing git via Homebrew..."
  brew install git
  success "git installed: $(git --version)"
fi

# --- Step 6: git-lfs ---
step "Step 6 - git-lfs"
if command -v git-lfs &>/dev/null; then
  success "git-lfs already installed: $(git-lfs version)"
else
  info "Installing git-lfs via Homebrew..."
  brew install git-lfs
  git lfs install
  success "git-lfs installed: $(git-lfs version)"
fi

# Ensure git lfs is initialized globally
if ! git lfs env &>/dev/null 2>&1; then
  info "Initializing git-lfs globally..."
  git lfs install
fi
success "git-lfs is initialized."

# --- Step 7: python3 ---
step "Step 7 - python3"
if command -v python3 &>/dev/null; then
  success "python3 already installed: $(python3 --version)"
else
  info "Installing python3 via Homebrew..."
  brew install python3
  success "python3 installed: $(python3 --version)"
fi

# --- Step 8: curl ---
step "Step 8 - curl"
if command -v curl &>/dev/null; then
  success "curl found: $(curl --version | head -1)"
else
  info "Installing curl via Homebrew..."
  brew install curl
  success "curl installed."
fi

# --- Step 9: Internet connectivity ---
step "Step 9 - Internet connectivity"
info "Checking connectivity to GitHub (needed to download backup and CNPG operator)..."
if curl -sf --max-time 8 https://raw.githubusercontent.com > /dev/null 2>&1; then
  success "GitHub is reachable."
else
  flag_error "Cannot reach GitHub (raw.githubusercontent.com). Check your network connection or VPN settings."
fi

info "Checking connectivity to GitHub API (needed to list backup folders)..."
if curl -sf --max-time 8 https://api.github.com > /dev/null 2>&1; then
  success "GitHub API is reachable."
else
  flag_error "Cannot reach GitHub API (api.github.com). Check your network connection or VPN settings."
fi

# --- Step 10: Disk space ---
step "Step 10 - Disk space"
FREE_KB=$(df -k . | tail -1 | awk '{print $4}')
FREE_GB=$(( FREE_KB / 1024 / 1024 ))
info "Free disk space in current directory: ~${FREE_GB} GB"

if [[ "${FREE_GB}" -lt 3 ]]; then
  flag_error "Low disk space: ${FREE_GB} GB free. Loading the Docker snapshot requires ~2-3 GB. Free up space and re-run."
elif [[ "${FREE_GB}" -lt 6 ]]; then
  warn "Disk space is a bit low: ${FREE_GB} GB. Restore should fit but keep an eye on it."
else
  success "Disk space is sufficient: ${FREE_GB} GB free."
fi

# --- Step 11: Existing kind clusters ---
step "Step 11 - Existing kind clusters"
EXISTING=$(kind get clusters 2>/dev/null || true)
if [[ -z "${EXISTING}" ]]; then
  success "No existing kind clusters - clean slate."
else
  echo ""
  warn "The following kind clusters already exist on this machine:"
  echo ""
  while IFS= read -r cl; do
    printf "    * %s\n" "$cl"
  done <<< "${EXISTING}"
  echo ""
  warn "If the backup you select has the same cluster name as one above,"
  warn "the restore script will offer to DELETE and re-create it."
  warn "Make sure you do not need the existing cluster before restoring."
fi

# --- Summary ---
echo ""
echo -e "${BOLD}--- Pre-restore check complete ---${NC}"
echo ""

if [[ "${ERRORS}" -gt 0 ]]; then
  echo -e "  ${RED}${ERRORS} issue(s) found - fix the errors above before running docker-cluster-restore.sh.${NC}"
  echo ""
  exit 1
else
  echo -e "  ${GREEN}All checks passed - you are ready to run docker-cluster-restore.sh${NC}"
  echo ""
  echo -e "  ${BOLD}Next step:${NC}"
  echo "  ./docker-cluster-restore.sh"
  echo ""
fi
