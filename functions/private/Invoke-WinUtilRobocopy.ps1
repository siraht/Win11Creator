function Invoke-WinUtilRobocopy {
    param (
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [AllowEmptyCollection()][string[]]$ExcludeFile = @(),
        [scriptblock]$RunRobocopy = {
            param([string[]]$ArgumentList)
            $commandOutput = @(& robocopy @ArgumentList 2>&1)
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($commandOutput) }
        }
    )

    $argumentList = @($Source, $Destination, '/E')
    if ($ExcludeFile.Count -gt 0) {
        $argumentList += '/XF'
        $argumentList += @($ExcludeFile)
    }
    $argumentList += @('/NFL', '/NDL', '/NJH', '/NJS')

    $result = & $RunRobocopy $argumentList
    if ($null -eq $result -or $null -eq $result.PSObject.Properties['ExitCode']) {
        throw 'Robocopy did not return an exit code.'
    }
    $exitCode = 0
    if (-not [int]::TryParse([string]$result.ExitCode, [ref]$exitCode) -or $exitCode -lt 0) {
        throw "Robocopy returned an invalid exit code '$($result.ExitCode)'."
    }
    if ($exitCode -ge 8) {
        $detail = (@($result.Output | Select-Object -Last 20) -join [Environment]::NewLine).Trim()
        throw "Robocopy failed with exit code $exitCode. $detail".Trim()
    }

    [pscustomobject][ordered]@{
        ExitCode = $exitCode
        Output = @($result.Output)
        Arguments = @($argumentList)
    }
}
