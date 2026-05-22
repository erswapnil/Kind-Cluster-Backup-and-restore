#!/usr/bin/env bash
# =============================================================================
# docker-backup-prerequisite.sh
# Checks and installs all tools required to run docker-cluster-backup.sh
# on the SOURCE machine (the machine with the kind cluster you want to back up).
#
# Tools checked / installed:
#   - Homebrew  (macOS only — package manager)
#   - Docker Desktop (must be installed manually if missing)
#   - kubectl   (to export K8s resources)
#   - git       (to clone and push to GitHub)
#   - git-lfs   (to handle large Docker snapshot .tar files)
#   - python3   (for JSON parsing of GitHub API responses)
#   - curl      (for GitHub API calls)
#
# Usage:
#   chmod +x docker-backup-prerequisite.sh && ./docker-backup-prerequisite.sh
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
echo -e "${BOLD}${CYAN}║      Backup Prerequisite Installer                   ║${RESET}"
echo -e "${BOLD}${CYAN}║      SOURCE machine setup for docker-cluster-backup  ║${RESET}"
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

# ── Step 4: git ───────────────────────────────────────────────────────────────
header "Step 4 · git"
if command -v git &>/dev/null; then
    success "git is installed: $(git --version)"
else
    if [[ "$PLATFORM" == "macOS" ]]; then
        brew_install "git"
    else
        apt_install "git"
    fi
fi

# ── Step 5: git-lfs ───────────────────────────────────────────────────────────
header "Step 5 · git-lfs"
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
        error "Docker must be running before you can use docker-cluster-backup.sh"
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
        info "Installing Docker Engine on Linux..."
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

# ── Step 8: Verify kind cluster exists ────────────────────────────────────────
header "Step 8 · Verify a kind cluster is available to back up"

if ! docker ps -a --format '{{.Names}}' | grep -q "\-control-plane$"; then
    echo ""
    warn "No kind control-plane containers found in Docker."
    echo ""
    echo -e "  This means no kind cluster is currently running on this machine."
    echo -e "  Make sure your kind cluster is running before running the backup script."
    echo ""
    echo -e "  ${CYAN}To list running containers:${RESET}"
    echo -e "  docker ps -a"
    echo ""
    warn "No kind cluster detected — you can still proceed, but backup will fail without one."
else
    CLUSTER_COUNT=$(docker ps -a --format '{{.Names}}' | grep -c "\-control-plane$" || true)
    success "Found ${CLUSTER_COUNT} kind cluster(s) available to back up."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
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
echo -e "  ${BOLD}You are ready to run the backup script:${RESET}"
echo ""
echo -e "  ${CYAN}curl -fsSL https://raw.githubusercontent.com/erswapnil/Kind-Cluster-Backup-and-restore/main/docker-cluster-backup.sh \\${RESET}"
echo -e "  ${CYAN}  -o docker-cluster-backup.sh && chmod +x docker-cluster-backup.sh && ./docker-cluster-backup.sh${RESET}"
echo ""
