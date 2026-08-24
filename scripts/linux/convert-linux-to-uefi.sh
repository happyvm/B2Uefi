#!/usr/bin/env bash
# Convertit le disque systeme Linux de MBR vers GPT et installe GRUB en mode UEFI.
#
# Usage:
#   ./convert-linux-to-uefi.sh --disk /dev/sda [--esp-size 512] [--confirm]
#
# Sans --confirm : mode simulation (dry-run), aucune ecriture n'est effectuee.
#
# ATTENTION : ce script modifie la table de partitions du disque systeme.
# Lire docs/03-linux-guide.md et docs/01-prerequisites.md avant execution,
# et s'assurer qu'un snapshot/checkpoint de la VM a ete pris au prealable.

set -euo pipefail

DISK=""
ESP_SIZE_MB=512
CONFIRM=0

usage() {
    cat <<EOF
Usage: $0 --disk /dev/sdX [--esp-size Mo] [--confirm]

  --disk DEVICE   Disque systeme a convertir (obligatoire, ex: /dev/sda)
  --esp-size MO   Taille de l'ESP a creer en Mo (defaut: 512)
  --confirm       Applique reellement les changements (sinon: simulation)
  -h, --help      Affiche cette aide
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --disk) DISK="$2"; shift 2 ;;
        --esp-size) ESP_SIZE_MB="$2"; shift 2 ;;
        --confirm) CONFIRM=1; shift ;;
        -h|--help) usage ;;
        *) echo "Option inconnue : $1" >&2; usage ;;
    esac
done

[ -z "$DISK" ] && { echo "Erreur : --disk est obligatoire." >&2; usage; }
[ -b "$DISK" ] || { echo "Erreur : $DISK n'est pas un disque bloc valide." >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Erreur : ce script doit etre execute en root." >&2; exit 1; }

run() {
    if [ "$CONFIRM" -eq 1 ]; then
        echo "+ $*"
        "$@"
    else
        echo "[dry-run] $*"
    fi
}

echo "=== Migration BIOS -> UEFI : $DISK ==="
echo "Mode : $([ "$CONFIRM" -eq 1 ] && echo 'EXECUTION REELLE' || echo 'SIMULATION (dry-run, ajoutez --confirm pour appliquer)')"
echo "Taille ESP prevue : ${ESP_SIZE_MB} Mo"
echo

# --- 1. Detection distribution / gestionnaire de paquets ---
PKG_MGR=""
DISTRO_ID="linux"
if [ -r /etc/os-release ]; then
    . /etc/os-release
    DISTRO_ID="${ID:-linux}"
fi
for m in apt dnf yum zypper; do
    if command -v "$m" >/dev/null 2>&1; then PKG_MGR="$m"; break; fi
done
[ -z "$PKG_MGR" ] && { echo "Erreur : aucun gestionnaire de paquets supporte (apt/dnf/yum/zypper)." >&2; exit 1; }
echo "Distribution detectee : $DISTRO_ID (gestionnaire : $PKG_MGR)"

case "$PKG_MGR" in
    apt)    PKGS="gdisk grub-efi-amd64 efibootmgr dosfstools" ;;
    dnf|yum) PKGS="gdisk grub2-efi-x64 shim-x64 efibootmgr dosfstools" ;;
    zypper) PKGS="gptfdisk grub2-x86_64-efi efibootmgr dosfstools" ;;
esac

# --- 2. Sauvegarde de la table de partitions ---
BACKUP_FILE="/root/$(basename "$DISK")-partition-table-$(date +%Y%m%d%H%M%S).backup"
echo
echo "=== 1/8 : sauvegarde de la table de partitions -> $BACKUP_FILE ==="
run sgdisk --backup="$BACKUP_FILE" "$DISK"

# --- 3. Installation des paquets ---
echo
echo "=== 2/8 : installation des paquets requis ($PKGS) ==="
case "$PKG_MGR" in
    apt)     run apt-get update -y && run apt-get install -y $PKGS ;;
    dnf)     run dnf install -y $PKGS ;;
    yum)     run yum install -y $PKGS ;;
    zypper)  run zypper --non-interactive install $PKGS ;;
esac

