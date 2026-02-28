#!/usr/bin/env bash
# =============================================================================
# Blackbeard Media — Interactive Setup Wizard
# =============================================================================
# Streamlines setting up accounts.yml and settings.yml intelligently based on
# node type to eliminate unnecessary questions.
# =============================================================================

set -euo pipefail

BB_DIR="$(cd "$(dirname "$(readlink -f "$0" || readlink "$0" || echo "$0")")/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[setup]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[setup]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[setup]${NC} $1"; }
ask()      { echo -ne "\n${BOLD}$1${NC} "; }

echo -e "${MAGENTA}╔═════════════════════════════════════════╗${NC}"
echo -e "${MAGENTA}║  Blackbeard Media Node Setup Wizard     ║${NC}"
echo -e "${MAGENTA}╚═════════════════════════════════════════╝${NC}"
echo "This wizard will quickly configure your node by skipping"
echo "questions that don't apply to your use case."
echo ""
echo -e "Press ${BOLD}[Enter]${NC} on any question to keep the current value."
echo -e "Required inputs marked with ${RED}*${NC}"
echo ""

# Ensure templates exist
if [[ ! -f "${BB_DIR}/settings.yml" ]]; then
    cp "${BB_DIR}/settings.yml.default" "${BB_DIR}/settings.yml"
fi
if [[ ! -f "${BB_DIR}/accounts.yml" ]]; then
    cp "${BB_DIR}/accounts.yml.default" "${BB_DIR}/accounts.yml"
fi

# --- Helper functions ---

# Gets current value stripping quotes and comments
get_val() {
    local file="$1"
    local key="$2"
    grep "^${key}:" "${BB_DIR}/${file}" | head -1 | cut -d':' -f2- | awk -F'#' '{print $1}' | xargs | sed 's/^"//;s/"$//'
}

# Sets value with quotes if string, without if boolean
set_val() {
    local file="$1"
    local key="$2"
    local val="$3"
    local is_bool="${4:-false}"
    
    if [[ "${is_bool}" == "true" ]]; then
        sed -i "s|^${key}:.*|${key}: \"${val}\"|" "${BB_DIR}/${file}"
    fi
}

# Injects an SSH key into the group_vars/all.yml dictionary cleanly
inject_ssh_key() {
    local list_name="$1"
    local key_string="$2"
    local key_label="$3"

    if [[ -z "${key_string}" ]]; then return; fi
    
    # Strip wrapping quotes if accidentally entered
    key_string=$(echo "${key_string}" | sed 's/^"//;s/"$//')

    local file="${BB_DIR}/group_vars/all.yml"

    # Use awk to find the exact array block and append a new dictionary entry at the top of the block
    awk -v list="${list_name}:" -v name="\"${key_label}\"" -v key="\"${key_string}\"" '
    $0 == list {
        print
        print "  - name: " name
        print "    key: " key
        next
    }
    { print }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# Generic prompter
prompt() {
    local file="$1"
    local key="$2"
    local question="$3"
    local is_bool="${4:-false}"
    
    local curr
    curr=$(get_val "${file}" "${key}")
    
    if [[ "${curr}" == "CHANGE_ME"* ]]; then curr=""; fi
    
    local display_curr="${curr}"
    if [[ -z "${curr}" ]]; then display_curr="<empty>"; fi
    
    ask "${question} [${display_curr}]:"
    read -r input
    
    if [[ -n "${input}" ]]; then
        set_val "${file}" "${key}" "${input}" "${is_bool}"
    fi
}

# --- Part 1: Identity & Topology ---
echo -e "${CYAN}━━━ Phase 1: Identity & Topology ━━━${NC}"

curr_node=$(get_val "settings.yml" "node_name")
if [[ -z "${curr_node}" ]]; then
    curr_node="$(hostname)"
    set_val "settings.yml" "node_name" "${curr_node}"
fi
prompt "settings.yml" "node_name" "Node hostname"

# Node Type
curr_type=$(get_val "settings.yml" "node_type")
echo -e "\n${BOLD}Node Type Options:${NC}"
echo "  1) appbox     (Edge node running media server)"
echo "  2) share      (Central/Services node running feeder apps, Arrs)"
echo "  3) baremetal  (Raw node with no media/feeder apps)"
ask "Select node type (1-3) [${curr_type}]:"
read -r ntype
case "${ntype}" in
    1|appbox)  node_type="appbox"; set_val "settings.yml" "node_type" "appbox" ;;
    2|share)   node_type="share"; set_val "settings.yml" "node_type" "share" ;;
    3|baremetal) node_type="baremetal"; set_val "settings.yml" "node_type" "baremetal" ;;
    *) node_type="${curr_type}" ;;
