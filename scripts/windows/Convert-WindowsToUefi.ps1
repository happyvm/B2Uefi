<#
.SYNOPSIS
    Converts the Windows system disk from MBR to GPT in preparation for a UEFI boot.
.DESCRIPTION
    Wrapper around MBR2GPT.exe: runs /validate then /convert, logs the output, and
    reminds the operator of the remaining steps (shutting down the VM, switching
    the hypervisor firmware) which this script does NOT perform.

    This is a destructive operation on the partition table. By default the script
    prompts for confirmation (SupportsShouldProcess); pass -Force to skip the
    prompt for unattended automation, or -WhatIf to preview without changing
    anything.
.PARAMETER DiskNumber
    Number of the disk to convert (default: 0).
.PARAMETER LogDirectory
    Output directory for MBR2GPT logs (default: %TEMP%).
.PARAMETER SkipValidation
    Skips the /validate step and goes straight to /convert (not recommended).
.PARAMETER Force
    Suppresses the confirmation prompt (still shows a warning banner first).
.EXAMPLE
    .\Convert-WindowsToUefi.ps1 -DiskNumber 0
.EXAMPLE
    .\Convert-WindowsToUefi.ps1 -DiskNumber 0 -Force
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateRange(0, [int]::MaxValue)]
    [int]$DiskNumber = 0,

    [ValidateNotNullOrEmpty()]
    [string]$LogDirectory = $env:TEMP,

    [switch]$SkipValidation,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script must be run as Administrator."
}

$mbr2gpt = Join-Path $env:WINDIR 'System32\mbr2gpt.exe'
if (-not (Test-Path -LiteralPath $mbr2gpt)) {
    # MBR2GPT shipped with Windows 10 1703 (build 15063). Server 2016 is built on
    # the 1607 codebase (14393) and does not include it, nor does Server 2012 R2.
    $build = [System.Environment]::OSVersion.Version.Build
    throw @"
mbr2gpt.exe not found at $mbr2gpt (this OS is build $build).

The tool shipped with Windows 10 1703 / build 15063. Windows Server 2016
(build 14393) and Server 2012 R2 (9600) do not include it.

To convert this guest, boot it from WinPE 10.0.15063 or later media and run:
    mbr2gpt /validate /disk:0
    mbr2gpt /convert /disk:0
(no /allowFullOS - that switch is only for a running OS)

Do not copy mbr2gpt.exe from a newer Windows: it depends on the servicing
stack of the OS it ships with. See docs/07-os-support-matrix.md.
"@
}

if (-not (Test-Path -LiteralPath $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}

try {
    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
} catch {
    throw "Disk $DiskNumber not found: $($_.Exception.Message)"
}
if ($disk.PartitionStyle -eq 'GPT') {
    throw "Disk $DiskNumber is already GPT - nothing to convert."
}

Write-Warning "This will rewrite the partition table of disk $DiskNumber ($($disk.FriendlyName), $([math]::Round($disk.Size / 1GB)) GB). Make sure a snapshot/backup exists before continuing."

if ($Force) {
    $ConfirmPreference = 'None'
}

if (-not $SkipValidation) {
    Write-Host "=== Step 1/2: validation (disk $DiskNumber) ===" -ForegroundColor Cyan
    & $mbr2gpt /validate /disk:$DiskNumber /allowFullOS /logs:$LogDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "MBR2GPT validation failed (exit code $LASTEXITCODE). Check the logs in $LogDirectory. Run Test-UefiReadiness.ps1 for a detailed diagnosis."
    }
    Write-Host "Validation succeeded." -ForegroundColor Green
} else {
    Write-Warning "Validation skipped (-SkipValidation) - risk of converting a disk that isn't eligible."
}

Write-Host "`n=== Step 2/2: conversion (disk $DiskNumber) ===" -ForegroundColor Cyan
if (-not $PSCmdlet.ShouldProcess("Disk $DiskNumber", "Convert MBR -> GPT (MBR2GPT /convert)")) {
    Write-Host "Conversion not executed." -ForegroundColor Yellow
    return
}

& $mbr2gpt /convert /disk:$DiskNumber /allowFullOS /logs:$LogDirectory
if ($LASTEXITCODE -ne 0) {
    throw "MBR2GPT conversion failed (exit code $LASTEXITCODE). Check the logs in $LogDirectory. The disk may be in an intermediate state: do not switch the firmware to UEFI before confirming the disk state via 'Get-Disk'."
}

Write-Host "`nConversion completed successfully." -ForegroundColor Green
Write-Host @'

Next steps (NOT performed by this script):
  1. Shut down the VM cleanly (Stop-Computer).
  2. Switch the VM firmware on the hypervisor side:
       - VMware   : scripts\vmware\Set-VMFirmware.ps1 -Firmware efi
       - Hyper-V  : scripts\hyperv\Convert-Gen1ToGen2.ps1 (creates a Generation 2 VM)
  3. Reboot the VM and validate with:
       $env:firmware_type   (should return "UEFI")
       Get-Disk | Select Number, PartitionStyle

See docs\06-troubleshooting-rollback.md if the VM fails to boot.
'@ -ForegroundColor Cyan
