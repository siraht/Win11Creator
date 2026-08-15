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

    $validationErrors = New-Object System.Collections.Generic.List[string]
    $allowedActions = @("keep", "remove", "disable", "manual", "protected")
    $allowedRisks = @("safe", "moderate", "high", "expert")
    $allowedTargetKinds = @("appx", "package", "capability", "feature", "registry", "service", "scheduled-task")
    $allowedMatchTypes = @("exact", "wildcard", "version-insensitive")
    $allowedConflictSeverities = @("warning", "likely-breakage", "forbidden-unless-expert")
    $allowedRegistryHives = @("SOFTWARE", "SYSTEM", "DEFAULT")
    $allowedRegistryTypes = @("REG_SZ", "REG_EXPAND_SZ", "REG_DWORD", "REG_QWORD", "REG_MULTI_SZ", "REG_BINARY")

    if ($Policy.schemaVersion -ne 1) {
        $validationErrors.Add("Unsupported component policy schemaVersion '$($Policy.schemaVersion)'.")
    }

    if ($Policy.documentType -eq "component-catalog") {
        $ids = New-Object System.Collections.Generic.HashSet[string]
        foreach ($component in @($Policy.components)) {
            $componentId = [string]$component.id
            if ([string]::IsNullOrWhiteSpace($componentId)) {
                $validationErrors.Add("Catalog component is missing id.")
                continue
            }
            if (-not $ids.Add($componentId)) {
                $validationErrors.Add("Catalog contains duplicate component id '$componentId'.")
            }

            foreach ($field in @("name", "category", "description", "reason", "consequences")) {
                if ([string]::IsNullOrWhiteSpace([string]$component.$field)) {
                    $validationErrors.Add("Component '$componentId' is missing $field.")
                }
            }
            if ($allowedActions -notcontains $component.defaultAction) {
                $validationErrors.Add("Component '$componentId' has invalid defaultAction '$($component.defaultAction)'.")
            }
            if ($allowedRisks -notcontains $component.risk) {
                $validationErrors.Add("Component '$componentId' has invalid risk '$($component.risk)'.")
            }
            if (@($component.targets).Count -eq 0) {
                $validationErrors.Add("Component '$componentId' has no targets.")
            }
            foreach ($target in @($component.targets)) {
                if ($allowedTargetKinds -notcontains $target.kind) {
                    $validationErrors.Add("Component '$componentId' has invalid target kind '$($target.kind)'.")
                }
                if ([string]::IsNullOrWhiteSpace([string]$target.match)) {
                    $validationErrors.Add("Component '$componentId' has a target without a match.")
                }
                if ($allowedMatchTypes -notcontains $target.matchType) {
                    $validationErrors.Add("Component '$componentId' has invalid target matchType '$($target.matchType)'.")
                } elseif ($target.matchType -eq "wildcard" -and [string]$target.match -notmatch '[*?]') {
                    $validationErrors.Add("Component '$componentId' wildcard target '$($target.match)' must contain * or ?.")
                } elseif ($target.matchType -ne "wildcard" -and [string]$target.match -match '[*?]') {
                    $validationErrors.Add("Component '$componentId' $($target.matchType) target '$($target.match)' cannot contain * or ?.")
                }
                foreach ($operation in @($target.operations)) {
                    if ($null -eq $operation) {
                        continue
                    }
                    if ($operation.onAction -notin @("remove", "disable")) {
                        $validationErrors.Add("Component '$componentId' target operation has invalid onAction '$($operation.onAction)'.")
                    }
                    switch ([string]$operation.operation) {
                        "set-registry-value" {
                            if ($target.kind -ne "registry") {
                                $validationErrors.Add("Component '$componentId' registry operation is attached to '$($target.kind)' target.")
                            }
                            foreach ($field in @("hive", "key", "name", "type")) {
                                if ([string]::IsNullOrWhiteSpace([string]$operation.$field)) {
                                    $validationErrors.Add("Component '$componentId' registry operation is missing $field.")
                                }
                            }
                            if ($allowedRegistryHives -notcontains $operation.hive) {
                                $validationErrors.Add("Component '$componentId' registry operation has unsupported hive '$($operation.hive)'.")
                            }
                            if ($allowedRegistryTypes -notcontains $operation.type) {
                                $validationErrors.Add("Component '$componentId' registry operation has unsupported type '$($operation.type)'.")
                            }
                            if ($operation.PSObject.Properties.Name -notcontains "value") {
                                $validationErrors.Add("Component '$componentId' registry operation is missing value.")
                            }
                        }
                        "disable-service" {
                            if ($target.kind -ne "service") {
                                $validationErrors.Add("Component '$componentId' service operation is attached to '$($target.kind)' target.")
                            }
                            if ($target.matchType -ne "exact" -or [string]$operation.serviceName -ne [string]$target.match) {
                                $validationErrors.Add("Component '$componentId' service operation must name its exact service target.")
                            }
                            if ($operation.startupType -ne "disabled") {
                                $validationErrors.Add("Component '$componentId' service operation has unsupported startupType '$($operation.startupType)'.")
                            }
                        }
                        "disable-scheduled-task-at-setup" {
                            if ($target.kind -ne "scheduled-task") {
                                $validationErrors.Add("Component '$componentId' scheduled-task operation is attached to '$($target.kind)' target.")
                            }
                            if ([string]$operation.taskPath -notmatch '^\\Microsoft\\Windows\\[^*?]+$') {
                                $validationErrors.Add("Component '$componentId' scheduled-task operation requires an exact Microsoft task path.")
                            }
                        }
                        default {
                            $validationErrors.Add("Component '$componentId' target has unsupported operation '$($operation.operation)'.")
                        }
                    }
                }
            }
            foreach ($conflict in @($component.conflicts)) {
                if ($allowedActions -notcontains $conflict.action) {
                    $validationErrors.Add("Component '$componentId' conflict has invalid action '$($conflict.action)'.")
                }
                if ($allowedActions -notcontains $conflict.withAction) {
                    $validationErrors.Add("Component '$componentId' conflict has invalid withAction '$($conflict.withAction)'.")
                }
                if ($allowedConflictSeverities -notcontains $conflict.severity) {
                    $validationErrors.Add("Component '$componentId' conflict has invalid severity '$($conflict.severity)'.")
                }
                if ([string]::IsNullOrWhiteSpace([string]$conflict.reason)) {
                    $validationErrors.Add("Component '$componentId' conflict is missing reason.")
                }
            }
            if ($component.exposed -eq $true) {
                foreach ($field in @("description", "reason", "consequences")) {
                    if ([string]::IsNullOrWhiteSpace([string]$component.$field)) {
                        $validationErrors.Add("Exposed component '$componentId' is missing $field.")
                    }
                }
                if ($null -eq $component.reversible -or $component.reversible -isnot [bool]) {
                    $validationErrors.Add("Exposed component '$componentId' is missing boolean reversible metadata.")
                }
            }
        }
        foreach ($component in @($Policy.components)) {
            $componentId = [string]$component.id
            foreach ($reference in @($component.requires) + @($component.protects)) {
                if (-not $ids.Contains([string]$reference)) {
                    $validationErrors.Add("Component '$componentId' references unknown dependency '$reference'.")
                }
            }
            foreach ($conflict in @($component.conflicts)) {
                if (-not $ids.Contains([string]$conflict.with)) {
                    $validationErrors.Add("Component '$componentId' references unknown conflict component '$($conflict.with)'.")
                }
            }
        }
    } elseif ($Policy.documentType -eq "component-profile") {
        foreach ($field in @("id", "name", "description")) {
            if ([string]::IsNullOrWhiteSpace([string]$Policy.$field)) {
                $validationErrors.Add("Component profile is missing $field.")
            }
        }
        if ($null -eq $Policy.actions) {
            $validationErrors.Add("Component profile is missing actions.")
        } else {
            $catalogIds = @()
            if ($Catalog) {
                $catalogIds = @($Catalog.components | ForEach-Object { $_.id })
            }
            foreach ($actionProperty in @($Policy.actions.PSObject.Properties)) {
                if ($allowedActions -notcontains $actionProperty.Value) {
                    $validationErrors.Add("Profile '$($Policy.id)' has invalid action '$($actionProperty.Value)' for '$($actionProperty.Name)'.")
                }
                if ($Catalog -and $catalogIds -notcontains $actionProperty.Name) {
                    $validationErrors.Add("Profile '$($Policy.id)' references unknown component '$($actionProperty.Name)'.")
                }
            }
        }
    } else {
        $validationErrors.Add("Invalid component policy documentType '$($Policy.documentType)'.")
    }

    if ($validationErrors.Count -gt 0 -and $ThrowOnError) {
        throw ($validationErrors -join "`n")
    }

    return $validationErrors.Count -eq 0
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
        [Alias("Profile")]
        [psobject]$ComponentProfile
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

    $profileAction = $ComponentProfile.actions.PSObject.Properties[$ComponentId]
    $action = if ($profileAction) { [string]$profileAction.Value } else { [string]$component.defaultAction }
    return [pscustomobject]@{
        ComponentId   = $ComponentId
        Action        = $action
        Recommendation = $action
        Risk          = [string]$component.risk
        Known         = $true
    }
}
