#===========================================================================
# Tests - Component policy adapter and offline plan integration
#===========================================================================

Describe 'Component policy plan integration' {
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
            Items = @(
                [pscustomobject]@{ Kind = 'AppX'; Name = 'Microsoft.WindowsFeedbackHub'; Identity = 'Microsoft.WindowsFeedbackHub_1.0_neutral_~_8wekyb3d8bbwe'; State = 'Installed' }
                [pscustomobject]@{ Kind = 'Feature'; Name = 'ServicesForNFS-ClientOnly'; Identity = 'ServicesForNFS-ClientOnly'; State = 'Enabled' }
                [pscustomobject]@{ Kind = 'Package'; Name = 'Microsoft-Windows-StartMenuExperienceHost-Package'; Identity = 'Microsoft-Windows-StartMenuExperienceHost-Package~31bf~amd64~~10.0.1.0'; State = 'Installed' }
                [pscustomobject]@{ Kind = 'Package'; Name = 'Contoso.Future-Package'; Identity = 'Contoso.Future-Package~31bf~amd64~~1.0.0.0'; State = 'Installed' }
                [pscustomobject]@{ Kind = 'SystemApp'; Name = 'MicrosoftWindows.Client.WebExperience_cw5n1h2txyewy'; Identity = 'MicrosoftWindows.Client.WebExperience_cw5n1h2txyewy'; State = 'Discovered' }
            )
        }
    }

    It 'PolicyAdapter_DefaultAndLeanProfilesProduceDifferentResolvedPlans' {
        $defaultResult = Resolve-WinUtilComponentPolicyPlan -Inventory $script:inventory -Catalog $script:catalog -Profile $script:defaultProfile
        $leanResult = Resolve-WinUtilComponentPolicyPlan -Inventory $script:inventory -Catalog $script:catalog -Profile $script:leanProfile -ExpertMode

        ($defaultResult.ResolvedPlan.Decisions | Where-Object Name -eq 'Microsoft.WindowsFeedbackHub').Action | Should -Be 'Keep'
        ($leanResult.ResolvedPlan.Decisions | Where-Object Name -eq 'Microsoft.WindowsFeedbackHub').Action | Should -Be 'Remove'
        $leanResult.Safety.Conflicts | Where-Object {
            $_.ComponentId -eq 'uac' -and $_.RelatedComponentId -eq 'microsoft-store-infrastructure'
        } | Should -HaveCount 1
    }

    It 'PolicyAdapter_KeepsUnknownInventoryAndProtectsLeanNfs' {
        $result = Resolve-WinUtilComponentPolicyPlan -Inventory $script:inventory -Catalog $script:catalog -Profile $script:leanProfile -ExpertMode

        $unknown = $result.ResolvedPlan.Decisions | Where-Object Name -eq 'Contoso.Future-Package'
        $unknown.Action | Should -Be 'Manual'
        $unknown.Reason | Should -Match 'kept unless explicitly overridden'
        ($result.ResolvedPlan.Decisions | Where-Object Kind -eq 'SystemApp').Action | Should -Be 'Manual'
        ($result.ResolvedPlan.Decisions | Where-Object Name -eq 'ServicesForNFS-ClientOnly').Action | Should -Be 'Protected'
    }

    It 'PolicyAdapter_BlocksProtectedOverrideWithoutExpertAndRetainsEvidence' {
        $result = Resolve-WinUtilComponentPolicyPlan -Inventory $script:inventory -Catalog $script:catalog -Profile $script:defaultProfile -ActionOverrides @{
            'modern-shell' = 'remove'
        }

        $result.Safety.IsAllowed | Should -BeFalse
        $result.ResolvedPlan.IsAllowed | Should -BeFalse
        [object]::ReferenceEquals($result.ResolvedPlan.Safety, $result.Safety) | Should -BeTrue
        $result.Safety.Conflicts | Where-Object {
            $_.ComponentId -eq 'modern-shell' -and
            $_.Severity -eq 'forbidden-unless-expert' -and
            $_.IsBlocking
        } | Should -HaveCount 1
    }

    It 'PolicyAdapter_ExpertOverrideRetainsNonblockingConflictEvidence' {
        $result = Resolve-WinUtilComponentPolicyPlan -Inventory $script:inventory -Catalog $script:catalog -Profile $script:defaultProfile -ActionOverrides @{
            'modern-shell' = 'remove'
        } -ExpertMode

        $result.Safety.IsAllowed | Should -BeTrue
        $result.ResolvedPlan.IsAllowed | Should -BeTrue
        $result.ResolvedPlan.Safety.Conflicts | Should -Not -BeNullOrEmpty
        $result.Safety.Conflicts | Where-Object {
            $_.ComponentId -eq 'modern-shell' -and
            $_.Severity -eq 'forbidden-unless-expert' -and
            -not $_.IsBlocking
        } | Should -HaveCount 1
        ($result.ResolvedPlan.Decisions | Where-Object Name -eq 'Microsoft-Windows-StartMenuExperienceHost-Package').Action | Should -Be 'Remove'
    }

    It 'regenerates an Expert inventory override with retained protection evidence' {
        $override = @([pscustomobject]@{ Kind = 'Feature'; Identity = 'ServicesForNFS-ClientOnly'; Action = 'Remove'; Reason = 'Expert selection.' })
        $result = Resolve-WinUtilComponentPolicyPlan -Inventory $script:inventory -Catalog $script:catalog -Profile $script:leanProfile -ActionOverrides @{ defender = 'keep' } -ManualOverride $override -OfflineSystemSelect ([pscustomobject]@{ Current = 1 }) -ExpertMode

        ($result.ResolvedPlan.Decisions | Where-Object Identity -eq 'ServicesForNFS-ClientOnly').Action | Should -Be 'Remove'
        $result.Safety.IsAllowed | Should -BeTrue
        $result.Safety.Conflicts | Where-Object { $_.RelatedComponentId -eq 'ServicesForNFS-ClientOnly' -and -not $_.IsBlocking } | Should -HaveCount 1
    }

    It 'keeps unknown inventory closed to manual removal' {
        $override = @([pscustomobject]@{ Kind = 'Package'; Identity = 'Contoso.Future-Package~31bf~amd64~~1.0.0.0'; Action = 'Remove' })
        { Resolve-WinUtilComponentPolicyPlan -Inventory $script:inventory -Catalog $script:catalog -Profile $script:leanProfile -ManualOverride $override -ExpertMode } |
            Should -Throw '*remains kept and cannot be overridden*'
    }

    It 'resolves concrete Lean app and AI targets without selecting protected WebView2 or Client CBS' {
        $inventory = [pscustomobject]@{
            SchemaVersion = '1.0'; Source = $script:inventory.Source
            Items = @(
                [pscustomobject]@{ Kind = 'AppX'; Name = 'MicrosoftWindows.Client.WebExperience'; Identity = 'MicrosoftWindows.Client.WebExperience_1.0_neutral_~_cw5n1h2txyewy'; State = 'Provisioned' }
                [pscustomobject]@{ Kind = 'AppX'; Name = 'Microsoft.Copilot'; Identity = 'Microsoft.Copilot_1.0_neutral_~_8wekyb3d8bbwe'; State = 'Provisioned' }
                [pscustomobject]@{ Kind = 'AppX'; Name = 'Microsoft.WindowsFeedbackHub'; Identity = 'Microsoft.WindowsFeedbackHub_1.0_neutral_~_8wekyb3d8bbwe'; State = 'Provisioned' }
                [pscustomobject]@{ Kind = 'AppX'; Name = 'Microsoft.BingNews'; Identity = 'Microsoft.BingNews_1.0_neutral_~_8wekyb3d8bbwe'; State = 'Provisioned' }
                [pscustomobject]@{ Kind = 'AppX'; Name = 'Microsoft.XboxApp'; Identity = 'Microsoft.XboxApp_1.0_neutral_~_8wekyb3d8bbwe'; State = 'Provisioned' }
                [pscustomobject]@{ Kind = 'AppX'; Name = 'Microsoft.OneDriveSync'; Identity = 'Microsoft.OneDriveSync_1.0_neutral_~_8wekyb3d8bbwe'; State = 'Provisioned' }
                [pscustomobject]@{ Kind = 'Package'; Name = 'Microsoft-Windows-Client-AIX-Package'; Identity = 'Microsoft-Windows-Client-AIX-Package~31bf~amd64~~10.0.26200.1'; State = 'Installed' }
                [pscustomobject]@{ Kind = 'Package'; Name = 'Microsoft-Windows-OneDrive-Package'; Identity = 'Microsoft-Windows-OneDrive-Package~31bf~amd64~~10.0.26200.1'; State = 'Installed' }
                [pscustomobject]@{ Kind = 'Package'; Name = 'Microsoft-Windows-WebView2Runtime-Package'; Identity = 'Microsoft-Windows-WebView2Runtime-Package~31bf~amd64~~10.0.26200.1'; State = 'Installed' }
                [pscustomobject]@{ Kind = 'Package'; Name = 'Microsoft-Windows-Client-CBS-Package'; Identity = 'Microsoft-Windows-Client-CBS-Package~31bf~amd64~~10.0.26200.1'; State = 'Installed' }
            )
        }
        $result = Resolve-WinUtilComponentPolicyPlan -Inventory $inventory -Catalog $script:catalog -Profile $script:leanProfile -ActionOverrides @{ defender = 'keep' } -OfflineSystemSelect ([pscustomobject]@{ Current = 1 }) -ExpertMode

        foreach ($policyId in 'widgets-webexperience', 'copilot', 'feedback-hub', 'consumer-appx', 'xbox-gaming', 'windows-ai', 'onedrive') {
            $result.ResolvedPlan.Decisions | Where-Object PolicyId -eq $policyId | ForEach-Object { $_.Action | Should -Be 'Remove' }
        }
        ($result.ResolvedPlan.Decisions | Where-Object PolicyId -eq 'webview2').Action | Should -Be 'Protected'
        ($result.ResolvedPlan.Decisions | Where-Object PolicyId -eq 'client-cbs').Action | Should -Be 'Protected'
    }
}
