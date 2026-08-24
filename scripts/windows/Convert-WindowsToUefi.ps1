<#
.SYNOPSIS
    Convertit le disque systeme Windows de MBR vers GPT en vue d'un boot UEFI.
.DESCRIPTION
    Wrapper autour de MBR2GPT.exe : execute /validate puis /convert, journalise
    la sortie, et rappelle les etapes restantes (arret VM, bascule firmware
    hyperviseur) qui ne sont PAS effectuees par ce script.
.PARAMETER DiskNumber
    Numero du disque a convertir (par defaut : 0).
.PARAMETER LogDirectory
    Dossier de sortie des journaux MBR2GPT (par defaut : %TEMP%).
.PARAMETER SkipValidation
    Ignore l'etape /validate et passe directement a /convert (deconseille).
.EXAMPLE
    .\Convert-WindowsToUefi.ps1 -DiskNumber 0
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [int]$DiskNumber = 0,
    [string]$LogDirectory = $env:TEMP,
    [switch]$SkipValidation
)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Ce script doit etre execute en tant qu'administrateur."
}

$mbr2gpt = "$env:WINDIR\System32\mbr2gpt.exe"
if (-not (Test-Path $mbr2gpt)) {
    throw "MBR2GPT.exe introuvable. Ce script requiert Windows 10 1703+ / Windows Server 2016+."
}

if (-not $SkipValidation) {
    Write-Host "=== Etape 1/2 : validation (disque $DiskNumber) ===" -ForegroundColor Cyan
    & $mbr2gpt /validate /disk:$DiskNumber /allowFullOS /logs:$LogDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "La validation MBR2GPT a echoue (code $LASTEXITCODE). Consultez les journaux dans $LogDirectory. Executez Test-UefiReadiness.ps1 pour un diagnostic detaille."
    }
    Write-Host "Validation reussie." -ForegroundColor Green
} else {
    Write-Warning "Validation ignoree (-SkipValidation) - risque de conversion sur un disque non eligible."
}

Write-Host "`n=== Etape 2/2 : conversion (disque $DiskNumber) ===" -ForegroundColor Cyan
if ($PSCmdlet.ShouldProcess("Disque $DiskNumber", "Convertir MBR -> GPT (MBR2GPT /convert)")) {
    & $mbr2gpt /convert /disk:$DiskNumber /allowFullOS /logs:$LogDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "La conversion MBR2GPT a echoue (code $LASTEXITCODE). Consultez les journaux dans $LogDirectory. Le disque peut etre dans un etat intermediaire : ne redemarrez pas le firmware en UEFI avant d'avoir confirme l'etat via 'Get-Disk'."
    }
} else {
    Write-Host "(WhatIf) Conversion non executee." -ForegroundColor Yellow
    return
}

Write-Host "`nConversion terminee avec succes." -ForegroundColor Green
Write-Host @"

Prochaines etapes (NON effectuees par ce script) :
  1. Eteindre la VM proprement (Stop-Computer).
  2. Basculer le firmware de la VM cote hyperviseur :
       - VMware   : scripts\vmware\Set-VMFirmware.ps1 -Firmware efi
       - Hyper-V  : scripts\hyperv\Convert-Gen1ToGen2.ps1 (creation d'une VM Generation 2)
  3. Redemarrer la VM et valider avec :
       `$env:firmware_type   (doit renvoyer "UEFI")
       Get-Disk | Select Number, PartitionStyle

Voir docs\06-troubleshooting-rollback.md en cas de probleme au demarrage.
"@ -ForegroundColor Cyan
