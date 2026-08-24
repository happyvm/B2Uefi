#!/usr/bin/env bash
# Validates that a Linux guest actually booted in UEFI mode after migration.
#
# Run this inside the guest after the firmware switch and the first reboot. It
# confirms the things that must all be true for the migration to be complete:
# the firmware is UEFI, the disk is GPT, an ESP exists and is mounted, /etc/fstab
# persists it, a GRUB EFI binary is installed, and a boot entry exists.
#
# Read-only: this script makes no changes to the system.
# Exits 0 when the migration is confirmed, 1 when any check fails.
#
# Usage: sudo ./verify-uefi-migration.sh [/dev/sda]

set -uo pipefail

DISK="${1:-}"
FAIL=0

ok()   { printf '\033[32m[OK]\033[0m      %s\n' "$1"; }
info() { printf '\033[90m[INFO]\033[0m    %s\n' "$1"; }
warn() { printf '\033[33m[WARNING]\033[0m %s\n' "$1"; }
fail() { printf '\033[31m[FAIL]\033[0m    %s\n' "$1"; FAIL=1; }

if [ "$(id -u)" -ne 0 ]; then
    warn "This script should be run as root for reliable results (efibootmgr, sgdisk)."
fi

echo "=== Post-migration UEFI validation ==="

# --- 1. Firmware mode -------------------------------------------------------
# The kernel only populates /sys/firmware/efi when it was booted by UEFI.
if [ -d /sys/firmware/efi ]; then
    ok "Booted in UEFI mode (/sys/firmware/efi is present)."
else
    fail "Still booted in legacy BIOS mode - the hypervisor firmware switch has not taken effect."
fi

# --- 2. Resolve the system disk --------------------------------------------
if [ -z "$DISK" ]; then
    root_src=$(findmnt -no SOURCE / 2>/dev/null || true)
    if [ -n "$root_src" ]; then
        parent=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n1)
        if [ -n "$parent" ]; then
            DISK="/dev/${parent}"
        fi
    fi
fi

if [ -z "$DISK" ] || [ ! -b "$DISK" ]; then
    fail "Could not determine the system disk. Specify it explicitly: $0 /dev/sda"
else
    info "System disk: $DISK"

    # --- 3. Partition table is GPT -----------------------------------------
    if command -v parted >/dev/null 2>&1; then
        table=$(parted -s "$DISK" print 2>/dev/null | grep -i "Partition Table" | awk -F: '{print $2}' | tr -d ' ')
        if [ "$table" = "gpt" ]; then
            ok "Partition table on $DISK is GPT."
        else
            fail "Partition table on $DISK is '$table', expected 'gpt' - the conversion did not apply."
        fi
    else
        warn "'parted' not available, skipping the partition table check."
    fi

    # --- 4. An ESP exists (type EF00) --------------------------------------
    if command -v sgdisk >/dev/null 2>&1; then
        if sgdisk -p "$DISK" 2>/dev/null | grep -qi 'EF00'; then
            ok "An EFI System Partition (type EF00) exists on $DISK."
        else
            fail "No EFI System Partition (type EF00) found on $DISK."
        fi
    else
        warn "'sgdisk' not available, skipping the ESP type check."
    fi
fi

# --- 5. The ESP is mounted ---------------------------------------------------
if mountpoint -q /boot/efi 2>/dev/null; then
    esp_dev=$(findmnt -no SOURCE /boot/efi)
    esp_fs=$(findmnt -no FSTYPE /boot/efi)
    if [ "$esp_fs" = "vfat" ]; then
        ok "ESP mounted at /boot/efi ($esp_dev, $esp_fs)."
    else
        fail "/boot/efi is mounted but its filesystem is '$esp_fs', expected 'vfat'."
    fi
else
    fail "/boot/efi is not mounted - the ESP is missing from the running system."
fi

# --- 6. /etc/fstab persists the ESP -----------------------------------------
if grep -qE '^[^#].*[[:space:]]/boot/efi[[:space:]]' /etc/fstab 2>/dev/null; then
    ok "/etc/fstab contains an entry for /boot/efi (the mount survives reboot)."
else
    fail "No /boot/efi entry in /etc/fstab - the ESP will not be mounted on next boot."
fi

# --- 7. A GRUB EFI binary is installed on the ESP ---------------------------
if [ -d /boot/efi/EFI ]; then
    efi_loader=$(find /boot/efi/EFI -maxdepth 2 -type f \( -iname 'grubx64.efi' -o -iname 'shimx64.efi' -o -iname 'bootx64.efi' \) 2>/dev/null | head -n1)
    if [ -n "$efi_loader" ]; then
        ok "EFI boot loader present: $efi_loader"
    else
        fail "No EFI boot loader (grubx64.efi / shimx64.efi / bootx64.efi) found under /boot/efi/EFI."
    fi
else
    fail "/boot/efi/EFI does not exist - GRUB was not installed in UEFI mode."
fi

# --- 8. Firmware boot entries ------------------------------------------------
if command -v efibootmgr >/dev/null 2>&1; then
    if [ -d /sys/firmware/efi ]; then
        entries=$(efibootmgr 2>/dev/null | grep -c '^Boot[0-9A-Fa-f]\{4\}' || true)
        if [ "${entries:-0}" -gt 0 ]; then
            ok "$entries firmware boot entry/entries registered (efibootmgr)."
        else
            warn "No firmware boot entry listed. Some emulated EFI firmwares ignore NVRAM writes; check the boot order on the hypervisor side."
        fi
    else
        info "Skipping efibootmgr: not booted in UEFI mode."
    fi
else
    warn "'efibootmgr' not installed, skipping the boot entry check."
fi

# --- 9. Secure Boot (informational) -----------------------------------------
if [ -d /sys/firmware/efi/efivars ]; then
    sb_var=$(find /sys/firmware/efi/efivars -maxdepth 1 -name 'SecureBoot-*' 2>/dev/null | head -n1)
    if [ -n "$sb_var" ]; then
        # The 5th byte of the SecureBoot EFI variable is the actual flag.
        sb_state=$(od -An -t u1 -j 4 -N 1 "$sb_var" 2>/dev/null | tr -d ' ')
        if [ "${sb_state:-0}" = "1" ]; then
            ok "Secure Boot is enabled."
        else
            info "Secure Boot is available but disabled - enable it on the hypervisor side if required."
        fi
    else
        info "Secure Boot state not exposed by this firmware."
    fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32mResult: MIGRATION CONFIRMED - the guest is running in UEFI mode on a GPT disk.\033[0m\n'
    printf 'You can now remove the pre-migration snapshot/checkpoint to reclaim space.\n'
    exit 0
else
    printf '\033[31mResult: MIGRATION NOT CONFIRMED - see docs/06-troubleshooting-rollback.md\033[0m\n'
    exit 1
fi
