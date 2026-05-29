#!/usr/bin/env bash
# =============================================================================
# docker-restore-prerequisite.sh
# Run this ONCE on the destination machine before running docker-cluster-restore.sh.
#
# What it checks / installs:
#   â Homebrew
#   â Docker Desktop (installed + daemon running)
#   â kind       (installs via brew if missing)
#   â kubectl    (installs via brew if missing)
#   â unzip      (installs via brew if missing)
#   â Internet connectivity (needed for CNPG operator download)
#   â Enough free disk space (warns if < 5 GB)
#
# Usage:
#   chmod +x prereqs_before_restore.sh
#   ./prereqs_before_restore.sh
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
echo -e "${BOLD}âââââââââââââââââââââââââââââââââââââââââââââââââââââââ${NC}"
echo -e "${BOLD}â    kind CNPG â Pre-Restore Prerequisite Check        â${NC}"
echo -e "${BOLD}â  Run before docker-cluster-restore.sh on dest Mac    â${NC}"
echo -e "${BOLD}ââââââââââââââââââââââââââââââââââââââââââââââââââââââââ${NC}"
echo ""

# âââ Step 1: Homebrew âââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
step "Step 1 â Homebrew"
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

# âââ Step 5: Install unzip ââââââââââââââââââââââââââââââââââââââââââââââââââââ
step "Step 5 â unzip"
if command -v unzip &>/dev/null; then
  success "unzip already available."
else
  info "Installing unzip via Homebrew..."
  brew install unzip
  success "unzip installed."
fi

# âââ Step 6: Internet connectivity âââââââââââââââââââââââââââââââââââââââââââ
step "Step 6 â Internet connectivity"
info "Checking connectivity to GitHub (needed to download CNPG operator)..."
if curl -sf --max-time 8 https://raw.githubusercontent.com > /dev/null 2>&1; then
  success "GitHub is reachable."
else
  flag_error "Cannot reach GitHub (raw.githubusercontent.com).
  The restore script downloads the CNPG operator manifest from GitHub.
  Check your network connection or VPN settings."
fi

# âââ Step 7: Disk space âââââââââââââââââââââââââââââââââââââââââââââââââââââââ
step "Step 7 â Disk space"
FREE_KB=$(df -k . | tail -1 | awk '{print $4}')
FREE_GB=$(( FREE_KB / 1024 / 1024 ))
info "Free disk space in current directory: ~${FREE_GB} GB"

if [[ "${FREE_GB}" -lt 3 ]]; then
  flag_error "Low disk space: ${FREE_GB} GB free. Loading the Docker snapshot requires ~2â3 GB. Free up space and re-run."
elif [[ "${FREE_GB}" -lt 6 ]]; then
  warn "Disk space is a bit low: ${FREE_GB} GB. Restore should fit but keep an eye on it."
else
  success "Disk space is sufficient: ${FREE_GB} GB free."
fi

# âââ Step 8: Check no conflicting kind cluster ââââââââââââââââââââââââââââââââ
step "Step 8 â Existing kind clusters"
EXISTING=$(kind get clusters 2>/dev/null || true)
if [[ -z "${EXISTING}" ]]; then
  success "No existing kind clusters â clean slate."
else
  echo ""
  warn "The following kind clusters already exist on this machine:"
  echo ""
  while IFS= read -r cl; do
    printf "    â¢ %s\n" "$cl"
  done <<< "${EXISTING}"
  echo ""
  warn "If the backup zip has the same cluster name as one above, the restore"
  warn "script will DELETE and re-create that cluster automatically."
  warn "Make sure you do not need the existing cluster before restoring."
fi

# âââ Summary ââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââââ
echo ""
echo -e "${BOLD}âââ Pre-restore check complete âââ${NC}"
echo ""

if [[ "${ERRORS}" -gt 0 ]]; then
  echo -e "  ${RED}${ERRORS} issue(s) found â fix the errors above before running docker-cluster-restore.sh.${NC}"
  echo ""
  exit 1
else
  echo -e "  ${GREEN}All checks passed â you are ready to run docker-cluster-restore.sh${NC}"
  echo ""
  echo -e "  ${BOLD}Next step â run the restore with your zip file:${NC}"
  echo ""
  echo "  ./docker-cluster-restore.sh ~/Downloads/kind-backup-<cluster>-<date>.zip"
  echo ""
  echo "  Example:"
  echo "  ./docker-cluster-restore.sh ~/Downloads/kind-backup-cnpg-20250528.zip"
  echo ""
fi
