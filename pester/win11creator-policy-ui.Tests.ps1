#===========================================================================
# Tests - Win11 Creator component policy presentation
#===========================================================================

Describe 'Win11 Creator component policy presentation' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $script:repoRoot 'functions/private/Initialize-WinUtilComponentPolicyUI.ps1')

        $script:catalog = Get-Content -LiteralPath (Join-Path $script:repoRoot 'policy/component-catalog.json') -Raw | ConvertFrom-Json
        $script:profiles = @(Get-ChildItem -LiteralPath (Join-Path $script:repoRoot 'policy/profiles') -Filter *.json | ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
        })
        $script:leanModel = New-WinUtilComponentPolicyPresentation -Catalog $script:catalog -Profiles $script:profiles -SelectedProfileId 'lean-daw'
    }

    It 'shows only the two implemented profiles and Custom in product order' {
        @($script:leanModel.Profiles.Name) | Should -Be @('Default WinUtil', 'Lean DAW', 'Custom')
        @($script:leanModel.Profiles.Id) | Should -Be @('default-winutil', 'lean-daw', 'custom')
    }

    It 'includes newly implemented profile data without adding a UI placeholder' {
        $futureProfile = [pscustomobject]@{ id = 'developer'; name = 'Developer'; actions = [pscustomobject]@{} }
        $model = New-WinUtilComponentPolicyPresentation -Catalog $script:catalog -Profiles (@($script:profiles) + @($futureProfile))

        @($model.Profiles.Id) | Should -Be @('default-winutil', 'lean-daw', 'developer', 'custom')
    }

    It 'summarizes the selected profile from policy actions and risks' {
        $leanProfile = $script:profiles | Where-Object id -eq 'lean-daw'
        $expectedRemove = @($leanProfile.actions.PSObject.Properties | Where-Object Value -eq 'remove').Count
        $expectedDisable = @($leanProfile.actions.PSObject.Properties | Where-Object Value -eq 'disable').Count
        $expectedProtected = @($leanProfile.actions.PSObject.Properties | Where-Object Value -eq 'protected').Count

        $script:leanModel.Summary.RemoveCount | Should -Be $expectedRemove
        $script:leanModel.Summary.DisableCount | Should -Be $expectedDisable
        $script:leanModel.Summary.ProtectedCount | Should -Be $expectedProtected
        $script:leanModel.Summary.Risk | Should -Be 'expert'
    }

    It 'publishes all five customization groups in a stable order' {
        @($script:leanModel.Groups.Name) | Should -Be @(
            'Apps',
            'Windows Components',
            'Features & Capabilities',
            'Privacy / Runtime',
            'Developer / Virtualization'
        )
        ($script:leanModel.Groups | Where-Object Name -eq 'Apps').Items.Name | Should -Contain 'Feedback Hub'
        ($script:leanModel.Groups | Where-Object Name -eq 'Developer / Virtualization').Items.Name | Should -Contain 'NFS client'
    }

    It 'uses catalog defaults for the Custom starting state' {
        $custom = New-WinUtilComponentPolicyPresentation -Catalog $script:catalog -Profiles $script:profiles -SelectedProfileId 'custom'

        $custom.Summary.RemoveCount | Should -Be 0
        $custom.Summary.DisableCount | Should -Be 0
        $custom.Summary.ProtectedCount | Should -Be @($script:catalog.components | Where-Object defaultAction -eq 'protected').Count
    }
}

