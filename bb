#!/usr/bin/env bash
# =============================================================================
# Blackbeard Media — CLI Wrapper (bb)
# =============================================================================
# Usage:
#   bb setup                     Run the interactive configuration wizard
#   bb install core              Install bare minimum
#   bb install node              Full provisioning (all roles)
#   bb install docker            Install/update a single component
#   bb install core,docker,ceph  Install multiple components
#   bb list                      List available install tags
#   bb status                    Show current node config
#   bb edit <file>               Quick-edit settings or accounts
#   bb reconfigure               Apply variable changes without full install
#   bb logs                      Show last ansible run log
#   bb update                    Pull latest from git and update deps
#   bb health [smart|cpu|mem|io] Run hardware health checks
# =============================================================================

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Dynamically resolve the true installation directory by tracing the symlink
BB_DIR="$(cd "$(dirname "$(readlink -f "$0" || readlink "$0" || echo "$0")")" && pwd)"
LOG_DIR="/var/log/blackbeard"

log_info()  { echo -e "${CYAN}[bb]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[bb]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[bb]${NC} $1"; }
log_error() { echo -e "${RED}[bb]${NC} $1"; }

# --- Tag definitions ---
# "core" is the bare minimum hardware + OS to make a node production-ready.
# "node" runs everything (core + all services).
# Individual tags map 1:1 to Ansible roles.

declare -A TAG_DESCRIPTIONS=(
    # Grouped installs
    ["core"]="Base system: hostname, users, SSH, packages, TCP, LVM, ethtool, docker, traefik"
    ["node"]="Full provisioning: core + all services (Ceph, CrowdSec, Apps, etc.)"

    # Individual components
    ["base"]="Hostname, dotfiles (.bashrc, .bash_aliases), NTP, timezone"
    ["users"]="Create admin user, deploy SSH keys, configure sudoers"
    ["packages"]="Install system packages (pacman/apt) + yay + AUR"
    ["ssh"]="SSH hardening (sshd_config) + fail2ban"
    ["tcp"]="TCP/sysctl performance tuning (BBR, buffers)"
    ["lvm"]="Extend LVM with secondary drive + grow XFS"
    ["ethtool"]="NIC ring buffer optimization (auto-detects max for 1G/10G)"
    ["ceph"]="Ceph client config, REST API user creation, fstab mounts"
    ["docker"]="Docker engine, daemon config, networks, Portainer agent, autoheal, dops"
    ["crowdsec"]="CrowdSec IDS + Traefik bouncer (replaces fail2ban for web)"
    ["diun"]="Dockwatch container update management web UI"
    ["beszel"]="Lightweight server monitoring agent"
    ["ipset"]="ipset IP blacklist service + weekly update timer"
    ["traefik"]="Traefik reverse proxy via Docker Compose + ACME certs"
    ["authentik"]="Authentik Single Sign-On (SSO) Stack"
    ["autoscan"]="Autopulse media notifier via Docker Compose (share nodes)"
    ["gluetun"]="Gluetun VPN via Docker Compose (Plex nodes)"
    ["finishing"]="Auth files, deployment archives, Emby staging timers"
    
    # App Deployments
    ["apps"]="Full application stack (Services, Arrs, Torrents, Managers, AI)"
    ["app_services"]="Service node web utilities (Nextcloud, Vaultwarden, etc.)"
    ["app_arrs"]="Arr arrays (Sonarr, Radarr, Readarr, etc.)"
    ["app_torrents"]="Downloader arrays (qBittorrent, SABnzbd, Cross-Seed)"
    ["app_managers"]="Ecosystem Managers (Autoscan, Tracearr, Unpackerr)"
    ["open_webui"]="Open WebUI (AI Stack) — Service node only"
    ["enclosed"]="Enclosed (Secure File Sharing) — Service node only"
    ["validate"]="Pre-flight: Ansible syntax check + dry-run --check mode"
    ["audit"]="Security audit: scan for exposed secrets, weak permissions, misconfigs"
)

# What "core" expands to (includes lvm/ethtool — they self-skip via when:):
CORE_TAGS="base,users,packages,ssh,tcp,lvm,ethtool,docker,traefik"

