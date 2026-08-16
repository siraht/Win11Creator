function Get-WinUtilEffectiveComponentPresetActionMap {
    <#
    .SYNOPSIS
        Resolves the complete portable action state for a Win11 Creator preset.
    #>
    param (
        [Parameter(Mandatory)][psobject]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Profiles,
        [Parameter(Mandatory)][string]$SelectedProfileId,
        [System.Collections.IDictionary]$ActionOverrides = @{}
    )

    $selectedProfile = @($Profiles | Where-Object { [string]$_.id -eq $SelectedProfileId }) | Select-Object -First 1
    if (-not $selectedProfile -and $SelectedProfileId -ne 'custom') {
        throw "Component profile '$SelectedProfileId' is not available."
    }

    $catalogIds = @($Catalog.components | ForEach-Object { [string]$_.id })
    foreach ($overrideId in @($ActionOverrides.Keys)) {
        if ([string]$overrideId -notin $catalogIds) {
            throw "Custom override references unknown component '$overrideId'."
        }
    }

    $actions = [ordered]@{}
    foreach ($component in @($Catalog.components | Sort-Object { [string]$_.id })) {
        $componentId = [string]$component.id
        $profileAction = if ($selectedProfile) { $selectedProfile.actions.PSObject.Properties[$componentId] } else { $null }
        $action = if ($profileAction) { [string]$profileAction.Value } else { [string]$component.defaultAction }
        if ($ActionOverrides.Contains($componentId)) { $action = [string]$ActionOverrides[$componentId] }
        $action = $action.ToLowerInvariant()
        if ($action -notin @('keep', 'remove', 'disable', 'manual', 'protected')) {
            throw "Custom override for '$componentId' has invalid action '$action'."
        }
        $actions[$componentId] = $action
    }
    return $actions
}

function Get-WinUtilComponentPresetDocument {
    param (
        [Parameter(Mandatory)][psobject]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Profiles,
        [Parameter(Mandatory)][string]$SelectedProfileId,
        [System.Collections.IDictionary]$ActionOverrides = @{}
    )

    [pscustomobject][ordered]@{
        schemaVersion = 1
        documentType = 'win11creator-component-preset'
        profileId = 'custom'
        actions = [pscustomobject](Get-WinUtilEffectiveComponentPresetActionMap `
            -Catalog $Catalog `
            -Profiles $Profiles `
            -SelectedProfileId $SelectedProfileId `
            -ActionOverrides $ActionOverrides)
    }
}

function ConvertTo-WinUtilComponentPresetJson {
    param ([Parameter(Mandatory)][psobject]$Preset)

    return ($Preset | ConvertTo-Json -Depth 4)
}

