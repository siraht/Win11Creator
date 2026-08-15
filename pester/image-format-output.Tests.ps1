#===========================================================================
# Tests - Win11 Creator image format and FAT32 output primitives
#===========================================================================

Describe 'Win11 Creator install image detection' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $script:repoRoot 'functions/private/Get-WinUtilInstallImage.ps1')
    }

    BeforeEach {
        $script:mediaRoot = Join-Path ([IO.Path]::GetTempPath()) "WinUtilFormat_$([guid]::NewGuid().ToString('N'))"
        New-Item -Path (Join-Path $script:mediaRoot 'sources') -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:mediaRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'detects install.wim' {
        Set-Content -LiteralPath (Join-Path $script:mediaRoot 'sources/install.wim') -Value 'wim'

        $result = Get-WinUtilInstallImage -MediaRoot $script:mediaRoot

        $result.Format | Should -Be 'WIM'
        $result.Path | Should -Be (Join-Path $script:mediaRoot 'sources/install.wim')
    }

    It 'detects install.esd' {
        Set-Content -LiteralPath (Join-Path $script:mediaRoot 'sources/install.esd') -Value 'esd'

        $result = Get-WinUtilInstallImage -MediaRoot $script:mediaRoot

        $result.Format | Should -Be 'ESD'
        $result.Path | Should -Be (Join-Path $script:mediaRoot 'sources/install.esd')
    }

    It 'fails closed when both formats or neither format exists' {
        { Get-WinUtilInstallImage -MediaRoot $script:mediaRoot } | Should -Throw '*neither*'

        Set-Content -LiteralPath (Join-Path $script:mediaRoot 'sources/install.wim') -Value 'wim'
        Set-Content -LiteralPath (Join-Path $script:mediaRoot 'sources/install.esd') -Value 'esd'
        { Get-WinUtilInstallImage -MediaRoot $script:mediaRoot } | Should -Throw '*both*'
    }
}

