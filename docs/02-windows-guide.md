# Guide Windows : conversion invité MBR → GPT/UEFI

S'applique à Windows 10/11 et Windows Server 2012 R2+ tournant en VM (VMware ou Hyper-V), disque système actuellement en BIOS/MBR.

## Principe

L'outil natif `MBR2GPT.exe` (présent dans `C:\Windows\System32` depuis Windows 10 1703) convertit la table de partitions **en place**, sans perte de données, et prépare les partitions système nécessaires au boot UEFI (ESP, MSR). Il peut s'exécuter :

- depuis l'environnement de récupération (WinRE), sans `/allowFullOS` ;
- depuis l'OS complet démarré normalement, avec `/allowFullOS` (le cas d'usage principal pour une VM en production).

**Important** : `MBR2GPT` ne change pas le firmware de la VM. Après conversion, l'OS boote encore momentanément en BIOS (le firmware de la VM n'a pas changé). Ce n'est qu'après avoir basculé le firmware côté hyperviseur (VMware) ou recréé la VM en Gen 2 (Hyper-V) que le prochain démarrage utilisera UEFI.

## Étapes

### 1. Vérifier l'éligibilité

```powershell
.\scripts\windows\Test-UefiReadiness.ps1
```

Ce script vérifie : build Windows, style de partition actuel, TPM (si Secure Boot est visé), Secure Boot déjà actif ou non, et exécute `mbr2gpt /validate`.

Vous pouvez aussi lancer directement :

```powershell
mbr2gpt /validate /disk:0 /allowFullOS
```

Une validation réussie affiche `MBR2GPT: Validation completed successfully`.

### 2. Convertir le disque

```powershell
.\scripts\windows\Convert-WindowsToUefi.ps1 -DiskNumber 0
```

Ce script exécute `mbr2gpt /validate` puis `mbr2gpt /convert` avec journalisation, et affiche un rappel des étapes suivantes. Équivalent manuel :

```powershell
mbr2gpt /convert /disk:0 /allowFullOS
```

Ne redémarrez pas immédiatement l'OS entre la conversion et le changement de firmware : le disque est désormais en GPT mais la VM démarre toujours en BIOS via l'ancien chemin de boot, ce qui fonctionne encore grâce à la compatibilité descendante — mais l'objectif est de ne pas laisser la VM dans cet état intermédiaire plus longtemps que nécessaire.

### 3. Éteindre la VM

```powershell
Stop-Computer  # ou arrêt propre depuis vCenter / Hyper-V Manager
```

### 4. Basculer le firmware côté hyperviseur

- **VMware** : voir [04-vmware-guide.md](04-vmware-guide.md), script `scripts/vmware/Set-VMFirmware.ps1`.
- **Hyper-V** : voir [05-hyperv-guide.md](05-hyperv-guide.md) — nécessite de recréer la VM en Generation 2 (`scripts/hyperv/Convert-Gen1ToGen2.ps1`), le disque VHDX converti est réattaché à la nouvelle VM.

### 5. Redémarrer et valider

- La VM doit démarrer directement sur le menu Windows (pas d'écran noir/erreur "no bootable device").
- Vérifier le mode de boot effectif :

```powershell
$env:firmware_type      # doit renvoyer "UEFI"
Confirm-SecureBootUEFI   # $true si Secure Boot est activé (optionnel, nécessite d'avoir activé l'option côté hyperviseur)
```

- Vérifier le style de disque :

```powershell
Get-Disk | Select-Object Number, PartitionStyle
```

## Cas particuliers

- **Disque avec plus de 3 partitions primaires** : `MBR2GPT` échoue à la validation. Il faut d'abord fusionner/supprimer des partitions superflues (ou utiliser `/allowFullOS` après nettoyage) avant de relancer.
- **BitLocker actif** : suspendre le chiffrement (`Suspend-BitLocker -MountPoint "C:"`) avant conversion, le réactiver après validation du boot UEFI.
- **Windows 11 / Credential Guard / VBS** : ces fonctions nécessitent en plus Secure Boot et un TPM 2.0 exposé par la VM — à activer séparément côté hyperviseur une fois le boot UEFI validé (VMware : `EfiSecureBootEnabled`, vTPM 2.0 ; Hyper-V : `Set-VMKeyProtector` + `Enable-VMTPM` sur la VM Gen 2, qui nécessite Host Guardian Service ou un hôte autonome avec chiffrement).

Suite : [04-vmware-guide.md](04-vmware-guide.md) ou [05-hyperv-guide.md](05-hyperv-guide.md).
