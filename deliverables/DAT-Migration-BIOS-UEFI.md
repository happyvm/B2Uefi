---
title: "Dossier d'Architecture Technique"
subtitle: "Migration BIOS vers UEFI — Environnements VMware et Hyper-V"
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
| Titre | Dossier d'Architecture Technique — Migration BIOS vers UEFI |
| Référence | DAT-B2UEFI-001 |
| Version | 1.0 |
| Statut | À valider |
| Classification | Interne |
| Périmètre | Machines virtuelles VMware (ESXi/vSphere) et Hyper-V, invités Windows et Linux |
| Rédacteur | *(à compléter)* |
| Valideur technique | *(à compléter)* |
| Approbateur | *(à compléter)* |

## Historique des révisions

| Version | Date | Auteur | Nature de la modification |
|---|---|---|---|
| 1.0 | *(à compléter)* | *(à compléter)* | Création initiale |

## Documents de référence

| Réf. | Document |
|---|---|
| R1 | Microsoft Learn — MBR2GPT.exe |
| R2 | Microsoft Learn — Generation 1 ou 2 sous Hyper-V |
| R3 | Microsoft Learn — Systèmes invités Windows supportés par Hyper-V |
| R4 | Red Hat Customer Portal — Cycle de vie Red Hat Enterprise Linux |
| R5 | Red Hat Customer Portal — UEFI Secure Boot dans RHEL 7 |
| R6 | Broadcom/VMware — Changement du firmware de démarrage d'une machine virtuelle |

# Objet et périmètre

## Objet

Ce document décrit l'architecture technique retenue pour migrer le mode de démarrage des machines virtuelles du parc, du **BIOS hérité (legacy)** vers **UEFI**, sur les hyperviseurs VMware et Hyper-V, pour des systèmes invités Windows et Linux.

Il définit l'architecture cible, les composants d'automatisation livrés, les contraintes de compatibilité par système d'exploitation, ainsi que les risques identifiés et les mesures associées.

## Périmètre inclus

- Machines virtuelles hébergées sur VMware ESXi/vSphere et Microsoft Hyper-V.
- Systèmes invités Windows Server et Red Hat Enterprise Linux (et rebuilds compatibles : CentOS, AlmaLinux, Rocky Linux).
- Architecture x86_64 exclusivement.
- Machines disposant d'un **disque système unique** avec partitionnement classique.
- Conversion de la table de partitions MBR vers GPT et reconfiguration du chargeur d'amorçage.
- Bascule du firmware de la machine virtuelle côté hyperviseur.

## Périmètre exclu

Les configurations suivantes sont explicitement hors périmètre. Elles nécessitent une étude et une validation manuelles spécifiques :

- Architectures 32 bits (l'UEFI 32 bits existe mais n'est pas traité).
- Disques système en RAID logiciel.
- Volumes `/boot` sur LVM ou chiffrés (LUKS), et disques dynamiques Windows.
- Configurations multi-amorçage.
- Machines physiques (bare metal).
- Systèmes d'exploitation hors support éditeur, pour lesquels la reconstruction est préconisée plutôt que la conversion.

# Contexte et enjeux

## Justification de la migration

| Enjeu | Description |
|---|---|
| **Sécurité** | Le Secure Boot exige UEFI. Il est prérequis pour Windows 11 et recommandé pour le durcissement des serveurs Linux. Les fonctions Credential Guard, VBS et BitLocker adossé au TPM en dépendent également. |
| **Conformité éditeur** | Microsoft et les distributions Linux orientent les nouvelles fonctions d'amorçage (measured boot, TPM, shielded VMs) vers UEFI exclusivement. |
| **Levée de limites techniques** | Le partitionnement MBR plafonne à 2 To et 4 partitions primaires. Le GPT, utilisé par UEFI, supprime ces limites. |
| **Prérequis de montée de version** | Windows Server 2022 et Windows 11 supposent UEFI + Secure Boot pour bénéficier de l'ensemble des fonctions de sécurité. |

## Fenêtre de contrainte

Deux échéances de support conditionnent le calendrier :

- **Windows Server 2012 / 2012 R2** : programme ESU arrivant à échéance en **octobre 2026**.
- **Windows Server 2016** : fin de support étendu en **janvier 2027**.