Describe 'Win11 Creator advanced package selector safeguards' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $script:repoRoot 'functions/private/Initialize-WinUtilComponentPolicyUI.ps1')

        $script:inventory = [pscustomobject]@{
            SchemaVersion = '1.0'
            Source = [pscustomobject]@{ ImagePath = 'install.wim'; ImageIndex = 6 }
            Items = @(
                [pscustomobject]@{ Kind = 'AppX'; Name = 'Feedback Hub'; Identity = 'Microsoft.WindowsFeedbackHub'; State = 'Provisioned' },
                [pscustomobject]@{ Kind = 'Feature'; Name = 'NFS client'; Identity = 'ServicesForNFS-ClientOnly'; State = 'Disabled' },
                [pscustomobject]@{ Kind = 'Package'; Name = 'Future package'; Identity = 'Contoso.Future.Package'; State = 'Installed' }
            )
        }
        $script:plan = [pscustomobject]@{
            SchemaVersion = '1.0'
            Source = $script:inventory.Source
            Decisions = @(
                [pscustomobject]@{ Kind = 'AppX'; Identity = 'Microsoft.WindowsFeedbackHub'; Action = 'Remove'; PolicyId = 'feedback-hub'; Risk = 'Safe'; Reason = 'Not required.' },
                [pscustomobject]@{ Kind = 'Feature'; Identity = 'ServicesForNFS-ClientOnly'; Action = 'Protected'; PolicyId = 'nfs'; Risk = 'High'; Reason = 'Required for development.' },
                [pscustomobject]@{ Kind = 'Package'; Identity = 'Contoso.Future.Package'; Action = 'Manual'; PolicyId = ''; Risk = ''; Reason = 'Unknown component; kept.' }
            )
        }
    }

    It 'shows kind, recommendation, and rationale from supplied inventory and plan' {
        $rows = @(New-WinUtilAdvancedPackageSelectorModel -ImageInventory $script:inventory -ResolvedPlan $script:plan)
        $feedback = $rows | Where-Object Identity -eq 'Microsoft.WindowsFeedbackHub'

        @($rows).Count | Should -Be 3
        $feedback.Kind | Should -Be 'AppX'
        $feedback.Recommendation | Should -Be 'Remove'
        $feedback.Rationale | Should -Be 'Not required.'
        $feedback.IsSelected | Should -BeTrue
    }

    It 'plants the negative invariant that unknown inventory is never auto-selected' {
        $unknown = @(New-WinUtilAdvancedPackageSelectorModel -ImageInventory $script:inventory -ResolvedPlan $script:plan -ExpertMode) |
            Where-Object Identity -eq 'Contoso.Future.Package'

        $unknown.IsUnknown | Should -BeTrue
        $unknown.CanSelect | Should -BeFalse
        $unknown.IsSelected | Should -BeFalse
        $result = Set-WinUtilAdvancedPackageSelection -Row $unknown -Selected $true -ExpertMode
        $result.IsAllowed | Should -BeFalse
        $unknown.IsSelected | Should -BeFalse
    }

    It 'plants the negative invariant that protected inventory cannot be selected without Expert mode' {
        $protected = @(New-WinUtilAdvancedPackageSelectorModel -ImageInventory $script:inventory -ResolvedPlan $script:plan) |
            Where-Object Identity -eq 'ServicesForNFS-ClientOnly'

        $protected.IsProtected | Should -BeTrue
        $protected.CanSelect | Should -BeFalse
        $result = Set-WinUtilAdvancedPackageSelection -Row $protected -Selected $true
        $result.IsAllowed | Should -BeFalse
        $result.Warning | Should -Match 'Expert mode'
        $protected.IsSelected | Should -BeFalse
    }

    It 'allows an Expert protected selection and returns the dependency risk warning' {
        $protected = @(New-WinUtilAdvancedPackageSelectorModel -ImageInventory $script:inventory -ResolvedPlan $script:plan -ExpertMode) |
            Where-Object Identity -eq 'ServicesForNFS-ClientOnly'

        $protected.CanSelect | Should -BeTrue
        $result = Set-WinUtilAdvancedPackageSelection -Row $protected -Selected $true -ExpertMode
        $result.IsAllowed | Should -BeTrue
        $result.Warning | Should -Match 'dependencies and Windows servicing'
        $protected.IsSelected | Should -BeTrue
    }

    It 'turns selector changes into actionable overrides without accepting unknown rows' {
        $rows = @(New-WinUtilAdvancedPackageSelectorModel -ImageInventory $script:inventory -ResolvedPlan $script:plan)
        $feedback = $rows | Where-Object Identity -eq 'Microsoft.WindowsFeedbackHub'
        $unknown = $rows | Where-Object Identity -eq 'Contoso.Future.Package'

        $keepFeedback = Set-WinUtilAdvancedPackageOverride -Row $feedback -Selected $false
        $rejectUnknown = Set-WinUtilAdvancedPackageOverride -Row $unknown -Selected $true -ExpertMode

        $keepFeedback.IsAllowed | Should -BeTrue
        $keepFeedback.Override.Action | Should -Be 'Keep'
        $keepFeedback.Override.Identity | Should -Be 'Microsoft.WindowsFeedbackHub'
        $rejectUnknown.IsAllowed | Should -BeFalse
        $rejectUnknown.Override | Should -BeNullOrEmpty
    }

    It 'keeps baseline recommendation separate from an effective manual override' {
        $effectivePlan = $script:plan | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        ($effectivePlan.Decisions | Where-Object Identity -eq 'Microsoft.WindowsFeedbackHub').Action = 'Keep'
        $override = [pscustomobject]@{ Kind = 'AppX'; Identity = 'Microsoft.WindowsFeedbackHub'; Action = 'Keep' }
        $row = @(New-WinUtilAdvancedPackageSelectorModel `
            -ImageInventory $script:inventory `
            -ResolvedPlan $effectivePlan `
            -RecommendationPlan $script:plan `
            -ManualOverride @($override)) | Where-Object Identity -eq 'Microsoft.WindowsFeedbackHub'

        $row.Recommendation | Should -Be 'Remove'
        $row.InitialSelected | Should -BeTrue
        $row.IsSelected | Should -BeFalse
        (Set-WinUtilAdvancedPackageOverride -Row $row -Selected $true).Override | Should -BeNullOrEmpty
    }

    It 'keeps the servicing handoff staged until inventory, plan, and registry actions are supplied' {
        $preview = New-WinUtilComponentPolicyHandoff -SelectedProfileId 'lean-daw'
        $missingRegistry = New-WinUtilComponentPolicyHandoff `
            -SelectedProfileId 'lean-daw' `
            -ImageInventory $script:inventory `
            -ResolvedPlan $script:plan `
            -OfflineSession ([pscustomobject]@{ State = 'Mounted'; InstallImagePath = 'install.wim'; ImageIndex = 6 })
        $ready = New-WinUtilComponentPolicyHandoff `
            -SelectedProfileId 'lean-daw' `
            -ImageInventory $script:inventory `
            -ResolvedPlan $script:plan `
            -Safety ([pscustomobject]@{ IsAllowed = $true }) `
            -ActionBundle ([pscustomobject]@{ IsReady = $true }) `
            -OfflineSession ([pscustomobject]@{ State = 'Mounted'; InstallImagePath = 'install.wim'; ImageIndex = 6 }) `
            -RegistryActions @()
        $unstagedSetup = New-WinUtilComponentPolicyHandoff `
            -SelectedProfileId 'lean-daw' `
            -ImageInventory $script:inventory `
            -ResolvedPlan $script:plan `
            -Safety ([pscustomobject]@{ IsAllowed = $true }) `
            -ActionBundle ([pscustomobject]@{ IsReady = $false }) `
            -OfflineSession ([pscustomobject]@{ State = 'Mounted'; InstallImagePath = 'install.wim'; ImageIndex = 6 }) `
            -RegistryActions @()

        $preview.IsReady | Should -BeFalse
        $preview.Status | Should -Match 'Preview only'
        $missingRegistry.IsReady | Should -BeFalse
        $missingRegistry.Status | Should -Match 'registry actions have not been staged'
        $unstagedSetup.IsReady | Should -BeFalse
        $unstagedSetup.Status | Should -Match 'setup actions have not been staged'
        $ready.IsReady | Should -BeTrue
    }
}

