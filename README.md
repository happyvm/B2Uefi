# B2Uefi

Documentation et scripts pour migrer des machines virtuelles **BIOS → UEFI**, sur **VMware (ESXi/vSphere)** et **Hyper-V**, pour des invités **Windows** et **Linux**.

## Démarrage rapide

1. Lire [docs/00-overview.md](docs/00-overview.md) pour comprendre le principe général (conversion invité vs bascule firmware hyperviseur).
2. Suivre la checklist de [docs/01-prerequisites.md](docs/01-prerequisites.md) (sauvegarde, éligibilité).
3. Convertir l'OS invité :
   - Windows : [docs/02-windows-guide.md](docs/02-windows-guide.md)
   - Linux : [docs/03-linux-guide.md](docs/03-linux-guide.md)
4. Basculer le firmware côté hyperviseur :
   - VMware : [docs/04-vmware-guide.md](docs/04-vmware-guide.md)
   - Hyper-V : [docs/05-hyperv-guide.md](docs/05-hyperv-guide.md)
5. En cas de problème : [docs/06-troubleshooting-rollback.md](docs/06-troubleshooting-rollback.md)

## Structure du dépôt

```
docs/
  00-overview.md                  Vue d'ensemble et ordre des opérations
  01-prerequisites.md             Checklist avant migration
  02-windows-guide.md             Conversion invité Windows (MBR2GPT)
  03-linux-guide.md               Conversion invité Linux (sgdisk + GRUB-EFI)
  04-vmware-guide.md              Bascule firmware VMware (BIOS -> EFI)
  05-hyperv-guide.md              Migration Hyper-V Generation 1 -> Generation 2
  06-troubleshooting-rollback.md  Dépannage et retour arrière

scripts/
  windows/
    Test-UefiReadiness.ps1        Audit d'éligibilité (build, TPM, MBR2GPT /validate)
    Convert-WindowsToUefi.ps1     Conversion MBR -> GPT (wrapper MBR2GPT)
  linux/
    check-uefi-readiness.sh       Audit d'éligibilité (table de partitions, espace libre, paquets)
    convert-linux-to-uefi.sh      Conversion MBR -> GPT + GRUB-EFI (dry-run par défaut)
  vmware/
    Get-VMFirmwareReport.ps1      Audit du firmware des VM (PowerCLI)
    Set-VMFirmware.ps1            Bascule BIOS <-> EFI sur une VM existante (PowerCLI)
  hyperv/
    Get-VMGenerationReport.ps1    Audit des VM Generation 1/2
    Convert-Gen1ToGen2.ps1        Migration automatisée Gen 1 -> Gen 2
```

## Points clés à retenir

- **VMware** : le firmware se bascule sur une VM existante (simple paramètre). **Hyper-V** : impossible en place, il faut recréer une VM Generation 2 et y rattacher le disque converti.
- Dans tous les cas, l'OS invité doit être converti en GPT avec un bootloader UEFI **avant** de basculer le firmware côté hyperviseur, jamais après.
- Tous les scripts destructifs (`convert-linux-to-uefi.sh`, conversions de disque) fonctionnent en simulation par défaut ou exposent `-WhatIf`/`--confirm` — toujours tester en environnement non critique en premier.
- Aucun script ne supprime automatiquement une VM ou un disque d'origine : le nettoyage final reste une action manuelle, après validation.

## Prérequis généraux

- Accès administrateur sur les VM invitées.
- PowerCLI (`Install-Module VMware.PowerCLI`) pour les scripts `scripts/vmware/`.
- Module PowerShell Hyper-V pour les scripts `scripts/hyperv/`.
- `gdisk`/`gptfdisk` et les droits root pour les scripts `scripts/linux/` (installés automatiquement si absents).

Voir [docs/01-prerequisites.md](docs/01-prerequisites.md) pour le détail complet.
