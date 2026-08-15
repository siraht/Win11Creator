function Get-WinUtilComponentPolicyGroupName {
    param ([Parameter(Mandatory)][string]$Category)

    switch ($Category) {
        'app' { return 'Apps' }
        'windows-component' { return 'Windows Components' }
        'protected-runtime' { return 'Windows Components' }
        'servicing-debug' { return 'Windows Components' }
        'privacy-runtime' { return 'Privacy / Runtime' }
        'security' { return 'Privacy / Runtime' }
        'developer-virtualization' { return 'Developer / Virtualization' }
        default { return 'Features & Capabilities' }
    }
}

function New-WinUtilComponentPolicyPresentation {
    <#
    .SYNOPSIS
        Creates a headless presentation model for component profiles and groups.
    #>
    param (
        [Parameter(Mandatory)][psobject]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Profiles,
        [string]$SelectedProfileId = 'default-winutil'
    )

    $supportedProfileIds = @('default-winutil', 'lean-daw')
    $profileOptions = @(
        $Profiles |
            Where-Object { $_.id -in $supportedProfileIds } |
            Sort-Object { [array]::IndexOf($supportedProfileIds, [string]$_.id) } |
            ForEach-Object { [pscustomobject]@{ Id = [string]$_.id; Name = [string]$_.name } }
        [pscustomobject]@{ Id = 'custom'; Name = 'Custom' }
    )

    $selectedProfile = @($Profiles | Where-Object { $_.id -eq $SelectedProfileId }) | Select-Object -First 1
    if (-not $selectedProfile -and $SelectedProfileId -ne 'custom') {
        throw "Component profile '$SelectedProfileId' is not available."
    }

    $items = foreach ($component in @($Catalog.components)) {
        $profileAction = if ($selectedProfile) { $selectedProfile.actions.PSObject.Properties[[string]$component.id] } else { $null }
        $action = if ($profileAction) { [string]$profileAction.Value } else { [string]$component.defaultAction }
        [pscustomobject]@{
            Id          = [string]$component.id
            Name        = [string]$component.name
            Group       = Get-WinUtilComponentPolicyGroupName -Category ([string]$component.category)
            Action      = $action
            Risk        = [string]$component.risk
            Rationale   = [string]$component.reason
            Consequences = [string]$component.consequences
        }
    }

    $riskRank = @{ safe = 0; moderate = 1; high = 2; expert = 3 }
    $changedItems = @($items | Where-Object { $_.Action -in @('remove', 'disable') })
    $estimatedRisk = 'safe'
    if ($changedItems.Count -gt 0) {
        $estimatedRisk = [string]($changedItems | Sort-Object { $riskRank[[string]$_.Risk] } -Descending | Select-Object -First 1).Risk
    }

    $groupNames = @('Apps', 'Windows Components', 'Features & Capabilities', 'Privacy / Runtime', 'Developer / Virtualization')
    $groups = foreach ($groupName in $groupNames) {
        [pscustomobject]@{
            Name = $groupName
            Items = @($items | Where-Object Group -eq $groupName | Sort-Object Name)
        }
    }

    [pscustomobject]@{
        Profiles = @($profileOptions)
        SelectedProfileId = $SelectedProfileId
        Summary = [pscustomobject]@{
            RemoveCount = @($items | Where-Object Action -eq 'remove').Count
            DisableCount = @($items | Where-Object Action -eq 'disable').Count
            ProtectedCount = @($items | Where-Object Action -eq 'protected').Count
            Risk = $estimatedRisk
        }
        Groups = @($groups)
    }
}

