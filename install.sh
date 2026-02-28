#!/usr/bin/env bash
# =============================================================================
# BB Ansible — Bootstrap Install Script
# =============================================================================
# Usage:
#   curl -sL https://raw.githubusercontent.com/LunarVigilante/bb_ansible/main/install.sh | bash
#
# This script:
#   1. Detects OS (Arch Linux / Ubuntu)
#   2. Installs Ansible, Git, Python dependencies
#   3. Clones (or updates) the repo to /srv/git/blackbeard
#   4. Creates template config files if they don't exist
#   5. Installs the 'bb' CLI wrapper to /usr/local/bin/bb
# =============================================================================

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

REPO_URL="${BB_REPO_URL:-https://github.com/LunarVigilante/bb_ansible.git}"
REPO_BRANCH="${BB_REPO_BRANCH:-main}"

# Intelligently detect if piped via curl or run explicitly to determine install directory
if [[ "$0" == *"bash"* || "$0" == *"sh" ]]; then
    INSTALL_DIR="${BB_INSTALL_DIR:-/srv/git/blackbeard}"
    ORIGIN_DIR="${PWD}"
else
    INSTALL_DIR="${BB_INSTALL_DIR:-$(cd "$(dirname "$0")" && pwd)}"
    ORIGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

log_info()  { echo -e "${CYAN}[bb]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[bb]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[bb]${NC} $1"; }
log_error() { echo -e "${RED}[bb]${NC} $1"; }

# --- Must be root ---
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root."
    exit 1
fi

# --- Detect OS ---
detect_os() {
    if [[ -f /etc/arch-release ]]; then
        OS="arch"
    elif [[ -f /etc/lsb-release ]] || [[ -f /etc/debian_version ]]; then
        OS="ubuntu"
    else
        log_error "Unsupported OS. Only Arch Linux and Ubuntu are supported."
        exit 1
    fi
    log_info "Detected OS: ${OS}"
}

# --- Install dependencies ---
install_deps_arch() {
    log_info "Installing dependencies via pacman..."
    pacman -Sy --noconfirm --needed ansible-core git python python-passlib sudo nano vim
    
    # Force shell to recognize new binaries immediately
    hash -r || true

    # Install community.docker collection
    ansible-galaxy collection install community.general community.docker --force 2>/dev/null || true
}

install_deps_ubuntu() {
    log_info "Installing dependencies via apt..."
    apt-get update -qq
    apt-get install -y -qq software-properties-common git python3 python3-pip python3-passlib sudo nano vim
    # Add Ansible PPA if not present
    if ! command -v ansible &> /dev/null; then
        add-apt-repository --yes ppa:ansible/ansible
        apt-get update -qq
        apt-get install -y -qq ansible
    fi
    ansible-galaxy collection install community.general community.docker --force 2>/dev/null || true
}

# --- Clone or update repo ---
setup_repo() {
    if [[ -d "${INSTALL_DIR}/.git" ]]; then
        log_info "Repo already exists at ${INSTALL_DIR}, pulling latest..."
        cd "${INSTALL_DIR}"
        git fetch origin "${REPO_BRANCH}"
        git reset --hard "origin/${REPO_BRANCH}"
    else
        log_info "Cloning repo to ${INSTALL_DIR}..."
        mkdir -p "$(dirname "${INSTALL_DIR}")"
        git clone -b "${REPO_BRANCH}" "${REPO_URL}" "${INSTALL_DIR}"
    fi
    cd "${INSTALL_DIR}"

    # Re-exec from the on-disk copy so any fixes in the repo take effect
    if [[ "${BB_REEXEC:-}" != "1" ]]; then
        log_info "Re-executing installer from updated repo..."
        BB_REEXEC=1 BB_INSTALL_DIR="${INSTALL_DIR}" exec bash "${INSTALL_DIR}/install.sh"
    fi
}

# --- Create config files from templates (always overwrite — install.sh is one-time bootstrap) ---
create_configs() {
    cp "${INSTALL_DIR}/accounts.yml.default" "${INSTALL_DIR}/accounts.yml"
    chmod 600 "${INSTALL_DIR}/accounts.yml"
    log_ok "Created accounts.yml (locked 0600)"

    cp "${INSTALL_DIR}/settings.yml.default" "${INSTALL_DIR}/settings.yml"
    chmod 600 "${INSTALL_DIR}/settings.yml"
    log_ok "Created settings.yml (locked 0600)"

    # Headless Pre-provisioning via .env detection
    # Search order: origin dir (where curl was run), $HOME, install dir
    local env_source=""
    if [[ -f "${ORIGIN_DIR}/.env" && "${ORIGIN_DIR}" != "${INSTALL_DIR}" ]]; then
        env_source="${ORIGIN_DIR}/.env"
        log_info "Found .env at ${env_source} (origin dir)"
    elif [[ -f "${HOME}/.env" && "${HOME}" != "${INSTALL_DIR}" ]]; then
        env_source="${HOME}/.env"
        log_info "Found .env at ${env_source} (home dir)"
    elif [[ -f "${INSTALL_DIR}/.env" ]]; then
        env_source="${INSTALL_DIR}/.env"
        log_info "Found .env at ${env_source} (install dir)"
    fi

    if [[ -n "${env_source}" ]]; then
        log_info "Executing headless .env injection into config files..."
        if [[ "${env_source}" != "${INSTALL_DIR}/.env" ]]; then
            cp "${env_source}" "${INSTALL_DIR}/.env"
        fi
        bash "${INSTALL_DIR}/scripts/apply_env.sh"
    else
        log_warn "No .env file found. You will need to manually edit accounts.yml and settings.yml."
    fi
}

# --- Install bb CLI ---
install_cli() {
    if [[ -L /usr/local/bin/bb ]] || [[ -f /usr/local/bin/bb ]]; then
        rm -f /usr/local/bin/bb
    fi
    ln -s "${INSTALL_DIR}/bb" /usr/local/bin/bb
    chmod +x "${INSTALL_DIR}/bb"
    log_ok "Installed 'bb' CLI to /usr/local/bin/bb"
}

# === Main ===
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║   BB Ansible — Server Bootstrap Installer  ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

detect_os

case "${OS}" in
    arch)   install_deps_arch   ;;
    ubuntu) install_deps_ubuntu ;;
esac

setup_repo
create_configs
install_cli

echo ""
log_ok "Bootstrap complete!"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo -e "  ${CYAN}1.${NC} cd ${INSTALL_DIR}"
echo -e "  ${CYAN}2.${NC} nano accounts.yml    ${YELLOW}# Fill in your credentials${NC}"
echo -e "  ${CYAN}3.${NC} nano settings.yml    ${YELLOW}# Configure this node${NC}"
echo -e "  ${CYAN}4.${NC} bb install core      ${YELLOW}# Install base system${NC}"
echo ""
echo -e "  Run ${GREEN}bb list${NC} to see all available install tags."
echo ""
