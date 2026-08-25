BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:repoRoot 'tools/Invoke-WinUtilIsoRepair.ps1')

    function New-IsoRepairFixture {
        param ([switch]$NotApplicable, [switch]$WithProductKey, [int]$OscdimgExitCode = 0)

        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $media = Join-Path $root 'mounted-media'
        $sourceIso = Join-Path $root 'source.iso'
        $outputIso = Join-Path $root 'repaired.iso'
        $work = Join-Path $root 'work'
        $oscdimg = Join-Path $root 'oscdimg.exe'
        New-Item -Path (Join-Path $media 'sources') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $media 'boot') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $media 'efi/microsoft/boot') -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $media 'boot/etfsboot.com') -Value 'bios boot image'
        Set-Content -LiteralPath (Join-Path $media 'efi/microsoft/boot/efisys.bin') -Value 'uefi boot image'
        Set-Content -LiteralPath (Join-Path $media 'sources/install.wim') -Value 'customized Windows image that must remain byte-for-byte untouched'
        Set-Content -LiteralPath $sourceIso -Value 'source ISO fixture'
        Set-Content -LiteralPath $oscdimg -Value 'oscdimg fixture'
        if (-not $NotApplicable) {
            Set-Content -LiteralPath (Join-Path $media 'sources/ei.cfg') -Encoding ASCII -Value "[EditionID]`r`nEnterpriseEval`r`n[Channel]`r`nRetail`r`n[VL]`r`n0"
            Set-Content -LiteralPath (Join-Path $media 'sources/PID.txt') -Value 'stale product key'
        }
        $productKeyXml = if ($WithProductKey) { '<ProductKey><Key>AAAAA-BBBBB-CCCCC-DDDDD-EEEEE</Key></ProductKey>' } else { '' }
        $answer = @"
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE"><component name="Microsoft-Windows-Setup">$productKeyXml<ImageInstall><OSImage><InstallFrom>
    <MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData>
  </InstallFrom></OSImage></ImageInstall></component></settings>
</unattend>
"@
        Set-Content -LiteralPath (Join-Path $media 'autounattend.xml') -Value $answer -Encoding UTF8

        $state = [pscustomobject]@{ Mounts = 0; Dismounts = 0; Copies = 0; Creates = 0; OscdimgArguments = @(); CopiedMedia = '' }
        $provider = @{
            MountIso = { param($path) $state.Mounts++; $media }.GetNewClosure()
            DismountIso = { param($path) $state.Dismounts++ }.GetNewClosure()
            CopyMedia = {
                param($source, $destination)
                $state.Copies++
                $state.CopiedMedia = $destination
                Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force
            }.GetNewClosure()
            CreateIso = {
                param($executable, $arguments)
                $state.Creates++
                $state.OscdimgArguments = @($arguments)
                if ($OscdimgExitCode -eq 0) { Set-Content -LiteralPath $arguments[-1] -Value 'repaired ISO fixture' }
                [pscustomobject]@{ ExitCode = $OscdimgExitCode; Output = @('oscdimg repair fixture') }
            }.GetNewClosure()
        }
        [pscustomobject]@{ Root = $root; Media = $media; SourceIso = $sourceIso; OutputIso = $outputIso; Work = $work; Oscdimg = $oscdimg; Provider = $provider; State = $state }
    }
}

Describe 'Extensible ISO repair definitions' {
    It 'declares the current repair through one data-driven definition' {
        $definitions = @(Get-WinUtilIsoRepairDefinition)

        $definitions | Should -HaveCount 1
        $definitions[0].Id | Should -Be 'evaluation-product-key'
        $definitions[0].Test | Should -BeOfType ([scriptblock])
        $definitions[0].Apply | Should -BeOfType ([scriptblock])
    }

    It 'keeps the shared repair engine independent of Windows image servicing' {
        $repairEngine = Get-Content -LiteralPath (Join-Path $script:repoRoot 'tools/Invoke-WinUtilIsoRepair.ps1') -Raw

        $repairEngine | Should -Not -Match 'Mount-WindowsImage|Dismount-WindowsImage|dism\.exe|install\.wim'
    }
}

