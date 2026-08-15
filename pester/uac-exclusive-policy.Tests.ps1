#===========================================================================
# Tests - Mutually exclusive UAC policy modes
#===========================================================================

Describe 'Mutually exclusive UAC policy modes' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $script:repoRoot 'functions/private/Import-WinUtilComponentPolicy.ps1')
        . (Join-Path $script:repoRoot 'functions/private/Test-WinUtilComponentSafety.ps1')
        . (Join-Path $script:repoRoot 'functions/private/Resolve-WinUtilOfflineImagePolicy.ps1')
        . (Join-Path $script:repoRoot 'functions/private/Resolve-WinUtilComponentPolicyPlan.ps1')

        $policyRoot = Join-Path $script:repoRoot 'policy'
        $script:catalog = Import-WinUtilComponentPolicy -Path (Join-Path $policyRoot 'component-catalog.json')
        $script:defaultProfile = Import-WinUtilComponentPolicy -Path (Join-Path $policyRoot 'profiles/default-winutil.json') -Catalog $script:catalog
        $script:leanProfile = Import-WinUtilComponentPolicy -Path (Join-Path $policyRoot 'profiles/lean-daw.json') -Catalog $script:catalog
        $script:inventory = [pscustomobject]@{
            SchemaVersion = '1.0'
            Source = [pscustomobject]@{ ImagePath = 'install.wim'; ImageIndex = 1; ImageName = 'Windows 11 Pro' }
            Items = @()
        }
    }

    It 'keeps UAC in Default and selects full disable in Lean DAW' {
        $script:defaultProfile.actions.uac | Should -Be 'keep'
        $script:defaultProfile.actions.'uac-prompt-suppression' | Should -Be 'keep'
        $script:leanProfile.actions.uac | Should -Be 'disable'
        $script:leanProfile.actions.'uac-prompt-suppression' | Should -Be 'keep'
    }

    It 'emits the exact typed full-disable registry action and Store conflict evidence' {
        $result = Resolve-WinUtilComponentPolicyPlan -Inventory $script:inventory -Catalog $script:catalog -Profile $script:leanProfile -ExpertMode
        $uacActions = @($result.ActionBundle.RegistryActions | Where-Object SourceComponentId -eq 'uac')

        $uacActions | Should -HaveCount 1
        $uacActions[0].Action | Should -Be 'Set'
        $uacActions[0].Hive | Should -Be 'SOFTWARE'
        $uacActions[0].Key | Should -Be 'Microsoft\Windows\CurrentVersion\Policies\System'
        $uacActions[0].Name | Should -Be 'EnableLUA'
        $uacActions[0].Type | Should -Be 'REG_DWORD'
        $uacActions[0].Value | Should -Be 0
        $result.Safety.Conflicts | Where-Object {
            $_.ComponentId -eq 'uac' -and $_.RelatedComponentId -eq 'microsoft-store-infrastructure' -and
            $_.Severity -eq 'forbidden-unless-expert'
        } | Should -HaveCount 1
    }

    It 'emits supported prompt-suppression values while explicitly retaining EnableLUA' {
        $result = Resolve-WinUtilComponentPolicyPlan -Inventory $script:inventory -Catalog $script:catalog -Profile $script:defaultProfile -ActionOverrides @{
            'uac-prompt-suppression' = 'disable'
        }
        $actions = @($result.ActionBundle.RegistryActions | Where-Object SourceComponentId -eq 'uac-prompt-suppression')

        $actions | Should -HaveCount 4
        foreach ($expected in @(
            @{ Name = 'EnableLUA'; Value = 1 },
            @{ Name = 'ConsentPromptBehaviorAdmin'; Value = 0 },
            @{ Name = 'ConsentPromptBehaviorUser'; Value = 0 },
            @{ Name = 'PromptOnSecureDesktop'; Value = 0 }
        )) {
            $actions | Where-Object {
                $_.Action -eq 'Set' -and $_.Hive -eq 'SOFTWARE' -and
                $_.Key -eq 'Microsoft\Windows\CurrentVersion\Policies\System' -and
                $_.Name -eq $expected.Name -and $_.Type -eq 'REG_DWORD' -and $_.Value -eq $expected.Value
            } | Should -HaveCount 1
        }
        $result.Safety.IsAllowed | Should -BeTrue
    }

    It 'blocks a planted conflicting selection even in Expert mode' {
        $result = Resolve-WinUtilComponentPolicyPlan -Inventory $script:inventory -Catalog $script:catalog -Profile $script:leanProfile -ActionOverrides @{
            'uac-prompt-suppression' = 'disable'
        } -ExpertMode

        $result.Safety.IsAllowed | Should -BeFalse
        $result.Safety.Conflicts | Where-Object {
            $_.Severity -eq 'mutually-exclusive-selection' -and $_.IsBlocking
        } | Should -HaveCount 1
    }

    It 'rejects a planted profile conflict during policy validation' {
        $invalidProfile = $script:leanProfile | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $invalidProfile.actions.'uac-prompt-suppression' = 'disable'

        { Test-WinUtilComponentPolicy -Policy $invalidProfile -Catalog $script:catalog -ThrowOnError } |
            Should -Throw '*mutually exclusive components*'
    }
}
