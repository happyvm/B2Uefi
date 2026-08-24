---
title: "Technical Architecture Document"
subtitle: "BIOS to UEFI Migration — VMware and Hyper-V Environments"
author: "Infrastructure Department"
date: "Version 1.0"
lang: en
toc: true
toc-title: "Table of Contents"
toc-depth: 3
numbersections: true
---

# Document control

| Item | Value |
|---|---|
| Title | Technical Architecture Document — BIOS to UEFI Migration |
| Reference | TAD-B2UEFI-001 |
| Version | 1.0 |
| Status | Pending approval |
| Classification | Internal |
| Scope | VMware (ESXi/vSphere) and Hyper-V virtual machines, Windows and Linux guests |
| Author | *(to be completed)* |
| Technical reviewer | *(to be completed)* |
| Approver | *(to be completed)* |

## Revision history

| Version | Date | Author | Nature of change |
|---|---|---|---|
| 1.0 | *(to be completed)* | *(to be completed)* | Initial release |

## Reference documents

| Ref. | Document |
|---|---|
| R1 | Microsoft Learn — MBR2GPT.exe |
| R2 | Microsoft Learn — Should I create a generation 1 or 2 virtual machine in Hyper-V? |
| R3 | Microsoft Learn — Supported Windows guest operating systems for Hyper-V |
| R4 | Red Hat Customer Portal — Red Hat Enterprise Linux Life Cycle |
| R5 | Red Hat Customer Portal — UEFI Secure Boot in Red Hat Enterprise Linux 7 |
| R6 | Broadcom/VMware — Switching virtual machine boot firmware |
| R7 | Microsoft Learn — Credential Guard overview and requirements |
| R8 | Microsoft Learn — What is Secured-core server for Windows Server |
| R9 | Microsoft Learn — Hyper-V Generation 2 virtual machine security features |

# Purpose and scope

## Purpose

This document describes the technical architecture adopted to migrate the boot mode of the virtual machine estate from **legacy BIOS** to **UEFI**, across VMware and Hyper-V hypervisors, for Windows and Linux guest operating systems.

It defines the target architecture, the automation components delivered, the per-operating-system compatibility constraints, and the identified risks together with their mitigations.

## In scope

- Virtual machines hosted on VMware ESXi/vSphere and Microsoft Hyper-V.
- Windows Server and Red Hat Enterprise Linux guests (and the compatible rebuilds: CentOS, AlmaLinux, Rocky Linux).
- x86_64 architecture exclusively.
- Machines with a **single system disk** using standard partitioning.
- Conversion of the partition table from MBR to GPT, and reconfiguration of the boot loader.
- Switching the virtual machine firmware on the hypervisor side.

## Out of scope

The following configurations are explicitly excluded. They require dedicated study and manual validation:

- 32-bit architectures (32-bit UEFI exists but is not addressed).
- System disks on software RAID.
- `/boot` volumes on LVM or encrypted (LUKS), and Windows dynamic disks.
- Multi-boot configurations.
- Physical machines (bare metal).
- Operating systems out of vendor support, for which rebuilding is recommended over conversion.

# Context and drivers

## Justification for the migration

| Driver | Description |
|---|---|
| **Security** | Secure Boot requires UEFI. It is a prerequisite for Windows 11 and is recommended for hardening Linux servers. Credential Guard, VBS and TPM-backed BitLocker also depend on it. |
| **Vendor alignment** | Microsoft and the Linux distributions are directing new boot-related features (measured boot, TPM, shielded VMs) exclusively toward UEFI. |
| **Removal of technical limits** | MBR partitioning is capped at 2 TB and four primary partitions. GPT, used by UEFI, removes both limits. |
| **Upgrade prerequisite** | Windows Server 2022 and Windows 11 assume UEFI + Secure Boot in order to expose their full security feature set. |

## Timing constraint

Two support deadlines govern the schedule:

- **Windows Server 2012 / 2012 R2**: ESU program ending **October 2026**.
- **Windows Server 2016**: extended support ending **January 2027**.

These two versions represent the bulk of the machines still running in BIOS mode, and they fall under a degraded conversion procedure (see "Major constraint: Server 2012 R2 and 2016").

# Target architecture

## Founding principle: two independent layers

