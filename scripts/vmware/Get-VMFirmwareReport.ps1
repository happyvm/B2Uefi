<#
.SYNOPSIS
    Rapporte le firmware (BIOS/EFI) et les caracteristiques associees des VM VMware.
.DESCRIPTION
    Necessite une session PowerCLI deja connectee (Connect-VIServer). Liste pour
    chaque VM correspondant au filtre : firmware actuel, version materielle,
    etat d'alimentation, et eligibilite Secure Boot (hardware version >= 13).
.PARAMETER VMName
    Filtre de nom de VM (supporte les wildcards). Par defaut : toutes les VM ("*").
.EXAMPLE
    .\Get-VMFirmwareReport.ps1 -VMName "srv-*"
#>
[CmdletBinding()]
param(
    [string]$VMName = "*"
)

$ErrorActionPreference = 'Stop'

if (-not $global:DefaultVIServers -or $global:DefaultVIServers.Count -eq 0) {
    throw "Aucune session PowerCLI active. Connectez-vous d'abord avec Connect-VIServer -Server <vcenter>."
}

$vms = Get-VM -Name $VMName
if (-not $vms) {
    Write-Warning "Aucune VM ne correspond au filtre '$VMName'."
    return
}

$report = foreach ($vm in $vms) {
    $view = $vm.ExtensionData
    $hwVersionNumber = [int]($view.Config.Version -replace '\D', '')
    [pscustomobject]@{
        Name                 = $vm.Name
        PowerState           = $vm.PowerState
        Firmware             = $view.Config.Firmware
        HardwareVersion      = $view.Config.Version
        SecureBootCapable    = $hwVersionNumber -ge 13
        SecureBootEnabled    = $view.Config.BootOptions.EfiSecureBootEnabled
        MotherboardLayout    = $view.Config.MotherboardLayout
    }
}

$report | Sort-Object Name | Format-Table -AutoSize

$biosCount = ($report | Where-Object { $_.Firmware -eq 'bios' }).Count
Write-Host "`n$biosCount VM(s) encore en firmware BIOS sur $($report.Count) analysee(s)." -ForegroundColor Cyan