Ces deux versions représentent le volume principal des machines encore en BIOS et relèvent d'une procédure de conversion dégradée (voir section « Contrainte majeure : Server 2012 R2 et 2016 »).

# Architecture cible

## Principe fondateur : deux couches indépendantes

Une migration BIOS vers UEFI ne constitue pas une opération unique. Elle agit sur **deux couches techniques indépendantes**, qui doivent impérativement être modifiées dans un ordre déterminé.

| Couche | Objet de la modification | Effectuée par |
|---|---|---|
| **Couche invité** (guest OS) | Conversion de la table de partitions du disque système de MBR vers GPT, et installation d'un chargeur d'amorçage capable de démarrer en UEFI (`bootmgfw.efi` sous Windows, `grubx64.efi` sous Linux). | Scripts exécutés dans le système invité |
| **Couche hyperviseur** | Présentation d'un firmware UEFI à la machine virtuelle, en remplacement du BIOS émulé. | Scripts exécutés depuis l'administration de l'hyperviseur |

## Asymétrie critique

Les deux couches sont liées, mais leur inversion produit dans les deux cas une machine non démarrable :

| Séquence erronée | Conséquence |
|---|---|
| Disque converti en GPT, firmware laissé en BIOS | Le BIOS hérité ne sait pas amorcer un disque GPT porteur d'une partition système EFI. **La VM ne démarre plus.** |
| Firmware basculé en UEFI, disque laissé en MBR | Le firmware UEFI recherche une partition FAT32 (ESP) contenant un chargeur `.efi`, absente d'un disque MBR. **La VM ne démarre plus.** |

## Séquence nominale

```
Étape 0 : Prise d'un instantané restaurable (snapshot / checkpoint)
Étape 1 : Vérification d'éligibilité du système invité
Étape 2 : Conversion du disque invité (MBR -> GPT + chargeur UEFI)
          [le système tourne encore en mode BIOS]
Étape 3 : Arrêt propre de la machine virtuelle
Étape 4 : Bascule du firmware côté hyperviseur
Étape 5 : Redémarrage
Étape 6 : Validation depuis l'intérieur du système invité
Étape 7 : Retour arrière si la validation échoue
```

Les étapes 0 et 6 ne sont pas facultatives :

- **L'étape 0 constitue l'unique voie de retour arrière réelle** une fois le disque converti. Il n'existe pas de conversion automatisée et sûre de GPT vers MBR pour un disque système ayant déjà démarré en UEFI.
- **L'étape 6 distingue « la machine a démarré » de « la machine a démarré comme prévu »**. Une machine virtuelle peut s'amorcer sur une entrée de démarrage obsolète et paraître saine tout en étant à un redémarrage de la panne.

# Différence structurelle entre les deux hyperviseurs

Le point d'architecture le plus déterminant du projet est que **les deux hyperviseurs ne se comportent pas de la même manière**, ce qui impose deux chemins de migration distincts.

| Critère | VMware (ESXi / vSphere) | Hyper-V |
|---|---|---|
| Bascule BIOS vers EFI sur une VM existante | **Oui.** Le firmware est un paramètre de configuration modifiable machine éteinte. | **Non.** Le firmware est déterminé par la *génération* de la VM (Gen 1 = BIOS, Gen 2 = UEFI), figée à la création. |
| Méthode | Reconfiguration de la VM existante (API `ReconfigVM`). | Création d'une **nouvelle VM Génération 2**, rattachement du disque converti, réplication de la configuration. |
| Conservation de l'identité de la VM | Oui (même objet, même UUID). | Non. Nouvel objet VM ; la VM d'origine est conservée renommée. |
| Impact sur les sauvegardes / supervision | Faible. | À anticiper : la nouvelle VM peut être perçue comme un nouvel objet par les outils tiers. |

## Conséquences d'exploitation

Le chemin Hyper-V comporte des contraintes supplémentaires à intégrer au chiffrage :

