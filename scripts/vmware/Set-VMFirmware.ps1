<#
.SYNOPSIS
    Switches a VMware VM's firmware between BIOS and EFI.
.DESCRIPTION
    Requires an already-connected PowerCLI session (Connect-VIServer). The VM must
    be powered off. Applies Firmware via ReconfigVM_Task and adjusts
    motherboardLayout accordingly (acpiHostBridges for EFI, i440bxHostBridge for
    BIOS).

    IMPORTANT: the guest OS conversion (MBR->GPT + UEFI bootloader) must already
    be done BEFORE switching a VM from BIOS to EFI, otherwise the VM will fail to
    boot. See docs/02-windows-guide.md / docs/03-linux-guide.md.

    This changes how the VM boots. By default the script prompts for
    confirmation (SupportsShouldProcess); pass -Force to skip the prompt for
    unattended automation, or -WhatIf to preview without changing anything.
.PARAMETER VMName
    Exact name of the target VM.
.PARAMETER Firmware
    'efi' or 'bios'.
.PARAMETER EnableSecureBoot
    Also enables Secure Boot when switching to EFI (requires hardware version
    >= 13 and a signed bootloader/kernel on the guest side).
.PARAMETER Force
    Suppresses the confirmation prompt.
.EXAMPLE
    .\Set-VMFirmware.ps1 -VMName "srv-app01" -Firmware efi
.EXAMPLE
    .\Set-VMFirmware.ps1 -VMName "srv-app01" -Firmware efi -EnableSecureBoot -Force
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [Parameter(Mandatory)]
    [ValidateSet('efi', 'bios')]
    [string]$Firmware,

    [switch]$EnableSecureBoot,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -Name VMware.VimAutomation.Core -ListAvailable)) {
    throw "The VMware.VimAutomation.Core module (PowerCLI) is not installed. Install-Module VMware.PowerCLI."
}
$viServersVar = Get-Variable -Name DefaultVIServers -Scope Global -ErrorAction SilentlyContinue
$viServers = if ($viServersVar) { $viServersVar.Value } else { $null }
if (-not $viServers -or $viServers.Count -eq 0) {
    throw "No active PowerCLI session. Connect first with Connect-VIServer -Server <vcenter>."
}

if ($EnableSecureBoot -and $Firmware -ne 'efi') {
    throw "Secure Boot requires -Firmware efi."
}

$vm = Get-VM -Name $VMName -ErrorAction Stop
if (@($vm).Count -gt 1) {
    throw "Multiple VMs match the name '$VMName'. Use an exact, unambiguous name."
}
if ($vm.PowerState -ne 'PoweredOff') {
    throw "VM '$VMName' must be powered off before changing its firmware (current state: $($vm.PowerState)). This script does not stop it automatically."
}

$currentFirmware = $vm.ExtensionData.Config.Firmware
if ($currentFirmware -eq $Firmware -and -not $EnableSecureBoot) {
    Write-Host "VM '$VMName' is already using firmware '$Firmware'. Nothing to do." -ForegroundColor Yellow
    return
}

Write-Host "VM '$VMName' - current firmware: $currentFirmware -> target: $Firmware" -ForegroundColor Cyan

if ($EnableSecureBoot) {
    $hwVersion = 0
    if ($vm.ExtensionData.Config.Version -match '(\d+)') {
        $hwVersion = [int]$Matches[1]
    }
    if ($hwVersion -lt 13) {
        throw "Secure Boot requires hardware version >= 13 (current version: $($vm.ExtensionData.Config.Version)). Upgrade the VM hardware version before continuing."
    }
}

if ($Force) {
    $ConfirmPreference = 'None'
}

$actionDescription = "Set firmware=$Firmware"
if ($EnableSecureBoot) { $actionDescription += ' + Secure Boot' }
if (-not $PSCmdlet.ShouldProcess("VM $VMName", $actionDescription)) {
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

try {
    $taskMoRef = $vm.ExtensionData.ReconfigVM_Task($spec)
    $taskView = Get-Task -Id ("Task-$($taskMoRef.Value)")
    $taskView = $taskView | Wait-Task -ErrorAction Stop
} catch {
    throw "Firmware reconfiguration failed for VM '$VMName': $($_.Exception.Message)"
}

if ($taskView.State -ne 'Success') {
    throw "The reconfiguration task did not complete successfully (state: $($taskView.State))."
}

$vm = Get-VM -Name $VMName -ErrorAction Stop
Write-Host "Done. Current firmware: $($vm.ExtensionData.Config.Firmware)" -ForegroundColor Green
if ($EnableSecureBoot) {
    Write-Host "Secure Boot: $($vm.ExtensionData.Config.BootOptions.EfiSecureBootEnabled)" -ForegroundColor Green
}

if ($Firmware -eq 'efi') {
    Write-Host "`nReminder: power on the VM and validate the UEFI boot before making any further changes (see docs/06-troubleshooting-rollback.md if it fails)." -ForegroundColor Yellow
}