function ConvertFrom-WinUtilComponentPresetJson {
    <#
    .SYNOPSIS
        Parses a v1 preset and rejects every unknown field, component, and action.
    #>
    param (
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][psobject]$Catalog
    )

    try { $preset = $Json | ConvertFrom-Json -ErrorAction Stop } catch {
        throw "Unable to parse Win11 Creator preset JSON: $($_.Exception.Message)"
    }
    if ($null -eq $preset -or $preset -is [array]) { throw 'Win11 Creator preset must be one JSON object.' }

    $allowedProperties = @('schemaVersion', 'documentType', 'profileId', 'actions')
    $properties = @($preset.PSObject.Properties.Name)
    foreach ($property in $properties) {
        if ($property -notin $allowedProperties) { throw "Win11 Creator preset contains unknown property '$property'." }
    }
    foreach ($property in $allowedProperties) {
        if ($property -notin $properties) { throw "Win11 Creator preset is missing required property '$property'." }
    }
    if ([string]$preset.schemaVersion -ne '1') {
        throw "Unsupported Win11 Creator preset schemaVersion '$($preset.schemaVersion)'."
    }
    if ([string]$preset.documentType -ne 'win11creator-component-preset') {
        throw "Invalid Win11 Creator preset documentType '$($preset.documentType)'."
    }
    if ([string]$preset.profileId -ne 'custom') { throw "Win11 Creator preset profileId must be 'custom'." }
    if ($null -eq $preset.actions -or $preset.actions -is [array] -or $preset.actions -is [string]) {
        throw 'Win11 Creator preset actions must be one JSON object.'
    }

    $catalogIds = @($Catalog.components | ForEach-Object { [string]$_.id })
    $actionProperties = @($preset.actions.PSObject.Properties)
    foreach ($property in $actionProperties) {
        if ([string]$property.Name -notin $catalogIds) {
            throw "Win11 Creator preset references unknown component '$($property.Name)'."
        }
    }
    if ($actionProperties.Count -ne $catalogIds.Count) {
        throw 'Win11 Creator preset actions must contain every catalog component exactly once.'
    }
    $actions = [ordered]@{}
    foreach ($property in @($actionProperties | Sort-Object Name)) {
        $componentId = [string]$property.Name
        $action = ([string]$property.Value).ToLowerInvariant()
        if ($action -notin @('keep', 'remove', 'disable', 'manual', 'protected')) {
            throw "Win11 Creator preset action for '$componentId' is invalid: '$action'."
        }
        $actions[$componentId] = $action
    }
    foreach ($componentId in $catalogIds) {
        if (-not $actions.Contains($componentId)) {
            throw "Win11 Creator preset is missing catalog component '$componentId'."
        }
    }
    foreach ($exclusiveGroup in @($Catalog.exclusiveGroups)) {
        $activeMembers = @($exclusiveGroup.members | Where-Object { $actions[[string]$_] -in @('remove', 'disable') })
        if ($activeMembers.Count -gt 1) {
            throw "Win11 Creator preset activates more than one choice in exclusive group '$($exclusiveGroup.id)'."
        }
    }
    return $actions
}

function Export-WinUtilComponentPreset {
    param ([Parameter(Mandatory)][string]$Path)

    $preset = Get-WinUtilComponentPresetDocument `
        -Catalog $sync.configs.componentPolicy.catalog `
        -Profiles @($sync.configs.componentPolicy.profiles.PSObject.Properties.Value) `
        -SelectedProfileId ([string]$sync['Win11ISOSelectedProfileId']) `
        -ActionOverrides $sync['Win11ISOComponentActionOverrides']
    ConvertTo-WinUtilComponentPresetJson -Preset $preset | Set-Content -LiteralPath $Path -Encoding UTF8
    return $preset
}

function Import-WinUtilComponentPreset {
    param ([Parameter(Mandatory)][string]$Path)

    $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $actions = ConvertFrom-WinUtilComponentPresetJson -Json $json -Catalog $sync.configs.componentPolicy.catalog
    $sync['Win11ISOManualOverrides'] = @()
    Update-WinUtilComponentPolicyUI -SelectedProfileId 'custom' -ActionOverrides $actions

    $wasUpdatingProfileSelection = $sync['Win11ISOUpdatingProfileSelection'] -eq $true
    $sync['Win11ISOUpdatingProfileSelection'] = $true
    try {
        Invoke-WPFUIThread { $sync.WPFWin11ISOProfileComboBox.SelectedValue = 'custom' }
    } finally {
        $sync['Win11ISOUpdatingProfileSelection'] = $wasUpdatingProfileSelection
    }
    return $actions
}

function Invoke-WinUtilComponentPresetImportDialog {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    $dialog.Title = 'Import Win11 Creator Preset'
    $dialog.Filter = 'Win11 Creator preset (*.json)|*.json'
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        Import-WinUtilComponentPreset -Path $dialog.FileName | Out-Null
        [System.Windows.MessageBox]::Show('The preset was imported into Custom.', 'Preset Imported', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Preset Import Failed', 'OK', 'Error') | Out-Null
    }
}

function Invoke-WinUtilComponentPresetExportDialog {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [System.Windows.Forms.SaveFileDialog]::new()
    $dialog.Title = 'Export Win11 Creator Preset'
    $dialog.Filter = 'Win11 Creator preset (*.json)|*.json'
    $dialog.FileName = 'Win11Creator-Custom.json'
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        Export-WinUtilComponentPreset -Path $dialog.FileName | Out-Null
        [System.Windows.MessageBox]::Show('The effective component state was exported as a portable Custom preset.', 'Preset Exported', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Preset Export Failed', 'OK', 'Error') | Out-Null
    }
}
