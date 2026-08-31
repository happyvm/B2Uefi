<#
.SYNOPSIS
    Runs the full Hyper-V Generation 1 -> Generation 2 migration for one VM:
    report, checkpoint, conversion.
.DESCRIPTION
    Orchestrates the three scripts in this directory, in order:
      1. Get-VMGenerationReport.ps1     - current generation / disk format (read-only)
      2. New-PreMigrationCheckpoint.ps1 - safety checkpoint taken before anything changes
      3. Convert-Gen1ToGen2.ps1         - renames the source VM and creates the new
                                           Generation 2 VM

    Imports the Hyper-V module if it is not already loaded. Unlike the VMware
    scripts in this repository, no remote connection step is needed: every
    hyperv/*.ps1 script here (including this one) operates on the local
    Hyper-V host only.

    PREREQUISITE: the guest OS conversion (MBR -> GPT + UEFI bootloader) must
    already be done BEFORE migrating to Generation 2 - this script does not
    perform it. See scripts/windows/Convert-WindowsToUefi.ps1 or
    scripts/linux/convert-linux-to-uefi.sh, and docs/02-windows-guide.md /
    docs/03-linux-guide.md.

    This creates a new VM and renames the source VM. By default the script
    prompts once for confirmation before the checkpoint and conversion steps
    (SupportsShouldProcess); pass -Force to skip the prompt for unattended
    automation, or -WhatIf to preview without changing anything. If the
    checkpoint step fails, the script stops before ever touching the VM.
.PARAMETER VMName
    Name of the Generation 1 VM to migrate (passed as -SourceVMName to
    Convert-Gen1ToGen2.ps1).
.PARAMETER NewVMName
    Name of the new Generation 2 VM (default: same as VMName).
.PARAMETER OSRelease
    Guest OS release running on the VM, checked against the support matrix in
    docs/07-os-support-matrix.md before anything is touched. Also determines
    the Secure Boot template passed to Convert-Gen1ToGen2.ps1 (Windows vs.
    Linux family). Releases marked "Rebuild" in the matrix (2003/2008/2008 R2,
    RHEL 5/6) have no supported Generation 2 path and are refused unless
    -AllowUnsupportedOS is passed. Use OtherWindows/OtherLinux for a release
    not covered by the matrix (e.g. Ubuntu/Debian/SUSE, or a Windows client
    OS) - always allowed, with a reminder to verify support manually.
.PARAMETER AllowUnsupportedOS
    Proceeds even though -OSRelease is in the matrix's "Rebuild" bucket. Only
    for a deliberate, informed exception - these releases have no supported
    Generation 2 path (there is no firmware to switch to).
.PARAMETER DisableSecureBoot
    Disables Secure Boot (needed for some unsigned Linux kernels). Passed
    through to Convert-Gen1ToGen2.ps1.
.PARAMETER VMPath
    Configuration folder for the new VM (default: the host's default VM path).
    Passed through to Convert-Gen1ToGen2.ps1.
.PARAMETER CheckpointName
    Name of the pre-migration checkpoint (default: 'pre-uefi-migration').
    New-PreMigrationCheckpoint.ps1 appends a timestamp to it.
.PARAMETER Start
    Automatically starts the new Generation 2 VM after creation. Passed
    through to Convert-Gen1ToGen2.ps1.
.PARAMETER SkipReport
    Skips the generation report step.
.PARAMETER SkipCheckpoint
    Skips the safety checkpoint step. NOT recommended - Convert-Gen1ToGen2.ps1
    keeps the source VM intact on its own, but the checkpoint is the only
    rollback point for the guest disk contents.
.PARAMETER Force
    Suppresses the confirmation prompt for the whole run (still shows the
    warning banner first).
.EXAMPLE
    .\Invoke-HyperVMigration.ps1 -VMName "srv-app01" -OSRelease WindowsServer2022
.EXAMPLE
    .\Invoke-HyperVMigration.ps1 -VMName "srv-web01" -OSRelease RHEL9 -Start -Force
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [ValidateNotNullOrEmpty()]
    [string]$NewVMName = $VMName,

    [Parameter(Mandatory)]
    [ValidateSet(
        'WindowsServer2003', 'WindowsServer2008', 'WindowsServer2008R2',
        'WindowsServer2012', 'WindowsServer2012R2', 'WindowsServer2016',
        'WindowsServer2019', 'WindowsServer2022', 'WindowsServer2025',
        'RHEL5', 'RHEL6', 'RHEL7', 'RHEL8', 'RHEL9', 'RHEL10',
        'OtherWindows', 'OtherLinux'
    )]
    [string]$OSRelease,

    [switch]$AllowUnsupportedOS,

    [switch]$DisableSecureBoot,

    [ValidateNotNullOrEmpty()]
    [string]$VMPath,

    [ValidateNotNullOrEmpty()]
    [string]$CheckpointName = 'pre-uefi-migration',

    [switch]$Start,

    [switch]$SkipReport,

    [switch]$SkipCheckpoint,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- 0. OS support gate (docs/07-os-support-matrix.md) -------------------------
# Verdicts:
#   Supported        - convert in place, no caveats
#   SupportedOffline - convertible, but MBR2GPT is not native: the guest disk
#                       conversion step needs WinPE 1703+ media
#   SupportedButEOL  - technically convertible, but the OS itself is EOL
#   Unsupported      - "Rebuild" bucket: no supported Generation 2 path at all
#                       (there is no firmware to switch to); refused unless
#                       -AllowUnsupportedOS is passed
#   Unknown          - not in the matrix (e.g. Ubuntu/Debian/SUSE, Windows
#                       client) - always allowed, verify manually
$osSupportMatrix = @{
    WindowsServer2003   = @{ Family = 'Windows'; Verdict = 'Unsupported'; Detail = 'Ended Jul 2015 - no UEFI boot support at all.' }
    WindowsServer2008   = @{ Family = 'Windows'; Verdict = 'Unsupported'; Detail = 'Ended Jan 2020 - not a supported Hyper-V Generation 2 guest.' }
    WindowsServer2008R2 = @{ Family = 'Windows'; Verdict = 'Unsupported'; Detail = 'Ended Jan 2020 - not a supported Hyper-V Generation 2 guest.' }
    WindowsServer2012   = @{ Family = 'Windows'; Verdict = 'SupportedOffline'; Detail = 'ESU ends Oct 2026 - MBR2GPT native unavailable; convert the guest disk from WinPE 1703+ media first.' }
    WindowsServer2012R2 = @{ Family = 'Windows'; Verdict = 'SupportedOffline'; Detail = 'ESU ends Oct 2026 - MBR2GPT native unavailable; convert the guest disk from WinPE 1703+ media first.' }
    WindowsServer2016   = @{ Family = 'Windows'; Verdict = 'SupportedOffline'; Detail = 'Ends Jan 2027 - MBR2GPT native unavailable; convert the guest disk from WinPE 1703+ media first.' }
    WindowsServer2019   = @{ Family = 'Windows'; Verdict = 'Supported'; Detail = 'Ends Jan 2029.' }
    WindowsServer2022   = @{ Family = 'Windows'; Verdict = 'Supported'; Detail = 'Ends Oct 2031.' }
    WindowsServer2025   = @{ Family = 'Windows'; Verdict = 'Supported'; Detail = 'Ends Nov 2034.' }
    RHEL5               = @{ Family = 'Linux'; Verdict = 'Unsupported'; Detail = 'EOL Nov 2020 - UEFI boot is not viable on x86_64.' }
    RHEL6               = @{ Family = 'Linux'; Verdict = 'Unsupported'; Detail = 'EOL Nov 2020 (ELS ended Jun 2024) - GPT/UEFI path is unreliable; no Generation 2 path (needs 7.0+).' }
    RHEL7               = @{ Family = 'Linux'; Verdict = 'SupportedButEOL'; Detail = 'EOL Jun 2024 (ELS available) - technically convertible, but consider folding into a RHEL 8/9 upgrade instead.' }
    RHEL8               = @{ Family = 'Linux'; Verdict = 'Supported'; Detail = 'Maintenance to May 2029.' }
    RHEL9               = @{ Family = 'Linux'; Verdict = 'Supported'; Detail = 'Maintenance to May 2032.' }
    RHEL10              = @{ Family = 'Linux'; Verdict = 'Supported'; Detail = 'Maintenance to ~May 2035.' }
    OtherWindows        = @{ Family = 'Windows'; Verdict = 'Unknown'; Detail = 'Not in docs/07-os-support-matrix.md - verify UEFI/Secure Boot/Generation 2 support manually before proceeding.' }
    OtherLinux          = @{ Family = 'Linux'; Verdict = 'Unknown'; Detail = 'Not in docs/07-os-support-matrix.md - verify UEFI/Secure Boot/Generation 2 support manually before proceeding.' }
}

$osEntry = $osSupportMatrix[$OSRelease]
switch ($osEntry.Verdict) {
    'Unsupported' {
        if (-not $AllowUnsupportedOS) {
            throw "OSRelease '$OSRelease' has no supported Generation 2 path: $($osEntry.Detail) See docs/07-os-support-matrix.md. Rebuild the workload on a supported OS instead, or pass -AllowUnsupportedOS to proceed anyway (not recommended)."
        }
        Write-Warning "OSRelease '$OSRelease' is UNSUPPORTED ($($osEntry.Detail)) - proceeding anyway because -AllowUnsupportedOS was passed."
    }
    'SupportedOffline' { Write-Warning "OSRelease '$OSRelease': $($osEntry.Detail)" }
    'SupportedButEOL' { Write-Warning "OSRelease '$OSRelease': $($osEntry.Detail)" }
    'Unknown' { Write-Warning "OSRelease '$OSRelease': $($osEntry.Detail)" }
}
$OSType = $osEntry.Family

$scriptDir = $PSScriptRoot
$reportScript = Join-Path $scriptDir 'Get-VMGenerationReport.ps1'
$checkpointScript = Join-Path $scriptDir 'New-PreMigrationCheckpoint.ps1'
$convertScript = Join-Path $scriptDir 'Convert-Gen1ToGen2.ps1'
foreach ($s in @($reportScript, $checkpointScript, $convertScript)) {
    if (-not (Test-Path -LiteralPath $s)) {
        throw "Required script not found: $s (this script must stay in scripts/hyperv/, alongside the others)."
    }
}

# --- 1. Hyper-V module ---------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw "The Hyper-V PowerShell module is required on this machine (Install-WindowsFeature RSAT-Hyper-V-Tools, or run locally on the host)."
}
if (-not (Get-Module -Name Hyper-V)) {
    Write-Host "Importing Hyper-V module..." -ForegroundColor Cyan
    Import-Module Hyper-V -ErrorAction Stop
}

Write-Host "`n=== Hyper-V Generation 1 -> Generation 2 migration: $VMName -> $NewVMName ===" -ForegroundColor Cyan
Write-Host "OS release: $OSRelease ($OSType family)$(if ($DisableSecureBoot) { ' - Secure Boot disabled' })"
Write-Warning "This assumes the guest OS disk has ALREADY been converted from MBR to GPT with a UEFI bootloader. Migrating a guest that isn't ready to Generation 2 will make it fail to boot."

# --- 2. Step 1/3: report (always runs, read-only, informational) --------------
if (-not $SkipReport) {
    Write-Host "`n--- Step 1/3: generation report ---" -ForegroundColor Cyan
    try {
        & $reportScript -VMName $VMName
    } catch {
        throw "Generation report failed for '$VMName': $($_.Exception.Message)"
    }
} else {
    Write-Host "`n--- Step 1/3: generation report (skipped: -SkipReport) ---" -ForegroundColor Yellow
}

if ($Force) {
    $ConfirmPreference = 'None'
}

$actionDescription = "Checkpoint + migrate to Generation 2"
if ($NewVMName -ne $VMName) { $actionDescription += " as '$NewVMName'" }
if (-not $PSCmdlet.ShouldProcess("VM $VMName", $actionDescription)) {
    Write-Host "`nMigration steps not executed." -ForegroundColor Yellow
    return
}

# --- 3. Step 2/3: pre-migration checkpoint --------------------------------------
if (-not $SkipCheckpoint) {
    Write-Host "`n--- Step 2/3: pre-migration checkpoint ---" -ForegroundColor Cyan
    try {
        & $checkpointScript -VMName $VMName -CheckpointName $CheckpointName -Confirm:$false
    } catch {
        throw "Pre-migration checkpoint failed for '$VMName': $($_.Exception.Message). Aborting before touching the VM."
    }
} else {
    Write-Warning "Step 2/3: pre-migration checkpoint SKIPPED (-SkipCheckpoint) - no rollback point will exist for this run."
}

# --- 4. Step 3/3: Generation 1 -> Generation 2 conversion -----------------------
Write-Host "`n--- Step 3/3: Generation 1 -> Generation 2 conversion ---" -ForegroundColor Cyan
$convertParams = @{
    SourceVMName = $VMName
    NewVMName    = $NewVMName
    OSType       = $OSType
    Confirm      = $false
}
if ($DisableSecureBoot) { $convertParams['DisableSecureBoot'] = $true }
if ($VMPath) { $convertParams['VMPath'] = $VMPath }
if ($Start) { $convertParams['Start'] = $true }

& $convertScript @convertParams

Write-Host "`n=== Migration steps complete for '$NewVMName'. ===" -ForegroundColor Green
Write-Host @"

Next steps (NOT performed by this script):
  1. Validate that '$NewVMName' boots and behaves correctly.
  2. Once validated, remove the legacy VM (the VHDX files are NOT touched)
     and the checkpoint:
       Remove-VM -Name '$VMName-gen1-legacy' -Force
       Get-VMSnapshot -VMName '$NewVMName' | Remove-VMSnapshot
  3. If something goes wrong, see docs/06-troubleshooting-rollback.md -
     Restore-Gen1VM.ps1 can roll back the VM container.
"@ -ForegroundColor Cyan
