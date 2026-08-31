<#
    Canonical classification of every PowerShell script in this repository.

    Kept in its own file because Pester's discovery and run phases have separate
    scopes: Scripts.Tests.ps1 dot-sources this from both BeforeDiscovery (to
    generate the -ForEach cases) and BeforeAll (to assert the inventory).

    Kinds:
      Destructive - rewrites a partition table, reconfigures or removes a VM.
                    Must gate behind ShouldProcess/ConfirmImpact High and offer -Force.
      Additive    - creates a snapshot/checkpoint. Uses ShouldProcess but must not
                    prompt by default, so ConfirmImpact stays Low.
      ReadOnly    - reports only. Must not offer -Force or SupportsShouldProcess.

    Adding a script under scripts/ without listing it here fails the
    "classifies every .ps1" test by design.
#>
param(
    [Parameter(Mandatory)]
    [string]$ScriptsRoot
)

$contract = @(
    @{ Path = 'windows/Test-UefiReadiness.ps1';        Kind = 'ReadOnly' }
    @{ Path = 'windows/Test-UefiMigrationResult.ps1';  Kind = 'ReadOnly' }
    @{ Path = 'windows/Convert-WindowsToUefi.ps1';     Kind = 'Destructive' }
    @{ Path = 'vmware/Get-VMFirmwareReport.ps1';       Kind = 'ReadOnly' }
    @{ Path = 'vmware/Set-VMFirmware.ps1';             Kind = 'Destructive' }
    @{ Path = 'vmware/New-PreMigrationSnapshot.ps1';   Kind = 'Additive' }
    @{ Path = 'vmware/Invoke-VMwareMigration.ps1';     Kind = 'Destructive' }
    @{ Path = 'hyperv/Get-VMGenerationReport.ps1';     Kind = 'ReadOnly' }
    @{ Path = 'hyperv/Convert-Gen1ToGen2.ps1';         Kind = 'Destructive' }
    @{ Path = 'hyperv/Restore-Gen1VM.ps1';             Kind = 'Destructive' }
    @{ Path = 'hyperv/New-PreMigrationCheckpoint.ps1'; Kind = 'Additive' }
)

foreach ($entry in $contract) {
    $entry['FullPath'] = Join-Path $ScriptsRoot $entry.Path
    $entry['Name'] = Split-Path -Leaf $entry.Path
}

$contract