Describe 'Win11 Creator selected ESD export' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $script:repoRoot 'functions/private/Get-WinUtilInstallImage.ps1')
    }

    BeforeEach {
        $script:exportRoot = Join-Path ([IO.Path]::GetTempPath()) "WinUtilEsdExport_$([guid]::NewGuid().ToString('N'))"
        New-Item -Path $script:exportRoot -ItemType Directory -Force | Out-Null
        $script:sourceEsd = Join-Path $script:exportRoot 'install.esd'
        $script:destinationWim = Join-Path $script:exportRoot 'install.wim'
        Set-Content -LiteralPath $script:sourceEsd -Value 'immutable source esd'
        $script:dismCalls = [System.Collections.Generic.List[object]]::new()
    }

    AfterEach {
        Remove-Item -LiteralPath $script:exportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'exports the selected index with exact DISM arguments and validates single-index metadata' {
        $invokeDism = {
            param([string[]]$ArgumentList)
            $script:dismCalls.Add(@($ArgumentList))
            $wimArgument = $ArgumentList | Where-Object { $_ -like '/WimFile:*' } | Select-Object -First 1
            $isTemporaryWim = $wimArgument -like '*.winutil-export-*.wim'

            if ($ArgumentList -contains '/Export-Image') {
                $destinationArgument = $ArgumentList | Where-Object { $_ -like '/DestinationImageFile:*' }
                Set-Content -LiteralPath ($destinationArgument -replace '^/DestinationImageFile:', '') -Value 'exported wim'
                return [pscustomobject]@{ ExitCode = 0; Output = @('Export completed') }
            }
            if (-not ($ArgumentList | Where-Object { $_ -like '/Index:*' })) {
                $indexes = if ($isTemporaryWim) { @('Index : 1') } else { @('Index : 1', 'Index : 2', 'Index : 6') }
                return [pscustomobject]@{ ExitCode = 0; Output = $indexes }
            }
            return [pscustomobject]@{ ExitCode = 0; Output = @(
                'Name : Windows 11 Pro', 'Description : Windows 11 Pro', 'Edition : Professional',
                'Installation : Client', 'Architecture : x64'
            ) }
        }

        $result = Export-WinUtilEsdImageToWim `
            -SourceImagePath $script:sourceEsd `
            -SourceImageIndex 6 `
            -DestinationImagePath $script:destinationWim `
            -InvokeDism $invokeDism

        $result.DestinationIndex | Should -Be 1
        $result.Edition | Should -Be 'Professional'
        Test-Path -LiteralPath $script:sourceEsd | Should -BeTrue
        Get-Content -LiteralPath $script:sourceEsd -Raw | Should -Match 'immutable source esd'
        Test-Path -LiteralPath $script:destinationWim | Should -BeTrue

        $exportCall = @($script:dismCalls | Where-Object { $_ -contains '/Export-Image' })[0]
        $exportCall | Should -Contain '/English'
        $exportCall | Should -Contain '/Export-Image'
        $exportCall | Should -Contain "/SourceImageFile:$script:sourceEsd"
        $exportCall | Should -Contain '/SourceIndex:6'
        $exportCall | Should -Contain '/Compress:max'
        $exportCall | Should -Contain '/CheckIntegrity'
        ($exportCall | Where-Object { $_ -like '/DestinationImageFile:*.winutil-export-*.wim' }).Count | Should -Be 1
    }

    It 'rejects an out-of-bounds selected index before export' {
        $invokeDism = {
            param([string[]]$ArgumentList)
            $script:dismCalls.Add(@($ArgumentList))
            [pscustomobject]@{ ExitCode = 0; Output = @('Index : 1', 'Index : 2') }
        }

        { Export-WinUtilEsdImageToWim -SourceImagePath $script:sourceEsd -SourceImageIndex 6 -DestinationImagePath $script:destinationWim -InvokeDism $invokeDism } |
            Should -Throw '*outside available indexes: 1, 2*'

        @($script:dismCalls | Where-Object { $_ -contains '/Export-Image' }).Count | Should -Be 0
        Test-Path -LiteralPath $script:destinationWim | Should -BeFalse
    }

    It 'plants an export failure and removes partial output without changing the source' {
        $sourceBefore = Get-Content -LiteralPath $script:sourceEsd -Raw
        $invokeDism = {
            param([string[]]$ArgumentList)
            if ($ArgumentList -contains '/Export-Image') {
                $destinationArgument = $ArgumentList | Where-Object { $_ -like '/DestinationImageFile:*' }
                Set-Content -LiteralPath ($destinationArgument -replace '^/DestinationImageFile:', '') -Value 'partial'
                return [pscustomobject]@{ ExitCode = 87; Output = @('export failed') }
            }
            if (-not ($ArgumentList | Where-Object { $_ -like '/Index:*' })) {
                return [pscustomobject]@{ ExitCode = 0; Output = @('Index : 1', 'Index : 6') }
            }
            return [pscustomobject]@{ ExitCode = 0; Output = @('Name : Windows 11 Pro', 'Edition : Professional') }
        }

        { Export-WinUtilEsdImageToWim -SourceImagePath $script:sourceEsd -SourceImageIndex 6 -DestinationImagePath $script:destinationWim -InvokeDism $invokeDism } |
            Should -Throw '*ESD export failed with exit code 87*'

        Test-Path -LiteralPath $script:destinationWim | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:exportRoot -Filter '.winutil-export-*.wim').Count | Should -Be 0
        Get-Content -LiteralPath $script:sourceEsd -Raw | Should -Be $sourceBefore
    }

    It 'rejects changed edition metadata and removes the invalid export' {
        $invokeDism = {
            param([string[]]$ArgumentList)
            $wimArgument = $ArgumentList | Where-Object { $_ -like '/WimFile:*' } | Select-Object -First 1
            $isTemporaryWim = $wimArgument -like '*.winutil-export-*.wim'
            if ($ArgumentList -contains '/Export-Image') {
                $destinationArgument = $ArgumentList | Where-Object { $_ -like '/DestinationImageFile:*' }
                Set-Content -LiteralPath ($destinationArgument -replace '^/DestinationImageFile:', '') -Value 'exported'
                return [pscustomobject]@{ ExitCode = 0; Output = @() }
            }
            if (-not ($ArgumentList | Where-Object { $_ -like '/Index:*' })) {
                return [pscustomobject]@{ ExitCode = 0; Output = if ($isTemporaryWim) { @('Index : 1') } else { @('Index : 6') } }
            }
            $edition = if ($isTemporaryWim) { 'Core' } else { 'Professional' }
            return [pscustomobject]@{ ExitCode = 0; Output = @('Name : Windows 11 Pro', "Edition : $edition") }
        }

        { Export-WinUtilEsdImageToWim -SourceImagePath $script:sourceEsd -SourceImageIndex 6 -DestinationImagePath $script:destinationWim -InvokeDism $invokeDism } |
            Should -Throw '*metadata mismatch for Edition*'
        Test-Path -LiteralPath $script:destinationWim | Should -BeFalse
    }
}

