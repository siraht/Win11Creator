#===========================================================================
# Tests - Deep customization component policy
#===========================================================================

Describe "Deep customization component policy" {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
        $script:policyRoot = Join-Path $script:repoRoot "policy"
        . (Join-Path $script:repoRoot "functions/private/Import-WinUtilComponentPolicy.ps1")

        $script:catalog = Import-WinUtilComponentPolicy -Path (Join-Path $script:policyRoot "component-catalog.json")
        $script:defaultProfile = Import-WinUtilComponentPolicy -Path (Join-Path $script:policyRoot "profiles/default-winutil.json") -Catalog $script:catalog
        $script:leanDawProfile = Import-WinUtilComponentPolicy -Path (Join-Path $script:policyRoot "profiles/lean-daw.json") -Catalog $script:catalog
    }

    It "deserializes the versioned schema, catalog, and both profiles" {
        $schema = Get-Content -LiteralPath (Join-Path $script:policyRoot "component-policy.schema.json") -Raw | ConvertFrom-Json

        $schema.'$defs'.action.enum | Should -Be @("keep", "remove", "disable", "manual", "protected")
        $schema.'$defs'.risk.enum | Should -Be @("safe", "moderate", "high", "expert")
        $schema.'$defs'.matchType.enum | Should -Be @("exact", "wildcard", "version-insensitive")
        $schema.'$defs'.conflictSeverity.enum | Should -Be @("warning", "likely-breakage", "forbidden-unless-expert")
        $script:catalog.schemaVersion | Should -Be 1
        @($script:defaultProfile, $script:leanDawProfile).Count | Should -Be 2
    }

    It "accepts every supported action and risk value" {
        $actions = @("keep", "remove", "disable", "manual", "protected")
        $risks = @("safe", "moderate", "high", "expert")

        foreach ($action in $actions) {
            foreach ($risk in $risks) {
                $candidate = [pscustomobject]@{
                    schemaVersion = 1
                    documentType = "component-catalog"
                    components = @([pscustomobject]@{
                        id = "test-component"
                        name = "Test component"
                        category = "test"
                        defaultAction = $action
                        risk = $risk
                        targets = @([pscustomobject]@{ kind = "package"; match = "Test-*"; matchType = "wildcard" })
                        protects = @()
                        conflicts = @()
                        requires = @()
                        description = "Test description."
                        reason = "Test reason."
                        consequences = "Test consequences."
                        reversible = $true
                        exposed = $true
                    })
                }

                Test-WinUtilComponentPolicy -Policy $candidate | Should -BeTrue
            }
        }
    }

    It "represents every servicing target kind separately" {
        $targetKinds = @($script:catalog.components.targets | ForEach-Object { $_.kind } | Sort-Object -Unique)
        $targetKinds | Should -Be @("appx", "capability", "feature", "package", "registry", "scheduled-task", "service")
    }

    It "covers every declared Lean DAW removal or disable concept" {
        $expected = @(
            "windows-search", "bing-search", "widgets-webexperience", "copilot", "feedback-hub", "defender",
            "smartscreen", "uac", "windows-ai", "onedrive", "xbox-gaming", "consumer-appx", "telemetry-consumer-content"
        )

        foreach ($componentId in $expected) {
            $script:catalog.components.id | Should -Contain $componentId
            $script:leanDawProfile.actions.$componentId | Should -BeIn @("remove", "disable")
        }
    }

    It "protects every declared Lean DAW keep target" {
        $expected = @(
            "nfs", "modern-shell", "client-cbs", "microsoft-store-infrastructure", "desktop-app-installer", "windows-terminal",
            "webview2", "windows-app-runtime", "ui-xaml", "vclibs", "wsl", "virtual-machine-platform", "hyper-v-payloads",
            "windows-error-reporting", "app-compatibility", "sysmain-prefetch", "feature-delivery", "featureconfig-onesettings",
            "cpu-mitigations", "windows-servicing-tasks", "component-store", "rollback-state", "windows-update",
            "reversible-component-cleanup"
        )

        foreach ($componentId in $expected) {
            $script:catalog.components.id | Should -Contain $componentId
            $script:leanDawProfile.actions.$componentId | Should -Be "protected"
        }
    }

    It "gives every catalog component an action in both profiles" {
        foreach ($componentId in $script:catalog.components.id) {
            $script:defaultProfile.actions.PSObject.Properties.Name | Should -Contain $componentId
            $script:leanDawProfile.actions.PSObject.Properties.Name | Should -Contain $componentId
        }
    }

    It "defaults an unknown component to keep with manual review" {
        $result = Get-WinUtilComponentPolicyAction -ComponentId "future-windows-package" -Catalog $script:catalog -Profile $script:leanDawProfile

        $result.Known | Should -BeFalse
        $result.Action | Should -Be "keep"
        $result.Recommendation | Should -Be "manual"
    }

    It "rejects an exposed entry with invalid explanatory metadata" {
        $invalid = [pscustomobject]@{
            schemaVersion = 1
            documentType = "component-catalog"
            components = @([pscustomobject]@{
                id = "invalid-entry"
                name = "Invalid entry"
                category = "test"
                defaultAction = "remove"
                risk = "moderate"
                targets = @([pscustomobject]@{ kind = "appx"; match = "Invalid.Package"; matchType = "exact" })
                protects = @()
                conflicts = @()
                requires = @()
                description = ""
                reason = ""
                consequences = ""
                reversible = "sometimes"
                exposed = $true
            })
        }

        { Test-WinUtilComponentPolicy -Policy $invalid -ThrowOnError } | Should -Throw "*Exposed component 'invalid-entry'*"
    }

    It "PolicyContract_MalformedMatchSemantics_PlantedNegative" {
        $invalid = $script:catalog | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $invalid.components[0].targets[0].matchType = "wildcard"

        { Test-WinUtilComponentPolicy -Policy $invalid -ThrowOnError } |
            Should -Throw "*wildcard target*must contain * or ?*"
    }

    It "PolicyContract_UnknownDependencyReference_PlantedNegative" {
        $invalid = $script:catalog | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $invalid.components[0].requires = @("missing-runtime")

        { Test-WinUtilComponentPolicy -Policy $invalid -ThrowOnError } |
            Should -Throw "*references unknown dependency 'missing-runtime'*"
    }

    It "PolicyContract_UnknownConflictReference_PlantedNegative" {
        $invalid = $script:catalog | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $invalid.components[0].conflicts[0].with = "missing-shell"

        { Test-WinUtilComponentPolicy -Policy $invalid -ThrowOnError } |
            Should -Throw "*references unknown conflict component 'missing-shell'*"
    }

    It "PolicyContract_NonBooleanMultipleMatchOptIn_PlantedNegative" {
        $invalid = $script:catalog | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $invalid.components[0].targets[0] | Add-Member -NotePropertyName allowMultiple -NotePropertyValue 'yes'

        { Test-WinUtilComponentPolicy -Policy $invalid -ThrowOnError } |
            Should -Throw '*non-boolean allowMultiple*'
    }
}
