function ConvertTo-WinUtilImageInventoryItem {
    param (
        [Parameter(Mandatory)][ValidateSet('AppX', 'Capability', 'Feature', 'Package', 'SystemApp')][string]$Kind,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$InputObject
    )

    foreach ($item in $InputObject) {
        if ($null -eq $item) { continue }

        $name = switch ($Kind) {
            'AppX'       { $item.DisplayName }
            'Capability' { $item.Name }
            'Feature'    { $item.FeatureName }
            'Package'    { $item.PackageName }
            'SystemApp'  { if ($item.Name) { $item.Name } else { $item.Identity } }
        }
        $identity = switch ($Kind) {
            'AppX'       { $item.PackageName }
            'Capability' { $item.Name }
            'Feature'    { $item.FeatureName }
            'Package'    { $item.PackageName }
            'SystemApp'  { if ($item.Identity) { $item.Identity } else { $item.Name } }
        }
        $state = switch ($Kind) {
            'AppX'       { 'Provisioned' }
            'Capability' { $item.State }
            'Feature'    { $item.State }
            'Package'    { $item.PackageState }
            'SystemApp'  { if ($item.State) { $item.State } else { 'Discovered' } }
        }

        if ([string]::IsNullOrWhiteSpace([string]$identity)) {
            throw "A $Kind inventory record did not contain an identity."
        }
        if ([string]::IsNullOrWhiteSpace([string]$name)) { $name = $identity }

        [pscustomobject][ordered]@{
            Kind     = $Kind
            Name     = [string]$name
            Identity = [string]$identity
            State    = [string]$state
        }
    }
}

function Get-WinUtilOfflineImageInventory {
    param (
        [Parameter(Mandatory)][string]$MountedImagePath,
        [Parameter(Mandatory)][string]$SourceImagePath,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ImageIndex,
        [string]$ImageName = '',
        [AllowEmptyCollection()][object[]]$SystemApp = @(),
        [hashtable]$InventoryInput,
        [scriptblock]$DiscoverSystemApp = {
            param([string]$Path)
            @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction Stop)
        }
    )

    if ($InventoryInput) {
        $appx = @($InventoryInput.AppX)
        $capabilities = @($InventoryInput.Capability)
        $features = @($InventoryInput.Feature)
        $packages = @($InventoryInput.Package)
    } else {
        $appx = @(Get-AppxProvisionedPackage -Path $MountedImagePath -ErrorAction Stop)
        $capabilities = @(Get-WindowsCapability -Path $MountedImagePath -ErrorAction Stop)
        $features = @(Get-WindowsOptionalFeature -Path $MountedImagePath -ErrorAction Stop)
        $packages = @(Get-WindowsPackage -Path $MountedImagePath -ErrorAction Stop)
    }

    $systemAppRoot = [IO.Path]::Combine($MountedImagePath, 'Windows', 'SystemApps')
    $discoveredSystemApps = @()
    foreach ($entry in @(& $DiscoverSystemApp $systemAppRoot)) {
        if ($null -eq $entry) { continue }
        $entryName = [string]$entry.Name
        if ([string]::IsNullOrWhiteSpace($entryName) -or $entryName -in @('.', '..') -or $entryName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "A SystemApp discovery record contained a malformed identity."
        }
        $discoveredSystemApps += [pscustomobject]@{
            Name = $entryName
            Identity = $entryName
            State = 'Discovered'
        }
    }
    $allSystemApps = @($discoveredSystemApps) + @($SystemApp)
    $systemAppIdentities = @{}
    foreach ($entry in $allSystemApps) {
        $identity = if ($entry.Identity) { [string]$entry.Identity } else { [string]$entry.Name }
        if ([string]::IsNullOrWhiteSpace($identity)) { throw 'A SystemApp inventory record did not contain an identity.' }
        $key = $identity.Trim().ToUpperInvariant()
        if ($systemAppIdentities.ContainsKey($key)) { throw "Duplicate SystemApp identity '$identity' was discovered." }
        $systemAppIdentities[$key] = $true
    }

    $items = @(
        ConvertTo-WinUtilImageInventoryItem -Kind AppX -InputObject $appx
        ConvertTo-WinUtilImageInventoryItem -Kind Capability -InputObject $capabilities
        ConvertTo-WinUtilImageInventoryItem -Kind Feature -InputObject $features
        ConvertTo-WinUtilImageInventoryItem -Kind Package -InputObject $packages
        ConvertTo-WinUtilImageInventoryItem -Kind SystemApp -InputObject $allSystemApps
    ) | Sort-Object Kind, Identity

    [pscustomobject][ordered]@{
        SchemaVersion = '1.0'
        Source = [pscustomobject][ordered]@{
            ImagePath       = $SourceImagePath
            ImageIndex      = $ImageIndex
            ImageName       = $ImageName
            MountedImagePath = $MountedImagePath
        }
        Items = @($items)
    }
}
