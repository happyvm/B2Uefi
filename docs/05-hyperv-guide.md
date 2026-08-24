# Hyper-V guide: migrating from Generation 1 (BIOS) to Generation 2 (UEFI)

## Key difference from VMware

On Hyper-V, firmware **is not a parameter you can change** on an existing VM: it is fixed once and for all by the VM's **generation**, chosen at creation time.

| | Generation 1 | Generation 2 |
|---|---|---|
| Firmware | Legacy BIOS | UEFI |
| Supported disk | VHD or VHDX, IDE or SCSI | **VHDX only**, SCSI only |
| Secure Boot | No | Yes (can be enabled) |

**There is no official command to convert a Gen 1 VM to Gen 2 in place.** The only method supported by Microsoft is to:
1. Prepare the guest disk for a UEFI boot (on the OS side, while the VM is still Gen 1);
2. Create a new **Generation 2 VM**;
3. Attach the converted disk to this new VM;
4. Replicate the configuration (RAM, vCPU, network, boot order);
5. Boot the new VM and validate it, keeping the original Gen 1 VM disabled until fully validated.

## Detailed steps

### 1. Convert the guest disk (VM still Gen 1, powered on)

- Windows: [02-windows-guide.md](02-windows-guide.md) (`mbr2gpt /convert`)
- Linux: [03-linux-guide.md](03-linux-guide.md) (`convert-linux-to-uefi.sh`)

### 2. Make sure the disk is in VHDX format

Generation 2 does not support VHD. If the Gen 1 VM's disk is a `.vhd`:

```powershell
Convert-VHD -Path "D:\VMs\srv-app01\srv-app01.vhd" -DestinationPath "D:\VMs\srv-app01\srv-app01.vhdx" -VHDType Dynamic
```

### 3. Shut down the Gen 1 VM

```powershell
Stop-VM -Name "srv-app01"
```

### 4. Audit candidate Gen 1 VMs (optional, ahead of time)

```powershell
.\scripts\hyperv\Get-VMGenerationReport.ps1
```

Lists every VM on the host with its generation, its state, and flags the Gen 1 VMs whose disk is still MBR (requiring guest conversion before migration).

### 5. Create the Generation 2 VM and migrate

```powershell
.\scripts\hyperv\Convert-Gen1ToGen2.ps1 -SourceVMName "srv-app01" -NewVMName "srv-app01" -OSType Windows
```

The script:
1. Verifies the source VM is **powered off** and that its disk is a VHDX.
2. Renames the Gen 1 source VM to `srv-app01-gen1-legacy` (it is **never deleted automatically**).
3. Creates a new Generation 2 VM with the original name, replicating: memory (static or dynamic), vCPU count, network switch(es) (synthetic adapters only — Gen 1's "Legacy Network Adapters" are not supported on Gen 2 and are replaced with their synthetic equivalent).
4. Attaches the VHDX to a SCSI controller and sets it first in the boot order.
5. Configures Secure Boot with the appropriate template:
   - `MicrosoftWindows` for `-OSType Windows`
   - `MicrosoftUEFICertificateAuthority` for `-OSType Linux`
   - Secure Boot disabled if `-DisableSecureBoot` is passed (needed for some unsigned Linux kernels).
6. Starts the new VM if `-Start` is passed (otherwise leaves it powered off for manual review before the first boot).

### 6. Validate

On the host:

```powershell
Get-VM "srv-app01" | Select-Object Name, Generation, State
```

Then inside the guest, once it has booted — this is the check that actually proves the migration worked:

```powershell
.\scripts\windows\Test-UefiMigrationResult.ps1   # Windows guest
```
```bash
sudo ./scripts/linux/verify-uefi-migration.sh    # Linux guest
```

If validation fails, roll back with `.\scripts\hyperv\Restore-Gen1VM.ps1 -VMName "srv-app01"` (see [06-troubleshooting-rollback.md](06-troubleshooting-rollback.md)).

### 7. Final cleanup (after validation, manual)

Once the new VM's behavior has been confirmed over the desired observation period, delete the `-gen1-legacy` VM:

```powershell
Remove-VM -Name "srv-app01-gen1-legacy" -Force
```

> This repository **never** automatically deletes the original Gen 1 VM — that is a deliberate operator decision, carried out manually after validation.

## Known limitations

- No in-place migration for VMs with multiple IDE disks that can't be converted individually — each disk must be VHDX and attached via SCSI on the new VM.
- "Legacy Network Adapters" (Gen 1 only, hardware emulation) have no direct equivalent: the script replaces them with standard synthetic network adapters (same virtual switches), which may require rechecking the MAC address if it was statically assigned.
- Windows Server 2008 R2 / Windows 7: not supported on Generation 2 by Microsoft, out of scope.

Next: [06-troubleshooting-rollback.md](06-troubleshooting-rollback.md)