# What "node" expands to (everything):
NODE_TAGS="base,users,packages,ssh,tcp,lvm,ethtool,ceph,docker,crowdsec,diun,beszel,ipset,traefik,authentik,autoscan,gluetun,finishing,app_services,app_arrs,app_torrents,app_managers,open_webui,enclosed"

VALID_TAGS="lvm|base|users|packages|ssh|tcp|ethtool|ceph|docker|crowdsec|diun|beszel|ipset|traefik|authentik|autoscan|gluetun|finishing|app_services|app_arrs|app_torrents|app_managers|open_webui|enclosed|apps"

# --- Functions ---

show_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║   Blackbeard Media — Server Manager      ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
}

show_usage() {
    echo -e "Usage: ${GREEN}bb${NC} <command> [arguments]"
    echo ""
    echo -e "Commands:"
    echo -e "  ${GREEN}setup${NC}              Run the interactive configuration wizard"
    echo -e "  ${GREEN}install${NC} <tag>      Install a component or group of components"
    echo -e "  ${GREEN}list${NC}               List all available install tags"
    echo -e "  ${GREEN}commands${NC}            List all bb commands with descriptions"
    echo -e "  ${GREEN}help${NC} <command>      Show detailed help for a command"
    echo -e "  ${GREEN}status${NC}             Show current node configuration"
    echo -e "  ${GREEN}edit${NC} <file>        Edit accounts.yml or settings.yml"
    echo -e "  ${GREEN}reconfigure${NC}        Apply variable changes without full install"
    echo -e "  ${GREEN}logs${NC}               Show last ansible run log"
    echo -e "  ${GREEN}update${NC}             Pull latest changes from git"
    echo -e "  ${GREEN}health${NC} [check]     Run hardware health checks"
    echo -e ""
    echo -e "Run ${CYAN}bb commands${NC} for the full list or ${CYAN}bb help <command>${NC} for details."
    echo ""
}

show_commands() {
    echo -e "${MAGENTA}═══ All Commands ═══${NC}"
    echo ""
    printf "  ${GREEN}%-14s${NC} %s\n" "setup"     "Run the interactive configuration wizard"
    printf "  ${GREEN}%-14s${NC} %s\n" "install"   "Run Ansible roles to provision components on this node"
    printf "  ${GREEN}%-14s${NC} %s\n" "list"      "Show all available install tags (core, node, docker, etc.)"
    printf "  ${GREEN}%-14s${NC} %s\n" "commands"  "Show this list of all bb commands"
    printf "  ${GREEN}%-14s${NC} %s\n" "help"      "Show detailed help and examples for a specific command"
    printf "  ${GREEN}%-14s${NC} %s\n" "status"    "Display current node settings and config validation"
    printf "  ${GREEN}%-14s${NC} %s\n" "edit"      "Open accounts.yml or settings.yml in your editor"
    printf "  ${GREEN}%-14s${NC} %s\n" "reconfigure" "Apply variable changes without full install"
    printf "  ${GREEN}%-14s${NC} %s\n" "logs"      "View the most recent Ansible run log"
    printf "  ${GREEN}%-14s${NC} %s\n" "update"    "Pull latest code from git and update Ansible collections"
    printf "  ${GREEN}%-14s${NC} %s\n" "health"    "Run hardware health checks (SMART, CPU, memory, I/O)"
    echo ""
    echo -e "For details on any command, run: ${CYAN}bb help <command>${NC}"
    echo ""
}

