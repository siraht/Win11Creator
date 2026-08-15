function Get-WinUtilOfflineSystemSelect {
    <#
        .SYNOPSIS
        Reads the single Current control-set value from a mounted image's SYSTEM hive.
    #>
    param (
        [Parameter(Mandatory)][string]$MountedImagePath,
        [scriptblock]$InvokeRegistry = {
            param ([string[]]$ArgumentList)
            $output = @(& reg.exe @ArgumentList 2>&1)
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
        }
    )

    $systemHivePath = Join-Path $MountedImagePath 'Windows\System32\config\SYSTEM'
    if (-not (Test-Path -LiteralPath $systemHivePath -PathType Leaf)) {
        throw "Mounted SYSTEM hive was not found: $systemHivePath"
    }

    function Invoke-WinUtilCheckedRegistryCommand {
        param ([string[]]$ArgumentList, [string]$Operation)

        $result = & $InvokeRegistry -ArgumentList $ArgumentList
        if ($null -eq $result -or $null -eq $result.ExitCode) {
            throw "Registry $Operation did not return an exit code."
        }
        if ([int]$result.ExitCode -ne 0) {
            throw "Registry $Operation failed with exit code $($result.ExitCode)."
        }
        return @($result.Output)
    }

    $temporaryRoot = "HKLM\WinUtilOfflineSelect$([guid]::NewGuid().ToString('N'))"
    $loaded = $false
    try {
        Invoke-WinUtilCheckedRegistryCommand -Operation 'SYSTEM hive load' -ArgumentList @(
            'load', $temporaryRoot, $systemHivePath
        ) | Out-Null
        $loaded = $true

        $queryOutput = Invoke-WinUtilCheckedRegistryCommand -Operation 'Select Current query' -ArgumentList @(
            'query', "$temporaryRoot\Select", '/v', 'Current'
        )
        $currentValues = @($queryOutput | ForEach-Object {
            if ([string]$_ -match '^\s*Current\s+REG_DWORD\s+(0x[0-9a-fA-F]+|[0-9]+)\s*$') {
                $rawValue = $Matches[1]
                if ($rawValue.StartsWith('0x', [StringComparison]::OrdinalIgnoreCase)) {
                    [Convert]::ToInt32($rawValue.Substring(2), 16)
                } else {
                    [Convert]::ToInt32($rawValue, 10)
                }
            }
        })
        if ($currentValues.Count -ne 1 -or $currentValues[0] -lt 1 -or $currentValues[0] -gt 999) {
            throw 'Offline SYSTEM Select must contain exactly one valid Current control-set value.'
        }

        [pscustomobject][ordered]@{ Current = [int]$currentValues[0] }
    } finally {
        if ($loaded) {
            $unloadResult = & $InvokeRegistry -ArgumentList @('unload', $temporaryRoot)
            if ($null -eq $unloadResult -or [int]$unloadResult.ExitCode -ne 0) {
                throw "Registry SYSTEM hive unload failed for '$temporaryRoot'."
            }
        }
    }
}