function New-WinUtilAdvancedPackageSelectorModel {
    <#
    .SYNOPSIS
        Creates conservative selector rows from an ImageInventory and resolved plan.
    #>
    param (
        [Parameter(Mandatory)][psobject]$ImageInventory,
        [psobject]$ResolvedPlan,
        [AllowEmptyCollection()][object[]]$ManualOverride = @(),
        [switch]$ExpertMode
    )

    if ([string]$ImageInventory.SchemaVersion -ne '1.0' -or $null -eq $ImageInventory.Items) {
        throw 'ImageInventory must use schema version 1.0 and contain Items.'
    }

    $decisionByKey = @{}
    foreach ($decision in @($ResolvedPlan.Decisions)) {
        $decisionByKey['{0}|{1}' -f [string]$decision.Kind, [string]$decision.Identity] = $decision
    }

    foreach ($item in @($ImageInventory.Items | Sort-Object Kind, Identity)) {
        $key = '{0}|{1}' -f [string]$item.Kind, [string]$item.Identity
        $decision = $decisionByKey[$key]
        $isUnknown = $null -eq $decision -or (
            [string]$decision.Action -eq 'Manual' -and [string]::IsNullOrWhiteSpace([string]$decision.PolicyId)
        )
        $recommendation = if ($isUnknown) { 'Manual' } else { [string]$decision.Action }
        $rationale = if ($isUnknown) {
            'Unknown component; kept unless explicitly reviewed.'
        } else {
            [string]$decision.Reason
        }
        $isProtected = $recommendation -eq 'Protected'
        $initialSelected = -not $isUnknown -and -not $isProtected -and $recommendation -in @('Remove', 'Disable')
        $rowOverride = @($ManualOverride | Where-Object {
            [string]$_.Kind -eq [string]$item.Kind -and [string]$_.Identity -eq [string]$item.Identity
        }) | Select-Object -First 1
        $isSelected = if ($rowOverride) { [string]$rowOverride.Action -in @('Remove', 'Disable') } else { $initialSelected }

        [pscustomobject]@{
            Kind           = [string]$item.Kind
            Name           = [string]$item.Name
            Identity       = [string]$item.Identity
            Recommendation = $recommendation
            Rationale      = $rationale
            Risk           = if ($decision) { [string]$decision.Risk } else { 'Expert' }
            IsUnknown      = $isUnknown
            IsProtected    = $isProtected
            CanSelect      = -not $isUnknown -and (-not $isProtected -or $ExpertMode.IsPresent)
            IsSelected     = $isSelected
            InitialSelected = $initialSelected
        }
    }
}

function Set-WinUtilAdvancedPackageOverride {
    <#
    .SYNOPSIS
        Converts a selector change into an explicit resolver manual override.
    #>
    param (
        [Parameter(Mandatory)][psobject]$Row,
        [Parameter(Mandatory)][bool]$Selected,
        [switch]$ExpertMode
    )

    $selection = Set-WinUtilAdvancedPackageSelection -Row $Row -Selected $Selected -ExpertMode:$ExpertMode
    if (-not $selection.IsAllowed) {
        return [pscustomobject]@{ IsAllowed = $false; Warning = $selection.Warning; Override = $null }
    }

    $override = $null
    if ($Selected -ne [bool]$Row.InitialSelected) {
        $action = if ($Selected) {
            if ($Row.IsProtected -or $Row.Recommendation -notin @('Remove', 'Disable')) { 'Remove' } else { [string]$Row.Recommendation }
        } else { 'Keep' }
        $override = [pscustomobject]@{
            Kind = [string]$Row.Kind
            Identity = [string]$Row.Identity
            Action = $action
            Reason = 'Advanced Package Selector user override.'
        }
    }

    [pscustomobject]@{ IsAllowed = $true; Warning = $selection.Warning; Override = $override }
}

function Set-WinUtilAdvancedPackageSelection {
    <#
    .SYNOPSIS
        Applies a selector choice while enforcing unknown and protected safeguards.
    #>
    param (
        [Parameter(Mandatory)][psobject]$Row,
        [Parameter(Mandatory)][bool]$Selected,
        [switch]$ExpertMode
    )

    if ($Selected -and $Row.IsUnknown) {
        $Row.IsSelected = $false
        return [pscustomobject]@{ IsAllowed = $false; Warning = 'Unknown components remain kept and require manual review.' }
    }
    if ($Selected -and $Row.IsProtected -and -not $ExpertMode.IsPresent) {
        $Row.IsSelected = $false
        return [pscustomobject]@{ IsAllowed = $false; Warning = 'Protected components require Expert mode and dependency review.' }
    }

    $Row.IsSelected = $Selected
    $warning = if ($Selected -and $Row.IsProtected) {
        'Expert override selected: removing protected components can break dependencies and Windows servicing.'
    } else { '' }
    return [pscustomobject]@{ IsAllowed = $true; Warning = $warning }
}

