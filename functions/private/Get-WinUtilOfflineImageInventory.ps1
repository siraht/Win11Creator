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
        [hashtable]$InventoryInput
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

    $items = @(
        ConvertTo-WinUtilImageInventoryItem -Kind AppX -InputObject $appx
        ConvertTo-WinUtilImageInventoryItem -Kind Capability -InputObject $capabilities
        ConvertTo-WinUtilImageInventoryItem -Kind Feature -InputObject $features
        ConvertTo-WinUtilImageInventoryItem -Kind Package -InputObject $packages
        ConvertTo-WinUtilImageInventoryItem -Kind SystemApp -InputObject $SystemApp
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