- Le disque doit être au format **VHDX** ; les disques VHD nécessitent une conversion préalable (`Convert-VHD`).
- Les cartes réseau « Legacy Network Adapter » (spécifiques Gen 1) n'ont pas d'équivalent en Gen 2 et sont remplacées par des cartes synthétiques ; **l'adresse MAC statique éventuelle doit être contrôlée**.
- La VM d'origine est conservée (renommée avec le suffixe `-gen1-legacy`) et n'est **jamais supprimée automatiquement**. Sa suppression relève d'une décision humaine explicite après validation.

# Matrice de compatibilité des systèmes invités

Légende des verdicts :

| Symbole | Signification |
|---|---|
| **OK** | Conversion en place supportée par les composants livrés |
| **HORS LIGNE** | Conversion possible, mais nécessitant un amorçage sur média externe |
| **REFUS** | Aucune voie supportée — reconstruction préconisée |

## Windows Server

| Version | Build | Boot UEFI | Secure Boot | `MBR2GPT` natif | Invité Hyper-V Gen 2 | Fin de support | Verdict |
|---|---|---|---|---|---|---|---|
| 2003 / 2003 R2 | 5.2 | Non | Non | Non | Non | Juillet 2015 | **REFUS** |
| 2008 / 2008 R2 | 6.0 / 6.1 | Oui (x64) | Non | Non | **Non supporté** | Janvier 2020 | **REFUS** |
| 2012 / 2012 R2 | 9200 / 9600 | Oui | Oui | **Non** | Oui | ESU : octobre 2026 | **HORS LIGNE** |
| 2016 | 14393 | Oui | Oui | **Non** | Oui | Janvier 2027 | **HORS LIGNE** |
| 2019 | 17763 | Oui | Oui | Oui | Oui | Janvier 2029 | **OK** |
| 2022 | 20348 | Oui | Oui | Oui | Oui | Octobre 2031 | **OK** |
| 2025 | 26100 | Oui | Oui | Oui | Oui | Novembre 2034 | **OK** |

## Contrainte majeure : Server 2012 R2 et 2016

L'outil `MBR2GPT.exe` a été livré avec **Windows 10 version 1703 (build 15063)**.

Windows Server 2016 repose sur le socle de code de Windows 10 version 1607 (**build 14393**) et **ne contient pas cet outil**. Windows Server 2012 R2 (build 9600) non plus. L'hypothèse courante selon laquelle « Server 2016 dispose de MBR2GPT » est **erronée** et constitue le principal facteur de dérive de planning identifié.

Pour ces deux versions, la conversion reste réalisable, mais uniquement hors ligne :

1. Amorçage de la machine virtuelle sur un média **WinPE 10.0.15063 ou supérieur** (ADK Windows 10 1703+ ou Server 2019+).
2. Exécution de `mbr2gpt /validate /disk:0` puis `mbr2gpt /convert /disk:0`, **sans le commutateur `/allowFullOS`** qui est réservé à un système démarré.
3. Arrêt, bascule du firmware, redémarrage.

> **Point de vigilance :** la copie du binaire `mbr2gpt.exe` depuis un Windows plus récent vers un système ancien n'est pas supportée par l'éditeur et est proscrite — l'exécutable dépend de la pile de servicing du système avec lequel il est livré.

## Red Hat Enterprise Linux

Applicable également aux rebuilds compatibles de chaque génération (CentOS, AlmaLinux, Rocky Linux).

| Version | Boot UEFI | Secure Boot | Invité Hyper-V Gen 2 | Support | Verdict |
|---|---|---|---|---|---|
| RHEL 5 | Non viable sur x86_64 | Non | Non | Fin de vie novembre 2020 | **REFUS** |
| RHEL 6 | Présent mais non fiable | Non | Non (Gen 2 exige 7.0+) | ELS terminé juin 2024 | **REFUS** |
| RHEL 7 | Oui | Oui (premier RHEL avec Secure Boot) | Oui (7.0+) | Fin de vie juin 2024, ELS disponible | **OK, mais OS en fin de vie** |
| RHEL 8 | Oui | Oui | Oui | Maintenance jusqu'à mai 2029 | **OK** |
| RHEL 9 | Oui | Oui | Oui | Maintenance jusqu'à mai 2032 | **OK** |
| RHEL 10 | Oui | Oui | Oui | Publié mai 2025, maintenance ~mai 2035 | **OK** |

### Justification du refus de RHEL 6

