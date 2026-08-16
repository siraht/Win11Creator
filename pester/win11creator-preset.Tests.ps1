Describe 'Win11 Creator component preset import and export' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $repoRoot 'functions/private/Import-WinUtilComponentPreset.ps1')
        $script:catalog = Get-Content (Join-Path $repoRoot 'policy/component-catalog.json') -Raw | ConvertFrom-Json
        $script:profiles = @(
            Get-Content (Join-Path $repoRoot 'policy/profiles/default-winutil.json') -Raw | ConvertFrom-Json
            Get-Content (Join-Path $repoRoot 'policy/profiles/lean-daw.json') -Raw | ConvertFrom-Json
        )
    }

    It 'round-trips a deterministic complete effective Custom action state' {
        $first = Get-WinUtilComponentPresetDocument -Catalog $script:catalog -Profiles $script:profiles `
            -SelectedProfileId 'lean-daw' -ActionOverrides @{ uac = 'keep'; 'uac-prompt-suppression' = 'disable' }
        $json = ConvertTo-WinUtilComponentPresetJson -Preset $first
        $actions = ConvertFrom-WinUtilComponentPresetJson -Json $json -Catalog $script:catalog
        $second = Get-WinUtilComponentPresetDocument -Catalog $script:catalog -Profiles $script:profiles `
            -SelectedProfileId 'custom' -ActionOverrides $actions

        (ConvertTo-WinUtilComponentPresetJson -Preset $second) | Should -BeExactly $json
        @($actions.Keys).Count | Should -Be @($script:catalog.components).Count
        $actions.'uac-prompt-suppression' | Should -Be 'disable'
        $actions.uac | Should -Be 'keep'
        @($first.actions.PSObject.Properties.Name) | Should -Be (@($first.actions.PSObject.Properties.Name) | Sort-Object)
    }

    It 'does not serialize inventory-scoped package identities or manual overrides' {
        $preset = Get-WinUtilComponentPresetDocument -Catalog $script:catalog -Profiles $script:profiles `
            -SelectedProfileId 'default-winutil'
        $json = ConvertTo-WinUtilComponentPresetJson -Preset $preset

        $json | Should -Not -Match 'ManualOverrides|Identity|Contoso.Unknown'
        @($preset.PSObject.Properties.Name) | Should -Be @('schemaVersion', 'documentType', 'profileId', 'actions')
    }

    It 'plants malformed, unsupported-version, and unknown-field negatives' {
        { ConvertFrom-WinUtilComponentPresetJson -Json '{' -Catalog $script:catalog } |
            Should -Throw '*Unable to parse*'

        $valid = Get-WinUtilComponentPresetDocument -Catalog $script:catalog -Profiles $script:profiles -SelectedProfileId 'default-winutil'
        $valid.schemaVersion = 2
        { ConvertFrom-WinUtilComponentPresetJson -Json ($valid | ConvertTo-Json -Depth 4) -Catalog $script:catalog } |
            Should -Throw "*Unsupported*schemaVersion '2'*"

        $valid.schemaVersion = 1
        $valid | Add-Member -NotePropertyName expertMode -NotePropertyValue $true
        { ConvertFrom-WinUtilComponentPresetJson -Json ($valid | ConvertTo-Json -Depth 4) -Catalog $script:catalog } |
            Should -Throw "*unknown property 'expertMode'*"

        $stringVersion = Get-WinUtilComponentPresetDocument -Catalog $script:catalog -Profiles $script:profiles -SelectedProfileId 'default-winutil'
        $stringVersion.schemaVersion = '1'
        { ConvertFrom-WinUtilComponentPresetJson -Json ($stringVersion | ConvertTo-Json -Depth 4) -Catalog $script:catalog } |
            Should -Throw '*Unsupported*schemaVersion*'
    }

    It 'plants unknown component, missing component, and invalid action negatives' {
        $valid = Get-WinUtilComponentPresetDocument -Catalog $script:catalog -Profiles $script:profiles -SelectedProfileId 'default-winutil'
        $unknown = $valid | ConvertTo-Json -Depth 4 | ConvertFrom-Json
        $unknown.actions | Add-Member -NotePropertyName 'unknown-component' -NotePropertyValue 'remove'
        { ConvertFrom-WinUtilComponentPresetJson -Json ($unknown | ConvertTo-Json -Depth 4) -Catalog $script:catalog } |
            Should -Throw "*unknown component 'unknown-component'*"

        $missing = $valid | ConvertTo-Json -Depth 4 | ConvertFrom-Json
        $missing.actions.PSObject.Properties.Remove([string]$script:catalog.components[0].id)
        { ConvertFrom-WinUtilComponentPresetJson -Json ($missing | ConvertTo-Json -Depth 4) -Catalog $script:catalog } |
            Should -Throw '*must contain every catalog component*'

        $invalid = $valid | ConvertTo-Json -Depth 4 | ConvertFrom-Json
        $invalid.actions.([string]$script:catalog.components[0].id) = 'erase'
        { ConvertFrom-WinUtilComponentPresetJson -Json ($invalid | ConvertTo-Json -Depth 4) -Catalog $script:catalog } |
            Should -Throw '*is invalid*erase*'

        $wrongCase = $valid | ConvertTo-Json -Depth 4 | ConvertFrom-Json
        $wrongCase.actions.([string]$script:catalog.components[0].id) = 'Remove'
        { ConvertFrom-WinUtilComponentPresetJson -Json ($wrongCase | ConvertTo-Json -Depth 4) -Catalog $script:catalog } |
            Should -Throw '*is invalid*Remove*'
    }

    It 'rejects mutually exclusive actions before they can reach Custom state' {
        $invalid = Get-WinUtilComponentPresetDocument -Catalog $script:catalog -Profiles $script:profiles -SelectedProfileId 'default-winutil'
        $invalid.actions.uac = 'disable'
        $invalid.actions.'uac-prompt-suppression' = 'disable'

        { ConvertFrom-WinUtilComponentPresetJson -Json ($invalid | ConvertTo-Json -Depth 4) -Catalog $script:catalog } |
            Should -Throw "*exclusive group 'uac-mode'*"
    }

    It 'imports by replacing an existing Custom state and clearing stale inventory overrides' {
        $preset = Get-WinUtilComponentPresetDocument -Catalog $script:catalog -Profiles $script:profiles `
            -SelectedProfileId 'lean-daw' -ActionOverrides @{ uac = 'keep' }
        $path = Join-Path $TestDrive 'preset.json'
        ConvertTo-WinUtilComponentPresetJson -Preset $preset | Set-Content -LiteralPath $path
        $global:sync = [hashtable]::Synchronized(@{
            configs = @{ componentPolicy = [pscustomobject]@{ catalog = $script:catalog; profiles = [pscustomobject]@{} } }
            Win11ISOSelectedProfileId = 'custom'
            Win11ISOComponentActionOverrides = @{ uac = 'disable' }
            Win11ISOCustomActionOverrides = @{ uac = 'disable' }
            Win11ISOManualOverrides = @([pscustomobject]@{ Kind = 'Package'; Identity = 'inventory-specific'; Action = 'Remove' })
            WPFWin11ISOProfileComboBox = [pscustomobject]@{ SelectedValue = 'custom' }
        })
        $script:appliedProfile = $null
        $script:appliedActions = $null
        function Update-WinUtilComponentPolicyUI {
            param($SelectedProfileId, $ActionOverrides)
            $script:appliedProfile = $SelectedProfileId
            $script:appliedActions = $ActionOverrides
            $sync.Win11ISOSelectedProfileId = $SelectedProfileId
            $sync.Win11ISOComponentActionOverrides = $ActionOverrides
        }
        function Invoke-WPFUIThread { param([scriptblock]$ScriptBlock) & $ScriptBlock }

        Import-WinUtilComponentPreset -Path $path | Out-Null

        $script:appliedProfile | Should -Be 'custom'
        $script:appliedActions.uac | Should -Be 'keep'
        $sync.Win11ISOManualOverrides | Should -BeNullOrEmpty
    }

    It 'does not mutate live state when validation fails' {
        $path = Join-Path $TestDrive 'invalid.json'
        '{"schemaVersion":2}' | Set-Content -LiteralPath $path
        $global:sync = [hashtable]::Synchronized(@{
            configs = @{ componentPolicy = [pscustomobject]@{ catalog = $script:catalog } }
            Win11ISOManualOverrides = @([pscustomobject]@{ Identity = 'still-present' })
        })

        { Import-WinUtilComponentPreset -Path $path } | Should -Throw
        @($sync.Win11ISOManualOverrides).Count | Should -Be 1
    }

}
