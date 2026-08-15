function Invoke-WinUtilImageDism {
    param ([Parameter(Mandatory)][string[]]$ArgumentList)

    $output = @(& dism.exe @ArgumentList 2>&1)
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

function Get-WinUtilInstallImage {
    <#
    .SYNOPSIS
        Detects the single install.wim or install.esd in copied setup media.
    #>
    param ([Parameter(Mandatory)][string]$MediaRoot)

    $sourcesRoot = Join-Path $MediaRoot 'sources'
    $wimPath = Join-Path $sourcesRoot 'install.wim'
    $esdPath = Join-Path $sourcesRoot 'install.esd'
    $hasWim = Test-Path -LiteralPath $wimPath -PathType Leaf
    $hasEsd = Test-Path -LiteralPath $esdPath -PathType Leaf

    if ($hasWim -and $hasEsd) {
        throw "Setup media is ambiguous: both sources\install.wim and sources\install.esd exist."
    }
    if (-not $hasWim -and -not $hasEsd) {
        throw "Setup media contains neither sources\install.wim nor sources\install.esd."
    }

    if ($hasWim) {
        return [pscustomobject]@{ Format = 'WIM'; Path = $wimPath }
    }
    return [pscustomobject]@{ Format = 'ESD'; Path = $esdPath }
}

function ConvertFrom-WinUtilWimMetadataOutput {
    param ([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Output)

    $metadata = @{}
    foreach ($line in $Output) {
        if ([string]$line -match '^\s*([^:]+?)\s*:\s*(.*?)\s*$') {
            $metadata[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    return $metadata
}

function Invoke-WinUtilCheckedImageDism {
    param (
        [Parameter(Mandatory)][scriptblock]$InvokeDism,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$Operation
    )

    $result = & $InvokeDism $ArgumentList
    if ($null -eq $result -or $null -eq $result.ExitCode) {
        throw "DISM $Operation did not return an exit code."
    }
    if ([int]$result.ExitCode -ne 0) {
        throw "DISM $Operation failed with exit code $($result.ExitCode)."
    }
    return @($result.Output)
}

function Get-WinUtilImageIndexes {
    param (
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][scriptblock]$InvokeDism
    )

    $output = Invoke-WinUtilCheckedImageDism -InvokeDism $InvokeDism -Operation 'image index query' -ArgumentList @(
        '/English', '/Get-WimInfo', "/WimFile:$ImagePath"
    )
    return @($output | ForEach-Object {
        if ([string]$_ -match '^\s*Index\s*:\s*(\d+)\s*$') { [int]$Matches[1] }
    })
}

function Get-WinUtilImageMetadata {
    param (
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][int]$ImageIndex,
        [Parameter(Mandatory)][scriptblock]$InvokeDism
    )

    $output = Invoke-WinUtilCheckedImageDism -InvokeDism $InvokeDism -Operation 'image metadata query' -ArgumentList @(
        '/English', '/Get-WimInfo', "/WimFile:$ImagePath", "/Index:$ImageIndex"
    )
    return ConvertFrom-WinUtilWimMetadataOutput -Output $output
}

function Export-WinUtilEsdImageToWim {
    <#
    .SYNOPSIS
        Exports one ESD edition to an independently validated single-index WIM.
    #>
    param (
        [Parameter(Mandatory)][string]$SourceImagePath,
        [Parameter(Mandatory)][int]$SourceImageIndex,
        [Parameter(Mandatory)][string]$DestinationImagePath,
        [scriptblock]$InvokeDism = ${function:Invoke-WinUtilImageDism}
    )

    if ([IO.Path]::GetExtension($SourceImagePath) -ine '.esd') {
        throw 'ESD export requires a source path ending in .esd.'
    }
    if (-not (Test-Path -LiteralPath $SourceImagePath -PathType Leaf)) {
        throw "Source ESD was not found: $SourceImagePath"
    }
    if ([IO.Path]::GetFullPath($SourceImagePath) -eq [IO.Path]::GetFullPath($DestinationImagePath)) {
        throw 'Source and destination image paths must be different.'
    }
    if (Test-Path -LiteralPath $DestinationImagePath) {
        throw "Destination WIM already exists: $DestinationImagePath"
    }

    $availableIndexes = @(Get-WinUtilImageIndexes -ImagePath $SourceImagePath -InvokeDism $InvokeDism)
    if ($availableIndexes.Count -eq 0) {
        throw 'Source ESD did not report any image indexes.'
    }
    if ($SourceImageIndex -notin $availableIndexes) {
        throw "Selected ESD index $SourceImageIndex is outside available indexes: $($availableIndexes -join ', ')."
    }

    $sourceMetadata = Get-WinUtilImageMetadata -ImagePath $SourceImagePath -ImageIndex $SourceImageIndex -InvokeDism $InvokeDism
    foreach ($requiredKey in 'Name', 'Edition') {
        if ([string]::IsNullOrWhiteSpace([string]$sourceMetadata[$requiredKey]) -or [string]$sourceMetadata[$requiredKey] -eq '<undefined>') {
            throw "Source ESD metadata is invalid: $requiredKey is undefined."
        }
    }

    $destinationParent = Split-Path -Path $DestinationImagePath -Parent
    if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
        throw "Destination directory was not found: $destinationParent"
    }
    $temporaryPath = Join-Path $destinationParent ".winutil-export-$([guid]::NewGuid().ToString('N')).wim"

    try {
        Invoke-WinUtilCheckedImageDism -InvokeDism $InvokeDism -Operation 'ESD export' -ArgumentList @(
            '/English', '/Export-Image', "/SourceImageFile:$SourceImagePath", "/SourceIndex:$SourceImageIndex",
            "/DestinationImageFile:$temporaryPath", '/Compress:max', '/CheckIntegrity'
        ) | Out-Null
        if (-not (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
            throw 'DISM ESD export reported success but did not create the destination WIM.'
        }

        $exportedIndexes = @(Get-WinUtilImageIndexes -ImagePath $temporaryPath -InvokeDism $InvokeDism)
        if ($exportedIndexes.Count -ne 1 -or $exportedIndexes[0] -ne 1) {
            throw "Exported WIM must contain exactly index 1; found: $($exportedIndexes -join ', ')."
        }
        $exportedMetadata = Get-WinUtilImageMetadata -ImagePath $temporaryPath -ImageIndex 1 -InvokeDism $InvokeDism
        foreach ($metadataKey in 'Name', 'Description', 'Edition', 'Installation', 'Architecture') {
            $before = [string]$sourceMetadata[$metadataKey]
            $after = [string]$exportedMetadata[$metadataKey]
            if ($before -and $after -ne $before) {
                throw "Exported WIM metadata mismatch for ${metadataKey}: '$before' became '$after'."
            }
        }

        Move-Item -LiteralPath $temporaryPath -Destination $DestinationImagePath -ErrorAction Stop
        [pscustomobject]@{
            SourcePath = $SourceImagePath
            SourceIndex = $SourceImageIndex
            DestinationPath = $DestinationImagePath
            DestinationIndex = 1
            Edition = [string]$exportedMetadata.Edition
            Name = [string]$exportedMetadata.Name
        }
    } catch {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $DestinationImagePath) {
            Remove-Item -LiteralPath $DestinationImagePath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}
