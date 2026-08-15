function Resolve-WinUtilComponentPolicyPlan {
    <#
        .SYNOPSIS
        Adapts a component catalog and profile into a safe offline image plan.

        .PARAMETER OfflineSystemSelect
        The mounted offline SYSTEM hive Select key. A single numeric Current value is
        required before service operations can resolve a ControlSetNNN registry path.
    #>
    param (
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][psobject]$Catalog,
        [Parameter(Mandatory)][Alias('Profile')][psobject]$ComponentProfile,
        [System.Collections.IDictionary]$ActionOverrides = @{},
        [psobject]$OfflineSystemSelect,
        [AllowEmptyCollection()][object[]]$ManualOverride = @(),
        [switch]$ExpertMode
    )

    Test-WinUtilComponentPolicy -Policy $Catalog -ThrowOnError | Out-Null
    Test-WinUtilComponentPolicy -Policy $ComponentProfile -Catalog $Catalog -ThrowOnError | Out-Null

    $selectedActions = @{}
    $resolverRules = [System.Collections.Generic.List[object]]::new()
    $safetyDeclarations = [System.Collections.Generic.List[object]]::new()
    $protectedOverrideConflicts = [System.Collections.Generic.List[object]]::new()
    $exclusiveSelectionConflicts = [System.Collections.Generic.List[object]]::new()
    $operationConflicts = [System.Collections.Generic.List[object]]::new()
    $registryActions = [System.Collections.Generic.List[object]]::new()
    $setupActions = [System.Collections.Generic.List[object]]::new()
    $securityOperations = [System.Collections.Generic.List[object]]::new()

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

        if ($selectedAction -in @('remove', 'disable')) {
            foreach ($target in @($component.targets | Where-Object kind -in @('registry', 'service', 'scheduled-task', 'setup', 'security'))) {
                $matchingOperations = @($target.operations | Where-Object onAction -eq $selectedAction)
                if ($matchingOperations.Count -eq 0) {
                    $operationConflicts.Add([pscustomobject]@{
                        ComponentId = $componentId
                        RelatedComponentId = $componentId
                        Severity = 'unsupported-operation'
                        Reason = "Selected action '$selectedAction' has no typed operation for $($target.kind) target '$($target.match)'."
                        IsBlocking = $true
                    })
                    continue
                }
                foreach ($operation in $matchingOperations) {
                    switch ([string]$operation.operation) {
                        'set-registry-value' {
                            $registryActions.Add([pscustomobject]@{
                                Action = 'Set'
                                Hive = [string]$operation.hive
                                Key = [string]$operation.key
                                Name = [string]$operation.name
                                Type = [string]$operation.type
                                Value = $operation.value
                                SourceComponentId = $componentId
                            })
                        }
                        'disable-service' {
                            $currentValues = @($OfflineSystemSelect.Current)
                            $currentControlSet = 0
                            if ($currentValues.Count -ne 1 -or -not [int]::TryParse([string]$currentValues[0], [ref]$currentControlSet) -or $currentControlSet -lt 1 -or $currentControlSet -gt 999) {
                                $operationConflicts.Add([pscustomobject]@{
                                    ComponentId = $componentId
                                    RelatedComponentId = $componentId
                                    Severity = 'unsupported-operation'
                                    Reason = "Service '$($operation.serviceName)' requires one valid offline SYSTEM Select\Current control-set value."
                                    IsBlocking = $true
                                })
                                continue
                            }
                            $registryActions.Add([pscustomobject]@{
                                Action = 'Set'
                                Hive = 'SYSTEM'
                                Key = ('ControlSet{0:D3}\Services\{1}' -f $currentControlSet, [string]$operation.serviceName)
                                Name = 'Start'
                                Type = 'REG_DWORD'
                                Value = 4
                                SourceComponentId = $componentId
                            })
                        }
                        'disable-scheduled-task-at-setup' {
                            $setupActions.Add([pscustomobject]@{
                                Mechanism = 'schtasks-change-disable'
                                Phase = 'specialize'
                                Executable = 'schtasks.exe'
                                Arguments = @('/Change', '/TN', [string]$operation.taskPath, '/Disable')
                                SourceComponentId = $componentId
                            })
                        }
                        'run-onedrive-uninstaller-at-setup' {
                            $setupActions.Add([pscustomobject]@{
                                Mechanism = 'onedrive-built-in-uninstaller'
                                Phase = 'specialize'
                                Executable = 'OneDriveSetup.exe'
                                Arguments = @('/uninstall')
                                SourceComponentId = $componentId
                            })
                        }
                        'remove-defender-offline' {
                            $securityOperations.Add([pscustomobject]@{
                                Operation = 'RemoveDefenderOffline'
                                SourceComponentId = $componentId
                                Status = 'BlockedNoValidatedConsumer'
                            })
                            $operationConflicts.Add([pscustomobject]@{
                                ComponentId = $componentId
                                RelatedComponentId = $componentId
                                Severity = 'unsupported-operation'
                                Reason = 'Defender removal requires a dedicated validated offline consumer; ordinary AppX, feature, package, or service removal is not accepted.'
                                IsBlocking = $true
                            })
                        }
                        default {
                            $operationConflicts.Add([pscustomobject]@{
                                ComponentId = $componentId
                                RelatedComponentId = $componentId
                                Severity = 'unsupported-operation'
                                Reason = "Unsupported typed operation '$($operation.operation)'."
                                IsBlocking = $true
                            })
                        }
                    }
                }
            }
        }
    }

    foreach ($overrideId in @($ActionOverrides.Keys)) {
        if (-not $selectedActions.ContainsKey([string]$overrideId)) {
            throw "Override references unknown component '$overrideId'."
        }
    }

    foreach ($group in @($Catalog.exclusiveGroups)) {
        $activeMembers = @($group.members | Where-Object { $selectedActions[[string]$_] -in @('remove', 'disable') })
        if ($activeMembers.Count -gt 1) {
            $exclusiveSelectionConflicts.Add([pscustomobject]@{
                ComponentId = [string]$activeMembers[0]
                RelatedComponentId = [string]$activeMembers[1]
                Severity = 'mutually-exclusive-selection'
                Reason = "Exclusive group '$($group.name)' permits only one active choice; selected: $($activeMembers -join ', ')."
                IsBlocking = $true
            })
        }
    }

    $evaluatedSafety = Test-WinUtilComponentSafety `
        -ComponentDeclarations @($safetyDeclarations) `
        -SelectedActions $selectedActions `
        -ExpertMode:$ExpertMode
    $baseResolvedPlan = Resolve-WinUtilOfflineImagePolicy -Inventory $Inventory -Policy @($resolverRules)
    $inventoryOverrideConflicts = [System.Collections.Generic.List[object]]::new()
    foreach ($override in $ManualOverride) {
        $baseDecision = @($baseResolvedPlan.Decisions | Where-Object {
            [string]$_.Kind -eq [string]$override.Kind -and [string]$_.Identity -eq [string]$override.Identity
        }) | Select-Object -First 1
        if (-not $baseDecision) { throw "Manual override target '$($override.Identity)' is not present in the resolved inventory." }
        if ([string]$baseDecision.Action -eq 'Manual' -and [string]::IsNullOrWhiteSpace([string]$baseDecision.PolicyId)) {
            throw "Unknown inventory item '$($override.Identity)' remains kept and cannot be overridden."
        }
        if ([string]$baseDecision.Action -eq 'Protected' -and [string]$override.Action -ne 'Protected') {
            $inventoryOverrideConflicts.Add([pscustomobject]@{
                ComponentId = [string]$baseDecision.PolicyId
                RelatedComponentId = [string]$override.Identity
                Severity = 'forbidden-unless-expert'
                Reason = "Protected inventory item '$($override.Identity)' has an explicit '$($override.Action)' override."
                IsBlocking = -not $ExpertMode.IsPresent
            })
        }
    }

    $allConflicts = @($evaluatedSafety.Conflicts) + @($protectedOverrideConflicts) +
        @($inventoryOverrideConflicts) + @($exclusiveSelectionConflicts) + @($operationConflicts)
    $safety = [pscustomobject]@{
        IsAllowed = @($allConflicts | Where-Object IsBlocking).Count -eq 0
        ExpertMode = $ExpertMode.IsPresent
        ProtectedComponentIds = @($evaluatedSafety.ProtectedComponentIds)
        Conflicts = @($allConflicts)
    }
    $resolvedPlan = Resolve-WinUtilOfflineImagePolicy -Inventory $Inventory -Policy @($resolverRules) -ManualOverride $ManualOverride
    foreach ($override in $ManualOverride) {
        $decision = @($resolvedPlan.Decisions | Where-Object {
            [string]$_.Kind -eq [string]$override.Kind -and [string]$_.Identity -eq [string]$override.Identity
        }) | Select-Object -First 1
        $decision.Action = [string]$override.Action
        $decision.PolicyId = 'manual-override'
        $decision.Reason = if ($override.Reason) { [string]$override.Reason } else { 'Manual override.' }
    }
    $resolvedPlan | Add-Member -NotePropertyName IsAllowed -NotePropertyValue $safety.IsAllowed
    $resolvedPlan | Add-Member -NotePropertyName Safety -NotePropertyValue $safety
    $deduplicatedRegistryActions = @($registryActions | Group-Object {
        '{0}|{1}|{2}|{3}|{4}|{5}' -f $_.Action, $_.Hive, $_.Key, $_.Name, $_.Type, $_.Value
    } | ForEach-Object { $_.Group[0] })
    $deduplicatedSetupActions = @($setupActions | Group-Object {
        '{0}|{1}|{2}|{3}' -f $_.Mechanism, $_.Phase, $_.Executable, ($_.Arguments -join '|')
    } | ForEach-Object { $_.Group[0] })
    $requiresSetupStaging = $deduplicatedSetupActions.Count -gt 0
    $actionBundle = [pscustomobject][ordered]@{
        SchemaVersion = '1.0'
        ProfileId = [string]$ComponentProfile.id
        IsAllowed = $safety.IsAllowed
        IsReady = $safety.IsAllowed
        RequiresSetupStaging = $requiresSetupStaging
        Consumers = [pscustomobject]@{
            RegistryActions = 'offline-servicing-transaction'
            SetupActions = 'iso-policy-setup-staging'
        }
        Safety = $safety
        ResolvedPlan = $resolvedPlan
        RegistryActions = $deduplicatedRegistryActions
        SetupActions = $deduplicatedSetupActions
        SecurityOperations = @($securityOperations)
    }

    [pscustomobject]@{
        ProfileId = [string]$ComponentProfile.id
        Rules = @($resolverRules)
        Safety = $safety
        BaseResolvedPlan = $baseResolvedPlan
        ResolvedPlan = $resolvedPlan
        ActionBundle = $actionBundle
    }
}
