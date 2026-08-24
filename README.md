# B2Uefi

Documentation and scripts to migrate virtual machines from **BIOS to UEFI**, on **VMware (ESXi/vSphere)** and **Hyper-V**, for **Windows** and **Linux** guests.

## Quick start

1. Read [docs/00-overview.md](docs/00-overview.md) to understand the overall principle (guest OS conversion vs. hypervisor firmware switch).
2. Follow the checklist in [docs/01-prerequisites.md](docs/01-prerequisites.md) (backup, eligibility).
3. Convert the guest OS:
   - Windows: [docs/02-windows-guide.md](docs/02-windows-guide.md)
   - Linux: [docs/03-linux-guide.md](docs/03-linux-guide.md)
4. Switch the firmware on the hypervisor side:
   - VMware: [docs/04-vmware-guide.md](docs/04-vmware-guide.md)
   - Hyper-V: [docs/05-hyperv-guide.md](docs/05-hyperv-guide.md)
5. If something goes wrong: [docs/06-troubleshooting-rollback.md](docs/06-troubleshooting-rollback.md)

## Repository layout

```
docs/
  00-overview.md                  Overview and correct order of operations
  01-prerequisites.md             Pre-migration checklist
  02-windows-guide.md             Windows guest conversion (MBR2GPT)
  03-linux-guide.md               Linux guest conversion (sgdisk + GRUB-EFI)
  04-vmware-guide.md              VMware firmware switch (BIOS -> EFI)
  05-hyperv-guide.md              Hyper-V Generation 1 -> Generation 2 migration
  06-troubleshooting-rollback.md  Troubleshooting and rollback

scripts/
  windows/
    Test-UefiReadiness.ps1        Eligibility audit (build, TPM, MBR2GPT /validate)
    Convert-WindowsToUefi.ps1     MBR -> GPT conversion (MBR2GPT wrapper)
  linux/
    check-uefi-readiness.sh       Eligibility audit (partition table, free space, packages)
    convert-linux-to-uefi.sh      MBR -> GPT conversion + GRUB-EFI (dry-run by default)
  vmware/
    Get-VMFirmwareReport.ps1      Firmware audit for VMs (PowerCLI)
    Set-VMFirmware.ps1            BIOS <-> EFI switch on an existing VM (PowerCLI)
  PSScriptAnalyzerSettings.psd1   Shared PSScriptAnalyzer settings (see "Linting" below)
  hyperv/
    Get-VMGenerationReport.ps1    Generation 1/2 audit
    Convert-Gen1ToGen2.ps1        Automated Generation 1 -> Generation 2 migration

.github/workflows/
  lint.yml                        CI: ShellCheck + PSScriptAnalyzer on every push/PR
```

## Key points to remember

- **VMware**: firmware can be switched on an existing VM (a simple config parameter). **Hyper-V**: not possible in place — you must create a new Generation 2 VM and attach the converted disk to it.
- In every case, the guest OS must be converted to GPT with a UEFI bootloader **before** switching the firmware on the hypervisor side, never after.
- Every destructive script (`convert-linux-to-uefi.sh`, disk conversions) runs in simulation mode by default or exposes `-WhatIf`/`--confirm` — always test in a non-critical environment first.
- No script automatically deletes an original VM or disk: final cleanup is always a manual, deliberate action after validation.

## General prerequisites

- Administrator access on the guest VMs.
- PowerCLI (`Install-Module VMware.PowerCLI`) for the `scripts/vmware/` scripts.
- The Hyper-V PowerShell module for the `scripts/hyperv/` scripts.
- `gdisk`/`gptfdisk` and root privileges for the `scripts/linux/` scripts (installed automatically if missing).

See [docs/01-prerequisites.md](docs/01-prerequisites.md) for full details.

## Linting

Every script is checked in CI on each push/PR (see `.github/workflows/lint.yml`): a bash syntax check, ShellCheck, a PowerShell parser check, and PSScriptAnalyzer. To run the same checks locally:

```bash
# Bash: syntax + ShellCheck
bash -n scripts/linux/*.sh
shellcheck scripts/linux/*.sh

# PowerShell: PSScriptAnalyzer (requires PowerShell 7+ and the PSScriptAnalyzer module)
# scripts/PSScriptAnalyzerSettings.psd1 documents the two rules deliberately excluded
# (Write-Host for interactive output, and PowerCLI's own $global:DefaultVIServers).
pwsh -NoProfile -Command "Install-Module PSScriptAnalyzer -Scope CurrentUser -Force; Invoke-ScriptAnalyzer -Path scripts -Recurse -Settings scripts/PSScriptAnalyzerSettings.psd1"
```