A BIOS to UEFI migration is not a single operation. It acts on **two independent technical layers**, which must be modified in a specific order.

| Layer | What is modified | Performed by |
|---|---|---|
| **Guest layer** (guest OS) | Conversion of the system disk partition table from MBR to GPT, and installation of a boot loader capable of starting in UEFI mode (`bootmgfw.efi` on Windows, `grubx64.efi` on Linux). | Scripts executed inside the guest operating system |
| **Hypervisor layer** | Presenting a UEFI firmware to the virtual machine in place of the emulated BIOS. | Scripts executed from the hypervisor management plane |

## Critical asymmetry

The two layers are related, but inverting them produces an unbootable machine in both directions:

| Incorrect sequence | Consequence |
|---|---|
| Disk converted to GPT, firmware left on BIOS | Legacy BIOS cannot boot a GPT disk carrying an EFI system partition. **The VM no longer starts.** |
| Firmware switched to UEFI, disk left on MBR | UEFI firmware looks for a FAT32 partition (ESP) containing an `.efi` loader, which does not exist on an MBR disk. **The VM no longer starts.** |

## Nominal sequence

```
Step 0 : Take a restorable snapshot / checkpoint
Step 1 : Verify guest operating system eligibility
Step 2 : Convert the guest disk (MBR -> GPT + UEFI boot loader)
         [the system is still running in BIOS mode]
Step 3 : Cleanly shut down the virtual machine
Step 4 : Switch the firmware on the hypervisor side
Step 5 : Reboot
Step 6 : Validate from inside the guest operating system
Step 7 : Roll back if validation fails
```

Steps 0 and 6 are not optional:

- **Step 0 is the only genuine rollback path** once the disk has been converted. There is no safe, automated GPT to MBR conversion for a system disk that has already booted in UEFI mode.
- **Step 6 distinguishes "the machine booted" from "the machine booted as intended"**. A virtual machine can start from a stale boot entry and appear healthy while still being one reboot away from failing.

# Structural difference between the two hypervisors

The single most consequential architectural point of the project is that **the two hypervisors do not behave in the same way**, which imposes two distinct migration paths.

| Criterion | VMware (ESXi / vSphere) | Hyper-V |
|---|---|---|
| Switching BIOS to EFI on an existing VM | **Yes.** Firmware is a configuration parameter, changeable while the machine is powered off. | **No.** Firmware is determined by the VM *generation* (Gen 1 = BIOS, Gen 2 = UEFI), fixed at creation time. |
| Method | Reconfiguration of the existing VM (`ReconfigVM` API). | Creation of a **new Generation 2 VM**, attachment of the converted disk, replication of the configuration. |
| VM identity preserved | Yes (same object, same UUID). | No. A new VM object; the original VM is retained under a new name. |
| Impact on backup / monitoring | Low. | Must be anticipated: the new VM may be seen as a new object by third-party tooling. |

## Operational consequences

The Hyper-V path carries additional constraints that must be factored into the estimate:

- The disk must be in **VHDX** format; VHD disks require prior conversion (`Convert-VHD`).
- "Legacy Network Adapter" cards (Gen 1 only) have no Gen 2 equivalent and are replaced by synthetic adapters; **any static MAC address must be verified afterwards**.
- The original VM is retained (renamed with the `-gen1-legacy` suffix) and is **never deleted automatically**. Its removal is an explicit human decision taken after validation.

## Management capabilities gained on the hypervisor side

Beyond the guest security features, the migration changes what can be done with the virtual machine itself. **These gains are strongly asymmetric between the two platforms, and the difference must not be flattened when building the business case.**

Hyper-V Generation 1 virtual machines are constrained by emulated legacy hardware: the boot disk sits on an IDE controller, PXE requires a slow emulated adapter, and network adapters cannot be added while running. Moving to Generation 2 removes all of that. On VMware, by contrast, a BIOS virtual machine already boots from a paravirtual SCSI controller, already hot-adds network adapters and already resizes disks online — so switching to EFI changes very little in day-to-day operation and is essentially about unlocking capabilities that BIOS cannot address at all.

### Hyper-V: Generation 1 to Generation 2

