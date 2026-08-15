function Test-WinUtilWindowsImageSupport {
    param (
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ImageMetadata
    )

    $editions = @($ImageMetadata)
    if ($editions.Count -eq 0) {
        return [pscustomobject]@{ IsSupported = $false; Reason = 'The install image did not expose any selectable editions.'; Editions = @() }
    }

    $seenIndexes = @{}
    foreach ($edition in $editions) {
        $index = 0
        if (-not [int]::TryParse([string]$edition.ImageIndex, [ref]$index) -or $index -lt 1) {
            return [pscustomobject]@{ IsSupported = $false; Reason = 'An edition has missing or invalid image-index metadata.'; Editions = $editions }
        }
        if ($seenIndexes.ContainsKey($index)) {
            return [pscustomobject]@{ IsSupported = $false; Reason = "Image index $index is ambiguous because it appears more than once."; Editions = $editions }
        }
        $seenIndexes[$index] = $true

        $name = [string]$edition.ImageName
        if ([string]::IsNullOrWhiteSpace($name)) {
            return [pscustomobject]@{ IsSupported = $false; Reason = "Image index $index is missing its edition name."; Editions = $editions }
        }
        if ($name -notmatch '^Windows 11(?:\s|$)') {
            return [pscustomobject]@{ IsSupported = $false; Reason = "Image index $index ('$name') is not an official-looking Windows 11 edition."; Editions = $editions }
        }

        $architecture = ([string]$edition.Architecture).Trim().ToLowerInvariant()
        if ($architecture -notin @('9', 'amd64', 'x64')) {
            $displayArchitecture = if ($architecture) { $edition.Architecture } else { 'missing' }
            return [pscustomobject]@{ IsSupported = $false; Reason = "Image index $index has unsupported architecture '$displayArchitecture'; x64 is required."; Editions = $editions }
        }

        $version = $null
        if (-not [version]::TryParse([string]$edition.Version, [ref]$version)) {
            return [pscustomobject]@{ IsSupported = $false; Reason = "Image index $index has missing or invalid version metadata."; Editions = $editions }
        }
        if ($version.Build -ne 26200) {
            return [pscustomobject]@{ IsSupported = $false; Reason = "Image index $index is build $($version.Build); only Windows 11 25H2 build family 26200 is supported."; Editions = $editions }
        }
    }

    [pscustomobject]@{
        IsSupported = $true
        Reason = "All $($editions.Count) selectable editions are Windows 11 x64 25H2 build family 26200."
        Editions = $editions
    }
}
