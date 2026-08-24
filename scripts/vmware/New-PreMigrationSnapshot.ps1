<#
.SYNOPSIS
    Creates the pre-migration safety snapshot of a VMware VM.
.DESCRIPTION
    Every conversion script in this repository assumes a restorable snapshot
    exists before the guest disk is touched. This script creates that snapshot
    and reports any snapshot the VM already carries.

    Requires an already-connected PowerCLI session (Connect-VIServer).

    Creating a snapshot is additive, so this script does not prompt by default;
    use -WhatIf to preview. Note that snapshots consume datastore space and
    degrade performance while they exist - delete the snapshot once the
    migration has been validated.
.PARAMETER VMName
    Exact name of the target VM.
.PARAMETER SnapshotName
    Name of the snapshot to create (default: 'pre-uefi-migration').
.PARAMETER Description
    Snapshot description (default: an auto-generated line stating the purpose
    and the creation timestamp).
.PARAMETER IncludeMemory
    Captures the memory state as well. Only meaningful on a powered-on VM; the
    documented workflow converts the guest with the VM running but switches
    firmware with it powered off, so this is usually not needed.
.PARAMETER Quiesce
    Quiesces the guest file system via VMware Tools (recommended when
    snapshotting a powered-on VM carrying a database or similar workload).
.EXAMPLE
    .\New-PreMigrationSnapshot.ps1 -VMName "srv-app01"
.EXAMPLE
    .\New-PreMigrationSnapshot.ps1 -VMName "srv-app01" -Quiesce
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [ValidateNotNullOrEmpty()]
    [string]$SnapshotName = 'pre-uefi-migration',

    [ValidateNotNullOrEmpty()]
    [string]$Description,

    [switch]$IncludeMemory,

    [switch]$Quiesce
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -Name VMware.VimAutomation.Core -ListAvailable)) {
    throw "The VMware.VimAutomation.Core module (PowerCLI) is not installed. Install-Module VMware.PowerCLI."
}
if (-not $global:DefaultVIServers -or $global:DefaultVIServers.Count -eq 0) {
    throw "No active PowerCLI session. Connect first with Connect-VIServer -Server <vcenter>."
}

$vm = Get-VM -Name $VMName -ErrorAction Stop
if (@($vm).Count -gt 1) {
    throw "Multiple VMs match the name '$VMName'. Use an exact, unambiguous name."
}

if (-not $Description) {
    $Description = "Pre BIOS-to-UEFI migration safety snapshot, created $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')."
}

Write-Host "VM '$VMName' - power state: $($vm.PowerState)" -ForegroundColor Cyan

$existing = Get-Snapshot -VM $vm -ErrorAction SilentlyContinue
if ($existing) {
    Write-Warning "This VM already has $(@($existing).Count) snapshot(s):"
    $existing | Select-Object Name, Created, @{N = 'SizeGB'; E = { [math]::Round($_.SizeGB, 2) } } |
        Format-Table -AutoSize
    Write-Warning "Stacking snapshots increases datastore usage and consolidation time. Consider removing stale ones first."
}

if ($IncludeMemory -and $vm.PowerState -ne 'PoweredOn') {
    Write-Warning "-IncludeMemory ignored: the VM is not powered on."
    $IncludeMemory = $false
}
if ($Quiesce -and $vm.PowerState -ne 'PoweredOn') {
    Write-Warning "-Quiesce ignored: the VM is not powered on."
    $Quiesce = $false
}

if (-not $PSCmdlet.ShouldProcess("VM $VMName", "Create snapshot '$SnapshotName'")) {
    return
}

$snapshotParams = @{
    VM          = $vm
    Name        = $SnapshotName
    Description = $Description
    Confirm     = $false
}
if ($IncludeMemory) { $snapshotParams['Memory'] = $true }
if ($Quiesce) { $snapshotParams['Quiesce'] = $true }

$snapshot = New-Snapshot @snapshotParams

Write-Host "`nSnapshot created:" -ForegroundColor Green
$snapshot | Select-Object Name, Created, PowerState, @{N = 'SizeGB'; E = { [math]::Round($_.SizeGB, 2) } } |
    Format-Table -AutoSize

Write-Host @"
You can now proceed with the migration:
  1. Guest conversion  : scripts\windows\Convert-WindowsToUefi.ps1 or scripts/linux/convert-linux-to-uefi.sh
  2. Firmware switch   : scripts\vmware\Set-VMFirmware.ps1 -VMName '$VMName' -Firmware efi
  3. Validation        : scripts\windows\Test-UefiMigrationResult.ps1 or scripts/linux/verify-uefi-migration.sh

To roll back, revert to this snapshot:
  Get-Snapshot -VM '$VMName' -Name '$SnapshotName' | Set-VM -VM '$VMName' -Confirm:`$false

Once the migration is validated, remove the snapshot to reclaim space:
  Get-Snapshot -VM '$VMName' -Name '$SnapshotName' | Remove-Snapshot -Confirm:`$false
"@ -ForegroundColor Cyan