| Management capability | Generation 1 (BIOS) | Generation 2 (UEFI) |
|---|---|---|
| Boot device | IDE controller only | **SCSI controller** (virtual disk or DVD), up to 4 controllers and 64 drives each |
| Resizing the system volume | Offline only (boot disk on IDE) | **Online, while the VM is running** (VHDX on SCSI) |
| Adding / removing a network adapter | VM shutdown required | **Hot-add and hot-remove supported** |
| PXE / network deployment | Requires the emulated "Legacy Network Adapter" | **Standard synthetic adapter**, no legacy component |
| System volume above 2 TB | Not addressable under MBR | **Supported** (GPT) |
| Emulated device layer | Present (IDE, legacy NIC, legacy BIOS) | **Removed** — faster boot and installation, smaller attack surface, lower host overhead |
| Virtual TPM | Not available | **Available**, enabling BitLocker and shielded VMs |
| Boot order management | Fixed legacy device list (`Set-VMBios`) | Ordered, scriptable device list (`Set-VMFirmware -BootOrder`) |

The two entries with the greatest day-to-day operational value are **online expansion of the system volume** and **hot-add of network adapters**: both remove a planned outage from routine work that is currently performed under a maintenance window.

### VMware: BIOS to EFI

| Management capability | BIOS firmware | EFI firmware |
|---|---|---|
| System volume above 2 TB | Not addressable under MBR | **Supported** (GPT) |
| Virtual TPM | Not available | **Available** (ESXi 6.7 or later) |
| Windows 11 and Server 2025 guests | Not supportable (TPM 2.0 required) | **Supported** |
| Virtualization-based Security in the guest | Not available | **Available** (hardware version 14+, vSphere 6.7+) |
| Secure Boot | Not available | **Available** (hardware version 13+) |
| SCSI boot, hot-add of adapters, online disk growth | Already available | Unchanged — no gain, these are not BIOS limitations on this platform |
| VM identity, UUID, backup jobs | — | Preserved: the VM object is reconfigured, not recreated |

### Consequences for estate management

Independently of the platform, the migration produces three effects at fleet level:

- **A single provisioning baseline.** Once the estate is homogeneous, templates, golden images and automation stop having to handle two boot modes. Mixed BIOS/UEFI estates are a recurring source of deployment defects, because a template built for one mode fails silently on the other.
- **Future guest support.** Recent operating systems increasingly assume UEFI. Remaining on BIOS progressively narrows the set of guests that can be deployed, and makes each future upgrade a firmware migration as well as an OS migration.
- **Hardware version and generation alignment.** The migration is the natural point to bring the virtual hardware level up to the version required by Secure Boot and VBS, rather than performing a second disruptive pass later.

> **Counterpart to be planned for.** On Hyper-V only, the gains above come at the cost of a new VM object: the Generation 2 machine is not the Generation 1 machine reconfigured. Backup jobs, monitoring, inventory and any automation keyed on the VM identifier must be verified after migration. On VMware this cost does not exist, since the VM object is preserved.

# Guest operating system compatibility matrix

Verdict legend:

| Symbol | Meaning |
|---|---|
| **OK** | In-place conversion supported by the delivered components |
| **OFFLINE** | Conversion possible, but requires booting from external media |
| **REFUSED** | No supported path — rebuild recommended |

## Windows Server

| Version | Build | UEFI boot | Secure Boot | Native `MBR2GPT` | Hyper-V Gen 2 guest | End of support | Verdict |
|---|---|---|---|---|---|---|---|
| 2003 / 2003 R2 | 5.2 | No | No | No | No | July 2015 | **REFUSED** |
| 2008 / 2008 R2 | 6.0 / 6.1 | Yes (x64) | No | No | **Not supported** | January 2020 | **REFUSED** |
| 2012 / 2012 R2 | 9200 / 9600 | Yes | Yes | **No** | Yes | ESU: October 2026 | **OFFLINE** |
| 2016 | 14393 | Yes | Yes | **No** | Yes | January 2027 | **OFFLINE** |
| 2019 | 17763 | Yes | Yes | Yes | Yes | January 2029 | **OK** |
| 2022 | 20348 | Yes | Yes | Yes | Yes | October 2031 | **OK** |
| 2025 | 26100 | Yes | Yes | Yes | Yes | November 2034 | **OK** |

## Major constraint: Server 2012 R2 and 2016

