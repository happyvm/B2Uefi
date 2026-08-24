# Windows guide: guest MBR → GPT/UEFI conversion

Applies to Windows 10/11 and Windows Server running as a VM (VMware or Hyper-V), with a system disk currently in BIOS/MBR mode.

**Check the [OS support matrix](07-os-support-matrix.md) first.** Which route you take depends on the version:

| Guest | Route |
|---|---|
| Windows 10 1703+, Server 2019 / 2022 / 2025 | This guide, conversion from the running OS |
| Server 2012 R2, Server 2016 | Same steps, but the conversion must run from **WinPE 1703+ media** — see below |
| Server 2008 R2 and earlier | No supported path. Rebuild on a current OS. |

## Principle

The native `MBR2GPT.exe` tool converts the partition table **in place**, without data loss, and prepares the system partitions needed for UEFI boot (ESP, MSR). It can run:

- from the Windows Recovery Environment or WinPE, without `/allowFullOS`;
- from the fully booted OS, with `/allowFullOS` (the main use case for a production VM).

`MBR2GPT.exe` shipped with **Windows 10 version 1703 (build 15063)**. Windows Server 2016 is built on the 1607 codebase (build 14393) and **does not include the tool**; neither does Server 2012 R2. For those, boot the VM from WinPE 10.0.15063+ media and run the conversion there without `/allowFullOS`. Do not copy the binary from a newer Windows — it depends on the servicing stack it ships with.

**Important**: `MBR2GPT` does not change the VM's firmware. After conversion, the OS still boots in BIOS mode momentarily (the VM firmware hasn't changed). It's only after switching the firmware on the hypervisor side (VMware) or recreating the VM as Gen 2 (Hyper-V) that the next boot will actually use UEFI.

## Steps

### 1. Check eligibility

```powershell
.\scripts\windows\Test-UefiReadiness.ps1
```

This script checks: Windows build, current partition style, TPM (if Secure Boot is targeted), whether Secure Boot is already active, and runs `mbr2gpt /validate`.

You can also run directly:

```powershell
mbr2gpt /validate /disk:0 /allowFullOS
```

A successful validation prints `MBR2GPT: Validation completed successfully`.

### 2. Convert the disk

```powershell
.\scripts\windows\Convert-WindowsToUefi.ps1 -DiskNumber 0
```

This script runs `mbr2gpt /validate` then `mbr2gpt /convert` with logging, and prints a reminder of the next steps. Manual equivalent:

```powershell
mbr2gpt /convert /disk:0 /allowFullOS
```

Don't leave the VM in this intermediate state (disk converted but firmware not switched) any longer than necessary — proceed straight to shutting it down and switching the firmware.

### 3. Shut down the VM

```powershell
Stop-Computer  # or a clean shutdown from vCenter / Hyper-V Manager
```

### 4. Switch the firmware on the hypervisor side

- **VMware**: see [04-vmware-guide.md](04-vmware-guide.md), script `scripts/vmware/Set-VMFirmware.ps1`.
- **Hyper-V**: see [05-hyperv-guide.md](05-hyperv-guide.md) — requires recreating the VM as Generation 2 (`scripts/hyperv/Convert-Gen1ToGen2.ps1`); the converted VHDX disk is reattached to the new VM.

### 5. Reboot and validate

- The VM should boot straight into the Windows login screen (no "no bootable device" error/black screen).
- Run the validation script inside the guest:

```powershell
.\scripts\windows\Test-UefiMigrationResult.ps1
```

It confirms the four things that must all be true — the firmware is UEFI, the system disk is GPT, an EFI System Partition exists, and the boot manager points at `bootmgfw.efi` — and exits non-zero if any of them fails. It also reminds you to re-enable BitLocker if it was suspended.

Manual equivalents, if you prefer to check by hand:

```powershell
$env:firmware_type      # should return "UEFI"
Get-Disk | Select-Object Number, PartitionStyle
Confirm-SecureBootUEFI   # $true if Secure Boot is enabled (optional, requires having enabled the option on the hypervisor side)
```

## Special cases

- **Disk with more than 3 primary partitions**: `MBR2GPT` fails validation. You must first merge/remove extra partitions (or use `/allowFullOS` after cleanup) before retrying.
- **BitLocker active**: suspend encryption (`Suspend-BitLocker -MountPoint "C:"`) before conversion, re-enable it after validating the UEFI boot.
- **Windows 11 / Credential Guard / VBS**: these features additionally require Secure Boot and a TPM 2.0 exposed by the VM — enable them separately on the hypervisor side once the UEFI boot has been validated (VMware: `EfiSecureBootEnabled`, vTPM 2.0; Hyper-V: `Set-VMKeyProtector` + `Enable-VMTPM` on the Gen 2 VM, which requires either the Host Guardian Service or a standalone host with encryption support).

Next: [04-vmware-guide.md](04-vmware-guide.md) or [05-hyperv-guide.md](05-hyperv-guide.md).