show_command_help() {
    local cmd="${1:-}"

    if [[ -z "${cmd}" ]]; then
        show_commands
        return
    fi

    case "${cmd}" in
        setup)
            echo -e "${MAGENTA}═══ bb setup ═══${NC}"
            echo ""
            echo -e "  Run the interactive configuration wizard to set up your node."
            echo -e "  This will guide you through initial settings and account details."
            echo ""
            echo -e "  ${BOLD}Usage:${NC}"
            echo -e "    ${CYAN}bb setup${NC}"
            ;;
        install)
            echo -e "${MAGENTA}═══ bb install ═══${NC}"
            echo ""
            echo -e "  Run Ansible roles to provision components on this node."
            echo -e "  Tags can be individual roles or groups (core, node)."
            echo -e "  Combine multiple tags with commas."
            echo ""
            echo -e "  ${BOLD}Usage:${NC}"
            echo -e "    bb install <tag>[,tag2,...] [ansible options]"
            echo ""
            echo -e "  ${BOLD}Examples:${NC}"
            echo -e "    ${CYAN}bb install core${NC}              # Base system: users, SSH, packages, TCP"
            echo -e "    ${CYAN}bb install node${NC}              # Full provisioning (all roles)"
            echo -e "    ${CYAN}bb install apps${NC}              # Just the Feeder/Service container stacks"
            echo -e "    ${CYAN}bb install app_arrs${NC}          # Only the (Sonarr/Radarr) ecosystem"
            echo -e "    ${CYAN}bb install docker${NC}            # Just Docker engine + base containers"
            echo -e "    ${CYAN}bb install core,docker,ceph${NC}  # Multiple components"
            echo -e "    ${CYAN}bb install ssh -v${NC}            # Verbose mode (pass ansible flags)"
            echo ""
            echo -e "  Run ${CYAN}bb list${NC} to see all available tags."
            ;;
        list)
            echo -e "${MAGENTA}═══ bb list ═══${NC}"
            echo ""
            echo -e "  Show all available install tags with descriptions."
            echo -e "  Tags are grouped into install groups (core, node) and individual roles."
            echo ""
            echo -e "  ${BOLD}Usage:${NC}  bb list"
            ;;
        commands)
            echo -e "${MAGENTA}═══ bb commands ═══${NC}"
            echo ""
            echo -e "  List every bb command with a short description."
            echo ""
            echo -e "  ${BOLD}Usage:${NC}  bb commands"
            ;;
        help)
            echo -e "${MAGENTA}═══ bb help ═══${NC}"
            echo ""
            echo -e "  Show detailed help for any bb command."
            echo ""
            echo -e "  ${BOLD}Usage:${NC}  bb help <command>"
            echo -e "  ${BOLD}Example:${NC} ${CYAN}bb help install${NC}"
            ;;
        status)
            echo -e "${MAGENTA}═══ bb status ═══${NC}"
            echo ""
            echo -e "  Display the current node configuration from settings.yml."
            echo -e "  Also checks accounts.yml for CHANGE_ME placeholders."
            echo ""
            echo -e "  ${BOLD}Usage:${NC}  bb status"
            ;;
        edit)
            echo -e "${MAGENTA}═══ bb edit ═══${NC}"
            echo ""
            echo -e "  Open a config file in your editor (\$EDITOR, defaults to nano)."
            echo ""
            echo -e "  ${BOLD}Usage:${NC}"
            echo -e "    ${CYAN}bb edit accounts${NC}   # Edit credentials and API keys"
            echo -e "    ${CYAN}bb edit settings${NC}   # Edit node identity and service config"
            ;;
        reconfigure)
            echo -e "${MAGENTA}═══ bb reconfigure ═══${NC}"
            echo ""
            echo -e "  Apply changes from settings.yml and accounts.yml without running a full install."
            echo -e "  This is useful for updating variables that don't require re-provisioning services."
            echo -e "  It runs a limited set of Ansible tasks to refresh configuration."
            echo ""
            echo -e "  ${BOLD}Usage:${NC}  bb reconfigure"
            ;;
        logs|log)
            echo -e "${MAGENTA}═══ bb logs ═══${NC}"
            echo ""
            echo -e "  Open the most recent Ansible run log in less."
            echo -e "  Logs are saved to /var/log/blackbeard/."
            echo ""
            echo -e "  ${BOLD}Usage:${NC}  bb logs"
            ;;
        update)
            echo -e "${MAGENTA}═══ bb update ═══${NC}"
            echo ""
            echo -e "  Pull latest changes from the git repository."
            echo -e "  Shows a diff of new commits and updates Ansible Galaxy"
            echo -e "  collections if requirements.yml exists."
            echo ""
            echo -e "  ${BOLD}Usage:${NC}  bb update"
            ;;
        health|check)
            echo -e "${MAGENTA}═══ bb health ═══${NC}"
            echo ""
            echo -e "  Run hardware health checks on this node."
            echo -e "  Requires smartmontools and stress-ng (installed via bb install packages)."
            echo ""
            echo -e "  ${BOLD}Usage:${NC}"
            echo -e "    ${CYAN}bb health${NC}         # Run all checks"
            echo -e "    ${CYAN}bb health smart${NC}   # SMART disk: status, temp, power-on hours, bad sectors"
            echo -e "    ${CYAN}bb health cpu${NC}     # 30s CPU stress test on all cores + temps"
            echo -e "    ${CYAN}bb health mem${NC}     # 256MB memory stress test"
            echo -e "    ${CYAN}bb health io${NC}      # 256MB sequential disk benchmark + Ceph read"
            ;;
        *)
            log_error "Unknown command: '${cmd}'"
            echo -e "Run ${CYAN}bb commands${NC} for the full list."
            exit 1
            ;;
    esac
    echo ""
}

