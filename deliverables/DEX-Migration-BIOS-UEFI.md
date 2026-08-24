---
title: "Document d'Exploitation"
subtitle: "Procédure de migration BIOS vers UEFI — VMware et Hyper-V"
author: "Direction Infrastructure"
date: "Version 1.0"
lang: fr-FR
toc: true
toc-title: "Table des matières"
toc-depth: 3
numbersections: true
---

# Fiche du document

| Rubrique | Valeur |
|---|---|
| Titre | Document d'Exploitation — Migration BIOS vers UEFI |
| Référence | DEX-B2UEFI-001 |
| Version | 1.0 |
| Statut | À valider |
| Classification | Interne |
| Document d'architecture associé | DAT-B2UEFI-001 |
| Public visé | Exploitants système et virtualisation, astreinte N2/N3 |
| Rédacteur | *(à compléter)* |
| Valideur exploitation | *(à compléter)* |

## Historique des révisions

| Version | Date | Auteur | Nature de la modification |
|---|---|---|---|
| 1.0 | *(à compléter)* | *(à compléter)* | Création initiale |

## Avertissement

Cette procédure modifie la table de partitions du disque système et le firmware de machines virtuelles de production. **Une erreur d'enchaînement rend la machine non démarrable.**

Aucune étape de ce document ne doit être engagée sans :

1. un instantané (snapshot / checkpoint) vérifié restaurable ;
2. une sauvegarde applicative validée ;
3. une fenêtre de maintenance actée avec les responsables applicatifs.

# Objet et conditions d'emploi

## Objet

Ce document décrit la procédure d'exploitation à appliquer pour migrer une machine virtuelle du mode d'amorçage BIOS vers UEFI, sur VMware ou Hyper-V, pour un système invité Windows ou Linux.

Il couvre la préparation, l'exécution, les points de contrôle, le retour arrière et le diagnostic des incidents courants.

## Durée et impact

| Phase | Durée indicative | Interruption de service |
|---|---|---|
| Audit d'éligibilité | 5 min | Non |
| Instantané de sécurité | 2 à 10 min | Non |
| Conversion du disque invité | 5 à 15 min | **Non** (système en fonctionnement) |
| Arrêt, bascule firmware, redémarrage | 5 à 15 min | **Oui** |
| Validation post-migration | 5 min | Non |
| **Total avec interruption** | — | **5 à 15 minutes** |

Pour les systèmes Windows Server 2012 R2 et 2016, la conversion s'effectue hors ligne sur média WinPE : l'interruption s'étend alors à **30 à 45 minutes**.

## Règle d'or

> La conversion du disque invité se fait **toujours avant** la bascule du firmware. Jamais l'inverse. Jamais les deux dans la même opération sans validation intermédiaire.

# Éligibilité — à vérifier avant toute planification

Contrôler la version du système invité dans le tableau ci-dessous **avant** d'engager quoi que ce soit.

## Windows Server

| Version | Verdict | Procédure applicable |
|---|---|---|
| 2019, 2022, 2025 | **Autorisé** | Procédure nominale (section 5) |
| 2016 | **Hors ligne uniquement** | Procédure WinPE (section 6) |
| 2012 / 2012 R2 | **Hors ligne uniquement** | Procédure WinPE (section 6) |
| 2008 / 2008 R2 | **INTERDIT** | Aucune voie supportée. Escalader vers l'architecte. |
| 2003 / 2003 R2 | **INTERDIT** | Aucune voie supportée. Escalader vers l'architecte. |

> **Piège fréquent :** l'outil `MBR2GPT.exe` n'est **pas présent** sur Windows Server 2016 ni sur Server 2012 R2. Il n'est livré qu'à partir du socle Windows 10 1703 (build 15063), soit Server 2019. Ne pas copier le binaire depuis un autre système : opération non supportée par l'éditeur.

## Red Hat Enterprise Linux (et CentOS / AlmaLinux / Rocky équivalents)

| Version | Verdict | Observation |
|---|---|---|
| RHEL 8, 9, 10 | **Autorisé** | Procédure nominale |
| RHEL 7 | **Autorisé sous réserve** | OS hors support complet. Valider avec l'architecte l'intérêt de convertir plutôt que de migrer de version. |
| RHEL 6 | **INTERDIT** | Chemin UEFI non fiable, OS hors support |
| RHEL 5 | **INTERDIT** | UEFI non viable sur x86_64 |

# Préparation de l'intervention

## Checklist de pré-intervention

À compléter et à conserver comme preuve d'exécution.