Describe 'Win11 Creator FAT32 WIM preparation' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $script:repoRoot 'functions/private/Prepare-WinUtilFat32Image.ps1')
    }

    BeforeEach {
        $script:fatRoot = Join-Path ([IO.Path]::GetTempPath()) "WinUtilFat32_$([guid]::NewGuid().ToString('N'))"
        $script:destinationRoot = Join-Path $script:fatRoot 'usb/sources'
        New-Item -Path $script:fatRoot -ItemType Directory -Force | Out-Null
        $script:installWim = Join-Path $script:fatRoot 'install.wim'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:fatRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'preserves the existing copy path below the split threshold' {
        Set-Content -LiteralPath $script:installWim -Value 'small wim'
        $invokeSplit = { throw 'split must not run for a small WIM' }

        $result = Prepare-WinUtilFat32Image -ImagePath $script:installWim -DestinationDirectory $script:destinationRoot -SplitThresholdBytes 1MB -InvokeSplit $invokeSplit

        $result.Mode | Should -Be 'Copy'
        $result.ExcludeSourceImage | Should -BeFalse
        $result.SourcePath | Should -Be $script:installWim
        Test-Path -LiteralPath $script:installWim | Should -BeTrue
    }

    It 'splits an oversized WIM into deterministically ordered SWM segments' {
        [IO.File]::WriteAllBytes($script:installWim, [byte[]](1..32))
        $script:splitArguments = $null
        $invokeSplit = {
            param($sourcePath, $splitPath, $fileSizeMB)
            $script:splitArguments = @($sourcePath, $splitPath, $fileSizeMB)
            Set-Content -LiteralPath $splitPath -Value 'segment one'
            Set-Content -LiteralPath (Join-Path (Split-Path $splitPath -Parent) 'install2.swm') -Value 'segment two'
        }

        $result = Prepare-WinUtilFat32Image -ImagePath $script:installWim -DestinationDirectory $script:destinationRoot -SplitThresholdBytes 16 -SplitSizeMB 3800 -InvokeSplit $invokeSplit

        $result.Mode | Should -Be 'Split'
        $result.ExcludeSourceImage | Should -BeTrue
        @($result.Segments | ForEach-Object { Split-Path $_ -Leaf }) | Should -Be @('install.swm', 'install2.swm')
        $script:splitArguments | Should -Be @($script:installWim, (Join-Path $script:destinationRoot 'install.swm'), 3800)
        Test-Path -LiteralPath $script:installWim | Should -BeTrue
    }

    It 'plants a split failure and removes stale and partial segments' {
        [IO.File]::WriteAllBytes($script:installWim, [byte[]](1..32))
        New-Item -Path $script:destinationRoot -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:destinationRoot 'install9.swm') -Value 'stale'
        $invokeSplit = {
            param($sourcePath, $splitPath, $fileSizeMB)
            $null = $sourcePath, $fileSizeMB
            Set-Content -LiteralPath $splitPath -Value 'partial'
            throw 'injected split failure'
        }

        { Prepare-WinUtilFat32Image -ImagePath $script:installWim -DestinationDirectory $script:destinationRoot -SplitThresholdBytes 16 -InvokeSplit $invokeSplit } |
            Should -Throw '*injected split failure*'

        @(Get-ChildItem -LiteralPath $script:destinationRoot -Filter 'install*.swm').Count | Should -Be 0
        Test-Path -LiteralPath $script:installWim | Should -BeTrue
    }

    It 'fails when the split boundary reports success without install.swm' {
        [IO.File]::WriteAllBytes($script:installWim, [byte[]](1..32))
        $invokeSplit = { param($sourcePath, $splitPath, $fileSizeMB); $null = $sourcePath, $splitPath, $fileSizeMB }

        { Prepare-WinUtilFat32Image -ImagePath $script:installWim -DestinationDirectory $script:destinationRoot -SplitThresholdBytes 16 -InvokeSplit $invokeSplit } |
            Should -Throw '*did not create install.swm*'
    }
}