RHEL 6 fournit `efibootmgr` et son installeur sait opérer en mode UEFI : sur le papier, la version est éligible. En pratique, le chemin GPT/UEFI de RHEL 6 présente des défauts connus — notamment l'incapacité d'`efibootmgr` à créer une entrée de démarrage lorsque les variables dépassent 1024 octets — et plusieurs produits Red Hat bâtis sur RHEL 6 ont été livrés en amorçage hérité uniquement. Combiné au dépassement de la phase de vie étendue, l'effort de conversion porterait sur un système devant de toute façon être remplacé.

### Cas particulier de RHEL 7

RHEL 7 est techniquement convertible mais hors support complet depuis juin 2024. Convertir ce parc revient à obtenir un amorçage UEFI sur un système qu'il faudra remplacer. **Préconisation : intégrer la bascule UEFI à la montée de version vers RHEL 8 ou 9 plutôt que de réaliser l'opération deux fois.**

# Sécurité

## Secure Boot

Le Secure Boot est une fonction distincte de l'UEFI, activable **après** validation d'un amorçage UEFI simple. Son activation prématurée est une cause fréquente de machine convertie correctement mais refusant de démarrer.

| Plateforme | Prérequis |
|---|---|
| VMware | Version matérielle de la VM ≥ 13, et chargeur/noyau signés côté invité. |
| Hyper-V — invité Windows | Modèle `MicrosoftWindows`. |
| Hyper-V — invité Linux | Modèle **`MicrosoftUEFICertificateAuthority`**, et non `MicrosoftWindows`. |

Sous Linux, le Secure Boot exige un shim signé (`shim-x64`), fourni par la distribution à partir de RHEL 7. Un noyau non signé impose la désactivation du Secure Boot.

## Point d'attention calendaire

Plusieurs certificats de signature Secure Boot arrivent à expiration au cours de **2026**, ce qui affecte la manière dont les shims sont signés et reconnus. Si le projet est motivé principalement par l'activation du Secure Boot, il convient de vérifier les préconisations en vigueur de Red Hat et Microsoft sur ce renouvellement de certificats avant d'arrêter le calendrier.

## TPM virtuel

Les fonctions Windows 11, Credential Guard et VBS requièrent, au-delà de l'UEFI, un TPM 2.0 exposé par l'hyperviseur. Cette activation est une opération distincte, à réaliser après validation de l'amorçage UEFI.

# Composants livrés

L'automatisation est constituée de scripts PowerShell (Windows, VMware, Hyper-V) et Bash (Linux), classés en trois natures selon leur impact.

## Classification des composants

| Nature | Comportement imposé |
|---|---|
| **Lecture seule** | Ne modifie rien. Ne propose pas d'option de forçage. |
| **Additif** | Crée un instantané. Ne doit jamais être bloqué par une demande de confirmation. |
| **Destructif** | Réécrit une table de partitions ou reconfigure/supprime une VM. Demande confirmation par défaut, avec option de forçage pour l'automatisation. |

## Inventaire

| Composant | Plateforme | Nature | Rôle |
|---|---|---|---|
| `Test-UefiReadiness.ps1` | Windows invité | Lecture seule | Audit d'éligibilité : build, TPM, BitLocker, validation MBR2GPT |
| `Convert-WindowsToUefi.ps1` | Windows invité | Destructif | Conversion MBR vers GPT (encapsulation de MBR2GPT) |
| `Test-UefiMigrationResult.ps1` | Windows invité | Lecture seule | Validation post-migration depuis l'invité |
| `check-uefi-readiness.sh` | Linux invité | Lecture seule | Audit d'éligibilité : table de partitions, espace libre, paquets |
| `convert-linux-to-uefi.sh` | Linux invité | Destructif | Conversion MBR vers GPT, création ESP, installation GRUB-EFI |
| `verify-uefi-migration.sh` | Linux invité | Lecture seule | Validation post-migration depuis l'invité |
| `restore-partition-table.sh` | Linux invité | Destructif | Restauration d'une table de partitions sauvegardée |
| `Get-VMFirmwareReport.ps1` | VMware | Lecture seule | Audit du firmware du parc |
| `New-PreMigrationSnapshot.ps1` | VMware | Additif | Instantané de sécurité avant migration |
| `Set-VMFirmware.ps1` | VMware | Destructif | Bascule BIOS / EFI sur VM existante |
| `Get-VMGenerationReport.ps1` | Hyper-V | Lecture seule | Audit des générations du parc |
| `New-PreMigrationCheckpoint.ps1` | Hyper-V | Additif | Point de contrôle de sécurité avant migration |
| `Convert-Gen1ToGen2.ps1` | Hyper-V | Destructif | Migration Génération 1 vers Génération 2 |
| `Restore-Gen1VM.ps1` | Hyper-V | Destructif | Retour arrière vers la VM Génération 1 conservée |

