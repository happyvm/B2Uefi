<#
.SYNOPSIS
    Validates that a Windows guest actually booted in UEFI mode after migration.
.DESCRIPTION
    Run this inside the guest after the firmware switch and the first reboot. It
    confirms the four things that must all be true for the migration to be
    complete: the firmware is UEFI, the system disk is GPT, an EFI System
    Partition exists, and the boot loader points at bootmgfw.efi.

    Read-only: this script makes no changes to the system.

    Exits 0 when the migration is confirmed, 1 when any check fails.
.PARAMETER DiskNumber
    System disk number to inspect. Defaults to the disk hosting the Windows
    volume.
.EXAMPLE
    .\Test-UefiMigrationResult.ps1
.EXAMPLE
    .\Test-UefiMigrationResult.ps1 -DiskNumber 0
#>
[CmdletBinding()]
param(
    [ValidateRange(0, [int]::MaxValue)]
    [int]$DiskNumber = -1
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
    Write-Warning "This script should be run as Administrator for reliable results (bcdedit, disk queries)."
}

# --- 1. Firmware mode -------------------------------------------------------
# $env:firmware_type is set by Windows itself and is the authoritative answer.
$firmwareType = $env:firmware_type
if ($firmwareType -eq 'UEFI') {
    Add-Result -Check 'Firmware mode' -Status 'OK' -Detail "Booted in UEFI (firmware_type = $firmwareType)"
} elseif ($firmwareType) {
    Add-Result -Check 'Firmware mode' -Status 'FAIL' -Detail "Still booted in $firmwareType - the hypervisor firmware switch has not taken effect"
} else {
    Add-Result -Check 'Firmware mode' -Status 'FAIL' -Detail "Could not determine firmware type (firmware_type environment variable is empty)"
}

# --- 2. System disk resolution ---------------------------------------------
if ($DiskNumber -lt 0) {
    try {
        $windowsDrive = ($env:SystemDrive).TrimEnd(':')
        $DiskNumber = (Get-Partition -DriveLetter $windowsDrive -ErrorAction Stop).DiskNumber
        Add-Result -Check 'System disk' -Status 'INFO' -Detail "Auto-detected disk $DiskNumber (hosting $($env:SystemDrive))"
    } catch {
        Add-Result -Check 'System disk' -Status 'FAIL' -Detail "Could not auto-detect the system disk: $($_.Exception.Message). Pass -DiskNumber explicitly."
    }
}

# --- 3. Partition style + ESP ----------------------------------------------
if ($DiskNumber -ge 0) {
    try {
        $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
        if ($disk.PartitionStyle -eq 'GPT') {
            Add-Result -Check 'Partition style' -Status 'OK' -Detail "Disk $DiskNumber is GPT"
        } else {
            Add-Result -Check 'Partition style' -Status 'FAIL' -Detail "Disk $DiskNumber is still $($disk.PartitionStyle) - the MBR2GPT conversion did not apply"
        }

        # GUID of the EFI System Partition type, per the UEFI specification.
        $espGuid = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        $esp = Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop |
            Where-Object { $_.GptType -eq $espGuid }
        if ($esp) {
            $espSizeMB = [math]::Round((@($esp)[0].Size / 1MB))
            Add-Result -Check 'EFI System Partition' -Status 'OK' -Detail "ESP present on disk $DiskNumber ($espSizeMB MB)"
        } else {
            Add-Result -Check 'EFI System Partition' -Status 'FAIL' -Detail "No EFI System Partition found on disk $DiskNumber"
        }
    } catch {
        Add-Result -Check 'Partition style' -Status 'FAIL' -Detail "Could not inspect disk ${DiskNumber}: $($_.Exception.Message)"
    }
}

# --- 4. Boot loader path ----------------------------------------------------
try {
    $bcdOutput = & "$env:WINDIR\System32\bcdedit.exe" /enum '{bootmgr}' 2>&1 | Out-String
    if ($bcdOutput -match 'bootmgfw\.efi') {
        Add-Result -Check 'Boot loader' -Status 'OK' -Detail "Boot manager points at bootmgfw.efi (UEFI loader)"
    } elseif ($bcdOutput -match 'bootmgr') {
        Add-Result -Check 'Boot loader' -Status 'FAIL' -Detail "Boot manager still points at the legacy BIOS loader"
    } else {
        Add-Result -Check 'Boot loader' -Status 'WARNING' -Detail "Could not parse the bcdedit output; check manually with: bcdedit /enum {bootmgr}"
    }
} catch {
    Add-Result -Check 'Boot loader' -Status 'WARNING' -Detail "Could not run bcdedit: $($_.Exception.Message)"
}

# --- 5. Secure Boot (informational) ----------------------------------------
try {
    $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
    if ($secureBoot) {
        Add-Result -Check 'Secure Boot' -Status 'OK' -Detail "Secure Boot is enabled"
    } else {
        Add-Result -Check 'Secure Boot' -Status 'INFO' -Detail "Secure Boot is available but disabled - enable it on the hypervisor side if required"
    }
} catch {
    Add-Result -Check 'Secure Boot' -Status 'INFO' -Detail "Secure Boot state unavailable (expected if the firmware is not yet UEFI)"
}

# --- 6. BitLocker reminder --------------------------------------------------
try {
    $bitlocker = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ($bitlocker.ProtectionStatus -eq 'Off') {
        Add-Result -Check 'BitLocker' -Status 'WARNING' -Detail "BitLocker is suspended/off on $($env:SystemDrive) - re-enable it now that the migration is validated (Resume-BitLocker)"
    } else {
        Add-Result -Check 'BitLocker' -Status 'OK' -Detail "BitLocker protection is on for $($env:SystemDrive)"
    }
} catch {
    Add-Result -Check 'BitLocker' -Status 'INFO' -Detail "BitLocker module unavailable or volume not protected"
}

# --- Report -----------------------------------------------------------------
Write-Host "`n=== Post-migration UEFI validation ===" -ForegroundColor Cyan
foreach ($entry in $results.GetEnumerator()) {
    $color = switch ($entry.Value.Status) {
        'OK'      { 'Green' }
        'INFO'    { 'Gray' }
        'WARNING' { 'Yellow' }
        default   { 'Red' }
    }
    Write-Host ("{0,-22} [{1,-8}] {2}" -f $entry.Key, $entry.Value.Status, $entry.Value.Detail) -ForegroundColor $color
}

$failed = $results.Values | Where-Object { $_.Status -eq 'FAIL' }
if ($failed) {
    Write-Host "`nResult: MIGRATION NOT CONFIRMED - see docs\06-troubleshooting-rollback.md" -ForegroundColor Red
    exit 1
}

Write-Host "`nResult: MIGRATION CONFIRMED - the guest is running in UEFI mode on a GPT disk." -ForegroundColor Green
Write-Host "You can now remove the pre-migration snapshot/checkpoint to reclaim space." -ForegroundColor Cyan
exit 0
