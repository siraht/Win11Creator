function Test-WinUtilComponentSafety {
    <#
        .SYNOPSIS
        Evaluates component selections against dependency and conflict declarations.

        .DESCRIPTION
        Components selected for keep or protected transitively protect everything in
        their Requires declaration. Removing a protected component is forbidden unless
        Expert mode is active. Explicit conflict declarations may use warning,
        likely-breakage, or forbidden-unless-expert severity.
    #>
    param(
        [Parameter(Mandatory)]
        [object[]]$ComponentDeclarations,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$SelectedActions,

        [switch]$ExpertMode
    )

    $componentsById = @{}
    foreach ($component in $ComponentDeclarations) {
        $id = [string]$component.Id
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw "Every component declaration must have a non-empty Id."
        }
        if ($componentsById.ContainsKey($id)) {
            throw "Duplicate component declaration Id: $id"
        }
        $componentsById[$id] = $component
    }

    $actionsById = @{}
    foreach ($entry in $SelectedActions.GetEnumerator()) {
        $id = [string]$entry.Key
        $action = ([string]$entry.Value).ToLowerInvariant()
        if (-not $componentsById.ContainsKey($id)) {
            throw "Selected action references unknown component: $id"
        }
        if ($action -notin @('keep', 'remove', 'disable', 'manual', 'protected')) {
            throw "Unsupported action '$action' for component '$id'."
        }
        $actionsById[$id] = $action
    }

    $protected = @{}
    $protectionSources = @{}
    $pending = [System.Collections.Generic.Queue[string]]::new()
    foreach ($entry in $actionsById.GetEnumerator()) {
        if ($entry.Value -in @('keep', 'protected')) {
            $protected[$entry.Key] = $true
            $protectionSources[$entry.Key] = $entry.Key
            $pending.Enqueue($entry.Key)
        }
    }

    while ($pending.Count -gt 0) {
        $componentId = $pending.Dequeue()
        foreach ($requiredIdValue in @($componentsById[$componentId].Requires)) {
            $requiredId = [string]$requiredIdValue
            if (-not $componentsById.ContainsKey($requiredId)) {
                throw "Component '$componentId' requires undeclared component '$requiredId'."
            }
            if (-not $protected.ContainsKey($requiredId)) {
                $protected[$requiredId] = $true
                $protectionSources[$requiredId] = $protectionSources[$componentId]
                $pending.Enqueue($requiredId)
            }
        }
    }

    $conflicts = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $actionsById.GetEnumerator()) {
        if ($entry.Value -eq 'remove' -and $protected.ContainsKey($entry.Key)) {
            $conflicts.Add([pscustomobject]@{
                ComponentId = $entry.Key
                RelatedComponentId = $protectionSources[$entry.Key]
                Severity = 'forbidden-unless-expert'
                Reason = "Removal conflicts with transitive protection from '$($protectionSources[$entry.Key])'."
                IsBlocking = -not $ExpertMode.IsPresent
            })
        }
    }

    $allowedSeverities = @('warning', 'likely-breakage', 'forbidden-unless-expert')
    foreach ($component in $ComponentDeclarations) {
        $componentId = [string]$component.Id
        foreach ($declaration in @($component.Conflicts)) {
            if ($null -eq $declaration) {
                continue
            }
            $relatedId = [string]$declaration.With
            $action = ([string]$declaration.Action).ToLowerInvariant()
            $relatedAction = ([string]$declaration.WithAction).ToLowerInvariant()
            $severity = ([string]$declaration.Severity).ToLowerInvariant()
            if (-not $componentsById.ContainsKey($relatedId)) {
                throw "Conflict for '$componentId' references undeclared component '$relatedId'."
            }
            if ($severity -notin $allowedSeverities) {
                throw "Conflict for '$componentId' has unsupported severity '$severity'."
            }
            if ($actionsById[$componentId] -eq $action -and $actionsById[$relatedId] -eq $relatedAction) {
                $conflicts.Add([pscustomobject]@{
                    ComponentId = $componentId
                    RelatedComponentId = $relatedId
                    Severity = $severity
                    Reason = [string]$declaration.Reason
                    IsBlocking = $severity -eq 'forbidden-unless-expert' -and -not $ExpertMode.IsPresent
                })
            }
        }
    }

    $blockingConflicts = @($conflicts | Where-Object IsBlocking)
    [pscustomobject]@{
        IsAllowed = $blockingConflicts.Count -eq 0
        ExpertMode = $ExpertMode.IsPresent
        ProtectedComponentIds = @($protected.Keys | Sort-Object)
        Conflicts = @($conflicts)
    }
}
