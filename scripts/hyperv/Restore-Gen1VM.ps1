<#
.SYNOPSIS
    Rolls back a Generation 1 -> Generation 2 migration on Hyper-V.
.DESCRIPTION
    Undoes what Convert-Gen1ToGen2.ps1 did: stops and removes the Generation 2
    VM, then renames the preserved '-gen1-legacy' VM back to its original name.

    The VHDX files are never deleted - Remove-VM only detaches them. Both VMs
    reference the same VHDX, so the disk contents are whatever the migration
    left behind.

    IMPORTANT: this rolls back the VM *container*, not the guest disk. If the
    guest disk was already converted from MBR to GPT, the restored Generation 1
    (BIOS) VM will not boot from it either - in that case restore the
    pre-migration checkpoint instead (see docs/06-troubleshooting-rollback.md).

    Safety: the script verifies the legacy VM exists and is Generation 1 BEFORE
    removing anything, so a missing legacy VM aborts the rollback instead of
    leaving you with neither VM.

    This removes a VM. By default the script prompts for confirmation
    (SupportsShouldProcess); pass -Force to skip the prompt, or -WhatIf to
    preview without changing anything.
.PARAMETER VMName
    Original VM name - the name currently carried by the Generation 2 VM, and
    the name the legacy VM will be renamed back to.
.PARAMETER LegacyVMName
    Name of the preserved Generation 1 VM (default: '<VMName>-gen1-legacy',
    matching what Convert-Gen1ToGen2.ps1 creates).
.PARAMETER Start
    Starts the restored Generation 1 VM after the rollback.
.PARAMETER Force
    Suppresses the confirmation prompt.
.EXAMPLE
    .\Restore-Gen1VM.ps1 -VMName "srv-app01"
.EXAMPLE
    .\Restore-Gen1VM.ps1 -VMName "srv-app01" -Start -Force
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [ValidateNotNullOrEmpty()]
    [string]$LegacyVMName,

    [switch]$Start,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw "The Hyper-V PowerShell module is required on this machine (Install-WindowsFeature RSAT-Hyper-V-Tools, or run locally on the host)."
}
Import-Module Hyper-V -ErrorAction Stop

if (-not $LegacyVMName) {
    $LegacyVMName = "$VMName-gen1-legacy"
}

# --- Verify the rollback target exists FIRST -------------------------------
# Removing the Gen 2 VM before confirming the legacy VM is recoverable would
# leave the operator with nothing to fall back to.
$legacyVM = Get-VM -Name $LegacyVMName -ErrorAction SilentlyContinue
if (-not $legacyVM) {
    throw "Legacy VM '$LegacyVMName' not found. Nothing to roll back to - aborting before touching '$VMName'. If the legacy VM was renamed or removed, restore the pre-migration checkpoint instead (docs/06-troubleshooting-rollback.md)."
}
if (@($legacyVM).Count -gt 1) {
    throw "Multiple VMs match '$LegacyVMName'. Use an exact, unambiguous name."
}
if ($legacyVM.Generation -ne 1) {
    throw "VM '$LegacyVMName' is Generation $($legacyVM.Generation), expected Generation 1. Refusing to proceed - verify you are rolling back the right VM."
}

$gen2VM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($gen2VM -and @($gen2VM).Count -gt 1) {
    throw "Multiple VMs match '$VMName'. Use an exact, unambiguous name."
}

Write-Host "=== Generation 2 -> Generation 1 rollback ===" -ForegroundColor Cyan
if ($gen2VM) {
    Write-Host "Gen 2 VM to remove : $($gen2VM.Name) (generation $($gen2VM.Generation), state $($gen2VM.State))"
} else {
    Write-Host "Gen 2 VM to remove : none found (already removed - only the rename will run)" -ForegroundColor Yellow
}
Write-Host "Legacy VM to restore: $($legacyVM.Name) (generation $($legacyVM.Generation), state $($legacyVM.State)) -> '$VMName'"

if ($gen2VM) {
    $gen2Disks = Get-VMHardDiskDrive -VMName $gen2VM.Name -ErrorAction SilentlyContinue
    if ($gen2Disks) {
        Write-Host "Disks (kept on disk, only detached): $(($gen2Disks | ForEach-Object { $_.Path }) -join ', ')"
    }
}

if ($Force) {
    $ConfirmPreference = 'None'
}

if (-not $PSCmdlet.ShouldProcess("$VMName", "Remove the Generation 2 VM and restore '$LegacyVMName'")) {
    return
}

# --- Stop and remove the Generation 2 VM ------------------------------------
if ($gen2VM) {
    if ($gen2VM.State -ne 'Off') {
        Write-Host "`nStopping '$($gen2VM.Name)'..." -ForegroundColor Yellow
        Stop-VM -Name $gen2VM.Name -TurnOff -Force -Confirm:$false
    }

    Write-Host "Removing the Generation 2 VM '$($gen2VM.Name)' (VHDX files are preserved)..." -ForegroundColor Yellow
    Remove-VM -Name $gen2VM.Name -Force -Confirm:$false
}

# --- Restore the legacy VM name ---------------------------------------------
Write-Host "Renaming '$LegacyVMName' back to '$VMName'..." -ForegroundColor Cyan
Rename-VM -Name $LegacyVMName -NewName $VMName

if ($Start) {
    Write-Host "Starting '$VMName'..." -ForegroundColor Cyan
    Start-VM -Name $VMName
} else {
    Write-Host "`nVM not started (use -Start, or run 'Start-VM -Name $VMName')." -ForegroundColor Yellow
}

Write-Host "`nRollback complete." -ForegroundColor Green
Write-Host @"

Reminder: this restored the Generation 1 (BIOS) VM container. If the guest disk
was already converted from MBR to GPT, this VM will NOT boot from it - restore
the pre-migration checkpoint instead:

  Get-VMSnapshot -VMName '$VMName'
  Restore-VMSnapshot -VMName '$VMName' -Name '<checkpoint>' -Confirm:`$false

See docs/06-troubleshooting-rollback.md for the full decision tree.
"@ -ForegroundColor Cyan
