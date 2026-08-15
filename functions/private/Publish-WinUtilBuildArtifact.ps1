function Read-WinUtilOfflineManifest {
    <#
    .SYNOPSIS
        Reads and validates one versioned offline servicing manifest.
    #>
    param (
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('ResolvedPlan', 'ImageInventoryBefore', 'ImageInventoryAfter', 'ImageInventoryDiff')][string]$ManifestType
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required $ManifestType manifest was not found: $Path"
    }
    try {
        $manifest = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Unable to read $ManifestType manifest '$Path': $_"
    }

    $collectionProperty = if ($ManifestType -eq 'ResolvedPlan') {
        'Decisions'
    } elseif ($ManifestType -eq 'ImageInventoryDiff') {
        'Changes'
    } else {
        'Items'
    }
    if ([string]$manifest.SchemaVersion -ne '1.0' -or [string]$manifest.ManifestType -ne $ManifestType -or
        $null -eq $manifest.Source -or [string]::IsNullOrWhiteSpace([string]$manifest.Source.ImagePath) -or
        [int]$manifest.Source.ImageIndex -lt 1 -or $null -eq $manifest.PSObject.Properties[$collectionProperty]) {
        throw "$ManifestType manifest '$Path' does not satisfy the v1 contract."
    }
    return $manifest
}

function Publish-WinUtilBuildArtifact {
    <#
    .SYNOPSIS
        Atomically publishes validated manifests, the build log, and SHA-256 evidence beside a completed output.
    #>
    param (
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$ManifestDirectory,
        [Parameter(Mandatory)][string]$BuildLogPath,
        [scriptblock]$CopyFile = { param($source, $destination) Copy-Item -LiteralPath $source -Destination $destination -ErrorAction Stop },
        [scriptblock]$GetHash = { param($path) (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash },
        [scriptblock]$PublishDirectory = { param($source, $destination) [System.IO.Directory]::Move($source, $destination) }
    )

    $null = $GetHash
    $outputItem = Get-Item -LiteralPath $OutputPath -ErrorAction Stop
    if (-not $outputItem.PSIsContainer -and $outputItem.Length -eq 0) {
        throw "Completed output is empty: $($outputItem.FullName)"
    }
    if (-not (Test-Path -LiteralPath $ManifestDirectory -PathType Container)) {
        throw "Transaction manifest directory was not found: $ManifestDirectory"
    }
    if (-not (Test-Path -LiteralPath $BuildLogPath -PathType Leaf) -or (Get-Item -LiteralPath $BuildLogPath).Length -eq 0) {
        throw "Required build log was not found or is empty: $BuildLogPath"
    }

    $requiredManifests = [ordered]@{
        'ResolvedPlan.json' = 'ResolvedPlan'
        'ImageInventory.before.json' = 'ImageInventoryBefore'
        'ImageInventory.after.json' = 'ImageInventoryAfter'
        'ImageInventory.diff.json' = 'ImageInventoryDiff'
    }
    foreach ($entry in $requiredManifests.GetEnumerator()) {
        Read-WinUtilOfflineManifest -Path (Join-Path $ManifestDirectory $entry.Key) -ManifestType $entry.Value | Out-Null
    }
    $dryRunPath = Join-Path $ManifestDirectory 'ResolvedPlan.txt'
    if (-not (Test-Path -LiteralPath $dryRunPath -PathType Leaf) -or (Get-Item -LiteralPath $dryRunPath).Length -eq 0) {
        throw "Required resolved-plan dry run was not found or is empty: $dryRunPath"
    }

    $outputParent = if ($outputItem.PSIsContainer) { $outputItem.FullName } else { Split-Path $outputItem.FullName -Parent }
    $evidenceLeaf = if ($outputItem.PSIsContainer) { 'WinUtil-build' } else { "$($outputItem.BaseName).WinUtil-build" }
    $evidenceDirectory = Join-Path $outputParent $evidenceLeaf
    if (Test-Path -LiteralPath $evidenceDirectory) {
        throw "Build evidence destination already exists: $evidenceDirectory"
    }
    $pendingDirectory = Join-Path $outputParent ".$evidenceLeaf.pending-$(([guid]::NewGuid()).ToString('N'))"

    function Get-ValidatedWinUtilHash {
        param ([Parameter(Mandatory)][string]$Path)
        $hashResult = & $GetHash $Path
        $hash = if ($hashResult -is [string]) { $hashResult } else { [string]$hashResult.Hash }
        if ($hash -notmatch '^[A-Fa-f0-9]{64}$') { throw "SHA-256 hashing returned an invalid digest for '$Path'." }
        return $hash.ToUpperInvariant()
    }

    function Get-WinUtilOutputHash {
        if (-not $outputItem.PSIsContainer) { return Get-ValidatedWinUtilHash -Path $outputItem.FullName }

        $fileHashLines = foreach ($file in @(Get-ChildItem -LiteralPath $outputItem.FullName -File -Recurse -Force | Sort-Object FullName)) {
            $relativePath = $file.FullName.Substring($outputItem.FullName.Length).TrimStart('\', '/') -replace '\\', '/'
            '{0} *{1}' -f (Get-ValidatedWinUtilHash -Path $file.FullName), $relativePath
        }
        if (@($fileHashLines).Count -eq 0) { throw "Output directory contains no files: $($outputItem.FullName)" }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($fileHashLines -join "`n"))
        $hasher = [System.Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($hasher.ComputeHash($bytes))).Replace('-', '') } finally { $hasher.Dispose() }
    }

    try {
        $outputHash = Get-WinUtilOutputHash
        New-Item -Path $pendingDirectory -ItemType Directory -ErrorAction Stop | Out-Null
        $publishNames = @($requiredManifests.Keys) + @('ResolvedPlan.txt')
        foreach ($name in $publishNames) {
            & $CopyFile (Join-Path $ManifestDirectory $name) (Join-Path $pendingDirectory $name)
        }
        & $CopyFile $BuildLogPath (Join-Path $pendingDirectory 'WinUtil.build.log')

        $hashLines = [System.Collections.Generic.List[string]]::new()
        $outputHashName = if ($outputItem.PSIsContainer) { 'USB-CONTENT' } else { $outputItem.Name }
        $hashLines.Add("$outputHash *$outputHashName")
        foreach ($name in $publishNames + @('WinUtil.build.log')) {
            $publishedPath = Join-Path $pendingDirectory $name
            if (-not (Test-Path -LiteralPath $publishedPath -PathType Leaf)) { throw "Publication copy did not create '$name'." }
            $hashLines.Add("$(Get-ValidatedWinUtilHash -Path $publishedPath) *$name")
        }
        [System.IO.File]::WriteAllLines(
            (Join-Path $pendingDirectory 'SHA256SUMS.txt'),
            $hashLines,
            [System.Text.UTF8Encoding]::new($false)
        )
        & $PublishDirectory $pendingDirectory $evidenceDirectory
        return [pscustomobject][ordered]@{
            SchemaVersion = '1.0'
            OutputPath = $outputItem.FullName
            OutputSha256 = $outputHash
            EvidenceDirectory = $evidenceDirectory
            HashFile = Join-Path $evidenceDirectory 'SHA256SUMS.txt'
        }
    } catch {
        if (Test-Path -LiteralPath $pendingDirectory) {
            Remove-Item -LiteralPath $pendingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw "Build artifact publication failed: $_"
    }
}
