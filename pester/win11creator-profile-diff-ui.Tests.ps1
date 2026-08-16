Describe 'Win11 Creator component profile comparison UI contract' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        [xml]$xaml = Get-Content (Join-Path $repoRoot 'xaml/inputXML.xaml') -Raw
        $xamlSource = Get-Content (Join-Path $repoRoot 'xaml/inputXML.xaml') -Raw
        $mainSource = Get-Content (Join-Path $repoRoot 'scripts/main.ps1') -Raw
        $modelSource = Get-Content (Join-Path $repoRoot 'functions/private/New-WinUtilComponentProfileComparison.ps1') -Raw
        $functionSource = Get-Content (Join-Path $repoRoot 'functions/private/Initialize-WinUtilComponentProfileComparisonUI.ps1') -Raw
    }

    It 'defines accessible selectors, status, action columns, and results view' {
        foreach ($name in @('WPFWin11ISOCompareLeftProfile', 'WPFWin11ISOCompareRightProfile',
            'WPFWin11ISOCompareProfilesButton', 'WPFWin11ISOProfileDiffStatus', 'WPFWin11ISOProfileDiffLeftHeader',
            'WPFWin11ISOProfileDiffRightHeader', 'WPFWin11ISOProfileDiffItems')) {
            @($xaml.SelectNodes("//*[@Name='$name']")).Count | Should -Be 1
        }
        $xamlSource | Should -Match 'AutomationProperties.Name="First profile to compare"'
        $xamlSource | Should -Match 'AutomationProperties.Name="Second profile to compare"'
        $xamlSource | Should -Match 'AutomationProperties.LiveSetting="Polite"'
        foreach ($binding in @('Name', 'LeftAction', 'RightAction', 'Risk', 'Rationale')) {
            $xamlSource | Should -Match ('Text="\{Binding ' + $binding + '\}"')
        }
    }

    It 'wires comparison initialization and button refresh through dispatcher-safe functions' {
        $mainSource | Should -Match 'WPFWin11ISOCompareProfilesButton\.Add_Click'
        $mainSource | Should -Match 'Update-WinUtilComponentProfileComparisonUI'
        $functionSource | Should -Match '(?s)function\s+Initialize-WinUtilComponentProfileComparisonUI.*?Invoke-WPFUIThread'
        $functionSource | Should -Match '(?s)function\s+Update-WinUtilComponentProfileComparisonUI.*?Invoke-WPFUIThread'
        $modelSource | Should -Match 'Get-WinUtilEffectiveComponentPresetActionMap'
    }
}
