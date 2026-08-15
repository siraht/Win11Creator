Describe 'Windows image v1 support boundary' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\functions\private\Test-WinUtilWindowsImageSupport.ps1')
        function New-TestEdition {
            param($Index = 1, $Name = 'Windows 11 Pro', $Architecture = 'x64', $Version = '10.0.26200.1000')
            [pscustomobject]@{
                ImageIndex = $Index
                ImageName = $Name
                Architecture = $Architecture
                Version = $Version
                EditionId = 'Professional'
                InstallationType = 'Client'
            }
        }
    }

    It 'accepts every selectable Windows 11 x64 build 26200 edition and retains metadata' {
        $input = @(New-TestEdition -Index 1 -Name 'Windows 11 Home'; New-TestEdition -Index 6 -Name 'Windows 11 Pro' -Architecture 9)
        $result = Test-WinUtilWindowsImageSupport -ImageMetadata $input
        $result.IsSupported | Should -BeTrue
        $result.Editions.Count | Should -Be 2
        $result.Editions[1].EditionId | Should -Be 'Professional'
    }

    It 'rejects Windows 10, ARM64, x86, other releases, missing metadata, and ambiguous indexes' {
        $cases = @(
            @{ Editions = @(New-TestEdition -Name 'Windows 10 Pro'); Message = '*not an official-looking Windows 11*' }
            @{ Editions = @(New-TestEdition -Architecture 'ARM64'); Message = '*x64 is required*' }
            @{ Editions = @(New-TestEdition -Architecture 'x86'); Message = '*x64 is required*' }
            @{ Editions = @(New-TestEdition -Version '10.0.26100.1'); Message = '*only Windows 11 25H2*' }
            @{ Editions = @(New-TestEdition -Version ''); Message = '*missing or invalid version*' }
            @{ Editions = @(New-TestEdition -Name ''); Message = '*missing its edition name*' }
            @{ Editions = @(New-TestEdition -Index 1; New-TestEdition -Index 1 -Name 'Windows 11 Home'); Message = '*ambiguous*' }
        )
        foreach ($case in $cases) {
            $result = Test-WinUtilWindowsImageSupport -ImageMetadata $case.Editions
            $result.IsSupported | Should -BeFalse
            $result.Reason | Should -BeLike $case.Message
        }
    }

    It 'rejects the whole image when any selectable edition is unsupported' {
        $result = Test-WinUtilWindowsImageSupport -ImageMetadata @(
            New-TestEdition -Index 1
            New-TestEdition -Index 2 -Architecture ARM64
        )
        $result.IsSupported | Should -BeFalse
        $result.Reason | Should -Match 'index 2'
    }

    It 'wires mount verification and Analyze to the support result' {
        $source = Get-Content (Join-Path $PSScriptRoot '..\functions\private\Invoke-WinUtilISO.ps1') -Raw
        $source | Should -Match 'Test-WinUtilWindowsImageSupport -ImageMetadata \$imageInfo'
        $source | Should -Match 'Get-WinUtilInstallImage -MediaRoot \$driveLetter'
        $source | Should -Match '\$support\.Editions'
        $source | Should -Match ([regex]::Escape("`$sync['Win11ISOImageSupport'].IsSupported -ne `$true"))
        $source | Should -Match 'Use an official Windows 11 x64 25H2 ISO'
        $source | Should -Match 'Timed out waiting for the mounted ISO'
        $source | Should -Match '(?s)catch \{.*Dismount-DiskImage -ImagePath \$isoPath'
    }
}
