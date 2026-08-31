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
.PARAMETER OSRelease
    Guest OS release running on the VM, checked against the support matrix in
    docs/07-os-support-matrix.md before anything is touched. Only enforced
    when -Firmware is 'efi' (switching back to 'bios' has no OS support
    constraint). Releases marked "Rebuild" in the matrix (Windows
    2003/2008/2008 R2, RHEL 5/6) cannot boot UEFI in practice and are refused
    unless -AllowUnsupportedOS is passed. Use OtherWindows/OtherLinux for a
    release not covered by the matrix (e.g. Ubuntu/Debian/SUSE, or a Windows
    client OS) - always allowed, with a reminder to verify support manually.
.PARAMETER AllowUnsupportedOS
    Proceeds even though -OSRelease is in the matrix's "Rebuild" bucket. Only
    for a deliberate, informed exception - these releases cannot boot UEFI in
    practice.
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
    .\Invoke-VMwareMigration.ps1 -VMName "srv-app01" -OSRelease WindowsServer2022 -Server vcenter.corp.local -Firmware efi
.EXAMPLE
    .\Invoke-VMwareMigration.ps1 -VMName "srv-app01" -OSRelease RHEL9 -Firmware efi -EnableSecureBoot -Force
    Assumes an existing PowerCLI session (Connect-VIServer already run).
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

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

# --- 0. OS support gate (docs/07-os-support-matrix.md) -------------------------
# Only enforced when switching to EFI - going back to 'bios' has no OS support
# constraint. Verdicts:
#   Supported        - convert in place, no caveats
#   SupportedOffline - convertible, but MBR2GPT is not native: the guest disk
#                       conversion step needs WinPE 1703+ media
#   SupportedButEOL  - technically convertible, but the OS itself is EOL
#   Unsupported      - "Rebuild" bucket: cannot boot UEFI in practice; refused
#                       unless -AllowUnsupportedOS is passed
#   Unknown          - not in the matrix (e.g. Ubuntu/Debian/SUSE, Windows
#                       client) - always allowed, verify manually
$osSupportMatrix = @{
    WindowsServer2003   = @{ Verdict = 'Unsupported'; Detail = 'Ended Jul 2015 - no UEFI boot support at all.' }
    WindowsServer2008   = @{ Verdict = 'Unsupported'; Detail = 'Ended Jan 2020 - guest cannot boot UEFI in practice.' }
    WindowsServer2008R2 = @{ Verdict = 'Unsupported'; Detail = 'Ended Jan 2020 - guest cannot boot UEFI in practice.' }
    WindowsServer2012   = @{ Verdict = 'SupportedOffline'; Detail = 'ESU ends Oct 2026 - MBR2GPT native unavailable; convert the guest disk from WinPE 1703+ media first.' }
    WindowsServer2012R2 = @{ Verdict = 'SupportedOffline'; Detail = 'ESU ends Oct 2026 - MBR2GPT native unavailable; convert the guest disk from WinPE 1703+ media first.' }
    WindowsServer2016   = @{ Verdict = 'SupportedOffline'; Detail = 'Ends Jan 2027 - MBR2GPT native unavailable; convert the guest disk from WinPE 1703+ media first.' }
    WindowsServer2019   = @{ Verdict = 'Supported'; Detail = 'Ends Jan 2029.' }
    WindowsServer2022   = @{ Verdict = 'Supported'; Detail = 'Ends Oct 2031.' }
    WindowsServer2025   = @{ Verdict = 'Supported'; Detail = 'Ends Nov 2034.' }
    RHEL5               = @{ Verdict = 'Unsupported'; Detail = 'EOL Nov 2020 - UEFI boot is not viable on x86_64.' }
    RHEL6               = @{ Verdict = 'Unsupported'; Detail = 'EOL Nov 2020 (ELS ended Jun 2024) - GPT/UEFI path is unreliable.' }
    RHEL7               = @{ Verdict = 'SupportedButEOL'; Detail = 'EOL Jun 2024 (ELS available) - technically convertible, but consider folding into a RHEL 8/9 upgrade instead.' }
    RHEL8               = @{ Verdict = 'Supported'; Detail = 'Maintenance to May 2029.' }
    RHEL9               = @{ Verdict = 'Supported'; Detail = 'Maintenance to May 2032.' }
    RHEL10              = @{ Verdict = 'Supported'; Detail = 'Maintenance to ~May 2035.' }
    OtherWindows        = @{ Verdict = 'Unknown'; Detail = 'Not in docs/07-os-support-matrix.md - verify UEFI/Secure Boot support manually before proceeding.' }
    OtherLinux          = @{ Verdict = 'Unknown'; Detail = 'Not in docs/07-os-support-matrix.md - verify UEFI/Secure Boot support manually before proceeding.' }
}

if ($Firmware -eq 'efi') {
    $osEntry = $osSupportMatrix[$OSRelease]
    switch ($osEntry.Verdict) {
        'Unsupported' {
            if (-not $AllowUnsupportedOS) {
                throw "OSRelease '$OSRelease' cannot boot UEFI in practice: $($osEntry.Detail) See docs/07-os-support-matrix.md. Rebuild the workload on a supported OS instead, or pass -AllowUnsupportedOS to proceed anyway (not recommended)."
            }
            Write-Warning "OSRelease '$OSRelease' is UNSUPPORTED ($($osEntry.Detail)) - proceeding anyway because -AllowUnsupportedOS was passed."
        }
        'SupportedOffline' { Write-Warning "OSRelease '$OSRelease': $($osEntry.Detail)" }
        'SupportedButEOL' { Write-Warning "OSRelease '$OSRelease': $($osEntry.Detail)" }
        'Unknown' { Write-Warning "OSRelease '$OSRelease': $($osEntry.Detail)" }
    }
}

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
Write-Host "OS release: $OSRelease"
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
