<#
.SYNOPSIS
    Creates the pre-migration safety checkpoint of a Hyper-V VM.
.DESCRIPTION
    Every conversion script in this repository assumes a restorable checkpoint
    exists before the guest disk is touched. This script creates that checkpoint
    and reports any checkpoint the VM already carries.

    Creating a checkpoint is additive, so this script does not prompt by
    default; use -WhatIf to preview. Note that checkpoints keep differencing
    disks growing on the host - delete the checkpoint once the migration has
    been validated.

    A checkpoint protects the VM configuration and disk contents, but it does
    NOT protect against the Generation 1 -> Generation 2 migration path, which
    creates a separate VM. Convert-Gen1ToGen2.ps1 keeps the source VM intact
    (renamed '-gen1-legacy') for that purpose.
.PARAMETER VMName
    Exact name of the target VM.
.PARAMETER CheckpointName
    Name of the checkpoint to create (default: 'pre-uefi-migration').
.EXAMPLE
    .\New-PreMigrationCheckpoint.ps1 -VMName "srv-app01"
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [ValidateNotNullOrEmpty()]
    [string]$CheckpointName = 'pre-uefi-migration'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw "The Hyper-V PowerShell module is required on this machine (Install-WindowsFeature RSAT-Hyper-V-Tools, or run locally on the host)."
}
Import-Module Hyper-V -ErrorAction Stop

$vm = Get-VM -Name $VMName -ErrorAction Stop
if (@($vm).Count -gt 1) {
    throw "Multiple VMs match the name '$VMName'. Use an exact, unambiguous name."
}

Write-Host "VM '$VMName' - state: $($vm.State), generation: $($vm.Generation)" -ForegroundColor Cyan

if (-not $vm.CheckpointType -or $vm.CheckpointType -eq 'Disabled') {
    throw "Checkpoints are disabled on VM '$VMName' (CheckpointType: $($vm.CheckpointType)). Enable them with: Set-VM -Name '$VMName' -CheckpointType Standard"
}
Write-Host "Checkpoint type: $($vm.CheckpointType)"

$existing = Get-VMSnapshot -VMName $VMName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Warning "This VM already has $(@($existing).Count) checkpoint(s):"
    $existing | Select-Object Name, SnapshotType, CreationTime | Format-Table -AutoSize
    Write-Warning "Stacking checkpoints grows the differencing disk chain and lengthens merge time. Consider removing stale ones first."
}

$checkpointFullName = "$CheckpointName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

if (-not $PSCmdlet.ShouldProcess("VM $VMName", "Create checkpoint '$checkpointFullName'")) {
    return
}

Checkpoint-VM -Name $VMName -SnapshotName $checkpointFullName -Confirm:$false

$created = Get-VMSnapshot -VMName $VMName -Name $checkpointFullName
Write-Host "`nCheckpoint created:" -ForegroundColor Green
$created | Select-Object Name, SnapshotType, CreationTime | Format-Table -AutoSize

Write-Host @"
You can now proceed with the migration:
  1. Guest conversion  : scripts\windows\Convert-WindowsToUefi.ps1 or scripts/linux/convert-linux-to-uefi.sh
  2. Gen 2 migration   : scripts\hyperv\Convert-Gen1ToGen2.ps1 -SourceVMName '$VMName' -OSType <Windows|Linux>
  3. Validation        : scripts\windows\Test-UefiMigrationResult.ps1 or scripts/linux/verify-uefi-migration.sh

To roll back to this checkpoint:
  Restore-VMSnapshot -VMName '$VMName' -Name '$checkpointFullName' -Confirm:`$false

Once the migration is validated, remove the checkpoint to merge the disk chain:
  Remove-VMSnapshot -VMName '$VMName' -Name '$checkpointFullName'
"@ -ForegroundColor Cyan
