# B2Uefi

Documentation and scripts to migrate virtual machines from **BIOS to UEFI**, on **VMware (ESXi/vSphere)** and **Hyper-V**, for **Windows** and **Linux** guests.

## The migration in one picture

A BIOS→UEFI migration touches two independent layers, and the order matters. Converting the disk without switching the firmware leaves an unbootable VM; switching the firmware without converting the disk does the same.

```
1. Snapshot / checkpoint        New-PreMigrationSnapshot.ps1   (VMware)
                                New-PreMigrationCheckpoint.ps1 (Hyper-V)
2. Check eligibility            Test-UefiReadiness.ps1  /  check-uefi-readiness.sh
3. Convert the guest disk       Convert-WindowsToUefi.ps1  /  convert-linux-to-uefi.sh
4. Shut down the VM             (manual)
5. Switch the firmware          Set-VMFirmware.ps1      (VMware)
                                Convert-Gen1ToGen2.ps1  (Hyper-V)
6. Reboot and validate          Test-UefiMigrationResult.ps1  /  verify-uefi-migration.sh
7. Roll back if needed          Restore-Gen1VM.ps1  /  restore-partition-table.sh
```

## Quick start

1. Read [docs/00-overview.md](docs/00-overview.md) to understand the two layers above.
2. Check the guest OS in the [support matrix](docs/07-os-support-matrix.md) — not every version can be converted, and two common ones (Server 2012 R2 and 2016) need an offline route.
3. Follow the checklist in [docs/01-prerequisites.md](docs/01-prerequisites.md) (backup, eligibility).
4. Convert the guest OS:
   - Windows: [docs/02-windows-guide.md](docs/02-windows-guide.md)
   - Linux: [docs/03-linux-guide.md](docs/03-linux-guide.md)
5. Switch the firmware on the hypervisor side:
   - VMware: [docs/04-vmware-guide.md](docs/04-vmware-guide.md)
   - Hyper-V: [docs/05-hyperv-guide.md](docs/05-hyperv-guide.md)
6. If something goes wrong: [docs/06-troubleshooting-rollback.md](docs/06-troubleshooting-rollback.md)

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
  07-os-support-matrix.md         Which guest OS versions can be migrated, and how

scripts/
  windows/
    Test-UefiReadiness.ps1        Eligibility audit (build, TPM, MBR2GPT /validate)
    Convert-WindowsToUefi.ps1     MBR -> GPT conversion (MBR2GPT wrapper)
    Test-UefiMigrationResult.ps1  Post-migration validation, run inside the guest
  linux/
    check-uefi-readiness.sh       Eligibility audit (partition table, free space, packages)
    convert-linux-to-uefi.sh      MBR -> GPT conversion + GRUB-EFI (dry-run by default)
    verify-uefi-migration.sh      Post-migration validation, run inside the guest
    restore-partition-table.sh    Restores a partition table saved by the converter
  vmware/
    Get-VMFirmwareReport.ps1      Firmware audit across VMs (PowerCLI)
    New-PreMigrationSnapshot.ps1  Creates the pre-migration safety snapshot
    Set-VMFirmware.ps1            BIOS <-> EFI switch on an existing VM (PowerCLI)
  hyperv/
    Get-VMGenerationReport.ps1    Generation 1/2 audit
    New-PreMigrationCheckpoint.ps1 Creates the pre-migration safety checkpoint
    Convert-Gen1ToGen2.ps1        Automated Generation 1 -> Generation 2 migration
    Restore-Gen1VM.ps1            Rolls a Gen 2 migration back to the preserved Gen 1 VM
  PSScriptAnalyzerSettings.psd1   Shared PSScriptAnalyzer settings (see "Linting and tests")

tests/
  ScriptContract.ps1              Canonical classification of every script
  Scripts.Tests.ps1               Pester tests enforcing the script conventions
  bash-args.test.sh               Argument-handling tests for the bash scripts

.github/workflows/
  ci.yml                          Lint + tests on every push/PR
```

## Key points to remember

- **VMware**: firmware can be switched on an existing VM (a simple config parameter). **Hyper-V**: not possible in place — you must create a new Generation 2 VM and attach the converted disk to it.
- In every case, the guest OS must be converted to GPT with a UEFI bootloader **before** switching the firmware on the hypervisor side, never after.
- Every destructive script runs in simulation mode by default or exposes `-WhatIf`/`--confirm` — always test in a non-critical environment first.
- No script automatically deletes an original VM or disk: final cleanup is always a manual, deliberate action after validation.
- The real rollback is the snapshot from step 1. `restore-partition-table.sh` undoes partition-table edits but **cannot** convert a disk back to MBR — it documents this limitation rather than pretending otherwise.

## General prerequisites

- Administrator access on the guest VMs.
- PowerCLI (`Install-Module VMware.PowerCLI`) for the `scripts/vmware/` scripts.
- The Hyper-V PowerShell module for the `scripts/hyperv/` scripts.
- `gdisk`/`gptfdisk` and root privileges for the `scripts/linux/` scripts (installed automatically if missing).

See [docs/01-prerequisites.md](docs/01-prerequisites.md) for full details.

## Linting and tests

Every push and pull request runs ShellCheck, a bash syntax check, the bash argument tests, a PowerShell parser check, PSScriptAnalyzer, and the Pester convention suite (see `.github/workflows/ci.yml`).

The Pester suite does not talk to VMware, Hyper-V or a disk. It parses each script and asserts the safety conventions hold — that destructive scripts prompt by default and offer `-Force`, that read-only scripts do neither, that every script sets StrictMode and carries help. A new script must be classified in `tests/ScriptContract.ps1` or the suite fails.

To run everything locally:

```bash
# Bash: syntax, static analysis, argument tests
bash -n scripts/linux/*.sh
shellcheck scripts/linux/*.sh tests/*.sh
./tests/bash-args.test.sh

# PowerShell: static analysis + convention tests
pwsh -NoProfile -Command "Install-Module PSScriptAnalyzer -Scope CurrentUser -Force; Invoke-ScriptAnalyzer -Path scripts,tests -Recurse -Settings scripts/PSScriptAnalyzerSettings.psd1"
pwsh -NoProfile -Command "Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck; Invoke-Pester ./tests -Output Detailed"
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the script conventions CI enforces and what to test before submitting a change.
