BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:repoRoot 'tools/Invoke-WinUtilWindowsBuild.ps1')

    function New-NonInteractiveBuildFixture {
        param ([string]$Format = 'WIM', [int]$OscdimgExitCode = 0, [switch]$EmptyOutput, [int]$Build = 26200)

        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $media = Join-Path $root 'mounted-media'
        $sourceIso = Join-Path $root 'official.iso'
        $outputIso = Join-Path $root 'output.iso'
        $work = Join-Path $root 'work'
        $oscdimg = Join-Path $root 'oscdimg.exe'
        New-Item -Path (Join-Path $media 'sources') -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath $sourceIso -Value 'official ISO fixture'
        Set-Content -LiteralPath $oscdimg -Value 'oscdimg fixture'
        Set-Content -LiteralPath (Join-Path $media "sources/install.$($Format.ToLowerInvariant())") -Value 'install image fixture'
        $state = [pscustomobject]@{ Mounts = 0; Dismounts = 0; Sessions = 0; Exports = 0; PrepareArguments = $null; OscdimgArguments = @() }
        $session = [pscustomobject]@{
            State = 'Mounted'; MountPath = (Join-Path $work 'wim_mount'); InstallImagePath = ''; ImageIndex = 6; ImageName = 'Windows 11 Pro'
            Inventory = [pscustomobject]@{
                SchemaVersion = '1.0'
                Source = [pscustomobject]@{ ImagePath = 'install.wim'; ImageIndex = 6; ImageName = 'Windows 11 Pro'; MountedImagePath = 'mount' }
                Items = @(
                    [pscustomobject]@{ Kind = 'Feature'; Name = 'Windows-Defender-Feature'; Identity = 'Windows-Defender-Feature'; State = 'Enabled' }
                    [pscustomobject]@{ Kind = 'Package'; Name = 'Microsoft-Windows-Windows-Defender-Package'; Identity = 'Microsoft-Windows-Windows-Defender-Package~31bf~amd64~~10.0.26200.1'; State = 'Installed' }
                )
            }
        }
        $provider = @{
            MountIso = { param($path) $state.Mounts++; $media }.GetNewClosure()
            DismountIso = { param($path) $state.Dismounts++ }.GetNewClosure()
            GetImageMetadata = {
                param($path)
                @([pscustomobject]@{ ImageIndex = 6; ImageName = 'Windows 11 Pro'; Architecture = 9; Version = "10.0.$Build.1" })
            }.GetNewClosure()
            CopyMedia = {
                param($source, $destination)
                Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force
            }
            ExportEsd = {
                param($source, $index, $destination)
                $state.Exports++
                Set-Content -LiteralPath $destination -Value 'validated WIM fixture'
                [pscustomobject]@{ DestinationPath = $destination; DestinationIndex = 1; Name = 'Windows 11 Pro' }
            }.GetNewClosure()
            StartSession = {
                param($image, $index, $name, $mount, $log)
                $state.Sessions++
                $session.InstallImagePath = $image; $session.ImageIndex = $index; $session.MountPath = $mount
                $session.Inventory.Source.ImagePath = $image; $session.Inventory.Source.ImageIndex = $index
                $session
            }.GetNewClosure()
            StopSession = { param($value) $value.State = 'Discarded' }
            GetSystemSelect = { param($mount) [pscustomobject]@{ Current = 1 } }
            PrepareMedia = {
                param($arguments)
                $state.PrepareArguments = $arguments
                $session.State = 'Committed'
                New-Item -Path $arguments.ManifestDirectory -ItemType Directory -Force | Out-Null
            }.GetNewClosure()
            CreateIso = {
                param($executable, $arguments)
                $state.OscdimgArguments = @($arguments)
                if (-not $EmptyOutput) { Set-Content -LiteralPath $arguments[-1] -Value 'built ISO fixture' }
                [pscustomobject]@{ ExitCode = $OscdimgExitCode; Output = @('oscdimg fixture output') }
            }.GetNewClosure()
            PublishArtifact = {
                param($output, $manifests, $log)
                $evidence = Join-Path (Split-Path $output -Parent) 'output.WinUtil-build'
                New-Item -Path $evidence -ItemType Directory | Out-Null
                [pscustomobject]@{ EvidenceDirectory = $evidence }
            }
        }
        [pscustomobject]@{ Root = $root; SourceIso = $sourceIso; OutputIso = $outputIso; Work = $work; Oscdimg = $oscdimg; Provider = $provider; State = $state; Session = $session }
    }
}

