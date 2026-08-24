# Troubleshooting and rollback

## The VM no longer boots after the firmware switch ("no bootable device" / black screen)

Most likely causes, in order of probability:

1. **The disk wasn't actually converted to GPT before the switch** (step skipped or silently failed). Check via a live-CD/rescue: `parted /dev/sda print` should show `gpt`.
2. **The ESP doesn't have the right flag** (`esp` on Linux, EFI system partition on Windows). Check with `sgdisk -p /dev/sda` (type `EF00`) or `Get-Partition` (`GptType` `{c12a7328-...}`).
3. **Boot order** (Hyper-V Gen 2 / VMware) doesn't point to the right disk/EFI entry. VMware: check the VM's boot options; Hyper-V: `Get-VMFirmware -VMName ... | Select BootOrder`.
4. **Secure Boot enabled before the bootloader is signed/compatible** (common on Linux without `shim`). Temporarily disable Secure Boot to confirm, then fix the bootloader.

## Rollback — VMware

If the VM has **not yet rebooted** after the firmware switch:

```powershell
.\scripts\vmware\Set-VMFirmware.ps1 -VMName "srv-app01" -Firmware bios
```

This only works if the guest disk is still readable in BIOS mode, i.e. if you roll back **before** the MBR→GPT conversion, or if you restore the snapshot taken before the guest conversion. Once the disk has been converted to GPT, a clean rollback to pure BIOS requires restoring the snapshot from [01-prerequisites.md](01-prerequisites.md) — there is no safe "GPT→MBR" path for a system disk that has already booted in UEFI.

## Rollback — Hyper-V

The original Gen 1 VM was never modified or deleted by `Convert-Gen1ToGen2.ps1` (it was only renamed to `-gen1-legacy`). To roll back:

```powershell
.\scripts\hyperv\Restore-Gen1VM.ps1 -VMName "srv-app01" -Start
```

The script stops and removes the Generation 2 VM (VHDX files are preserved, only detached), then renames the legacy VM back to its original name. It verifies the legacy VM exists **and** is Generation 1 *before* removing anything — a missing legacy VM aborts the rollback rather than leaving you with neither VM.

Manual equivalent:

```powershell
Stop-VM -Name "srv-app01" -TurnOff -Force   # stops the Gen 2 VM if it has started
Remove-VM -Name "srv-app01" -Force          # deletes the Gen 2 VM (the VHDX is NOT deleted, only detached)
Rename-VM -Name "srv-app01-gen1-legacy" -NewName "srv-app01"
Start-VM -Name "srv-app01"
```

> Warning: if the guest disk had already been converted to GPT before the failure, the Gen 1 (BIOS) VM won't be able to boot from it either. In that case, restore the snapshot/checkpoint taken before the guest conversion.

## Rollback — the guest disk (Linux)

`convert-linux-to-uefi.sh` saves two artifacts under `/root` before it changes anything:

| File | What it is |
|---|---|
| `<disk>-partition-table-<stamp>.backup` | `sgdisk` backup, replayable with the script below |
| `<disk>-original-<stamp>.mbr` | Raw dump of the original first sector — the only copy of the real MBR |

To list and replay the partition-table backup:

```bash
sudo ./scripts/linux/restore-partition-table.sh --disk /dev/sda --list
sudo ./scripts/linux/restore-partition-table.sh --disk /dev/sda --confirm
```

**Know what this does and does not do.** It removes partition-table entries added after the backup (most usefully, the ESP). It does **not** convert the disk back to MBR: `sgdisk --backup` run against an MBR disk stores a GPT representation of that layout, so replaying it yields GPT. And it does not undo the `/etc/fstab` entry, the GRUB EFI installation, or the initramfs rebuild.

For a genuine full rollback, restore the VM snapshot or checkpoint. That is what it is for.

## `MBR2GPT /validate` fails

| Message | Cause | Action |
|---|---|---|
| `Disk layout validation failed` | More than 3 primary partitions, or a non-standard disk (software RAID, dynamic disk) | Clean up extra partitions, or convert the dynamic disk to basic |
| `Disk is not a fixed MBR disk` | The disk is already GPT, or isn't the expected system disk | Check `Get-Disk`, fix `/disk:N` |
| `Not enough free space` | Not enough unallocated space to create the ESP/MSR partitions | Shrink an existing partition (`Resize-Partition`) to free up ~100 MB |

## `sgdisk -g` fails, or GRUB stays in BIOS mode

- **`grub-install: error: /boot/efi is not a mountpoint`**: the ESP wasn't mounted before `grub-install --target=x86_64-efi`. Check `mount | grep efi` and `/etc/fstab`.
- **`grub-install` succeeds but the firmware still falls back to BIOS at boot**: expected as long as the VM's firmware hasn't been switched on the hypervisor side — this isn't a `grub-install` error, it's the hypervisor step that's still pending.
- **The GRUB menu appears but the kernel doesn't boot**: regenerate the initramfs (`update-initramfs -u -k all` or `dracut -f --regenerate-all`) — an initramfs built for a BIOS boot can be missing needed modules (rare but possible depending on the distribution).

## No boot entry visible in the firmware (VMware/Hyper-V)

```bash
# Linux, from rescue if needed
efibootmgr -c -d /dev/sda -p 1 -L "GRUB" -l '\EFI\<distro>\grubx64.efi'
```

manually recreates the NVRAM entry if `grub-install` didn't do so (this happens on some emulated EFI environments that ignore automatic NVRAM writes — also check the hypervisor's firmware boot order manually in that case).

## Support

These scripts cover the standard case (single system disk, classic partitioning). For more complex topologies (software RAID, LVM on `/boot`, multi-boot), validate every step manually in a test environment before running anything in production.
