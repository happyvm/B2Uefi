#!/usr/bin/env bash
# Converts the Linux system disk from MBR to GPT and installs GRUB in UEFI mode.
#
# Usage:
#   ./convert-linux-to-uefi.sh --disk /dev/sda [--esp-size 512] [--confirm] [--yes]
#
# Without --confirm: simulation mode (dry-run), no write is performed.
# With --confirm but without --yes: prompts for an interactive "yes" before
# touching the partition table. --yes skips that prompt for automation.
#
# WARNING: this script modifies the system disk's partition table.
# Read docs/03-linux-guide.md and docs/01-prerequisites.md before running it,
# and make sure a VM snapshot/checkpoint has been taken beforehand.

set -euo pipefail

DISK=""
ESP_SIZE_MB=512
CONFIRM=0
ASSUME_YES=0

usage() {
    cat <<EOF
Usage: $0 --disk /dev/sdX [--esp-size MB] [--confirm] [--yes]

  --disk DEVICE   System disk to convert (required, e.g. /dev/sda)
  --esp-size MB   Size of the ESP to create, in MB (default: 512)
  --confirm       Actually apply the changes (otherwise: simulation)
  --yes           Skip the interactive confirmation prompt (requires --confirm)
  -h, --help      Show this help
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --disk)
            [ $# -ge 2 ] || { echo "Error: --disk requires a value." >&2; usage; }
            DISK="$2"
            shift 2
            ;;
        --esp-size)
            [ $# -ge 2 ] || { echo "Error: --esp-size requires a value." >&2; usage; }
            ESP_SIZE_MB="$2"
            shift 2
            ;;
        --confirm) CONFIRM=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

trap 'echo "Error on line $LINENO. Aborting - the disk may be in an intermediate state, check it manually before retrying." >&2' ERR

[ -n "$DISK" ] || { echo "Error: --disk is required." >&2; usage; }
[ -b "$DISK" ] || { echo "Error: $DISK is not a valid block device." >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Error: this script must be run as root." >&2; exit 1; }

if ! [[ "$ESP_SIZE_MB" =~ ^[0-9]+$ ]] || [ "$ESP_SIZE_MB" -lt 100 ]; then
    echo "Error: --esp-size must be an integer >= 100 (MB)." >&2
    exit 1
fi

disk_type=$(lsblk -ndo TYPE "$DISK" 2>/dev/null || true)
if [ "$disk_type" != "disk" ]; then
    echo "Error: $DISK does not look like a whole disk (lsblk TYPE='$disk_type'). Pass a whole-disk device such as /dev/sda, not a partition." >&2
    exit 1
fi

# sgdisk/mkfs.fat/grub-install are installed later by this script if missing;
# lsblk and blkid (util-linux) are expected to already be present.
for tool in lsblk blkid; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Error: required tool '$tool' not found (part of util-linux)." >&2; exit 1; }
done

run() {
    if [ "$CONFIRM" -eq 1 ]; then
        echo "+ $*"
        "$@"
    else
        echo "[dry-run] $*"
    fi
}

settle() {
    if [ "$CONFIRM" -eq 1 ] && command -v udevadm >/dev/null 2>&1; then
        udevadm settle --timeout=10 || true
    fi
}

wait_for_device() {
    local dev="$1"
    [ "$CONFIRM" -eq 1 ] || return 0
    for _ in $(seq 1 20); do
        [ -b "$dev" ] && return 0
        sleep 0.5
    done
    echo "Error: device $dev did not appear after partition creation." >&2
    return 1
}

echo "=== BIOS -> UEFI migration: $DISK ==="
if [ "$CONFIRM" -eq 1 ]; then
    echo "Mode: LIVE EXECUTION"
else
    echo "Mode: SIMULATION (dry-run, add --confirm to apply)"
fi
echo "Planned ESP size: ${ESP_SIZE_MB} MB"
echo

if [ "$CONFIRM" -eq 1 ] && [ "$ASSUME_YES" -ne 1 ]; then
    echo "This will rewrite the partition table of $DISK and create a new ${ESP_SIZE_MB} MB partition."
    read -r -p "Type 'yes' to continue: " reply
    if [ "$reply" != "yes" ]; then
        echo "Aborted by user." >&2
        exit 1
    fi
fi

# --- 1. Distribution / package manager detection ---
pkg_mgr=""
distro_id="linux"
if [ -r /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    distro_id=$(printf '%s' "${ID:-linux}" | tr -cd 'a-z0-9')
    [ -n "$distro_id" ] || distro_id="linux"
fi
for m in apt dnf yum zypper; do
    if command -v "$m" >/dev/null 2>&1; then
        pkg_mgr="$m"
        break
    fi
done
[ -n "$pkg_mgr" ] || { echo "Error: no supported package manager (apt/dnf/yum/zypper)." >&2; exit 1; }
echo "Detected distribution: $distro_id (package manager: $pkg_mgr)"

case "$pkg_mgr" in
    apt)     pkgs=(gdisk grub-efi-amd64 efibootmgr dosfstools) ;;
    dnf|yum) pkgs=(gdisk grub2-efi-x64 shim-x64 efibootmgr dosfstools) ;;
    zypper)  pkgs=(gptfdisk grub2-x86_64-efi efibootmgr dosfstools) ;;
esac

# --- 2. Package installation (sgdisk must be available before the backup step) ---
echo
echo "=== 1/8: installing required packages (${pkgs[*]}) ==="
case "$pkg_mgr" in
    apt)
        run apt-get update
        run apt-get install -y "${pkgs[@]}"
        ;;
    dnf)     run dnf install -y "${pkgs[@]}" ;;
    yum)     run yum install -y "${pkgs[@]}" ;;
    zypper)  run zypper --non-interactive install "${pkgs[@]}" ;;