| # | Point de contrôle | Fait |
|---|---|---|
| 1 | Version du système invité vérifiée dans la matrice d'éligibilité | ☐ |
| 2 | Fenêtre de maintenance actée avec le responsable applicatif | ☐ |
| 3 | Sauvegarde applicative récente et **testée restaurable** | ☐ |
| 4 | Instantané / point de contrôle créé | ☐ |
| 5 | Espace disque libre suffisant sur la banque de données / l'hôte | ☐ |
| 6 | BitLocker suspendu (invités Windows chiffrés) | ☐ |
| 7 | Audit d'éligibilité exécuté sans erreur bloquante | ☐ |
| 8 | Configuration réseau relevée (adresses MAC statiques éventuelles) | ☐ |
| 9 | Accès console hyperviseur disponible (indispensable si la VM ne démarre plus) | ☐ |
| 10 | Procédure de retour arrière lue et comprise par l'intervenant | ☐ |

## Commandes de préparation

### Instantané de sécurité — VMware

```powershell
Connect-VIServer -Server <vcenter>
.\scripts\vmware\New-PreMigrationSnapshot.ps1 -VMName "srv-app01"
```

### Point de contrôle de sécurité — Hyper-V

```powershell
.\scripts\hyperv\New-PreMigrationCheckpoint.ps1 -VMName "srv-app01"
```

Les deux scripts signalent les instantanés déjà présents et affichent les commandes exactes de restauration et de nettoyage. **Relever ces commandes avant de poursuivre.**

### Suspension de BitLocker (invité Windows chiffré)

```powershell
Suspend-BitLocker -MountPoint "C:" -RebootCount 0
Get-BitLockerVolume -MountPoint "C:" | Select-Object MountPoint, ProtectionStatus
```

# Procédure nominale

Applicable aux invités Windows Server 2019 et supérieur, et RHEL 7 et supérieur.

## Étape 1 — Audit d'éligibilité

Exécution **dans le système invité**, sans impact.

### Invité Windows

```powershell
.\scripts\windows\Test-UefiReadiness.ps1
```

### Invité Linux

```bash
sudo ./scripts/linux/check-uefi-readiness.sh
```

**Point de contrôle n°1 :** le script doit se terminer par un verdict d'éligibilité et un code retour 0.

| Résultat | Décision |
|---|---|
| Éligible (code 0) | Poursuivre à l'étape 2 |
| Non éligible (code 1) | **Arrêt.** Traiter les points en échec ou escalader. Ne pas poursuivre. |

## Étape 2 — Conversion du disque invité

Exécution **dans le système invité**. Le système reste en fonctionnement, sans coupure de service.

### Invité Windows

```powershell
.\scripts\windows\Convert-WindowsToUefi.ps1 -DiskNumber 0
```

Le script demande confirmation. En automatisation, ajouter `-Force`. Pour simuler sans écrire : `-WhatIf`.

### Invité Linux

Simulation d'abord, systématiquement :

```bash
sudo ./scripts/linux/convert-linux-to-uefi.sh --disk /dev/sda
```

Puis exécution réelle :

```bash
sudo ./scripts/linux/convert-linux-to-uefi.sh --disk /dev/sda --confirm
```

Le script demande une confirmation interactive (`yes`). En automatisation, ajouter `--yes`.

**Point de contrôle n°2 :** la conversion doit se terminer sans erreur.

- Windows : vérifier `Get-Disk | Select-Object Number, PartitionStyle` → doit afficher `GPT`.
- Linux : vérifier `parted -s /dev/sda print` → doit afficher `Partition Table: gpt`.

> **Ne pas laisser la machine dans cet état intermédiaire.** Le disque est converti mais le firmware ne l'est pas encore. Enchaîner immédiatement sur l'étape 3.

## Étape 3 — Arrêt de la machine virtuelle

Arrêt propre depuis le système invité ou la console de l'hyperviseur.

```powershell
Stop-Computer          # invité Windows
```
```bash
sudo shutdown -h now   # invité Linux
```

Attendre la confirmation d'extinction complète côté hyperviseur avant de poursuivre.

## Étape 4 — Bascule du firmware

**C'est ici que débute l'interruption de service.**

### VMware

```powershell
.\scripts\vmware\Set-VMFirmware.ps1 -VMName "srv-app01" -Firmware efi
```

Le script refuse de s'exécuter si la VM n'est pas éteinte : c'est un comportement attendu, ne pas contourner.

### Hyper-V

