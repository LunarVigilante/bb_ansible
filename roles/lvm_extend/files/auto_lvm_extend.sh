#!/usr/bin/env bash
# =============================================================================
# BB Ansible — Automated LVM Drive Discovery and Extension
# =============================================================================
# Purpose: Natively detect all unused drives on the host, automatically wipe them, 
# and safely append them into the primary LVM storage pool. Skips the boot drive.
# =============================================================================

# Note: no set -e — some lsblk/lvs calls return non-zero in normal operation

# Colors for log output
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[lvm]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[lvm]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[lvm]${NC} $1"; }
log_err()  { echo -e "${RED}[lvm]${NC} $1"; }

# Check that tools exist
for cmd in lsblk pvs vgs lvs wipefs pvcreate vgextend lvextend xfs_growfs; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_err "Required command '$cmd' not found. Ensure LVM2 and util-linux are installed."
        exit 1
    fi
done

# Optional first argument: comma-separated list of drives to explicitly ignore (e.g., sda,sdb)
IGNORE_LIST="${1:-}"

# Step 1: Detect the root volume group
root_device=$(findmnt -n -o SOURCE /)
if [[ -z "$root_device" ]]; then
    log_err "Failed to detect the root mounted device."
    exit 1
fi

log_info "Root device detected as: $root_device"

# Check if root is an LVM logic volume mapping
if [[ ! "$root_device" == "/dev/mapper/"* && ! "$root_device" == "/dev/vg0/"* ]]; then
    log_warn "Root does not appear to be an LVM mapper partition ($root_device). Skipping LVM extension."
    exit 0
fi

# Extract the VG name from the mapper
root_vg=$(lvs --noheadings -o vg_name "$root_device" | xargs || true)
if [[ -z "$root_vg" ]]; then
    # Fallback assumption if lvs fails parsing mapper path directly
    log_warn "Could not explicitly map VG from $root_device. Presuming 'vg0'."
    root_vg="vg0"
fi

log_ok "Target LVM Volume Group: $root_vg"

# Step 2: Determine disks already enrolled in the LVM group to avoid wiping them
enrolled_disks=$(pvs --noheadings -o pv_name,vg_name | awk -v vg="$root_vg" '$2 == vg {print $1}')

# Identify the root physical disk (where /boot lives, etc.) by looking at partitions
# We'll just grab all block devices that host the current PVs and exclude them.
declare -A protected_disks
for disk in $enrolled_disks; do
    # Strip partition numbers to get base disk name (e.g. /dev/nvme0n1p3 -> /dev/nvme0n1)
    base_disk=$(lsblk -no PKNAME "$disk" 2>/dev/null || echo "$disk")
    while [[ -n "$base_disk" && "$base_disk" != *" "* ]]; do
        protected_disks["/dev/$base_disk"]=1
        base_disk=$(lsblk -no PKNAME "/dev/$base_disk" 2>/dev/null)
    done
    
    # Also grab the raw string fallback
    raw_base=$(echo "$disk" | sed 's/[0-9p]*$//')
    protected_disks["$raw_base"]=1
    protected_disks["$disk"]=1
done

# Also forcefully protect the disk hosting /boot
boot_disk=$(findmnt -n -o SOURCE /boot || true)
if [[ -n "$boot_disk" ]]; then
    base=$(lsblk -no PKNAME "$boot_disk" 2>/dev/null || true)
    if [[ -n "$base" ]]; then protected_disks["/dev/$base"]=1; fi
    protected_disks["$(echo "$boot_disk" | sed 's/[0-9p]*$//')"]=1
fi

log_info "Protected disks: ${!protected_disks[@]}"

# Step 3: Iterate through physical drives and consume empty ones
extended_pool=false

# Get a clean list of all physical disks, excluding loopback, ram, cdrom, sr
candidate_disks=$(lsblk -nd -o NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')

for candidate in $candidate_disks; do
    if [[ "${protected_disks[$candidate]:-}" == "1" ]]; then
        log_warn "Skipping root/enrolled disk: $candidate"
        continue
    fi

    # Check against explicit operator ignore list
    # Strip /dev/ from candidate for exact matching
    base_candidate="${candidate#/dev/}"
    if [[ ",${IGNORE_LIST}," == *",${base_candidate},"* ]]; then
        log_warn "Disk matched explicit operator ignore list ($base_candidate). Insulation active. Skipping."
        continue
    fi

    log_info "Evaluating untapped disk candidate: $candidate"

    # Skip if drive is already an LVM Physical Volume
    if pvs "$candidate" >/dev/null 2>&1; then
        log_warn "Drive $candidate is already an LVM PV. Skipping."
        continue
    fi

    # Skip if drive has partitions (it's probably in use)
    if lsblk -n -o NAME "$candidate" 2>/dev/null | grep -q "^[[:space:]]"; then
        log_warn "Drive $candidate has partitions. Skipping."
        continue
    fi

    # Skip if drive has holders (mounted, dm, md, etc.)
    if [[ -n "$(lsblk -n -o MOUNTPOINT "$candidate" 2>/dev/null | grep -v '^$')" ]]; then
        log_warn "Drive $candidate has active mount points. Skipping."
        continue
    fi

    # Wipe existing signatures (filesystems, partition tables)
    log_info "Wiping $candidate..."
    wipefs -fa "$candidate" >/dev/null 2>&1
    dd if=/dev/zero of="$candidate" bs=1M count=10 >/dev/null 2>&1

    # Enroll into LVM
    log_info "Creating LVM Physical Volume on $candidate..."
    if ! pvcreate -y "$candidate"; then
        log_err "pvcreate failed on $candidate"
        continue
    fi

    log_info "Extending Volume Group $root_vg with $candidate..."
    if ! vgextend "$root_vg" "$candidate"; then
        log_err "vgextend failed for $candidate"
        continue
    fi
    
    log_ok "Successfully appended $candidate to storage pool!"
    extended_pool=true
done

# Step 4: Maximize filesystem capacity if changes occurred
if [[ "$extended_pool" == "true" ]]; then
    log_info "Disk topology altered. Expanding Root Logical Volume..."
    lvextend -l +100%FREE "$root_device"
    
    log_info "Growing XFS filesystem boundary..."
    xfs_growfs "$root_device" || resize2fs "$root_device" || log_err "Failed to grow filesystem."
    
    log_ok "LVM automated scale-up complete!"
else
    log_info "No new physical disks discovered. Storage pool remains untouched."
fi

# Show updated layout
df -h / 2>/dev/null || true