The `MBR2GPT.exe` tool shipped with **Windows 10 version 1703 (build 15063)**.

Windows Server 2016 is built on the Windows 10 version 1607 codebase (**build 14393**) and **does not contain this tool**. Neither does Windows Server 2012 R2 (build 9600). The common assumption that "Server 2016 has MBR2GPT" is **incorrect**, and is the principal schedule-slippage factor identified.

For these two versions the conversion remains achievable, but only offline:

1. Boot the virtual machine from **WinPE 10.0.15063 or later** media (Windows 10 1703+ or Server 2019+ ADK).
2. Run `mbr2gpt /validate /disk:0` then `mbr2gpt /convert /disk:0`, **without the `/allowFullOS` switch**, which is reserved for a running system.
3. Shut down, switch the firmware, reboot.

> **Point of caution:** copying the `mbr2gpt.exe` binary from a newer Windows onto an older system is not supported by the vendor and is prohibited — the executable depends on the servicing stack of the OS it ships with.

## What each Windows version actually gains

The migration delivers value in two successive stages, and they must not be conflated when building the business case. **UEFI on its own** removes structural limits and unlocks the Generation 2 virtual machine. **UEFI plus Secure Boot** is what opens the security feature set — and what that set contains depends entirely on the Windows version.

The table below reads: what is gained by switching the firmware, then what is additionally gained by enabling Secure Boot on top of it.

| Version | Gained with UEFI alone | Additionally gained with UEFI + Secure Boot (+ TPM 2.0) |
|---|---|---|
| **2008 / 2008 R2** | — no supported migration path — | — |
| **2012 / 2012 R2** | System disk > 2 TB (GPT); Hyper-V Generation 2 VM; faster boot | Secure Boot and Measured Boot (boot chain integrity); BitLocker sealed to a Secure Boot state rather than legacy boot data. **No VBS, no Credential Guard** — those require 2016 or later. |
| **2016** | Same as above | Everything above, plus **Virtualization-based Security (VBS)**, **HVCI** (hypervisor-enforced code integrity), **Credential Guard** (manual enablement by GPO), and eligibility as a **shielded VM** guest. |
| **2019** | Same as above | Same set as 2016. |
| **2022** | Same as above | Everything above, plus **System Guard Secure Launch (DRTM)** and eligibility for the **Secured-core server** profile. |
| **2025** | Same as above | Everything above, with **Credential Guard enabled by default** instead of requiring a GPO. |

### The two inflection points

Two versions change the nature of what the migration buys:

- **Server 2016 is the security inflection point.** Before it, Secure Boot delivers boot integrity and nothing more. From 2016 onward, Secure Boot becomes the gateway to the isolation-based defences — VBS, HVCI, Credential Guard. A 2012 R2 estate migrated to UEFI gains a hardened boot chain, but it does **not** gain credential-theft protection: that arrives only with the operating system upgrade.
- **Server 2022 raises the ceiling** with DRTM and the Secured-core profile, and **Server 2025 changes the default**, shipping with Credential Guard on unless explicitly disabled — which makes the UEFI + Secure Boot prerequisite non-negotiable rather than optional on that version.

### Minimum version per capability

| Capability | Minimum Windows Server | Requires UEFI | Requires Secure Boot | Requires TPM 2.0 |
|---|---|---|---|---|
| System disk > 2 TB (GPT) | Any | Yes | No | No |
| Hyper-V Generation 2 guest | 2012 | Yes | No | No |
| Secure Boot / Measured Boot | 2012 | Yes | Yes | Recommended |
| VBS (Virtualization-based Security) | 2016 | Yes | Yes | Recommended |
| HVCI / Memory integrity | 2016 | Yes | Yes | Recommended |
| Credential Guard | 2016 (default-on from 2025) | Yes | Yes | Yes |
| Shielded VM (as guest) | 2016 | Yes | Yes | Yes (vTPM) |
| System Guard Secure Launch (DRTM) | 2022 | Yes | Yes | Yes |
| Secured-core server profile | 2022 | Yes | Yes | Yes |

### Prerequisite specific to virtual machines

This is the point most often missed when planning: on a virtual machine, UEFI and Secure Boot are **necessary but not sufficient** for VBS and Credential Guard. The hypervisor must also expose the capabilities those features depend on.