Describe 'Noninteractive Windows ISO build orchestration' {
    It 'builds the default profile through one analyzed servicing session and canonical handoff' {
        $fixture = New-NonInteractiveBuildFixture

        $result = Invoke-WinUtilWindowsBuild -SourceIsoPath $fixture.SourceIso -ImageIndex 6 -Profile default-winutil `
            -OutputIsoPath $fixture.OutputIso -WorkDirectory $fixture.Work -OscdimgPath $fixture.Oscdimg -BuildProvider $fixture.Provider

        $result.Profile | Should -Be 'default-winutil'
        $fixture.State.Mounts | Should -Be 1
        $fixture.State.Dismounts | Should -Be 1
        $fixture.State.Sessions | Should -Be 1
        $fixture.Session.State | Should -Be 'Committed'
        $fixture.State.PrepareArguments.ResolvedPlan.SchemaVersion | Should -Be '1.0'
        $fixture.State.PrepareArguments.ActionBundle.IsReady | Should -BeTrue
        [object]::ReferenceEquals($fixture.State.PrepareArguments.OfflineServicingSession, $fixture.Session) | Should -BeTrue
        $fixture.State.OscdimgArguments | Should -Contain '-lCTOS_MODIFIED'
        Test-Path -LiteralPath $result.EvidenceDirectory -PathType Container | Should -BeTrue
    }

    It 'exports one selected ESD index before the single servicing session' {
        $fixture = New-NonInteractiveBuildFixture -Format ESD

        Invoke-WinUtilWindowsBuild -SourceIsoPath $fixture.SourceIso -ImageIndex 6 -Profile default-winutil `
            -OutputIsoPath $fixture.OutputIso -WorkDirectory $fixture.Work -OscdimgPath $fixture.Oscdimg -BuildProvider $fixture.Provider | Out-Null

        $fixture.State.Exports | Should -Be 1
        $fixture.State.Sessions | Should -Be 1
        $fixture.State.PrepareArguments.InstallImageIndex | Should -Be 1
        $fixture.State.PrepareArguments.InstallImagePath | Should -Match 'install\.wim$'
    }

    It 'forwards only an explicitly supplied driver directory to canonical media preparation' {
        $fixture = New-NonInteractiveBuildFixture
        $drivers = Join-Path $fixture.Root 'drivers'
        New-Item -Path $drivers -ItemType Directory | Out-Null

        Invoke-WinUtilWindowsBuild -SourceIsoPath $fixture.SourceIso -ImageIndex 6 -Profile default-winutil -DriverDirectory $drivers `
            -OutputIsoPath $fixture.OutputIso -WorkDirectory $fixture.Work -OscdimgPath $fixture.Oscdimg -BuildProvider $fixture.Provider | Out-Null

        $fixture.State.PrepareArguments.DriverDirectory | Should -Be $drivers
        (Get-Content -LiteralPath (Join-Path $script:repoRoot 'functions/private/Invoke-WinUtilISOScript.ps1') -Raw) |
            Should -Match 'Invoke-WinUtilOfflineServicingTransaction[^\r\n]+-DriverDirectory \$DriverDirectory'
    }

    It 'requires explicit Expert mode for an otherwise blocked Lean DAW plan' {
        $fixture = New-NonInteractiveBuildFixture

        { Invoke-WinUtilWindowsBuild -SourceIsoPath $fixture.SourceIso -ImageIndex 6 -Profile lean-daw `
            -OutputIsoPath $fixture.OutputIso -WorkDirectory $fixture.Work -OscdimgPath $fixture.Oscdimg -BuildProvider $fixture.Provider } |
            Should -Throw "*Resolved 'lean-daw' plan is not ready or allowed*"

        $fixture.Session.State | Should -Be 'Discarded'
        Test-Path -LiteralPath $fixture.Work | Should -BeFalse
        Test-Path -LiteralPath $fixture.OutputIso | Should -BeFalse
    }

    It 'allows the Lean DAW profile only when Expert mode is explicit' {
        $fixture = New-NonInteractiveBuildFixture

        $result = Invoke-WinUtilWindowsBuild -SourceIsoPath $fixture.SourceIso -ImageIndex 6 -Profile lean-daw -ExpertMode `
            -OutputIsoPath $fixture.OutputIso -WorkDirectory $fixture.Work -OscdimgPath $fixture.Oscdimg -BuildProvider $fixture.Provider

        $result.Profile | Should -Be 'lean-daw'
        $fixture.State.PrepareArguments.ActionBundle.IsAllowed | Should -BeTrue
        $fixture.State.PrepareArguments.ActionBundle.ProfileId | Should -Be 'lean-daw'
    }

    It 'plants unsupported-media and stale-path negatives before durable output' {
        $unsupported = New-NonInteractiveBuildFixture -Build 26100
        { Invoke-WinUtilWindowsBuild -SourceIsoPath $unsupported.SourceIso -ImageIndex 6 -Profile default-winutil `
            -OutputIsoPath $unsupported.OutputIso -WorkDirectory $unsupported.Work -OscdimgPath $unsupported.Oscdimg -BuildProvider $unsupported.Provider } |
            Should -Throw '*Unsupported source media*only Windows 11 25H2*'
        Test-Path -LiteralPath $unsupported.OutputIso | Should -BeFalse

        $stale = New-NonInteractiveBuildFixture
        New-Item -Path $stale.Work -ItemType Directory | Out-Null
        Set-Content -LiteralPath (Join-Path $stale.Work 'keep.txt') -Value 'stale evidence'
        { Invoke-WinUtilWindowsBuild -SourceIsoPath $stale.SourceIso -ImageIndex 6 -Profile default-winutil `
            -OutputIsoPath $stale.OutputIso -WorkDirectory $stale.Work -OscdimgPath $stale.Oscdimg -BuildProvider $stale.Provider } |
            Should -Throw '*refusing stale state*'
        (Get-Content -LiteralPath (Join-Path $stale.Work 'keep.txt') -Raw).Trim() | Should -Be 'stale evidence'
        $stale.State.Mounts | Should -Be 0
    }

    It 'plants oscdimg error and empty-output negatives and removes invocation-owned state' -ForEach @(
        @{ ExitCode = 9; EmptyOutput = $false; Expected = '*oscdimg failed with exit code 9*' }
        @{ ExitCode = 0; EmptyOutput = $true; Expected = '*output ISO is missing or empty*' }
    ) {
        $fixture = New-NonInteractiveBuildFixture -OscdimgExitCode $ExitCode -EmptyOutput:$EmptyOutput

        { Invoke-WinUtilWindowsBuild -SourceIsoPath $fixture.SourceIso -ImageIndex 6 -Profile default-winutil `
            -OutputIsoPath $fixture.OutputIso -WorkDirectory $fixture.Work -OscdimgPath $fixture.Oscdimg -BuildProvider $fixture.Provider } |
            Should -Throw $Expected

        Test-Path -LiteralPath $fixture.OutputIso | Should -BeFalse
        Test-Path -LiteralPath $fixture.Work | Should -BeFalse
    }
}

Describe 'Noninteractive pre-release build wiring' {
    It 'builds both acceptance ISOs from one explicit official source instead of pre-generated variables' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:repoRoot '.github/workflows/pre-release.yaml') -Raw

        ([regex]::Matches($workflow, '\./tools/Invoke-WinUtilWindowsBuild\.ps1')).Count | Should -Be 2
        $workflow | Should -Match 'WINUTIL_OFFICIAL_SOURCE_ISO_PATH: \$\{\{ vars\.WINUTIL_OFFICIAL_SOURCE_ISO_PATH \}\}'
        $workflow | Should -Match '-Profile default-winutil'
        $workflow | Should -Match '-Profile lean-daw -ExpertMode'
        $workflow | Should -Not -Match 'vars\.WINUTIL_(STOCK_CONTROL|LEAN_DAW|UNATTEND)_ISO_PATH'
        $workflow | Should -Not -Match '-UnattendIsoPath'
    }
}
