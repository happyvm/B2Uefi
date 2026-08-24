#!/usr/bin/env bash
# Restores a partition table saved by convert-linux-to-uefi.sh.
#
# Usage:
#   ./restore-partition-table.sh --disk /dev/sda [--backup FILE] [--confirm] [--yes]
#   ./restore-partition-table.sh --disk /dev/sda --list
#
# Without --confirm: simulation mode (dry-run), no write is performed.
#
# ============================ WHAT THIS DOES ================================
# convert-linux-to-uefi.sh saves the partition table with `sgdisk --backup`
# before making changes. This script loads that file back with
# `sgdisk --load-backup`, which undoes partition-table edits made after the
# backup was taken - most usefully, it removes the ESP entry that the
# conversion added.
#
# ========================== WHAT THIS DOES *NOT* DO =========================
# 1. It does NOT convert the disk back to MBR. `sgdisk --backup` run against an
#    MBR disk stores a GPT representation of that layout (sgdisk converts in
#    memory before writing the backup), so restoring it yields GPT, not MBR.
#    convert-linux-to-uefi.sh therefore also dumps the raw first sector to a
#    .mbr file next to the backup; recovering true MBR boot from it is an
#    expert, manual operation and is deliberately not automated here.
# 2. It does NOT undo filesystem-level changes: the ESP formatting, the
#    /etc/fstab entry, the GRUB EFI installation and the initramfs rebuild all
#    remain in place.
#
# For a genuine full rollback, restore the VM snapshot/checkpoint taken before
# the migration. See docs/06-troubleshooting-rollback.md.
# ============================================================================

set -euo pipefail

DISK=""
BACKUP_FILE=""
CONFIRM=0
ASSUME_YES=0
LIST_ONLY=0
BACKUP_DIR="/root"

usage() {
    cat <<EOF
Usage: $0 --disk /dev/sdX [--backup FILE] [--confirm] [--yes]
       $0 --disk /dev/sdX --list

  --disk DEVICE   Disk whose partition table should be restored (required)
  --backup FILE   Backup file to load (default: newest matching backup in $BACKUP_DIR)
  --list          List available backups for this disk and exit
  --confirm       Actually apply the restore (otherwise: simulation)
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
        --backup)
            [ $# -ge 2 ] || { echo "Error: --backup requires a value." >&2; usage; }
            BACKUP_FILE="$2"
            shift 2
            ;;
        --list) LIST_ONLY=1; shift ;;
        --confirm) CONFIRM=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

