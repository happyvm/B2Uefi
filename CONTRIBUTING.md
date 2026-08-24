# Contributing

These scripts rewrite partition tables and reconfigure virtual machines. A bug here does not produce a stack trace — it produces a server that will not boot. The conventions below exist for that reason, and CI enforces them.

## Before you start

Read [docs/00-overview.md](docs/00-overview.md). The single most important fact about this repository is that a BIOS→UEFI migration has two independent layers (guest OS and hypervisor firmware) that must be changed in a specific order. Most bugs come from conflating them.

## Script conventions

Every script under `scripts/` is classified in [`tests/ScriptContract.ps1`](tests/ScriptContract.ps1) as one of three kinds. **A new script must be added to that file**, or the test suite fails by design.

| Kind | What it does | Required |
|---|---|---|
| `ReadOnly` | Reports only, changes nothing | No `-Force`, no `SupportsShouldProcess` |
| `Additive` | Creates a snapshot/checkpoint | `SupportsShouldProcess`, `ConfirmImpact = 'Low'` |
| `Destructive` | Rewrites a partition table, reconfigures or removes a VM | `SupportsShouldProcess`, `ConfirmImpact = 'High'`, and a `-Force` switch |

`ConfirmImpact` is not cosmetic: `High` makes the script prompt by default, and `Low` keeps a safety snapshot from being blocked behind a prompt during an incident.

### All PowerShell scripts must

- declare `[CmdletBinding()]`;
- set `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`;
- carry comment-based help with `.SYNOPSIS`, `.DESCRIPTION` and at least one `.EXAMPLE`;
- validate parameters with `[ValidateNotNullOrEmpty()]`, `[ValidateSet(...)]` or `[ValidateRange(...)]` rather than checking inside the body;
- fail with a `throw` that says what to do next, not just what went wrong.

### All bash scripts must

- start with `#!/usr/bin/env bash` and be executable;
- use `set -euo pipefail`;
- default to a dry run and require an explicit `--confirm` before writing anything, plus an interactive `yes` prompt that `--yes` can bypass for automation;
- pass ShellCheck with no suppressions. If you think you need a `# shellcheck disable`, the code usually wants restructuring instead — the glob-in-a-variable case in `restore-partition-table.sh` was fixed by using an array, not by silencing SC2125.

### Both

- **Never delete the operator's fallback.** `Convert-Gen1ToGen2.ps1` renames the source VM instead of removing it; `Restore-Gen1VM.ps1` verifies the legacy VM exists *before* removing the Gen 2 VM. Final cleanup is always a separate, manual, human decision.
- **Never claim more than the script does.** `restore-partition-table.sh` documents at length that it does *not* convert a disk back to MBR, because `sgdisk --backup` cannot represent one. Overstating a rollback path is worse than not shipping it.
- Print the next step. Every script that finishes a stage tells the operator what comes after it.

## Running the checks locally

CI runs all of these on every push and pull request (`.github/workflows/ci.yml`); run them before you push.

```bash
# Bash: syntax, static analysis, argument tests
bash -n scripts/linux/*.sh
shellcheck scripts/linux/*.sh tests/*.sh
./tests/bash-args.test.sh

# PowerShell: static analysis + convention tests
pwsh -NoProfile -Command "Install-Module PSScriptAnalyzer -Scope CurrentUser -Force; Invoke-ScriptAnalyzer -Path scripts,tests -Recurse -Settings scripts/PSScriptAnalyzerSettings.psd1"
pwsh -NoProfile -Command "Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck; Invoke-Pester ./tests -Output Detailed"
```

The two PSScriptAnalyzer rules excluded in `scripts/PSScriptAnalyzerSettings.psd1` are deliberate and documented in that file. Do not add exclusions without the same justification.

## Testing changes for real

The test suite checks conventions, not behavior — it cannot verify that a conversion works. Before submitting a change to any conversion or firmware script:

1. Test on a throwaway VM with a snapshot, not a VM you care about.
2. Test both guest families if you touched shared logic (Windows and Linux).
3. Test the rollback path too, not just the happy path.
4. Say in your pull request what you actually ran it against — hypervisor, guest OS, and whether you exercised the rollback.

Changes that only touch documentation do not need this.

## Scope

This repository targets x86_64 guests with a single system disk and standard partitioning. Complex topologies (software RAID, LVM on `/boot`, multi-boot) are deliberately out of scope — see the note at the end of [docs/06-troubleshooting-rollback.md](docs/06-troubleshooting-rollback.md). Proposals to support them should start with an issue, not a pull request.
