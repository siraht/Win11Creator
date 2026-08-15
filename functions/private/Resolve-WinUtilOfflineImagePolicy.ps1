function ConvertTo-WinUtilVersionInsensitiveIdentity {
    param ([Parameter(Mandatory)][string]$Identity)

    $normalized = $Identity -replace '_\d+(?:\.\d+){1,3}_[^_]+_[^_]+$', ''
    $normalized = $normalized -replace '(~[^~]+~[^~]*~)[^~]+$', '$1'
    return $normalized
}

function Test-WinUtilInventoryTargetMatch {
    param (
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)]$Target
    )

    if ([string]$Item.Kind -ne [string]$Target.Kind) { return $false }
    $matchType = ([string]$Target.MatchType).ToLowerInvariant()
    $candidateValues = @([string]$Item.Identity, [string]$Item.Name) | Select-Object -Unique

    switch ($matchType) {
        'exact' {
            return @($candidateValues | Where-Object { $_ -ieq [string]$Target.Match }).Count -gt 0
        }
        'wildcard' {
            if ([string]$Target.Match -notmatch '[*?]') {
                throw "Wildcard target '$($Target.Match)' must contain * or ?."
            }
            return @($candidateValues | Where-Object { $_ -ilike [string]$Target.Match }).Count -gt 0
        }
        'version-insensitive' {
            $expected = ConvertTo-WinUtilVersionInsensitiveIdentity -Identity ([string]$Target.Match)
            return @($candidateValues | Where-Object {
                (ConvertTo-WinUtilVersionInsensitiveIdentity -Identity $_) -ieq $expected
            }).Count -gt 0
        }
        default { throw "Unsupported target match type '$matchType'." }
    }
}

function Resolve-WinUtilOfflineImagePolicy {
    param (
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Policy,
        [AllowEmptyCollection()][object[]]$ManualOverride = @()
    )

    if ([string]$Inventory.SchemaVersion -ne '1.0' -or -not $Inventory.Source -or $null -eq $Inventory.Items) {
        throw 'ImageInventory must use schema version 1.0 and contain Source and Items.'
    }

    $decisions = @{}
    foreach ($item in @($Inventory.Items)) {
        $itemKey = '{0}|{1}' -f [string]$item.Kind, [string]$item.Identity
        if ($decisions.ContainsKey($itemKey)) {
            throw "ImageInventory contains duplicate item '$itemKey'."
        }
        $decisions[$itemKey] = [pscustomobject][ordered]@{
            Kind       = [string]$item.Kind
            Name       = [string]$item.Name
            Identity   = [string]$item.Identity
            Action     = 'Manual'
            PolicyId   = ''
            Risk       = ''
            Reason     = 'Unknown component; kept unless explicitly overridden.'
        }
    }

    foreach ($rule in $Policy) {
        $ruleAction = if ($rule.Action) { [string]$rule.Action } else { [string]$rule.DefaultAction }
        if ($ruleAction -notin @('Keep', 'Remove', 'Disable', 'Manual', 'Protected')) {
            throw "Policy '$($rule.Id)' has unsupported action '$ruleAction'."
        }

        foreach ($target in @($rule.Targets)) {
            $targetMatches = @($Inventory.Items | Where-Object { Test-WinUtilInventoryTargetMatch -Item $_ -Target $target })
            if ($targetMatches.Count -gt 1 -and [string]$rule.Risk -in @('High', 'Expert')) {
                throw "High-risk policy '$($rule.Id)' target '$($target.Match)' is ambiguous ($($targetMatches.Count) matches)."
            }
            foreach ($match in $targetMatches) {
                $matchKey = '{0}|{1}' -f [string]$match.Kind, [string]$match.Identity
                $current = $decisions[$matchKey]
                if ($current.Action -eq 'Protected') { continue }
                $current.Action = $ruleAction
                $current.PolicyId = [string]$rule.Id
                $current.Risk = [string]$rule.Risk
                $current.Reason = [string]$rule.Reason
            }
        }
    }

    foreach ($override in $ManualOverride) {
        $identity = [string]$override.Identity
        $overrideMatches = @($decisions.Values | Where-Object {
            $_.Identity -eq $identity -and (-not $override.Kind -or $_.Kind -eq [string]$override.Kind)
        })
        if ($overrideMatches.Count -eq 0) {
            throw "Manual override target '$identity' is not present in the image inventory."
        }
        if ($overrideMatches.Count -gt 1) {
            throw "Manual override target '$identity' is ambiguous; specify Kind."
        }
        $action = [string]$override.Action
        if ($action -notin @('Keep', 'Remove', 'Disable', 'Manual', 'Protected')) {
            throw "Manual override for '$identity' has unsupported action '$action'."
        }
        $decision = $overrideMatches[0]
        $decision.Action = $action
        $decision.PolicyId = 'manual-override'
        $decision.Risk = ''
        $decision.Reason = if ($override.Reason) { [string]$override.Reason } else { 'Manual override.' }
    }

    # Protection is deliberately resolved last so catalog protection cannot be weakened by removal or overrides.
    foreach ($rule in @($Policy | Where-Object {
        ([string]$_.Action -eq 'Protected') -or (-not $_.Action -and [string]$_.DefaultAction -eq 'Protected')
    })) {
        foreach ($target in @($rule.Targets)) {
            foreach ($match in @($Inventory.Items | Where-Object { Test-WinUtilInventoryTargetMatch -Item $_ -Target $target })) {
                $matchKey = '{0}|{1}' -f [string]$match.Kind, [string]$match.Identity
                $decision = $decisions[$matchKey]
                $decision.Action = 'Protected'
                $decision.PolicyId = [string]$rule.Id
                $decision.Risk = [string]$rule.Risk
                $decision.Reason = [string]$rule.Reason
            }
        }
    }

    [pscustomobject][ordered]@{
        SchemaVersion = '1.0'
        Source = $Inventory.Source
        Decisions = @($decisions.Values | Sort-Object Kind, Identity)
    }
}

function Format-WinUtilOfflineImagePlan {
    param ([Parameter(Mandatory, ValueFromPipeline)]$ResolvedPlan)

    process {
        $header = "Image: $($ResolvedPlan.Source.ImagePath) [index $($ResolvedPlan.Source.ImageIndex)] $($ResolvedPlan.Source.ImageName)".TrimEnd()
        $lines = @($header)
        foreach ($decision in @($ResolvedPlan.Decisions)) {
            $lines += ('{0,-9} {1,-10} {2} - {3}' -f $decision.Action.ToUpperInvariant(), $decision.Kind, $decision.Identity, $decision.Reason)
        }
        return $lines -join [Environment]::NewLine
    }
}