[ -n "$DISK" ] || { echo "Error: --disk is required." >&2; usage; }
[ -b "$DISK" ] || { echo "Error: $DISK is not a valid block device." >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Error: this script must be run as root." >&2; exit 1; }

disk_type=$(lsblk -ndo TYPE "$DISK" 2>/dev/null || true)
if [ "$disk_type" != "disk" ]; then
    echo "Error: $DISK does not look like a whole disk (lsblk TYPE='$disk_type'). Pass a whole-disk device such as /dev/sda, not a partition." >&2
    exit 1
fi

disk_base=$(basename "$DISK")

# Collect matching backups into an array. nullglob makes the array empty rather
# than leaving the literal pattern when nothing matches.
shopt -s nullglob
backups=("${BACKUP_DIR}/${disk_base}-partition-table-"*.backup)
shopt -u nullglob

echo "=== Partition table restore: $DISK ==="
echo "Available backups in $BACKUP_DIR:"
if [ "${#backups[@]}" -eq 0 ]; then
    echo "  (none found matching ${disk_base}-partition-table-*.backup)"
    if [ "$LIST_ONLY" -eq 1 ]; then
        exit 0
    fi
    echo "Error: no backup available to restore. Restore the VM snapshot instead (docs/06-troubleshooting-rollback.md)." >&2
    exit 1
fi

for f in "${backups[@]}"; do
    printf '  %s  (%s)\n' "$f" "$(date -r "$f" '+%Y-%m-%d %H:%M:%S')"
done

if [ "$LIST_ONLY" -eq 1 ]; then
    exit 0
fi

# --- Resolve the backup file to load ----------------------------------------
if [ -z "$BACKUP_FILE" ]; then
    # The filenames embed a sortable YYYYMMDDHHMMSS stamp, so the lexically
    # last entry is the newest - no need to parse ls output.
    mapfile -t sorted_backups < <(printf '%s\n' "${backups[@]}" | sort)
    BACKUP_FILE="${sorted_backups[-1]}"
    echo
    echo "No --backup given, selecting the newest: $BACKUP_FILE"
fi

[ -f "$BACKUP_FILE" ] || { echo "Error: backup file '$BACKUP_FILE' not found." >&2; exit 1; }
[ -r "$BACKUP_FILE" ] || { echo "Error: backup file '$BACKUP_FILE' is not readable." >&2; exit 1; }
[ -s "$BACKUP_FILE" ] || { echo "Error: backup file '$BACKUP_FILE' is empty." >&2; exit 1; }

command -v sgdisk >/dev/null 2>&1 || { echo "Error: sgdisk not found (package 'gdisk' / 'gptfdisk')." >&2; exit 1; }

echo
echo "Backup to restore : $BACKUP_FILE"
echo "Target disk       : $DISK"
if [ "$CONFIRM" -eq 1 ]; then
    echo "Mode              : LIVE EXECUTION"
else
    echo "Mode              : SIMULATION (dry-run, add --confirm to apply)"
fi

echo
echo "Current layout:"
sgdisk -p "$DISK" 2>/dev/null || true

# --- Guard against restoring onto a mounted-root disk without warning -------
root_src=$(findmnt -no SOURCE / 2>/dev/null || true)
if [ -n "$root_src" ]; then
    root_parent=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n1)
    if [ "/dev/${root_parent}" = "$DISK" ]; then
        echo
        echo "WARNING: $DISK currently hosts the running root filesystem."
        echo "Rewriting its partition table live is risky - prefer running this from a"
        echo "rescue/live environment with the system offline."
    fi
fi

if [ "$CONFIRM" -eq 1 ] && [ "$ASSUME_YES" -ne 1 ]; then
    echo
    echo "This will OVERWRITE the partition table of $DISK with the contents of"
    echo "$BACKUP_FILE. Partitions created after that backup (such as the ESP) will"
    echo "be removed from the table. This does NOT convert the disk back to MBR and"
    echo "does NOT undo /etc/fstab, GRUB or initramfs changes."
    read -r -p "Type 'yes' to continue: " reply
    if [ "$reply" != "yes" ]; then
        echo "Aborted by user." >&2
        exit 1
    fi
fi

echo
if [ "$CONFIRM" -eq 1 ]; then
    echo "+ sgdisk --load-backup=$BACKUP_FILE $DISK"
    sgdisk --load-backup="$BACKUP_FILE" "$DISK"
    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$DISK" || true
    fi
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle --timeout=10 || true
    fi
    echo
    echo "Restored layout:"
    sgdisk -p "$DISK" 2>/dev/null || true
    echo
    echo "=== Restore complete. ==="
else
    echo "[dry-run] sgdisk --load-backup=$BACKUP_FILE $DISK"
    echo
    echo "=== Simulation complete, no write was performed. Re-run with --confirm to apply. ==="
fi

cat <<EOF

Remaining manual steps (this script does not perform them):
  - Remove the /boot/efi line from /etc/fstab if you are abandoning the UEFI layout.
  - Reinstall the BIOS bootloader if you intend to boot this disk in BIOS mode:
      grub-install --target=i386-pc $DISK && update-grub
  - Confirm the hypervisor firmware setting matches the layout you just restored.

If the system still does not boot, restore the pre-migration VM snapshot or
checkpoint - see docs/06-troubleshooting-rollback.md.
EOF
