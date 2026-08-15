Describe 'Checked robocopy boundary' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $script:repoRoot 'functions/private/Invoke-WinUtilRobocopy.ps1')
        $script:usbSource = Get-Content -LiteralPath (Join-Path $script:repoRoot 'functions/private/Invoke-WinUtilISOUSB.ps1') -Raw
    }

    It 'accepts documented nonfatal robocopy exit codes and preserves exact exclusions' {
        $runner = {
            param($argumentList)
            [pscustomobject]@{ ExitCode = 3; Output = @('copied with extras'); ArgumentsSeen = $argumentList }
        }

        $result = Invoke-WinUtilRobocopy -Source 'source' -Destination 'target' -ExcludeFile 'install.wim' -RunRobocopy $runner

        $result.ExitCode | Should -Be 3
        $result.Arguments | Should -Be @('source', 'target', '/E', '/XF', 'install.wim', '/NFL', '/NDL', '/NJH', '/NJS')
    }

    It 'plants the negative that a fatal copy result cannot reach publication' {
        $runner = { param($argumentList) $null = $argumentList; [pscustomobject]@{ ExitCode = 8; Output = @('access denied') } }
        { Invoke-WinUtilRobocopy -Source 'source' -Destination 'target' -RunRobocopy $runner } |
            Should -Throw '*failed with exit code 8*access denied*'
    }

    It 'rejects a copy boundary without a valid exit code' {
        $missing = { param($argumentList) $null = $argumentList; [pscustomobject]@{ Output = @() } }
        $malformed = { param($argumentList) $null = $argumentList; [pscustomobject]@{ ExitCode = 'success'; Output = @() } }

        { Invoke-WinUtilRobocopy -Source 'source' -Destination 'target' -RunRobocopy $missing } | Should -Throw '*did not return an exit code*'
        { Invoke-WinUtilRobocopy -Source 'source' -Destination 'target' -RunRobocopy $malformed } | Should -Throw '*invalid exit code*'
    }

    It 'injects and uses the checked boundary before build publication' {
        $script:usbSource | Should -Match '\$\{function:Invoke-WinUtilRobocopy\}\.ToString\(\)'
        $copy = $script:usbSource.IndexOf('Invoke-WinUtilRobocopy -Source $contentsDir')
        $publish = $script:usbSource.IndexOf('Publish-WinUtilBuildArtifact -OutputPath $usbDrive', $copy)

        $copy | Should -BeGreaterThan -1
        $publish | Should -BeGreaterThan $copy
        $script:usbSource | Should -Not -Match '& robocopy'
    }
}
