---
title: "Operations Runbook"
subtitle: "BIOS to UEFI Migration Procedure — VMware and Hyper-V"
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
| Title | Operations Runbook — BIOS to UEFI Migration |
| Reference | DEX-B2UEFI-001 |
| Version | 1.0 |
| Status | Pending approval |
| Classification | Internal |
| Related architecture document | DAT-B2UEFI-001 |
| Intended audience | System and virtualization operators, L2/L3 on-call |
| Author | *(to be completed)* |
| Operations reviewer | *(to be completed)* |

## Revision history

| Version | Date | Author | Nature of change |
|---|---|---|---|
| 1.0 | *(to be completed)* | *(to be completed)* | Initial release |

## Warning

This procedure modifies the system disk partition table and the firmware of production virtual machines. **An error in the sequence renders the machine unbootable.**

No step in this document may be started without:

1. a snapshot / checkpoint verified as restorable;
2. a validated application backup;
3. a maintenance window agreed with the application owners.

# Purpose and conditions of use

## Purpose

This document describes the operational procedure to migrate a virtual machine's boot mode from BIOS to UEFI, on VMware or Hyper-V, for a Windows or Linux guest operating system.

It covers preparation, execution, control points, rollback and diagnosis of common incidents.

## Duration and impact

| Phase | Indicative duration | Service interruption |
|---|---|---|
| Eligibility audit | 5 min | No |
| Safety snapshot | 2 to 10 min | No |
| Guest disk conversion | 5 to 15 min | **No** (system running) |
| Shutdown, firmware switch, reboot | 5 to 15 min | **Yes** |
| Post-migration validation | 5 min | No |
| **Total with interruption** | — | **5 to 15 minutes** |

For Windows Server 2012 R2 and 2016, the conversion is performed offline from WinPE media: the interruption then extends to **30 to 45 minutes**.

## Golden rule

> The guest disk conversion is **always** done before the firmware switch. Never the other way round. Never both in the same operation without an intermediate validation.

# Eligibility — verify before any planning

Check the guest operating system version in the table below **before** committing to anything.

## Windows Server

| Version | Verdict | Applicable procedure |
|---|---|---|
| 2019, 2022, 2025 | **Permitted** | Nominal procedure (section 5) |
| 2016 | **Offline only** | WinPE procedure (section 6) |
| 2012 / 2012 R2 | **Offline only** | WinPE procedure (section 6) |
| 2008 / 2008 R2 | **PROHIBITED** | No supported path. Escalate to the architect. |
| 2003 / 2003 R2 | **PROHIBITED** | No supported path. Escalate to the architect. |

> **Common trap:** the `MBR2GPT.exe` tool is **not present** on Windows Server 2016 or Server 2012 R2. It shipped only from the Windows 10 1703 codebase (build 15063), i.e. Server 2019. Do not copy the binary from another system: that is not supported by the vendor.

## Red Hat Enterprise Linux (and equivalent CentOS / AlmaLinux / Rocky)

| Version | Verdict | Note |
|---|---|---|
| RHEL 8, 9, 10 | **Permitted** | Nominal procedure |
| RHEL 7 | **Permitted with reservation** | OS out of full support. Confirm with the architect whether converting is preferable to a version upgrade. |
| RHEL 6 | **PROHIBITED** | Unreliable UEFI path, OS out of support |
| RHEL 5 | **PROHIBITED** | UEFI not viable on x86_64 |

# Preparing the intervention

## Pre-intervention checklist

To be completed and retained as evidence of execution.

| # | Control point | Done |
|---|---|---|
| 1 | Guest OS version checked against the eligibility matrix | ☐ |
| 2 | Maintenance window agreed with the application owner | ☐ |
| 3 | Application backup recent and **tested as restorable** | ☐ |
| 4 | Snapshot / checkpoint created | ☐ |
| 5 | Sufficient free space on the datastore / host | ☐ |
| 6 | BitLocker suspended (encrypted Windows guests) | ☐ |
| 7 | Eligibility audit run with no blocking error | ☐ |
| 8 | Network configuration recorded (any static MAC addresses) | ☐ |
| 9 | Hypervisor console access available (essential if the VM fails to boot) | ☐ |
| 10 | Rollback procedure read and understood by the operator | ☐ |

## Preparation commands

### Safety snapshot — VMware

```powershell
Connect-VIServer -Server <vcenter>
.\scripts\vmware\New-PreMigrationSnapshot.ps1 -VMName "srv-app01"
```

### Safety checkpoint — Hyper-V

```powershell
.\scripts\hyperv\New-PreMigrationCheckpoint.ps1 -VMName "srv-app01"
```

Both scripts report any snapshots already present and display the exact restore and cleanup commands. **Record those commands before proceeding.**

### Suspending BitLocker (encrypted Windows guest)

