# Blackbeard Media — Ansible Server Provisioning

Automated provisioning for Blackbeard Media share & appbox nodes on Hetzner.  
Inspired by [Saltbox](https://docs.saltbox.dev/) — curl, configure, install.

## Quick Start

### 1. Bootstrap the Node
Blackbeard operates on top of clean, minimal OS installations. If you are starting from a raw image, you must first switch to the root user and pull the deployment codebase using your native package manager.

```bash
# Switch to root (if not already)
su -

# 1. Update packages and install Git
# For Debian/Ubuntu (apt):
apt-get update && apt-get install -y git sudo
# For Arch Linux (pacman):
# pacman -Syu --noconfirm git sudo
# For CentOS/RHEL/Alma (dnf):
# dnf install -y git sudo

# 2. Create the deploy directory
mkdir -p /srv/git
cd /srv/git

# 3. Clone the repository and install Ansible
git clone https://github.com/LunarVigilante/bb_ansible.git blackbeard
cd blackbeard
chmod +x install.sh
./install.sh
```

### 2. Configure Node Identity
```bash
cp accounts.yml.default accounts.yml
cp settings.yml.default settings.yml

nano accounts.yml    # Fill in your secure credentials (Git-ignored)
nano settings.yml    # Configure this node's topology (e.g., node_type: fdr)
```

### 3. Deploy
```bash
bb install core      # Base system (users, SSH, packages, TCP, ring buffers)
bb install node      # OR full provisioning (everything)
```

## BB Commands

| Command | What it does |
|---------|-------------|
| `bb install core` | Base system: hostname, users, SSH, packages, TCP, LVM, ring buffers |
| `bb install node` | Full provisioning: core + all services |
| `bb install docker` | Single component |
| `bb install core,docker,ceph` | Multiple components |
| `bb list` | Show all available install tags |
| `bb commands` | List all bb commands with descriptions |
| `bb help <command>` | Detailed help for any command (usage, examples) |
| `bb status` | Show current node config + validation |
| `bb edit accounts` | Edit credentials file |
| `bb edit settings` | Edit node settings file |
| `bb logs` | View last ansible run log |
| `bb update` | Pull latest from git + show commit diff |
| `bb health` | Run all hardware health checks |
| `bb health smart` | SMART disk status, temp, power-on hours, bad sectors |
| `bb health cpu` | 30-second CPU stress test on all cores |
| `bb health mem` | 256MB memory stress test |
| `bb health io` | Disk I/O benchmark + Ceph read speed |

## Available Tags

### Groups

| Tag | Components |
|-----|-----------|
| `core` | base, users, packages, ssh, tcp, lvm, ethtool |
| `node` | All 17 roles |

### Individual

| Tag | Description | Conditional |
|-----|-------------|-------------|
| `base` | Hostname, dotfiles, NTP, timezone, locale | — |
| `users` | Admin user, SSH keys, sudoers | — |
| `packages` | pacman/apt, yay, AUR, smartmontools, stress-ng, jq, etc. | — |
| `ssh` | SSH hardening (modern ciphers, MaxAuthTries 3, idle timeout) + fail2ban (aggressive + recidive) | — |
| `tcp` | TCP/sysctl tuning optimized for Ceph + media streaming (BBR, conditional 10G/1G buffers) | — |
| `lvm` | Extend LVM + XFS | `secondary_drive != none` |
| `ethtool` | NIC ring buffer optimization (auto-detects max for 1G and 10G) | — |
| `ceph` | Ceph config + API user + mounts (tuned for streaming readahead) | — |
| `docker` | Docker 28.5.2 (pinned), daemon.json, all networks, Portainer agent, autoheal | — |
| `crowdsec` | CrowdSec IDS + Traefik bouncer | — |
| `diun` | Docker image update notifier (Discord/webhook) | — |
| `beszel` | Lightweight server monitoring agent (8MB RAM) | needs `beszel_hub_key` |
| `ipset` | IP blacklist timer | — |
| `traefik` | Traefik reverse proxy via Docker Compose + Cloudflare ACME | — |
| `autoscan` | Autoscan media scanner via Docker Compose | `node_type: share` |
| `gluetun` | Gluetun VPN via Docker Compose | `media_service: plex` |
| `finishing` | Auth files, deployments | — |

## Configuration Files

### `accounts.yml` — Credentials

```yaml
admin_password: "your_secure_password"
ceph_dashboard_url: "https://ceph:8443"
ceph_dashboard_user: "admin"
ceph_dashboard_password: "ceph_pass"
cf_email: "you@example.com"
cf_auth_key: "cloudflare_global_key"
cf_api_token: "cloudflare_api_token"
musics_api_key: "music_key"
autoscan_password: ""           # leave blank to auto-generate
crowdsec_enroll_key: ""         # free at app.crowdsec.net
diun_discord_webhook: ""        # Discord webhook for image updates
beszel_hub_key: ""              # from Beszel Hub → Add System
```

### `settings.yml` — Node Settings

```yaml
node_name: "e-ab-sm-01"
media_service: "emby"       # emby / plex / jellyfin
node_type: "appbox"         # share / appbox / baremetal
is_10g_node: false
secondary_drive: "none"     # or /dev/nvme1n1
emby_tier: "skip"           # appbox / basic / skip
```

## Project Structure

```
/srv/git/blackbeard/
├── install.sh              # Bootstrap script (curl target)
├── bb                      # CLI wrapper → /usr/local/bin/bb
├── ansible.cfg             # Self-provisioning config
├── setup.yml               # Main playbook
├── accounts.yml.default    # Credentials template
├── settings.yml.default    # Settings template
├── group_vars/all.yml      # Shared defaults (versions, networks, tuning)
└── roles/                  # 17 modular roles
    ├── base/               # hostname, dotfiles, NTP, locale, sudo
    ├── users/              # admin user, SSH keys
    ├── packages/           # system packages, yay, AUR
    ├── ssh_hardening/      # sshd (modern ciphers, banner), fail2ban (aggressive + recidive)
    ├── tcp_tuning/         # sysctl for Ceph + streaming (BBR, 10G/1G buffers, VM tuning)
    ├── lvm_extend/         # LVM + XFS grow
    ├── ethtool_buffer/     # NIC ring buffer (auto-detect max, all nodes)
    ├── ceph_client/        # Ceph REST API + mounts (8MB readahead, OSD tuning)
    ├── docker/             # Docker 28.5.2 (pinned), daemon.json, all networks, Portainer, autoheal
    ├── crowdsec/           # CrowdSec IDS + Traefik bouncer
    ├── diun/               # Docker image update notifier
    ├── beszel/             # Lightweight server monitoring agent
    ├── ipset_blacklist/    # IP blacklist timer
    ├── traefik/            # Traefik reverse proxy (Docker Compose + Cloudflare ACME)
    ├── autoscan/           # Media scanner (Docker Compose, share nodes)
    ├── gluetun/            # VPN (Docker Compose, Plex nodes)
    └── finishing/          # Auth files, deployments
```

## Security

- **SSH:** Modern ciphers only (no CBC/SHA1), MaxAuthTries 3, idle timeout 10min, login banner, VERBOSE logging
- **fail2ban:** Aggressive sshd mode + recidive jail (3 bans in 24h = 1 week ban on all ports)
- **CrowdSec:** Proactive IP blocking with community blocklists + Traefik bouncer
- **Docker:** Version pinned, log rotation, live-restore enabled

## Post-Install

After `bb install node` completes:
1. SSH as admin: `ssh admin@NODE_IP`
2. Verify config: `bb status`
3. Run health check: `bb health`
4. Containers are deployed automatically via Docker Compose (Traefik, Gluetun, Autoscan)
5. Portainer dashboard: `NODE_IP:9001` (monitoring only — deployment is handled by Ansible)
6. (Plex) Copy `.ovpn` file: `cp your-vpn.ovpn /opt/gluetun/config.conf && cd /opt/gluetun && docker compose up -d`
7. Accept CrowdSec enrollment at [app.crowdsec.net](https://app.crowdsec.net)
    