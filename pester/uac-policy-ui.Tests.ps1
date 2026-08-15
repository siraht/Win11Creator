#===========================================================================
# Tests - UAC exclusive-choice presentation
#===========================================================================

Describe 'UAC exclusive-choice presentation' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $script:repoRoot 'functions/private/Initialize-WinUtilComponentPolicyUI.ps1')
        $script:catalog = Get-Content -LiteralPath (Join-Path $script:repoRoot 'policy/component-catalog.json') -Raw | ConvertFrom-Json
        $script:profiles = @(Get-ChildItem -LiteralPath (Join-Path $script:repoRoot 'policy/profiles') -Filter *.json | ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
        })
    }

    It 'derives three distinct UAC choices and their visible risks from policy data' {
        $model = New-WinUtilComponentPolicyPresentation -Catalog $script:catalog -Profiles $script:profiles
        $uacGroup = $model.ChoiceGroups | Where-Object Id -eq 'uac-mode'

        @($uacGroup.Options.Id) | Should -Be @('keep', 'uac-prompt-suppression', 'uac')
        ($uacGroup.Options | Where-Object Id -eq 'uac-prompt-suppression').Risk | Should -Be 'high'
        ($uacGroup.Options | Where-Object Id -eq 'uac').Risk | Should -Be 'expert'
        ($uacGroup.Options | Where-Object Id -eq 'uac').Description | Should -Match 'Store'
    }

    It 'selects keep for Default and full disable for Lean DAW' {
        $defaultModel = New-WinUtilComponentPolicyPresentation -Catalog $script:catalog -Profiles $script:profiles -SelectedProfileId 'default-winutil'
        $leanModel = New-WinUtilComponentPolicyPresentation -Catalog $script:catalog -Profiles $script:profiles -SelectedProfileId 'lean-daw'

        ($defaultModel.ChoiceGroups | Where-Object Id -eq 'uac-mode').SelectedChoiceId | Should -Be 'keep'
        ($leanModel.ChoiceGroups | Where-Object Id -eq 'uac-mode').SelectedChoiceId | Should -Be 'uac'
    }

    It 'turns a UI choice into mutually exclusive resolver action overrides' {
        $model = New-WinUtilComponentPolicyPresentation -Catalog $script:catalog -Profiles $script:profiles -SelectedProfileId 'lean-daw'
        $uacGroup = $model.ChoiceGroups | Where-Object Id -eq 'uac-mode'
        $result = Set-WinUtilExclusiveComponentChoice -ChoiceGroup $uacGroup -SelectedChoiceId 'uac-prompt-suppression' -ExistingOverrides @{
            'feedback-hub' = 'keep'
        }

        $result.ActionOverrides.'uac-prompt-suppression' | Should -Be 'disable'
        $result.ActionOverrides.uac | Should -Be 'keep'
        $result.ActionOverrides.'feedback-hub' | Should -Be 'keep'
        $result.Risk | Should -Be 'high'
        $result.Warning | Should -Match 'weakens elevation protection'
    }

    It 'plants the negative that an unknown choice cannot create overrides' {
        $model = New-WinUtilComponentPolicyPresentation -Catalog $script:catalog -Profiles $script:profiles
        $uacGroup = $model.ChoiceGroups | Where-Object Id -eq 'uac-mode'

        { Set-WinUtilExclusiveComponentChoice -ChoiceGroup $uacGroup -SelectedChoiceId 'both' } |
            Should -Throw "*not valid for exclusive group 'uac-mode'*"
    }

    It 'plants the negative that conflicting presentation state is rejected' {
        {
            New-WinUtilComponentPolicyPresentation -Catalog $script:catalog -Profiles $script:profiles -SelectedProfileId 'default-winutil' -ActionOverrides @{
                'uac-prompt-suppression' = 'disable'
                'uac' = 'disable'
            }
        } | Should -Throw "*more than one active choice*"
    }
}

Describe 'UAC exclusive-choice XAML and event wiring' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        [xml]$script:xaml = Get-Content -LiteralPath (Join-Path $script:repoRoot 'xaml/inputXML.xaml') -Raw
        $script:xamlSource = Get-Content -LiteralPath (Join-Path $script:repoRoot 'xaml/inputXML.xaml') -Raw
        $script:mainSource = Get-Content -LiteralPath (Join-Path $script:repoRoot 'scripts/main.ps1') -Raw
    }

    It 'provides a policy-bound exclusive choice selector without UAC-specific XAML' {
        @($script:xaml.SelectNodes("//*[@Name='WPFWin11ISOExclusiveChoices']")).Count | Should -Be 1
        $script:xamlSource | Should -Match 'ItemsSource="\{Binding Options\}"'
        $script:xamlSource | Should -Match 'SelectedValue="\{Binding SelectedChoiceId, Mode=OneWay\}"'
        $script:xamlSource | Should -Not -Match 'uac-prompt-suppression|EnableLUA'
    }

    It 'stores resolver-ready overrides and invalidates stale servicing artifacts' {
        $script:mainSource | Should -Match 'Set-WinUtilExclusiveComponentChoice'
        $script:mainSource | Should -Match 'Win11ISOComponentActionOverrides'
        $functionSource = Get-Content -LiteralPath (Join-Path $script:repoRoot 'functions/private/Initialize-WinUtilComponentPolicyUI.ps1') -Raw
        $functionSource | Should -Match '\$sync\[''Win11ISOResolvedPlan''\]\s*=\s*\$null'
        $functionSource | Should -Match '\$sync\[''Win11ISORegistryActions''\]\s*=\s*\$null'
    }
}
