<#
.SYNOPSIS
    Migre une VM Hyper-V Generation 1 (BIOS) vers une nouvelle VM Generation 2 (UEFI).
.DESCRIPTION
    Hyper-V ne permet pas de changer la generation d'une VM existante. Ce script
    automatise la methode documentee par Microsoft :
      1. Verifie que la VM source est eteinte, en Generation 1, avec disque(s) VHDX.
      2. Renomme la VM source en "<Nom>-gen1-legacy" (JAMAIS supprimee automatiquement).
      3. Cree une nouvelle VM Generation 2 avec le nom d'origine, en recopiant
         memoire, vCPU, adaptateurs reseau (synthetiques).
      4. Rattache le(s) meme(s) fichier(s) VHDX sur un controleur SCSI.
      5. Configure Secure Boot selon -OSType.
    PREREQUIS : le disque invite de la VM source doit deja avoir ete converti en
    GPT avec un bootloader UEFI (scripts/windows/Convert-WindowsToUefi.ps1 ou
    scripts/linux/convert-linux-to-uefi.sh) AVANT d'executer ce script.
    Le fichier VHDX reste reference par les DEUX VM (source renommee + nouvelle) ;
    Hyper-V empeche via verrou fichier de demarrer les deux simultanement, mais
    ne demarrez jamais manuellement la VM "-gen1-legacy" sauf pour un rollback
    volontaire (voir docs/06-troubleshooting-rollback.md).
.PARAMETER SourceVMName
    Nom de la VM Generation 1 a migrer.
.PARAMETER NewVMName
    Nom de la nouvelle VM Generation 2 (par defaut : identique a SourceVMName).
.PARAMETER OSType
    'Windows' ou 'Linux' - determine le template Secure Boot applique.
.PARAMETER DisableSecureBoot
    Desactive Secure Boot (necessaire pour certains noyaux Linux non signes).
.PARAMETER VMPath
    Dossier de configuration de la nouvelle VM (par defaut : chemin par defaut de l'hote).
.PARAMETER Start
    Demarre automatiquement la nouvelle VM apres creation.
.EXAMPLE
    .\Convert-Gen1ToGen2.ps1 -SourceVMName "srv-app01" -OSType Windows
.EXAMPLE
    .\Convert-Gen1ToGen2.ps1 -SourceVMName "srv-web01" -OSType Linux -Start
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SourceVMName,

    [string]$NewVMName = $SourceVMName,

    [Parameter(Mandatory)]
    [ValidateSet('Windows', 'Linux')]
    [string]$OSType,

    [switch]$DisableSecureBoot,

    [string]$VMPath,

    [switch]$Start
)

$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop

$sourceVM = Get-VM -Name $SourceVMName -ErrorAction Stop

if ($sourceVM.State -ne 'Off') {
    throw "La VM '$SourceVMName' doit etre eteinte (etat actuel : $($sourceVM.State))."
}
if ($sourceVM.Generation -ne 1) {
    throw "La VM '$SourceVMName' est deja en Generation $($sourceVM.Generation) - rien a migrer."
}

$disks = Get-VMHardDiskDrive -VMName $SourceVMName
if (-not $disks) {
    throw "Aucun disque dur trouve sur '$SourceVMName'."
}
$nonVhdx = $disks | Where-Object { [System.IO.Path]::GetExtension($_.Path) -ine '.vhdx' }
if ($nonVhdx) {
    $paths = ($nonVhdx | ForEach-Object { $_.Path }) -join ', '
    throw "Generation 2 ne supporte que le VHDX. Convertissez d'abord : $paths (Convert-VHD -Path <src.vhd> -DestinationPath <dst.vhdx>)."
}

if (Get-VM -Name $NewVMName -ErrorAction SilentlyContinue) {
    throw "Une VM nommee '$NewVMName' existe deja. Choisissez un autre -NewVMName ou renommez/supprimez la VM existante."
}

$memory = Get-VMMemory -VMName $SourceVMName
$processor = Get-VMProcessor -VMName $SourceVMName
$netAdapters = Get-VMNetworkAdapter -VMName $SourceVMName

if (-not $VMPath) {
    $VMPath = (Get-VMHost).VirtualMachinePath
}

