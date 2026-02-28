#!/usr/bin/env bash
# =============================================================================
# Blackbeard Media — .env Injector
# =============================================================================
# Ingests an existing .env file and securely pre-populates all Ansible YAML
# configuration templates to allow for zero-touch headless provisioning.
# =============================================================================

set -e

BB_DIR="$(cd "$(dirname "$(readlink -f "$0" || readlink "$0" || echo "$0")")/.." && pwd)"
ENV_FILE="${BB_DIR}/.env"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[env]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[env]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[env]${NC} $1"; }

if [[ ! -f "${ENV_FILE}" ]]; then
    exit 0
fi

log_info "Found .env file. Executing headless pre-provisioning injection..."

# Source the .env cleanly
set -a
source "${ENV_FILE}"
set +a

# Sets value with quotes if string, without if boolean
set_val() {
    local file="$1"
    local key="$2"
    local val="$3"
    local is_bool="${4:-false}"
    
    # Don't overwrite if input val is practically empty, unless it's a specific generation scenario
    if [[ -z "${val}" ]]; then return; fi

    if [[ "${is_bool}" == "true" ]]; then
        sed -i "s|^${key}:.*|${key}: ${val}|" "${BB_DIR}/${file}"
    else
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

    # Pre-flight Idempotency Check: if the base64 string exists exactly, abort injection
    if grep -Fq "${key_string}" "$file"; then
        return 0
    fi

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

# Ensure templates exist
if [[ ! -f "${BB_DIR}/settings.yml" ]]; then cp "${BB_DIR}/settings.yml.default" "${BB_DIR}/settings.yml"; fi
if [[ ! -f "${BB_DIR}/accounts.yml" ]]; then cp "${BB_DIR}/accounts.yml.default" "${BB_DIR}/accounts.yml"; fi

# --- Generate dynamic node name if blank ---
if [[ -z "${BB_NODE_NAME:-}" ]]; then
    BB_NODE_NAME="$(hostname)"
fi

# =============================================================================
# Apply settings.yml
# =============================================================================
set_val "settings.yml" "node_name" "${BB_NODE_NAME}"
set_val "settings.yml" "node_type" "${BB_NODE_TYPE:-}"
set_val "settings.yml" "media_service" "${BB_MEDIA_SERVICE:-}"
set_val "settings.yml" "emby_tier" "${BB_EMBY_TIER:-skip}"

if [[ "${BB_IS_10G_NODE:-}" == "true" || "${BB_IS_10G_NODE:-}" == "true" ]]; then
    set_val "settings.yml" "is_10g_node" "true" "true"
else
    set_val "settings.yml" "is_10g_node" "false" "true"
fi

set_val "settings.yml" "lvm_ignore_drives" "${BB_LVM_IGNORE_DRIVES:-}"

# =============================================================================
# Apply accounts.yml & global identites
# =============================================================================

# Globals
set_val "accounts.yml" "admin_password" "${BB_ADMIN_PASSWORD:-}"
set_val "accounts.yml" "cf_email" "${BB_CF_EMAIL:-}"
set_val "accounts.yml" "cf_api_token" "${BB_CF_API_TOKEN:-}"

# SSH Identities
for var in $(compgen -v | grep '^BB_ADMIN_SSH_KEY'); do
    val="${!var}"
    if [[ -n "${val}" ]]; then
        inject_ssh_key "ssh_authorized_keys" "${val}" "Env_${var}"
        log_info "Injected Headless Admin SSH Key: ${var}"
    fi
done

for var in $(compgen -v | grep '^BB_ROOT_SSH_KEY'); do
    val="${!var}"
    if [[ -n "${val}" ]]; then
        inject_ssh_key "ssh_root_keys" "${val}" "Env_${var}"
        log_info "Injected Headless Root SSH Key: ${var}"
    fi
done

# Media Service
set_val "accounts.yml" "plex_token" "${BB_PLEX_TOKEN:-}"
set_val "accounts.yml" "jellyfin_api_key" "${BB_JELLYFIN_API_KEY:-}"
set_val "accounts.yml" "emby_api_key" "${BB_EMBY_API_KEY:-}"

# Ceph Appbox Dashboard
set_val "accounts.yml" "ceph_dashboard_url" "${BB_CEPH_DASHBOARD_URL:-}"
set_val "accounts.yml" "ceph_dashboard_user" "${BB_CEPH_DASHBOARD_USER:-}"
set_val "accounts.yml" "ceph_dashboard_password" "${BB_CEPH_DASHBOARD_PASSWORD:-}"

# Arrs
set_val "accounts.yml" "sonarr_api_key" "${BB_SONARR_API_KEY:-}"
set_val "accounts.yml" "radarr_api_key" "${BB_RADARR_API_KEY:-}"
set_val "accounts.yml" "lidarr_api_key" "${BB_LIDARR_API_KEY:-}"
set_val "accounts.yml" "readarr_api_key" "${BB_READARR_API_KEY:-}"
set_val "accounts.yml" "prowlarr_api_key" "${BB_PROWLARR_API_KEY:-}"
set_val "accounts.yml" "bazarr_api_key" "${BB_BAZARR_API_KEY:-}"

# Ecosystem
set_val "accounts.yml" "beszel_hub_url" "${BB_BESZEL_HUB_URL:-}"
set_val "accounts.yml" "beszel_hub_key" "${BB_BESZEL_HUB_KEY:-}"
set_val "accounts.yml" "crowdsec_enroll_key" "${BB_CROWDSEC_ENROLL_KEY:-}"
set_val "accounts.yml" "crowdsec_traefik_bouncer_key" "${BB_CROWDSEC_TRAEFIK_BOUNCER_KEY:-}"
set_val "accounts.yml" "discord_webhook_general" "${BB_DISCORD_WEBHOOK_GENERAL:-}"
set_val "accounts.yml" "discord_webhook_media" "${BB_DISCORD_WEBHOOK_MEDIA:-}"

# Open WebUI
set_val "accounts.yml" "openwebui_postgres_user" "${BB_OPENWEBUI_POSTGRES_USER:-}"
if [[ -z "${BB_OPENWEBUI_POSTGRES_PASSWORD:-}" || "${BB_OPENWEBUI_POSTGRES_PASSWORD:-}" == "CHANGE_ME"* ]]; then
    BB_OPENWEBUI_POSTGRES_PASSWORD="$(openssl rand -hex 16)"
    log_info "Auto-generated secure password for Open WebUI Postgres"
fi
set_val "accounts.yml" "openwebui_postgres_password" "${BB_OPENWEBUI_POSTGRES_PASSWORD}"
set_val "accounts.yml" "openwebui_openrouter_api_key" "${BB_OPENWEBUI_OPENROUTER_API_KEY:-}"
set_val "accounts.yml" "openwebui_tavily_api_key" "${BB_OPENWEBUI_TAVILY_API_KEY:-}"
set_val "accounts.yml" "openwebui_google_api_key" "${BB_OPENWEBUI_GOOGLE_API_KEY:-}"

# Authentik SSO
if [[ -z "${BB_AUTHENTIK_POSTGRESQL_PASSWORD:-}" || "${BB_AUTHENTIK_POSTGRESQL_PASSWORD:-}" == "CHANGE_ME"* ]]; then
    BB_AUTHENTIK_POSTGRESQL_PASSWORD="$(openssl rand -hex 16)"
    log_info "Auto-generated secure password for Authentik Postgres"
fi
set_val "accounts.yml" "authentik_postgresql_password" "${BB_AUTHENTIK_POSTGRESQL_PASSWORD}"

if [[ -z "${BB_AUTHENTIK_SECRET_KEY:-}" || "${BB_AUTHENTIK_SECRET_KEY:-}" == "CHANGE_ME"* ]]; then
    BB_AUTHENTIK_SECRET_KEY="$(openssl rand -base64 36)"
    log_info "Auto-generated 36-char secure Secret Key for Authentik JWT"
fi
set_val "accounts.yml" "authentik_secret_key" "${BB_AUTHENTIK_SECRET_KEY}"

log_ok "Successfully mapped .env parameters to configuration files."
