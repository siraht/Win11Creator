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
        [AllowEmptyCollection()][object[]]$SystemAppDiscovery = @(),
        [psobject]$Session,
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

    New-Item -Path $ManifestDirectory -ItemType Directory -Force | Out-Null
    $pendingManifestDirectory = Join-Path $ManifestDirectory ".pending-$(([guid]::NewGuid()).ToString('N'))"
    New-Item -Path $pendingManifestDirectory -ItemType Directory -Force | Out-Null
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
            Invoke-WinUtilOfflineDism -ArgumentList @('/English', "/Image:$MountPath", '/Add-Driver', "/Driver:$DriverDirectory", '/Recurse') -Operation 'add-driver'
        }
        Invoke-WinUtilOfflineDism -ArgumentList @('/English', "/Image:$MountPath", '/Cleanup-Image', '/StartComponentCleanup') -Operation 'component-cleanup'

        $after = Get-WinUtilOfflineImageInventory -MountedImagePath $MountPath -SourceImagePath $InstallImagePath -ImageIndex $ImageIndex -ImageName $ImageName -SystemApp $SystemAppDiscovery
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
        foreach ($manifestName in 'ResolvedPlan.json', 'ResolvedPlan.txt', 'ImageInventory.before.json', 'ImageInventory.after.json', 'ImageInventory.diff.json') {
            Move-Item -LiteralPath (Join-Path $pendingManifestDirectory $manifestName) -Destination (Join-Path $ManifestDirectory $manifestName) -Force
        }
        return [pscustomobject][ordered]@{ Before = $before; After = $after; Diff = $diff; ManifestDirectory = $ManifestDirectory }
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
