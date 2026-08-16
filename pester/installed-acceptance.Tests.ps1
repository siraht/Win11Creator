BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:harnessPath = Join-Path $script:repoRoot 'tools/Invoke-WinUtilInstalledAcceptance.ps1'
    . $script:harnessPath

    function Get-TestEncodedPowerShellScript {
        param ([object[]]$ArgumentList)
        $encodedIndex = [Array]::IndexOf($ArgumentList, '-EncodedCommand')
        if ($encodedIndex -lt 0 -or $encodedIndex + 1 -ge $ArgumentList.Count) { return $null }
        [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String([string]$ArgumentList[$encodedIndex + 1]))
    }

    function New-AcceptanceProbeProvider {
        param ([ValidateSet('StockControl', 'LeanDaw')][string]$Mode = 'StockControl', [string]$FailCommand, [switch]$StockOptionalAbsent)
        $lean = $Mode -eq 'LeanDaw'
        $decodeCommand = ${function:Get-TestEncodedPowerShellScript}
        @{
            Command = {
                param ($FilePath, $ArgumentList)
                $decodedCommand = & $decodeCommand $ArgumentList
                $identity = "$FilePath $($ArgumentList -join ' ') $decodedCommand"
                $commandFails = $FailCommand -and $identity -match $FailCommand
                $evidence = if ($FilePath -eq 'reagentc.exe') {
                    'Windows RE status: Enabled'
                } elseif ($identity -match '/(?:Check|Scan)Health') {
                    'No component store corruption detected.'
                } elseif ($identity -match 'Microsoft\.Update\.Session') {
                    'UpdateScan count=0 result=2'
                } else {
                    "command=$identity"
                }
                [pscustomobject]@{ Success = -not $commandFails; Evidence = $evidence; ExitCode = $(if ($commandFails) { 1 } else { 0 }) }
            }.GetNewClosure()
            Registry = {
                param ($Path, $Name)
                $leanValue = if ($Name -in @('DisableWindowsConsumerFeatures', 'DisableSearchBoxSuggestions')) { 1 } else { 0 }
                [pscustomobject]@{ Exists = $lean; Value = $leanValue; Evidence = "$Path::$Name=$leanValue" }
            }.GetNewClosure()
            Appx = {
                param ($Pattern)
                $protected = $Pattern -in @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller')
                [pscustomobject]@{ Present = $protected -or (-not $lean -and -not $StockOptionalAbsent); Evidence = "appx=$Pattern" }
            }.GetNewClosure()
            Service = {
                param ($Name)
                $declaredRemoval = $Name -in @('WSearch', 'WinDefend', 'OneSyncSvc', 'DiagTrack')
                [pscustomobject]@{ Present = -not (($lean -or $StockOptionalAbsent) -and $declaredRemoval); StartType = 'Manual'; Evidence = "service=$Name start=Manual" }
            }.GetNewClosure()
            Feature = { param ($Name) [pscustomobject]@{ Present = $true; Evidence = "feature=$Name" } }
            Package = { param ($Pattern) [pscustomobject]@{ Present = -not $lean -and -not $StockOptionalAbsent; Evidence = "package=$Pattern" } }.GetNewClosure()
            SystemApp = { param ($Pattern) [pscustomobject]@{ Present = -not $lean -and -not $StockOptionalAbsent; Evidence = "systemapp=$Pattern" } }.GetNewClosure()
            Task = {
                param ($TaskPath)
                $protected = $TaskPath -eq '\Microsoft\Windows\Flighting\OneSettings\RefreshCache'
                [pscustomobject]@{ Present = $protected -or -not $StockOptionalAbsent; Enabled = $protected -or -not $lean; Evidence = "task=$TaskPath" }
            }.GetNewClosure()
            File = {
                param ($Path)
                $declaredRemoval = $Path -match 'OneDriveSetup\.exe$'
                [pscustomobject]@{ Present = -not (($lean -or $StockOptionalAbsent) -and $declaredRemoval); Evidence = "file=$Path version=1.0" }
            }.GetNewClosure()
            Registration = { param ($Target) [pscustomobject]@{ Present = $true; Evidence = "registration=$Target" } }
            UpdateInstall = {
                [pscustomobject]@{
                    Outcome = 'ZeroApplicable'; SearchResultCode = 2; ApplicableCount = 0; Title = $null; KBArticleIDs = @()
                    DownloadResultCode = $null; InstallResultCode = $null; UpdateResultCode = $null; HResult = $null
                    RebootRequired = $false; Evidence = 'UpdateInstall outcome=ZeroApplicable searchResult=2 applicable=0 rebootRequired=False'
                }
            }
            WerCrash = { [pscustomobject]@{ Success = $true; Evidence = 'Controlled crash exit=-1073740791; WER dump=WinUtilWerCrash.dmp bytes=4096' } }
            NfsFunctional = { [pscustomobject]@{ Success = $true; Evidence = 'Enabled and queried NFS client; service=Running; nfsadmin exit=0; changedFeatures=ServicesForNFS-ClientOnly' } }
            DeveloperFunctional = {
                [pscustomobject]@{
                    CleanupSucceeded = $true; Evidence = 'Removed isolated developer probe root.'
                    Results = @('git', 'powershell', 'node', 'bun', 'python', 'rust', 'cargo' | ForEach-Object {
                        [pscustomobject]@{ Id = "developer.$_"; Success = $true; Evidence = "functional $_ smoke passed" }
                    })
                }
            }
        }
    }
}

