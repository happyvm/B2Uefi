#!/usr/bin/env bash
# Checks whether the Linux system disk is eligible for MBR -> GPT/UEFI conversion.
# Read-only: this script makes no changes to the system.
#
# Usage: sudo ./check-uefi-readiness.sh [/dev/sda]

set -uo pipefail

DISK="${1:-}"
FAIL=0

ok()   { printf '\033[32m[OK]\033[0m      %s\n' "$1"; }
info() { printf '\033[90m[INFO]\033[0m    %s\n' "$1"; }
warn() { printf '\033[33m[WARNING]\033[0m %s\n' "$1"; }
fail() { printf '\033[31m[FAIL]\033[0m    %s\n' "$1"; FAIL=1; }

if [ "$(id -u)" -ne 0 ]; then
    warn "This script should be run as root for reliable results (parted, full lsblk output)."
fi

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
    fail "Could not automatically determine the system disk. Specify it explicitly: $0 /dev/sda"
    exit 1
fi

disk_type=$(lsblk -ndo TYPE "$DISK" 2>/dev/null || true)
if [ "$disk_type" != "disk" ]; then
    fail "$DISK does not look like a whole disk (lsblk TYPE='$disk_type'). Pass a whole-disk device such as /dev/sda, not a partition."
    exit 1
fi
info "Analyzing disk: $DISK"

if [ -d /sys/firmware/efi ]; then
    info "The VM is already booted in UEFI (nothing to convert on the firmware side, the guest is already compatible)."
else
    ok "VM currently booted in legacy BIOS mode (expected before migration)."
fi

if command -v parted >/dev/null 2>&1; then
    table=$(parted -s "$DISK" print 2>/dev/null | grep -i "Partition Table" | awk -F: '{print $2}' | tr -d ' ')
    case "$table" in
        gpt)   info "Partition table on $DISK is already GPT." ;;
        msdos) ok "Partition table on $DISK is MBR (msdos) - conversion applies." ;;
        *)     fail "Unrecognized partition table on $DISK: '$table'" ;;
    esac
else
    fail "'parted' not found. Install the 'parted' package."
fi

if command -v sgdisk >/dev/null 2>&1; then
    ok "gdisk/sgdisk is present."
else
    warn "'sgdisk' not found (package 'gdisk' / 'gptfdisk') - will be installed by convert-linux-to-uefi.sh."
fi

pkg_mgr=""
for m in apt dnf yum zypper; do
    if command -v "$m" >/dev/null 2>&1; then
        pkg_mgr="$m"
        break
    fi
done
if [ -n "$pkg_mgr" ]; then
    info "Detected package manager: $pkg_mgr"
else
    fail "No known package manager (apt/dnf/yum/zypper) detected."
fi

case "$pkg_mgr" in
    apt)
        if dpkg -s grub-efi-amd64 >/dev/null 2>&1; then
            ok "grub-efi-amd64 is already installed."
        else
            info "grub-efi-amd64 will be installed during conversion."
        fi
        ;;
    dnf|yum)
        if rpm -q grub2-efi-x64 >/dev/null 2>&1; then
            ok "grub2-efi-x64 is already installed."
        else
            info "grub2-efi-x64 will be installed during conversion."
        fi
        ;;
    zypper)
        if rpm -q grub2-x86_64-efi >/dev/null 2>&1; then
            ok "grub2-x86_64-efi is already installed."
        else
            info "grub2-x86_64-efi will be installed during conversion."
        fi
        ;;
esac

free_mb=0
if command -v parted >/dev/null 2>&1; then
    free_mb=$(parted -s "$DISK" unit MiB print free 2>/dev/null |
        awk '/Free Space/ {gsub("MiB",""); if ($3+0 > max) max=$3+0} END {print int(max)}')
fi
free_mb=${free_mb:-0}
if [ "$free_mb" -ge 512 ]; then
    ok "Available free space: ${free_mb} MB (>= 512 MB recommended for the ESP)."
elif [ "$free_mb" -ge 100 ]; then
    warn "Available free space: ${free_mb} MB (minimum 100 MB, 512 MB recommended). Use --esp-size to adjust."
else
    fail "Not enough free space (${free_mb} MB) to create an ESP. Shrink an existing partition first."
fi

echo
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32mResult: ELIGIBLE for conversion.\033[0m\n'
    exit 0
else
    printf '\033[31mResult: NOT ELIGIBLE - fix the failing checks above before running convert-linux-to-uefi.sh.\033[0m\n'
    exit 1
fi
