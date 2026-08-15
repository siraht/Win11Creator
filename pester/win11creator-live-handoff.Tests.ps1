Describe 'Win11 Creator live policy handoff' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $repoRoot 'functions/private/Import-WinUtilComponentPolicy.ps1')
        . (Join-Path $repoRoot 'functions/private/Test-WinUtilComponentSafety.ps1')
        . (Join-Path $repoRoot 'functions/private/Resolve-WinUtilOfflineImagePolicy.ps1')
        . (Join-Path $repoRoot 'functions/private/Resolve-WinUtilComponentPolicyPlan.ps1')
        . (Join-Path $repoRoot 'functions/private/Initialize-WinUtilComponentPolicyUI.ps1')

        function Invoke-WPFUIThread { param([scriptblock]$ScriptBlock) & $ScriptBlock }
        function New-TestControl {
            [pscustomobject]@{ Text = ''; Foreground = ''; IsEnabled = $false; IsChecked = $false; Visibility = 'Collapsed'; ItemsSource = @() }
        }

        $catalog = Get-Content (Join-Path $repoRoot 'policy/component-catalog.json') -Raw | ConvertFrom-Json
        $profiles = [pscustomobject]@{
            'default-winutil' = Get-Content (Join-Path $repoRoot 'policy/profiles/default-winutil.json') -Raw | ConvertFrom-Json
            'lean-daw' = Get-Content (Join-Path $repoRoot 'policy/profiles/lean-daw.json') -Raw | ConvertFrom-Json
        }
        $script:inventory = [pscustomobject]@{
            SchemaVersion = '1.0'
            Source = [pscustomobject]@{ ImagePath = 'copied-install.wim'; ImageIndex = 6; ImageName = 'Windows 11 Pro' }
            Items = @(
                [pscustomobject]@{ Kind = 'AppX'; Name = 'Microsoft.WindowsFeedbackHub'; Identity = 'Microsoft.WindowsFeedbackHub_1.0_neutral_~_8wekyb3d8bbwe'; State = 'Provisioned' },
                [pscustomobject]@{ Kind = 'Package'; Name = 'Microsoft-Windows-StartMenuExperienceHost-Package'; Identity = 'Microsoft-Windows-StartMenuExperienceHost-Package~31bf~amd64~~10.0.1.0'; State = 'Installed' },
                [pscustomobject]@{ Kind = 'Package'; Name = 'Unknown'; Identity = 'Contoso.Unknown~test'; State = 'Installed' }
            )
        }
        $global:sync = [hashtable]::Synchronized(@{
            configs = @{ componentPolicy = [pscustomobject]@{ catalog = $catalog; profiles = $profiles } }
            Win11ISOSelectedProfileId = 'default-winutil'
            Win11ISOImageInventory = $script:inventory
            Win11ISOManualOverrides = @()
            WPFWin11ISOExpertMode = New-TestControl
            WPFWin11ISOAdvancedPackageItems = New-TestControl
            WPFWin11ISOExpertWarning = New-TestControl
            WPFWin11ISOPolicyHandoffStatus = New-TestControl
            WPFWin11ISOModifyButton = New-TestControl
            WPFWin11ISOSummaryRemove = New-TestControl
            WPFWin11ISOSummaryDisable = New-TestControl
            WPFWin11ISOSummaryProtected = New-TestControl
            WPFWin11ISOSummaryRisk = New-TestControl
            WPFWin11ISOExclusiveChoices = New-TestControl
            WPFWin11ISOAppsItems = New-TestControl
            WPFWin11ISOWindowsComponentsItems = New-TestControl
            WPFWin11ISOFeaturesItems = New-TestControl
            WPFWin11ISOPrivacyItems = New-TestControl
            WPFWin11ISODeveloperItems = New-TestControl
        })
    }

    BeforeEach {
        $sync.Win11ISOSelectedProfileId = 'default-winutil'
        $sync.Win11ISOImageInventory = $script:inventory
        $sync.Win11ISOManualOverrides = @()
        $sync.Win11ISOComponentActionOverrides = @{}
        $sync.Win11ISOOfflineSession = [pscustomobject]@{
            State = 'Mounted'; InstallImagePath = 'copied-install.wim'; ImageIndex = 6
            OfflineSystemSelect = [pscustomobject]@{ Current = 1 }
        }
        $sync.WPFWin11ISOExpertMode.IsChecked = $false
        $sync.WPFWin11ISOModifyButton.IsEnabled = $false
    }

    It 'freshly resolves canonical policy and enables build only when ready' {
        $result = Resolve-WinUtilComponentPolicyHandoff

        $result.ProfileId | Should -Be 'default-winutil'
        $sync.Win11ISOResolvedPlan | Should -Not -BeNullOrEmpty
        $sync.Win11ISOPolicyHandoff.IsReady | Should -BeTrue
        $sync.WPFWin11ISOModifyButton.IsEnabled | Should -BeTrue
        ($sync.Win11ISOResolvedPlan.Decisions | Where-Object Identity -eq 'Contoso.Unknown~test').Action | Should -Be 'Manual'
    }

    It 'regenerates a changed manual override instead of leaving a stale null plan' {
        Resolve-WinUtilComponentPolicyHandoff | Out-Null
        $sync.Win11ISOManualOverrides = @([pscustomobject]@{
            Kind = 'AppX'; Identity = 'Microsoft.WindowsFeedbackHub_1.0_neutral_~_8wekyb3d8bbwe'; Action = 'Remove'; Reason = 'Test override.'
        })

        Resolve-WinUtilComponentPolicyHandoff | Out-Null

        $sync.Win11ISOResolvedPlan | Should -Not -BeNullOrEmpty
        ($sync.Win11ISOResolvedPlan.Decisions | Where-Object Name -eq 'Microsoft.WindowsFeedbackHub').Action | Should -Be 'Remove'
    }

    It 'visibly blocks build for a protected override without Expert mode' {
        $sync.Win11ISOManualOverrides = @([pscustomobject]@{
            Kind = 'Package'; Identity = 'Microsoft-Windows-StartMenuExperienceHost-Package~31bf~amd64~~10.0.1.0'; Action = 'Remove'; Reason = 'Blocked test.'
        })

        Resolve-WinUtilComponentPolicyHandoff | Out-Null

        $sync.Win11ISOPolicyHandoff.IsReady | Should -BeFalse
        $sync.Win11ISOResolvedPlan.Safety.IsAllowed | Should -BeFalse
        $sync.WPFWin11ISOModifyButton.IsEnabled | Should -BeFalse
        $sync.WPFWin11ISOPolicyHandoffStatus.Text | Should -Match '^Blocked:'
    }

    It 'wires analyze, build, edition invalidation, cancel, and app-exit cleanup' {
        $main = Get-Content (Join-Path $repoRoot 'scripts/main.ps1') -Raw
        $isoSource = Get-Content (Join-Path $repoRoot 'functions/private/Invoke-WinUtilISO.ps1') -Raw

        $main | Should -Match '(?s)WPFWin11ISOAnalyzeButton.*Invoke-WinUtilISOAnalyze'
        $main | Should -Match 'WPFWin11ISOEditionComboBox\.Add_SelectionChanged'
        $main | Should -Match '(?s)Add_Closing.*Stop-WinUtilOfflineServicingSession'
        $isoSource | Should -Match '(?s)function Invoke-WinUtilISOCleanAndReset.*Stop-WinUtilOfflineServicingSession'
        $isoSource | Should -Match '(?s)ERROR during edition analysis.*Stop-WinUtilOfflineServicingSession.*Remove-Item'
    }

    It 'prepares ESD and resolves the typed action bundle before the single analysis mount' {
        $isoSource = Get-Content (Join-Path $repoRoot 'functions/private/Invoke-WinUtilISO.ps1') -Raw
        $uiSource = Get-Content (Join-Path $repoRoot 'functions/private/Initialize-WinUtilComponentPolicyUI.ps1') -Raw
        $exportIndex = $isoSource.IndexOf('Export-WinUtilEsdImageToWim')
        $controlSetIndex = $isoSource.IndexOf('Get-WinUtilOfflineSystemSelect')
        $mountIndex = $isoSource.IndexOf('$session = Start-WinUtilOfflineServicingSession')

        $exportIndex | Should -BeGreaterThan -1
        $mountIndex | Should -BeGreaterThan $exportIndex
        $controlSetIndex | Should -BeGreaterThan $mountIndex
        $uiSource | Should -Match '-OfflineSystemSelect \$sync\[''Win11ISOOfflineSession''\]\.OfflineSystemSelect'
        $uiSource | Should -Match '\$result\.ActionBundle\.RegistryActions'
        $uiSource | Should -Match '-ActionBundle \$result\.ActionBundle'
    }

    It 'carries an exclusive UAC UI choice into the typed live action bundle' {
        $sync.Win11ISOComponentActionOverrides = @{
            'uac-prompt-suppression' = 'disable'
            'uac' = 'keep'
        }

        $result = Resolve-WinUtilComponentPolicyHandoff

        $result.Safety.IsAllowed | Should -BeTrue
        $result.ActionBundle.RegistryActions | Where-Object {
            $_.Name -eq 'EnableLUA' -and [int]$_.Value -eq 1
        } | Should -HaveCount 1
        $result.ActionBundle.RegistryActions.Name | Should -Contain 'ConsentPromptBehaviorAdmin'
        $sync.Win11ISOActionBundle | Should -Be $result.ActionBundle
    }

    It 're-resolves profile, summary, groups, selector, and readiness from a mounted analysis' {
        $sync.WPFWin11ISOExpertMode.IsChecked = $true

        Update-WinUtilComponentPolicyUI -SelectedProfileId 'lean-daw'

        $sync.Win11ISOSelectedProfileId | Should -Be 'lean-daw'
        ($sync.Win11ISOResolvedPlan.Decisions | Where-Object Name -eq 'Microsoft.WindowsFeedbackHub').Action | Should -Be 'Remove'
        $sync.WPFWin11ISOSummaryRemove.Text | Should -BeGreaterThan 0
        @($sync.WPFWin11ISOAppsItems.ItemsSource).Count | Should -BeGreaterThan 0
        @($sync.WPFWin11ISOAdvancedPackageItems.ItemsSource).Count | Should -Be 3
        $sync.Win11ISOPolicyHandoff.IsReady | Should -BeTrue
        $sync.WPFWin11ISOModifyButton.IsEnabled | Should -BeTrue
    }

    It 'plants the negative that stale inventory cannot retain a ready build state' {
        Resolve-WinUtilComponentPolicyHandoff | Out-Null
        $sync.Win11ISOOfflineSession.ImageIndex = 5

        Update-WinUtilComponentPolicyUI -SelectedProfileId 'default-winutil'

        $sync.Win11ISOResolvedPlan | Should -BeNullOrEmpty
        $sync.Win11ISOActionBundle | Should -BeNullOrEmpty
        $sync.Win11ISOPolicyHandoff.IsReady | Should -BeFalse
        $sync.Win11ISOPolicyHandoff.Status | Should -Match '^Blocked:.*does not match'
        $sync.WPFWin11ISOModifyButton.IsEnabled | Should -BeFalse
    }

    It 'clears inventory overrides and readiness before an analysis refresh' {
        Resolve-WinUtilComponentPolicyHandoff | Out-Null
        $sync.Win11ISOManualOverrides = @([pscustomobject]@{
            Kind = 'AppX'; Identity = 'Microsoft.WindowsFeedbackHub_1.0_neutral_~_8wekyb3d8bbwe'; Action = 'Keep'
        })

        Clear-WinUtilComponentPolicyAnalysisState

        $sync.Win11ISOImageInventory | Should -BeNullOrEmpty
        $sync.Win11ISOManualOverrides | Should -BeNullOrEmpty
        $sync.Win11ISOResolvedPlan | Should -BeNullOrEmpty
        $sync.Win11ISOPolicyHandoff.IsReady | Should -BeFalse
        $sync.WPFWin11ISOModifyButton.IsEnabled | Should -BeFalse
    }

    It 'plants the negative that leaving Expert mode blocks a selected protected override' {
        $sync.Win11ISOManualOverrides = @([pscustomobject]@{
            Kind = 'Package'; Identity = 'Microsoft-Windows-StartMenuExperienceHost-Package~31bf~amd64~~10.0.1.0'; Action = 'Remove'
        })
        $sync.WPFWin11ISOExpertMode.IsChecked = $true
        Resolve-WinUtilComponentPolicyHandoff | Out-Null
        $sync.Win11ISOPolicyHandoff.IsReady | Should -BeTrue

        $sync.WPFWin11ISOExpertMode.IsChecked = $false
        Resolve-WinUtilComponentPolicyHandoff | Out-Null

        $sync.Win11ISOPolicyHandoff.IsReady | Should -BeFalse
        $sync.WPFWin11ISOModifyButton.IsEnabled | Should -BeFalse
        $sync.WPFWin11ISOExpertWarning.Visibility | Should -Be 'Visible'
        $sync.WPFWin11ISOExpertWarning.Text | Should -Match 'Blocked by component safety policy'
    }
}