| Platform | Additional configuration required |
|---|---|
| **Hyper-V** | Generation 2 VM, virtual TPM enabled (`Enable-VMTPM`), and nested virtualization exposed to the guest (`Set-VMProcessor -ExposeVirtualizationExtensions $true`). |
| **VMware** | VM hardware version 14 or later on vSphere 6.7+, EFI firmware with Secure Boot, and the VBS option enabled on the VM, which in turn exposes nested virtualization, IOMMU and a vTPM. |

Consequently the migration described in this document is a **prerequisite for** these security features, not a deployment of them. Enabling VBS or Credential Guard is a separate project phase, to be scheduled after the UEFI boot has been validated, and to be assessed against its own compatibility constraints — nested virtualization in particular interacts with third-party hypervisor-level tooling and with some backup agents.

> **Capabilities unlocked, not activated.** Every item in the tables above becomes *possible* after the migration. With the sole exception of Credential Guard on Server 2025, none of them is enabled automatically. Each requires explicit configuration and its own validation.

## Red Hat Enterprise Linux

Applies equally to the compatible rebuilds of each generation (CentOS, AlmaLinux, Rocky Linux).

| Version | UEFI boot | Secure Boot | Hyper-V Gen 2 guest | Support | Verdict |
|---|---|---|---|---|---|
| RHEL 5 | Not viable on x86_64 | No | No | End of life November 2020 | **REFUSED** |
| RHEL 6 | Present but unreliable | No | No (Gen 2 requires 7.0+) | ELS ended June 2024 | **REFUSED** |
| RHEL 7 | Yes | Yes (first RHEL with Secure Boot) | Yes (7.0+) | End of life June 2024, ELS available | **OK, but OS is end of life** |
| RHEL 8 | Yes | Yes | Yes | Maintenance until May 2029 | **OK** |
| RHEL 9 | Yes | Yes | Yes | Maintenance until May 2032 | **OK** |
| RHEL 10 | Yes | Yes | Yes | Released May 2025, maintenance to ~May 2035 | **OK** |

### Rationale for refusing RHEL 6

RHEL 6 ships `efibootmgr` and its installer can operate in UEFI mode: on paper, the version qualifies. In practice, the GPT/UEFI path in RHEL 6 carried known defects — notably `efibootmgr` failing to create a boot entry when boot variables exceeded 1024 bytes — and several Red Hat products built on RHEL 6 shipped with legacy-only boot. Combined with the operating system being past even its extended life phase, conversion effort would be spent on a system that must be replaced regardless.

### Special case of RHEL 7

RHEL 7 is technically convertible but has been out of full support since June 2024. Converting this estate buys a UEFI boot on a system that will have to be replaced anyway. **Recommendation: fold the UEFI switch into the upgrade to RHEL 8 or 9 rather than performing the operation twice.**

# Security

## Secure Boot

Secure Boot is a feature distinct from UEFI, to be enabled **after** a plain UEFI boot has been validated. Enabling it prematurely is a frequent cause of a machine that converts correctly yet refuses to start.

| Platform | Prerequisite |
|---|---|
| VMware | VM hardware version ≥ 13, and a signed loader/kernel on the guest side. |
| Hyper-V — Windows guest | `MicrosoftWindows` template. |
| Hyper-V — Linux guest | **`MicrosoftUEFICertificateAuthority`** template, not `MicrosoftWindows`. |

On Linux, Secure Boot requires a signed shim (`shim-x64`), provided by the distribution from RHEL 7 onward. An unsigned kernel forces Secure Boot to be disabled.

## Calendar watch point

Several Secure Boot signing certificates reach expiry during **2026**, which affects how shims are signed and trusted. If the project is motivated primarily by enabling Secure Boot, the current Red Hat and Microsoft guidance on this certificate rollover should be checked before the schedule is finalized.

## Virtual TPM

Windows 11, Credential Guard and VBS require, beyond UEFI, a TPM 2.0 exposed by the hypervisor. Enabling it is a separate operation, to be carried out after the UEFI boot has been validated.

The per-version detail of which security capabilities each Windows release unlocks, and the hypervisor-side configuration they additionally require, is set out in "What each Windows version actually gains" above.

# Delivered components

