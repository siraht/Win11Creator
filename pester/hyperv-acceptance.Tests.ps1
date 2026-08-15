BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:repoRoot 'tools/Invoke-WinUtilHyperVAcceptance.ps1')

    function New-HyperVAcceptanceProvider {
        param (
            [string]$VMState = 'Running',
            [bool]$GuestReady = $true,
            [int]$GuestExitCode = 0,
            [bool]$GuestAccepted = $true,
            [bool]$CopyEvidence = $true,
            [int]$ClockStepMinutes = 0,
            [bool]$CreateFailure = $false,
            [bool]$TargetFailure = $false,
            [bool]$AnswerFailure = $false
        )
        $state = [pscustomobject]@{ Removed = $false; AnswerRemoved = $false; Started = $false; Clock = [datetime]'2026-01-01T00:00:00Z'; AnswerUser = $null }
        $provider = @{
            AssertHost = { param ($SwitchName) if (-not $SwitchName) { throw 'missing switch' } }
            AssertTargets = { param ($VMName, $VhdPath) if ($TargetFailure) { throw 'target already exists' } }.GetNewClosure()
            GenerateAnswerMedia = {
                param ($GeneratorPath, $OutputPath, $Edition, $Credential)
                if ($AnswerFailure) { throw 'planted answer generation failure' }
                $state.AnswerUser = $Credential.UserName
                Set-Content -LiteralPath $OutputPath -Value 'ephemeral answer fixture'
                [pscustomobject]@{ Path = $OutputPath; Edition = $Edition; Sha256 = 'A' * 64 }
            }.GetNewClosure()
            RemoveAnswerMedia = {
                param ($VMName, $Path)
                Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
                $state.AnswerRemoved = $true
            }.GetNewClosure()
            CreateVM = { param ($VMName) if (-not $VMName) { throw 'missing VM' }; if ($CreateFailure) { throw 'planted creation failure' } }.GetNewClosure()
            StartVM = { param ($VMName) $state.Started = $true }.GetNewClosure()
            GetVMState = { param ($VMName) $VMState }.GetNewClosure()
            TestGuestReady = { param ($VMName, $Credential) $GuestReady }.GetNewClosure()
            CopyToGuest = { param ($VMName, $Credential, $Source, $Destination) }
            InvokeGuestAcceptance = { param ($VMName) [pscustomobject]@{ ExitCode = $GuestExitCode } }.GetNewClosure()
            CopyFromGuest = {
                param ($VMName, $Credential, $Source, $Destination)
                if (-not $CopyEvidence) { return }
                if ($Destination -match '\.json$') {
                    [pscustomobject]@{ SchemaVersion = '1.0'; IsAccepted = $GuestAccepted } | ConvertTo-Json | Set-Content -LiteralPath $Destination
                } else { Set-Content -LiteralPath $Destination -Value 'guest acceptance log' }
            }.GetNewClosure()
            RemoveVM = { param ($VMName, $VhdPath) $state.Removed = $true }.GetNewClosure()
            Now = {
                $value = $state.Clock
                $state.Clock = $state.Clock.AddMinutes($ClockStepMinutes)
                $value
            }.GetNewClosure()
            Delay = { param ($Seconds) }
        }
        [pscustomobject]@{ Provider = $provider; State = $state }
    }

    function Invoke-TestHyperVAcceptance {
        param ($ProviderState, [string]$ExpectedState = 'StockControl', [int]$TimeoutMinutes = 5, [string]$OutputName = 'result')
        $isoPath = Join-Path $TestDrive "$OutputName.iso"
        Set-Content -LiteralPath $isoPath -Value 'generated iso fixture'
        $credential = [pscredential]::new('WinUtilTest', (ConvertTo-SecureString 'fixture-only' -AsPlainText -Force))
        Invoke-WinUtilHyperVAcceptance -IsoPath $isoPath -Edition 'Windows 11 Pro' -ExpectedState $ExpectedState -Depth Quick `
            -VMName "WinUtil-$OutputName" -SwitchName 'TestSwitch' -VhdPath (Join-Path $TestDrive "$OutputName.vhdx") `
            -OutputDirectory (Join-Path $TestDrive $OutputName) -GuestCredential $credential -InstallTimeoutMinutes $TimeoutMinutes `
            -PostLoginSmokeCommand 'exit 0' -VMProvider $ProviderState.Provider
    }
}

Describe 'Hyper-V installed acceptance orchestration' {
    It 'HyperVAcceptance_InstallsAndValidates_<ExpectedState>' -ForEach @(
        @{ ExpectedState = 'StockControl' }, @{ ExpectedState = 'LeanDaw' }
    ) {
        $fake = New-HyperVAcceptanceProvider
        $result = Invoke-TestHyperVAcceptance -ProviderState $fake -ExpectedState $ExpectedState -OutputName $ExpectedState

        $result.ExitCode | Should -Be 0
        $result.IsAccepted | Should -BeTrue
        $fake.State.Started | Should -BeTrue
        $fake.State.Removed | Should -BeTrue
        $fake.State.AnswerRemoved | Should -BeTrue
        $fake.State.AnswerUser | Should -Be 'WinUtilTest'
        Test-Path -LiteralPath (Join-Path $result.OutputDirectory 'installed-acceptance.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $result.OutputDirectory 'installed-acceptance.log') | Should -BeTrue
        Get-Content -LiteralPath $result.LogPath -Raw | Should -Match 'Guest installed acceptance passed'
        Get-Content -LiteralPath $result.LogPath -Raw | Should -Not -Match 'fixture-only'
    }

    It 'HyperVAcceptance_BootFailure_PlantedNegative' {
        $fake = New-HyperVAcceptanceProvider -VMState Off -GuestReady $false
        $result = Invoke-TestHyperVAcceptance -ProviderState $fake -OutputName 'boot-failure'

        $result.ExitCode | Should -Be 1
        $result.Failure | Should -Match 'powered off before guest acceptance'
        $fake.State.Removed | Should -BeTrue
    }

    It 'HyperVAcceptance_PartialCreationFailureCleansUp_PlantedNegative' {
        $fake = New-HyperVAcceptanceProvider -CreateFailure $true
        $result = Invoke-TestHyperVAcceptance -ProviderState $fake -OutputName 'creation-failure'

        $result.ExitCode | Should -Be 1
        $result.Failure | Should -Match 'planted creation failure'
        $fake.State.Removed | Should -BeTrue
    }

    It 'HyperVAcceptance_AnswerGenerationFailure_PlantedNegative' {
        $fake = New-HyperVAcceptanceProvider -AnswerFailure $true
        $result = Invoke-TestHyperVAcceptance -ProviderState $fake -OutputName 'answer-failure'

        $result.ExitCode | Should -Be 1
        $result.Failure | Should -Match 'planted answer generation failure'
        $fake.State.Started | Should -BeFalse
        $fake.State.Removed | Should -BeFalse
    }

    It 'HyperVAcceptance_PreexistingTargetIsNeverRemoved_PlantedNegative' {
        $fake = New-HyperVAcceptanceProvider -TargetFailure $true
        $result = Invoke-TestHyperVAcceptance -ProviderState $fake -OutputName 'existing-target'

        $result.ExitCode | Should -Be 1
        $result.Failure | Should -Match 'target already exists'
        $fake.State.Removed | Should -BeFalse
    }

    It 'HyperVAcceptance_InstallTimeout_PlantedNegative' {
        $fake = New-HyperVAcceptanceProvider -GuestReady $false -ClockStepMinutes 3
        $result = Invoke-TestHyperVAcceptance -ProviderState $fake -TimeoutMinutes 1 -OutputName 'timeout'

        $result.ExitCode | Should -Be 1
        $result.Failure | Should -Match 'Timed out after 1 minute'
        $fake.State.Removed | Should -BeTrue
    }

    It 'HyperVAcceptance_AcceptanceNonzero_PlantedNegative' {
        $fake = New-HyperVAcceptanceProvider -GuestExitCode 9 -GuestAccepted $false
        $result = Invoke-TestHyperVAcceptance -ProviderState $fake -OutputName 'acceptance-failure'

        $result.ExitCode | Should -Be 1
        $result.Failure | Should -Match 'failed with exit code 9'
        Test-Path -LiteralPath (Join-Path $result.OutputDirectory 'installed-acceptance.json') | Should -BeTrue
    }

    It 'HyperVAcceptance_MissingGuestEvidence_PlantedNegative' {
        $fake = New-HyperVAcceptanceProvider -CopyEvidence $false
        $result = Invoke-TestHyperVAcceptance -ProviderState $fake -OutputName 'missing-evidence'

        $result.ExitCode | Should -Be 1
        $result.Failure | Should -Match 'evidence was not retrieved completely'
    }

    It 'HyperVAcceptance_RejectsStaleOutputDirectory' {
        $fake = New-HyperVAcceptanceProvider
        $output = Join-Path $TestDrive 'stale'
        New-Item -Path $output -ItemType Directory | Out-Null
        Set-Content -LiteralPath (Join-Path $output 'old.json') -Value '{}'
        $iso = Join-Path $TestDrive 'stale.iso'
        Set-Content -LiteralPath $iso -Value fixture
        $credential = [pscredential]::new('test', (ConvertTo-SecureString 'test' -AsPlainText -Force))

        { Invoke-WinUtilHyperVAcceptance -IsoPath $iso -Edition 'Windows 11 Pro' -ExpectedState StockControl -VMName Test -SwitchName Test -VhdPath (Join-Path $TestDrive 'stale.vhdx') -OutputDirectory $output -GuestCredential $credential -PostLoginSmokeCommand 'exit 0' -VMProvider $fake.Provider } |
            Should -Throw '*must be empty to prevent stale evidence*'
    }

    It 'HyperVAcceptance_MalformedBoundary_PlantedNegative' {
        $fake = New-HyperVAcceptanceProvider
        $fake.Provider.Remove('StartVM')
        { Invoke-TestHyperVAcceptance -ProviderState $fake -OutputName 'bad-provider' } | Should -Throw "*boundary 'StartVM' must be a scriptblock*"
    }
}

Describe 'Release VM acceptance wiring' {
    It 'HyperVAcceptance_ReleaseRunsBothGeneratedIsoContracts' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:repoRoot '.github/workflows/pre-release.yaml') -Raw
        ([regex]::Matches($workflow, 'Invoke-WinUtilHyperVAcceptance\.ps1')).Count | Should -Be 2
        $workflow | Should -Match '-ExpectedState StockControl'
        $workflow | Should -Match '-ExpectedState LeanDaw'
        $workflow | Should -Match 'WINUTIL_STOCK_CONTROL_ISO_PATH'
        $workflow | Should -Match 'WINUTIL_LEAN_DAW_ISO_PATH'
        $workflow | Should -Not -Match 'WINUTIL_UNATTEND_ISO_PATH'
        $workflow | Should -Not -Match '(?m)^\s*\./tools/Invoke-WinUtilInstalledAcceptance\.ps1'
    }

    It 'HyperVAcceptance_AttachesAnswerMediaBeforeBootMediaForAnswerDiscovery' {
        $source = Get-Content -LiteralPath (Join-Path $script:repoRoot 'tools/Invoke-WinUtilHyperVAcceptance.ps1') -Raw
        $source.IndexOf('Add-VMDvdDrive -VMName $VMName -Path $UnattendIsoPath') | Should -BeLessThan $source.IndexOf('$installDrive = Add-VMDvdDrive -VMName $VMName -Path $IsoPath')
        $source | Should -Match 'Set-VMFirmware -VMName \$VMName -FirstBootDevice \$installDrive'
    }
}