Write-Host "=== Migration Gen1 -> Gen2 : $SourceVMName -> $NewVMName ===" -ForegroundColor Cyan
Write-Host "Memoire : $($memory.Startup / 1GB) Go (dynamique: $($memory.DynamicMemoryEnabled))"
Write-Host "vCPU    : $($processor.Count)"
Write-Host "Reseau  : $(($netAdapters | ForEach-Object { $_.SwitchName }) -join ', ')"
Write-Host "Disques : $(($disks | ForEach-Object { $_.Path }) -join ', ')"

if (-not $PSCmdlet.ShouldProcess("$SourceVMName -> $NewVMName", "Migrer vers Generation 2")) {
    return
}

$legacyName = "$SourceVMName-gen1-legacy"
Write-Host "`nRenommage de la VM source en '$legacyName' (conservee intacte pour rollback)..." -ForegroundColor Yellow
Rename-VM -VM $sourceVM -NewName $legacyName

try {
    Write-Host "Creation de la VM Generation 2 '$NewVMName'..." -ForegroundColor Cyan
    $newVM = New-VM -Name $NewVMName -Generation 2 -MemoryStartupBytes $memory.Startup -Path $VMPath -NoVHD

    Set-VMProcessor -VM $newVM -Count $processor.Count
    Set-VMMemory -VM $newVM -DynamicMemoryEnabled $memory.DynamicMemoryEnabled `
        -MinimumBytes $memory.Minimum -MaximumBytes $memory.Maximum -StartupBytes $memory.Startup

    Get-VMNetworkAdapter -VM $newVM | Remove-VMNetworkAdapter
    foreach ($nic in $netAdapters) {
        $newNic = Add-VMNetworkAdapter -VM $newVM -SwitchName $nic.SwitchName -Name $nic.Name -Passthru
        if (-not $nic.DynamicMacAddressEnabled) {
            Set-VMNetworkAdapter -VMNetworkAdapter $newNic -StaticMacAddress $nic.MacAddress
        }
        if ($nic.VlanSetting.OperationMode -eq 'Access') {
            Set-VMNetworkAdapterVlan -VMNetworkAdapter $newNic -Access -VlanId $nic.VlanSetting.AccessVlanId
        }
    }

    foreach ($disk in $disks) {
        Add-VMHardDiskDrive -VM $newVM -ControllerType SCSI -Path $disk.Path
    }

    $bootDisk = Get-VMHardDiskDrive -VM $newVM | Select-Object -First 1
    $secureBootParams = @{ VMName = $NewVMName }
    if ($DisableSecureBoot) {
        $secureBootParams['EnableSecureBoot'] = 'Off'
    } else {
        $secureBootParams['EnableSecureBoot'] = 'On'
        $secureBootParams['SecureBootTemplate'] = if ($OSType -eq 'Windows') { 'MicrosoftWindows' } else { 'MicrosoftUEFICertificateAuthority' }
    }
    Set-VMFirmware @secureBootParams -FirstBootDevice $bootDisk

    Write-Host "`nVM '$NewVMName' creee avec succes (Generation 2)." -ForegroundColor Green
    $secureBootMsg = "Secure Boot : $($secureBootParams['EnableSecureBoot'])"
    if ($secureBootParams.ContainsKey('SecureBootTemplate')) {
        $secureBootMsg += " (template: $($secureBootParams['SecureBootTemplate']))"
    }
    Write-Host $secureBootMsg

    if ($Start) {
        Write-Host "Demarrage de '$NewVMName'..." -ForegroundColor Cyan
        Start-VM -Name $NewVMName
    } else {
        Write-Host "`nVM non demarree (utilisez -Start ou 'Start-VM -Name $NewVMName' apres verification)." -ForegroundColor Yellow
    }
}
catch {
    Write-Warning "Echec de la migration : $($_.Exception.Message)"
    Write-Warning "La VM source a ete renommee '$legacyName' mais n'a PAS ete modifiee. Pour revenir en arriere : Rename-VM -Name '$legacyName' -NewName '$SourceVMName'."
    throw
}

Write-Host @"

Prochaines etapes :
  1. Valider le demarrage et le fonctionnement de '$NewVMName'.
  2. Une fois valide, supprimer la VM legacy (les fichiers VHDX ne sont PAS touches) :
       Remove-VM -Name '$legacyName' -Force
  3. En cas de probleme, voir docs/06-troubleshooting-rollback.md.
"@ -ForegroundColor Cyan