Rappel : sous Hyper-V le firmware n'est pas modifiable. Le script crée une **nouvelle VM Génération 2** et conserve la VM d'origine renommée `<nom>-gen1-legacy`.

```powershell
.\scripts\hyperv\Convert-Gen1ToGen2.ps1 -SourceVMName "srv-app01" -OSType Windows
```

Pour un invité Linux :

```powershell
.\scripts\hyperv\Convert-Gen1ToGen2.ps1 -SourceVMName "srv-web01" -OSType Linux
```

Si le noyau Linux n'est pas signé, ajouter `-DisableSecureBoot`.

**Point de contrôle n°3 :**

- VMware : `(Get-VM "srv-app01").ExtensionData.Config.Firmware` → doit renvoyer `efi`.
- Hyper-V : `Get-VM "srv-app01" | Select-Object Name, Generation` → doit renvoyer `2`.

## Étape 5 — Redémarrage et validation

Démarrer la machine virtuelle, puis exécuter **dans l'invité** :

### Invité Windows

```powershell
.\scripts\windows\Test-UefiMigrationResult.ps1
```

### Invité Linux

```bash
sudo ./scripts/linux/verify-uefi-migration.sh
```

**Point de contrôle n°4 — décision go / no-go :**

| Résultat | Décision |
|---|---|
| Migration confirmée (code 0) | Poursuivre à l'étape 6 |
| Migration non confirmée (code 1) | **Retour arrière** (section 7) |

> Ce contrôle est obligatoire. Une machine peut démarrer sur une entrée d'amorçage obsolète et paraître saine tout en étant à un redémarrage de la panne. Le fait que la machine « démarre » ne vaut pas validation.

## Étape 6 — Clôture

1. Réactiver BitLocker le cas échéant :

```powershell
Resume-BitLocker -MountPoint "C:"
```

2. Faire valider le service rendu par le responsable applicatif.
3. **Après période d'observation** (recommandé : 5 à 7 jours ouvrés), supprimer les éléments de secours :

```powershell
# VMware
Get-Snapshot -VM "srv-app01" -Name "pre-uefi-migration" | Remove-Snapshot -Confirm:$false

# Hyper-V : suppression de la VM d'origine conservée
Remove-VM -Name "srv-app01-gen1-legacy" -Force
```

> Cette suppression est une **décision humaine explicite**. Aucun script ne la réalise automatiquement. Ne pas l'exécuter avant validation applicative formelle.

# Procédure hors ligne — Windows Server 2012 R2 et 2016

Ces versions ne disposent pas de l'outil `MBR2GPT.exe`. La conversion s'effectue depuis un environnement d'amorçage externe.

## Prérequis supplémentaires

- Image ISO **WinPE 10.0.15063 ou supérieure** (ADK Windows 10 1703+ ou Windows Server 2019+), accessible depuis l'hyperviseur.
- Accès console à la machine virtuelle.

## Déroulement

1. Réaliser les étapes de préparation (section 4) — instantané inclus, sans exception.
2. Arrêter la machine virtuelle.
3. Monter l'ISO WinPE et configurer l'amorçage sur le lecteur optique.
4. Démarrer sur WinPE et ouvrir l'invite de commandes.
5. Identifier le disque système :

```
diskpart
list disk
list volume
exit
```

6. Valider puis convertir — **sans `/allowFullOS`**, réservé à un système démarré :

```
mbr2gpt /validate /disk:0
mbr2gpt /convert /disk:0
```

7. Arrêter la machine, démonter l'ISO, rétablir l'ordre d'amorçage sur le disque.
8. Reprendre la procédure nominale à l'**étape 4** (bascule du firmware).

## Erreurs fréquentes en mode WinPE

| Message | Cause | Action |
|---|---|---|
| `Disk layout validation failed` | Plus de 3 partitions primaires, ou disque dynamique | Nettoyer les partitions superflues ou convertir le disque en basique |
| `Cannot find OS partition` | Mauvais numéro de disque | Revérifier avec `diskpart` / `list disk` |
| `Not enough free space` | Espace non alloué insuffisant pour l'ESP et la MSR | Réduire une partition existante d'environ 100 Mo |

# Procédures de retour arrière

## Arbre de décision

| Situation | Procédure |
|---|---|
| Firmware basculé, **disque encore en MBR** | Rebasculer le firmware (§ 7.1) |
| Disque converti en GPT, VM ne démarre pas, plateforme VMware | Restaurer l'instantané (§ 7.3) |
| Disque converti en GPT, VM ne démarre pas, plateforme Hyper-V | Restaurer la VM Gen 1 (§ 7.2), puis instantané si insuffisant (§ 7.3) |
| Partition ESP créée à tort, système Linux amorçable | Restaurer la table de partitions (§ 7.4) |
| Toute autre situation | **Restaurer l'instantané** (§ 7.3) |