## Principes de conception retenus

1. **Aucun composant ne supprime le recours de l'exploitant.** La migration Hyper-V renomme la VM source au lieu de la supprimer ; le script de retour arrière vérifie l'existence et la génération de la VM de secours **avant** toute suppression, de sorte qu'une VM de secours absente interrompt l'opération plutôt que de laisser l'exploitant sans aucune des deux machines.
2. **Simulation par défaut sur les opérations destructives.** Les scripts Bash exigent `--confirm` explicite ; les scripts PowerShell exposent `-WhatIf`.
3. **Aucune promesse excédant la capacité réelle.** La restauration de table de partitions documente explicitement qu'elle **ne reconvertit pas** un disque en MBR, cette opération étant techniquement impossible depuis la sauvegarde produite.
4. **Le nettoyage final est une décision humaine.** Aucune suppression automatique de VM, de disque ou d'instantané.

## Contrôle qualité

Une chaîne d'intégration continue exécute à chaque modification : analyse statique Bash (ShellCheck), analyse statique PowerShell (PSScriptAnalyzer), contrôle syntaxique, et une suite de tests vérifiant que les règles de sûreté ci-dessus sont effectivement respectées par chaque composant. Tout nouveau composant doit être déclaré dans le référentiel de classification, faute de quoi la chaîne échoue.

# Prérequis techniques

## Environnement VMware

- Version matérielle de VM ≥ 13 pour le Secure Boot.
- Droit vSphere `VirtualMachine.Config.Settings` sur les VM concernées.
- Module PowerCLI installé sur le poste d'administration.
- Machine virtuelle **éteinte** pour la bascule du firmware.

## Environnement Hyper-V

- Hôte Hyper-V sous Windows Server 2012 R2 ou supérieur.
- Module PowerShell Hyper-V disponible.
- Espace disque suffisant pour la coexistence temporaire des deux VM.
- Disques au format VHDX.

## Systèmes invités

| Invité | Prérequis |
|---|---|
| Windows | Compte administrateur local ; BitLocker suspendu le cas échéant ; au plus 3 partitions primaires ; espace non alloué disponible (~100 Mo) |
| Linux | Accès root ; espace libre pour la partition ESP (512 Mo recommandés) ; dépôts accessibles pour l'installation des paquets `gdisk`, `grub-efi`, `efibootmgr`, `dosfstools` |

# Analyse des risques

| # | Risque | Probabilité | Impact | Mesure de maîtrise |
|---|---|---|---|---|
| R1 | Machine non démarrable après bascule (ordre des opérations inversé) | Moyenne | Critique | Séquence imposée par la documentation ; scripts de validation à chaque étape ; instantané préalable obligatoire |
| R2 | Absence de `MBR2GPT` sur Server 2012 R2 / 2016 découverte en cours d'intervention | **Élevée** | Majeur | Matrice de compatibilité communiquée en amont ; le script d'audit identifie le cas et indique la voie WinPE |
| R3 | Secure Boot activé avant validation de l'amorçage UEFI | Moyenne | Majeur | Activation en étape distincte, postérieure à la validation ; modèle de certificat adapté à l'OS invité |
| R4 | Perte du recours en cas d'échec (instantané absent) | Faible | Critique | Scripts d'instantané dédiés ; étape 0 non facultative dans la procédure |
| R5 | VM Hyper-V Gen 2 non reconnue par les outils de sauvegarde | Moyenne | Modéré | Recensement des outils tiers avant campagne ; VM d'origine conservée jusqu'à validation complète |
| R6 | Perte de l'adressage MAC statique (Hyper-V, carte Legacy) | Moyenne | Modéré | Contrôle post-migration de l'adressage ; relevé préalable de la configuration réseau |
| R7 | Conversion tentée sur un OS hors support | Moyenne | Majeur | Matrice de compatibilité ; verdict **REFUS** explicite ; script d'audit bloquant |
| R8 | Saturation du stockage par les instantanés durant une campagne | Moyenne | Modéré | Suppression des instantanés après validation ; les scripts signalent les instantanés déjà présents |

