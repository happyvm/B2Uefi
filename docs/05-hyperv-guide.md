# Guide Hyper-V : migration Generation 1 (BIOS) → Generation 2 (UEFI)

## Différence essentielle avec VMware

Sous Hyper-V, le firmware **n'est pas un paramètre modifiable** sur une VM existante : il est déterminé une fois pour toutes par la **génération** de la VM, choisie à sa création.

| | Generation 1 | Generation 2 |
|---|---|---|
| Firmware | BIOS legacy | UEFI |
| Disque supporté | VHD ou VHDX, IDE ou SCSI | **VHDX uniquement**, SCSI uniquement |
| Secure Boot | Non | Oui (activable) |

**Il n'existe aucune commande officielle pour convertir une VM Gen 1 en Gen 2 en place.** La seule méthode supportée par Microsoft consiste à :
1. Préparer le disque invité pour un boot UEFI (côté OS, pendant que la VM est encore Gen 1) ;
2. Créer une **nouvelle VM Generation 2** ;
3. Rattacher le disque converti à cette nouvelle VM ;
4. Recopier la configuration (RAM, vCPU, réseau, ordre de boot) ;
5. Démarrer la nouvelle VM et valider, en conservant la VM Gen 1 d'origine désactivée jusqu'à validation complète.

## Étapes détaillées

### 1. Convertir le disque invité (VM encore Gen 1, allumée)

- Windows : [02-windows-guide.md](02-windows-guide.md) (`mbr2gpt /convert`)
- Linux : [03-linux-guide.md](03-linux-guide.md) (`convert-linux-to-uefi.sh`)

### 2. S'assurer que le disque est au format VHDX

Generation 2 ne supporte pas le VHD. Si le disque de la VM Gen 1 est un `.vhd` :

```powershell
Convert-VHD -Path "D:\VMs\srv-app01\srv-app01.vhd" -DestinationPath "D:\VMs\srv-app01\srv-app01.vhdx" -VHDType Dynamic
```

### 3. Éteindre la VM Gen 1

```powershell
Stop-VM -Name "srv-app01"
```

### 4. Auditer les VM Gen 1 candidates (optionnel, en amont)

```powershell
.\scripts\hyperv\Get-VMGenerationReport.ps1
```

Liste toutes les VM de l'hôte avec leur génération, leur état, et signale celles en Gen 1 encore en MBR côté disque (nécessitant la conversion invité avant migration).

### 5. Créer la VM Generation 2 et migrer

```powershell
.\scripts\hyperv\Convert-Gen1ToGen2.ps1 -SourceVMName "srv-app01" -NewVMName "srv-app01" -EnableSecureBoot -OSType Windows
```

Le script :
1. Vérifie que la VM source est **éteinte** et que son disque est un VHDX.
2. Renomme la VM Gen 1 source en `srv-app01-gen1-legacy` (elle n'est **jamais supprimée automatiquement**).
3. Crée une nouvelle VM Generation 2 avec le nom d'origine, en recopiant : mémoire (statique ou dynamique), nombre de vCPU, commutateur(s) réseau (adaptateurs synthétiques uniquement — les adaptateurs "Legacy Network Adapter" de Gen 1 ne sont pas supportés en Gen 2 et sont remplacés par leur équivalent synthétique).
4. Attache le VHDX sur un contrôleur SCSI et le place en premier dans l'ordre de démarrage.
5. Configure Secure Boot avec le template adapté :
   - `MicrosoftWindows` pour `-OSType Windows`
   - `MicrosoftUEFICertificateAuthority` pour `-OSType Linux`
   - Secure Boot désactivé si `-DisableSecureBoot` est passé (nécessaire pour certains noyaux Linux non signés).
6. Démarre la nouvelle VM si `-Start` est passé (sinon la laisse éteinte pour contrôle manuel avant premier boot).

### 6. Valider

```powershell
Get-VM "srv-app01" | Select-Object Name, Generation, State
```

Puis dans l'invité (voir sections validation de [02-windows-guide.md](02-windows-guide.md) / [03-linux-guide.md](03-linux-guide.md)).

### 7. Nettoyage final (après validation, manuel)

Une fois le fonctionnement confirmé pendant la période d'observation souhaitée, supprimer la VM `-gen1-legacy` :

```powershell
Remove-VM -Name "srv-app01-gen1-legacy" -Force
```

> Ce dépôt ne supprime **jamais** automatiquement la VM Gen 1 d'origine — c'est une décision volontaire de l'opérateur, effectuée manuellement après validation.

## Limitations connues

- Pas de migration en place pour les VM avec des disques IDE multiples non convertibles individuellement — chaque disque doit être VHDX et rattaché en SCSI sur la nouvelle VM.
- Les "Legacy Network Adapter" (Gen 1 uniquement, émulation matérielle) n'ont pas d'équivalent direct : le script les remplace par des adaptateurs réseau synthétiques standards (mêmes commutateurs virtuels), ce qui peut nécessiter de revérifier l'adresse MAC si elle était statique.
- Windows Server 2008 R2 / Windows 7 : non supportés en Generation 2 par Microsoft, hors périmètre.

Suite : [06-troubleshooting-rollback.md](06-troubleshooting-rollback.md)
