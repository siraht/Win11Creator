Describe 'Win11 Creator component profile comparison' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $repoRoot 'functions/private/Initialize-WinUtilComponentPolicyUI.ps1')
        . (Join-Path $repoRoot 'functions/private/Import-WinUtilComponentPreset.ps1')
        . (Join-Path $repoRoot 'functions/private/New-WinUtilComponentProfileComparison.ps1')
        $catalog = Get-Content (Join-Path $repoRoot 'policy/component-catalog.json') -Raw | ConvertFrom-Json
        $profiles = @(Get-ChildItem (Join-Path $repoRoot 'policy/profiles') -Filter '*.json' | ForEach-Object {
            Get-Content $_.FullName -Raw | ConvertFrom-Json
        })
    }

    It 'reports only changed actions in deterministic catalog order with review context' {
        $comparison = New-WinUtilComponentProfileComparison -Catalog $catalog -Profiles $profiles `
            -LeftProfileId 'default-winutil' -RightProfileId 'lean-daw'
        $expected = @($catalog.components | Where-Object {
            $profiles[0].actions.PSObject.Properties[[string]$_.id].Value -ne
                $profiles[1].actions.PSObject.Properties[[string]$_.id].Value
        } | ForEach-Object id)

        $comparison.LeftProfileName | Should -Be 'Default WinUtil'
        $comparison.RightProfileName | Should -Be 'Lean DAW'
        @($comparison.Items.Id) | Should -Be $expected
        $comparison.ChangedCount | Should -Be $expected.Count
        foreach ($item in $comparison.Items) {
            $item.LeftAction | Should -Not -Be $item.RightAction
            $item.Group | Should -Not -BeNullOrEmpty
            $item.Risk | Should -Not -BeNullOrEmpty
            $item.Rationale | Should -Not -BeNullOrEmpty
        }
    }

    It 'uses catalog defaults when a valid profile omits an action' {
        $partial = [pscustomobject]@{ id = 'partial'; name = 'Partial'; actions = [pscustomobject]@{} }
        $comparison = New-WinUtilComponentProfileComparison -Catalog $catalog -Profiles (@($profiles) + $partial) `
            -LeftProfileId 'partial' -RightProfileId 'lean-daw'
        ($comparison.Items | Where-Object Id -eq 'windows-search').LeftAction | Should -Be 'keep'
    }

    It 'rejects unavailable, duplicate, and identical profile selections' {
        { New-WinUtilComponentProfileComparison -Catalog $catalog -Profiles $profiles `
            -LeftProfileId 'missing' -RightProfileId 'lean-daw' } | Should -Throw "*unavailable or duplicated*"
        { New-WinUtilComponentProfileComparison -Catalog $catalog -Profiles (@($profiles) + $profiles[0]) `
            -LeftProfileId 'default-winutil' -RightProfileId 'lean-daw' } | Should -Throw "*unavailable or duplicated*"
        { New-WinUtilComponentProfileComparison -Catalog $catalog -Profiles $profiles `
            -LeftProfileId 'lean-daw' -RightProfileId 'lean-daw' } | Should -Throw "*two different*"
    }
}