```powershell
Suspend-BitLocker -MountPoint "C:" -RebootCount 0
Get-BitLockerVolume -MountPoint "C:" | Select-Object MountPoint, ProtectionStatus
```

# Nominal procedure

Applies to Windows Server 2019 and later guests, and RHEL 7 and later.

## Step 1 — Eligibility audit

Run **inside the guest operating system**, with no impact.

### Windows guest

```powershell
.\scripts\windows\Test-UefiReadiness.ps1
```

### Linux guest

```bash
sudo ./scripts/linux/check-uefi-readiness.sh
```

**Control point 1:** the script must finish with an eligibility verdict and exit code 0.

| Result | Decision |
|---|---|
| Eligible (exit code 0) | Proceed to step 2 |
| Not eligible (exit code 1) | **Stop.** Resolve the failing checks or escalate. Do not proceed. |

## Step 2 — Guest disk conversion

Run **inside the guest operating system**. The system stays up; there is no service outage.

### Windows guest

```powershell
.\scripts\windows\Convert-WindowsToUefi.ps1 -DiskNumber 0
```

The script prompts for confirmation. For automation, add `-Force`. To simulate without writing: `-WhatIf`.

### Linux guest

Always simulate first:

```bash
sudo ./scripts/linux/convert-linux-to-uefi.sh --disk /dev/sda
```

Then run for real:

```bash
sudo ./scripts/linux/convert-linux-to-uefi.sh --disk /dev/sda --confirm
```

The script asks for an interactive confirmation (`yes`). For automation, add `--yes`.

**Control point 2:** the conversion must complete without error.

- Windows: check `Get-Disk | Select-Object Number, PartitionStyle` → must show `GPT`.
- Linux: check `parted -s /dev/sda print` → must show `Partition Table: gpt`.

> **Do not leave the machine in this intermediate state.** The disk is converted but the firmware is not yet. Move straight on to step 3.

## Step 3 — Shutting down the virtual machine

Clean shutdown from the guest or from the hypervisor console.

```powershell
Stop-Computer          # Windows guest
```
```bash
sudo shutdown -h now   # Linux guest
```

Wait for confirmation of complete power-off on the hypervisor side before proceeding.

## Step 4 — Firmware switch

**This is where the service interruption begins.**

### VMware

```powershell
.\scripts\vmware\Set-VMFirmware.ps1 -VMName "srv-app01" -Firmware efi
```

The script refuses to run if the VM is not powered off: this is expected behavior, do not work around it.

### Hyper-V

Reminder: under Hyper-V the firmware cannot be changed. The script creates a **new Generation 2 VM** and retains the original VM renamed `<name>-gen1-legacy`.

```powershell
.\scripts\hyperv\Convert-Gen1ToGen2.ps1 -SourceVMName "srv-app01" -OSType Windows
```

For a Linux guest:

```powershell
.\scripts\hyperv\Convert-Gen1ToGen2.ps1 -SourceVMName "srv-web01" -OSType Linux
```

If the Linux kernel is unsigned, add `-DisableSecureBoot`.

**Control point 3:**

- VMware: `(Get-VM "srv-app01").ExtensionData.Config.Firmware` → must return `efi`.
- Hyper-V: `Get-VM "srv-app01" | Select-Object Name, Generation` → must return `2`.

## Step 5 — Reboot and validation

Start the virtual machine, then run **inside the guest**:

### Windows guest

```powershell
.\scripts\windows\Test-UefiMigrationResult.ps1
```

### Linux guest

```bash
sudo ./scripts/linux/verify-uefi-migration.sh
```

**Control point 4 — go / no-go decision:**

| Result | Decision |
|---|---|
| Migration confirmed (exit code 0) | Proceed to step 6 |
| Migration not confirmed (exit code 1) | **Roll back** (section 7) |

> This check is mandatory. A machine can boot from a stale boot entry and appear healthy while still being one reboot away from failing. The fact that the machine "starts" does not constitute validation.

## Step 6 — Closure

1. Re-enable BitLocker where applicable:

```powershell
Resume-BitLocker -MountPoint "C:"
```

2. Have the service confirmed by the application owner.
3. **After an observation period** (recommended: 5 to 7 working days), delete the fallback artifacts:

```powershell
# VMware
Get-Snapshot -VM "srv-app01" -Name "pre-uefi-migration" | Remove-Snapshot -Confirm:$false

# Hyper-V: removal of the retained original VM
Remove-VM -Name "srv-app01-gen1-legacy" -Force
```

> This deletion is an **explicit human decision**. No script performs it automatically. Do not run it before formal application validation.

# Offline procedure — Windows Server 2012 R2 and 2016

These versions do not include the `MBR2GPT.exe` tool. The conversion is performed from an external boot environment.

