#Requires -Modules Pester
<#
    Convention tests for every PowerShell script in this repository.

    These tests never touch VMware, Hyper-V or a real disk. They parse each
    script's AST and assert that the hardening conventions established in
    CONTRIBUTING.md hold, so a future script cannot silently drop them:

      - it parses;
      - it carries comment-based help (synopsis, description, at least one example);
      - it sets StrictMode and $ErrorActionPreference = 'Stop';
      - it declares [CmdletBinding()];
      - destructive scripts declare SupportsShouldProcess with ConfirmImpact
        'High' and expose -Force;
      - read-only scripts do not pretend to be destructive.

    Run locally with:  Invoke-Pester ./tests
#>

BeforeDiscovery {
    $discoveryScriptsRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
    $script:ScriptContract = & (Join-Path $PSScriptRoot 'ScriptContract.ps1') -ScriptsRoot $discoveryScriptsRoot

    $script:AllScripts = $script:ScriptContract
    $script:MutatingScripts = $script:ScriptContract | Where-Object { $_.Kind -in @('Destructive', 'Additive') }
    $script:DestructiveScripts = $script:ScriptContract | Where-Object { $_.Kind -eq 'Destructive' }
    $script:AdditiveScripts = $script:ScriptContract | Where-Object { $_.Kind -eq 'Additive' }
    $script:ReadOnlyScripts = $script:ScriptContract | Where-Object { $_.Kind -eq 'ReadOnly' }
}

BeforeAll {
    $script:ScriptsRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
    # Re-loaded here because Pester's run phase does not share scope with discovery.
    $script:Contract = & (Join-Path $PSScriptRoot 'ScriptContract.ps1') -ScriptsRoot $script:ScriptsRoot

    function Get-ScriptAst {
        param([Parameter(Mandatory)][string]$Path)

        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$null, [ref]$parseErrors)

        [pscustomobject]@{
            Ast    = $ast
            Errors = $parseErrors
        }
    }

    function Get-CmdletBindingArgument {
        param(
            [Parameter(Mandatory)]$Ast,
            [Parameter(Mandatory)][string]$ArgumentName
        )

        if (-not $Ast.ParamBlock) { return $null }

        $binding = $Ast.ParamBlock.Attributes |
            Where-Object { $_.TypeName.Name -eq 'CmdletBinding' } |
            Select-Object -First 1
        if (-not $binding) { return $null }

        $binding.NamedArguments |
            Where-Object { $_.ArgumentName -eq $ArgumentName } |
            Select-Object -First 1
    }

    function Get-ParameterName {
        param([Parameter(Mandatory)]$Ast)

        if (-not $Ast.ParamBlock) { return @() }
        $Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
    }
}

Describe 'Repository script inventory' {
    It 'classifies every .ps1 under scripts/ in the contract table' {
        $onDisk = Get-ChildItem -Path $script:ScriptsRoot -Filter *.ps1 -Recurse |
            ForEach-Object { (Resolve-Path $_.FullName).Path } |
            Sort-Object

        $declared = $script:Contract |
            ForEach-Object { (Resolve-Path $_.FullPath).Path } |
            Sort-Object

        # A new script must be added to $ScriptContract so its conventions get enforced.
        $onDisk | Should -Be $declared
    }
}

Describe 'Every script: <Name>' -ForEach $script:AllScripts {
    BeforeAll {
        $script:Parsed = Get-ScriptAst -Path $FullPath
        $script:ScriptAst = $script:Parsed.Ast
        $script:Content = Get-Content -LiteralPath $FullPath -Raw
    }

    It 'parses without errors' {
        $script:Parsed.Errors | Should -BeNullOrEmpty
    }

    It 'declares [CmdletBinding()]' {
        $binding = $script:ScriptAst.ParamBlock.Attributes |
            Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }
        $binding | Should -Not -BeNullOrEmpty
    }

    It 'provides comment-based help with a synopsis' {
        $help = $script:ScriptAst.GetHelpContent()
        $help | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }

    It 'provides comment-based help with a description' {
        $script:ScriptAst.GetHelpContent().Description | Should -Not -BeNullOrEmpty
    }

    It 'provides at least one usage example' {
        $script:ScriptAst.GetHelpContent().Examples.Count | Should -BeGreaterThan 0
    }

    It 'enables StrictMode' {
        $calls = $script:ScriptAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Set-StrictMode'
            }, $true)
        $calls | Should -Not -BeNullOrEmpty
    }

    It 'sets $ErrorActionPreference to Stop' {
        $assignments = $script:ScriptAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$ErrorActionPreference'
            }, $true)

        $assignments | Should -Not -BeNullOrEmpty
        ($assignments | ForEach-Object { $_.Right.Extent.Text }) | Should -Contain "'Stop'"
    }

    It 'has no trailing whitespace' {
        $offenders = Get-Content -LiteralPath $FullPath |
            Select-String -Pattern '\s+$' |
            ForEach-Object { $_.LineNumber }
        $offenders | Should -BeNullOrEmpty
    }
}

Describe 'Scripts that change state: <Name>' -ForEach $script:MutatingScripts {
    BeforeAll {
        $script:ScriptAst = (Get-ScriptAst -Path $FullPath).Ast
    }

    It 'declares SupportsShouldProcess so -WhatIf works' {
        Get-CmdletBindingArgument -Ast $script:ScriptAst -ArgumentName 'SupportsShouldProcess' |
            Should -Not -BeNullOrEmpty
    }

    It 'actually calls ShouldProcess before mutating' {
        $calls = $script:ScriptAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                $node.Member.Value -eq 'ShouldProcess'
            }, $true)
        $calls | Should -Not -BeNullOrEmpty
    }
}

Describe 'Destructive scripts: <Name>' -ForEach $script:DestructiveScripts {
    BeforeAll {
        $script:ScriptAst = (Get-ScriptAst -Path $FullPath).Ast
    }

    It 'sets ConfirmImpact to High so it prompts by default' {
        $impact = Get-CmdletBindingArgument -Ast $script:ScriptAst -ArgumentName 'ConfirmImpact'
        $impact | Should -Not -BeNullOrEmpty
        $impact.Argument.Value | Should -Be 'High'
    }

    It 'exposes -Force for unattended automation' {
        Get-ParameterName -Ast $script:ScriptAst | Should -Contain 'Force'
    }
}

Describe 'Additive scripts: <Name>' -ForEach $script:AdditiveScripts {
    BeforeAll {
        $script:ScriptAst = (Get-ScriptAst -Path $FullPath).Ast
    }

    It 'keeps ConfirmImpact Low so a safety snapshot is never blocked by a prompt' {
        $impact = Get-CmdletBindingArgument -Ast $script:ScriptAst -ArgumentName 'ConfirmImpact'
        $impact | Should -Not -BeNullOrEmpty
        $impact.Argument.Value | Should -Be 'Low'
    }
}

Describe 'Read-only scripts: <Name>' -ForEach $script:ReadOnlyScripts {
    BeforeAll {
        $script:ScriptAst = (Get-ScriptAst -Path $FullPath).Ast
    }

    It 'does not expose -Force (nothing to force in a report)' {
        Get-ParameterName -Ast $script:ScriptAst | Should -Not -Contain 'Force'
    }

    It 'does not declare SupportsShouldProcess' {
        Get-CmdletBindingArgument -Ast $script:ScriptAst -ArgumentName 'SupportsShouldProcess' |
            Should -BeNullOrEmpty
    }
}
