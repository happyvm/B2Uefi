# Guide VMware (ESXi/vSphere) : bascule du firmware BIOS → EFI

Contrairement à Hyper-V, VMware ne distingue pas de "génération" de VM : le firmware (`BIOS` ou `EFI`) est un simple paramètre de configuration de la VM, modifiable **VM éteinte**, sans recréation.

## Prérequis

- La conversion invité (MBR→GPT + bootloader UEFI) doit être **déjà effectuée** ([02-windows-guide.md](02-windows-guide.md) / [03-linux-guide.md](03-linux-guide.md)) avant de basculer le firmware, sous peine de VM non démarrable.
- VM **éteinte** (le paramètre firmware n'est pas modifiable à chaud).
- PowerCLI connecté à vCenter ou à l'hôte ESXi : `Connect-VIServer -Server <vcenter>`.
- Droit `VirtualMachine.Config.Settings`.

## Auditer les VM (avant migration)

```powershell
.\scripts\vmware\Get-VMFirmwareReport.ps1 -VMName "*"
```

Liste pour chaque VM : firmware actuel (`bios`/`efi`), version matérielle, état d'alimentation, et si le hardware version supporte Secure Boot (≥ 13).

## Basculer le firmware d'une VM

```powershell
.\scripts\vmware\Set-VMFirmware.ps1 -VMName "srv-app01" -Firmware efi
```

Le script :
1. Vérifie que la VM est éteinte (sinon échec explicite, il ne l'arrête pas automatiquement).
2. Applique `Firmware = efi` via `ReconfigVM_Task`.
3. Ajuste `motherboardLayout` (`acpiHostBridges` pour EFI, requis à partir de vSphere 8 sur certaines configs) — voir la note ci-dessous.
4. Attend la fin de la tâche et affiche le résultat.

Pour activer Secure Boot en plus (une fois le boot UEFI simple validé sur un premier redémarrage) :

```powershell
.\scripts\vmware\Set-VMFirmware.ps1 -VMName "srv-app01" -Firmware efi -EnableSecureBoot
```

> Secure Boot exige hardware version ≥ 13 et un bootloader/kernel signé côté invité (Windows : nativement signé ; Linux : `shim-x64` + noyau signé, sinon le boot échouera avec Secure Boot activé).

## Note sur `motherboardLayout` (vSphere 8+)

Depuis vSphere 8, certaines VM EFI nécessitent explicitement `motherboardLayout = acpiHostBridges` (au lieu de `i440bxHostBridge`, valeur historique BIOS) pour un fonctionnement correct de l'ACPI. Le script le positionne automatiquement en fonction du firmware choisi ; en cas de doute sur une VM déjà en EFI mais avec un layout `i440bxHostBridge` hérité, relancez le script sur cette VM pour corriger le paramètre.

## Rollback

Tant que la VM n'a pas redémarré avec succès, il suffit de repasser `Firmware = bios` avec le même script (`-Firmware bios`) pour revenir à l'état précédent — **à condition que le disque invité soit toujours en MBR** (n'effectuez pas encore la conversion invité si vous n'êtes pas sûr de vouloir basculer immédiatement). Si le disque invité a déjà été converti en GPT et que vous devez revenir en arrière, restaurez le snapshot pris avant migration (voir [01-prerequisites.md](01-prerequisites.md)).

## Validation post-migration

```powershell
$vm = Get-VM "srv-app01"
$vm.ExtensionData.Config.Firmware        # doit renvoyer "efi"
$vm.ExtensionData.Config.BootOptions.EfiSecureBootEnabled   # $true si activé
```

Suite : [06-troubleshooting-rollback.md](06-troubleshooting-rollback.md)
