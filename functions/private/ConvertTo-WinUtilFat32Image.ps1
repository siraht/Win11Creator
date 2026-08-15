function ConvertTo-WinUtilFat32Image {
    <#
    .SYNOPSIS
        Prepares install.wim for FAT32 output, splitting only when necessary.
    #>
    param (
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][string]$DestinationDirectory,
        [int64]$SplitThresholdBytes = 3800MB,
        [int]$SplitSizeMB = 3800,
        [scriptblock]$InvokeSplit = {
            param($sourcePath, $splitPath, $fileSizeMB)
            Split-WindowsImage -ImagePath $sourcePath -SplitImagePath $splitPath -FileSize $fileSizeMB -CheckIntegrity -ErrorAction Stop
        }
    )

    if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
        throw "install.wim was not found: $ImagePath"
    }
    if ($SplitThresholdBytes -le 0 -or $SplitSizeMB -le 0) {
        throw 'FAT32 split threshold and segment size must be positive.'
    }

    $imageLength = (Get-Item -LiteralPath $ImagePath).Length
    if ($imageLength -le $SplitThresholdBytes) {
        return [pscustomobject]@{
            Mode = 'Copy'
            SourcePath = $ImagePath
            ExcludeSourceImage = $false
            Segments = @()
        }
    }

    if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
        New-Item -Path $DestinationDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    $splitPath = Join-Path $DestinationDirectory 'install.swm'
    $segmentPattern = 'install*.swm'
    Get-ChildItem -LiteralPath $DestinationDirectory -Filter $segmentPattern -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction Stop

    try {
        & $InvokeSplit $ImagePath $splitPath $SplitSizeMB
        $segments = @(Get-ChildItem -LiteralPath $DestinationDirectory -Filter $segmentPattern -File |
            Where-Object { $_.Name -match '^install(?:\d+)?\.swm$' } |
            Sort-Object { if ($_.BaseName -eq 'install') { 1 } else { [int]($_.BaseName -replace '^install', '') } })
        if ($segments.Count -eq 0 -or $segments[0].Name -ne 'install.swm') {
            throw 'WIM split reported success but did not create install.swm.'
        }
        if (@($segments | Where-Object Length -le 0).Count -gt 0) {
            throw 'WIM split created an empty segment.'
        }

        return [pscustomobject]@{
            Mode = 'Split'
            SourcePath = $ImagePath
            ExcludeSourceImage = $true
            Segments = @($segments.FullName)
        }
    } catch {
        Get-ChildItem -LiteralPath $DestinationDirectory -Filter $segmentPattern -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        throw "FAT32 WIM split failed: $_"
    }
}
