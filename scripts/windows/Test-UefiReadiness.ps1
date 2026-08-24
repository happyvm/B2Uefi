<#
.SYNOPSIS
    Verifie si le disque systeme Windows est eligible a une conversion MBR -> GPT/UEFI.
.DESCRIPTION
    Controle la version de build Windows, le style de partition actuel, le nombre de
    partitions, le TPM et l'etat Secure Boot, puis execute "mbr2gpt /validate".
.PARAMETER DiskNumber
    Numero du disque a valider (par defaut : disque systeme, disque 0).
.EXAMPLE
    .\Test-UefiReadiness.ps1 -DiskNumber 0
#>
[CmdletBinding()]
param(
    [int]$DiskNumber = 0
)

$ErrorActionPreference = 'Stop'
$results = [ordered]@{}

function Add-Result {
    param([string]$Check, [string]$Status, [string]$Detail)
    $results[$Check] = [pscustomobject]@{ Status = $Status; Detail = $Detail }
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Ce script doit etre execute en tant qu'administrateur pour des resultats fiables (mbr2gpt, Get-Tpm)."
}

$build = [System.Environment]::OSVersion.Version.Build
if ($build -ge 15063) {
    Add-Result -Check 'Build Windows' -Status 'OK' -Detail "Build $build (>= 15063 requis pour MBR2GPT natif)"
} else {
    Add-Result -Check 'Build Windows' -Status 'ECHEC' -Detail "Build $build trop ancien, MBR2GPT natif indisponible"
}

try {
    $disk = Get-Disk -Number $DiskNumber
    Add-Result -Check 'Style de partition' -Status ($(if ($disk.PartitionStyle -eq 'MBR') {'OK'} else {'INFO'})) `
        -Detail "Disque $DiskNumber actuellement en $($disk.PartitionStyle)"

    $partCount = (Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Where-Object { $_.Type -ne 'Reserved' }).Count
    if ($partCount -le 3) {
        Add-Result -Check 'Nombre de partitions' -Status 'OK' -Detail "$partCount partition(s) detectee(s) (limite : 3 pour MBR2GPT)"
    } else {
        Add-Result -Check 'Nombre de partitions' -Status 'ECHEC' -Detail "$partCount partitions detectees, MBR2GPT exige au maximum 3"
    }
} catch {
    Add-Result -Check 'Style de partition' -Status 'ERREUR' -Detail $_.Exception.Message
}

try {
    $tpm = Get-Tpm -ErrorAction Stop
    if ($tpm.TpmPresent -and $tpm.TpmReady) {
        Add-Result -Check 'TPM' -Status 'OK' -Detail "TPM present et pret (requis pour Secure Boot / Windows 11 / BitLocker)"
    } else {
        Add-Result -Check 'TPM' -Status 'INFO' -Detail "TPM absent ou non pret - a activer cote hyperviseur si Secure Boot est vise"
    }
} catch {
    Add-Result -Check 'TPM' -Status 'INFO' -Detail "Impossible d'interroger le TPM (Get-Tpm indisponible sur ce systeme)"
}

try {
    $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
    Add-Result -Check 'Secure Boot' -Status 'INFO' -Detail "Secure Boot actuellement : $secureBoot"
} catch {
    Add-Result -Check 'Secure Boot' -Status 'INFO' -Detail "Firmware BIOS actuel : Secure Boot non applicable avant bascule UEFI"
}

try {
    $bitlocker = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
    if ($bitlocker.ProtectionStatus -eq 'On') {
        Add-Result -Check 'BitLocker' -Status 'ATTENTION' -Detail "BitLocker actif sur C: - a suspendre avant conversion (Suspend-BitLocker -MountPoint 'C:')"
    } else {
        Add-Result -Check 'BitLocker' -Status 'OK' -Detail "BitLocker inactif ou deja suspendu sur C:"
    }
} catch {
    Add-Result -Check 'BitLocker' -Status 'INFO' -Detail "Module BitLocker indisponible ou volume non protege"
}

Write-Host "`n=== Validation MBR2GPT (disque $DiskNumber) ===" -ForegroundColor Cyan
$mbr2gptOutput = & "$env:WINDIR\System32\mbr2gpt.exe" /validate /disk:$DiskNumber /allowFullOS 2>&1
$mbr2gptOutput | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -eq 0) {
    Add-Result -Check 'MBR2GPT /validate' -Status 'OK' -Detail 'Validation reussie'
} else {
    Add-Result -Check 'MBR2GPT /validate' -Status 'ECHEC' -Detail "Code de sortie $LASTEXITCODE - voir le journal ci-dessus"
}

Write-Host "`n=== Rapport de compatibilite BIOS -> UEFI ===" -ForegroundColor Cyan
$results.GetEnumerator() | ForEach-Object {
    $color = switch ($_.Value.Status) {
        'OK'        { 'Green' }
        'INFO'      { 'Gray' }
        'ATTENTION' { 'Yellow' }
        default     { 'Red' }
    }
    Write-Host ("{0,-24} [{1,-9}] {2}" -f $_.Key, $_.Value.Status, $_.Value.Detail) -ForegroundColor $color
}

$blocking = $results.Values | Where-Object { $_.Status -eq 'ECHEC' }
if ($blocking) {
    Write-Host "`nResultat : NON ELIGIBLE - corriger les points en echec avant de lancer Convert-WindowsToUefi.ps1" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nResultat : ELIGIBLE a la conversion" -ForegroundColor Green
    exit 0
}