# --- 4. Conversion MBR -> GPT ---
echo
echo "=== 3/8 : conversion MBR -> GPT ($DISK) ==="
run sgdisk -g "$DISK"
run partprobe "$DISK"

# --- 5. Creation de la partition ESP ---
echo
echo "=== 4/8 : creation de l'ESP (${ESP_SIZE_MB} Mo) ==="
if [ "$CONFIRM" -eq 1 ]; then
    NEXT_PART_NUM=$(( $(sgdisk -p "$DISK" | awk '/^ *[0-9]+/ {print $1}' | sort -n | tail -1) + 1 ))
else
    NEXT_PART_NUM="N"
fi
run sgdisk -n "${NEXT_PART_NUM}:0:+${ESP_SIZE_MB}M" -t "${NEXT_PART_NUM}:ef00" -c "${NEXT_PART_NUM}:EFI System Partition" "$DISK"
run partprobe "$DISK"

if [[ "$DISK" =~ [0-9]$ ]]; then
    ESP_PART="${DISK}p${NEXT_PART_NUM}"
else
    ESP_PART="${DISK}${NEXT_PART_NUM}"
fi
echo "Partition ESP : $ESP_PART"

# --- 6. Formatage FAT32 ---
echo
echo "=== 5/8 : formatage FAT32 de $ESP_PART ==="
run mkfs.fat -F32 -n EFI "$ESP_PART"

# --- 7. Montage + fstab ---
echo
echo "=== 6/8 : montage sur /boot/efi et mise a jour de /etc/fstab ==="
run mkdir -p /boot/efi
run mount "$ESP_PART" /boot/efi
if [ "$CONFIRM" -eq 1 ]; then
    ESP_UUID=$(blkid -s UUID -o value "$ESP_PART")
    if ! grep -q "/boot/efi" /etc/fstab; then
        echo "UUID=${ESP_UUID}  /boot/efi  vfat  umask=0077  0  1" >> /etc/fstab
        echo "Ligne ajoutee a /etc/fstab pour UUID=${ESP_UUID}"
    else
        echo "Une entree /boot/efi existe deja dans /etc/fstab, verifiez-la manuellement."
    fi
else
    echo "[dry-run] ajout d'une ligne UUID=<esp>  /boot/efi  vfat  umask=0077  0  1 dans /etc/fstab"
fi

# --- 8. Installation de GRUB en mode UEFI ---
echo
echo "=== 7/8 : installation de GRUB (mode UEFI) ==="
case "$PKG_MGR" in
    apt)
        run grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$DISTRO_ID" --recheck
        run update-grub
        ;;
    dnf|yum)
        run grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$DISTRO_ID" --recheck
        GRUB_CFG="/boot/efi/EFI/${DISTRO_ID}/grub.cfg"
        run grub2-mkconfig -o "$GRUB_CFG"
        ;;
    zypper)
        run grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$DISTRO_ID" --recheck
        run grub2-mkconfig -o /boot/grub2/grub.cfg
        ;;
esac

# --- 9. Regeneration de l'initramfs ---
echo
echo "=== 8/8 : regeneration de l'initramfs ==="
if command -v update-initramfs >/dev/null 2>&1; then
    run update-initramfs -u -k all
elif command -v dracut >/dev/null 2>&1; then
    run dracut -f --regenerate-all
else
    echo "Aucun outil initramfs connu trouve (update-initramfs/dracut) - a regenerer manuellement."
fi

echo
if [ "$CONFIRM" -eq 1 ]; then
    echo "=== Conversion terminee. ==="
else
    echo "=== Simulation terminee, aucune ecriture effectuee. Relancez avec --confirm pour appliquer. ==="
fi
cat <<EOF

Prochaines etapes (NON effectuees par ce script) :
  1. Verifier : parted -s $DISK print ; lsblk $DISK ; efibootmgr -v
  2. Eteindre la VM (shutdown -h now)
  3. Basculer le firmware cote hyperviseur :
       - VMware   : scripts/vmware/Set-VMFirmware.ps1 -Firmware efi
       - Hyper-V  : scripts/hyperv/Convert-Gen1ToGen2.ps1 (VM Generation 2)
  4. Redemarrer et valider ( [ -d /sys/firmware/efi ] doit etre vrai )

Voir docs/06-troubleshooting-rollback.md en cas de probleme au demarrage.
EOF
