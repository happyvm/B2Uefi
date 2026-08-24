# Prérequis et checklist avant migration

## 1. Sauvegarde

- **Snapshot VMware** ou **checkpoint Hyper-V** de la VM avant toute opération, en plus d'une sauvegarde applicative classique (Veeam, etc.).
- Sur l'invité, exporter la table de partitions actuelle :
  - Linux : `sgdisk --backup=/root/partition-table.backup /dev/sda` (fonctionne aussi en source MBR)
  - Windows : `mbr2gpt /validate` génère déjà un rapport ; conserver aussi une image système (`wbadmin` ou équivalent) avant conversion.
- Ne jamais lancer la conversion sans pouvoir revenir en arrière (snapshot + backup applicatif).

## 2. Compatibilité du système d'exploitation invité

| OS | Version minimale supportée pour conversion en place | Outil |
|---|---|---|
| Windows | Windows 10 1703+ / Windows Server 2012 R2+ (build ≥ 15063 pour l'outil natif) | `MBR2GPT.exe` |
| Linux | Noyau avec support EFI (quasi toutes les distributions depuis 2015), `gdisk`/`sgdisk` (paquet `gdisk`/`gptfdisk`), paquet `grub-efi-amd64`/`grub2-efi-x64` disponible | `sgdisk` + `grub-install` |

- Architecture x86_64 obligatoire (le 32 bits UEFI existe mais n'est pas couvert par ces scripts).
- Windows Server 2008 R2 / Windows 7 et antérieurs : **pas d'outil natif**, migration hors périmètre de ce dépôt (nécessite une réinstallation ou un outil tiers).

## 3. Disque système

- Un seul disque système par migration (ne pas convertir un disque de données seul si l'OS ne boote pas dessus).
- **Windows** : `MBR2GPT` exige au maximum 3 partitions primaires visibles + de l'espace libre non alloué (~ quelques dizaines de Mo) pour créer les nouvelles partitions système EFI/MSR. Pas de volume RAID logiciel sur le disque système.
- **Linux** : espace libre disponible pour créer une partition EFI System Partition (ESP, ≥ 100 Mo, idéalement 512 Mo, formatée FAT32) — soit de l'espace non alloué en fin de disque, soit une partition à réduire.
- Pas de disque chiffré au niveau bloc avant conversion (BitLocker doit être **suspendu**, `luksOpen`/dm-crypt doit être pris en compte séparément — hors script).

## 4. Côté hyperviseur

### VMware
- VM **hardware version ≥ 13** pour Secure Boot (EFI seul fonctionne dès la version 7, mais restez sur une version récente supportée).
- Droits vSphere : `VirtualMachine.Config.Settings` sur la VM.
- PowerCLI installé (`Install-Module VMware.PowerCLI`) si vous utilisez les scripts fournis.

### Hyper-V
- Hyper-V sur Windows Server 2012 R2+ / Windows 10+ (Generation 2 requiert ces versions minimum côté hôte).
- Espace disque suffisant pour dupliquer/déplacer le VHDX pendant la migration (la VM Gen 1 d'origine doit être conservée intacte jusqu'à validation du démarrage de la nouvelle VM Gen 2).
- Le disque doit être au format **VHDX** (Gen 2 ne supporte pas VHD) ; convertir avec `Convert-VHD` si nécessaire.

## 5. Fenêtre de maintenance

Compter un arrêt de service pendant :
1. La conversion du disque (peut se faire OS démarré, sans coupure, pour Windows comme pour Linux).
2. L'arrêt de la VM, le basculement firmware (VMware) ou la recréation Gen 2 (Hyper-V), et le redémarrage — **c'est cette étape qui coupe le service**.

## Checklist synthétique

- [ ] Snapshot/checkpoint pris
- [ ] Sauvegarde applicative validée et restaurable
- [ ] BitLocker suspendu (si applicable)
- [ ] Rapport de compatibilité généré (`Test-UefiReadiness.ps1` / `check-uefi-readiness.sh`) sans erreur bloquante
- [ ] Espace libre confirmé sur le disque système
- [ ] Fenêtre de maintenance planifiée
- [ ] Procédure de rollback relue ([06-troubleshooting-rollback.md](06-troubleshooting-rollback.md))

Suite : [02-windows-guide.md](02-windows-guide.md) · [03-linux-guide.md](03-linux-guide.md)