> **Principe :** l'instantané pris en étape 0 est la seule voie de retour arrière réellement complète. En cas de doute, ne pas chercher à réparer — restaurer.

## 7.1 Rebascule du firmware (VMware)

Applicable **uniquement** si le disque invité n'a pas encore été converti.

```powershell
.\scripts\vmware\Set-VMFirmware.ps1 -VMName "srv-app01" -Firmware bios
```

## 7.2 Restauration de la VM Génération 1 (Hyper-V)

La VM d'origine n'a été ni modifiée ni supprimée : elle a seulement été renommée.

```powershell
.\scripts\hyperv\Restore-Gen1VM.ps1 -VMName "srv-app01" -Start
```

Le script arrête et supprime la VM Génération 2 (les fichiers VHDX sont conservés, simplement détachés), puis restaure le nom d'origine de la VM de secours. Il vérifie l'existence et la génération de la VM de secours **avant** toute suppression : une VM de secours absente interrompt l'opération.

> **Limite :** si le disque invité avait déjà été converti en GPT, la VM Génération 1 (BIOS) ne saura pas non plus démarrer dessus. Enchaîner alors sur § 7.3.

## 7.3 Restauration de l'instantané

### VMware

```powershell
$snap = Get-Snapshot -VM "srv-app01" -Name "pre-uefi-migration"
Set-VM -VM "srv-app01" -Snapshot $snap -Confirm:$false
Start-VM -VM "srv-app01"
```

### Hyper-V

```powershell
Get-VMSnapshot -VMName "srv-app01"
Restore-VMSnapshot -VMName "srv-app01" -Name "<nom du point de contrôle>" -Confirm:$false
Start-VM -Name "srv-app01"
```

## 7.4 Restauration de la table de partitions (Linux)

Le script de conversion sauvegarde deux éléments sous `/root` avant toute écriture :

| Fichier | Contenu |
|---|---|
| `<disque>-partition-table-<horodatage>.backup` | Sauvegarde `sgdisk`, rejouable |
| `<disque>-original-<horodatage>.mbr` | Copie brute du premier secteur — seul exemplaire du MBR d'origine |

Lister puis restaurer :

```bash
sudo ./scripts/linux/restore-partition-table.sh --disk /dev/sda --list
sudo ./scripts/linux/restore-partition-table.sh --disk /dev/sda --confirm
```

> **Ce que cette opération fait et ne fait pas.** Elle supprime les entrées de partition ajoutées après la sauvegarde, typiquement l'ESP. Elle **ne reconvertit pas** le disque en MBR : la sauvegarde `sgdisk` d'un disque MBR enregistre une représentation GPT de la disposition, donc son rejeu produit du GPT. Elle ne défait pas non plus la ligne `/etc/fstab`, l'installation de GRUB-EFI ni la régénération de l'initramfs. **Pour un retour arrière complet, restaurer l'instantané.**

# Diagnostic des incidents

## La machine ne démarre plus (« no bootable device » / écran noir)

Causes par ordre de probabilité décroissante :

| # | Cause | Vérification | Correction |
|---|---|---|---|
| 1 | Disque non réellement converti en GPT | Depuis un live-CD : `parted /dev/sda print` | Reprendre l'étape 2, ou restaurer l'instantané |
| 2 | Partition ESP sans le bon type | `sgdisk -p /dev/sda` → type `EF00` attendu | Corriger le type ou restaurer |
| 3 | Ordre d'amorçage incorrect | VMware : options de démarrage de la VM. Hyper-V : `Get-VMFirmware -VMName <nom> \| Select BootOrder` | Repositionner le disque en premier |
| 4 | Secure Boot activé prématurément | Console firmware de la VM | Désactiver le Secure Boot, valider l'amorçage, puis le réactiver |

## Le script d'audit refuse la machine

| Message | Signification | Action |
|---|---|---|
| `mbr2gpt.exe not present on this OS` | Server 2012 R2 ou 2016 | Basculer sur la procédure hors ligne (section 6) |
| OS `past end of support` | Server 2008 R2 ou antérieur, RHEL 5/6 | **Ne pas convertir.** Escalader vers l'architecte |
| `partitions detected, MBR2GPT allows at most 3` | Trop de partitions primaires | Nettoyer les partitions superflues |
| `Not enough free space to create an ESP` | Espace non alloué insuffisant (Linux) | Réduire une partition existante |

