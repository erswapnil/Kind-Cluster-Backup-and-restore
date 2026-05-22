#!/usr/bin/env bash
# =============================================================================
# docker-restore-prerequisite.sh
# Checks and installs all tools required to run docker-cluster-restore.sh
# on the TARGET machine (the machine you want to restore the kind cluster onto).
#
# Tools checked / installed:
#   - Homebrew  (macOS only — package manager)
#   - Docker Desktop (must be installed manually if missing)
#   - curl      (to download restore scripts and GitHub API calls)
#   - python3   (for JSON parsing of GitHub API responses)
#   - kind      (to create and manage local Kubernetes clusters)
#   - kubectl   (to apply manifests and check cluster health)
#   - git-lfs   (to download large Docker snapshot .tar files from GitHub)
#
# Note: The restore script (docker-cluster-restore.sh) also runs cnpg_prereqs.sh
# automatically, which re-checks kind/kubectl/git-lfs. Running this script first
# ensures a clean environment before any restore attempt.
#
# Usage:
#   chmod +x docker-restore-prerequisite.sh && ./docker-restore-prerequisite.sh
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}═══ $* ═══${RESET}\n"; }
divider() { echo "────────────────────────────────────────────────────────"; }

INSTALL_LOG=()

# ── Detect OS ─────────────────────────────────────────────────────────────────
OS="$(uname -s)"
case "$OS" in
    Darwin) PLATFORM="macOS" ;;
    Linux)  PLATFORM="Linux" ;;
    *)      error "Unsupported OS: ${OS}"; exit 1 ;;
esac

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║      Restore Prerequisite Installer                  ║${RESET}"
echo -e "${BOLD}${CYAN}║      TARGET machine setup for docker-cluster-restore ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Platform detected: ${BOLD}${PLATFORM}${RESET}"
echo ""

# ── Helper: install via brew ──────────────────────────────────────────────────
brew_install() {
    local pkg="$1"
    if brew list "$pkg" &>/dev/null 2>&1; then
        success "${pkg} already installed (brew)."
    else
        info "Installing ${pkg} via Homebrew..."
        brew install "$pkg"
        success "${pkg} installed."
        INSTALL_LOG+=("$pkg")
    fi
}

# ── Helper: install via apt ───────────────────────────────────────────────────
apt_install() {
    local pkg="$1"
    if dpkg -l "$pkg" &>/dev/null 2>&1; then
        success "${pkg} already installed (apt)."
    else
        info "Installing ${pkg} via apt..."
        sudo apt-get install -y "$pkg"
        success "${pkg} installed."
        INSTALL_LOG+=("$pkg")
    fi
}

# ── Step 1: Homebrew (macOS only) ─────────────────────────────────────────────
if [[ "$PLATFORM" == "macOS" ]]; then
    header "Step 1 · Homebrew"
    if command -v brew &>/dev/null; then
        success "Homebrew is installed: $(brew --version | head -1)"
    else
        warn "Homebrew not found. Installing..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        success "Homebrew installed."
        INSTALL_LOG+=("homebrew")
    fi
else
    header "Step 1 · apt-get update (Linux)"
    sudo apt-get update -qq
    success "Package index updated."
fi

# ── Step 2: curl ──────────────────────────────────────────────────────────────
header "Step 2 · curl"
if command -v curl &>/dev/null; then
    success "curl is installed: $(curl --version | head -1 | cut -d' ' -f1-2)"
else
    [[ "$PLATFORM" == "macOS" ]] && brew_install "curl" || apt_install "curl"
fi

# ── Step 3: python3 ───────────────────────────────────────────────────────────
header "Step 3 · python3"
if command -v python3 &>/dev/null; then
    success "python3 is installed: $(python3 --version)"
else
    if [[ "$PLATFORM" == "macOS" ]]; then
        brew_install "python3"
    else
        apt_install "python3"
    fi
fi

# ── Step 4: git-lfs ───────────────────────────────────────────────────────────
header "Step 4 · git-lfs"
if git lfs version &>/dev/null 2>&1; then
    success "git-lfs is installed: $(git lfs version)"
else
    if [[ "$PLATFORM" == "macOS" ]]; then
        brew_install "git-lfs"
    else
        apt_install "git-lfs"
    fi
    git lfs install
    success "git-lfs configured globally."
    INSTALL_LOG+=("git-lfs-init")
fi

# ── Step 5: kind ──────────────────────────────────────────────────────────────
header "Step 5 · kind (Kubernetes IN Docker)"
if command -v kind &>/dev/null; then
    success "kind is installed: $(kind --version)"
else
    if [[ "$PLATFORM" == "macOS" ]]; then
        brew_install "kind"
    else
        info "Installing kind on Linux..."
        KIND_VERSION="$(curl -Ls https://api.github.com/repos/kubernetes-sigs/kind/releases/latest \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")"
        curl -Lo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
        chmod +x ./kind
        sudo mv ./kind /usr/local/bin/kind
        success "kind installed."
        INSTALL_LOG+=("kind")
    fi
