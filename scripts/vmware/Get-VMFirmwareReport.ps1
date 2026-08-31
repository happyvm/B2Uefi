<#
.SYNOPSIS
    Reports the firmware (BIOS/EFI) and related settings of VMware VMs.
.DESCRIPTION
    Requires an already-connected PowerCLI session (Connect-VIServer). Lists, for
    each VM matching the filter: current firmware, hardware version, power state,
    and Secure Boot eligibility (hardware version >= 13). Read-only.
.PARAMETER VMName
    VM name filter (wildcards supported). Default: all VMs ("*").
.EXAMPLE
    .\Get-VMFirmwareReport.ps1 -VMName "srv-*"
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$VMName = "*"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -Name VMware.VimAutomation.Core -ListAvailable)) {
    throw "The VMware.VimAutomation.Core module (PowerCLI) is not installed. Install-Module VMware.PowerCLI."
}
$viServersVar = Get-Variable -Name DefaultVIServers -Scope Global -ErrorAction SilentlyContinue
$viServers = if ($viServersVar) { $viServersVar.Value } else { $null }
if (-not $viServers -or @($viServers).Count -eq 0) {
    throw "No active PowerCLI session. Connect first with Connect-VIServer -Server <vcenter>."
}

$vms = Get-VM -Name $VMName -ErrorAction Stop
if (-not $vms) {
    Write-Warning "No VM matches the filter '$VMName'."
    return
}

# Some Config sub-fields (MotherboardLayout, BootOptions) were added to the
# vSphere API in later versions than others. Depending on the vCenter/ESXi API
# version and the VM's own hardware version, the ExtensionData object handed
# back by PowerCLI can be missing them entirely - not merely $null, but absent
# as a property - which throws under Set-StrictMode. Read defensively via
# PSObject.Properties instead of a bare '.' access.
function Get-ConfigProperty {
    param($InputObject, [Parameter(Mandatory)][string]$Name)
    if ($InputObject -and $InputObject.PSObject.Properties[$Name]) {
        return $InputObject.PSObject.Properties[$Name].Value
    }
    return $null
}

$report = foreach ($vm in $vms) {
    $view = $vm.ExtensionData
    $hwVersionNumber = 0
    if ($view.Config.Version -match '(\d+)') {
        $hwVersionNumber = [int]$Matches[1]
    }
    $bootOptions = Get-ConfigProperty -InputObject $view.Config -Name 'BootOptions'
    [pscustomobject]@{
        Name              = $vm.Name
        PowerState        = $vm.PowerState
        Firmware          = $view.Config.Firmware
        HardwareVersion   = $view.Config.Version
        SecureBootCapable = $hwVersionNumber -ge 13
        SecureBootEnabled = Get-ConfigProperty -InputObject $bootOptions -Name 'EfiSecureBootEnabled'
        MotherboardLayout = Get-ConfigProperty -InputObject $view.Config -Name 'MotherboardLayout'
    }
}

$report | Sort-Object Name | Format-Table -AutoSize

$biosCount = @($report | Where-Object { $_.Firmware -eq 'bios' }).Count
Write-Host "`n$biosCount of $(@($report).Count) analyzed VM(s) are still on BIOS firmware." -ForegroundColor Cyan