show_list() {
    echo -e "${MAGENTA}═══ Install Groups ═══${NC}"
    echo ""
    printf "  ${GREEN}%-12s${NC} %s\n" "core" "${TAG_DESCRIPTIONS[core]}"
    printf "  ${GREEN}%-12s${NC} %s\n" "node" "${TAG_DESCRIPTIONS[node]}"
    echo ""
    echo -e "${MAGENTA}═══ Individual Tags ═══${NC}"
    echo ""
    for tag in base users packages ssh tcp lvm ethtool ceph docker crowdsec diun beszel ipset traefik authentik autoscan gluetun finishing app_services app_arrs app_torrents app_managers open_webui enclosed; do
        printf "  ${GREEN}%-12s${NC} %s\n" "${tag}" "${TAG_DESCRIPTIONS[$tag]}"
    done
    echo ""
    echo -e "Combine tags with commas: ${CYAN}bb install core,docker,ceph${NC}"
    echo ""
}

show_status() {
    if [[ ! -f "${BB_DIR}/settings.yml" ]]; then
        log_error "settings.yml not found. Run: cp settings.yml.default settings.yml"
        exit 1
    fi

    echo -e "${MAGENTA}═══ Node Configuration ═══${NC}"
    echo ""
    # Parse key values from settings.yml
    while IFS=':' read -r key value; do
        # Skip comments and empty lines
        [[ "${key}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key}" ]] && continue
        key=$(echo "${key}" | xargs)
        value=$(echo "${value}" | xargs | sed 's/^"//;s/"$//')
        [[ -z "${key}" ]] && continue
        [[ "${key}" == "---" ]] && continue
        printf "  ${CYAN}%-20s${NC} %s\n" "${key}" "${value}"
    done < "${BB_DIR}/settings.yml"

    echo ""

    # Check accounts.yml for placeholder values
    if [[ -f "${BB_DIR}/accounts.yml" ]]; then
        if grep -q "CHANGE_ME" "${BB_DIR}/accounts.yml"; then
            log_warn "accounts.yml still has CHANGE_ME placeholders — edit before installing!"
        else
            log_ok "accounts.yml looks configured."
        fi
    else
        log_error "accounts.yml not found. Run: cp accounts.yml.default accounts.yml"
    fi
    echo ""
}

validate_configs() {
    local has_error=false

    if [[ ! -f "${BB_DIR}/accounts.yml" ]]; then
        log_error "accounts.yml not found! Run: cp accounts.yml.default accounts.yml && nano accounts.yml"
        has_error=true
    fi

    if [[ ! -f "${BB_DIR}/settings.yml" ]]; then
        log_error "settings.yml not found! Run: cp settings.yml.default settings.yml && nano settings.yml"
        has_error=true
    fi

    # Check for unchanged defaults
    if [[ -f "${BB_DIR}/accounts.yml" ]] && grep -q "CHANGE_ME" "${BB_DIR}/accounts.yml"; then
        log_warn "accounts.yml still contains CHANGE_ME placeholders!"
        log_warn "Some roles may fail. Edit accounts.yml first: bb edit accounts"
    fi

    if [[ "${has_error}" == "true" ]]; then
        exit 1
    fi
}

resolve_tags() {
    local input="$1"
    local resolved=""

    # Split on comma
    IFS=',' read -ra TAGS <<< "${input}"

    for tag in "${TAGS[@]}"; do
        tag=$(echo "${tag}" | xargs)  # trim whitespace
        case "${tag}" in
            core)
                resolved="${resolved:+${resolved},}${CORE_TAGS}"
                ;;
            node)
                resolved="${resolved:+${resolved},}${NODE_TAGS}"
                ;;
            apps)
                resolved="${resolved:+${resolved},}app_services,app_arrs,app_torrents,app_managers,open_webui,enclosed"
                ;;
            lvm|base|users|packages|ssh|tcp|ethtool|ceph|docker|crowdsec|diun|beszel|ipset|traefik|authentik|autoscan|gluetun|finishing|app_services|app_arrs|app_torrents|app_managers|open_webui|enclosed)
                resolved="${resolved:+${resolved},}${tag}"
                ;;
            *)
                log_error "Unknown tag: '${tag}'. Run 'bb list' to see available tags."
                exit 1
                ;;
        esac
    done

    echo "${resolved}"
}