esac

# Media Service
curr_media=$(get_val "settings.yml" "media_service")
echo -e "\n${BOLD}Primary Media Service:${NC}"
echo "  1) emby"
echo "  2) plex"
echo "  3) jellyfin"
echo "  4) none"
ask "Select media service (1-4) [${curr_media}]:"
read -r mservice
case "${mservice}" in
    1|emby) media_service="emby"; set_val "settings.yml" "media_service" "emby" ;;
    2|plex) media_service="plex"; set_val "settings.yml" "media_service" "plex" ;;
    3|jellyfin) media_service="jellyfin"; set_val "settings.yml" "media_service" "jellyfin" ;;
    4|none) media_service="none"; set_val "settings.yml" "media_service" "none" ;;
    *) media_service="${curr_media}" ;;
esac

# Emby Tier (only if emby)
if [[ "${media_service}" == "emby" ]]; then
    curr_tier=$(get_val "settings.yml" "emby_tier")
    echo -e "\n${BOLD}Emby Tier:${NC}"
    echo "  1) appbox (Full library + plugins)"
    echo "  2) basic  (Light library)"
    ask "Select Emby tier (1-2) [${curr_tier}]:"
    read -r etier
    case "${etier}" in
        1|appbox) set_val "settings.yml" "emby_tier" "appbox" ;;
        2|basic)  set_val "settings.yml" "emby_tier" "basic" ;;
    esac
fi

# Hardware
echo ""
curr_10g=$(get_val "settings.yml" "is_10g_node")
ask "Is this a 10Gbps node? (y/n) [${curr_10g}]:"
read -r is10g
if [[ "${is10g}" == "y" || "${is10g}" == "Y" || "${is10g}" == "true" ]]; then
    set_val "settings.yml" "is_10g_node" "true" "true"
elif [[ "${is10g}" == "n" || "${is10g}" == "N" || "${is10g}" == "false" ]]; then
    set_val "settings.yml" "is_10g_node" "false" "true"
fi

curr_hdd=$(get_val "settings.yml" "secondary_drive")
ask "Secondary drive path (e.g. /dev/nvme1n1, or 'none') [${curr_hdd}]:"
read -r hdd
[[ -n "${hdd}" ]] && set_val "settings.yml" "secondary_drive" "${hdd}"


# --- Part 2: Accounts & Secrets ---
echo -e "\n${CYAN}━━━ Phase 2: Core Credentials ━━━${NC}"

prompt "accounts.yml" "admin_password" "Linux Admin User Password ${RED}*${NC}"

echo -e "\n${BOLD}SSH Authorized Keys (Optional)${NC}"
ask "Paste an ssh-ed25519 or ssh-rsa key for the Admin User (Blank to skip):"
read -r ssh_admin
if [[ -n "${ssh_admin}" ]]; then
    inject_ssh_key "ssh_authorized_keys" "${ssh_admin}" "Wizard_Admin_Key"
    log_ok "Injected Admin SSH Key"
fi

ask "Paste an ssh-ed25519 or ssh-rsa key for Direct Root Access (Blank to skip):"
read -r ssh_root
if [[ -n "${ssh_root}" ]]; then
    inject_ssh_key "ssh_root_keys" "${ssh_root}" "Wizard_Root_Key"
    log_ok "Injected Root SSH Key"
fi

echo -e "\n${BOLD}Cloudflare Integrations${NC}"
prompt "accounts.yml" "cf_email" "Cloudflare ACME Email ${RED}*${NC}"
prompt "accounts.yml" "cf_api_token" "Cloudflare API Token ${RED}*${NC}"

echo -e "\n${BOLD}Server Monitoring (Beszel)${NC}"
prompt "accounts.yml" "beszel_hub_url" "Beszel Hub URL (e.g. https://stats.wyldhive.com) (Optional)"
prompt "accounts.yml" "beszel_hub_key" "Beszel Hub Public Key (Optional)"

