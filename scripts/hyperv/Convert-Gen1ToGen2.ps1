<#
.SYNOPSIS
    Migrates a Hyper-V Generation 1 (BIOS) VM to a new Generation 2 (UEFI) VM.
.DESCRIPTION
    Hyper-V does not allow changing the generation of an existing VM. This script
    automates the method documented by Microsoft:
      1. Verifies the source VM is powered off, Generation 1, with VHDX disk(s).
      2. Renames the source VM to "<Name>-gen1-legacy" (NEVER deleted automatically).
      3. Creates a new Generation 2 VM with the original name, replicating
         memory, vCPU, and network adapters (synthetic).
      4. Attaches the same VHDX file(s) to a SCSI controller.
      5. Configures Secure Boot based on -OSType.

    PREREQUISITE: the source VM's guest disk must already have been converted to
    GPT with a UEFI bootloader (scripts/windows/Convert-WindowsToUefi.ps1 or
    scripts/linux/convert-linux-to-uefi.sh) BEFORE running this script.

    The VHDX file remains referenced by BOTH VMs (renamed source + new VM);
    Hyper-V's file locking prevents starting both at once, but never manually
    start the "-gen1-legacy" VM except for a deliberate rollback (see
    docs/06-troubleshooting-rollback.md).

    This creates a new VM and renames the source VM. By default the script
    prompts for confirmation (SupportsShouldProcess); pass -Force to skip the
    prompt for unattended automation, or -WhatIf to preview without changing
    anything. On any failure after the rename, the script automatically
    attempts to roll back (remove the partially created VM, rename the source
    VM back to its original name).
.PARAMETER SourceVMName
    Name of the Generation 1 VM to migrate.
.PARAMETER NewVMName
    Name of the new Generation 2 VM (default: same as SourceVMName).
.PARAMETER OSType
    'Windows' or 'Linux' - determines the Secure Boot template applied.
.PARAMETER DisableSecureBoot
    Disables Secure Boot (needed for some unsigned Linux kernels).
