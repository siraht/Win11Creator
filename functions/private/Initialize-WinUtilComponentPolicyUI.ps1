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
        [string]$SelectedProfileId = 'default-winutil',
        [System.Collections.IDictionary]$ActionOverrides = @{}
    )

    $preferredProfileIds = @('default-winutil', 'lean-daw')
    $profileOptions = @(
        $Profiles |
            Sort-Object @{ Expression = {
                $preferredIndex = [array]::IndexOf($preferredProfileIds, [string]$_.id)
                if ($preferredIndex -ge 0) { $preferredIndex } else { $preferredProfileIds.Count }
            } }, @{ Expression = { [string]$_.name } } |
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
        if ($ActionOverrides.Contains([string]$component.id)) {
            $action = ([string]$ActionOverrides[[string]$component.id]).ToLowerInvariant()
        }
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

    $exclusiveMemberIds = @($Catalog.exclusiveGroups.members | Sort-Object -Unique)
    $choiceGroups = foreach ($exclusiveGroup in @($Catalog.exclusiveGroups)) {
        $memberItems = @($items | Where-Object Id -in @($exclusiveGroup.members))
        $activeItems = @($memberItems | Where-Object Action -in @('remove', 'disable'))
        if ($activeItems.Count -gt 1) {
            throw "Exclusive group '$($exclusiveGroup.id)' has more than one active choice."
        }
        $options = @(
            [pscustomobject]@{
                Id = 'keep'
                Name = [string]$exclusiveGroup.keepLabel
                ComponentId = ''
                Action = 'keep'
                Risk = 'safe'
                Description = [string]$exclusiveGroup.description
            }
            foreach ($memberItem in $memberItems) {
                [pscustomobject]@{
                    Id = [string]$memberItem.Id
                    Name = [string]$memberItem.Name
                    ComponentId = [string]$memberItem.Id
                    Action = 'disable'
                    Risk = [string]$memberItem.Risk
                    Description = [string]$memberItem.Consequences
                }
            }
        )
        $selectedChoiceId = if ($activeItems.Count -eq 1) { [string]$activeItems[0].Id } else { 'keep' }
        $selectedOption = $options | Where-Object Id -eq $selectedChoiceId | Select-Object -First 1
        [pscustomobject]@{
            Id = [string]$exclusiveGroup.id
            Name = [string]$exclusiveGroup.name
            Description = [string]$exclusiveGroup.description
            MemberIds = @($exclusiveGroup.members)
            Options = @($options)
            SelectedChoiceId = $selectedChoiceId
            SelectedRisk = [string]$selectedOption.Risk
            SelectedDescription = [string]$selectedOption.Description
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
            Items = @($items | Where-Object { $_.Group -eq $groupName -and $_.Id -notin $exclusiveMemberIds } | Sort-Object Name)
        }
    }

    [pscustomobject]@{
        Profiles = @($profileOptions)
        SelectedProfileId = $SelectedProfileId
        ChoiceGroups = @($choiceGroups)
        Summary = [pscustomobject]@{
            RemoveCount = @($items | Where-Object Action -eq 'remove').Count
            DisableCount = @($items | Where-Object Action -eq 'disable').Count
            ProtectedCount = @($items | Where-Object Action -eq 'protected').Count
            Risk = $estimatedRisk
        }
        Groups = @($groups)
    }
}

