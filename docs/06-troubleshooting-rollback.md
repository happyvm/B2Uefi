# Dépannage et rollback

## La VM ne démarre plus après bascule firmware ("no bootable device" / écran noir)

Causes les plus fréquentes, par ordre de probabilité :

1. **Le disque n'a pas réellement été converti en GPT avant la bascule** (étape sautée ou échouée silencieusement). Vérifier via un live-CD/rescue : `parted /dev/sda print` doit indiquer `gpt`.
2. **L'ESP n'est pas marquée avec le bon flag** (`esp` sous Linux, partition système EFI sous Windows). Vérifier avec `sgdisk -p /dev/sda` (type `EF00`) ou `Get-Partition` (`GptType` `{c12a7328-...}`).
3. **Ordre de boot** (Hyper-V Gen 2 / VMware) ne pointe pas vers le bon disque/entrée EFI. VMware : vérifier dans les options de démarrage de la VM ; Hyper-V : `Get-VMFirmware -VMName ... | Select BootOrder`.
4. **Secure Boot activé avant que le bootloader ne soit signé/compatible** (fréquent sous Linux sans `shim`). Désactiver Secure Boot temporairement pour confirmer, puis corriger le bootloader.

## Rollback — VMware

Si la VM n'a **pas encore redémarré** après la bascule firmware :

```powershell
.\scripts\vmware\Set-VMFirmware.ps1 -VMName "srv-app01" -Firmware bios
```

Cela ne fonctionne que si le disque invité est encore lisible en BIOS, c'est-à-dire si vous revenez en arrière **avant** la conversion MBR→GPT, ou si vous restaurez le snapshot pris avant la conversion invité. Une fois le disque converti en GPT, un retour en BIOS pur nécessite de restaurer le snapshot pris en [01-prerequisites.md](01-prerequisites.md) — il n'y a pas de "GPT→MBR" sûr pour un disque système déjà démarré en UEFI.

## Rollback — Hyper-V

La VM Gen 1 d'origine n'a jamais été modifiée ni supprimée par `Convert-Gen1ToGen2.ps1` (elle est seulement renommée `-gen1-legacy`). Pour revenir en arrière :

```powershell
Stop-VM -Name "srv-app01" -TurnOff -Force   # arrête la VM Gen 2 si elle a démarré
Remove-VM -Name "srv-app01" -Force          # supprime la VM Gen 2 (le VHDX n'est PAS supprimé, il est simplement détaché)
Rename-VM -Name "srv-app01-gen1-legacy" -NewName "srv-app01"
Start-VM -Name "srv-app01"
```

> Attention : si le disque invité a déjà été converti en GPT avant l'échec, la VM Gen 1 (BIOS) ne pourra pas non plus démarrer dessus. Dans ce cas, restaurer le snapshot/checkpoint pris avant la conversion invité.

## `MBR2GPT /validate` échoue

| Message | Cause | Action |
|---|---|---|
| `Disk layout validation failed` | Plus de 3 partitions primaires, ou disque non standard (RAID logiciel, disque dynamique) | Nettoyer les partitions superflues, ou convertir le disque dynamique en basique |
| `Disk is not a fixed MBR disk` | Le disque est déjà en GPT, ou n'est pas le disque système attendu | Vérifier `Get-Disk`, corriger `/disk:N` |
| `Not enough free space` | Pas assez d'espace non alloué pour créer les partitions ESP/MSR | Réduire une partition existante (`Resize-Partition`) pour libérer ~100 Mo |

## `sgdisk -g` échoue ou le boot GRUB reste en mode BIOS

- **`grub-install: error: /boot/efi is not a mountpoint`** : l'ESP n'a pas été montée avant `grub-install --target=x86_64-efi`. Vérifier `mount | grep efi` et `/etc/fstab`.
- **`grub-install` réussit mais le firmware retombe en BIOS au boot** : normal tant que le firmware de la VM n'a pas été basculé côté hyperviseur — ce n'est pas une erreur de `grub-install`, c'est l'étape hyperviseur qui reste à faire.
- **Le menu GRUB apparaît mais le noyau ne boote pas** : régénérer l'initramfs (`update-initramfs -u -k all` ou `dracut -f --regenerate-all`) — un initramfs généré pour un boot BIOS peut manquer de modules nécessaires (rare mais possible selon la distribution).

## Aucune entrée de boot visible dans le firmware (VMware/Hyper-V)

```bash
# Linux, en rescue si nécessaire
efibootmgr -c -d /dev/sda -p 1 -L "GRUB" -l '\EFI\<distro>\grubx64.efi'
```

recrée manuellement l'entrée NVRAM si `grub-install` ne l'a pas fait (cas de certains environnements EFI émulés qui ignorent les écritures NVRAM automatiques — vérifier alors le firmware boot order manuellement côté hyperviseur en complément).

## Support

Ces scripts couvrent le cas standard (disque système unique, partitionnement classique). Pour des topologies complexes (RAID logiciel, LVM sur `/boot`, multi-boot), valider chaque étape manuellement en environnement de test avant toute exécution en production.
