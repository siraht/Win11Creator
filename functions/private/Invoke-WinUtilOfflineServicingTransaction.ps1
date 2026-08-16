function Start-WinUtilOfflineServicingSession {
    param (
        [Parameter(Mandatory)][string]$InstallImagePath,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ImageIndex,
        [Parameter(Mandatory)][string]$MountPath,
        [string]$ImageName = '',
        [AllowEmptyCollection()][object[]]$SystemAppDiscovery = @(),
        [scriptblock]$Log = { param($message) Write-Output $message }
    )

    if ([IO.Path]::GetExtension($InstallImagePath) -ne '.wim') {
        throw 'Offline analysis requires install.wim; install.esd support belongs to the image-format workflow.'
    }
    if (-not (Test-Path -LiteralPath $InstallImagePath)) { throw "install.wim was not found: $InstallImagePath" }

    $mountAttempted = $false
    try {
        foreach ($staleMount in @(Get-WindowsImage -Mounted -ErrorAction Stop | Where-Object { $_.Path -eq $MountPath })) {
            $null = & $Log "Discarding stale image mount at '$MountPath'."
            Dismount-WindowsImage -Path $MountPath -Discard -ErrorAction Stop | Out-Null
        }
        if (Test-Path -LiteralPath $MountPath) { Remove-Item -LiteralPath $MountPath -Recurse -Force -ErrorAction Stop }
        New-Item -Path $MountPath -ItemType Directory -Force | Out-Null

        $mountAttempted = $true
        $null = & $Log "Mounting copied install.wim index $ImageIndex once for analysis and servicing."
        Mount-WindowsImage -ImagePath $InstallImagePath -Index $ImageIndex -Path $MountPath -ErrorAction Stop | Out-Null
        $inventory = Get-WinUtilOfflineImageInventory -MountedImagePath $MountPath -SourceImagePath $InstallImagePath -ImageIndex $ImageIndex -ImageName $ImageName -SystemApp $SystemAppDiscovery
        return [pscustomobject][ordered]@{
            SchemaVersion = '1.0'
            State = 'Mounted'
            InstallImagePath = $InstallImagePath
            ImageIndex = $ImageIndex
            ImageName = $ImageName
            MountPath = $MountPath
            Inventory = $inventory
        }
    } catch {
        if ($mountAttempted) {
            $registered = $false
            $cleanupSafe = $true
            try { $registered = @(Get-WindowsImage -Mounted -ErrorAction Stop | Where-Object { $_.Path -eq $MountPath }).Count -gt 0 } catch {
                $registered = $true
                $cleanupSafe = $false
                $null = & $Log "Mounted-image inspection failed after the mount attempt; attempting a conservative discard at '$MountPath'."
            }
            if ($registered) {
                try {
                    Dismount-WindowsImage -Path $MountPath -Discard -ErrorAction Stop | Out-Null
                    $cleanupSafe = $true
                } catch {
                    $null = & $Log "Warning: failed to discard analysis mount at '$MountPath': $_"
                }
            }
        } else {
            $cleanupSafe = $true
        }
        if ($cleanupSafe -and (Test-Path -LiteralPath $MountPath)) { Remove-Item -LiteralPath $MountPath -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Stop-WinUtilOfflineServicingSession {
    param (
        [Parameter(Mandatory)][psobject]$Session,
        [scriptblock]$Log = { param($message) Write-Output $message }
    )

    if ([string]$Session.State -ne 'Mounted') { return }
    try {
        try {
            $registered = @(Get-WindowsImage -Mounted -ErrorAction Stop | Where-Object { $_.Path -eq [string]$Session.MountPath }).Count -gt 0
        } catch {
            $null = & $Log "Mounted-image inspection failed; attempting a conservative discard at '$($Session.MountPath)'."
            $registered = $true
        }
        if ($registered) { Dismount-WindowsImage -Path ([string]$Session.MountPath) -Discard -ErrorAction Stop | Out-Null }
        $Session.State = 'Discarded'
        $null = & $Log "Discarded offline servicing session at '$($Session.MountPath)'."
        if (Test-Path -LiteralPath ([string]$Session.MountPath)) {
            Remove-Item -LiteralPath ([string]$Session.MountPath) -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {
        $Session.State = 'Failed'
        throw "Failed to discard offline servicing session at '$($Session.MountPath)': $_"
    }
}

function Invoke-WinUtilOfflineServicingTransaction {
    param (
        [Parameter(Mandatory)][string]$InstallImagePath,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ImageIndex,
        [Parameter(Mandatory)]$ResolvedPlan,
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)][string]$ManifestDirectory,
        [string]$ImageName = '',
        [string]$DriverDirectory = '',
        [AllowEmptyCollection()][object[]]$RegistryAction = @(),
        [AllowEmptyCollection()][object[]]$SecurityOperation = @(),
        [AllowEmptyCollection()][object[]]$SystemAppDiscovery = @(),
        [psobject]$Session,
        [scriptblock]$PublishManifestSet = { param($source, $destination) [System.IO.Directory]::Move($source, $destination) },
        [scriptblock]$Log = { param($message) Write-Output $message }
    )

    function Invoke-WinUtilOfflineDism {
        param ([string[]]$ArgumentList, [string]$Operation)

        $output = @(& dism.exe @ArgumentList 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $detail = (@($output | Select-Object -Last 20) -join [Environment]::NewLine).Trim()
            throw "DISM $Operation failed with exit code $LASTEXITCODE. $detail".Trim()
        }
        & $Log "DISM $Operation completed."
        return @($output)
    }

    function Assert-WinUtilOfflineComponentStoreHealth {
        param ([switch]$Scan)

        $mode = if ($Scan) { '/ScanHealth' } else { '/CheckHealth' }
        $operation = if ($Scan) { 'component-store-scan-health' } else { 'component-store-check-health' }
        $output = @(Invoke-WinUtilOfflineDism -ArgumentList @('/English', "/Image:$MountPath", '/Cleanup-Image', $mode) -Operation $operation)
        $text = $output -join "`n"
        if ($text -match '(?im)component store (?:is repairable|cannot be repaired)|^\s*(?!No\b).*component store corruption (?:was )?detected') {
            throw "DISM $operation reported component-store corruption; the offline transaction will be discarded."
        }
    }

    function Write-WinUtilOfflineJson {
        param (
            [Parameter(Mandatory)]$InputObject,
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$ManifestType,
            [Parameter(Mandatory)][string]$CollectionProperty
        )

        if ([string]$InputObject.SchemaVersion -ne '1.0' -or [string]$InputObject.ManifestType -ne $ManifestType -or
            $null -eq $InputObject.Source -or $null -eq $InputObject.Source.ImagePath -or [int]$InputObject.Source.ImageIndex -lt 1 -or
            $null -eq $InputObject.PSObject.Properties[$CollectionProperty]) {
            throw "$ManifestType manifest does not satisfy the v1 contract."
        }

        $json = $InputObject | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
    }

    function Get-WinUtilOfflineInventoryDiff {
        param ($Before, $After)

        $beforeMap = @{}
        $afterMap = @{}
        foreach ($item in @($Before.Items)) { $beforeMap["$($item.Kind)|$($item.Identity)"] = $item }
        foreach ($item in @($After.Items)) { $afterMap["$($item.Kind)|$($item.Identity)"] = $item }
        $changes = @()
        foreach ($key in @($beforeMap.Keys | Sort-Object)) {
            if (-not $afterMap.ContainsKey($key)) {
                $changes += [pscustomobject][ordered]@{ Change = 'Removed'; Kind = $beforeMap[$key].Kind; Identity = $beforeMap[$key].Identity; BeforeState = $beforeMap[$key].State; AfterState = $null }
            } elseif ([string]$beforeMap[$key].State -ne [string]$afterMap[$key].State) {
                $changes += [pscustomobject][ordered]@{ Change = 'StateChanged'; Kind = $beforeMap[$key].Kind; Identity = $beforeMap[$key].Identity; BeforeState = $beforeMap[$key].State; AfterState = $afterMap[$key].State }
            }
        }
        foreach ($key in @($afterMap.Keys | Sort-Object)) {
            if (-not $beforeMap.ContainsKey($key)) {
                $changes += [pscustomobject][ordered]@{ Change = 'Added'; Kind = $afterMap[$key].Kind; Identity = $afterMap[$key].Identity; BeforeState = $null; AfterState = $afterMap[$key].State }
            }
        }
        [pscustomobject][ordered]@{ SchemaVersion = '1.0'; ManifestType = 'ImageInventoryDiff'; Source = $Before.Source; Changes = @($changes) }
    }

    function Invoke-WinUtilOfflineRegistryActionBatch {
        param ([object[]]$Actions)

        if ($Actions.Count -eq 0) { return }
        $hiveDefinitions = @{
            SOFTWARE = @{ Root = 'HKLM\WinUtilOfflineSoftware'; File = Join-Path $MountPath 'Windows\System32\config\SOFTWARE' }
            SYSTEM   = @{ Root = 'HKLM\WinUtilOfflineSystem'; File = Join-Path $MountPath 'Windows\System32\config\SYSTEM' }
            DEFAULT  = @{ Root = 'HKU\WinUtilOfflineDefault'; File = Join-Path $MountPath 'Users\Default\NTUSER.DAT' }
        }
        $loaded = [System.Collections.Generic.List[string]]::new()
        try {
            foreach ($hiveName in @($Actions.Hive | Sort-Object -Unique)) {
                $normalizedHive = ([string]$hiveName).ToUpperInvariant()
                if (-not $hiveDefinitions.ContainsKey($normalizedHive)) {
                    throw "Unsupported offline registry hive '$hiveName'."
                }
                $definition = $hiveDefinitions[$normalizedHive]
                & reg.exe load $definition.Root $definition.File 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Failed to load offline registry hive '$normalizedHive'." }
                $loaded.Add($normalizedHive)
            }

            foreach ($action in $Actions) {
                $definition = $hiveDefinitions[([string]$action.Hive).ToUpperInvariant()]
                $registryPath = if ($action.Key) { "$($definition.Root)\$($action.Key)" } else { $definition.Root }
                switch ([string]$action.Action) {
                    'Set' {
                        if ([string]$action.Type -notin @('REG_SZ', 'REG_EXPAND_SZ', 'REG_DWORD', 'REG_QWORD', 'REG_MULTI_SZ', 'REG_BINARY')) {
                            throw "Unsupported registry type '$($action.Type)' for '$registryPath'."
                        }
                        & reg.exe add $registryPath /v ([string]$action.Name) /t ([string]$action.Type) /d ([string]$action.Value) /f 2>&1 | Out-Null
                    }
                    'DeleteValue' { & reg.exe delete $registryPath /v ([string]$action.Name) /f 2>&1 | Out-Null }
                    default { throw "Unsupported offline registry action '$($action.Action)'." }
                }
                if ($LASTEXITCODE -ne 0) { throw "Offline registry action failed for '$registryPath'." }
            }
        } finally {
            foreach ($hiveName in @($loaded | Select-Object -Last $loaded.Count)) {
                & reg.exe unload $hiveDefinitions[$hiveName].Root 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { & $Log "Warning: failed to unload offline registry hive '$hiveName'." }
            }
        }
    }

    function Assert-WinUtilDefenderSecurityOperation {
        param ([object[]]$Operations, $Plan)

        $plannedDefenderTargets = @($Plan.Decisions | Where-Object {
            [string]$_.PolicyId -eq 'defender' -and [string]$_.Action -eq 'Remove' -and [string]$_.Kind -in @('Feature', 'Package')
        })
        if ($Operations.Count -eq 0) {
            if ($plannedDefenderTargets.Count -gt 0) { throw 'Resolved Defender removals require the dedicated RemoveDefenderOffline security operation.' }
            return @()
        }
        if ($Operations.Count -ne 1) { throw 'Exactly one Defender security operation is supported per transaction.' }
        $operation = $Operations[0]
        if ([string]$operation.Operation -ne 'RemoveDefenderOffline' -or [string]$operation.SourceComponentId -ne 'defender') {
            throw 'Security operation must be the exact RemoveDefenderOffline contract sourced by defender.'
        }
        throw 'RemoveDefenderOffline has no validated Microsoft-supported offline Defender antivirus core target for Windows 11 client 25H2; default definitions and Sense/MDE payloads are not the antivirus core.'
    }

    function Assert-WinUtilGenericBeforeState {
        param ($Plan, $BeforeInventory)
        foreach ($decision in @($Plan.Decisions | Where-Object {
            [string]$_.Action -in @('Remove', 'Disable') -and [string]$_.PolicyId -ne 'defender'
        })) {
            $present = @($BeforeInventory.Items | Where-Object {
                [string]$_.Kind -eq [string]$decision.Kind -and [string]$_.Identity -eq [string]$decision.Identity
            })
            $requiredState = switch ([string]$decision.Kind) {
                'AppX' { 'Provisioned' }
                'Capability' { 'Installed' }
                'Feature' { 'Enabled' }
                'Package' { 'Installed' }
            }
            if ($present.Count -ne 1 -or [string]$present[0].State -ne $requiredState) {
                throw "Offline servicing precondition failed: '$($decision.Kind)|$($decision.Identity)' is not uniquely present in state '$requiredState'."
            }
        }
    }

    function Assert-WinUtilGenericAfterState {
        param ($Plan, $BeforeInventory, $AfterInventory)
        foreach ($decision in @($Plan.Decisions)) {
            $beforeMatches = @($BeforeInventory.Items | Where-Object {
                [string]$_.Kind -eq [string]$decision.Kind -and [string]$_.Identity -eq [string]$decision.Identity
            })
            $afterMatches = @($AfterInventory.Items | Where-Object {
                [string]$_.Kind -eq [string]$decision.Kind -and [string]$_.Identity -eq [string]$decision.Identity
            })
            if ([string]$decision.Action -in @('Keep', 'Protected', 'Manual')) {
                if ($beforeMatches.Count -eq 1 -and ($afterMatches.Count -ne 1 -or [string]$afterMatches[0].State -ne [string]$beforeMatches[0].State)) {
                    throw "Offline servicing collateral verification failed: '$($decision.Action)' target '$($decision.Kind)|$($decision.Identity)' changed or disappeared."
                }
                continue
            }
            if ([string]$decision.PolicyId -eq 'defender') { continue }
            switch ("$($decision.Kind)|$($decision.Action)") {
                'AppX|Remove' {
                    if ($afterMatches.Count -ne 0) { throw "Offline servicing verification failed: AppX '$($decision.Identity)' remains provisioned." }
                }
                'Capability|Remove' {
                    if ($afterMatches.Count -gt 1 -or ($afterMatches.Count -eq 1 -and [string]$afterMatches[0].State -ne 'NotPresent')) {
                        throw "Offline servicing verification failed: capability '$($decision.Identity)' is not absent or NotPresent."
                    }
                }
                'Feature|Remove' {
                    if ($afterMatches.Count -gt 1 -or ($afterMatches.Count -eq 1 -and [string]$afterMatches[0].State -ne 'DisabledWithPayloadRemoved')) {
                        throw "Offline servicing verification failed: feature '$($decision.Identity)' is not absent or DisabledWithPayloadRemoved."
                    }
                }
                'Feature|Disable' {
                    if ($afterMatches.Count -ne 1 -or [string]$afterMatches[0].State -ne 'Disabled') {
                        throw "Offline servicing verification failed: feature '$($decision.Identity)' is not Disabled."
                    }
                }
                'Package|Remove' {
                    if ($afterMatches.Count -ne 0) { throw "Offline servicing verification failed: package '$($decision.Identity)' remains installed." }
                }
                default { throw "Offline servicing has no after-state contract for '$($decision.Kind)|$($decision.Action)'." }
            }
        }
    }

    if ([IO.Path]::GetExtension($InstallImagePath) -ne '.wim') { throw 'Offline servicing requires install.wim; install.esd cannot be serviced in place.' }
    if (-not (Test-Path -LiteralPath $InstallImagePath)) { throw "install.wim was not found: $InstallImagePath" }
    if ([string]$ResolvedPlan.SchemaVersion -ne '1.0' -or $null -eq $ResolvedPlan.Decisions) { throw 'ResolvedPlan must use schema version 1.0 and contain Decisions.' }
    if ($ResolvedPlan.PSObject.Properties['Safety'] -and $ResolvedPlan.Safety.IsAllowed -ne $true) {
        throw 'ResolvedPlan safety evaluation is blocking offline servicing.'
    }
    foreach ($decision in @($ResolvedPlan.Decisions | Where-Object Action -in @('Remove', 'Disable'))) {
        if ([string]$decision.Kind -notin @('AppX', 'Capability', 'Feature', 'Package')) {
            throw "Resolved action '$($decision.Action)' for kind '$($decision.Kind)' cannot be safely serviced offline."
        }
        if ([string]$decision.Kind -ne 'Feature' -and [string]$decision.Action -eq 'Disable') {
            throw "Resolved Disable action is unsupported for kind '$($decision.Kind)'."
        }
    }
    if ($DriverDirectory -and -not (Test-Path -LiteralPath $DriverDirectory)) { throw "Driver directory was not found: $DriverDirectory" }
    Assert-WinUtilDefenderSecurityOperation -Operations $SecurityOperation -Plan $ResolvedPlan

    $manifestFullPath = [System.IO.Path]::GetFullPath($ManifestDirectory)
    $manifestParent = Split-Path $manifestFullPath -Parent
    $manifestLeaf = Split-Path $manifestFullPath -Leaf
    if ([string]::IsNullOrWhiteSpace($manifestParent) -or [string]::IsNullOrWhiteSpace($manifestLeaf)) {
        throw "Manifest directory must identify a non-root publication directory: $ManifestDirectory"
    }
    New-Item -Path $manifestParent -ItemType Directory -Force | Out-Null
    if (Test-Path -LiteralPath $manifestFullPath) {
        throw "Transaction manifest destination already exists; refusing stale evidence: $manifestFullPath"
    }
    $pendingManifestDirectory = Join-Path $manifestParent ".$manifestLeaf.pending-$(([guid]::NewGuid()).ToString('N'))"
    New-Item -Path $pendingManifestDirectory -ItemType Directory -ErrorAction Stop | Out-Null
    $mounted = $false
    $committed = $false
    $sessionStartHandledCleanup = $false
    try {
        if ($Session) {
            if ([string]$Session.State -ne 'Mounted' -or [string]$Session.MountPath -ne $MountPath -or [string]$Session.InstallImagePath -ne $InstallImagePath -or [int]$Session.ImageIndex -ne $ImageIndex) {
                throw 'Offline servicing session does not match the selected copied image and index.'
            }
            if ([string]$Session.Inventory.SchemaVersion -ne '1.0' -or [string]$Session.Inventory.Source.ImagePath -ne $InstallImagePath -or [int]$Session.Inventory.Source.ImageIndex -ne $ImageIndex) {
                throw 'Offline servicing session inventory does not match its copied image source contract.'
            }
            $mounted = $true
            $before = $Session.Inventory
        } else {
            try {
                $startedSession = Start-WinUtilOfflineServicingSession -InstallImagePath $InstallImagePath -ImageIndex $ImageIndex -MountPath $MountPath -ImageName $ImageName -SystemAppDiscovery $SystemAppDiscovery -Log $Log
            } catch {
                $sessionStartHandledCleanup = $true
                throw
            }
            $mounted = $true
            $before = $startedSession.Inventory
        }
        Assert-WinUtilGenericBeforeState -Plan $ResolvedPlan -BeforeInventory $before
        $beforeManifest = [pscustomobject][ordered]@{
            SchemaVersion = '1.0'; ManifestType = 'ImageInventoryBefore'; Source = $before.Source; Items = @($before.Items)
        }
        $resolvedPlanSource = if ($ResolvedPlan.Source) { $ResolvedPlan.Source } else { $before.Source }
        $resolvedPlanManifest = [pscustomobject][ordered]@{
            SchemaVersion = '1.0'; ManifestType = 'ResolvedPlan'; Source = $resolvedPlanSource; Decisions = @($ResolvedPlan.Decisions)
        }
        if ($ResolvedPlan.PSObject.Properties['IsAllowed']) {
            $resolvedPlanManifest | Add-Member -NotePropertyName IsAllowed -NotePropertyValue ([bool]$ResolvedPlan.IsAllowed)
        }
        if ($ResolvedPlan.PSObject.Properties['Safety']) {
            $resolvedPlanManifest | Add-Member -NotePropertyName Safety -NotePropertyValue $ResolvedPlan.Safety
        }
        Write-WinUtilOfflineJson -InputObject $beforeManifest -Path (Join-Path $pendingManifestDirectory 'ImageInventory.before.json') -ManifestType 'ImageInventoryBefore' -CollectionProperty 'Items'
        Write-WinUtilOfflineJson -InputObject $resolvedPlanManifest -Path (Join-Path $pendingManifestDirectory 'ResolvedPlan.json') -ManifestType 'ResolvedPlan' -CollectionProperty 'Decisions'
        $dryRunLines = @("Image: $($resolvedPlanSource.ImagePath) [index $($resolvedPlanSource.ImageIndex)] $($resolvedPlanSource.ImageName)".TrimEnd())
        foreach ($decision in @($ResolvedPlan.Decisions)) {
            $dryRunLines += ('{0,-9} {1,-10} {2} - {3}' -f ([string]$decision.Action).ToUpperInvariant(), $decision.Kind, $decision.Identity, $decision.Reason)
        }
        [System.IO.File]::WriteAllLines(
            (Join-Path $pendingManifestDirectory 'ResolvedPlan.txt'),
            $dryRunLines,
            [System.Text.UTF8Encoding]::new($false)
        )

        foreach ($decision in @($ResolvedPlan.Decisions)) {
            if ([string]$decision.Action -in @('Keep', 'Protected', 'Manual')) { continue }
            if ([string]$decision.PolicyId -eq 'defender') { continue }
            switch ([string]$decision.Kind) {
                'AppX' { Remove-AppxProvisionedPackage -Path $MountPath -PackageName ([string]$decision.Identity) -ErrorAction Stop | Out-Null }
                'Capability' { Remove-WindowsCapability -Path $MountPath -Name ([string]$decision.Identity) -ErrorAction Stop | Out-Null }
                'Feature' {
                    $removePayload = [string]$decision.Action -eq 'Remove'
                    Disable-WindowsOptionalFeature -Path $MountPath -FeatureName ([string]$decision.Identity) -Remove:$removePayload -ErrorAction Stop | Out-Null
                }
                'Package' { Remove-WindowsPackage -Path $MountPath -PackageName ([string]$decision.Identity) -ErrorAction Stop | Out-Null }
            }
        }

        Invoke-WinUtilOfflineRegistryActionBatch -Actions $RegistryAction
        if ($DriverDirectory) {
            Invoke-WinUtilOfflineDism -ArgumentList @('/English', "/Image:$MountPath", '/Add-Driver', "/Driver:$DriverDirectory", '/Recurse') -Operation 'add-driver' | Out-Null
        }
        Invoke-WinUtilOfflineDism -ArgumentList @('/English', "/Image:$MountPath", '/Cleanup-Image', '/StartComponentCleanup') -Operation 'component-cleanup' | Out-Null
        Assert-WinUtilOfflineComponentStoreHealth
        if (@($ResolvedPlan.Decisions | Where-Object { [string]$_.Kind -eq 'Package' -and [string]$_.Action -eq 'Remove' }).Count -gt 0) {
            Assert-WinUtilOfflineComponentStoreHealth -Scan
        }

        $after = Get-WinUtilOfflineImageInventory -MountedImagePath $MountPath -SourceImagePath $InstallImagePath -ImageIndex $ImageIndex -ImageName $ImageName -SystemApp $SystemAppDiscovery
        Assert-WinUtilGenericAfterState -Plan $ResolvedPlan -BeforeInventory $before -AfterInventory $after
        $diff = Get-WinUtilOfflineInventoryDiff -Before $before -After $after
        $afterManifest = [pscustomobject][ordered]@{
            SchemaVersion = '1.0'; ManifestType = 'ImageInventoryAfter'; Source = $after.Source; Items = @($after.Items)
        }
        Write-WinUtilOfflineJson -InputObject $afterManifest -Path (Join-Path $pendingManifestDirectory 'ImageInventory.after.json') -ManifestType 'ImageInventoryAfter' -CollectionProperty 'Items'
        Write-WinUtilOfflineJson -InputObject $diff -Path (Join-Path $pendingManifestDirectory 'ImageInventory.diff.json') -ManifestType 'ImageInventoryDiff' -CollectionProperty 'Changes'

        & $Log 'Committing the offline servicing transaction once.'
        Dismount-WindowsImage -Path $MountPath -Save -ErrorAction Stop | Out-Null
        $mounted = $false
        $committed = $true
        if ($Session) { $Session.State = 'Committed' }
        try {
            & $PublishManifestSet $pendingManifestDirectory $manifestFullPath
        } catch {
            throw "Offline image was committed, but atomic manifest publication failed: $_"
        }
        return [pscustomobject][ordered]@{ Before = $before; After = $after; Diff = $diff; ManifestDirectory = $manifestFullPath }
    } finally {
        $requiresDiscard = $mounted
        if (-not $committed -and -not $requiresDiscard -and -not $sessionStartHandledCleanup) {
            try {
                $requiresDiscard = @(
                    Get-WindowsImage -Mounted -ErrorAction Stop | Where-Object { $_.Path -eq $MountPath }
                ).Count -gt 0
            } catch {
                & $Log "Warning: could not inspect the failed offline mount at '$MountPath': $_"
            }
        }
        if ($requiresDiscard -and -not $committed) {
            try {
                Dismount-WindowsImage -Path $MountPath -Discard -ErrorAction Stop | Out-Null
                if ($Session) { $Session.State = 'Discarded' }
            } catch {
                if ($Session) { $Session.State = 'Failed' }
                & $Log "Warning: failed to discard offline image mount at '$MountPath': $_"
            }
        }
        Remove-Item -LiteralPath $pendingManifestDirectory -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $MountPath) { Remove-Item -LiteralPath $MountPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