echo -e "\n${BOLD}Discord Webhooks${NC}"
prompt "accounts.yml" "discord_webhook_general" "General Notifications Webhook (Optional)"
if [[ "${node_type}" == "share" ]]; then
    prompt "accounts.yml" "discord_webhook_media" "Media Additions Webhook (Optional)"
fi

# --- Edge Appboxes: Ceph ---
if [[ "${node_type}" == "appbox" ]]; then
    echo -e "\n${CYAN}━━━ Phase 3: Ceph Integration (Appbox) ━━━${NC}"
    prompt "accounts.yml" "ceph_dashboard_url" "Ceph Dashboard URL ${RED}*${NC}"
    prompt "accounts.yml" "ceph_dashboard_user" "Ceph Admin Username ${RED}*${NC}"
    prompt "accounts.yml" "ceph_dashboard_password" "Ceph Admin Password ${RED}*${NC}"
fi

# --- Main Media Service Token ---
if [[ "${media_service}" != "none" ]]; then
    echo -e "\n${CYAN}━━━ Phase 4: ${media_service^} API Key ━━━${NC}"
    if [[ "${media_service}" == "plex" ]]; then
        prompt "accounts.yml" "plex_token" "Plex Token ${RED}*${NC}"
    elif [[ "${media_service}" == "emby" ]]; then
        prompt "accounts.yml" "emby_api_key" "Emby API Key ${RED}*${NC}"
    elif [[ "${media_service}" == "jellyfin" ]]; then
        prompt "accounts.yml" "jellyfin_api_key" "Jellyfin API Key ${RED}*${NC}"
    fi
fi

# --- Feeder Nodes: Arrs, SSO, AI ---
if [[ "${node_type}" == "share" ]]; then
    echo -e "\n${CYAN}━━━ Phase 5: Ecosystem Integrations (Share/Feeder) ━━━${NC}"
    
    echo -e "\n${BOLD}*arr Stack API Keys${NC}"
    prompt "accounts.yml" "radarr_api_key" "Radarr API Key"
    prompt "accounts.yml" "sonarr_api_key" "Sonarr API Key"
    prompt "accounts.yml" "lidarr_api_key" "Lidarr API Key"
    prompt "accounts.yml" "readarr_api_key" "Readarr API Key"
    prompt "accounts.yml" "prowlarr_api_key" "Prowlarr API Key"
    prompt "accounts.yml" "bazarr_api_key" "Bazarr API Key"
    
    echo -e "\n${BOLD}Open WebUI (AI)${NC}"
    prompt "accounts.yml" "openwebui_postgres_password" "DB Password (Leave blank for generic secure)"
    db_pass=$(get_val "accounts.yml" "openwebui_postgres_password")
    if [[ -z "${db_pass}" ]]; then
        set_val "accounts.yml" "openwebui_postgres_password" "$(openssl rand -hex 16)"
    fi
    prompt "accounts.yml" "openwebui_openrouter_api_key" "OpenRouter API Key (Optional)"
    prompt "accounts.yml" "openwebui_tavily_api_key" "Tavily Serper API Key (Optional)"
    prompt "accounts.yml" "openwebui_google_api_key" "Google Gemini API Key (Optional)"

    echo -e "\n${BOLD}Authentik SSO Orchestrator${NC}"
    prompt "accounts.yml" "authentik_postgresql_password" "DB Password (Leave blank to cleanly auto-generate)"
    auth_db=$(get_val "accounts.yml" "authentik_postgresql_password")
    if [[ -z "${auth_db}" ]]; then
        set_val "accounts.yml" "authentik_postgresql_password" "$(openssl rand -hex 16)"
        log_ok "Auto-generated Authentik DB password"
    fi
    
    prompt "accounts.yml" "authentik_secret_key" "SSO Core JWT Secret (Leave blank to securely auto-generate)"
    auth_sec=$(get_val "accounts.yml" "authentik_secret_key")
    if [[ -z "${auth_sec}" ]]; then
        set_val "accounts.yml" "authentik_secret_key" "$(openssl rand -base64 36)"
        log_ok "Auto-generated 36-char secure Authentik secret"
    fi
fi

# Finish up
echo ""
log_ok "Setup Wizard Complete! Configuration files updated successfully."
echo -e "You can revisit these manually with ${CYAN}bb edit settings${NC} and ${CYAN}bb edit accounts${NC}."
echo ""
echo -e "You are now ready to install:"
echo -e "  ${BOLD}bb install node${NC}"
echo ""