.PARAMETER VMPath
    Configuration folder for the new VM (default: the host's default VM path).
.PARAMETER Start
    Automatically starts the new VM after creation.
.PARAMETER Force
    Suppresses the confirmation prompt.
.EXAMPLE
    .\Convert-Gen1ToGen2.ps1 -SourceVMName "srv-app01" -OSType Windows
.EXAMPLE
    .\Convert-Gen1ToGen2.ps1 -SourceVMName "srv-web01" -OSType Linux -Start -Force
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceVMName,

    [ValidateNotNullOrEmpty()]
    [string]$NewVMName = $SourceVMName,

    [Parameter(Mandatory)]
    [ValidateSet('Windows', 'Linux')]
    [string]$OSType,

    [switch]$DisableSecureBoot,

    [ValidateNotNullOrEmpty()]
    [string]$VMPath,

    [switch]$Start,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop

$sourceVM = Get-VM -Name $SourceVMName -ErrorAction Stop
if (@($sourceVM).Count -gt 1) {
    throw "Multiple VMs match the name '$SourceVMName'. Use an exact, unambiguous name."
}

if ($sourceVM.State -ne 'Off') {
    throw "VM '$SourceVMName' must be powered off (current state: $($sourceVM.State))."
}
if ($sourceVM.Generation -ne 1) {
    throw "VM '$SourceVMName' is already Generation $($sourceVM.Generation) - nothing to migrate."
}

$disks = Get-VMHardDiskDrive -VMName $SourceVMName
if (-not $disks) {
    throw "No hard disk found on '$SourceVMName'."
}
$nonVhdx = $disks | Where-Object { [System.IO.Path]::GetExtension($_.Path) -ine '.vhdx' }
if ($nonVhdx) {
    $paths = ($nonVhdx | ForEach-Object { $_.Path }) -join ', '
    throw "Generation 2 only supports VHDX. Convert first: $paths (Convert-VHD -Path <src.vhd> -DestinationPath <dst.vhdx>)."
}
foreach ($disk in $disks) {
    if (-not (Test-Path -LiteralPath $disk.Path)) {
        throw "Disk file not found: $($disk.Path)"
    }
}

if ($NewVMName -ne $SourceVMName -and (Get-VM -Name $NewVMName -ErrorAction SilentlyContinue)) {
    throw "A VM named '$NewVMName' already exists. Choose a different -NewVMName, or rename/remove the existing VM."
}

$memory = Get-VMMemory -VMName $SourceVMName
$processor = Get-VMProcessor -VMName $SourceVMName
$netAdapters = Get-VMNetworkAdapter -VMName $SourceVMName

if (-not $VMPath) {
    $VMPath = (Get-VMHost).VirtualMachinePath
}
if (-not (Test-Path -LiteralPath $VMPath)) {
    throw "VM path '$VMPath' does not exist or is not accessible."
}

Write-Host "=== Gen1 -> Gen2 migration: $SourceVMName -> $NewVMName ===" -ForegroundColor Cyan
Write-Host "Memory  : $($memory.Startup / 1GB) GB (dynamic: $($memory.DynamicMemoryEnabled))"
Write-Host "vCPU    : $($processor.Count)"
Write-Host "Network : $(($netAdapters | ForEach-Object { $_.SwitchName }) -join ', ')"
Write-Host "Disks   : $(($disks | ForEach-Object { $_.Path }) -join ', ')"

if ($Force) {
    $ConfirmPreference = 'None'
}

if (-not $PSCmdlet.ShouldProcess("$SourceVMName -> $NewVMName", "Migrate to Generation 2")) {
    return
}

$legacyName = "$SourceVMName-gen1-legacy"
Write-Host "`nRenaming the source VM to '$legacyName' (kept intact for rollback)..." -ForegroundColor Yellow
Rename-VM -VM $sourceVM -NewName $legacyName

$newVM = $null
try {
    Write-Host "Creating Generation 2 VM '$NewVMName'..." -ForegroundColor Cyan
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

    Write-Host "`nVM '$NewVMName' created successfully (Generation 2)." -ForegroundColor Green
    $secureBootMsg = "Secure Boot: $($secureBootParams['EnableSecureBoot'])"
    if ($secureBootParams.ContainsKey('SecureBootTemplate')) {
        $secureBootMsg += " (template: $($secureBootParams['SecureBootTemplate']))"
    }
    Write-Host $secureBootMsg

    if ($Start) {
        Write-Host "Starting '$NewVMName'..." -ForegroundColor Cyan
        Start-VM -Name $NewVMName
    } else {
        Write-Host "`nVM not started (use -Start, or run 'Start-VM -Name $NewVMName' after review)." -ForegroundColor Yellow
    }
}
catch {
    $failure = $_
    Write-Warning "Migration failed: $($failure.Exception.Message)"

    if ($newVM) {
        try {
            Remove-VM -VM $newVM -Force -ErrorAction Stop
            Write-Warning "Partially created VM '$NewVMName' has been removed (disk files were not touched)."
        } catch {
            Write-Warning "Could not remove the partially created VM '$NewVMName': $($_.Exception.Message). Remove it manually before retrying."
        }
    }

    try {
        Rename-VM -Name $legacyName -NewName $SourceVMName -ErrorAction Stop
        Write-Warning "Source VM automatically renamed back to '$SourceVMName'."
    } catch {
        Write-Warning "Could not rename the source VM back automatically: $($_.Exception.Message). Run manually: Rename-VM -Name '$legacyName' -NewName '$SourceVMName'"
    }

    throw $failure
}

Write-Host @"

Next steps:
  1. Validate that '$NewVMName' boots and behaves correctly.
  2. Once validated, remove the legacy VM (the VHDX files are NOT touched):
       Remove-VM -Name '$legacyName' -Force
  3. If something goes wrong, see docs/06-troubleshooting-rollback.md.
"@ -ForegroundColor Cyan