function New-WinUtilComponentPolicyHandoff {
    <#
    .SYNOPSIS
        Reports whether the UI has all artifacts required by the servicing handoff.
    #>
    param (
        [Parameter(Mandatory)][string]$SelectedProfileId,
        [psobject]$ImageInventory,
        [psobject]$ResolvedPlan,
        [psobject]$Safety,
        [psobject]$ActionBundle,
        [Parameter()][AllowEmptyCollection()][object[]]$RegistryActions
    )

    $hasInventory = $null -ne $ImageInventory
    $hasResolvedPlan = $null -ne $ResolvedPlan
    $hasActionBundle = $null -ne $ActionBundle
    $hasRegistryActions = $null -ne $RegistryActions
    $safetyAllowed = $null -ne $Safety -and $Safety.IsAllowed -eq $true
    $actionBundleReady = $hasActionBundle -and $ActionBundle.IsReady -eq $true
    $isReady = $hasInventory -and $hasResolvedPlan -and $hasRegistryActions -and $safetyAllowed -and $actionBundleReady
    $status = if (-not $hasInventory) {
        'Preview only: inventory, resolved plan, and registry actions have not been staged.'
    } elseif (-not $hasResolvedPlan) {
        'Inventory loaded; the selected profile has not been resolved for servicing.'
    } elseif (-not $hasRegistryActions) {
        'Resolved component plan staged; registry actions have not been staged.'
    } elseif (-not $safetyAllowed) {
        'Blocked: component safety review has unresolved conflicts.'
    } elseif (-not $hasActionBundle) {
        'Blocked: the typed component action bundle has not been staged.'
    } elseif (-not $actionBundleReady) {
        'Blocked: one or more required component setup actions have not been staged.'
    } else {
        'Ready: resolved component plan and typed actions are staged for servicing.'
    }

    [pscustomobject]@{
        SelectedProfileId = $SelectedProfileId
        HasInventory = $hasInventory
        HasResolvedPlan = $hasResolvedPlan
        HasActionBundle = $hasActionBundle
        HasRegistryActions = $hasRegistryActions
        SafetyAllowed = $safetyAllowed
        ActionBundleReady = $actionBundleReady
        IsReady = $isReady
        Status = $status
    }
}

function Update-WinUtilComponentPolicyUI {
    param ([Parameter(Mandatory)][string]$SelectedProfileId)

    $model = New-WinUtilComponentPolicyPresentation `
        -Catalog $sync.configs.componentPolicy.catalog `
        -Profiles @($sync.configs.componentPolicy.profiles.PSObject.Properties.Value) `
        -SelectedProfileId $SelectedProfileId
    $sync.ComponentPolicyPresentation = $model
    $sync['Win11ISOSelectedProfileId'] = $SelectedProfileId
    $sync['Win11ISOResolvedPlan'] = $null
    $sync['Win11ISORegistryActions'] = $null
    $sync['Win11ISOActionBundle'] = $null
    $sync['Win11ISOAdvancedPackageRows'] = @()
    $handoff = New-WinUtilComponentPolicyHandoff `
        -SelectedProfileId $SelectedProfileId `
        -ImageInventory $sync['Win11ISOImageInventory']
    $sync['Win11ISOPolicyHandoff'] = $handoff

    Invoke-WPFUIThread {
        $sync.WPFWin11ISOSummaryRemove.Text = [string]$model.Summary.RemoveCount
        $sync.WPFWin11ISOSummaryDisable.Text = [string]$model.Summary.DisableCount
        $sync.WPFWin11ISOSummaryProtected.Text = [string]$model.Summary.ProtectedCount
        $sync.WPFWin11ISOSummaryRisk.Text = ([string]$model.Summary.Risk).ToUpperInvariant()
        $sync.WPFWin11ISOPolicyHandoffStatus.Text = $handoff.Status
        $sync.WPFWin11ISOPolicyHandoffStatus.Foreground = 'OrangeRed'
        $sync.WPFWin11ISOModifyButton.IsEnabled = $false
        $sync.WPFWin11ISOAdvancedPackageItems.ItemsSource = @()

        $groupControlNames = @{
            'Apps' = 'WPFWin11ISOAppsItems'
            'Windows Components' = 'WPFWin11ISOWindowsComponentsItems'
            'Features & Capabilities' = 'WPFWin11ISOFeaturesItems'
            'Privacy / Runtime' = 'WPFWin11ISOPrivacyItems'
            'Developer / Virtualization' = 'WPFWin11ISODeveloperItems'
        }
        foreach ($group in $model.Groups) {
            $sync[$groupControlNames[$group.Name]].ItemsSource = @($group.Items)
        }
    }
    if ($sync['Win11ISOImageInventory']) {
        Resolve-WinUtilComponentPolicyHandoff | Out-Null
    } else {
        $sync['Win11ISOResolvedPlan'] = $null
        $sync['Win11ISOActionBundle'] = $null
        $sync['Win11ISORegistryActions'] = $null
    }
}

function Resolve-WinUtilComponentPolicyHandoff {
    $profileId = [string]$sync['Win11ISOSelectedProfileId']
    $selectedProfile = @($sync.configs.componentPolicy.profiles.PSObject.Properties.Value | Where-Object id -eq $profileId) | Select-Object -First 1
    if (-not $selectedProfile -and $profileId -eq 'custom') {
        $selectedProfile = [pscustomobject]@{
            schemaVersion = 1; documentType = 'component-profile'; id = 'custom'; name = 'Custom'
            description = 'Catalog defaults with explicit package overrides.'; actions = [pscustomobject]@{}
        }
    }
    if (-not $selectedProfile) { throw "Selected component profile '$profileId' is unavailable." }

    $result = Resolve-WinUtilComponentPolicyPlan `
        -Inventory $sync['Win11ISOImageInventory'] `
        -Catalog $sync.configs.componentPolicy.catalog `
        -ComponentProfile $selectedProfile `
        -OfflineSystemSelect $sync['Win11ISOOfflineSession'].OfflineSystemSelect `
        -ManualOverride @($sync['Win11ISOManualOverrides']) `
        -ExpertMode:($sync.WPFWin11ISOExpertMode.IsChecked -eq $true)
    $registryActions = @($result.ActionBundle.RegistryActions)
    Set-WinUtilAdvancedPackageSelectorUI `
        -ImageInventory $sync['Win11ISOImageInventory'] `
        -ResolvedPlan $result.ResolvedPlan `
        -Safety $result.Safety `
        -ActionBundle $result.ActionBundle `
        -RegistryActions $registryActions
    return $result
}

