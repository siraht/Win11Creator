#===========================================================================
# Tests - Component dependency safety evaluator
#===========================================================================

BeforeAll {
    . (Join-Path $PSScriptRoot "..\functions\private\Test-WinUtilComponentSafety.ps1")

    $script:components = @(
        [pscustomobject]@{ Id = 'winget'; Requires = @('app-installer'); Conflicts = @() }
        [pscustomobject]@{ Id = 'app-installer'; Requires = @('windows-app-runtime'); Conflicts = @() }
        [pscustomobject]@{
            Id = 'windows-app-runtime'
            Requires = @()
            Conflicts = @(
                [pscustomobject]@{
                    Action = 'remove'
                    With = 'app-installer'
                    WithAction = 'keep'
                    Severity = 'forbidden-unless-expert'
                    Reason = 'App Installer requires Windows App Runtime.'
                }
            )
        }
        [pscustomobject]@{
            Id = 'search'
            Requires = @()
            Conflicts = @(
                [pscustomobject]@{ Action = 'disable'; With = 'start-menu'; WithAction = 'keep'; Severity = 'warning'; Reason = 'Search integration is reduced.' }
            )
        }
        [pscustomobject]@{ Id = 'start-menu'; Requires = @(); Conflicts = @() }
        [pscustomobject]@{
            Id = 'webview'
            Requires = @()
            Conflicts = @(
                [pscustomobject]@{ Action = 'remove'; With = 'widgets'; WithAction = 'keep'; Severity = 'likely-breakage'; Reason = 'Widgets are likely to fail.' }
            )
        }
        [pscustomobject]@{ Id = 'widgets'; Requires = @(); Conflicts = @() }
    )
}

Describe 'Test-WinUtilComponentSafety dependency contracts' {
    It 'ComponentSafety_TransitiveProtectionWins_PlantedNegative' {
        $result = Test-WinUtilComponentSafety -ComponentDeclarations $script:components -SelectedActions @{
            winget = 'keep'
            'windows-app-runtime' = 'remove'
        }

        $result.ProtectedComponentIds | Should -Contain 'app-installer'
        $result.ProtectedComponentIds | Should -Contain 'windows-app-runtime'
        $result.IsAllowed | Should -BeFalse
        $result.Conflicts | Where-Object {
            $_.ComponentId -eq 'windows-app-runtime' -and
            $_.RelatedComponentId -eq 'winget' -and
            $_.Severity -eq 'forbidden-unless-expert' -and
            $_.IsBlocking
        } | Should -HaveCount 1
    }

    It 'ComponentSafety_ExplicitForbiddenConflictRejectedWithoutExpert' {
        $result = Test-WinUtilComponentSafety -ComponentDeclarations $script:components -SelectedActions @{
            'app-installer' = 'keep'
            'windows-app-runtime' = 'remove'
        }

        $result.IsAllowed | Should -BeFalse
        $result.Conflicts | Where-Object {
            $_.ComponentId -eq 'windows-app-runtime' -and
            $_.RelatedComponentId -eq 'app-installer' -and
            $_.Severity -eq 'forbidden-unless-expert' -and
            $_.Reason -eq 'App Installer requires Windows App Runtime.' -and
            $_.IsBlocking
        } | Should -HaveCount 1
    }

    It 'ComponentSafety_ExpertModeAllowsForbiddenConflictButRetainsEvidence' {
        $result = Test-WinUtilComponentSafety -ComponentDeclarations $script:components -SelectedActions @{
            'app-installer' = 'keep'
            'windows-app-runtime' = 'remove'
        } -ExpertMode

        $result.IsAllowed | Should -BeTrue
        $result.Conflicts | Should -Not -BeNullOrEmpty
        $result.Conflicts.IsBlocking | Should -Not -Contain $true
    }

    It 'ComponentSafety_ReportsWarningAndLikelyBreakageSeverities' {
        $result = Test-WinUtilComponentSafety -ComponentDeclarations $script:components -SelectedActions @{
            search = 'disable'
            'start-menu' = 'keep'
            webview = 'remove'
            widgets = 'keep'
        }

        $result.IsAllowed | Should -BeTrue
        $result.Conflicts.Severity | Should -Contain 'warning'
        $result.Conflicts.Severity | Should -Contain 'likely-breakage'
    }
}