The automation consists of PowerShell scripts (Windows, VMware, Hyper-V) and Bash scripts (Linux), classified into three kinds according to their impact.

## Component classification

| Kind | Mandated behavior |
|---|---|
| **Read-only** | Changes nothing. Offers no force option. |
| **Additive** | Creates a snapshot. Must never be blocked behind a confirmation prompt. |
| **Destructive** | Rewrites a partition table, or reconfigures/removes a VM. Prompts for confirmation by default, with a force option for automation. |

## Inventory

| Component | Platform | Kind | Role |
|---|---|---|---|
| `Test-UefiReadiness.ps1` | Windows guest | Read-only | Eligibility audit: build, TPM, BitLocker, MBR2GPT validation |
| `Convert-WindowsToUefi.ps1` | Windows guest | Destructive | MBR to GPT conversion (MBR2GPT wrapper) |
| `Test-UefiMigrationResult.ps1` | Windows guest | Read-only | Post-migration validation from within the guest |
| `check-uefi-readiness.sh` | Linux guest | Read-only | Eligibility audit: partition table, free space, packages |
| `convert-linux-to-uefi.sh` | Linux guest | Destructive | MBR to GPT conversion, ESP creation, GRUB-EFI installation |
| `verify-uefi-migration.sh` | Linux guest | Read-only | Post-migration validation from within the guest |
| `restore-partition-table.sh` | Linux guest | Destructive | Restoration of a saved partition table |
| `Get-VMFirmwareReport.ps1` | VMware | Read-only | Estate-wide firmware audit |
| `New-PreMigrationSnapshot.ps1` | VMware | Additive | Pre-migration safety snapshot |
| `Set-VMFirmware.ps1` | VMware | Destructive | BIOS / EFI switch on an existing VM |
| `Get-VMGenerationReport.ps1` | Hyper-V | Read-only | Estate-wide generation audit |
| `New-PreMigrationCheckpoint.ps1` | Hyper-V | Additive | Pre-migration safety checkpoint |
| `Convert-Gen1ToGen2.ps1` | Hyper-V | Destructive | Generation 1 to Generation 2 migration |
| `Restore-Gen1VM.ps1` | Hyper-V | Destructive | Rollback to the retained Generation 1 VM |

## Design principles adopted

1. **No component removes the operator's fallback.** The Hyper-V migration renames the source VM instead of deleting it; the rollback script verifies that the fallback VM exists and is Generation 1 **before** any removal, so that a missing fallback aborts the operation rather than leaving the operator with neither machine.
2. **Simulation by default on destructive operations.** Bash scripts require an explicit `--confirm`; PowerShell scripts expose `-WhatIf`.
3. **No promise exceeding actual capability.** The partition-table restore explicitly documents that it **does not** convert a disk back to MBR, that operation being technically impossible from the backup produced.
4. **Final cleanup is a human decision.** No automatic deletion of any VM, disk or snapshot.

## Quality control

A continuous integration pipeline runs on every change: Bash static analysis (ShellCheck), PowerShell static analysis (PSScriptAnalyzer), syntax checking, and a test suite verifying that the safety rules above are actually observed by each component. Any new component must be declared in the classification registry, failing which the pipeline fails.

# Technical prerequisites

## VMware environment

- VM hardware version ≥ 13 for Secure Boot.
- vSphere `VirtualMachine.Config.Settings` privilege on the target VMs.
- PowerCLI module installed on the administration workstation.
- Virtual machine **powered off** for the firmware switch.

## Hyper-V environment

- Hyper-V host on Windows Server 2012 R2 or later.
- Hyper-V PowerShell module available.
- Sufficient disk space for the two VMs to coexist temporarily.
- Disks in VHDX format.

## Guest operating systems

| Guest | Prerequisite |
|---|---|
| Windows | Local administrator account; BitLocker suspended where applicable; at most 3 primary partitions; unallocated space available (~100 MB) |
| Linux | Root access; free space for the ESP partition (512 MB recommended); repositories reachable to install the `gdisk`, `grub-efi`, `efibootmgr` and `dosfstools` packages |