esac
if [ "$CONFIRM" -eq 1 ]; then
    command -v sgdisk >/dev/null 2>&1 || { echo "Error: sgdisk still not found after package installation." >&2; exit 1; }
fi

# --- 3. Partition table backup ---
# Two artifacts are saved:
#  - the sgdisk backup, replayable with scripts/linux/restore-partition-table.sh;
#  - a raw dump of the first sector, which is the only copy of the *original MBR*
#    (sgdisk --backup converts the layout to GPT in memory before writing, so it
#    cannot represent the MBR itself). Kept for expert manual recovery.
backup_stamp=$(date +%Y%m%d%H%M%S)
backup_file="/root/$(basename "$DISK")-partition-table-${backup_stamp}.backup"
mbr_backup_file="/root/$(basename "$DISK")-original-${backup_stamp}.mbr"
echo
echo "=== 2/8: backing up the partition table -> $backup_file ==="
run sgdisk --backup="$backup_file" "$DISK"
echo "    also dumping the raw first sector -> $mbr_backup_file"
run dd if="$DISK" of="$mbr_backup_file" bs=512 count=1 status=none
if [ "$CONFIRM" -eq 1 ]; then
    chmod 600 "$backup_file" "$mbr_backup_file"
fi

# --- 4. MBR -> GPT conversion ---
echo
echo "=== 3/8: converting MBR -> GPT ($DISK) ==="
run sgdisk -g "$DISK"
run partprobe "$DISK"
settle

# --- 5. ESP partition creation ---
echo
echo "=== 4/8: creating the ESP (${ESP_SIZE_MB} MB) ==="
if [ "$CONFIRM" -eq 1 ]; then
    last_part_num=$(sgdisk -p "$DISK" 2>/dev/null | awk '/^ *[0-9]+/ {print $1}' | sort -n | tail -1)
    last_part_num=${last_part_num:-0}
    next_part_num=$((last_part_num + 1))
else
    next_part_num="N"
fi
run sgdisk -n "${next_part_num}:0:+${ESP_SIZE_MB}M" -t "${next_part_num}:ef00" -c "${next_part_num}:EFI System Partition" "$DISK"
run partprobe "$DISK"
settle

if [[ "$DISK" =~ [0-9]$ ]]; then
    esp_part="${DISK}p${next_part_num}"
else
    esp_part="${DISK}${next_part_num}"
fi
echo "ESP partition: $esp_part"
wait_for_device "$esp_part"

# --- 6. FAT32 formatting ---
echo
echo "=== 5/8: formatting $esp_part as FAT32 ==="
run mkfs.fat -F32 -n EFI "$esp_part"

# --- 7. Mount + fstab ---
echo
echo "=== 6/8: mounting on /boot/efi and updating /etc/fstab ==="
run mkdir -p /boot/efi
run mount "$esp_part" /boot/efi
if [ "$CONFIRM" -eq 1 ]; then
    esp_uuid=$(blkid -s UUID -o value "$esp_part")
    if ! grep -q "/boot/efi" /etc/fstab; then
        printf 'UUID=%s  /boot/efi  vfat  umask=0077  0  1\n' "$esp_uuid" >> /etc/fstab
        echo "Line added to /etc/fstab for UUID=${esp_uuid}"
    else
        echo "An entry for /boot/efi already exists in /etc/fstab, please check it manually."
    fi
else
    echo "[dry-run] append 'UUID=<esp>  /boot/efi  vfat  umask=0077  0  1' to /etc/fstab"
fi

# --- 8. Installing GRUB in UEFI mode ---
echo
echo "=== 7/8: installing GRUB (UEFI mode) ==="
case "$pkg_mgr" in
    apt)
        run grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$distro_id" --recheck
        run update-grub
        ;;
    dnf|yum)
        run grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$distro_id" --recheck
        run grub2-mkconfig -o "/boot/efi/EFI/${distro_id}/grub.cfg"
        ;;
    zypper)
        run grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$distro_id" --recheck
        run grub2-mkconfig -o /boot/grub2/grub.cfg
        ;;
esac

# --- 9. Initramfs regeneration ---
echo
echo "=== 8/8: regenerating the initramfs ==="
if command -v update-initramfs >/dev/null 2>&1; then
    run update-initramfs -u -k all
elif command -v dracut >/dev/null 2>&1; then
    run dracut -f --regenerate-all
else
    echo "No known initramfs tool found (update-initramfs/dracut) - regenerate it manually."
fi

echo
if [ "$CONFIRM" -eq 1 ]; then
    echo "=== Conversion complete. ==="
else
    echo "=== Simulation complete, no write was performed. Re-run with --confirm to apply. ==="
fi
cat <<EOF

Next steps (NOT performed by this script):
  1. Verify: parted -s $DISK print ; lsblk $DISK ; efibootmgr -v
  2. Shut down the VM (shutdown -h now)
  3. Switch the firmware on the hypervisor side:
       - VMware   : scripts/vmware/Set-VMFirmware.ps1 -Firmware efi
       - Hyper-V  : scripts/hyperv/Convert-Gen1ToGen2.ps1 (Generation 2 VM)
  4. Reboot and validate ( [ -d /sys/firmware/efi ] should be true )

See docs/06-troubleshooting-rollback.md if the VM fails to boot.
EOF
