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

Describe 'Win11 Creator component profile comparison headless UI state' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $repoRoot 'functions/private/Initialize-WinUtilComponentPolicyUI.ps1')
        . (Join-Path $repoRoot 'functions/private/Import-WinUtilComponentPreset.ps1')
        . (Join-Path $repoRoot 'functions/private/New-WinUtilComponentProfileComparison.ps1')
        . (Join-Path $repoRoot 'functions/private/Initialize-WinUtilComponentProfileComparisonUI.ps1')
        function Invoke-WPFUIThread { param([scriptblock]$ScriptBlock) & $ScriptBlock }
    }

    BeforeEach {
        $catalog = Get-Content (Join-Path $repoRoot 'policy/component-catalog.json') -Raw | ConvertFrom-Json
        $default = Get-Content (Join-Path $repoRoot 'policy/profiles/default-winutil.json') -Raw | ConvertFrom-Json
        $lean = Get-Content (Join-Path $repoRoot 'policy/profiles/lean-daw.json') -Raw | ConvertFrom-Json
        $script:sync = @{
            configs = [pscustomobject]@{ componentPolicy = [pscustomobject]@{
                catalog = $catalog
                profiles = [pscustomobject]@{ 'default-winutil' = $default; 'lean-daw' = $lean }
            } }
            WPFWin11ISOCompareLeftProfile = [pscustomobject]@{ ItemsSource = $null; DisplayMemberPath = ''; SelectedValuePath = ''; SelectedValue = '' }
            WPFWin11ISOCompareRightProfile = [pscustomobject]@{ ItemsSource = $null; DisplayMemberPath = ''; SelectedValuePath = ''; SelectedValue = '' }
            WPFWin11ISOProfileDiffStatus = [pscustomobject]@{ Text = ''; Foreground = '' }
            WPFWin11ISOProfileComboBox = [pscustomobject]@{ Foreground = 'White' }
            WPFWin11ISOProfileDiffLeftHeader = [pscustomobject]@{ Text = '' }
            WPFWin11ISOProfileDiffRightHeader = [pscustomobject]@{ Text = '' }
            WPFWin11ISOProfileDiffItems = [pscustomobject]@{ ItemsSource = $null }
        }
    }

    It 'initializes both selectors and renders the canonical profile differences' {
        Initialize-WinUtilComponentProfileComparisonUI

        @($sync.WPFWin11ISOCompareLeftProfile.ItemsSource).Count | Should -Be 2
        $sync.WPFWin11ISOCompareLeftProfile.SelectedValue | Should -Be 'default-winutil'
        $sync.WPFWin11ISOCompareRightProfile.SelectedValue | Should -Be 'lean-daw'
        $sync.WPFWin11ISOProfileDiffLeftHeader.Text | Should -Be 'Default WinUtil'
        $sync.WPFWin11ISOProfileDiffRightHeader.Text | Should -Be 'Lean DAW'
        @($sync.WPFWin11ISOProfileDiffItems.ItemsSource).Count | Should -BeGreaterThan 0
        $sync.WPFWin11ISOProfileDiffStatus.Text | Should -Match '^Showing [0-9]+ changed component actions\.$'
    }

    It 'clears stale results and announces an identical selection as invalid' {
        Initialize-WinUtilComponentProfileComparisonUI
        $sync.WPFWin11ISOCompareRightProfile.SelectedValue = 'default-winutil'
        Update-WinUtilComponentProfileComparisonUI

        $sync.WPFWin11ISOComponentProfileComparison | Should -BeNullOrEmpty
        @($sync.WPFWin11ISOProfileDiffItems.ItemsSource).Count | Should -Be 0
        $sync.WPFWin11ISOProfileDiffStatus.Text | Should -Be 'Choose two different component profiles to compare.'
        $sync.WPFWin11ISOProfileDiffStatus.Foreground | Should -Be 'OrangeRed'
    }
}
