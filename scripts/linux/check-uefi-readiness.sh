#!/usr/bin/env bash
# Verifie si le disque systeme Linux est eligible a une conversion MBR -> GPT/UEFI.
# Usage: sudo ./check-uefi-readiness.sh [/dev/sda]

set -uo pipefail

DISK="${1:-}"
FAIL=0

ok()   { printf '\033[32m[OK]\033[0m      %s\n' "$1"; }
info() { printf '\033[90m[INFO]\033[0m    %s\n' "$1"; }
warn() { printf '\033[33m[ATTENTION]\033[0m %s\n' "$1"; }
fail() { printf '\033[31m[ECHEC]\033[0m   %s\n' "$1"; FAIL=1; }

if [ "$(id -u)" -ne 0 ]; then
    warn "Ce script doit etre execute en root pour des resultats fiables (parted, lsblk complet)."
fi

if [ -z "$DISK" ]; then
    ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null || true)
    if [ -n "$ROOT_SRC" ]; then
        DISK=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -n1)
        DISK="/dev/${DISK}"
    fi
fi

if [ -z "$DISK" ] || [ ! -b "$DISK" ]; then
    fail "Impossible de determiner le disque systeme automatiquement. Precisez-le : $0 /dev/sda"
    exit 1
fi
info "Disque analyse : $DISK"

if [ -d /sys/firmware/efi ]; then
    info "La VM demarre deja en UEFI (rien a convertir cote firmware, l'invite est deja compatible)."
else
    ok "VM actuellement en BIOS legacy (attendu avant migration)."
fi

if command -v parted >/dev/null 2>&1; then
    TABLE=$(parted -s "$DISK" print 2>/dev/null | grep -i "Partition Table" | awk -F: '{print $2}' | tr -d ' ')
    if [ "$TABLE" = "gpt" ]; then
        info "Table de partitions deja en GPT sur $DISK."
    elif [ "$TABLE" = "msdos" ]; then
        ok "Table de partitions en MBR (msdos) sur $DISK - conversion applicable."
    else
        fail "Table de partitions non reconnue sur $DISK : '$TABLE'"
    fi
else
    fail "'parted' introuvable. Installez le paquet 'parted'."
fi

if command -v sgdisk >/dev/null 2>&1; then
    ok "gdisk/sgdisk present."
else
    warn "'sgdisk' introuvable (paquet 'gdisk' / 'gptfdisk') - sera installe par convert-linux-to-uefi.sh."
fi

PKG_MGR=""
for m in apt dnf yum zypper; do
    if command -v "$m" >/dev/null 2>&1; then PKG_MGR="$m"; break; fi
done
if [ -n "$PKG_MGR" ]; then
    info "Gestionnaire de paquets detecte : $PKG_MGR"
else
    fail "Aucun gestionnaire de paquets connu (apt/dnf/yum/zypper) detecte."
fi

case "$PKG_MGR" in
    apt)
        dpkg -s grub-efi-amd64 >/dev/null 2>&1 && ok "grub-efi-amd64 deja installe." || info "grub-efi-amd64 sera installe lors de la conversion."
        ;;
    dnf|yum)
        rpm -q grub2-efi-x64 >/dev/null 2>&1 && ok "grub2-efi-x64 deja installe." || info "grub2-efi-x64 sera installe lors de la conversion."
        ;;
    zypper)
        rpm -q grub2-x86_64-efi >/dev/null 2>&1 && ok "grub2-x86_64-efi deja installe." || info "grub2-x86_64-efi sera installe lors de la conversion."
        ;;
esac

FREE_MB=0
if command -v parted >/dev/null 2>&1; then
    FREE_MB=$(parted -s "$DISK" unit MiB print free 2>/dev/null | awk '/Free Space/ {gsub("MiB",""); if ($3+0 > max) max=$3+0} END {print int(max)}')
fi
if [ "${FREE_MB:-0}" -ge 512 ]; then
    ok "Espace libre disponible : ${FREE_MB} Mo (>= 512 Mo recommandes pour l'ESP)."
elif [ "${FREE_MB:-0}" -ge 100 ]; then
    warn "Espace libre disponible : ${FREE_MB} Mo (minimum 100 Mo, 512 Mo recommandes). Utilisez --esp-size pour ajuster."
else
    fail "Espace libre insuffisant (${FREE_MB:-0} Mo) pour creer une ESP. Reduisez une partition existante d'abord."
fi

echo
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32mResultat : ELIGIBLE a la conversion.\033[0m\n'
    exit 0
else
    printf '\033[31mResultat : NON ELIGIBLE - corriger les points en echec avant convert-linux-to-uefi.sh.\033[0m\n'
    exit 1
fi
