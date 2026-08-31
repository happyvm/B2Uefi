<#
.SYNOPSIS
    Checks whether the Windows system disk is eligible for MBR -> GPT/UEFI conversion.
.DESCRIPTION
    Checks the Windows build number, current partition style, partition count,
    TPM, and Secure Boot state, then runs "mbr2gpt /validate". Read-only: this
    script makes no changes to the system.
.PARAMETER DiskNumber
    Number of the disk to validate (default: system disk, disk 0).
.EXAMPLE
    .\Test-UefiReadiness.ps1 -DiskNumber 0
#>
[CmdletBinding()]
param(
    [ValidateRange(0, [int]::MaxValue)]
    [int]$DiskNumber = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$results = [ordered]@{}

function Add-Result {
    param(
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][ValidateSet('OK', 'INFO', 'WARNING', 'FAIL')][string]$Status,
        [Parameter(Mandatory)][string]$Detail
    )
    $results[$Check] = [pscustomobject]@{ Status = $Status; Detail = $Detail }
}

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "This script should be run as Administrator for reliable results (mbr2gpt, Get-Tpm)."
}

# MBR2GPT shipped with Windows 10 1703 / build 15063. Older builds - notably
# Server 2016 (14393) and Server 2012 R2 (9600) - can still be converted, but
# only from WinPE 1703+ media. Report that route instead of a bare failure.
$build = [System.Environment]::OSVersion.Version.Build
if ($build -ge 15063) {
    Add-Result -Check 'Windows build' -Status 'OK' -Detail "Build $build (>= 15063 required for native MBR2GPT)"
} else {
    $osName = switch ($build) {
        14393   { 'Windows Server 2016 / Windows 10 1607' }
        9600    { 'Windows Server 2012 R2 / Windows 8.1' }
        9200    { 'Windows Server 2012 / Windows 8' }
        default { "build $build" }
    }
    $convertible = $build -ge 9200
    if ($convertible) {
        Add-Result -Check 'Windows build' -Status 'WARNING' -Detail "$osName does not ship MBR2GPT (needs build >= 15063). Conversion is still possible from WinPE 1703+ media - see docs/07-os-support-matrix.md"
    } else {
        Add-Result -Check 'Windows build' -Status 'FAIL' -Detail "$osName is past end of support and has no supported UEFI conversion path - rebuild instead (docs/07-os-support-matrix.md)"
    }
}

try {
    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    $partStatus = if ($disk.PartitionStyle -eq 'MBR') { 'OK' } else { 'INFO' }
    Add-Result -Check 'Partition style' -Status $partStatus -Detail "Disk $DiskNumber is currently $($disk.PartitionStyle)"

    $partCount = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -ne 'Reserved' }).Count
    if ($partCount -le 3) {
        Add-Result -Check 'Partition count' -Status 'OK' -Detail "$partCount partition(s) detected (MBR2GPT limit: 3)"
    } else {
        Add-Result -Check 'Partition count' -Status 'FAIL' -Detail "$partCount partitions detected, MBR2GPT allows at most 3"
    }
} catch {
    Add-Result -Check 'Partition style' -Status 'FAIL' -Detail "Could not read disk ${DiskNumber}: $($_.Exception.Message)"
}

try {
    $tpm = Get-Tpm -ErrorAction Stop
    if ($tpm.TpmPresent -and $tpm.TpmReady) {
        Add-Result -Check 'TPM' -Status 'OK' -Detail "TPM present and ready (required for Secure Boot / Windows 11 / BitLocker)"
    } else {
        Add-Result -Check 'TPM' -Status 'INFO' -Detail "TPM absent or not ready - enable it on the hypervisor side if Secure Boot is planned"
    }
} catch {
    Add-Result -Check 'TPM' -Status 'INFO' -Detail "Unable to query the TPM (Get-Tpm unavailable on this system)"
}

try {
    $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
    Add-Result -Check 'Secure Boot' -Status 'INFO' -Detail "Secure Boot is currently: $secureBoot"
} catch {
    Add-Result -Check 'Secure Boot' -Status 'INFO' -Detail "Current firmware is BIOS: Secure Boot not applicable before switching to UEFI"
}

try {
    $bitlocker = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
    if ($bitlocker.ProtectionStatus -eq 'On') {
        Add-Result -Check 'BitLocker' -Status 'WARNING' -Detail "BitLocker is active on C: - suspend it before conversion (Suspend-BitLocker -MountPoint 'C:')"
    } else {
        Add-Result -Check 'BitLocker' -Status 'OK' -Detail "BitLocker is inactive or already suspended on C:"
    }
} catch {
    Add-Result -Check 'BitLocker' -Status 'INFO' -Detail "BitLocker module unavailable or volume not protected"
}

$mbr2gpt = Join-Path $env:WINDIR 'System32\mbr2gpt.exe'
if (Test-Path -LiteralPath $mbr2gpt) {
    Write-Host "`n=== MBR2GPT validation (disk $DiskNumber) ===" -ForegroundColor Cyan
    $mbr2gptOutput = & $mbr2gpt /validate /disk:$DiskNumber /allowFullOS 2>&1
    $mbr2gptOutput | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -eq 0) {
        Add-Result -Check 'MBR2GPT /validate' -Status 'OK' -Detail 'Validation succeeded'
    } else {
        Add-Result -Check 'MBR2GPT /validate' -Status 'FAIL' -Detail "Exit code $LASTEXITCODE - see log above"
    }
} else {
    # Reported as a failure on purpose: the in-place path this repository
    # automates is genuinely unavailable here. The WinPE route still exists and
    # the detail line points at it.
    Add-Result -Check 'MBR2GPT /validate' -Status 'FAIL' -Detail "mbr2gpt.exe not present on this OS - the in-place conversion is unavailable. Convert from WinPE 1703+ media instead (docs/07-os-support-matrix.md)"
}

Write-Host "`n=== BIOS -> UEFI compatibility report ===" -ForegroundColor Cyan
foreach ($entry in $results.GetEnumerator()) {
    $color = switch ($entry.Value.Status) {
        'OK'      { 'Green' }
        'INFO'    { 'Gray' }
        'WARNING' { 'Yellow' }
        default   { 'Red' }
    }
    Write-Host ("{0,-20} [{1,-8}] {2}" -f $entry.Key, $entry.Value.Status, $entry.Value.Detail) -ForegroundColor $color
}

$blocking = $results.Values | Where-Object { $_.Status -eq 'FAIL' }
if ($blocking) {
    Write-Host "`nResult: NOT ELIGIBLE - fix the failing checks above before running Convert-WindowsToUefi.ps1" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nResult: ELIGIBLE for conversion" -ForegroundColor Green
    exit 0
}
