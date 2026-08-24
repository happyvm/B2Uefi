# Windows guide: guest MBR → GPT/UEFI conversion

Applies to Windows 10/11 and Windows Server 2012 R2+ running as a VM (VMware or Hyper-V), with a system disk currently in BIOS/MBR mode.

## Principle

The native `MBR2GPT.exe` tool (present in `C:\Windows\System32` since Windows 10 1703) converts the partition table **in place**, without data loss, and prepares the system partitions needed for UEFI boot (ESP, MSR). It can run:

- from the Windows Recovery Environment (WinRE), without `/allowFullOS`;
- from the fully booted OS, with `/allowFullOS` (the main use case for a production VM).

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
- Verify the effective boot mode:

```powershell
$env:firmware_type      # should return "UEFI"
Confirm-SecureBootUEFI   # $true if Secure Boot is enabled (optional, requires having enabled the option on the hypervisor side)
```

- Verify the disk style:

```powershell
Get-Disk | Select-Object Number, PartitionStyle
```

## Special cases

- **Disk with more than 3 primary partitions**: `MBR2GPT` fails validation. You must first merge/remove extra partitions (or use `/allowFullOS` after cleanup) before retrying.
- **BitLocker active**: suspend encryption (`Suspend-BitLocker -MountPoint "C:"`) before conversion, re-enable it after validating the UEFI boot.
- **Windows 11 / Credential Guard / VBS**: these features additionally require Secure Boot and a TPM 2.0 exposed by the VM — enable them separately on the hypervisor side once the UEFI boot has been validated (VMware: `EfiSecureBootEnabled`, vTPM 2.0; Hyper-V: `Set-VMKeyProtector` + `Enable-VMTPM` on the Gen 2 VM, which requires either the Host Guardian Service or a standalone host with encryption support).

Next: [04-vmware-guide.md](04-vmware-guide.md) or [05-hyperv-guide.md](05-hyperv-guide.md).
