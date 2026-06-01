#!/usr/bin/env bash
# =============================================================================
# docker-restore-prerequisite.sh
# Run ONCE on the destination machine before running docker-cluster-restore.sh.
# Supports: macOS (Homebrew) + Linux (RHEL/CentOS/Ubuntu/Debian)
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

# --- Detect OS ---
OS="unknown"
PKG_MGR="unknown"
if [[ "$(uname -s)" == "Darwin" ]]; then
  OS="macos"
elif [[ -f /etc/os-release ]]; then
  source /etc/os-release
  case "${ID}" in
    rhel|centos|fedora|rocky|almalinux) OS="rhel";   PKG_MGR="dnf" ;;
    ubuntu|debian|linuxmint)            OS="debian";  PKG_MGR="apt" ;;
    *)                                  OS="linux";   PKG_MGR="dnf" ;;
  esac
fi

echo ""
echo -e "${BOLD}=======================================================${NC}"
echo -e "${BOLD}   kind CNPG - Pre-Restore Prerequisite Check          ${NC}"
echo -e "${BOLD}   Supports: macOS / RHEL / Ubuntu                     ${NC}"
echo -e "${BOLD}=======================================================${NC}"
echo ""
info "Detected OS: ${OS}"
echo ""

# ── Install helpers ────────────────────────────────────────────────────────────
install_brew_pkg() { info "Installing $1 via Homebrew..."; brew install "$1"; }

install_linux_pkg() {
  info "Installing $1 via ${PKG_MGR}..."
  if [[ "${PKG_MGR}" == "dnf" ]]; then sudo dnf install -y "$1"
  else sudo apt-get install -y "$1"; fi
}

install_kind_linux() {
  info "Installing kind binary for Linux..."
  ARCH=$(uname -m)
  [[ "${ARCH}" == "x86_64" ]] && ARCH="amd64"
  [[ "${ARCH}" == "aarch64" ]] && ARCH="arm64"
  KIND_VERSION=$(curl -s https://api.github.com/repos/kubernetes-sigs/kind/releases/latest \
    | grep '"tag_name"' | cut -d'"' -f4)
  curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}" -o /usr/local/bin/kind
  chmod +x /usr/local/bin/kind
  success "kind installed: $(kind version)"
}

install_kubectl_linux() {
  info "Installing kubectl for Linux..."
  ARCH=$(uname -m)
  [[ "${ARCH}" == "x86_64" ]] && ARCH="amd64"
  [[ "${ARCH}" == "aarch64" ]] && ARCH="arm64"
  K8S_VER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  curl -fsSL "https://dl.k8s.io/release/${K8S_VER}/bin/linux/${ARCH}/kubectl" -o /usr/local/bin/kubectl
  chmod +x /usr/local/bin/kubectl
  success "kubectl installed."
}

install_gitlfs_linux() {
  if [[ "${PKG_MGR}" == "dnf" ]]; then
    if ! rpm -q epel-release &>/dev/null 2>&1; then
      info "Enabling EPEL repository..."
      sudo dnf install -y epel-release 2>/dev/null || \
        sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm
    fi
    sudo dnf install -y git-lfs
  else
    sudo apt-get install -y git-lfs
  fi
}

# --- Step 1: Package manager ---
step "Step 1 - Package manager"
if [[ "${OS}" == "macos" ]]; then
  command -v brew &>/dev/null && success "Homebrew found: $(brew --version | head -1)" \
    || error "Homebrew not installed. Install from https://brew.sh"
elif [[ "${PKG_MGR}" == "dnf" ]]; then
  command -v dnf &>/dev/null && success "dnf found" || error "dnf not found."
else
  command -v apt-get &>/dev/null && success "apt-get found" || error "apt-get not found."
  sudo apt-get update -qq
fi

# --- Step 2: Docker ---
step "Step 2 - Docker"
if ! command -v docker &>/dev/null; then
  if [[ "${OS}" == "macos" ]]; then
    echo "  Install Docker Desktop from: https://docker.com/products/docker-desktop"
    error "Docker Desktop required."
  elif [[ "${PKG_MGR}" == "dnf" ]]; then
    info "Installing Docker Engine on RHEL/CentOS..."
    sudo dnf install -y dnf-plugins-core
    sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo 2>/dev/null || \
      sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    sudo dnf install -y docker-ce docker-ce-cli containerd.io
    sudo systemctl enable docker && sudo systemctl start docker
    success "Docker Engine installed and started."
  else
    info "Installing Docker Engine on Ubuntu/Debian..."
    sudo apt-get install -y ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -qq && sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    sudo systemctl enable docker && sudo systemctl start docker
    success "Docker Engine installed and started."
  fi
