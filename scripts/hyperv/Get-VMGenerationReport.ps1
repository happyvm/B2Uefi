<#
.SYNOPSIS
    Reports the generation (1/2) of every VM on the Hyper-V host.
.DESCRIPTION
    Flags Generation 1 VMs as candidates for migration to Generation 2, along
    with their disk format(s) (VHD/VHDX), since Generation 2 only accepts VHDX.
    Read-only.
.PARAMETER VMName
    VM name filter (wildcards supported). Default: all VMs.
.EXAMPLE
    .\Get-VMGenerationReport.ps1
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$VMName = "*"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw "The Hyper-V PowerShell module is required on this machine (Install-WindowsFeature RSAT-Hyper-V-Tools, or run locally on the host)."
}
Import-Module Hyper-V -ErrorAction Stop

$vms = Get-VM -Name $VMName -ErrorAction Stop
if (-not $vms) {
    Write-Warning "No VM matches the filter '$VMName'."
    return
}

$report = foreach ($vm in $vms) {
    $disks = @(Get-VMHardDiskDrive -VMName $vm.Name)
    $diskFormats = $disks | ForEach-Object { [System.IO.Path]::GetExtension($_.Path).TrimStart('.').ToUpper() }
    $needsVhdxConversion = ($vm.Generation -eq 1) -and ($diskFormats -contains 'VHD')

    [pscustomobject]@{
        Name                = $vm.Name
        Generation          = $vm.Generation
        State               = $vm.State
        DiskFormats         = ($diskFormats -join ', ')
        DiskCount           = $disks.Count
        RequiresVhdxConvert = $needsVhdxConversion
        MigrationCandidate  = ($vm.Generation -eq 1)
    }
}

$report | Sort-Object Name | Format-Table -AutoSize

$gen1Count = @($report | Where-Object { $_.Generation -eq 1 }).Count
$vhdCount = @($report | Where-Object { $_.RequiresVhdxConvert }).Count
Write-Host "`n$gen1Count of $(@($report).Count) analyzed VM(s) are Generation 1." -ForegroundColor Cyan
if ($vhdCount -gt 0) {
    Write-Host "$vhdCount VM(s) require a VHD -> VHDX conversion before migration (Convert-VHD)." -ForegroundColor Yellow
}
Write-Host "`nReminder: before running Convert-Gen1ToGen2.ps1, each candidate Gen 1 VM must first have its guest disk converted from MBR to GPT (scripts/windows or scripts/linux)." -ForegroundColor Cyan
