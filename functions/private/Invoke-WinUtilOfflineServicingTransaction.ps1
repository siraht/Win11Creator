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
        param ([Parameter(Mandatory)]$InputObject, [Parameter(Mandatory)][string]$Path)

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
        [pscustomobject][ordered]@{ SchemaVersion = '1.0'; Source = $Before.Source; Changes = @($changes) }
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
    $mounted = $false
    $committed = $false
    try {
        $staleMounts = @(Get-WindowsImage -Mounted -ErrorAction Stop | Where-Object { $_.Path -eq $MountPath })
        foreach ($staleMount in $staleMounts) {
            & $Log "Discarding stale image mount at '$MountPath'."
            Dismount-WindowsImage -Path $MountPath -Discard -ErrorAction Stop | Out-Null
        }
        if (Test-Path -LiteralPath $MountPath) { Remove-Item -LiteralPath $MountPath -Recurse -Force -ErrorAction Stop }
        New-Item -Path $MountPath -ItemType Directory -Force | Out-Null

        & $Log "Mounting install.wim index $ImageIndex once for offline servicing."
        Mount-WindowsImage -ImagePath $InstallImagePath -Index $ImageIndex -Path $MountPath -ErrorAction Stop | Out-Null
        $mounted = $true

        $before = Get-WinUtilOfflineImageInventory -MountedImagePath $MountPath -SourceImagePath $InstallImagePath -ImageIndex $ImageIndex -ImageName $ImageName -SystemApp $SystemAppDiscovery
        Write-WinUtilOfflineJson -InputObject $before -Path (Join-Path $ManifestDirectory 'ImageInventory.before.json')

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
        Write-WinUtilOfflineJson -InputObject $after -Path (Join-Path $ManifestDirectory 'ImageInventory.after.json')
        Write-WinUtilOfflineJson -InputObject $diff -Path (Join-Path $ManifestDirectory 'ImageInventory.diff.json')

        & $Log 'Committing the offline servicing transaction once.'
        Dismount-WindowsImage -Path $MountPath -Save -ErrorAction Stop | Out-Null
        $mounted = $false
        $committed = $true
        return [pscustomobject][ordered]@{ Before = $before; After = $after; Diff = $diff; ManifestDirectory = $ManifestDirectory }
    } finally {
        if ($mounted -and -not $committed) {
            try { Dismount-WindowsImage -Path $MountPath -Discard -ErrorAction Stop | Out-Null }
            catch { & $Log "Warning: failed to discard offline image mount at '$MountPath': $_" }
        }
        if (Test-Path -LiteralPath $MountPath) { Remove-Item -LiteralPath $MountPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