# Trajectoire de déploiement

## Segmentation du parc

Le parc doit être segmenté en trois lots traités différemment :

| Lot | Contenu | Traitement |
|---|---|---|
| **Lot 1 — Conversion standard** | Server 2019 / 2022 / 2025, RHEL 8 / 9 / 10 | Procédure nominale complète |
| **Lot 2 — Conversion hors ligne** | Server 2012 R2, Server 2016 | Procédure nominale, étape de conversion sur média WinPE ; immobilisation plus longue |
| **Lot 3 — Reconstruction** | Server 2003 / 2008 / 2008 R2, RHEL 5 / 6 | Hors périmètre de conversion. Reconstruction sur système courant et migration applicative |

RHEL 7 constitue un cas intermédiaire : techniquement éligible au lot 1, mais dont la préconisation est le rattachement au projet de montée de version.

## Séquencement recommandé

1. **Inventaire** : exécution des scripts d'audit en lecture seule sur l'ensemble du parc, sans impact de production.
2. **Segmentation** : répartition dans les trois lots ci-dessus.
3. **Pilote** : traitement d'un échantillon représentatif non critique de chaque lot, incluant **la validation de la procédure de retour arrière** et non uniquement du chemin nominal.
4. **Déploiement par vagues** : traitement par lots homogènes, avec point d'arrêt (go / no-go) après chaque vague.
5. **Clôture** : suppression des instantanés et des VM de secours après période d'observation.

# Limites connues et engagements

## Ce que la solution garantit

- La conversion en place du disque système, sans perte de données, pour les systèmes classés **OK** dans la matrice.
- La conservation systématique d'un moyen de retour arrière tant que l'exploitant n'a pas explicitement procédé au nettoyage.
- La détection en amont des cas non éligibles, avant toute écriture sur disque.

## Ce que la solution ne garantit pas

- **Aucune reconversion automatisée de GPT vers MBR.** Une fois le disque converti, le retour arrière réel passe exclusivement par la restauration de l'instantané.
- **Aucune prise en charge des topologies complexes** listées en périmètre exclu.
- **Aucune validation applicative.** Les scripts valident l'amorçage et la configuration système ; la validation du service rendu par la machine relève de l'exploitant applicatif.
- Les dates de fin de support mentionnées sont susceptibles d'évolution et doivent être revérifiées auprès des éditeurs avant tout engagement calendaire.

# Glossaire

| Terme | Définition |
|---|---|
| **BIOS** | Basic Input/Output System. Firmware d'amorçage historique, en voie de retrait. |
| **UEFI** | Unified Extensible Firmware Interface. Firmware d'amorçage moderne, remplaçant du BIOS. |
| **MBR** | Master Boot Record. Schéma de partitionnement hérité, limité à 2 To et 4 partitions primaires. |
| **GPT** | GUID Partition Table. Schéma de partitionnement associé à l'UEFI, sans ces limites. |
| **ESP** | EFI System Partition. Partition FAT32 contenant les chargeurs d'amorçage `.efi`. |
| **Secure Boot** | Mécanisme UEFI de vérification de signature du chargeur et du noyau au démarrage. |
| **Génération (Hyper-V)** | Attribut figé d'une VM Hyper-V déterminant son firmware : Gen 1 = BIOS, Gen 2 = UEFI. |
| **shim** | Chargeur signé intermédiaire permettant l'amorçage Linux sous Secure Boot. |
| **WinPE** | Windows Preinstallation Environment. Environnement d'amorçage minimal utilisé pour les opérations hors ligne. |
| **TPM** | Trusted Platform Module. Composant de stockage sécurisé de clés, requis par certaines fonctions de sécurité. |
| **ESU** | Extended Security Updates. Programme payant de correctifs de sécurité au-delà du support étendu. |
