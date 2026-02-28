#!/usr/bin/env bash
# =============================================================================
# Blackbeard Media — Bootstrap Install Script
# =============================================================================
# Usage:
#   curl -sL https://raw.githubusercontent.com/LunarVigilante/bb_ansible/main/install.sh | sudo bash
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
    INSTALL_DIR="${BB_INSTALL_DIR:-$HOME/blackbeard}"
else
    INSTALL_DIR="${BB_INSTALL_DIR:-$(cd "$(dirname "$0")" && pwd)}"
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
    pacman -Syu --noconfirm --needed \
        ansible git python python-pip python-passlib python-jmespath \
        community-general-docs 2>/dev/null || true
    # Install community.docker collection
    ansible-galaxy collection install community.general community.docker --force 2>/dev/null || true
}

install_deps_ubuntu() {
    log_info "Installing dependencies via apt..."
    apt-get update -qq
    apt-get install -y -qq \
        software-properties-common git python3 python3-pip python3-passlib
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
}

# --- Create config files from templates ---
create_configs() {
    if [[ ! -f "${INSTALL_DIR}/accounts.yml" ]]; then
        cp "${INSTALL_DIR}/accounts.yml.default" "${INSTALL_DIR}/accounts.yml"
        log_warn "Created accounts.yml — EDIT THIS FILE with your credentials!"
    else
        log_ok "accounts.yml already exists, skipping."
    fi

    if [[ ! -f "${INSTALL_DIR}/settings.yml" ]]; then
        cp "${INSTALL_DIR}/settings.yml.default" "${INSTALL_DIR}/settings.yml"
        log_warn "Created settings.yml — EDIT THIS FILE with your node settings!"
    else
        log_ok "settings.yml already exists, skipping."
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
echo "║   Blackbeard Media — Server Bootstrap Installer  ║"
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