function Set-WinUtilExclusiveComponentChoice {
    <#
    .SYNOPSIS
        Converts one exclusive UI choice into mutually exclusive resolver overrides.
    #>
    param (
        [Parameter(Mandatory)][psobject]$ChoiceGroup,
        [Parameter(Mandatory)][string]$SelectedChoiceId,
        [System.Collections.IDictionary]$ExistingOverrides = @{}
    )

    $selectedOption = @($ChoiceGroup.Options | Where-Object Id -eq $SelectedChoiceId) | Select-Object -First 1
    if (-not $selectedOption) {
        throw "Choice '$SelectedChoiceId' is not valid for exclusive group '$($ChoiceGroup.Id)'."
    }

    $overrides = @{}
    foreach ($key in @($ExistingOverrides.Keys)) {
        $overrides[[string]$key] = [string]$ExistingOverrides[$key]
    }
    foreach ($memberId in @($ChoiceGroup.MemberIds)) {
        $overrides[[string]$memberId] = 'keep'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$selectedOption.ComponentId)) {
        $overrides[[string]$selectedOption.ComponentId] = [string]$selectedOption.Action
    }

    [pscustomobject]@{
        ActionOverrides = $overrides
        SelectedChoiceId = [string]$selectedOption.Id
        Risk = [string]$selectedOption.Risk
        Warning = [string]$selectedOption.Description
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
        [psobject]$RecommendationPlan,
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
    $recommendationByKey = @{}
    foreach ($decision in @($RecommendationPlan.Decisions)) {
        $recommendationByKey['{0}|{1}' -f [string]$decision.Kind, [string]$decision.Identity] = $decision
    }

    foreach ($item in @($ImageInventory.Items | Sort-Object Kind, Identity)) {
        $key = '{0}|{1}' -f [string]$item.Kind, [string]$item.Identity
        $effectiveDecision = $decisionByKey[$key]
        $recommendationDecision = if ($recommendationByKey.ContainsKey($key)) { $recommendationByKey[$key] } else { $effectiveDecision }
        $isUnknown = $null -eq $recommendationDecision -or (
            [string]$recommendationDecision.Action -eq 'Manual' -and [string]::IsNullOrWhiteSpace([string]$recommendationDecision.PolicyId)
        )
        $recommendation = if ($isUnknown) { 'Manual' } else { [string]$recommendationDecision.Action }
        $rationale = if ($isUnknown) {
            'Unknown component; kept unless explicitly reviewed.'
        } else {
            [string]$recommendationDecision.Reason
        }
        $isProtected = $recommendation -eq 'Protected'
        $initialSelected = -not $isUnknown -and -not $isProtected -and $recommendation -in @('Remove', 'Disable')
        $rowOverride = @($ManualOverride | Where-Object {
            [string]$_.Kind -eq [string]$item.Kind -and [string]$_.Identity -eq [string]$item.Identity
        }) | Select-Object -First 1
        $isSelected = if ($rowOverride) {
            [string]$rowOverride.Action -in @('Remove', 'Disable')
        } elseif ($effectiveDecision) {
            [string]$effectiveDecision.Action -in @('Remove', 'Disable')
        } else { $initialSelected }

        [pscustomobject]@{
            Kind           = [string]$item.Kind
            Name           = [string]$item.Name
            Identity       = [string]$item.Identity
            Recommendation = $recommendation
            Rationale      = $rationale
            Risk           = if ($recommendationDecision) { [string]$recommendationDecision.Risk } else { 'Expert' }
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
        [psobject]$OfflineSession,
        [Parameter()][AllowEmptyCollection()][object[]]$RegistryActions
    )

    $hasInventory = $null -ne $ImageInventory
    $hasResolvedPlan = $null -ne $ResolvedPlan
    $hasActionBundle = $null -ne $ActionBundle
    $hasRegistryActions = $null -ne $RegistryActions
    $safetyAllowed = $null -ne $Safety -and $Safety.IsAllowed -eq $true
    $actionBundleReady = $hasActionBundle -and $ActionBundle.IsReady -eq $true
    $sessionMatch = Test-WinUtilComponentPolicySession -ImageInventory $ImageInventory -OfflineSession $OfflineSession
    $isReady = $hasInventory -and $hasResolvedPlan -and $hasRegistryActions -and $safetyAllowed -and $actionBundleReady -and $sessionMatch.IsValid
    $status = if (-not $hasInventory) {
        'Preview only: inventory, resolved plan, and registry actions have not been staged.'
    } elseif (-not $sessionMatch.IsValid) {
        "Blocked: $($sessionMatch.Reason)"
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
        SessionMatchesInventory = $sessionMatch.IsValid
        IsReady = $isReady
        Status = $status
    }
}

function Test-WinUtilComponentPolicySession {
    param (
        [psobject]$ImageInventory,
        [psobject]$OfflineSession
    )

    if ($null -eq $ImageInventory) { return [pscustomobject]@{ IsValid = $false; Reason = 'No image inventory is staged.' } }
    if ($null -eq $OfflineSession -or [string]$OfflineSession.State -ne 'Mounted') {
        return [pscustomobject]@{ IsValid = $false; Reason = 'The analyzed offline image session is not mounted.' }
    }
    if ([string]$ImageInventory.Source.ImagePath -ne [string]$OfflineSession.InstallImagePath -or
        [int]$ImageInventory.Source.ImageIndex -ne [int]$OfflineSession.ImageIndex) {
        return [pscustomobject]@{ IsValid = $false; Reason = 'The staged inventory does not match the mounted image and edition.' }
    }
    return [pscustomobject]@{ IsValid = $true; Reason = '' }
}

function Clear-WinUtilComponentPolicyAnalysisState {
    <#
    .SYNOPSIS
        Clears inventory-scoped selections and invalidates the live servicing handoff.
    #>
    $sync['Win11ISOImageInventory'] = $null
    $sync['Win11ISOManualOverrides'] = @()
    Update-WinUtilComponentPolicyUI `
        -SelectedProfileId ([string]$sync['Win11ISOSelectedProfileId']) `
        -ActionOverrides $sync['Win11ISOComponentActionOverrides']
}

function Update-WinUtilComponentPolicyUI {
    param (
        [Parameter(Mandatory)][string]$SelectedProfileId,
        [System.Collections.IDictionary]$ActionOverrides = @{}
    )

    $model = New-WinUtilComponentPolicyPresentation `
        -Catalog $sync.configs.componentPolicy.catalog `
        -Profiles @($sync.configs.componentPolicy.profiles.PSObject.Properties.Value) `
        -SelectedProfileId $SelectedProfileId `
        -ActionOverrides $ActionOverrides
    $sync.ComponentPolicyPresentation = $model
    $sync['Win11ISOSelectedProfileId'] = $SelectedProfileId
    $sync['Win11ISOComponentActionOverrides'] = $ActionOverrides
    $sync['Win11ISOResolvedPlan'] = $null
    $sync['Win11ISORegistryActions'] = $null
    $sync['Win11ISOActionBundle'] = $null
    $sync['Win11ISOAdvancedPackageRows'] = @()
    $handoff = New-WinUtilComponentPolicyHandoff `
        -SelectedProfileId $SelectedProfileId `
        -ImageInventory $sync['Win11ISOImageInventory'] `
        -OfflineSession $sync['Win11ISOOfflineSession']
    $sync['Win11ISOPolicyHandoff'] = $handoff

    $wasUpdatingExclusiveChoices = $sync['Win11ISOUpdatingExclusiveChoices'] -eq $true
    $sync['Win11ISOUpdatingExclusiveChoices'] = $true
    try {
        Invoke-WPFUIThread {
            $sync.WPFWin11ISOSummaryRemove.Text = [string]$model.Summary.RemoveCount
            $sync.WPFWin11ISOSummaryDisable.Text = [string]$model.Summary.DisableCount
            $sync.WPFWin11ISOSummaryProtected.Text = [string]$model.Summary.ProtectedCount
            $sync.WPFWin11ISOSummaryRisk.Text = ([string]$model.Summary.Risk).ToUpperInvariant()
            $sync.WPFWin11ISOPolicyHandoffStatus.Text = $handoff.Status
            $sync.WPFWin11ISOPolicyHandoffStatus.Foreground = 'OrangeRed'
            $sync.WPFWin11ISOModifyButton.IsEnabled = $false
            $sync.WPFWin11ISOAdvancedPackageItems.ItemsSource = @()
            $sync.WPFWin11ISOExclusiveChoices.ItemsSource = @($model.ChoiceGroups)

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
    } finally {
        $sync['Win11ISOUpdatingExclusiveChoices'] = $wasUpdatingExclusiveChoices
    }
    $sessionMatch = Test-WinUtilComponentPolicySession -ImageInventory $sync['Win11ISOImageInventory'] -OfflineSession $sync['Win11ISOOfflineSession']
    if ($sessionMatch.IsValid) {
        Resolve-WinUtilComponentPolicyHandoff | Out-Null
    } else {
        $sync['Win11ISOResolvedPlan'] = $null
        $sync['Win11ISOActionBundle'] = $null
        $sync['Win11ISORegistryActions'] = $null
    }
}

function Resolve-WinUtilComponentPolicyHandoff {
    $sessionMatch = Test-WinUtilComponentPolicySession -ImageInventory $sync['Win11ISOImageInventory'] -OfflineSession $sync['Win11ISOOfflineSession']
    if (-not $sessionMatch.IsValid) { throw $sessionMatch.Reason }
    $profileId = [string]$sync['Win11ISOSelectedProfileId']
    $actionOverrides = $sync['Win11ISOComponentActionOverrides']
    if ($null -eq $actionOverrides) { $actionOverrides = @{} }
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
        -ActionOverrides $actionOverrides `
        -OfflineSystemSelect $sync['Win11ISOOfflineSession'].OfflineSystemSelect `
        -ManualOverride @($sync['Win11ISOManualOverrides']) `
        -ExpertMode:($sync.WPFWin11ISOExpertMode.IsChecked -eq $true)
    $registryActions = @($result.ActionBundle.RegistryActions)
    Set-WinUtilAdvancedPackageSelectorUI `
        -ImageInventory $sync['Win11ISOImageInventory'] `
        -ResolvedPlan $result.ResolvedPlan `
        -RecommendationPlan $result.BaseResolvedPlan `
        -Safety $result.Safety `
        -ActionBundle $result.ActionBundle `
        -RegistryActions $registryActions
    return $result
}

function Set-WinUtilAdvancedPackageSelectorUI {
    param (
        [Parameter(Mandatory)][psobject]$ImageInventory,
        [psobject]$ResolvedPlan,
        [psobject]$RecommendationPlan,
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
        -RecommendationPlan $RecommendationPlan `
        -ManualOverride @($sync['Win11ISOManualOverrides']) `
        -ExpertMode:$expertMode)
    $sync['Win11ISOAdvancedPackageRows'] = $rows
    $handoff = New-WinUtilComponentPolicyHandoff `
        -SelectedProfileId ([string]$sync['Win11ISOSelectedProfileId']) `
        -ImageInventory $ImageInventory `
        -ResolvedPlan $ResolvedPlan `
        -Safety $Safety `
        -ActionBundle $ActionBundle `
        -OfflineSession $sync['Win11ISOOfflineSession'] `
        -RegistryActions $RegistryActions
    $sync['Win11ISOPolicyHandoff'] = $handoff

    $wasUpdatingAdvancedSelector = $sync['Win11ISOUpdatingAdvancedSelector'] -eq $true
    $sync['Win11ISOUpdatingAdvancedSelector'] = $true
    try {
        Invoke-WPFUIThread {
            $sync.WPFWin11ISOAdvancedPackageItems.ItemsSource = $rows
            if ($expertMode) {
                $sync.WPFWin11ISOExpertWarning.Text = 'Expert mode can override protected recommendations. Review dependencies and risk before selecting a protected component.'
                $sync.WPFWin11ISOExpertWarning.Visibility = 'Visible'
            } elseif ($handoff.SafetyAllowed) {
                $sync.WPFWin11ISOExpertWarning.Visibility = 'Collapsed'
            } else {
                $sync.WPFWin11ISOExpertWarning.Text = 'Blocked by component safety policy. Re-enable Expert mode to review or clear protected overrides.'
                $sync.WPFWin11ISOExpertWarning.Visibility = 'Visible'
            }
            $sync.WPFWin11ISOPolicyHandoffStatus.Text = $handoff.Status
            $sync.WPFWin11ISOPolicyHandoffStatus.Foreground = if ($handoff.IsReady) { 'Green' } else { 'OrangeRed' }
            $sync.WPFWin11ISOModifyButton.IsEnabled = $handoff.IsReady
        }
    } finally {
        $sync['Win11ISOUpdatingAdvancedSelector'] = $wasUpdatingAdvancedSelector
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