# Risk analysis

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Machine unbootable after the switch (operation order inverted) | Medium | Critical | Sequence mandated by the documentation; validation scripts at each step; mandatory prior snapshot |
| R2 | Absence of `MBR2GPT` on Server 2012 R2 / 2016 discovered mid-intervention | **High** | Major | Compatibility matrix circulated in advance; the audit script identifies the case and points to the WinPE route |
| R3 | Secure Boot enabled before the UEFI boot is validated | Medium | Major | Enabled as a separate step after validation; certificate template matched to the guest OS |
| R4 | Loss of fallback in the event of failure (snapshot missing) | Low | Critical | Dedicated snapshot scripts; step 0 is non-optional in the procedure |
| R5 | Hyper-V Gen 2 VM not recognized by backup tooling | Medium | Moderate | Third-party tooling surveyed before the campaign; original VM retained until full validation |
| R6 | Loss of static MAC addressing (Hyper-V, Legacy adapter) | Medium | Moderate | Post-migration addressing check; network configuration recorded beforehand |
| R7 | Conversion attempted on an out-of-support OS | Medium | Major | Compatibility matrix; explicit **REFUSED** verdict; blocking audit script |
| R8 | Storage saturation from snapshots during a campaign | Medium | Moderate | Snapshots deleted after validation; scripts report snapshots already present |

# Rollout approach

## Estate segmentation

The estate must be segmented into three lots, each handled differently:

| Lot | Contents | Treatment |
|---|---|---|
| **Lot 1 — Standard conversion** | Server 2019 / 2022 / 2025, RHEL 8 / 9 / 10 | Full nominal procedure |
| **Lot 2 — Offline conversion** | Server 2012 R2, Server 2016 | Nominal procedure, with the conversion step performed on WinPE media; longer outage |
| **Lot 3 — Rebuild** | Server 2003 / 2008 / 2008 R2, RHEL 5 / 6 | Outside the conversion scope. Rebuild on a current operating system and migrate the workload |

RHEL 7 is an intermediate case: technically eligible for Lot 1, but the recommendation is to attach it to the version-upgrade project.

## Recommended sequencing

1. **Inventory**: run the read-only audit scripts across the estate, with no production impact.
2. **Segmentation**: allocate machines to the three lots above.
3. **Pilot**: process a representative, non-critical sample of each lot, including **validation of the rollback procedure** and not only of the nominal path.
4. **Wave rollout**: process homogeneous lots, with a go / no-go decision point after each wave.
5. **Closure**: delete snapshots and fallback VMs after an observation period.

# Known limitations and commitments

## What the solution guarantees

- In-place conversion of the system disk, without data loss, for systems classified **OK** in the matrix.
- Systematic retention of a rollback path for as long as the operator has not explicitly performed the cleanup.
- Up-front detection of ineligible cases, before any write to disk.

## What the solution does not guarantee

- **No automated GPT to MBR reconversion.** Once the disk has been converted, genuine rollback is exclusively through snapshot restoration.
- **No support for the complex topologies** listed as out of scope.
- **No application-level validation.** The scripts validate the boot and the system configuration; validating the service delivered by the machine is the responsibility of the application owner.
- The end-of-support dates quoted are subject to change and must be re-verified with the vendors before any schedule commitment.

# Glossary

| Term | Definition |
|---|---|
| **BIOS** | Basic Input/Output System. The legacy boot firmware, now being retired. |
| **UEFI** | Unified Extensible Firmware Interface. The modern boot firmware, successor to the BIOS. |
| **MBR** | Master Boot Record. Legacy partitioning scheme, limited to 2 TB and four primary partitions. |
| **GPT** | GUID Partition Table. The partitioning scheme associated with UEFI, without those limits. |
| **ESP** | EFI System Partition. FAT32 partition holding the `.efi` boot loaders. |
| **Secure Boot** | UEFI mechanism verifying the signature of the loader and kernel at startup. |
| **Generation (Hyper-V)** | Immutable attribute of a Hyper-V VM determining its firmware: Gen 1 = BIOS, Gen 2 = UEFI. |
| **shim** | Signed intermediate loader allowing Linux to boot under Secure Boot. |
| **WinPE** | Windows Preinstallation Environment. Minimal boot environment used for offline operations. |
| **TPM** | Trusted Platform Module. Secure key storage component required by certain security features. |
| **ESU** | Extended Security Updates. Paid program providing security fixes beyond extended support. |