function Set-WinUtilAdvancedPackageSelectorUI {
    param (
        [Parameter(Mandatory)][psobject]$ImageInventory,
        [psobject]$ResolvedPlan,
        [psobject]$Safety,
        [psobject]$ActionBundle,
        [Parameter()][AllowEmptyCollection()][object[]]$RegistryActions
    )

    $sync['Win11ISOImageInventory'] = $ImageInventory
    $sync['Win11ISOResolvedPlan'] = $ResolvedPlan
    $sync['Win11ISOActionBundle'] = $ActionBundle
    $sync['Win11ISORegistryActions'] = $RegistryActions
    $expertMode = $sync.WPFWin11ISOExpertMode.IsChecked -eq $true
    $rows = @(New-WinUtilAdvancedPackageSelectorModel `
        -ImageInventory $ImageInventory `
        -ResolvedPlan $ResolvedPlan `
        -ManualOverride @($sync['Win11ISOManualOverrides']) `
        -ExpertMode:$expertMode)
    $sync['Win11ISOAdvancedPackageRows'] = $rows
    $handoff = New-WinUtilComponentPolicyHandoff `
        -SelectedProfileId ([string]$sync['Win11ISOSelectedProfileId']) `
        -ImageInventory $ImageInventory `
        -ResolvedPlan $ResolvedPlan `
        -Safety $Safety `
        -ActionBundle $ActionBundle `
        -RegistryActions $RegistryActions
    $sync['Win11ISOPolicyHandoff'] = $handoff

    Invoke-WPFUIThread {
        $sync.WPFWin11ISOAdvancedPackageItems.ItemsSource = $rows
        $sync.WPFWin11ISOExpertWarning.Visibility = if ($expertMode) { 'Visible' } else { 'Collapsed' }
        $sync.WPFWin11ISOPolicyHandoffStatus.Text = $handoff.Status
        $sync.WPFWin11ISOPolicyHandoffStatus.Foreground = if ($handoff.IsReady) { 'Green' } else { 'OrangeRed' }
        $sync.WPFWin11ISOModifyButton.IsEnabled = $handoff.IsReady
    }
}

function Initialize-WinUtilComponentPolicyUI {
    $model = New-WinUtilComponentPolicyPresentation `
        -Catalog $sync.configs.componentPolicy.catalog `
        -Profiles @($sync.configs.componentPolicy.profiles.PSObject.Properties.Value)
    $sync.ComponentPolicyPresentation = $model

    Invoke-WPFUIThread {
        $sync.WPFWin11ISOProfileComboBox.ItemsSource = @($model.Profiles)
        $sync.WPFWin11ISOProfileComboBox.DisplayMemberPath = 'Name'
        $sync.WPFWin11ISOProfileComboBox.SelectedValuePath = 'Id'
        $sync.WPFWin11ISOProfileComboBox.SelectedValue = $model.SelectedProfileId
    }
    Update-WinUtilComponentPolicyUI -SelectedProfileId $model.SelectedProfileId
}
