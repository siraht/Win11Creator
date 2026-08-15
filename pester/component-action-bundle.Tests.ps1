#===========================================================================
# Tests - Typed component action bundle
#===========================================================================

Describe 'Typed component action bundle' {
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
                [pscustomobject]@{ Kind = 'Capability'; Name = 'OpenSSH.Client~~~~0.0.1.0'; Identity = 'OpenSSH.Client~~~~0.0.1.0'; State = 'Installed' }
                [pscustomobject]@{ Kind = 'Capability'; Name = 'OpenSSH.Server~~~~0.0.1.0'; Identity = 'OpenSSH.Server~~~~0.0.1.0'; State = 'Installed' }
                [pscustomobject]@{ Kind = 'Package'; Name = 'Contoso.Unknown'; Identity = 'Contoso.Unknown~1.0'; State = 'Installed' }
            )
        }
    }

    It 'ActionBundle_LeanCoverageProducesExplicitRegistryServiceAndTaskIntents' {
        $result = Resolve-WinUtilComponentPolicyPlan -Inventory $script:inventory -Catalog $script:catalog -Profile $script:leanProfile -OfflineSystemSelect ([pscustomobject]@{ Current = 1 }) -ExpertMode
        $bundle = $result.ActionBundle

        $bundle.SchemaVersion | Should -Be '1.0'
        $bundle.Safety | Should -Be $result.Safety
        $bundle.IsAllowed | Should -BeTrue
        $bundle.IsReady | Should -BeFalse
        $bundle.RequiresSetupStaging | Should -BeTrue
        $bundle.RegistryActions.Name | Should -Contain 'DisableSearchBoxSuggestions'
        $bundle.RegistryActions.Name | Should -Contain 'EnableLUA'
        $bundle.RegistryActions | Where-Object {
            $_.Hive -eq 'SYSTEM' -and $_.Key -eq 'ControlSet001\Services\DiagTrack' -and
            $_.Name -eq 'Start' -and $_.Type -eq 'REG_DWORD' -and $_.Value -eq 4
        } | Should -HaveCount 1
        $bundle.SetupActions | Should -HaveCount 3
        $bundle.SetupActions.Mechanism | Should -Not -Contain 'taskcache'
        ($bundle.SetupActions | ConvertTo-Json -Depth 5) | Should -Not -Match 'delete|TaskCache'
        foreach ($setupAction in $bundle.SetupActions) {
            $setupAction.Executable | Should -Be 'schtasks.exe'
            $setupAction.Arguments[0] | Should -Be '/Change'
            $setupAction.Arguments[-1] | Should -Be '/Disable'
        }
    }

    It 'ActionBundle_ProtectsOpenSshAndKeepsUnknownInventory' {
        $result = Resolve-WinUtilComponentPolicyPlan -Inventory $script:inventory -Catalog $script:catalog -Profile $script:leanProfile -OfflineSystemSelect ([pscustomobject]@{ Current = 1 }) -ExpertMode

        ($result.ResolvedPlan.Decisions | Where-Object Identity -like 'OpenSSH.*').Action | Should -Be @('Protected', 'Protected')
        $unknown = $result.ResolvedPlan.Decisions | Where-Object Identity -eq 'Contoso.Unknown~1.0'
        $unknown.Action | Should -Be 'Manual'
        $unknown.Reason | Should -Match 'kept unless explicitly overridden'
    }

    It 'ActionBundle_NoOperationsForKeepProtectedOrManual' {
        $result = Resolve-WinUtilComponentPolicyPlan -Inventory $script:inventory -Catalog $script:catalog -Profile $script:defaultProfile

        $result.ActionBundle.RegistryActions | Should -HaveCount 0
        $result.ActionBundle.SetupActions | Should -HaveCount 0
        $result.ActionBundle.IsReady | Should -BeTrue
    }

    It 'ActionBundle_AmbiguousControlSet_PlantedNegative' {
        $result = Resolve-WinUtilComponentPolicyPlan -Inventory $script:inventory -Catalog $script:catalog -Profile $script:leanProfile -OfflineSystemSelect ([pscustomobject]@{ Current = @(1, 2) }) -ExpertMode

        $result.ActionBundle.IsAllowed | Should -BeFalse
        $result.ActionBundle.Safety.Conflicts | Where-Object {
            $_.Severity -eq 'unsupported-operation' -and $_.Reason -match 'one valid offline SYSTEM'
        } | Should -Not -BeNullOrEmpty
        $result.ActionBundle.RegistryActions | Where-Object Hive -eq 'SYSTEM' | Should -HaveCount 0
    }

    It 'ActionBundle_MissingControlSet_PlantedNegative' {
        $result = Resolve-WinUtilComponentPolicyPlan -Inventory $script:inventory -Catalog $script:catalog -Profile $script:leanProfile -ExpertMode

        $result.ActionBundle.IsAllowed | Should -BeFalse
        $result.ActionBundle.Safety.Conflicts.Reason | Should -Contain "Service 'WSearch' requires one valid offline SYSTEM Select\Current control-set value."
    }

    It 'ActionBundle_DeduplicatesExactOperations' {
        $duplicateCatalog = $script:catalog | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $bingTarget = ($duplicateCatalog.components | Where-Object id -eq 'bing-search').targets[0]
        $bingTarget.operations = @($bingTarget.operations[0], $bingTarget.operations[0])
        $result = Resolve-WinUtilComponentPolicyPlan -Inventory $script:inventory -Catalog $duplicateCatalog -Profile $script:leanProfile -OfflineSystemSelect ([pscustomobject]@{ Current = 1 }) -ExpertMode

        $result.ActionBundle.RegistryActions | Where-Object Name -eq 'DisableSearchBoxSuggestions' | Should -HaveCount 1
    }

    It 'ActionBundle_MalformedRegistryMetadata_PlantedNegative' {
        $invalid = $script:catalog | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $operation = ($invalid.components | Where-Object id -eq 'bing-search').targets[0].operations[0]
        $operation.key = ''

        { Test-WinUtilComponentPolicy -Policy $invalid -ThrowOnError } | Should -Throw '*registry operation is missing key*'
    }

    It 'ActionBundle_UnsupportedOperation_PlantedNegative' {
        $invalid = $script:catalog | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        ($invalid.components | Where-Object id -eq 'bing-search').targets[0].operations[0].operation = 'delete-registry-tree'

        { Test-WinUtilComponentPolicy -Policy $invalid -ThrowOnError } | Should -Throw '*unsupported operation*'
    }

    It 'ActionBundle_UnsupportedTaskWildcard_PlantedNegative' {
        $invalid = $script:catalog | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $taskTarget = ($invalid.components | Where-Object id -eq 'telemetry-consumer-content').targets |
            Where-Object kind -eq 'scheduled-task'
        $taskTarget.operations[0].taskPath = '\Microsoft\Windows\Customer Experience Improvement Program\*'

        { Test-WinUtilComponentPolicy -Policy $invalid -ThrowOnError } | Should -Throw '*requires an exact Microsoft task path*'
    }

    It 'ActionBundle_UnknownTargetKind_PlantedNegative' {
        $invalid = $script:catalog | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        ($invalid.components | Where-Object id -eq 'bing-search').targets[0].kind = 'taskcache'

        { Test-WinUtilComponentPolicy -Policy $invalid -ThrowOnError } | Should -Throw "*invalid target kind 'taskcache'*"
    }
}
