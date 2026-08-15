BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    . (Join-Path $repoRoot 'functions/private/Get-WinUtilOfflineSystemSelect.ps1')
}

Describe 'Offline SYSTEM control-set discovery' {
    BeforeEach {
        $script:mountRoot = Join-Path ([IO.Path]::GetTempPath()) "WinUtilSystemSelect_$([guid]::NewGuid().ToString('N'))"
        $systemHive = Join-Path $script:mountRoot 'Windows/System32/config/SYSTEM'
        New-Item -Path (Split-Path $systemHive -Parent) -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath $systemHive -Value 'fixture'
        $script:registryCalls = [System.Collections.Generic.List[object]]::new()
    }

    AfterEach {
        Remove-Item -LiteralPath $script:mountRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'loads, reads, and unloads the exact mounted SYSTEM hive' {
        $invokeRegistry = {
            param ([string[]]$ArgumentList)
            $script:registryCalls.Add(@($ArgumentList))
            if ($ArgumentList[0] -eq 'query') {
                return [pscustomobject]@{ ExitCode = 0; Output = @('    Current    REG_DWORD    0x2') }
            }
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }

        $result = Get-WinUtilOfflineSystemSelect -MountedImagePath $script:mountRoot -InvokeRegistry $invokeRegistry

        $result.Current | Should -Be 2
        $script:registryCalls.Count | Should -Be 3
        $script:registryCalls[0][0] | Should -Be 'load'
        $script:registryCalls[0][2] | Should -Be (Join-Path $script:mountRoot 'Windows/System32/config/SYSTEM')
        $script:registryCalls[1] | Should -Contain 'Current'
        $script:registryCalls[2][0] | Should -Be 'unload'
        $script:registryCalls[2][1] | Should -Be $script:registryCalls[0][1]
    }

    It 'plants an ambiguous Current value and still unloads the hive' {
        $invokeRegistry = {
            param ([string[]]$ArgumentList)
            $script:registryCalls.Add(@($ArgumentList))
            if ($ArgumentList[0] -eq 'query') {
                return [pscustomobject]@{ ExitCode = 0; Output = @(
                    '    Current    REG_DWORD    0x1',
                    '    Current    REG_DWORD    0x2'
                ) }
            }
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }

        { Get-WinUtilOfflineSystemSelect -MountedImagePath $script:mountRoot -InvokeRegistry $invokeRegistry } |
            Should -Throw '*exactly one valid Current*'
        $script:registryCalls[-1][0] | Should -Be 'unload'
    }

    It 'plants a query failure and still unloads the hive' {
        $invokeRegistry = {
            param ([string[]]$ArgumentList)
            $script:registryCalls.Add(@($ArgumentList))
            if ($ArgumentList[0] -eq 'query') {
                return [pscustomobject]@{ ExitCode = 2; Output = @('not found') }
            }
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }

        { Get-WinUtilOfflineSystemSelect -MountedImagePath $script:mountRoot -InvokeRegistry $invokeRegistry } |
            Should -Throw '*query failed with exit code 2*'
        $script:registryCalls[-1][0] | Should -Be 'unload'
    }

    It 'fails before loading when the mounted SYSTEM hive is absent' {
        Remove-Item -LiteralPath (Join-Path $script:mountRoot 'Windows/System32/config/SYSTEM') -Force
        $invokeRegistry = { throw 'must not run' }

        { Get-WinUtilOfflineSystemSelect -MountedImagePath $script:mountRoot -InvokeRegistry $invokeRegistry } |
            Should -Throw '*Mounted SYSTEM hive was not found*'
    }
}
