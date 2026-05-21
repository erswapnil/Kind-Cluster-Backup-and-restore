#!/usr/bin/env bash
# =============================================================================
# cnpg_prereqs.sh
# Installs all prerequisites for CNPG kind cluster restore and downloads
# the cnpg_restore.sh script from GitHub.
#
# Usage:
#   ./cnpg_prereqs.sh
#
# Run this once on any new machine before running cnpg_restore.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

RESTORE_SCRIPT_URL="https://raw.githubusercontent.com/erswapnil/Kind-Cluster-Backup-and-restore/main/cnpg_restore.sh"

# ─── STEP 1: Check Homebrew ───────────────────────────────────────────────────
step "Step 1 — Check Homebrew"
if ! command -v brew &>/dev/null; then
  error "Homebrew is not installed. Install it first: https://brew.sh"
fi
success "Homebrew found: $(brew --version | head -1)"

# ─── STEP 2: Check Docker Desktop ────────────────────────────────────────────
step "Step 2 — Check Docker Desktop"
if ! command -v docker &>/dev/null; then
  warn "Docker not found on PATH."
  warn "Install Docker Desktop from: https://docker.com/products/docker-desktop"
  warn "Start Docker Desktop, then re-run this script."
  exit 1
fi

if ! docker info &>/dev/null 2>&1; then
  warn "Docker is installed but the daemon is not running."
  warn "Open Docker Desktop, wait for the whale icon to go solid, then re-run."
  exit 1
fi
success "Docker is installed and running."

# ─── STEP 3: Install CLI tools via Homebrew ───────────────────────────────────
step "Step 3 — Install kind, kubectl, git, git-lfs"

TOOLS=(kind kubectl git git-lfs)
for tool in "${TOOLS[@]}"; do
  if brew list "$tool" &>/dev/null 2>&1; then
    success "$tool already installed: $(brew list --versions "$tool")"
  else
    info "Installing $tool..."
    brew install "$tool"
    success "$tool installed."
  fi
done

# ─── STEP 4: Initialise Git LFS ───────────────────────────────────────────────
step "Step 4 — Initialise Git LFS"
git lfs install
success "Git LFS initialised."

# ─── STEP 5: Verify all tools ─────────────────────────────────────────────────
step "Step 5 — Verify all tools"
info "kind:       $(kind version)"
info "kubectl:    $(kubectl version --client --short 2>/dev/null || kubectl version --client | head -1)"
info "git:        $(git --version)"
info "git-lfs:    $(git lfs version)"
success "All tools verified."

# ─── STEP 6: Download cnpg_restore.sh from GitHub ────────────────────────────
step "Step 6 — Download cnpg_restore.sh"
info "Downloading from: ${RESTORE_SCRIPT_URL}"

if curl -fsSL "${RESTORE_SCRIPT_URL}" -o cnpg_restore.sh; then
  chmod +x cnpg_restore.sh
  success "cnpg_restore.sh downloaded and made executable."
  info "Script saved to: $(pwd)/cnpg_restore.sh"
else
  error "Failed to download cnpg_restore.sh. Check the URL or your network connection."
fi

# ─── DONE ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ Setup complete ━━━${NC}"
success "All prerequisites installed. cnpg_restore.sh is ready."
echo ""
echo -e "${CYAN}Next step — run the restore script with your cluster details:${NC}"
echo ""
echo "  ./cnpg_restore.sh \\"
echo "    --git-repo     https://github.com/<username>/<repo>.git \\"
echo "    --cluster-name <cluster-name> \\"
echo "    --cnpg-version <version>"
echo ""
echo "  Example — klio cluster:"
echo "  ./cnpg_restore.sh \\"
echo "    --git-repo     https://github.com/erswapnil/klio-migration-artifacts.git \\"
echo "    --cluster-name klio \\"
echo "    --cnpg-version 1.29.1"
echo ""
