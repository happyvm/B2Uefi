# Prerequisites and pre-migration checklist

## 1. Backup

This is the step the whole repository leans on: every conversion script assumes a restorable snapshot exists. Create it with the provided scripts rather than by hand, so the naming and description are consistent across a migration campaign:

```powershell
# VMware
.\scripts\vmware\New-PreMigrationSnapshot.ps1 -VMName "srv-app01"

# Hyper-V
.\scripts\hyperv\New-PreMigrationCheckpoint.ps1 -VMName "srv-app01"
```

Both scripts report any snapshot the VM already carries and print the exact command to revert or to clean up afterwards.

- **VMware snapshot** or **Hyper-V checkpoint** of the VM before any operation, in addition to a regular application-level backup (Veeam, etc.).
- On the guest, export the current partition table:
  - Linux: `sgdisk --backup=/root/partition-table.backup /dev/sda` (also works on an MBR source)
  - Windows: `mbr2gpt /validate` already produces a report; also keep a system image (`wbadmin` or equivalent) before conversion.
- Never start the conversion without a way back (snapshot + validated application backup).

## 2. Guest OS compatibility

| OS | Minimum version for in-place conversion | Tool |
|---|---|---|
| Windows | Windows 10 1703+ / **Windows Server 2019+** (build ≥ 15063) | `MBR2GPT.exe`, run from the running OS |
| Windows (older) | Windows Server 2012 R2 and 2016 | `MBR2GPT.exe` from **WinPE 1703+ media only** — the tool is not present in these OSes |
| Linux | Kernel with EFI support (virtually every distribution since 2015), `gdisk`/`sgdisk` (`gdisk`/`gptfdisk` package), `grub-efi-amd64`/`grub2-efi-x64` package available | `sgdisk` + `grub-install` |

- x86_64 architecture required (32-bit UEFI exists but is out of scope for these scripts).
- `MBR2GPT.exe` shipped with Windows 10 1703 (build 15063). **Windows Server 2016 is built on the 1607 codebase (build 14393) and does not include it**, nor does Server 2012 R2 — these require booting WinPE 1703+ media to convert.
- Windows Server 2008 R2 and earlier, RHEL 6 and earlier: **rebuild rather than convert**. See the full [OS support matrix](07-os-support-matrix.md) before planning a wave.

## 3. System disk

- One system disk per migration (do not convert a data disk on its own if the OS doesn't boot from it).
- **Windows**: `MBR2GPT` requires at most 3 visible primary partitions plus some unallocated free space (a few dozen MB) to create the new EFI/MSR system partitions. No software RAID volume on the system disk.
- **Linux**: free space available to create an EFI System Partition (ESP, ≥ 100 MB, ideally 512 MB, FAT32-formatted) — either unallocated space at the end of the disk, or a partition to shrink.
- No block-level encryption before conversion (BitLocker must be **suspended**, `luksOpen`/dm-crypt must be handled separately — out of scope for these scripts).

## 4. Hypervisor side

### VMware
- VM **hardware version ≥ 13** for Secure Boot (EFI alone works from version 7, but stay on a recent supported version).
- vSphere permission: `VirtualMachine.Config.Settings` on the VM.
- PowerCLI installed (`Install-Module VMware.PowerCLI`) if you use the provided scripts.

### Hyper-V
- Hyper-V on Windows Server 2012 R2+ / Windows 10+ (Generation 2 requires these minimum host versions).
- Enough disk space to duplicate/move the VHDX during migration (the original Gen 1 VM must be kept intact until the new Gen 2 VM's boot is validated).
- The disk must be in **VHDX** format (Gen 2 does not support VHD); convert with `Convert-VHD` if needed.

## 5. Maintenance window

Plan for a service interruption during:
1. Disk conversion (can be done while the OS is running, without downtime, for both Windows and Linux).
2. Shutting down the VM, switching the firmware (VMware) or recreating it in Gen 2 (Hyper-V), and rebooting — **this step is what actually causes the outage**.

## Summary checklist

- [ ] Snapshot/checkpoint taken (`New-PreMigrationSnapshot.ps1` / `New-PreMigrationCheckpoint.ps1`)
- [ ] Application backup validated and restorable
- [ ] BitLocker suspended (if applicable)
- [ ] Compatibility report generated (`Test-UefiReadiness.ps1` / `check-uefi-readiness.sh`) with no blocking error
- [ ] Free space confirmed on the system disk
- [ ] Maintenance window scheduled
- [ ] Rollback procedure reviewed ([06-troubleshooting-rollback.md](06-troubleshooting-rollback.md))

Next: [02-windows-guide.md](02-windows-guide.md) · [03-linux-guide.md](03-linux-guide.md)