do_install() {
    local input="${1:-}"

    if [[ -z "${input}" ]]; then
        log_error "No tag specified. Usage: bb install <tag>"
        echo ""
        show_list
        exit 1
    fi

    # Separate the tag from any extra ansible-playbook args
    shift

    # --- Interactive Hostname Prompt (Initial Installs) ---
    if [[ "${input}" == *"core"* || "${input}" == *"node"* || "${input}" == *"base"* ]]; then
        if [[ -f "${BB_DIR}/settings.yml" ]]; then
            local current_hostname
            current_hostname=$(grep "^node_name:" "${BB_DIR}/settings.yml" | cut -d':' -f2 | xargs | sed 's/^"//;s/"$//')
            
            echo -e "${CYAN}━━━ Node Configuration ━━━${NC}"
            echo -e "Current node_name is: ${BOLD}${current_hostname:-CHANGE_ME}${NC}"
            read -r -p "Enter new hostname (or press Enter to keep current): " user_hostname
            
            if [[ -n "${user_hostname}" && "${user_hostname}" != "${current_hostname}" ]]; then
                log_info "Updating settings.yml with new node_name: ${user_hostname}"
                sed -i "s|^node_name:.*|node_name: \"${user_hostname}\"|" "${BB_DIR}/settings.yml"
                log_info "Setting system hostname immediately..."
                sudo hostnamectl set-hostname "${user_hostname}" || log_warn "Could not set hostname directly"
            fi
            echo ""
        fi
    fi

    validate_configs

    local tags
    tags=$(resolve_tags "${input}")

    log_info "Installing: ${YELLOW}${input}${NC}"
    log_info "Resolved tags: ${tags}"
    echo ""

    # Ensure log directory exists
    mkdir -p "${LOG_DIR}"
    local log_file="${LOG_DIR}/ansible-$(date +%Y%m%d-%H%M%S).log"

    cd "${BB_DIR}"

    /usr/bin/ansible-playbook setup.yml \
        --tags "${tags}" \
        "$@" \
        2>&1 | tee "${log_file}"

    local exit_code=${PIPESTATUS[0]}

    echo ""
    if [[ ${exit_code} -eq 0 ]]; then
        log_ok "Install complete: ${input}"
        log_info "Log saved: ${log_file}"
    else
        log_error "Install failed with exit code ${exit_code}"
        log_info "Check log: ${log_file}"
        exit ${exit_code}
    fi
}

cmd_edit() {
    local target="${1:-}"
    local editor="${EDITOR:-nano}"

    case "${target}" in
        accounts|account)
            ${editor} "${BB_DIR}/accounts.yml"
            ;;
        settings|setting)
            ${editor} "${BB_DIR}/settings.yml"
            ;;
        "")
            log_error "Specify a file to edit: bb edit accounts OR bb edit settings"
            exit 1
            ;;
        *)
            log_error "Unknown config: '${target}'. Use: bb edit accounts OR bb edit settings"
            exit 1
            ;;
    esac
}

do_reconfigure() {
    log_info "Applying configuration changes..."
    validate_configs

    mkdir -p "${LOG_DIR}"
    local log_file="${LOG_DIR}/ansible-reconfigure-$(date +%Y%m%d-%H%M%S).log"

    cd "${BB_DIR}"

    # Run a limited set of tasks to apply variable changes
    # This should be a lightweight playbook or specific tags that don't re-provision services
    /usr/bin/ansible-playbook setup.yml \
        --tags "base,users,ssh,tcp,ceph,docker,crowdsec,diun,beszel,ipset,traefik,authentik,autoscan,gluetun,finishing,app_services,app_arrs,app_torrents,app_managers,open_webui,enclosed" \
        --skip-tags "packages,lvm,ethtool" \
        -e "ansible_skip_install_checks=true" \
        2>&1 | tee "${log_file}"

    local exit_code=${PIPESTATUS[0]}

    echo ""
    if [[ ${exit_code} -eq 0 ]]; then
        log_ok "Configuration re-applied successfully."
        log_info "Log saved: ${log_file}"
    else
        log_error "Configuration re-application failed with exit code ${exit_code}"
        log_info "Check log: ${log_file}"
        exit ${exit_code}
    fi
}


