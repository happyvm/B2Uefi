# Overview: BIOS → UEFI migration

## Why migrate

- **Secure Boot**: requires UEFI, mandatory for Windows 11, recommended to harden Linux servers too.
- **Long-term support**: Microsoft and most Linux distributions are steering new boot-related features toward UEFI (measured boot, TPM, shielded VMs).
- **Disks > 2 TB**: MBR partitioning is limited to 2 TB and 4 primary partitions; GPT (used by UEFI) removes these limits.
- **Windows Server 2022 / Windows 11 requirement**, and many security stacks (BitLocker + TPM, Credential Guard, VBS) that require UEFI + Secure Boot.

## What "migrating" actually covers

A BIOS → UEFI migration touches **two independent layers** that must be handled in the correct order:

1. **The guest OS layer**: convert the system disk's partition table from MBR to GPT, and install/reconfigure the bootloader so it can boot in UEFI mode (`bootmgfw.efi` on Windows, `grubx64.efi` on Linux).
2. **The hypervisor layer (VM firmware)**: tell VMware or Hyper-V that the VM should now present a UEFI firmware to the guest OS, instead of a legacy BIOS (emulated SeaBIOS/PhoenixBIOS).

These two steps are **related but asymmetric**:

- Converting the disk to GPT without switching the VM firmware to UEFI → the VM no longer boots (legacy BIOS cannot read a GPT disk containing a UEFI ESP as a boot device).
- Switching the firmware to UEFI without having converted the disk → the VM no longer boots (UEFI firmware looks for a FAT32 ESP with a `.efi` loader, which doesn't exist on a classic MBR/BIOS-boot disk).

The correct order is therefore always:

```
1. Prepare the guest disk (MBR->GPT conversion + UEFI bootloader)  [OS still running in BIOS mode]
2. Shut down the VM
3. Switch the VM firmware to EFI on the hypervisor side
4. Reboot -> the VM now boots in UEFI
```

## Fundamental difference: VMware vs. Hyper-V

| | VMware (ESXi/vSphere) | Hyper-V |
|---|---|---|
| Switching BIOS→EFI on an existing VM | **Yes**, a single parameter change (`Firmware`) in the VM's boot options, no recreation needed | **No**, impossible: firmware (BIOS/UEFI) is fixed by the VM's **generation** (Gen 1 = BIOS, Gen 2 = UEFI) and cannot be changed after creation |
| Migration method | `Set-VM`/`ReconfigVM` API on the existing VM | Create a new **Generation 2 VM**, attach the converted disk (VHDX) to it, replicate the configuration (RAM, network, CPU) |
| See | [docs/04-vmware-guide.md](04-vmware-guide.md) | [docs/05-hyperv-guide.md](05-hyperv-guide.md) |

## Scope of this repository

| Folder | Content |
|---|---|
| `docs/` | Detailed guides per platform and per guest OS |
| `scripts/windows/` | Compatibility check + MBR→GPT conversion (`MBR2GPT.exe` wrapper) for the Windows guest OS |
| `scripts/linux/` | Compatibility check + MBR→GPT conversion + GRUB-EFI reinstallation for the Linux guest OS |
| `scripts/vmware/` | PowerCLI scripts to audit and switch the firmware of VMware VMs |
| `scripts/hyperv/` | PowerShell scripts to audit Generation 1 VMs and automate their migration to Generation 2 |

Next: [docs/01-prerequisites.md](01-prerequisites.md).