## Additional prerequisites

- **WinPE 10.0.15063 or later** ISO image (Windows 10 1703+ or Windows Server 2019+ ADK), reachable from the hypervisor.
- Console access to the virtual machine.

## Procedure

1. Carry out the preparation steps (section 4) — including the snapshot, without exception.
2. Shut down the virtual machine.
3. Mount the WinPE ISO and set the boot order to the optical drive.
4. Boot into WinPE and open the command prompt.
5. Identify the system disk:

```
diskpart
list disk
list volume
exit
```

6. Validate then convert — **without `/allowFullOS`**, which is reserved for a running system:

```
mbr2gpt /validate /disk:0
mbr2gpt /convert /disk:0
```

7. Shut down, unmount the ISO, restore the boot order to the disk.
8. Resume the nominal procedure at **step 4** (firmware switch).

## Common errors in WinPE mode

| Message | Cause | Action |
|---|---|---|
| `Disk layout validation failed` | More than 3 primary partitions, or a dynamic disk | Clean up surplus partitions or convert the disk to basic |
| `Cannot find OS partition` | Wrong disk number | Re-check with `diskpart` / `list disk` |
| `Not enough free space` | Insufficient unallocated space for the ESP and MSR | Shrink an existing partition by about 100 MB |

# Rollback procedures

## Decision tree

| Situation | Procedure |
|---|---|
| Firmware switched, **disk still on MBR** | Switch the firmware back (§ 7.1) |
| Disk converted to GPT, VM does not boot, VMware platform | Restore the snapshot (§ 7.3) |
| Disk converted to GPT, VM does not boot, Hyper-V platform | Restore the Gen 1 VM (§ 7.2), then the snapshot if that is not enough (§ 7.3) |
| ESP partition created in error, Linux system still bootable | Restore the partition table (§ 7.4) |
| Any other situation | **Restore the snapshot** (§ 7.3) |

> **Principle:** the snapshot taken at step 0 is the only genuinely complete rollback path. When in doubt, do not attempt to repair — restore.

## 7.1 Switching the firmware back (VMware)

Applies **only** if the guest disk has not yet been converted.

```powershell
.\scripts\vmware\Set-VMFirmware.ps1 -VMName "srv-app01" -Firmware bios
```

## 7.2 Restoring the Generation 1 VM (Hyper-V)

The original VM was neither modified nor deleted: it was only renamed.

```powershell
.\scripts\hyperv\Restore-Gen1VM.ps1 -VMName "srv-app01" -Start
```

The script stops and removes the Generation 2 VM (VHDX files are preserved, merely detached), then restores the original name of the fallback VM. It verifies that the fallback VM exists and is Generation 1 **before** any removal: a missing fallback VM aborts the operation.

> **Limitation:** if the guest disk had already been converted to GPT, the Generation 1 (BIOS) VM will not be able to boot from it either. In that case continue to § 7.3.

## 7.3 Restoring the snapshot

### VMware

```powershell
$snap = Get-Snapshot -VM "srv-app01" -Name "pre-uefi-migration"
Set-VM -VM "srv-app01" -Snapshot $snap -Confirm:$false
Start-VM -VM "srv-app01"
```

### Hyper-V

```powershell
Get-VMSnapshot -VMName "srv-app01"
Restore-VMSnapshot -VMName "srv-app01" -Name "<checkpoint name>" -Confirm:$false
Start-VM -Name "srv-app01"
```

## 7.4 Restoring the partition table (Linux)

The conversion script saves two artifacts under `/root` before any write:

| File | Content |
|---|---|
| `<disk>-partition-table-<timestamp>.backup` | `sgdisk` backup, replayable |
| `<disk>-original-<timestamp>.mbr` | Raw copy of the first sector — the only copy of the original MBR |

List, then restore:

```bash
sudo ./scripts/linux/restore-partition-table.sh --disk /dev/sda --list
sudo ./scripts/linux/restore-partition-table.sh --disk /dev/sda --confirm
```

> **What this operation does and does not do.** It removes partition entries added after the backup, typically the ESP. It **does not** convert the disk back to MBR: an `sgdisk` backup of an MBR disk records a GPT representation of the layout, so replaying it produces GPT. Nor does it undo the `/etc/fstab` line, the GRUB-EFI installation or the initramfs rebuild. **For a complete rollback, restore the snapshot.**

# Incident diagnosis

## The machine no longer boots ("no bootable device" / black screen)

Causes in decreasing order of likelihood:

| # | Cause | Check | Correction |
|---|---|---|---|
| 1 | Disk not actually converted to GPT | From a live CD: `parted /dev/sda print` | Redo step 2, or restore the snapshot |
| 2 | ESP partition with the wrong type | `sgdisk -p /dev/sda` → type `EF00` expected | Correct the type or restore |
| 3 | Incorrect boot order | VMware: VM boot options. Hyper-V: `Get-VMFirmware -VMName <name> \| Select BootOrder` | Move the disk back to first position |
| 4 | Secure Boot enabled prematurely | VM firmware console | Disable Secure Boot, validate the boot, then re-enable it |