fi
success "Docker binary found: $(command -v docker)"

if ! docker info &>/dev/null 2>&1; then
  if [[ "${OS}" == "macos" ]]; then
    error "Docker Desktop not running. Open it and wait for whale icon to go solid."
  else
    info "Starting Docker service..."
    sudo systemctl start docker || error "Could not start Docker. Run: sudo systemctl start docker"
  fi
fi
success "Docker daemon is running."
info "Docker version: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'unknown')"

# --- Step 3: kind ---
step "Step 3 - kind"
if command -v kind &>/dev/null; then
  success "kind already installed: $(kind version)"
else
  [[ "${OS}" == "macos" ]] && install_brew_pkg kind || install_kind_linux
fi

# --- Step 4: kubectl ---
step "Step 4 - kubectl"
if command -v kubectl &>/dev/null; then
  success "kubectl already installed: $(kubectl version --client 2>/dev/null | head -1)"
else
  [[ "${OS}" == "macos" ]] && install_brew_pkg kubectl || install_kubectl_linux
fi

# --- Step 5: git ---
step "Step 5 - git"
if command -v git &>/dev/null; then
  success "git already installed: $(git --version)"
else
  [[ "${OS}" == "macos" ]] && install_brew_pkg git || install_linux_pkg git
fi

# --- Step 6: git-lfs ---
step "Step 6 - git-lfs"
if command -v git-lfs &>/dev/null; then
  success "git-lfs already installed: $(git-lfs version)"
else
  [[ "${OS}" == "macos" ]] && install_brew_pkg git-lfs || install_gitlfs_linux
  git lfs install
  success "git-lfs installed: $(git-lfs version)"
fi
if ! git lfs env &>/dev/null 2>&1; then git lfs install; fi
success "git-lfs is initialized."

# --- Step 7: python3 ---
step "Step 7 - python3"
if command -v python3 &>/dev/null; then
  success "python3 already installed: $(python3 --version)"
else
  [[ "${OS}" == "macos" ]] && install_brew_pkg python3 || install_linux_pkg python3
fi

# --- Step 8: curl ---
step "Step 8 - curl"
if command -v curl &>/dev/null; then
  success "curl found: $(curl --version | head -1)"
else
  [[ "${OS}" == "macos" ]] && install_brew_pkg curl || install_linux_pkg curl
fi

# --- Step 9: Internet connectivity ---
step "Step 9 - Internet connectivity"
if curl -sf --max-time 8 https://raw.githubusercontent.com > /dev/null 2>&1; then
  success "GitHub is reachable."
else
  flag_error "Cannot reach GitHub. Check network or VPN."
fi
if curl -sf --max-time 8 https://api.github.com > /dev/null 2>&1; then
  success "GitHub API is reachable."
else
  flag_error "Cannot reach GitHub API. Check network or VPN."
fi

# --- Step 10: Disk space ---
step "Step 10 - Disk space"
FREE_KB=$(df -k . | tail -1 | awk '{print $4}')
FREE_GB=$(( FREE_KB / 1024 / 1024 ))
info "Free disk space: ~${FREE_GB} GB"
if [[ "${FREE_GB}" -lt 3 ]]; then
  flag_error "Low disk space: ${FREE_GB} GB. Need at least 3 GB to load Docker snapshot."
elif [[ "${FREE_GB}" -lt 6 ]]; then
  warn "Disk space tight: ${FREE_GB} GB. Restore should fit but keep an eye on it."
else
  success "Disk space sufficient: ${FREE_GB} GB free."
fi

# --- Step 11: Existing kind clusters ---
step "Step 11 - Existing kind clusters"
EXISTING=$(kind get clusters 2>/dev/null || true)
if [[ -z "${EXISTING}" ]]; then
  success "No existing kind clusters - clean slate."
else
  warn "Existing clusters on this machine:"
  while IFS= read -r cl; do printf "    * %s\n" "$cl"; done <<< "${EXISTING}"
  warn "If your backup has the same cluster name, restore will offer to delete it first."
fi

# --- Summary ---
echo ""
echo -e "${BOLD}--- Pre-restore check complete ---${NC}"
echo ""
if [[ "${ERRORS}" -gt 0 ]]; then
  echo -e "  ${RED}${ERRORS} issue(s) found - fix above before running docker-cluster-restore.sh.${NC}"
  echo ""; exit 1
else
  echo -e "  ${GREEN}All checks passed - you are ready to run docker-cluster-restore.sh${NC}"
  echo ""
  echo -e "  ${BOLD}Next step:${NC}"
  echo "  ./docker-cluster-restore.sh"
  echo ""
fi