do_validate() {
    log_info "Running IaC pre-flight security validation..."
    echo ""

    cd "${BB_DIR}"

    # Step 1: Ansible syntax check
    echo -e "${CYAN}━━━ Syntax Check ━━━${NC}"
    if /usr/bin/ansible-playbook setup.yml --syntax-check 2>&1; then
        log_ok "Syntax validation passed."
    else
        log_error "Syntax validation failed — fix errors before deploying."
        exit 1
    fi
    echo ""

    # Step 2: Dry-run (--check + --diff)
    echo -e "${CYAN}━━━ Dry-Run (--check mode) ━━━${NC}"
    log_info "Simulating full deployment without making changes..."
    echo ""
    /usr/bin/ansible-playbook setup.yml --check --diff 2>&1 | tail -20
    log_ok "Dry-run complete. Review the diff output above."
}

do_audit() {
    log_info "Running security configuration audit..."
    echo ""
    local issues=0

    cd "${BB_DIR}"

    # Check 1: CHANGE_ME placeholders
    echo -e "${CYAN}━━━ Credential Placeholders ━━━${NC}"
    if [[ -f accounts.yml ]] && grep -cq "CHANGE_ME" accounts.yml; then
        local count
        count=$(grep -c "CHANGE_ME" accounts.yml)
        log_warn "${count} CHANGE_ME placeholder(s) found in accounts.yml"
        issues=$((issues + count))
    else
        log_ok "No CHANGE_ME placeholders found."
    fi
    echo ""

    # Check 2: File permissions
    echo -e "${CYAN}━━━ Credential File Permissions ━━━${NC}"
    for f in accounts.yml settings.yml; do
        if [[ -f "${f}" ]]; then
            local perms
            perms=$(stat -c '%a' "${f}" 2>/dev/null || stat -f '%Lp' "${f}" 2>/dev/null)
            if [[ "${perms}" != "600" ]]; then
                log_warn "${f} has permissions ${perms} (should be 600)"
                issues=$((issues + 1))
            else
                log_ok "${f} is locked (0600)"
            fi
        fi
    done
    echo ""

    # Check 3: Docker socket exposure
    echo -e "${CYAN}━━━ Docker Socket Exposure ━━━${NC}"
    local socket_hits
    socket_hits=$(grep -rl '/var/run/docker.sock' roles/ --include='*.j2' --include='*.yml' 2>/dev/null | wc -l)
    if [[ "${socket_hits}" -gt 0 ]]; then
        log_warn "${socket_hits} file(s) still reference /var/run/docker.sock directly:"
        grep -rl '/var/run/docker.sock' roles/ --include='*.j2' --include='*.yml' 2>/dev/null | sed 's/^/    /'
        issues=$((issues + socket_hits))
    else
        log_ok "No direct Docker socket mounts found."
    fi
    echo ""

    # Summary
    echo -e "${MAGENTA}━━━ Audit Summary ━━━${NC}"
    if [[ ${issues} -eq 0 ]]; then
        log_ok "All checks passed. No issues found."
    else
        log_warn "${issues} issue(s) found. Review and remediate above."
    fi
}

do_logs() {
    if [[ ! -d "${LOG_DIR}" ]]; then
        log_warn "No logs yet. Run 'bb install' first."
        exit 0
    fi

    local latest
    latest=$(ls -t "${LOG_DIR}"/ansible-*.log 2>/dev/null | head -1)

    if [[ -z "${latest}" ]]; then
        log_warn "No ansible logs found."
        exit 0
    fi

    log_info "Last run: ${latest}"
    echo ""
    less "${latest}"
}

