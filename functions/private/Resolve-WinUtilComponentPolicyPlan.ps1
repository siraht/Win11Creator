function Resolve-WinUtilComponentPolicyPlan {
    <#
        .SYNOPSIS
        Adapts a component catalog and profile into a safe offline image plan.
    #>
    param (
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][psobject]$Catalog,
        [Parameter(Mandatory)][Alias('Profile')][psobject]$ComponentProfile,
        [System.Collections.IDictionary]$ActionOverrides = @{},
        [switch]$ExpertMode
    )

    Test-WinUtilComponentPolicy -Policy $Catalog -ThrowOnError | Out-Null
    Test-WinUtilComponentPolicy -Policy $ComponentProfile -Catalog $Catalog -ThrowOnError | Out-Null

    $selectedActions = @{}
    $resolverRules = [System.Collections.Generic.List[object]]::new()
    $safetyDeclarations = [System.Collections.Generic.List[object]]::new()
    $protectedOverrideConflicts = [System.Collections.Generic.List[object]]::new()

    foreach ($component in @($Catalog.components)) {
        $componentId = [string]$component.id
        $profileProperty = $ComponentProfile.actions.PSObject.Properties[$componentId]
        $profileAction = if ($profileProperty) { [string]$profileProperty.Value } else { [string]$component.defaultAction }
        $selectedAction = $profileAction

        if ($ActionOverrides.Contains($componentId)) {
            $selectedAction = ([string]$ActionOverrides[$componentId]).ToLowerInvariant()
            if ($selectedAction -notin @('keep', 'remove', 'disable', 'manual', 'protected')) {
                throw "Override for component '$componentId' has unsupported action '$selectedAction'."
            }
            if ($profileAction -eq 'protected' -and $selectedAction -ne 'protected') {
                $protectedOverrideConflicts.Add([pscustomobject]@{
                    ComponentId = $componentId
                    RelatedComponentId = $componentId
                    Severity = 'forbidden-unless-expert'
                    Reason = "Profile '$($ComponentProfile.id)' protects component '$componentId'; override requested '$selectedAction'."
                    IsBlocking = -not $ExpertMode.IsPresent
                })
            }
        }

        $selectedActions[$componentId] = $selectedAction
        $resolverRules.Add([pscustomobject]@{
            Id = $componentId
            Action = (Get-Culture).TextInfo.ToTitleCase($selectedAction)
            Risk = (Get-Culture).TextInfo.ToTitleCase([string]$component.risk)
            Reason = [string]$component.reason
            Targets = @($component.targets)
        })
        $safetyDeclarations.Add([pscustomobject]@{
            Id = $componentId
            Requires = @(@($component.requires) + @($component.protects) | Sort-Object -Unique)
            Conflicts = @($component.conflicts)
        })
    }

    foreach ($overrideId in @($ActionOverrides.Keys)) {
        if (-not $selectedActions.ContainsKey([string]$overrideId)) {
            throw "Override references unknown component '$overrideId'."
        }
    }

    $evaluatedSafety = Test-WinUtilComponentSafety `
        -ComponentDeclarations @($safetyDeclarations) `
        -SelectedActions $selectedActions `
        -ExpertMode:$ExpertMode
    $allConflicts = @($evaluatedSafety.Conflicts) + @($protectedOverrideConflicts)
    $safety = [pscustomobject]@{
        IsAllowed = @($allConflicts | Where-Object IsBlocking).Count -eq 0
        ExpertMode = $ExpertMode.IsPresent
        ProtectedComponentIds = @($evaluatedSafety.ProtectedComponentIds)
        Conflicts = @($allConflicts)
    }

    [pscustomobject]@{
        ProfileId = [string]$ComponentProfile.id
        Rules = @($resolverRules)
        Safety = $safety
        ResolvedPlan = Resolve-WinUtilOfflineImagePolicy -Inventory $Inventory -Policy @($resolverRules)
    }
}