Describe 'Win11 Creator policy XAML bindings' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        [xml]$script:xaml = Get-Content -LiteralPath (Join-Path $script:repoRoot 'xaml/inputXML.xaml') -Raw
        $script:source = Get-Content -LiteralPath (Join-Path $script:repoRoot 'xaml/inputXML.xaml') -Raw
    }

    It 'defines the profile, summary, group, selector, and Expert warning controls' {
        foreach ($name in @(
            'WPFWin11ISOProfileComboBox', 'WPFWin11ISOSummaryRemove', 'WPFWin11ISOSummaryDisable',
            'WPFWin11ISOSummaryProtected', 'WPFWin11ISOSummaryRisk', 'WPFWin11ISOAppsItems',
            'WPFWin11ISOWindowsComponentsItems', 'WPFWin11ISOFeaturesItems', 'WPFWin11ISOPrivacyItems',
            'WPFWin11ISODeveloperItems', 'WPFWin11ISOAdvancedPackageItems', 'WPFWin11ISOExpertMode',
            'WPFWin11ISOExpertWarning', 'WPFWin11ISOPolicyHandoffStatus'
        )) {
            @($script:xaml.SelectNodes("//*[@Name='$name']")).Count | Should -Be 1
        }
    }

    It 'binds advanced rows to kind, recommendation, rationale, and conservative selection state' {
        $script:source | Should -Match 'Text="\{Binding Kind\}"'
        $script:source | Should -Match 'Text="\{Binding Recommendation\}"'
        $script:source | Should -Match 'Text="\{Binding Rationale\}"'
        $script:source | Should -Match 'IsChecked="\{Binding IsSelected\}" IsEnabled="\{Binding CanSelect\}"'
    }

    It 'marshals policy and selector control updates through the WPF dispatcher helper' {
        $functionSource = Get-Content -LiteralPath (Join-Path $script:repoRoot 'functions/private/Initialize-WinUtilComponentPolicyUI.ps1') -Raw

        foreach ($functionName in @('Update-WinUtilComponentPolicyUI', 'Set-WinUtilAdvancedPackageSelectorUI', 'Initialize-WinUtilComponentPolicyUI')) {
            $pattern = '(?s)function\s+' + [regex]::Escape($functionName) + '\s*\{.*?Invoke-WPFUIThread\s*\{'
            $functionSource | Should -Match $pattern
        }
    }

    It 'consumes the canonical embedded component policy bundle and wires selector overrides' {
        $functionSource = Get-Content -LiteralPath (Join-Path $script:repoRoot 'functions/private/Initialize-WinUtilComponentPolicyUI.ps1') -Raw
        $mainSource = Get-Content -LiteralPath (Join-Path $script:repoRoot 'scripts/main.ps1') -Raw

        $functionSource | Should -Match '\$sync\.configs\.componentPolicy\.catalog'
        $functionSource | Should -Match '\$sync\.configs\.componentPolicy\.profiles\.PSObject\.Properties\.Value'
        $mainSource | Should -Match 'Set-WinUtilAdvancedPackageOverride'
        $mainSource | Should -Match '\$sync\[''Win11ISOManualOverrides''\]'
        $mainSource | Should -Match 'Resolve-WinUtilComponentPolicyHandoff'
        $mainSource | Should -Match 'Win11ISOOfflineSession'
    }
}