Describe 'ISO repair orchestration' {
    It 'repairs and repackages Evaluation media without servicing its Windows image' {
        $fixture = New-IsoRepairFixture

        $result = Invoke-WinUtilIsoRepair -SourceIsoPath $fixture.SourceIso -OutputIsoPath $fixture.OutputIso `
            -WorkDirectory $fixture.Work -OscdimgPath $fixture.Oscdimg -RepairId evaluation-product-key `
            -RemoveWorkDirectoryOnSuccess -RepairProvider $fixture.Provider

        $result.AppliedRepairIds | Should -Be @('evaluation-product-key')
        Test-Path -LiteralPath $result.OutputIsoPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $fixture.Work | Should -BeFalse
        $fixture.State.Mounts | Should -Be 1
        $fixture.State.Dismounts | Should -Be 1
        $fixture.State.Copies | Should -Be 1
        $fixture.State.Creates | Should -Be 1
        $fixture.State.OscdimgArguments | Should -Contain '-lCTOS_REPAIRED'
        ($fixture.State.OscdimgArguments -join '|') | Should -Match 'etfsboot\.com'
        ($fixture.State.OscdimgArguments -join '|') | Should -Match 'efisys\.bin'
        Test-Path -LiteralPath (Join-Path $fixture.Media 'sources/ei.cfg') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixture.Media 'sources/PID.txt') -PathType Leaf | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $fixture.Media 'sources/install.wim') -Raw).Trim() | Should -Be 'customized Windows image that must remain byte-for-byte untouched'
    }

    It 'rejects a non-applicable ISO instead of performing a pointless repack' {
        $fixture = New-IsoRepairFixture -NotApplicable

        { Invoke-WinUtilIsoRepair -SourceIsoPath $fixture.SourceIso -OutputIsoPath $fixture.OutputIso `
            -WorkDirectory $fixture.Work -OscdimgPath $fixture.Oscdimg -RepairId evaluation-product-key `
            -RepairProvider $fixture.Provider } | Should -Throw '*is not applicable*no output was created*'

        $fixture.State.Creates | Should -Be 0
        Test-Path -LiteralPath $fixture.OutputIso | Should -BeFalse
        Test-Path -LiteralPath $fixture.Work | Should -BeFalse
    }

    It 'rejects an answer file containing a product key without altering it' {
        $fixture = New-IsoRepairFixture -WithProductKey

        { Invoke-WinUtilIsoRepair -SourceIsoPath $fixture.SourceIso -OutputIsoPath $fixture.OutputIso `
            -WorkDirectory $fixture.Work -OscdimgPath $fixture.Oscdimg -RepairId evaluation-product-key `
            -RepairProvider $fixture.Provider } | Should -Throw '*contains a product key*will not silently remove*'

        $fixture.State.Creates | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $fixture.Media 'autounattend.xml') -Raw) | Should -Match 'AAAAA-BBBBB'
    }

    It 'cleans partial output and owned work after packaging failure' {
        $fixture = New-IsoRepairFixture -OscdimgExitCode 17

        { Invoke-WinUtilIsoRepair -SourceIsoPath $fixture.SourceIso -OutputIsoPath $fixture.OutputIso `
            -WorkDirectory $fixture.Work -OscdimgPath $fixture.Oscdimg -RepairId evaluation-product-key `
            -RepairProvider $fixture.Provider } | Should -Throw '*oscdimg failed with exit code 17*'

        Test-Path -LiteralPath $fixture.OutputIso | Should -BeFalse
        Test-Path -LiteralPath $fixture.Work | Should -BeFalse
        $fixture.State.Dismounts | Should -Be 1
    }

    It 'rejects unknown and duplicate repair IDs before mounting media' {
        $unknown = New-IsoRepairFixture
        { Invoke-WinUtilIsoRepair -SourceIsoPath $unknown.SourceIso -OutputIsoPath $unknown.OutputIso `
            -WorkDirectory $unknown.Work -OscdimgPath $unknown.Oscdimg -RepairId future-unknown `
            -RepairProvider $unknown.Provider } | Should -Throw "*Unknown ISO repair 'future-unknown'*"
        $unknown.State.Mounts | Should -Be 0

        $duplicate = New-IsoRepairFixture
        { Invoke-WinUtilIsoRepair -SourceIsoPath $duplicate.SourceIso -OutputIsoPath $duplicate.OutputIso `
            -WorkDirectory $duplicate.Work -OscdimgPath $duplicate.Oscdimg -RepairId @('evaluation-product-key', 'evaluation-product-key') `
            -RepairProvider $duplicate.Provider } | Should -Throw '*selected more than once*'
        $duplicate.State.Mounts | Should -Be 0
    }
}
