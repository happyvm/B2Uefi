# Vue d'ensemble : migration BIOS → UEFI

## Pourquoi migrer

- **Secure Boot** : nécessite UEFI, indispensable pour Windows 11, recommandé pour durcir les serveurs Linux.
- **Support long terme** : Microsoft et la plupart des distributions Linux orientent leurs nouvelles fonctionnalités de boot vers UEFI (mesured boot, TPM, shielded VMs).
- **Disques > 2 To** : le partitionnement MBR est limité à 2 To et 4 partitions primaires ; GPT (utilisé par UEFI) lève ces limites.
- **Prérequis Windows Server 2022 / Windows 11** et de nombreuses stacks de sécurité (BitLocker + TPM, Credential Guard, VBS) qui exigent UEFI + Secure Boot.

## Ce que "migrer" recouvre réellement

Une migration BIOS → UEFI touche **deux couches indépendantes** qui doivent être traitées dans le bon ordre :

1. **La couche invité (guest OS)** : convertir la table de partitions du disque système de MBR vers GPT, et installer/reconfigurer le bootloader pour qu'il sache démarrer en mode UEFI (`bootmgfw.efi` sous Windows, `grubx64.efi` sous Linux).
2. **La couche hyperviseur (firmware de la VM)** : indiquer à VMware ou Hyper-V que la VM doit désormais présenter un firmware UEFI au système d'exploitation invité, au lieu d'un BIOS legacy (SeaBIOS/PhoenixBIOS émulé).

Ces deux étapes sont **liées mais asymétriques** :

- Convertir le disque en GPT sans basculer le firmware de la VM en UEFI → la VM ne démarre plus (le BIOS legacy ne sait pas lire un GPT contenant un ESP UEFI comme boot device).
- Basculer le firmware en UEFI sans avoir converti le disque → la VM ne démarre plus (le firmware UEFI recherche un ESP FAT32 avec un chargeur `.efi`, qui n'existe pas sur un disque MBR/BIOS boot classique).

L'ordre correct est donc toujours :

```
1. Préparer le disque invité (conversion MBR→GPT + bootloader UEFI)  [OS encore démarré en BIOS]
2. Éteindre la VM
3. Basculer le firmware de la VM sur EFI côté hyperviseur
4. Redémarrer -> la VM démarre désormais en UEFI
```

## Différence fondamentale VMware vs Hyper-V

| | VMware (ESXi/vSphere) | Hyper-V |
|---|---|---|
| Bascule BIOS→EFI sur une VM existante | **Oui**, changement d'un paramètre (`Firmware`) dans les options de démarrage de la VM, sans recréation | **Non**, impossible : le firmware (BIOS/UEFI) est fixé par la **génération** de la VM (Gen 1 = BIOS, Gen 2 = UEFI) et n'est pas modifiable après création |
| Méthode de migration | `Set-VM`/API `ReconfigVM` sur la VM existante | Créer une **nouvelle VM Generation 2**, y rattacher le disque converti (VHDX), recopier la configuration (RAM, réseau, CPU) |
| Voir | [docs/04-vmware-guide.md](04-vmware-guide.md) | [docs/05-hyperv-guide.md](05-hyperv-guide.md) |

## Portée de ce dépôt

| Dossier | Contenu |
|---|---|
| `docs/` | Guides détaillés par plateforme et par OS invité |
| `scripts/windows/` | Vérification de compatibilité + conversion MBR→GPT (wrapper `MBR2GPT.exe`) pour l'OS invité Windows |
| `scripts/linux/` | Vérification de compatibilité + conversion MBR→GPT + réinstallation GRUB-EFI pour l'OS invité Linux |
| `scripts/vmware/` | Scripts PowerCLI pour auditer et basculer le firmware des VM VMware |
| `scripts/hyperv/` | Scripts PowerShell pour auditer les VM Gen 1 et automatiser leur migration vers Gen 2 |

Lire ensuite : [docs/01-prerequisites.md](01-prerequisites.md).
