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
.PARAMETER OSType
    'Windows' or 'Linux' - determines the Secure Boot template applied.
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
    .\Invoke-HyperVMigration.ps1 -VMName "srv-app01" -OSType Windows
.EXAMPLE
    .\Invoke-HyperVMigration.ps1 -VMName "srv-web01" -OSType Linux -Start -Force
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [ValidateNotNullOrEmpty()]
    [string]$NewVMName = $VMName,

    [Parameter(Mandatory)]
    [ValidateSet('Windows', 'Linux')]
    [string]$OSType,

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
Write-Host "OS type: $OSType$(if ($DisableSecureBoot) { ' (Secure Boot disabled)' })"
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