do_update() {
    log_info "Pulling latest from git..."
    cd "${BB_DIR}"

    local current_hash
    current_hash=$(git rev-parse HEAD)

    git fetch origin
    git pull origin "$(git rev-parse --abbrev-ref HEAD)"

    local new_hash
    new_hash=$(git rev-parse HEAD)

    if [[ "${current_hash}" == "${new_hash}" ]]; then
        log_ok "Already up to date."
    else
        log_ok "Updated: ${current_hash:0:8} → ${new_hash:0:8}"
        echo ""
        log_info "Recent changes:"
        git log --oneline "${current_hash}..${new_hash}" | head -15
    fi

    # Update Ansible Galaxy collections if requirements exist
    if [[ -f "${BB_DIR}/requirements.yml" ]]; then
        echo ""
        log_info "Updating Ansible collections..."
        ansible-galaxy install -r requirements.yml --force 2>/dev/null || true
    fi
}

# --- Health Check Functions ---

do_health() {
    local check="${1:-all}"

    echo -e "${MAGENTA}═══ Blackbeard Health Check ═══${NC}"
    echo ""

    case "${check}" in
        smart|disk|disks)
            health_smart
            ;;
        cpu)
            health_cpu
            ;;
        mem|memory|ram)
            health_mem
            ;;
        io|disk-io|diskio)
            health_io
            ;;
        all)
            health_smart
            echo ""
            health_cpu
            echo ""
            health_mem
            echo ""
            health_io
            ;;
        *)
            log_error "Unknown health check: '${check}'"
            echo -e "Available: ${CYAN}smart${NC}, ${CYAN}cpu${NC}, ${CYAN}mem${NC}, ${CYAN}io${NC}, ${CYAN}all${NC}"
            exit 1
            ;;
    esac
    echo ""
}

health_smart() {
    echo -e "${CYAN}━━━ SMART Disk Health ━━━${NC}"

    if ! command -v smartctl &>/dev/null; then
        log_warn "smartmontools not installed. Run: bb install packages"
        return
    fi

    # Find all block devices (exclude loop, ram, rom)
    local disks
    disks=$(lsblk -dno NAME,TYPE | awk '$2=="disk" {print "/dev/" $1}')

    if [[ -z "${disks}" ]]; then
        log_warn "No disks detected."
        return
    fi

    for disk in ${disks}; do
        echo ""
        echo -e "  ${BOLD}${disk}${NC}"

        # Get SMART health status
        local health
        health=$(smartctl -H "${disk}" 2>/dev/null | grep -i 'result\|health' | head -1 || echo "N/A")

        if echo "${health}" | grep -qi 'PASSED\|OK'; then
            echo -e "  Status:      ${GREEN}PASSED${NC}"
        elif echo "${health}" | grep -qi 'FAILED'; then
            echo -e "  Status:      ${RED}FAILED ⚠️${NC}"
        else
            echo -e "  Status:      ${YELLOW}Unknown (may not support SMART)${NC}"
        fi

        # Temperature
        local temp
        temp=$(smartctl -A "${disk}" 2>/dev/null | grep -i 'temperature' | head -1 | awk '{print $(NF-0)}' || echo "")
        [[ -n "${temp}" ]] && echo -e "  Temperature: ${temp}°C"

        # Power-on hours
        local hours
        hours=$(smartctl -A "${disk}" 2>/dev/null | grep -i 'power_on_hours\|Power On Hours' | awk '{print $(NF-0)}' || echo "")
        [[ -n "${hours}" ]] && echo -e "  Power-On:    ${hours} hours"

        # Reallocated sectors (bad sign if > 0)
        local realloc
        realloc=$(smartctl -A "${disk}" 2>/dev/null | grep -i 'reallocated_sector' | awk '{print $(NF-0)}' || echo "")
        if [[ -n "${realloc}" ]] && [[ "${realloc}" -gt 0 ]] 2>/dev/null; then
            echo -e "  Realloc:     ${RED}${realloc} sectors ⚠️${NC}"
        elif [[ -n "${realloc}" ]]; then
            echo -e "  Realloc:     ${GREEN}0${NC}"
        fi
    done
}