Describe 'Installed acceptance harness' {
    It 'InstalledAcceptance_QuickStockWritesVersionedJsonAndHumanLog' {
        $output = Join-Path $TestDrive 'stock.json'
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState StockControl -Depth Quick -OutputPath $output -ProbeProvider (New-AcceptanceProbeProvider)

        $result.ExitCode | Should -Be 0
        $result.IsAccepted | Should -BeTrue
        Test-Path -LiteralPath $output | Should -BeTrue
        Test-Path -LiteralPath ([IO.Path]::ChangeExtension($output, '.log')) | Should -BeTrue
        $document = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
        $document.SchemaVersion | Should -Be '1.0'
        $document.HarnessVersion | Should -Be '1.8.0'
        $document.Results.Id | Should -Contain 'servicing.dism-checkhealth'
        $document.Results.Id | Should -Contain 'developer.directml'
        ($document.Results | Where-Object Id -eq 'servicing.dism-scanhealth').Status | Should -Be 'NotRun'
        $werResult = $document.Results | Where-Object Id -eq 'protected.wer-crashdump'
        $werResult.Status | Should -Be 'NotRun'
        $werResult.Required | Should -BeFalse
        $nfsResult = $document.Results | Where-Object Id -eq 'protected.nfs-functional'
        $nfsResult.Status | Should -Be 'NotRun'
        $nfsResult.Required | Should -BeFalse
        $updateInstall = $document.Results | Where-Object Id -eq 'update.install-one'
        $updateInstall.Status | Should -Be 'NotRun'
        $updateInstall.Required | Should -BeFalse
    }

    It 'InstalledAcceptance_LeanExpectedStateCoversDeclaredAndProtectedTargets' {
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState LeanDaw -Depth Quick -OutputPath (Join-Path $TestDrive 'lean.json') -ProbeProvider (New-AcceptanceProbeProvider -Mode LeanDaw)

        $result.IsAccepted | Should -BeTrue
        foreach ($id in @('removal.search', 'removal.bing', 'removal.widgets', 'removal.defender', 'removal.uac', 'removal.ai', 'removal.onedrive', 'removal.xbox', 'removal.telemetry')) {
            ($result.Document.Results | Where-Object Id -eq $id).Status | Should -Be 'Pass'
        }
        foreach ($id in @('protected.feature.servicesfornfs-clientonly', 'protected.feature.microsoft-windows-subsystem-linux', 'protected.service.wersvc', 'protected.service.pcasvc', 'protected.service.sysmain', 'protected.onesettings', 'protected.featureconfig', 'protected.task.onesettings-refreshcache', 'protected.mitigations')) {
            ($result.Document.Results | Where-Object Id -eq $id).Status | Should -Be 'Pass'
        }
    }

    It 'InstalledAcceptance_PlantedRequiredFailureReturnsNonzero' {
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState StockControl -Depth Quick -OutputPath (Join-Path $TestDrive 'failure.json') -ProbeProvider (New-AcceptanceProbeProvider -FailCommand 'CheckHealth')

        $result.ExitCode | Should -Be 1
        $result.IsAccepted | Should -BeFalse
        ($result.Document.Results | Where-Object Id -eq 'servicing.dism-checkhealth').Status | Should -Be 'Fail'
        $result.Document.Summary.RequiredFailures | Should -BeGreaterThan 0
    }

    It 'InstalledAcceptance_RepairableComponentStoreWithZeroExit_PlantedNegative' {
        $provider = New-AcceptanceProbeProvider
        $baseCommand = $provider.Command
        $provider.Command = {
            param ($FilePath, $ArgumentList)
            if ($FilePath -eq 'dism.exe' -and $ArgumentList -contains '/CheckHealth') {
                [pscustomobject]@{ Success = $true; Evidence = 'The component store is repairable.'; ExitCode = 0 }
            } else {
                & $baseCommand $FilePath $ArgumentList
            }
        }.GetNewClosure()
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState StockControl -Depth Quick -OutputPath (Join-Path $TestDrive 'repairable-store.json') -ProbeProvider $provider

        $result.ExitCode | Should -Be 1
        ($result.Document.Results | Where-Object Id -eq 'servicing.dism-checkhealth').Status | Should -Be 'Fail'
    }

    It 'InstalledAcceptance_ReleaseScanHealthRequiresExplicitHealthyEvidence_PlantedNegative' -ForEach @(
        @{ Evidence = 'The component store corruption was detected.'; Label = 'corrupt' },
        @{ Evidence = 'The operation completed successfully.'; Label = 'missing-health-state' }
    ) {
        $provider = New-AcceptanceProbeProvider -Mode LeanDaw
        $baseCommand = $provider.Command
        $provider.Command = {
            param ($FilePath, $ArgumentList)
            if ($FilePath -eq 'dism.exe' -and $ArgumentList -contains '/ScanHealth') {
                [pscustomobject]@{ Success = $true; Evidence = $Evidence; ExitCode = 0 }
            } else {
                & $baseCommand $FilePath $ArgumentList
            }
        }.GetNewClosure()
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState LeanDaw -Depth Release -OutputPath (Join-Path $TestDrive "scanhealth-$Label.json") `
            -AbletonPath 'C:\ProgramData\Ableton\Live.exe' -Vst3Path @('C:\Program Files\Common Files\VST3\Vendor.vst3') `
            -LatencyMonReportPath 'C:\Evidence\latencymon.txt' -SmokeCommand 'exit 0' -PostLoginSmokeCommand 'exit 0' -ProbeProvider $provider

        $result.ExitCode | Should -Be 1
        ($result.Document.Results | Where-Object Id -eq 'servicing.dism-scanhealth').Status | Should -Be 'Fail'
    }

    It 'InstalledAcceptance_DisabledUpdateInfrastructure_PlantedNegative' {
        $provider = New-AcceptanceProbeProvider
        $provider.Service = {
            param ($Name)
            [pscustomobject]@{ Present = $true; StartType = $(if ($Name -eq 'wuauserv') { 'Disabled' } else { 'Manual' }); Evidence = "service=$Name" }
        }
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState StockControl -Depth Quick -OutputPath (Join-Path $TestDrive 'disabled-update.json') -ProbeProvider $provider

        $result.ExitCode | Should -Be 1
        ($result.Document.Results | Where-Object Id -eq 'update.service.wuauserv').Status | Should -Be 'Fail'
    }

    It 'InstalledAcceptance_UpdateSearchUsesUtf16EncodedCommand_PlantedContract' {
        $provider = New-AcceptanceProbeProvider
        $baseCommand = $provider.Command
        $decodeCommand = ${function:Get-TestEncodedPowerShellScript}
        $capture = [pscustomobject]@{ Arguments = $null }
        $provider.Command = {
            param ($FilePath, $ArgumentList)
            $decoded = & $decodeCommand $ArgumentList
            if ($decoded -match 'Microsoft\.Update\.Session') { $capture.Arguments = @($ArgumentList) }
            & $baseCommand $FilePath $ArgumentList
        }.GetNewClosure()
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState StockControl -Depth Quick -OutputPath (Join-Path $TestDrive 'encoded-update.json') -ProbeProvider $provider

        $result.ExitCode | Should -Be 0
        $capture.Arguments | Should -Contain '-EncodedCommand'
        $capture.Arguments | Should -Not -Contain '-Command'
        $decoded = Get-TestEncodedPowerShellScript $capture.Arguments
        $decoded | Should -Match 'New-Object -ComObject Microsoft\.Update\.Session'
        $decoded | Should -Match '\[int\]\$search\.ResultCode -ne 2'
        $decoded | Should -Match 'UpdateScan count=\$\(\$search\.Updates\.Count\) result=\$\(\$search\.ResultCode\)'
    }

    It 'InstalledAcceptance_UpdateScanUnsuccessfulResult_PlantedNegative' -ForEach @(
        @{ Evidence = 'UpdateScan count=0 result=4'; Label = 'failed-result' },
        @{ Evidence = 'search completed without a result code'; Label = 'missing-result' }
    ) {
        $provider = New-AcceptanceProbeProvider
        $baseCommand = $provider.Command
        $decodeCommand = ${function:Get-TestEncodedPowerShellScript}
        $provider.Command = {
            param ($FilePath, $ArgumentList)
            if ((& $decodeCommand $ArgumentList) -match 'Microsoft\.Update\.Session') {
                [pscustomobject]@{ Success = $true; Evidence = $Evidence; ExitCode = 0 }
            } else {
                & $baseCommand $FilePath $ArgumentList
            }
        }.GetNewClosure()
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState StockControl -Depth Quick -OutputPath (Join-Path $TestDrive "update-$Label.json") -ProbeProvider $provider

        $result.ExitCode | Should -Be 1
        ($result.Document.Results | Where-Object Id -eq 'update.scan').Status | Should -Be 'Fail'
        $result.Document.Summary.RequiredFailures | Should -BeGreaterThan 0
    }

    It 'InstalledAcceptance_ReleaseRecordsExactZeroApplicableUpdateEvidence' {
        $provider = New-AcceptanceProbeProvider -Mode LeanDaw
        $outputPath = Join-Path $TestDrive 'update-zero.json'
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState LeanDaw -Depth Release -OutputPath $outputPath `
            -AbletonPath 'C:\ProgramData\Ableton\Live.exe' -Vst3Path @('C:\Program Files\Common Files\VST3\Vendor.vst3') `
            -LatencyMonReportPath 'C:\Evidence\latencymon.txt' -SmokeCommand 'exit 0' -PostLoginSmokeCommand 'exit 0' -ProbeProvider $provider

        $probe = $result.Document.Results | Where-Object Id -eq 'update.install-one'
        $probe.Status | Should -Be 'Pass'
        $probe.Required | Should -BeTrue
        $probe.Evidence | Should -Be 'UpdateInstall outcome=ZeroApplicable searchResult=2 applicable=0 rebootRequired=False'
        $probe.Details.Outcome | Should -Be 'ZeroApplicable'
        $probe.Details.SearchResultCode | Should -Be 2
        $probe.Details.ApplicableCount | Should -Be 0
        $probe.Details.RebootRequired | Should -BeFalse
        $persistedProbe = (Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json).Results | Where-Object Id -eq 'update.install-one'
        $persistedProbe.Details.Outcome | Should -Be 'ZeroApplicable'
        $persistedProbe.Details.SearchResultCode | Should -Be 2
        $persistedProbe.Details.RebootRequired | Should -BeFalse
    }

    It 'InstalledAcceptance_ReleaseAcceptsOneInstalledSoftwareUpdateWithComEvidence' {
        $provider = New-AcceptanceProbeProvider -Mode LeanDaw
        $provider.UpdateInstall = {
            [pscustomobject]@{
                Outcome = 'Installed'; SearchResultCode = 2; ApplicableCount = 3; Title = '2026-08 Cumulative Update'; KBArticleIDs = @('5069999')
                DownloadResultCode = 2; InstallResultCode = 2; UpdateResultCode = 2; HResult = 0; RebootRequired = $true
                Evidence = 'UpdateInstall outcome=Installed searchResult=2 applicable=3 downloadResult=2 installResult=2 updateResult=2 hresult=0 rebootRequired=True title=2026-08 Cumulative Update kb=5069999'
            }
        }
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState LeanDaw -Depth Release -OutputPath (Join-Path $TestDrive 'update-installed.json') `
            -AbletonPath 'C:\ProgramData\Ableton\Live.exe' -Vst3Path @('C:\Program Files\Common Files\VST3\Vendor.vst3') `
            -LatencyMonReportPath 'C:\Evidence\latencymon.txt' -SmokeCommand 'exit 0' -PostLoginSmokeCommand 'exit 0' -ProbeProvider $provider

        $probe = $result.Document.Results | Where-Object Id -eq 'update.install-one'
        $probe.Status | Should -Be 'Pass'
        $probe.Evidence | Should -Match 'rebootRequired=True'
        $probe.Details.DownloadResultCode | Should -Be 2
        $probe.Details.InstallResultCode | Should -Be 2
        $probe.Details.UpdateResultCode | Should -Be 2
        $probe.Details.HResult | Should -Be 0
        $probe.Details.RebootRequired | Should -BeTrue
    }

    It 'InstalledAcceptance_ReleaseUpdateInstallFailsClosedOnPlantedComEvidence' -ForEach @(
        @{ Label = 'search-failed'; Value = @{ Outcome = 'ZeroApplicable'; SearchResultCode = 4; ApplicableCount = 0; RebootRequired = $false; Evidence = 'process exit=0' } },
        @{ Label = 'false-zero'; Value = @{ Outcome = 'ZeroApplicable'; SearchResultCode = 2; ApplicableCount = 1; RebootRequired = $false; Evidence = 'process exit=0' } },
        @{ Label = 'download-failed'; Value = @{ Outcome = 'Installed'; SearchResultCode = 2; ApplicableCount = 1; Title = 'Update'; KBArticleIDs = @(); DownloadResultCode = 4; InstallResultCode = 2; UpdateResultCode = 2; HResult = 0; RebootRequired = $false; Evidence = 'process exit=0'; Success = $true } },
        @{ Label = 'install-failed'; Value = @{ Outcome = 'Installed'; SearchResultCode = 2; ApplicableCount = 1; Title = 'Update'; KBArticleIDs = @(); DownloadResultCode = 2; InstallResultCode = 4; UpdateResultCode = 2; HResult = 0; RebootRequired = $false; Evidence = 'process exit=0'; Success = $true } },
        @{ Label = 'per-update-failed'; Value = @{ Outcome = 'Installed'; SearchResultCode = 2; ApplicableCount = 1; Title = 'Update'; KBArticleIDs = @(); DownloadResultCode = 2; InstallResultCode = 2; UpdateResultCode = 4; HResult = -2145124329; RebootRequired = $false; Evidence = 'process exit=0'; Success = $true } },
        @{ Label = 'failed-hresult'; Value = @{ Outcome = 'Installed'; SearchResultCode = 2; ApplicableCount = 1; Title = 'Update'; KBArticleIDs = @(); DownloadResultCode = 2; InstallResultCode = 2; UpdateResultCode = 2; HResult = -2145124329; RebootRequired = $false; Evidence = 'process exit=0'; Success = $true } },
        @{ Label = 'missing-hresult'; Value = @{ Outcome = 'Installed'; SearchResultCode = 2; ApplicableCount = 1; Title = 'Update'; KBArticleIDs = @(); DownloadResultCode = 2; InstallResultCode = 2; UpdateResultCode = 2; RebootRequired = $false; Evidence = 'process exit=0'; Success = $true } },
        @{ Label = 'string-reboot'; Value = @{ Outcome = 'Installed'; SearchResultCode = 2; ApplicableCount = 1; Title = 'Update'; KBArticleIDs = @(); DownloadResultCode = 2; InstallResultCode = 2; UpdateResultCode = 2; HResult = 0; RebootRequired = 'false'; Evidence = 'process exit=0'; Success = $true } },
        @{ Label = 'empty-evidence'; Value = @{ Outcome = 'ZeroApplicable'; SearchResultCode = 2; ApplicableCount = 0; RebootRequired = $false; Evidence = ' ' } }
    ) {
        $provider = New-AcceptanceProbeProvider -Mode LeanDaw
        $planted = $Value
        $provider.UpdateInstall = { [pscustomobject]$planted }.GetNewClosure()
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState LeanDaw -Depth Release -OutputPath (Join-Path $TestDrive "update-$Label.json") `
            -AbletonPath 'C:\ProgramData\Ableton\Live.exe' -Vst3Path @('C:\Program Files\Common Files\VST3\Vendor.vst3') `
            -LatencyMonReportPath 'C:\Evidence\latencymon.txt' -SmokeCommand 'exit 0' -PostLoginSmokeCommand 'exit 0' -ProbeProvider $provider

        $result.ExitCode | Should -Be 1
        ($result.Document.Results | Where-Object Id -eq 'update.install-one').Status | Should -Be 'Fail'
    }

    It 'InstalledAcceptance_QuickNeverInvokesUpdateInstallation' {
        $provider = New-AcceptanceProbeProvider
        $provider.Remove('UpdateInstall')
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState StockControl -Depth Quick -OutputPath (Join-Path $TestDrive 'update-quick.json') -ProbeProvider $provider

        $result.ExitCode | Should -Be 0
        ($result.Document.Results | Where-Object Id -eq 'update.install-one').Status | Should -Be 'NotRun'
    }

    It 'InstalledAcceptance_QuickNeverInvokesDeveloperFunctionalWork' {
        $provider = New-AcceptanceProbeProvider
        $provider.Remove('DeveloperFunctional')
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState StockControl -Depth Quick -OutputPath (Join-Path $TestDrive 'developer-quick.json') -ProbeProvider $provider

        $result.ExitCode | Should -Be 0
        foreach ($id in @('developer.git', 'developer.powershell', 'developer.node', 'developer.bun', 'developer.python', 'developer.rust', 'developer.cargo')) {
            $probe = $result.Document.Results | Where-Object Id -eq $id
            $probe.Required | Should -BeFalse
            $probe.Status | Should -Be 'Pass'
        }
    }

    It 'InstalledAcceptance_ReleaseUsesFunctionalDeveloperEvidence' {
        $provider = New-AcceptanceProbeProvider -Mode LeanDaw
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState LeanDaw -Depth Release -OutputPath (Join-Path $TestDrive 'developer-release.json') `
            -AbletonPath 'C:\ProgramData\Ableton\Live.exe' -Vst3Path @('C:\Program Files\Common Files\VST3\Vendor.vst3') `
            -LatencyMonReportPath 'C:\Evidence\latencymon.txt' -SmokeCommand 'exit 0' -PostLoginSmokeCommand 'exit 0' -ProbeProvider $provider

        $result.ExitCode | Should -Be 0
        foreach ($id in @('developer.git', 'developer.powershell', 'developer.node', 'developer.bun', 'developer.python', 'developer.rust', 'developer.cargo')) {
            $probe = $result.Document.Results | Where-Object Id -eq $id
            $probe.Required | Should -BeTrue
            $probe.Status | Should -Be 'Pass'
            $probe.Evidence | Should -Match '^functional '
        }
    }

    It 'InstalledAcceptance_DeveloperFunctionalPlantedNegativeFailsClosed' -ForEach @(
        @{ Label = 'cleanup'; Mutate = { param ($envelope) $envelope.CleanupSucceeded = $false; $envelope.Evidence = 'probe root remains' } },
        @{ Label = 'missing'; Mutate = { param ($envelope) $envelope.Results = @($envelope.Results | Where-Object Id -ne 'developer.node') } },
        @{ Label = 'duplicate'; Mutate = { param ($envelope) $envelope.Results = @($envelope.Results) + @($envelope.Results | Select-Object -First 1) } },
        @{ Label = 'malformed'; Mutate = { param ($envelope) ($envelope.Results | Where-Object Id -eq 'developer.python').Success = 'true' } },
        @{ Label = 'failed-smoke'; Mutate = { param ($envelope) ($envelope.Results | Where-Object Id -eq 'developer.cargo').Success = $false } }
    ) {
        $provider = New-AcceptanceProbeProvider -Mode LeanDaw
        $baseBoundary = $provider.DeveloperFunctional
        $mutation = $Mutate
        $provider.DeveloperFunctional = {
            $envelope = & $baseBoundary
            & $mutation $envelope
            $envelope
        }.GetNewClosure()
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState LeanDaw -Depth Release -OutputPath (Join-Path $TestDrive "developer-$Label.json") `
            -AbletonPath 'C:\ProgramData\Ableton\Live.exe' -Vst3Path @('C:\Program Files\Common Files\VST3\Vendor.vst3') `
            -LatencyMonReportPath 'C:\Evidence\latencymon.txt' -SmokeCommand 'exit 0' -PostLoginSmokeCommand 'exit 0' -ProbeProvider $provider

        $result.ExitCode | Should -Be 1
        ($result.Document.Results | Where-Object { $_.Id -in @('developer.git', 'developer.powershell', 'developer.node', 'developer.bun', 'developer.python', 'developer.rust', 'developer.cargo') }).Status | Should -Contain 'Fail'
    }

    It 'InstalledAcceptance_ProductionDeveloperProbeIsIsolatedTimedAndReversible' {
        $probeText = (Get-WinUtilInstalledProbeProvider).DeveloperFunctional.ToString()

        $probeText | Should -Match 'WinUtilDeveloperAcceptance_'
        $probeText | Should -Match 'WaitForExit\(\$TimeoutSeconds \* 1000\)'
        $probeText | Should -Match 'taskkill\.exe /PID \$process\.Id /T /F'
        $probeText | Should -Match 'process tree did not exit after taskkill'
        $probeText | Should -Match "@\('init', '--quiet'\)"
        $probeText | Should -Match "@\('commit', '--quiet', '-m', 'acceptance smoke'\)"
        $probeText | Should -Match ([regex]::Escape('@(''cat-file'', ''-e'', "$head^{commit}")'))
        $probeText | Should -Match '\{40\}\|\[0-9a-f\]\{64\}'
        $probeText | Should -Match "pwsh\.exe @\('-NoProfile', '-NonInteractive', '-File'"
        $probeText | Should -Match "node\.exe @\('--check'"
        $probeText | Should -Match "bun\.exe @\('build'"
        $probeText | Should -Match "python\.exe @\('-m', 'venv'"
        $probeText | Should -Match "cargo\.exe @\('run', '--quiet', '--manifest-path'"
        $probeText | Should -Match "-cne 'WINUTIL_"
        $probeText | Should -Match 'Remove-Item -LiteralPath \$probeRoot -Recurse -Force'
        $probeText | Should -Match 'CleanupSucceeded = \$cleanupSucceeded'
    }

    It 'InstalledAcceptance_ProductionUpdateInstallBoundarySelectsOneSoftwareUpdateAndRecordsComResults' {
        $probeText = (Get-WinUtilInstalledProbeProvider).UpdateInstall.ToString()

        $probeText | Should -Match "Type='Software'"
        $probeText | Should -Match '\$search\.Updates\.Item\(0\)'
        $probeText | Should -Match '\[void\]\$selection\.Add\(\$update\)'
        $probeText | Should -Match '\$downloader\.Download\(\)'
        $probeText | Should -Match '\$installer\.Install\(\)'
        $probeText | Should -Match '\$install\.GetUpdateResult\(0\)'
        $probeText | Should -Match 'HResult'
        $probeText | Should -Match 'RebootRequired'
    }

    It 'InstalledAcceptance_ReleaseMissingCommercialEvidenceIsNotRunAndBlocking' {
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState LeanDaw -Depth Release -OutputPath (Join-Path $TestDrive 'release.json') -ProbeProvider (New-AcceptanceProbeProvider -Mode LeanDaw)

        $result.ExitCode | Should -Be 1
        foreach ($id in @('daw.ableton', 'daw.vst3', 'daw.latencymon', 'daw.smoke')) {
            $probe = $result.Document.Results | Where-Object Id -eq $id
            $probe.Status | Should -Be 'NotRun'
            $probe.Required | Should -BeTrue
        }
    }

    It 'InstalledAcceptance_DisabledWinRe_PlantedNegative' {
        $provider = New-AcceptanceProbeProvider -Mode LeanDaw
        $provider.Command = {
            param ($FilePath, $ArgumentList)
            [pscustomobject]@{ Success = $true; Evidence = $(if ($FilePath -eq 'reagentc.exe') { 'Windows RE status: Disabled' } else { "command=$FilePath $($ArgumentList -join ' ')" }); ExitCode = 0 }
        }
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState LeanDaw -Depth Release -OutputPath (Join-Path $TestDrive 'disabled-winre.json') -ProbeProvider $provider

        ($result.Document.Results | Where-Object Id -eq 'servicing.winre').Status | Should -Be 'Fail'
        $result.ExitCode | Should -Be 1
    }

    It 'InstalledAcceptance_ReleaseAcceptsSuppliedDawEvidenceHooks' {
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState LeanDaw -Depth Release -OutputPath (Join-Path $TestDrive 'release-ready.json') `
            -AbletonPath 'C:\ProgramData\Ableton\Live.exe' -Vst3Path @('C:\Program Files\Common Files\VST3\Vendor.vst3') `
            -LatencyMonReportPath 'C:\Evidence\latencymon.txt' -SmokeCommand 'exit 0' -PostLoginSmokeCommand 'exit 0' -ProbeProvider (New-AcceptanceProbeProvider -Mode LeanDaw)

        $result.ExitCode | Should -Be 0
        ($result.Document.Results | Where-Object Area -eq 'DAW').Status | Should -Not -Contain 'NotRun'
    }

    It 'InstalledAcceptance_ReleaseWerDumpFailureIsBlocking_PlantedNegative' {
        $provider = New-AcceptanceProbeProvider -Mode LeanDaw
        $provider.WerCrash = { [pscustomobject]@{ Success = $false; Evidence = 'Controlled crash produced no nonempty WER local dump.' } }
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState LeanDaw -Depth Release -OutputPath (Join-Path $TestDrive 'wer-failure.json') `
            -AbletonPath 'C:\ProgramData\Ableton\Live.exe' -Vst3Path @('C:\Program Files\Common Files\VST3\Vendor.vst3') `
            -LatencyMonReportPath 'C:\Evidence\latencymon.txt' -SmokeCommand 'exit 0' -PostLoginSmokeCommand 'exit 0' -ProbeProvider $provider

        $result.ExitCode | Should -Be 1
        $werResult = $result.Document.Results | Where-Object Id -eq 'protected.wer-crashdump'
        $werResult.Required | Should -BeTrue
        $werResult.Status | Should -Be 'Fail'
        $werResult.Evidence | Should -Match 'no nonempty WER local dump'
    }

    It 'InstalledAcceptance_ReleaseRunsRequiredFunctionalNfsProbe' {
        $provider = New-AcceptanceProbeProvider -Mode LeanDaw
        $capture = [pscustomobject]@{ Calls = 0 }
        $provider.NfsFunctional = {
            $capture.Calls++
            [pscustomobject]@{ Success = $true; Evidence = 'Enabled and queried NFS client; service=Running; nfsadmin exit=0' }
        }.GetNewClosure()
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState LeanDaw -Depth Release -OutputPath (Join-Path $TestDrive 'nfs-release.json') `
            -AbletonPath 'C:\ProgramData\Ableton\Live.exe' -Vst3Path @('C:\Program Files\Common Files\VST3\Vendor.vst3') `
            -LatencyMonReportPath 'C:\Evidence\latencymon.txt' -SmokeCommand 'exit 0' -PostLoginSmokeCommand 'exit 0' -ProbeProvider $provider

        $capture.Calls | Should -Be 1
        $nfsResult = $result.Document.Results | Where-Object Id -eq 'protected.nfs-functional'
        $nfsResult.Required | Should -BeTrue
        $nfsResult.Status | Should -Be 'Pass'
    }

    It 'InstalledAcceptance_NfsEnableUseOrCleanupFailureIsBlocking_PlantedNegative' -ForEach @(
        @{ Evidence = 'NFS feature did not reach Enabled.'; Label = 'enable' },
        @{ Evidence = 'nfsadmin client failed with exit code 2.'; Label = 'use' },
        @{ Evidence = 'Enabled and queried NFS client; cleanup failed: restore NFS-Administration expected Disabled, found Enabled'; Label = 'cleanup' }
    ) {
        $provider = New-AcceptanceProbeProvider -Mode LeanDaw
        $provider.NfsFunctional = { [pscustomobject]@{ Success = $false; Evidence = $Evidence } }.GetNewClosure()
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState LeanDaw -Depth Release -OutputPath (Join-Path $TestDrive "nfs-$Label.json") `
            -AbletonPath 'C:\ProgramData\Ableton\Live.exe' -Vst3Path @('C:\Program Files\Common Files\VST3\Vendor.vst3') `
            -LatencyMonReportPath 'C:\Evidence\latencymon.txt' -SmokeCommand 'exit 0' -PostLoginSmokeCommand 'exit 0' -ProbeProvider $provider

        $result.ExitCode | Should -Be 1
        $nfsResult = $result.Document.Results | Where-Object Id -eq 'protected.nfs-functional'
        $nfsResult.Required | Should -BeTrue
        $nfsResult.Status | Should -Be 'Fail'
        $nfsResult.Evidence | Should -Be $Evidence
    }

    It 'InstalledAcceptance_MalformedNfsResultFailsClosed_PlantedNegative' -ForEach @(
        @{ Result = $null; Expected = 'Boolean Success' },
        @{ Result = @([pscustomobject]@{ Success = $true; Evidence = 'one' }, [pscustomobject]@{ Success = $true; Evidence = 'two' }); Expected = 'returned 2 results' },
        @{ Result = [pscustomobject]@{ Success = 'false'; Evidence = 'not Boolean' }; Expected = 'Boolean Success' },
        @{ Result = [pscustomobject]@{ Success = $true; Evidence = ' ' }; Expected = 'nonempty Evidence' }
    ) {
        $provider = New-AcceptanceProbeProvider -Mode LeanDaw
        $provider.NfsFunctional = { $Result }.GetNewClosure()
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState LeanDaw -Depth Release -OutputPath (Join-Path $TestDrive "nfs-malformed-$([Guid]::NewGuid().ToString('N')).json") `
            -AbletonPath 'C:\ProgramData\Ableton\Live.exe' -Vst3Path @('C:\Program Files\Common Files\VST3\Vendor.vst3') `
            -LatencyMonReportPath 'C:\Evidence\latencymon.txt' -SmokeCommand 'exit 0' -PostLoginSmokeCommand 'exit 0' -ProbeProvider $provider

        $result.ExitCode | Should -Be 1
        $nfsResult = $result.Document.Results | Where-Object Id -eq 'protected.nfs-functional'
        $nfsResult.Status | Should -Be 'Fail'
        $nfsResult.Evidence | Should -Match $Expected
    }

    It 'InstalledAcceptance_QuickDoesNotRunFunctionalNfsProbe' {
        $provider = New-AcceptanceProbeProvider
        $provider.NfsFunctional = { throw 'Quick mode must not mutate NFS state.' }
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState StockControl -Depth Quick -OutputPath (Join-Path $TestDrive 'nfs-quick.json') -ProbeProvider $provider

        $result.ExitCode | Should -Be 0
        ($result.Document.Results | Where-Object Id -eq 'protected.nfs-functional').Status | Should -Be 'NotRun'
    }

    It 'InstalledAcceptance_ProductionNfsProbeIsFunctionalAndReversible' {
        $provider = Get-WinUtilInstalledProbeProvider
        $probeText = $provider.NfsFunctional.ToString()

        $probeText | Should -Match 'Enable-WindowsOptionalFeature'
        $probeText | Should -Match 'Start-Service -Name ''NfsClnt'''
        $probeText | Should -Match 'WaitForExit\(30000\)'
        $probeText | Should -Match "ArgumentList @\('client'\)"
        $probeText | Should -Match 'Disable-WindowsOptionalFeature'
        $probeText | Should -Match 'expected \$\(\$initialStates\[\$featureName\]\), found'
        $probeText | Should -Match 'Remove-Item -LiteralPath \$probeRoot'
    }

    It 'InstalledAcceptance_QuickDoesNotRunControlledWerCrash' {
        $provider = New-AcceptanceProbeProvider
        $provider.WerCrash = { throw 'Quick mode must not trigger a controlled crash.' }
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState StockControl -Depth Quick -OutputPath (Join-Path $TestDrive 'wer-quick.json') -ProbeProvider $provider

        $result.ExitCode | Should -Be 0
        ($result.Document.Results | Where-Object Id -eq 'protected.wer-crashdump').Status | Should -Be 'NotRun'
    }

    It 'InstalledAcceptance_ProductionWerProbeUsesLocalDumpsAndCleansUp' {
        $provider = Get-WinUtilInstalledProbeProvider
        $probeText = $provider.WerCrash.ToString()

        $probeText | Should -Match 'Environment\.FailFast'
        $probeText | Should -Match 'Windows Error Reporting\\LocalDumps'
        $probeText | Should -Match "Where-Object Length -gt 0"
        $probeText | Should -Match 'Remove-Item -LiteralPath \$dumpKey'
        $probeText | Should -Match 'Remove-Item -LiteralPath \$probeRoot'
    }

    It 'InstalledAcceptance_MalformedBoundary_PlantedNegative' {
        $provider = New-AcceptanceProbeProvider
        $provider.Remove('Registry')
        { Invoke-WinUtilInstalledAcceptance -OutputPath (Join-Path $TestDrive 'bad.json') -ProbeProvider $provider } |
            Should -Throw "*boundary 'Registry' must be a scriptblock*"
    }

    It 'InstalledAcceptance_MissingWerBoundary_PlantedNegative' {
        $provider = New-AcceptanceProbeProvider
        $provider.Remove('WerCrash')
        { Invoke-WinUtilInstalledAcceptance -OutputPath (Join-Path $TestDrive 'bad-wer.json') -ProbeProvider $provider } |
            Should -Throw "*boundary 'WerCrash' must be a scriptblock*"
    }

    It 'InstalledAcceptance_MissingNfsBoundary_PlantedNegative' {
        $provider = New-AcceptanceProbeProvider
        $provider.Remove('NfsFunctional')
        { Invoke-WinUtilInstalledAcceptance -OutputPath (Join-Path $TestDrive 'bad-nfs.json') -ProbeProvider $provider } |
            Should -Throw "*boundary 'NfsFunctional' must be a scriptblock*"
    }

    It 'InstalledAcceptance_MissingUpdateInstallBoundary_PlantedNegative' {
        $provider = New-AcceptanceProbeProvider -Mode LeanDaw
        $provider.Remove('UpdateInstall')
        { Invoke-WinUtilInstalledAcceptance -ExpectedState LeanDaw -Depth Release -OutputPath (Join-Path $TestDrive 'bad-update-install.json') -ProbeProvider $provider } |
            Should -Throw "*boundary 'UpdateInstall' must be a scriptblock*"
    }

    It 'InstalledAcceptance_StockOptionalSourceAbsenceDoesNotBlock' {
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState StockControl -Depth Quick -OutputPath (Join-Path $TestDrive 'stock-optional.json') -ProbeProvider (New-AcceptanceProbeProvider -StockOptionalAbsent)

        $result.ExitCode | Should -Be 0
        foreach ($id in @('removal.bing', 'removal.search-package', 'removal.search-systemapp', 'removal.search', 'removal.onedrive', 'removal.task.consolidator')) {
            $probe = $result.Document.Results | Where-Object Id -eq $id
            $probe.Status | Should -Be 'NotRun'
            $probe.Required | Should -BeFalse
        }
    }

    It 'InstalledAcceptance_StockPresentButDisabledOptionalTarget_PlantedNegative' {
        $provider = New-AcceptanceProbeProvider
        $provider.Service = { param ($Name) [pscustomobject]@{ Present = $true; StartType = $(if ($Name -eq 'WSearch') { 'Disabled' } else { 'Manual' }); Evidence = "service=$Name" } }
        $provider.Task = { param ($TaskPath) [pscustomobject]@{ Present = $true; Enabled = $TaskPath -notmatch 'Consolidator$'; Evidence = "task=$TaskPath" } }
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState StockControl -Depth Quick -OutputPath (Join-Path $TestDrive 'stock-disabled.json') -ProbeProvider $provider

        $result.ExitCode | Should -Be 1
        ($result.Document.Results | Where-Object Id -eq 'removal.search').Status | Should -Be 'Fail'
        ($result.Document.Results | Where-Object Id -eq 'removal.task.consolidator').Status | Should -Be 'Fail'
    }

    It 'InstalledAcceptance_WebViewProviderAcceptsLiveShapedRegistrationAndEvidence' {
        Mock Get-ChildItem {
            if ($LiteralPath -like '*EdgeUpdate\Clients') { [pscustomobject]@{ PSPath = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\EdgeUpdate\Clients\live-guid' } }
        }
        Mock Get-ItemProperty { [pscustomobject]@{ name = 'Microsoft Edge WebView2 Runtime'; pv = '142.0.0.0' } }
        $provider = Get-WinUtilInstalledProbeProvider
        $probe = & $provider.Registration 'WebView2'

        $probe.Present | Should -BeTrue
        $probe.Evidence | Should -Match 'Microsoft Edge WebView2 Runtime'
        $scriptText = Get-Content -LiteralPath $script:harnessPath -Raw
        $scriptText | Should -Not -Match '\{F1E7E5A1-5E70-4A20-BA76-02E5215AC9F5\}'
    }

    It 'InstalledAcceptance_WebViewProviderAcceptsRuntimeExecutableWithoutRegistration' {
        Mock Get-ChildItem {
            if (($Path -join ';') -match 'msedgewebview2\.exe') { [pscustomobject]@{ FullName = 'C:\Program Files (x86)\Microsoft\EdgeWebView\Application\142.0.0.0\msedgewebview2.exe' } }
        }
        Mock Get-ItemProperty { throw 'No registration should be read when no client key exists.' }
        $provider = Get-WinUtilInstalledProbeProvider
        $probe = & $provider.Registration 'WebView2'

        $probe.Present | Should -BeTrue
        $probe.Evidence | Should -Match 'msedgewebview2\.exe'
    }

    It 'InstalledAcceptance_MissingOneSettingsRefreshCacheTask_PlantedNegative' {
        $provider = New-AcceptanceProbeProvider -Mode LeanDaw
        $baseTask = $provider.Task
        $provider.Task = {
            param ($TaskPath)
            if ($TaskPath -eq '\Microsoft\Windows\Flighting\OneSettings\RefreshCache') {
                [pscustomobject]@{ Present = $false; Enabled = $false; Evidence = 'RefreshCache missing' }
            } else { & $baseTask $TaskPath }
        }.GetNewClosure()
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState LeanDaw -Depth Quick -OutputPath (Join-Path $TestDrive 'missing-refreshcache.json') -ProbeProvider $provider

        $result.ExitCode | Should -Be 1
        ($result.Document.Results | Where-Object Id -eq 'protected.task.onesettings-refreshcache').Status | Should -Be 'Fail'
    }

    It 'InstalledAcceptance_RemovedProtectedFeaturePayload_PlantedNegative' {
        $provider = New-AcceptanceProbeProvider -Mode LeanDaw
        $provider.Feature = { param ($Name) [pscustomobject]@{ Present = $Name -ne 'ServicesForNFS-ClientOnly'; State = 'Disabled with Payload Removed'; Evidence = "feature=$Name payload removed" } }
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState LeanDaw -Depth Quick -OutputPath (Join-Path $TestDrive 'removed-feature.json') -ProbeProvider $provider

        $result.ExitCode | Should -Be 1
        ($result.Document.Results | Where-Object Id -eq 'protected.feature.servicesfornfs-clientonly').Status | Should -Be 'Fail'
    }

    It 'InstalledAcceptance_UnexpectedLeanPackageAndTask_PlantedNegative' {
        $provider = New-AcceptanceProbeProvider -Mode LeanDaw
        $provider.Package = { param ($Pattern) [pscustomobject]@{ Present = $Pattern -eq 'Microsoft-Windows-Client-CoreAI-*'; Evidence = "package=$Pattern" } }
        $provider.Task = { param ($TaskPath) [pscustomobject]@{ Present = $true; Enabled = $TaskPath -match 'Consolidator$'; Evidence = "task=$TaskPath" } }
        $result = Invoke-WinUtilInstalledAcceptance -ExpectedState LeanDaw -Depth Quick -OutputPath (Join-Path $TestDrive 'lean-targets.json') -ProbeProvider $provider

        $result.ExitCode | Should -Be 1
        ($result.Document.Results | Where-Object Id -eq 'removal.coreai-package').Status | Should -Be 'Fail'
        ($result.Document.Results | Where-Object Id -eq 'removal.task.consolidator').Status | Should -Be 'Fail'
    }
}
