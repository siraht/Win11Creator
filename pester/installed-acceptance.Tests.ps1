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
        $document.HarnessVersion | Should -Be '1.3.0'
        $document.Results.Id | Should -Contain 'servicing.dism-checkhealth'
        $document.Results.Id | Should -Contain 'developer.directml'
        ($document.Results | Where-Object Id -eq 'servicing.dism-scanhealth').Status | Should -Be 'NotRun'
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

    It 'InstalledAcceptance_MalformedBoundary_PlantedNegative' {
        $provider = New-AcceptanceProbeProvider
        $provider.Remove('Registry')
        { Invoke-WinUtilInstalledAcceptance -OutputPath (Join-Path $TestDrive 'bad.json') -ProbeProvider $provider } |
            Should -Throw "*boundary 'Registry' must be a scriptblock*"
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