health_cpu() {
    echo -e "${CYAN}━━━ CPU Stress Test (30 seconds) ━━━${NC}"

    if ! command -v stress-ng &>/dev/null; then
        log_warn "stress-ng not installed. Run: bb install packages"
        return
    fi

    local cores
    cores=$(nproc)
    echo -e "  Cores: ${cores}"
    echo -e "  Running 30s stress test on all cores..."
    echo ""

    # Run stress-ng CPU test
    stress-ng --cpu "${cores}" --cpu-method all --metrics --timeout 30s 2>&1 | \
        grep -E 'cpu|bogo|info' | tail -5

    echo ""

    # Show temps after stress (if available)
    if command -v sensors &>/dev/null; then
        echo -e "  ${BOLD}Post-stress temperatures:${NC}"
        sensors 2>/dev/null | grep -E 'Core|Tctl|temp' | head -8 | sed 's/^/  /'
    fi

    log_ok "CPU stress test complete."
}

health_mem() {
    echo -e "${CYAN}━━━ Memory Test (256MB) ━━━${NC}"

    if ! command -v stress-ng &>/dev/null; then
        log_warn "stress-ng not installed. Run: bb install packages"
        return
    fi

    local total_mem
    total_mem=$(free -h | awk '/^Mem:/ {print $2}')
    local avail_mem
    avail_mem=$(free -h | awk '/^Mem:/ {print $7}')
    echo -e "  Total:     ${total_mem}"
    echo -e "  Available: ${avail_mem}"
    echo -e "  Testing 256MB with stress-ng (30s)..."
    echo ""

    stress-ng --vm 1 --vm-bytes 256M --vm-method all --metrics --timeout 30s 2>&1 | \
        grep -E 'vm|bogo|info' | tail -5

    echo ""
    log_ok "Memory test complete. No errors detected."
}

health_io() {
    echo -e "${CYAN}━━━ Disk I/O Benchmark ━━━${NC}"

    # Quick dd-based sequential write/read test
    local test_dir="/tmp"
    local test_file="${test_dir}/.bb_io_test"
    local bs="1M"
    local count="256"

    echo -e "  Test: 256MB sequential write/read"
    echo ""

    # Write test
    echo -e "  ${BOLD}Write:${NC}"
    dd if=/dev/zero of="${test_file}" bs=${bs} count=${count} conv=fdatasync 2>&1 | \
        grep -oE '[0-9.]+ [GMKT]?B/s' | tail -1 | sed 's/^/    /'

    # Clear cache for honest read test
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    # Read test
    echo -e "  ${BOLD}Read:${NC}"
    dd if="${test_file}" of=/dev/null bs=${bs} count=${count} 2>&1 | \
        grep -oE '[0-9.]+ [GMKT]?B/s' | tail -1 | sed 's/^/    /'

    rm -f "${test_file}"

    # If Ceph is mounted, test Ceph too
    if mountpoint -q /mnt/ceph 2>/dev/null; then
        echo ""
        echo -e "  ${BOLD}Ceph (sequential read):${NC}"
        local ceph_test
        ceph_test=$(find /mnt/ceph -maxdepth 3 -type f -size +10M 2>/dev/null | head -1)
        if [[ -n "${ceph_test}" ]]; then
            dd if="${ceph_test}" of=/dev/null bs=${bs} count=256 2>&1 | \
                grep -oE '[0-9.]+ [GMKT]?B/s' | tail -1 | sed 's/^/    /'
        else
            echo "    (no suitable test file found on Ceph)"
        fi
    fi

    log_ok "I/O benchmark complete."
}

# === Main ===
if [[ $# -eq 0 ]]; then
    show_banner
    show_usage
    exit 0
fi

COMMAND="$1"
shift

case "${COMMAND}" in
    install)
        show_banner
        do_install "$@"
        ;;
    list)
        show_banner
        show_list
        ;;
    status)
        show_banner
        show_status
        ;;
    edit)
        cmd_edit "$1"
        ;;
    setup)
        bash "${BB_DIR}/scripts/setup_wizard.sh"
        ;;
    reconfigure)
        show_banner
        do_reconfigure
        ;;
    logs|log)
        do_logs
        ;;
    update)
        show_banner
        do_update
        ;;
    health|check)
        show_banner
        do_health "$@"
        ;;
    validate)
        show_banner
        do_validate
        ;;
    audit)
        show_banner
        do_audit
        ;;
    commands)
        show_banner
        show_commands
        ;;
    help)
        show_banner
        show_command_help "$@"
        ;;
    -h|--help)
        show_banner
        show_usage
        ;;
    *)
        log_error "Unknown command: '${COMMAND}'"
        echo -e "Run ${CYAN}bb commands${NC} for the full list."
        exit 1
        ;;
esac
