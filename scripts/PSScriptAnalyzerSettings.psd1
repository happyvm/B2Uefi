@{
    # Settings used both in CI (.github/workflows/lint.yml) and for local linting
    # (see README.md "Linting" section).
    Severity    = @('Error', 'Warning')
    ExcludeRules = @(
        # These are interactive operator-facing scripts (colored status output,
        # progress messages) run from an admin's console during a maintenance
        # window - Write-Host is the right tool here, not a bug.
        'PSAvoidUsingWriteHost',
        # $global:DefaultVIServers is VMware PowerCLI's own documented session
        # variable; reading it to check for an active Connect-VIServer session
        # is the standard, supported way to do so.
        'PSAvoidGlobalVars'
    )
}