fi

# ── Step 6: kubectl ───────────────────────────────────────────────────────────
header "Step 6 · kubectl"
if command -v kubectl &>/dev/null; then
    success "kubectl is installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
else
    if [[ "$PLATFORM" == "macOS" ]]; then
        brew_install "kubectl"
    else
        info "Installing kubectl on Linux..."
        curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/kubectl
        success "kubectl installed."
        INSTALL_LOG+=("kubectl")
    fi
fi

# ── Step 7: Docker ────────────────────────────────────────────────────────────
header "Step 7 · Docker"
if command -v docker &>/dev/null; then
    success "docker CLI is installed: $(docker --version)"
    echo ""
    info "Checking if Docker daemon is running..."
    if docker info &>/dev/null 2>&1; then
        success "Docker daemon is running."
    else
        echo ""
        warn "Docker is installed but the daemon is NOT running."
        echo ""
        if [[ "$PLATFORM" == "macOS" ]]; then
            echo -e "  ${YELLOW}Action required:${RESET}"
            echo -e "  Open Docker Desktop from Applications and wait for the whale icon"
            echo -e "  in the menu bar to become solid (not animated)."
        else
            echo -e "  ${YELLOW}Action required:${RESET}"
            echo -e "  Run:  sudo systemctl start docker"
        fi
        echo ""
        error "Docker must be running before you can use docker-cluster-restore.sh"
        exit 1
    fi
else
    echo ""
    warn "Docker is not installed. Installing now..."
    echo ""
    if [[ "$PLATFORM" == "macOS" ]]; then
        info "Installing Docker Desktop via Homebrew Cask..."
        brew install --cask docker
        success "Docker Desktop installed."
        echo ""
        echo -e "  ${YELLOW}One manual step required:${RESET}"
        echo -e "  1. Open Docker Desktop: ${CYAN}open -a Docker${RESET}"
        echo -e "  2. Complete the setup wizard (accept the license)"
        echo -e "  3. Wait for the whale icon in the menu bar to become solid"
        echo -e "  4. Re-run this script"
        echo ""
        info "Opening Docker Desktop now..."
        open -a Docker 2>/dev/null || true
    else
        echo -e "  ${YELLOW}Installing Docker Engine on Linux...${RESET}"
        curl -fsSL https://get.docker.com | sudo bash
        sudo usermod -aG docker "$USER"
        echo ""
        warn "Docker installed. You may need to log out and log back in for group changes."
        echo -e "  Then run:  sudo systemctl start docker"
    fi
    echo ""
    error "Docker is installed but needs to finish starting up. Re-run this script once the whale icon is solid."
    exit 1
fi

# ── Step 8: Disk space check ──────────────────────────────────────────────────
header "Step 8 · Disk space check"

AVAIL_GB=$(df -g / 2>/dev/null | awk 'NR==2 {print $4}' || df -BG / 2>/dev/null | awk 'NR==2 {gsub("G",""); print $4}' || echo "unknown")

if [[ "$AVAIL_GB" == "unknown" ]]; then
    warn "Could not determine available disk space. Ensure you have at least 20 GB free."
elif (( AVAIL_GB < 20 )); then
    warn "Only ${AVAIL_GB} GB available. Docker image snapshots can be 5-15 GB."
    echo -e "  ${YELLOW}Recommend at least 20 GB free before restoring.${RESET}"
else
    success "Disk space OK: ${AVAIL_GB} GB available."
fi

# ── Step 9: Docker resources check (macOS) ────────────────────────────────────
if [[ "$PLATFORM" == "macOS" ]]; then
    header "Step 9 · Docker Desktop resource recommendation"
    echo -e "  ${CYAN}Recommendation for kind cluster restore:${RESET}"
    echo -e "  In Docker Desktop > Settings > Resources, ensure:"
    echo -e "    ${BOLD}CPUs:${RESET}   4 or more"
    echo -e "    ${BOLD}Memory:${RESET} 8 GB or more"
    echo -e "    ${BOLD}Disk:${RESET}   60 GB or more (for snapshot loading)"
    echo ""
    info "Check your Docker Desktop settings if the restore step hangs."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
divider
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║  Prerequisites check complete!                               ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""

if [[ ${#INSTALL_LOG[@]} -eq 0 ]]; then
    success "All tools were already installed. No changes were made."
else
    info "Newly installed: ${INSTALL_LOG[*]}"
fi

echo ""
echo -e "  ${BOLD}You are ready to run the restore script:${RESET}"
echo ""
echo -e "  ${CYAN}curl -fsSL https://raw.githubusercontent.com/erswapnil/Kind-Cluster-Backup-and-restore/main/docker-cluster-restore.sh \\${RESET}"
echo -e "  ${CYAN}  -o docker-cluster-restore.sh && chmod +x docker-cluster-restore.sh && ./docker-cluster-restore.sh${RESET}"
echo ""
