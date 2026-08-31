<#
.SYNOPSIS
    Runs the full VMware-side BIOS -> UEFI migration for one VM: report, snapshot,
    firmware switch.
.DESCRIPTION
    Orchestrates the three scripts in this directory, in order:
      1. Get-VMFirmwareReport.ps1     - current firmware / hardware version (read-only)
      2. New-PreMigrationSnapshot.ps1 - safety snapshot taken before anything changes
      3. Set-VMFirmware.ps1           - switches the VM firmware to the target value

    Imports VMware.VimAutomation.Core (PowerCLI) if it is not already loaded, and
    connects to vCenter/ESXi with Connect-VIServer if no session is active and
    -Server is supplied. If a session is already active (Connect-VIServer was run
    beforehand), -Server can be omitted.

    PREREQUISITE: the guest OS conversion (MBR -> GPT + UEFI bootloader) must
    already be done BEFORE switching firmware to EFI - this script does not
    perform it. See scripts/windows/Convert-WindowsToUefi.ps1 or
    scripts/linux/convert-linux-to-uefi.sh, and docs/02-windows-guide.md /
    docs/03-linux-guide.md.

    This changes how the VM boots. By default the script prompts once for
    confirmation before the snapshot and firmware steps (SupportsShouldProcess);
    pass -Force to skip the prompt for unattended automation, or -WhatIf to
    preview without changing anything. If the snapshot step fails, the script
    stops before ever touching the firmware.
.PARAMETER VMName
    Exact name of the target VM.
.PARAMETER Firmware
    'efi' or 'bios' (default: 'efi').
.PARAMETER EnableSecureBoot
    Also enables Secure Boot when switching to EFI. Passed through to
    Set-VMFirmware.ps1 (requires hardware version >= 13).
.PARAMETER Server
    vCenter or ESXi host to connect to. Omit if a PowerCLI session is already
    active.
.PARAMETER Credential
    Credential for -Server. Omit to be prompted interactively by Connect-VIServer.
.PARAMETER SnapshotName
    Name of the pre-migration snapshot (default: 'pre-uefi-migration').
.PARAMETER Quiesce
    Quiesces the guest file system when taking the snapshot (recommended for a
    powered-on VM carrying a database or similar workload). Passed through to
    New-PreMigrationSnapshot.ps1.
.PARAMETER SkipReport
    Skips the firmware report step.
.PARAMETER SkipSnapshot
    Skips the safety snapshot step. NOT recommended - only for a VM already
    covered by another rollback path (e.g. a storage-level snapshot).
.PARAMETER Force
    Suppresses the confirmation prompt for the whole run (still shows the
    warning banner first).
.EXAMPLE
    .\Invoke-VMwareMigration.ps1 -VMName "srv-app01" -Server vcenter.corp.local -Firmware efi
.EXAMPLE
    .\Invoke-VMwareMigration.ps1 -VMName "srv-app01" -Firmware efi -EnableSecureBoot -Force
    Assumes an existing PowerCLI session (Connect-VIServer already run).
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [ValidateSet('efi', 'bios')]
    [string]$Firmware = 'efi',

    [switch]$EnableSecureBoot,

    [ValidateNotNullOrEmpty()]
    [string]$Server,

    [System.Management.Automation.PSCredential]$Credential,

    [ValidateNotNullOrEmpty()]
    [string]$SnapshotName = 'pre-uefi-migration',

    [switch]$Quiesce,

    [switch]$SkipReport,

    [switch]$SkipSnapshot,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$reportScript = Join-Path $scriptDir 'Get-VMFirmwareReport.ps1'
$snapshotScript = Join-Path $scriptDir 'New-PreMigrationSnapshot.ps1'
$firmwareScript = Join-Path $scriptDir 'Set-VMFirmware.ps1'
foreach ($s in @($reportScript, $snapshotScript, $firmwareScript)) {
    if (-not (Test-Path -LiteralPath $s)) {
        throw "Required script not found: $s (this script must stay in scripts/vmware/, alongside the others)."
    }
}

# --- 1. PowerCLI module -------------------------------------------------------
if (-not (Get-Module -Name VMware.VimAutomation.Core -ListAvailable)) {
    throw "The VMware.VimAutomation.Core module (PowerCLI) is not installed. Install-Module VMware.PowerCLI."
}
if (-not (Get-Module -Name VMware.VimAutomation.Core)) {
    Write-Host "Importing VMware.VimAutomation.Core..." -ForegroundColor Cyan
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
}

