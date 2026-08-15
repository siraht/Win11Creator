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
            IsSelected     = $false
        }
    }
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

function Update-WinUtilComponentPolicyUI {
    param ([Parameter(Mandatory)][string]$SelectedProfileId)

    $model = New-WinUtilComponentPolicyPresentation `
        -Catalog $sync.componentPolicyCatalog `
        -Profiles @($sync.componentPolicyProfiles) `
        -SelectedProfileId $SelectedProfileId
    $sync.ComponentPolicyPresentation = $model

    Invoke-WPFUIThread {
        $sync.WPFWin11ISOSummaryRemove.Text = [string]$model.Summary.RemoveCount
        $sync.WPFWin11ISOSummaryDisable.Text = [string]$model.Summary.DisableCount
        $sync.WPFWin11ISOSummaryProtected.Text = [string]$model.Summary.ProtectedCount
        $sync.WPFWin11ISOSummaryRisk.Text = ([string]$model.Summary.Risk).ToUpperInvariant()

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
}

function Set-WinUtilAdvancedPackageSelectorUI {
    param (
        [Parameter(Mandatory)][psobject]$ImageInventory,
        [psobject]$ResolvedPlan
    )

    $sync.Win11ISOImageInventory = $ImageInventory
    $sync.Win11ISOResolvedPlan = $ResolvedPlan
    $expertMode = $sync.WPFWin11ISOExpertMode.IsChecked -eq $true
    $rows = @(New-WinUtilAdvancedPackageSelectorModel -ImageInventory $ImageInventory -ResolvedPlan $ResolvedPlan -ExpertMode:$expertMode)
    $sync.Win11ISOAdvancedPackageRows = $rows

    Invoke-WPFUIThread {
        $sync.WPFWin11ISOAdvancedPackageItems.ItemsSource = $rows
        $sync.WPFWin11ISOExpertWarning.Visibility = if ($expertMode) { 'Visible' } else { 'Collapsed' }
    }
}

function Initialize-WinUtilComponentPolicyUI {
    $model = New-WinUtilComponentPolicyPresentation `
        -Catalog $sync.componentPolicyCatalog `
        -Profiles @($sync.componentPolicyProfiles)
    $sync.ComponentPolicyPresentation = $model

    Invoke-WPFUIThread {
        $sync.WPFWin11ISOProfileComboBox.ItemsSource = @($model.Profiles)
        $sync.WPFWin11ISOProfileComboBox.DisplayMemberPath = 'Name'
        $sync.WPFWin11ISOProfileComboBox.SelectedValuePath = 'Id'
        $sync.WPFWin11ISOProfileComboBox.SelectedValue = $model.SelectedProfileId
    }
    Update-WinUtilComponentPolicyUI -SelectedProfileId $model.SelectedProfileId
}