## Incidents Linux spécifiques

| Symptôme | Cause | Correction |
|---|---|---|
| `/boot/efi is not a mountpoint` | ESP non montée avant `grub-install` | Vérifier `mount \| grep efi` et `/etc/fstab` |
| GRUB s'affiche mais le noyau ne démarre pas | initramfs incomplet | `update-initramfs -u -k all` ou `dracut -f --regenerate-all` |
| Aucune entrée dans `efibootmgr` | Firmware émulé ignorant les écritures NVRAM | Recréer l'entrée manuellement et contrôler l'ordre d'amorçage côté hyperviseur |

Recréation manuelle d'une entrée d'amorçage :

```bash
efibootmgr -c -d /dev/sda -p 1 -L "GRUB" -l '\EFI\<distribution>\grubx64.efi'
```

## Critères d'escalade

Escalader vers le niveau supérieur ou l'architecte dans les cas suivants :

- Machine non démarrable après restauration de l'instantané.
- Topologie non prévue découverte en cours d'intervention (RAID logiciel, LVM sur `/boot`, chiffrement de volume).
- Système d'exploitation classé **INTERDIT** dans la matrice d'éligibilité.
- Doute sur l'intégrité des données après conversion.

# Fiche de suivi d'intervention

À compléter pour chaque machine traitée et à archiver comme preuve d'exécution.

| Rubrique | Valeur |
|---|---|
| Nom de la machine virtuelle | |
| Hyperviseur (VMware / Hyper-V) | |
| Système invité et version | |
| Verdict d'éligibilité | |
| Procédure appliquée (nominale / hors ligne) | |
| Date et heure de début | |
| Intervenant | |
| Numéro de changement (ITSM) | |

## Points de contrôle

| Point de contrôle | Résultat | Heure | Visa |
|---|---|---|---|
| PC1 — Audit d'éligibilité | ☐ OK ☐ KO | | |
| Instantané créé (nom) | | | |
| PC2 — Conversion du disque | ☐ OK ☐ KO | | |
| PC3 — Bascule du firmware | ☐ OK ☐ KO | | |
| PC4 — Validation post-migration | ☐ OK ☐ KO | | |
| Validation applicative | ☐ OK ☐ KO | | |

## Clôture

| Rubrique | Valeur |
|---|---|
| Date et heure de fin | |
| Durée d'interruption réelle | |
| Retour arrière effectué | ☐ Non ☐ Oui — motif : |
| Instantané supprimé le | |
| VM de secours supprimée le (Hyper-V) | |
| Observations | |

# Annexe — Aide-mémoire des commandes

## Audit (sans impact, exécutable à tout moment)

```powershell
.\scripts\vmware\Get-VMFirmwareReport.ps1 -VMName "*"       # parc VMware
.\scripts\hyperv\Get-VMGenerationReport.ps1                 # parc Hyper-V
.\scripts\windows\Test-UefiReadiness.ps1                    # invité Windows
```
```bash
sudo ./scripts/linux/check-uefi-readiness.sh                # invité Linux
```

## Vérifications manuelles rapides

### Invité Windows

```powershell
$env:firmware_type                                  # doit renvoyer UEFI
Get-Disk | Select-Object Number, PartitionStyle     # doit renvoyer GPT
Confirm-SecureBootUEFI                              # état du Secure Boot
bcdedit /enum "{bootmgr}"                           # doit citer bootmgfw.efi
```

### Invité Linux

```bash
[ -d /sys/firmware/efi ] && echo "UEFI" || echo "BIOS"
parted -s /dev/sda print | grep -i "Partition Table"
findmnt /boot/efi
efibootmgr -v
```

### Hyperviseur

```powershell
(Get-VM "srv-app01").ExtensionData.Config.Firmware              # VMware
Get-VM "srv-app01" | Select-Object Name, Generation, State      # Hyper-V
```

## Options communes aux scripts

| Option | Effet |
|---|---|
| `-WhatIf` | Simulation PowerShell, aucune écriture |
| `-Force` | Supprime la demande de confirmation (automatisation) |
| `--confirm` | Active l'exécution réelle des scripts Bash (sinon simulation) |
| `--yes` | Supprime la confirmation interactive Bash (automatisation) |
| `--list` | Liste les sauvegardes disponibles (restauration Linux) |

> Par défaut, les scripts Bash fonctionnent en **simulation**. L'absence de `--confirm` n'est pas une erreur : c'est le comportement attendu pour une première exécution.
