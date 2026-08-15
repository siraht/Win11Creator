function Test-WinUtilComponentPolicy {
    <#
    .SYNOPSIS
        Validates a WinUtil component catalog or profile object.
    #>
    param (
        [Parameter(Mandatory)]
        [psobject]$Policy,

        [Parameter()]
        [psobject]$Catalog,

        [Parameter()]
        [switch]$ThrowOnError
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $allowedActions = @("keep", "remove", "disable", "manual", "protected")
    $allowedRisks = @("safe", "moderate", "high", "expert")
    $allowedTargetKinds = @("appx", "package", "capability", "feature", "registry", "service", "scheduled-task")

    if ($Policy.schemaVersion -ne 1) {
        $errors.Add("Unsupported component policy schemaVersion '$($Policy.schemaVersion)'.")
    }

    if ($Policy.documentType -eq "component-catalog") {
        $ids = New-Object System.Collections.Generic.HashSet[string]
        foreach ($component in @($Policy.components)) {
            $componentId = [string]$component.id
            if ([string]::IsNullOrWhiteSpace($componentId)) {
                $errors.Add("Catalog component is missing id.")
                continue
            }
            if (-not $ids.Add($componentId)) {
                $errors.Add("Catalog contains duplicate component id '$componentId'.")
            }

            foreach ($field in @("name", "category", "description", "reason", "consequences")) {
                if ([string]::IsNullOrWhiteSpace([string]$component.$field)) {
                    $errors.Add("Component '$componentId' is missing $field.")
                }
            }
            if ($allowedActions -notcontains $component.defaultAction) {
                $errors.Add("Component '$componentId' has invalid defaultAction '$($component.defaultAction)'.")
            }
            if ($allowedRisks -notcontains $component.risk) {
                $errors.Add("Component '$componentId' has invalid risk '$($component.risk)'.")
            }
            if (@($component.targets).Count -eq 0) {
                $errors.Add("Component '$componentId' has no targets.")
            }
            foreach ($target in @($component.targets)) {
                if ($allowedTargetKinds -notcontains $target.kind) {
                    $errors.Add("Component '$componentId' has invalid target kind '$($target.kind)'.")
                }
                if ([string]::IsNullOrWhiteSpace([string]$target.match)) {
                    $errors.Add("Component '$componentId' has a target without a match.")
                }
            }
            if ($component.exposed -eq $true) {
                foreach ($field in @("description", "reason", "consequences")) {
                    if ([string]::IsNullOrWhiteSpace([string]$component.$field)) {
                        $errors.Add("Exposed component '$componentId' is missing $field.")
                    }
                }
                if ($null -eq $component.reversible -or $component.reversible -isnot [bool]) {
                    $errors.Add("Exposed component '$componentId' is missing boolean reversible metadata.")
                }
            }
        }
    } elseif ($Policy.documentType -eq "component-profile") {
        foreach ($field in @("id", "name", "description")) {
            if ([string]::IsNullOrWhiteSpace([string]$Policy.$field)) {
                $errors.Add("Component profile is missing $field.")
            }
        }
        if ($null -eq $Policy.actions) {
            $errors.Add("Component profile is missing actions.")
        } else {
            $catalogIds = @()
            if ($Catalog) {
                $catalogIds = @($Catalog.components | ForEach-Object { $_.id })
            }
            foreach ($actionProperty in @($Policy.actions.PSObject.Properties)) {
                if ($allowedActions -notcontains $actionProperty.Value) {
                    $errors.Add("Profile '$($Policy.id)' has invalid action '$($actionProperty.Value)' for '$($actionProperty.Name)'.")
                }
                if ($Catalog -and $catalogIds -notcontains $actionProperty.Name) {
                    $errors.Add("Profile '$($Policy.id)' references unknown component '$($actionProperty.Name)'.")
                }
            }
        }
    } else {
        $errors.Add("Invalid component policy documentType '$($Policy.documentType)'.")
    }

    if ($errors.Count -gt 0 -and $ThrowOnError) {
        throw ($errors -join "`n")
    }

    return $errors.Count -eq 0
}

function Import-WinUtilComponentPolicy {
    <#
    .SYNOPSIS
        Reads and validates a WinUtil component policy JSON document.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [psobject]$Catalog
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Component policy file was not found: $Path"
    }

    try {
        $policy = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        throw "Unable to parse component policy '$Path': $_"
    }

    Test-WinUtilComponentPolicy -Policy $policy -Catalog $Catalog -ThrowOnError | Out-Null
    return $policy
}

function Get-WinUtilComponentPolicyAction {
    <#
    .SYNOPSIS
        Gets the conservative action and recommendation for a component id.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$ComponentId,

        [Parameter(Mandatory)]
        [psobject]$Catalog,

        [Parameter(Mandatory)]
        [psobject]$Profile
    )

    $component = @($Catalog.components | Where-Object { $_.id -eq $ComponentId }) | Select-Object -First 1
    if (-not $component) {
        return [pscustomobject]@{
            ComponentId   = $ComponentId
            Action        = "keep"
            Recommendation = "manual"
            Risk          = "expert"
            Known         = $false
        }
    }

    $profileAction = $Profile.actions.PSObject.Properties[$ComponentId]
    $action = if ($profileAction) { [string]$profileAction.Value } else { [string]$component.defaultAction }
    return [pscustomobject]@{
        ComponentId   = $ComponentId
        Action        = $action
        Recommendation = $action
        Risk          = [string]$component.risk
        Known         = $true
    }
}
