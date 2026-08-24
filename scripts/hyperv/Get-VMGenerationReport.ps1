<#
.SYNOPSIS
    Rapporte la generation (1/2) de chaque VM Hyper-V de l'hote.
.DESCRIPTION
    Signale les VM Generation 1, candidates a une migration vers Generation 2,
    ainsi que le format de leur(s) disque(s) (VHD/VHDX), sachant que Generation 2
    n'accepte que du VHDX.
.PARAMETER VMName
    Filtre de nom de VM (supporte les wildcards). Par defaut : toutes les VM.
.EXAMPLE
    .\Get-VMGenerationReport.ps1
#>
[CmdletBinding()]
param(
    [string]$VMName = "*"
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw "Le module PowerShell Hyper-V est requis sur cette machine (Install-WindowsFeature RSAT-Hyper-V-Tools ou executer localement sur l'hote)."
}
Import-Module Hyper-V -ErrorAction Stop

$vms = Get-VM -Name $VMName
if (-not $vms) {
    Write-Warning "Aucune VM ne correspond au filtre '$VMName'."
    return
}

$report = foreach ($vm in $vms) {
    $disks = Get-VMHardDiskDrive -VMName $vm.Name
    $diskFormats = $disks | ForEach-Object { [System.IO.Path]::GetExtension($_.Path).TrimStart('.').ToUpper() }
    $needsVhdxConversion = ($vm.Generation -eq 1) -and ($diskFormats -contains 'VHD')

    [pscustomobject]@{
        Name                  = $vm.Name
        Generation            = $vm.Generation
        State                 = $vm.State
        DiskFormats           = ($diskFormats -join ', ')
        DiskCount             = $disks.Count
        RequiresVhdxConvert   = $needsVhdxConversion
        MigrationCandidate    = ($vm.Generation -eq 1)
    }
}

$report | Sort-Object Name | Format-Table -AutoSize

$gen1Count = ($report | Where-Object { $_.Generation -eq 1 }).Count
$vhdCount = ($report | Where-Object { $_.RequiresVhdxConvert }).Count
Write-Host "`n$gen1Count VM(s) en Generation 1 sur $($report.Count) analysee(s)." -ForegroundColor Cyan
if ($vhdCount -gt 0) {
    Write-Host "$vhdCount VM(s) necessitent une conversion VHD -> VHDX avant migration (Convert-VHD)." -ForegroundColor Yellow
}
Write-Host "`nRappel : avant Convert-Gen1ToGen2.ps1, chaque VM Gen 1 candidate doit d'abord avoir son disque invite converti MBR->GPT (scripts/windows ou scripts/linux)." -ForegroundColor Cyan
