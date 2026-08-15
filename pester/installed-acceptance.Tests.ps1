BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:harnessPath = Join-Path $script:repoRoot 'tools/Invoke-WinUtilInstalledAcceptance.ps1'
    . $script:harnessPath

    function New-AcceptanceProbeProvider {
        param ([ValidateSet('StockControl', 'LeanDaw')][string]$Mode = 'StockControl', [string]$FailCommand)
        $lean = $Mode -eq 'LeanDaw'
        @{
            Command = {
                param ($FilePath, $ArgumentList)
                $identity = "$FilePath $($ArgumentList -join ' ')"
                $commandFails = $FailCommand -and $identity -match $FailCommand
                $evidence = if ($FilePath -eq 'reagentc.exe') { 'Windows RE status: Enabled' } else { "command=$identity" }
                [pscustomobject]@{ Success = -not $commandFails; Evidence = $evidence; ExitCode = $(if ($commandFails) { 1 } else { 0 }) }
            }.GetNewClosure()
            Registry = {
                param ($Path, $Name)
                $leanValue = if ($Name -in @('DisableWindowsConsumerFeatures', 'DisableSearchBoxSuggestions')) { 1 } else { 0 }
                [pscustomobject]@{ Exists = $lean; Value = $leanValue; Evidence = "$Path::$Name=$leanValue" }
            }.GetNewClosure()
            Appx = {
                param ($Pattern)
                $protected = $Pattern -in @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', '*OneSettings*')
                [pscustomobject]@{ Present = $protected -or -not $lean; Evidence = "appx=$Pattern" }
            }.GetNewClosure()
            Service = {
                param ($Name)
                $declaredRemoval = $Name -in @('WSearch', 'WinDefend', 'OneSyncSvc', 'DiagTrack')
                [pscustomobject]@{ Present = -not ($lean -and $declaredRemoval); StartType = 'Manual'; Evidence = "service=$Name start=Manual" }
            }.GetNewClosure()
            Feature = { param ($Name) [pscustomobject]@{ Present = $true; Evidence = "feature=$Name" } }
            Package = { param ($Pattern) [pscustomobject]@{ Present = -not $lean; Evidence = "package=$Pattern" } }.GetNewClosure()
            SystemApp = { param ($Pattern) [pscustomobject]@{ Present = -not $lean; Evidence = "systemapp=$Pattern" } }.GetNewClosure()
            Task = { param ($TaskPath) [pscustomobject]@{ Present = $true; Enabled = -not $lean; Evidence = "task=$TaskPath enabled=$(-not $lean)" } }.GetNewClosure()
            File = {
                param ($Path)
                $declaredRemoval = $Path -match 'OneDriveSetup\.exe$'
                [pscustomobject]@{ Present = -not ($lean -and $declaredRemoval); Evidence = "file=$Path version=1.0" }
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
        $document.HarnessVersion | Should -Be '1.1.0'
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
        foreach ($id in @('protected.feature.servicesfornfs-clientonly', 'protected.feature.microsoft-windows-subsystem-linux', 'protected.service.wersvc', 'protected.service.pcasvc', 'protected.service.sysmain', 'protected.onesettings', 'protected.featureconfig', 'protected.mitigations')) {
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