## The audit script rejects the machine

| Message | Meaning | Action |
|---|---|---|
| `mbr2gpt.exe not present on this OS` | Server 2012 R2 or 2016 | Switch to the offline procedure (section 6) |
| OS `past end of support` | Server 2008 R2 or earlier, RHEL 5/6 | **Do not convert.** Escalate to the architect |
| `partitions detected, MBR2GPT allows at most 3` | Too many primary partitions | Clean up surplus partitions |
| `Not enough free space to create an ESP` | Insufficient unallocated space (Linux) | Shrink an existing partition |

## Linux-specific incidents

| Symptom | Cause | Correction |
|---|---|---|
| `/boot/efi is not a mountpoint` | ESP not mounted before `grub-install` | Check `mount \| grep efi` and `/etc/fstab` |
| GRUB appears but the kernel does not boot | Incomplete initramfs | `update-initramfs -u -k all` or `dracut -f --regenerate-all` |
| No entry in `efibootmgr` | Emulated firmware ignoring NVRAM writes | Recreate the entry manually and check the boot order on the hypervisor side |

Manually recreating a boot entry:

```bash
efibootmgr -c -d /dev/sda -p 1 -L "GRUB" -l '\EFI\<distribution>\grubx64.efi'
```

## Escalation criteria

Escalate to the next level or to the architect in the following cases:

- Machine unbootable after the snapshot has been restored.
- Unanticipated topology discovered mid-intervention (software RAID, LVM on `/boot`, volume encryption).
- Operating system classified **PROHIBITED** in the eligibility matrix.
- Any doubt about data integrity after conversion.

# Intervention record sheet

To be completed for each machine processed and archived as evidence of execution.

| Item | Value |
|---|---|
| Virtual machine name | |
| Hypervisor (VMware / Hyper-V) | |
| Guest OS and version | |
| Eligibility verdict | |
| Procedure applied (nominal / offline) | |
| Start date and time | |
| Operator | |
| Change number (ITSM) | |

## Control points

| Control point | Result | Time | Initials |
|---|---|---|---|
| CP1 — Eligibility audit | ☐ OK ☐ NOK | | |
| Snapshot created (name) | | | |
| CP2 — Disk conversion | ☐ OK ☐ NOK | | |
| CP3 — Firmware switch | ☐ OK ☐ NOK | | |
| CP4 — Post-migration validation | ☐ OK ☐ NOK | | |
| Application validation | ☐ OK ☐ NOK | | |

## Closure

| Item | Value |
|---|---|
| End date and time | |
| Actual outage duration | |
| Rollback performed | ☐ No ☐ Yes — reason: |
| Snapshot deleted on | |
| Fallback VM deleted on (Hyper-V) | |
| Observations | |

# Appendix — Command reference

## Audit (no impact, may be run at any time)

```powershell
.\scripts\vmware\Get-VMFirmwareReport.ps1 -VMName "*"       # VMware estate
.\scripts\hyperv\Get-VMGenerationReport.ps1                 # Hyper-V estate
.\scripts\windows\Test-UefiReadiness.ps1                    # Windows guest
```
```bash
sudo ./scripts/linux/check-uefi-readiness.sh                # Linux guest
```

## Quick manual checks

### Windows guest

```powershell
$env:firmware_type                                  # must return UEFI
Get-Disk | Select-Object Number, PartitionStyle     # must return GPT
Confirm-SecureBootUEFI                              # Secure Boot state
bcdedit /enum "{bootmgr}"                           # must reference bootmgfw.efi
```

### Linux guest

```bash
[ -d /sys/firmware/efi ] && echo "UEFI" || echo "BIOS"
parted -s /dev/sda print | grep -i "Partition Table"
findmnt /boot/efi
efibootmgr -v
```

### Hypervisor

```powershell
(Get-VM "srv-app01").ExtensionData.Config.Firmware              # VMware
Get-VM "srv-app01" | Select-Object Name, Generation, State      # Hyper-V
```

## Options common to the scripts

| Option | Effect |
|---|---|
| `-WhatIf` | PowerShell simulation, no writes |
| `-Force` | Suppresses the confirmation prompt (automation) |
| `--confirm` | Enables real execution of the Bash scripts (otherwise simulation) |
| `--yes` | Suppresses the interactive Bash confirmation (automation) |
| `--list` | Lists available backups (Linux restore) |

> By default, the Bash scripts run in **simulation** mode. The absence of `--confirm` is not an error: it is the expected behavior for a first run.