# --- 2. vCenter/ESXi connection ------------------------------------------------
$viServersVar = Get-Variable -Name DefaultVIServers -Scope Global -ErrorAction SilentlyContinue
$viServers = if ($viServersVar) { $viServersVar.Value } else { $null }
if (-not $viServers -or $viServers.Count -eq 0) {
    if (-not $Server) {
        throw "No active PowerCLI session and no -Server given. Either run Connect-VIServer first, or pass -Server (and optionally -Credential)."
    }
    Write-Host "Connecting to '$Server'..." -ForegroundColor Cyan
    $connectParams = @{ Server = $Server; ErrorAction = 'Stop' }
    if ($Credential) { $connectParams['Credential'] = $Credential }
    Connect-VIServer @connectParams | Out-Null
} elseif ($Server -and ($viServers.Name -notcontains $Server)) {
    Write-Warning "Already connected to $($viServers.Name -join ', '), which does not include -Server '$Server'. Using the existing session(s) - pass no -Server to silence this warning, or Disconnect-VIServer first to reconnect elsewhere."
}

Write-Host "`n=== VMware BIOS -> UEFI migration: $VMName ===" -ForegroundColor Cyan
Write-Host "Target firmware: $Firmware$(if ($EnableSecureBoot) { ' (+ Secure Boot)' })"
Write-Warning "This assumes the guest OS disk has ALREADY been converted from MBR to GPT with a UEFI bootloader. Switching firmware on a guest that isn't ready will make the VM fail to boot."

# --- 3. Step 1/3: report (always runs, read-only, informational) --------------
if (-not $SkipReport) {
    Write-Host "`n--- Step 1/3: firmware report ---" -ForegroundColor Cyan
    try {
        & $reportScript -VMName $VMName
    } catch {
        throw "Firmware report failed for '$VMName': $($_.Exception.Message)"
    }
} else {
    Write-Host "`n--- Step 1/3: firmware report (skipped: -SkipReport) ---" -ForegroundColor Yellow
}

if ($Force) {
    $ConfirmPreference = 'None'
}

$actionDescription = "Snapshot + set firmware=$Firmware"
if ($EnableSecureBoot) { $actionDescription += ' + Secure Boot' }
if (-not $PSCmdlet.ShouldProcess("VM $VMName", $actionDescription)) {
    Write-Host "`nMigration steps not executed." -ForegroundColor Yellow
    return
}

# --- 4. Step 2/3: pre-migration snapshot ---------------------------------------
if (-not $SkipSnapshot) {
    Write-Host "`n--- Step 2/3: pre-migration snapshot ---" -ForegroundColor Cyan
    $snapshotParams = @{
        VMName       = $VMName
        SnapshotName = $SnapshotName
        Confirm      = $false
    }
    if ($Quiesce) { $snapshotParams['Quiesce'] = $true }
    try {
        & $snapshotScript @snapshotParams
    } catch {
        throw "Pre-migration snapshot failed for '$VMName': $($_.Exception.Message). Aborting before touching the firmware."
    }
} else {
    Write-Warning "Step 2/3: pre-migration snapshot SKIPPED (-SkipSnapshot) - no VMware-level rollback point will exist for this run."
}

# --- 5. Step 3/3: firmware switch ----------------------------------------------
Write-Host "`n--- Step 3/3: firmware switch ---" -ForegroundColor Cyan
$firmwareParams = @{
    VMName   = $VMName
    Firmware = $Firmware
    Confirm  = $false
}
if ($EnableSecureBoot) { $firmwareParams['EnableSecureBoot'] = $true }

& $firmwareScript @firmwareParams

Write-Host "`n=== Migration steps complete for '$VMName'. ===" -ForegroundColor Green
Write-Host @"

Next steps (NOT performed by this script):
  1. Power on '$VMName' and validate the UEFI boot (see docs/06-troubleshooting-rollback.md if it fails).
  2. Once validated, remove the safety snapshot to reclaim datastore space:
       Get-Snapshot -VM '$VMName' -Name '$SnapshotName' | Remove-Snapshot -Confirm:`$false
"@ -ForegroundColor Cyan
