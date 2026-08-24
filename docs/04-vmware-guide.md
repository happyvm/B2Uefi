# VMware guide (ESXi/vSphere): switching firmware from BIOS to EFI

Unlike Hyper-V, VMware has no notion of VM "generation": firmware (`BIOS` or `EFI`) is a simple configuration parameter on the VM, changeable **while the VM is powered off**, with no recreation needed.

## Prerequisites

- The guest conversion (MBR→GPT + UEFI bootloader) must **already be done** ([02-windows-guide.md](02-windows-guide.md) / [03-linux-guide.md](03-linux-guide.md)) before switching the firmware, otherwise the VM will fail to boot.
- VM **powered off** (the firmware parameter cannot be changed while running).
- PowerCLI connected to vCenter or an ESXi host: `Connect-VIServer -Server <vcenter>`.
- `VirtualMachine.Config.Settings` permission.

## Auditing VMs (before migration)

```powershell
.\scripts\vmware\Get-VMFirmwareReport.ps1 -VMName "*"
```

Lists, for each VM: current firmware (`bios`/`efi`), hardware version, power state, and whether the hardware version supports Secure Boot (≥ 13).

## Switching a VM's firmware

```powershell
.\scripts\vmware\Set-VMFirmware.ps1 -VMName "srv-app01" -Firmware efi
```

The script:
1. Verifies the VM is powered off (otherwise fails explicitly; it does not stop it automatically).
2. Applies `Firmware = efi` via `ReconfigVM_Task`.
3. Adjusts `motherboardLayout` (`acpiHostBridges` for EFI, required from vSphere 8 onward in some configurations) — see the note below.
4. Waits for the task to finish and prints the result.

To also enable Secure Boot (once a plain UEFI boot has been validated on a first reboot):

```powershell
.\scripts\vmware\Set-VMFirmware.ps1 -VMName "srv-app01" -Firmware efi -EnableSecureBoot
```

> Secure Boot requires hardware version ≥ 13 and a signed bootloader/kernel on the guest side (Windows: natively signed; Linux: `shim-x64` + a signed kernel, otherwise the boot will fail with Secure Boot enabled).

## Note on `motherboardLayout` (vSphere 8+)

Since vSphere 8, some EFI VMs explicitly require `motherboardLayout = acpiHostBridges` (instead of `i440bxHostBridge`, the historical BIOS value) for correct ACPI behavior. The script sets this automatically based on the chosen firmware; if you have doubts about a VM already in EFI mode but with a legacy `i440bxHostBridge` layout, rerun the script on that VM to fix the parameter.

## Rollback

As long as the VM hasn't successfully rebooted, simply switch `Firmware = bios` back with the same script (`-Firmware bios`) to return to the previous state — **provided the guest disk is still in MBR format** (don't perform the guest conversion yet if you're not sure you want to switch immediately). If the guest disk has already been converted to GPT and you need to roll back, restore the snapshot taken before migration (see [01-prerequisites.md](01-prerequisites.md)).

## Post-migration validation

On the hypervisor side:

```powershell
$vm = Get-VM "srv-app01"
$vm.ExtensionData.Config.Firmware        # should return "efi"
$vm.ExtensionData.Config.BootOptions.EfiSecureBootEnabled   # $true if enabled
```

Then validate inside the guest once it has booted — this is the check that actually proves the migration worked:

```powershell
.\scripts\windows\Test-UefiMigrationResult.ps1   # Windows guest
```
```bash
sudo ./scripts/linux/verify-uefi-migration.sh    # Linux guest
```

Once validated, remove the pre-migration snapshot to reclaim datastore space:

```powershell
Get-Snapshot -VM "srv-app01" -Name "pre-uefi-migration" | Remove-Snapshot -Confirm:$false
```

Next: [06-troubleshooting-rollback.md](06-troubleshooting-rollback.md)
