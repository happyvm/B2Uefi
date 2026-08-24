# Guide Linux : conversion invité MBR → GPT/UEFI

S'applique aux distributions grand public (Debian/Ubuntu, RHEL/CentOS/Alma/Rocky, SUSE) tournant en VM (VMware ou Hyper-V), disque système actuellement en BIOS/MBR avec GRUB legacy.

## Principe

Contrairement à Windows, Linux n'a pas d'outil unique "officiel" équivalent à `MBR2GPT`. La conversion se fait en trois opérations distinctes :

1. **Conversion de la table de partitions** MBR → GPT avec `sgdisk` (partie de `gdisk`/`gptfdisk`), qui préserve les partitions existantes et leurs données.
2. **Création d'une ESP** (EFI System Partition, FAT32, flag `esp`) dans l'espace libre du disque, car un disque MBR n'en a jamais eu besoin.
3. **Installation de GRUB en mode UEFI** (`grub-install --target=x86_64-efi`) et régénération de la configuration + de l'initramfs.

Comme pour Windows, ceci ne change pas le firmware de la VM : tant que le firmware reste en BIOS côté hyperviseur, l'OS démarre encore via l'ancien chemin (`/boot/grub/i386-pc`). Ce n'est qu'après bascule firmware (VMware) ou recréation Gen 2 (Hyper-V) que GRUB-EFI prend le relais.

## Étapes

### 1. Vérifier l'éligibilité

```bash
sudo ./scripts/linux/check-uefi-readiness.sh
```

Vérifie : mode de boot actuel (`/sys/firmware/efi`), table de partitions (`parted`), espace libre disponible, présence des paquets nécessaires (`gdisk`, `grub-efi-*`), et détecte le gestionnaire de paquets (apt/dnf/yum/zypper).

### 2. Convertir le disque

```bash
sudo ./scripts/linux/convert-linux-to-uefi.sh --disk /dev/sda --confirm
```

Sans `--confirm`, le script s'exécute en **mode simulation** (dry-run) et affiche uniquement les actions prévues. Le script :

1. Sauvegarde la table de partitions actuelle (`sgdisk --backup`).
2. Installe les paquets manquants (`gdisk`, `grub-efi-amd64`/`grub2-efi-x64`, `efibootmgr`, `dosfstools`).
3. Crée une nouvelle partition ESP dans l'espace libre en fin de disque (par défaut 512 Mo, ajustable avec `--esp-size`).
4. Formate l'ESP en FAT32 et positionne le flag `esp`/`boot`.
5. Convertit la table de partitions en GPT (`sgdisk -g`).
6. Monte l'ESP sur `/boot/efi`, met à jour `/etc/fstab` avec son UUID.
7. Installe GRUB en mode UEFI et régénère `grub.cfg` + l'initramfs.

> ⚠️ Les étapes 3 et 5 modifient la structure du disque. Le script requiert `--confirm` explicitement et affiche un résumé avant toute écriture. Il est recommandé, sur un système critique, de lancer la conversion depuis un live-CD/rescue si possible plutôt qu'à chaud — le script fonctionne dans les deux cas mais le live-CD limite les risques si le disque système est en cours d'écriture intensive.

### 3. Éteindre la VM

```bash
sudo shutdown -h now
```

### 4. Basculer le firmware côté hyperviseur

- **VMware** : voir [04-vmware-guide.md](04-vmware-guide.md).
- **Hyper-V** : voir [05-hyperv-guide.md](05-hyperv-guide.md) — Secure Boot pour Linux doit utiliser le template `MicrosoftUEFICertificateAuthority` (et non `MicrosoftWindows`), ou être désactivé si le noyau/shim n'est pas signé.

### 5. Redémarrer et valider

```bash
[ -d /sys/firmware/efi ] && echo "Démarrage en UEFI" || echo "Toujours en BIOS"
efibootmgr -v
lsblk -o NAME,PARTTYPE,FSTYPE,MOUNTPOINT
```

- `efibootmgr -v` doit lister une entrée de boot pointant vers `\EFI\<distro>\grubx64.efi` sur l'ESP.
- `parted /dev/sda print` doit indiquer `Partition Table: gpt`.

## Cas particuliers

- **/boot séparé chiffré (LUKS)** : GRUB-EFI moderne (2.04+) supporte le déverrouillage LUKS au boot, mais vérifiez la version disponible sur votre distribution avant de migrer un système chiffré.
- **Partitions logiques étendues (MBR)** : `sgdisk -g` les convertit en partitions GPT indépendantes ; vérifiez `/etc/fstab` après conversion, les UUID des partitions existantes ne changent pas mais un `blkid` de contrôle est recommandé.
- **RHEL/CentOS** : le paquet est `grub2-efi-x64` + `shim-x64`, et la commande de régénération est `grub2-mkconfig -o /boot/efi/EFI/<id>/grub.cfg` (le script détecte automatiquement la famille de distribution).
- **Secure Boot** : nécessite un shim signé (`shim-x64` fourni par la distribution), déjà installé par le script si le paquet est disponible dans les dépôts.

Suite : [04-vmware-guide.md](04-vmware-guide.md) ou [05-hyperv-guide.md](05-hyperv-guide.md).
