# Linux guide: guest MBR → GPT/UEFI conversion

Applies to mainstream distributions (Debian/Ubuntu, RHEL/CentOS/Alma/Rocky, SUSE) running as a VM (VMware or Hyper-V), with a system disk currently in BIOS/MBR mode with legacy GRUB.

**Check the [OS support matrix](07-os-support-matrix.md) first.** RHEL 8/9/10 (and the equivalent Alma/Rocky releases) convert cleanly. RHEL 7 works but is out of full support. RHEL 5 and 6 have no viable path and should be rebuilt, not converted.

## Principle

Unlike Windows, Linux has no single "official" tool equivalent to `MBR2GPT`. Conversion is done through three separate operations:

1. **Partition table conversion** MBR → GPT with `sgdisk` (part of `gdisk`/`gptfdisk`), which preserves existing partitions and their data.
2. **Creating an ESP** (EFI System Partition, FAT32, `esp` flag) in the disk's free space, since an MBR disk never needed one.
3. **Installing GRUB in UEFI mode** (`grub-install --target=x86_64-efi`) and regenerating the config + the initramfs.

As with Windows, this doesn't change the VM's firmware: as long as the firmware stays in BIOS mode on the hypervisor side, the OS still boots through the old path (`/boot/grub/i386-pc`). It's only after the firmware switch (VMware) or the Gen 2 recreation (Hyper-V) that GRUB-EFI takes over.

## Steps

### 1. Check eligibility

```bash
sudo ./scripts/linux/check-uefi-readiness.sh
```

Checks: current boot mode (`/sys/firmware/efi`), partition table (`parted`), available free space, presence of required packages (`gdisk`, `grub-efi-*`), and detects the package manager (apt/dnf/yum/zypper).

### 2. Convert the disk

```bash
sudo ./scripts/linux/convert-linux-to-uefi.sh --disk /dev/sda --confirm
```

Without `--confirm`, the script runs in **simulation mode** (dry-run) and only prints the planned actions. The script:

1. Backs up the current partition table (`sgdisk --backup`).
2. Installs missing packages (`gdisk`, `grub-efi-amd64`/`grub2-efi-x64`, `efibootmgr`, `dosfstools`).
3. Creates a new ESP partition in the free space at the end of the disk (512 MB by default, adjustable with `--esp-size`).
4. Formats the ESP as FAT32 and sets the `esp`/`boot` flag.
5. Converts the partition table to GPT (`sgdisk -g`).
6. Mounts the ESP on `/boot/efi`, updates `/etc/fstab` with its UUID.
7. Installs GRUB in UEFI mode and regenerates `grub.cfg` + the initramfs.

> ⚠️ Steps 3 and 5 modify the disk's structure. The script requires `--confirm` explicitly and prints a summary before any write. On a critical system, it is recommended to run the conversion from a live-CD/rescue environment where possible rather than on a live system — the script works either way, but a live-CD limits risk if the system disk is under heavy write load.

### 3. Shut down the VM

```bash
sudo shutdown -h now
```

### 4. Switch the firmware on the hypervisor side

- **VMware**: see [04-vmware-guide.md](04-vmware-guide.md).
- **Hyper-V**: see [05-hyperv-guide.md](05-hyperv-guide.md) — Secure Boot for Linux must use the `MicrosoftUEFICertificateAuthority` template (not `MicrosoftWindows`), or be disabled if the kernel/shim isn't signed.

### 5. Reboot and validate

```bash
sudo ./scripts/linux/verify-uefi-migration.sh
```

It confirms everything that must be true for the migration to be complete — booted in UEFI, disk is GPT, an ESP exists and is mounted, `/etc/fstab` persists it, a GRUB EFI binary is installed, and a firmware boot entry exists — and exits non-zero if any check fails.

Manual equivalents, if you prefer to check by hand:

```bash
[ -d /sys/firmware/efi ] && echo "Booted in UEFI" || echo "Still in BIOS"
efibootmgr -v
lsblk -o NAME,PARTTYPE,FSTYPE,MOUNTPOINT
```

- `efibootmgr -v` should list a boot entry pointing to `\EFI\<distro>\grubx64.efi` on the ESP.
- `parted /dev/sda print` should show `Partition Table: gpt`.

## Special cases

- **Separate encrypted /boot (LUKS)**: modern GRUB-EFI (2.04+) supports LUKS unlocking at boot, but check the version available on your distribution before migrating an encrypted system.
- **Extended/logical partitions (MBR)**: `sgdisk -g` converts them into independent GPT partitions; check `/etc/fstab` after conversion — UUIDs of existing partitions don't change, but a sanity-check `blkid` run is recommended.
- **RHEL/CentOS**: the package is `grub2-efi-x64` + `shim-x64`, and the config-regeneration command is `grub2-mkconfig -o /boot/efi/EFI/<id>/grub.cfg` (the script automatically detects the distribution family).
- **Secure Boot**: requires a signed shim (`shim-x64` provided by the distribution), already installed by the script if the package is available in the repositories.

Next: [04-vmware-guide.md](04-vmware-guide.md) or [05-hyperv-guide.md](05-hyperv-guide.md).
