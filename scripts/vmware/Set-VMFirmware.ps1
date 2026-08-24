<#
.SYNOPSIS
    Bascule le firmware d'une VM VMware entre BIOS et EFI.
.DESCRIPTION
    Necessite une session PowerCLI deja connectee (Connect-VIServer). La VM doit
    etre eteinte. Le script applique Firmware via ReconfigVM_Task et ajuste
    motherboardLayout en consequence (acpiHostBridges pour EFI, i440bxHostBridge
    pour BIOS).
    IMPORTANT : la conversion du disque invite (MBR->GPT + bootloader UEFI) doit
    avoir ete effectuee AVANT de basculer une VM de BIOS vers EFI, sinon la VM ne
    demarrera plus. Voir docs/02-windows-guide.md / docs/03-linux-guide.md.
.PARAMETER VMName
    Nom exact de la VM cible.
.PARAMETER Firmware
    'efi' ou 'bios'.
.PARAMETER EnableSecureBoot
    Active Secure Boot en plus du passage en EFI (necessite hardware version >= 13
    et un bootloader/kernel signe cote invite).
.EXAMPLE
    .\Set-VMFirmware.ps1 -VMName "srv-app01" -Firmware efi
.EXAMPLE
    .\Set-VMFirmware.ps1 -VMName "srv-app01" -Firmware efi -EnableSecureBoot
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$VMName,

    [Parameter(Mandatory)]
    [ValidateSet('efi', 'bios')]
    [string]$Firmware,

    [switch]$EnableSecureBoot
)

$ErrorActionPreference = 'Stop'

if (-not $global:DefaultVIServers -or $global:DefaultVIServers.Count -eq 0) {
    throw "Aucune session PowerCLI active. Connectez-vous d'abord avec Connect-VIServer -Server <vcenter>."
}

if ($EnableSecureBoot -and $Firmware -ne 'efi') {
    throw "Secure Boot requiert -Firmware efi."
}

$vm = Get-VM -Name $VMName -ErrorAction Stop
if ($vm.PowerState -ne 'PoweredOff') {
    throw "La VM '$VMName' doit etre eteinte avant de changer son firmware (etat actuel : $($vm.PowerState)). Ce script ne l'arrete pas automatiquement."
}

$currentFirmware = $vm.ExtensionData.Config.Firmware
Write-Host "VM '$VMName' - firmware actuel : $currentFirmware -> cible : $Firmware" -ForegroundColor Cyan

if ($EnableSecureBoot) {
    $hwVersion = [int]($vm.ExtensionData.Config.Version -replace '\D', '')
    if ($hwVersion -lt 13) {
        throw "Secure Boot necessite hardware version >= 13 (version actuelle : $($vm.ExtensionData.Config.Version)). Mettez a niveau le hardware de la VM avant de continuer."
    }
}

if (-not $PSCmdlet.ShouldProcess("VM $VMName", "Definir firmware=$Firmware" + $(if ($EnableSecureBoot) { ' + Secure Boot' } else { '' }))) {
    return
}

$spec = New-Object VMware.Vim.VirtualMachineConfigSpec
$spec.Firmware = [VMware.Vim.GuestOsDescriptorFirmwareType]::$Firmware
$spec.motherboardLayout = if ($Firmware -eq 'efi') { 'acpiHostBridges' } else { 'i440bxHostBridge' }

if ($Firmware -eq 'efi') {
    $bootOptions = New-Object VMware.Vim.VirtualMachineBootOptions
    $bootOptions.EfiSecureBootEnabled = [bool]$EnableSecureBoot
    $spec.BootOptions = $bootOptions
}

$task = $vm.ExtensionData.ReconfigVM_Task($spec)
$taskView = Get-Task -Id ("Task-$($task.Value)")
$taskView | Wait-Task | Out-Null

$vm = Get-VM -Name $VMName
Write-Host "Termine. Firmware actuel : $($vm.ExtensionData.Config.Firmware)" -ForegroundColor Green
if ($EnableSecureBoot) {
    Write-Host "Secure Boot : $($vm.ExtensionData.Config.BootOptions.EfiSecureBootEnabled)" -ForegroundColor Green
}

if ($Firmware -eq 'efi') {
    Write-Host "`nRappel : demarrez la VM et validez le boot UEFI avant toute autre modification (voir docs/06-troubleshooting-rollback.md en cas d'echec)." -ForegroundColor Yellow
}
