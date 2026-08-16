[CmdletBinding()]
param (
    [ValidateSet('StockControl', 'LeanDaw')][string]$ExpectedState = 'StockControl',
    [ValidateSet('Quick', 'Release')][string]$Depth = 'Quick',
    [string]$OutputPath,
    [string]$AbletonPath,
    [string[]]$Vst3Path,
    [string]$LatencyMonReportPath,
    [string]$SmokeCommand,
    [string]$PostLoginSmokeCommand,
    [hashtable]$ProbeProvider,
    [switch]$PassThru
)

function Get-WinUtilInstalledProbeProvider {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    $runCommand = {
        param ([string]$FilePath, [string[]]$ArgumentList)
        try {
            $output = & $FilePath @ArgumentList 2>&1 | Out-String
            [pscustomobject]@{ Success = $LASTEXITCODE -eq 0; Evidence = $output.Trim(); ExitCode = $LASTEXITCODE }
        } catch {
            [pscustomobject]@{ Success = $false; Evidence = $_.Exception.Message; ExitCode = -1 }
        }
    }

    @{
        Command = $runCommand
        Registry = {
            param ([string]$Path, [string]$Name)
            try {
                $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
                [pscustomobject]@{ Exists = $null -ne $item.PSObject.Properties[$Name]; Value = $item.$Name; Evidence = "$Path::$Name=$($item.$Name)" }
            } catch {
                [pscustomobject]@{ Exists = $false; Value = $null; Evidence = $_.Exception.Message }
            }
        }
        Appx = {
            param ([string]$Pattern)
            $packages = @(Get-AppxPackage -AllUsers -Name $Pattern -ErrorAction SilentlyContinue)
            [pscustomobject]@{ Present = $packages.Count -gt 0; Evidence = ($packages.PackageFullName -join '; ') }
        }
        Service = {
            param ([string]$Name)
            $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
            [pscustomobject]@{ Present = $null -ne $service; State = [string]$service.Status; StartType = [string]$service.StartType; Evidence = "$Name state=$($service.Status) start=$($service.StartType)" }
        }
        Feature = {
            param ([string]$Name)
            $result = & dism.exe /Online /English /Get-FeatureInfo "/FeatureName:$Name" 2>&1 | Out-String
            $state = if ($result -match 'State\s*:\s*([^\r\n]+)') { $Matches[1].Trim() } else { $null }
            [pscustomobject]@{ Present = $LASTEXITCODE -eq 0 -and $state -and $state -notmatch 'Removed'; State = $state; Evidence = $result.Trim() }
        }
        Package = {
            param ([string]$Pattern)
            $packages = @(Get-WindowsPackage -Online -ErrorAction SilentlyContinue | Where-Object PackageName -Like $Pattern)
            [pscustomobject]@{ Present = $packages.Count -gt 0; Evidence = ($packages.PackageName -join '; ') }
        }
        SystemApp = {
            param ([string]$Pattern)
            $apps = @(Get-ChildItem -Path "$env:SystemRoot\SystemApps" -Directory -Filter $Pattern -ErrorAction SilentlyContinue)
            [pscustomobject]@{ Present = $apps.Count -gt 0; Evidence = ($apps.FullName -join '; ') }
        }
        Task = {
            param ([string]$TaskPath)
            $separator = $TaskPath.LastIndexOf('\')
            $path = $TaskPath.Substring(0, $separator + 1)
            $name = $TaskPath.Substring($separator + 1)
            $task = Get-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue
            [pscustomobject]@{ Present = $null -ne $task; Enabled = $null -ne $task -and [string]$task.State -ne 'Disabled'; Evidence = "$TaskPath state=$($task.State)" }
        }
        File = {
            param ([string]$Path)
            $present = Test-Path -LiteralPath $Path
            $version = if ($present) { [Diagnostics.FileVersionInfo]::GetVersionInfo($Path).FileVersion } else { $null }
            [pscustomobject]@{ Present = $present; Evidence = "$Path version=$version" }
        }
        Registration = {
            param ([string]$Target)
            $evidence = $null
            switch ($Target) {
                'Start' { $value = @(Get-AppxPackage -AllUsers -Name 'Microsoft.Windows.StartMenuExperienceHost' -ErrorAction SilentlyContinue).Count -gt 0 }
                'Explorer' { $value = Test-Path -LiteralPath "$env:SystemRoot\explorer.exe" }
                'Settings' { $value = Test-Path -LiteralPath 'Registry::HKEY_CLASSES_ROOT\ms-settings' }
                'WebView2' {
                    $registrations = @(foreach ($root in @(
                        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\EdgeUpdate\Clients',
                        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients'
                    )) {
                        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue } | Where-Object { [string]$_.name -match 'WebView2 Runtime' }
                    })
                    $executables = @(Get-ChildItem -Path "${env:ProgramFiles(x86)}\Microsoft\EdgeWebView\Application\*\msedgewebview2.exe", "$env:ProgramFiles\Microsoft\EdgeWebView\Application\*\msedgewebview2.exe" -File -ErrorAction SilentlyContinue)
                    $value = $registrations.Count -gt 0 -or $executables.Count -gt 0
                    $evidence = "WebView2 registrations=$($registrations.name -join '; '); executables=$($executables.FullName -join '; ')"
                }
                default { $value = $false }
            }
            if (-not $evidence) { $evidence = "$Target registration=$value" }
            [pscustomobject]@{ Present = $value; Evidence = $evidence }
        }
        WerCrash = {
            $token = [Guid]::NewGuid().ToString('N')
            $probeRoot = Join-Path ([IO.Path]::GetTempPath()) "WinUtilWerAcceptance_$token"
            $executableName = "WinUtilWerCrash_$token.exe"
            $executablePath = Join-Path $probeRoot $executableName
            $dumpKey = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\$executableName"
            $dumpKeyCreated = $false
            $probeResult = $null
            $cleanupErrors = [System.Collections.Generic.List[string]]::new()
            try {
                New-Item -Path $probeRoot -ItemType Directory -ErrorAction Stop | Out-Null
                $source = @"
using System;
internal static class WinUtilWerCrash_$token {
    public static void Main() { Environment.FailFast("WinUtil controlled WER acceptance crash"); }
}
"@
                Add-Type -TypeDefinition $source -OutputAssembly $executablePath -OutputType ConsoleApplication -ErrorAction Stop
                if (Test-Path -LiteralPath $dumpKey) { throw "Unexpected pre-existing WER probe key '$dumpKey'." }
                New-Item -Path $dumpKey -Force -ErrorAction Stop | Out-Null
                $dumpKeyCreated = $true
                New-ItemProperty -LiteralPath $dumpKey -Name DumpFolder -Value $probeRoot -PropertyType ExpandString -Force -ErrorAction Stop | Out-Null
                New-ItemProperty -LiteralPath $dumpKey -Name DumpType -Value 2 -PropertyType DWord -Force -ErrorAction Stop | Out-Null

                $process = Start-Process -FilePath $executablePath -PassThru -WindowStyle Hidden -ErrorAction Stop
                if (-not $process.WaitForExit(30000)) {
                    $process.Kill()
                    throw 'Controlled crash process did not exit within 30 seconds.'
                }
                $deadline = [DateTime]::UtcNow.AddSeconds(30)
                do {
                    $dump = Get-ChildItem -LiteralPath $probeRoot -Filter '*.dmp' -File -ErrorAction SilentlyContinue |
                        Where-Object Length -gt 0 | Select-Object -First 1
                    if (-not $dump) { Start-Sleep -Milliseconds 250 }
                } while (-not $dump -and [DateTime]::UtcNow -lt $deadline)

                if (-not $dump) { throw 'Controlled crash produced no nonempty WER local dump within 30 seconds.' }
                if ($process.ExitCode -eq 0) { throw 'Controlled crash unexpectedly exited successfully.' }
                $probeResult = [pscustomobject]@{
                    Success = $true
                    Evidence = "Controlled crash pid=$($process.Id) exit=$($process.ExitCode); WER dump=$($dump.Name) bytes=$($dump.Length)"
                }
            } catch {
                $probeResult = [pscustomobject]@{ Success = $false; Evidence = $_.Exception.Message }
            } finally {
                if ($dumpKeyCreated) {
                    try { Remove-Item -LiteralPath $dumpKey -Recurse -Force -ErrorAction Stop } catch { $cleanupErrors.Add($_.Exception.Message) }
                }
                if (Test-Path -LiteralPath $probeRoot) {
                    try { Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction Stop } catch { $cleanupErrors.Add($_.Exception.Message) }
                }
            }
            if ($cleanupErrors.Count -gt 0) {
                [pscustomobject]@{ Success = $false; Evidence = "$($probeResult.Evidence); cleanup failed: $($cleanupErrors -join '; ')" }
            } else {
                $probeResult
            }
        }
    }
}

function Invoke-WinUtilInstalledAcceptance {
    [CmdletBinding()]
    param (
        [ValidateSet('StockControl', 'LeanDaw')][string]$ExpectedState = 'StockControl',
        [ValidateSet('Quick', 'Release')][string]$Depth = 'Quick',
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$AbletonPath,
        [string[]]$Vst3Path,
        [string]$LatencyMonReportPath,
        [string]$SmokeCommand,
        [string]$PostLoginSmokeCommand,
        [hashtable]$ProbeProvider
    )

    if (-not $ProbeProvider) { $ProbeProvider = Get-WinUtilInstalledProbeProvider }
    foreach ($boundary in @('Command', 'Registry', 'Appx', 'Service', 'Feature', 'Package', 'SystemApp', 'Task', 'File', 'Registration', 'WerCrash')) {
        if (-not $ProbeProvider.ContainsKey($boundary) -or $ProbeProvider[$boundary] -isnot [scriptblock]) {
            throw "ProbeProvider boundary '$boundary' must be a scriptblock."
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    function Add-AcceptanceResult {
        param ([string]$Id, [string]$Area, [bool]$Required, [ValidateSet('Pass', 'Fail', 'NotRun')][string]$Status, [string]$Evidence)
        $results.Add([pscustomobject][ordered]@{ Id = $Id; Area = $Area; Required = $Required; Status = $Status; Evidence = $Evidence })
    }
    function Test-Presence {
        param ([string]$Id, [string]$Area, [bool]$Required, [string]$Boundary, [object[]]$Arguments, [bool]$Expected)
        try {
            $probe = & $ProbeProvider[$Boundary] @Arguments
            $actual = if ($probe.PSObject.Properties['Present']) { [bool]$probe.Present } else { [bool]$probe.Success }
            Add-AcceptanceResult $Id $Area $Required $(if ($actual -eq $Expected) { 'Pass' } else { 'Fail' }) ([string]$probe.Evidence)
        } catch {
            Add-AcceptanceResult $Id $Area $Required 'Fail' $_.Exception.Message
        }
    }
    function Test-Command {
        param ([string]$Id, [string]$Area, [bool]$Required, [string]$FilePath, [string[]]$Arguments, [string]$EvidencePattern)
        try {
            $probe = & $ProbeProvider.Command $FilePath $Arguments
            $evidenceMatches = -not $EvidencePattern -or [string]$probe.Evidence -match $EvidencePattern
            Add-AcceptanceResult $Id $Area $Required $(if ($probe.Success -and $evidenceMatches) { 'Pass' } else { 'Fail' }) ([string]$probe.Evidence)
        } catch {
            Add-AcceptanceResult $Id $Area $Required 'Fail' $_.Exception.Message
        }
    }
    function Test-ServiceAvailability {
        param ([string]$Id, [string]$Area, [bool]$Required, [string]$Name, [bool]$ExpectedAvailable)
        try {
            $probe = & $ProbeProvider.Service $Name
            $available = $probe.Present -and [string]$probe.StartType -ne 'Disabled'
            Add-AcceptanceResult $Id $Area $Required $(if ($available -eq $ExpectedAvailable) { 'Pass' } else { 'Fail' }) ([string]$probe.Evidence)
        } catch {
            Add-AcceptanceResult $Id $Area $Required 'Fail' $_.Exception.Message
        }
    }
    function Test-DeclaredPresence {
        param ([string]$Id, [string]$Boundary, [object[]]$Arguments)
        try {
            $probe = & $ProbeProvider[$Boundary] @Arguments
            if ($lean) {
                Add-AcceptanceResult $Id 'DeclaredState' $true $(if ($probe.Present) { 'Fail' } else { 'Pass' }) ([string]$probe.Evidence)
            } elseif ($probe.Present) {
                Add-AcceptanceResult $Id 'DeclaredState' $true 'Pass' ([string]$probe.Evidence)
            } else {
                Add-AcceptanceResult $Id 'DeclaredState' $false 'NotRun' 'Component is not present in this StockControl source.'
            }
        } catch { Add-AcceptanceResult $Id 'DeclaredState' $true 'Fail' $_.Exception.Message }
    }
    function Test-DeclaredService {
        param ([string]$Id, [string]$Name)
        try {
            $probe = & $ProbeProvider.Service $Name
            $available = $probe.Present -and [string]$probe.StartType -ne 'Disabled'
            if ($lean) {
                Add-AcceptanceResult $Id 'DeclaredState' $true $(if ($available) { 'Fail' } else { 'Pass' }) ([string]$probe.Evidence)
            } elseif (-not $probe.Present) {
                Add-AcceptanceResult $Id 'DeclaredState' $false 'NotRun' 'Service is not present in this StockControl source.'
            } else {
                Add-AcceptanceResult $Id 'DeclaredState' $true $(if ($available) { 'Pass' } else { 'Fail' }) ([string]$probe.Evidence)
            }
        } catch { Add-AcceptanceResult $Id 'DeclaredState' $true 'Fail' $_.Exception.Message }
    }

    $healthyComponentStorePattern = '(?im)^\s*No component store corruption detected\.\s*$'
    Test-Command 'servicing.dism-checkhealth' 'Servicing' $true 'dism.exe' @('/Online', '/Cleanup-Image', '/CheckHealth') $healthyComponentStorePattern
    if ($Depth -eq 'Release') {
        Test-Command 'servicing.dism-scanhealth' 'Servicing' $true 'dism.exe' @('/Online', '/Cleanup-Image', '/ScanHealth') $healthyComponentStorePattern
        Test-Command 'servicing.component-cleanup' 'Servicing' $true 'dism.exe' @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    } else {
        Add-AcceptanceResult 'servicing.dism-scanhealth' 'Servicing' $false 'NotRun' 'Release-depth probe.'
        Add-AcceptanceResult 'servicing.component-cleanup' 'Servicing' $false 'NotRun' 'Release-depth probe.'
    }
    Test-Command 'servicing.winre' 'Servicing' ($Depth -eq 'Release') 'reagentc.exe' @('/info') 'Windows RE status:\s+Enabled'
    foreach ($serviceName in @('wuauserv', 'BITS', 'UsoSvc', 'WaaSMedicSvc')) {
        Test-ServiceAvailability "update.service.$($serviceName.ToLowerInvariant())" 'WindowsUpdate' $true $serviceName $true
    }
    $updateSearchScript = '$session = New-Object -ComObject Microsoft.Update.Session; $search = $session.CreateUpdateSearcher().Search(''IsInstalled=0 and IsHidden=0''); if ([int]$search.ResultCode -ne 2) { throw "Windows Update search returned result code $($search.ResultCode)." }; "UpdateScan count=$($search.Updates.Count) result=$($search.ResultCode)"'
    $encodedUpdateSearch = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($updateSearchScript))
    Test-Command 'update.scan' 'WindowsUpdate' $true 'powershell.exe' @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedUpdateSearch) '(?m)^UpdateScan count=\d+ result=2$'

    foreach ($registration in @('Start', 'Explorer', 'Settings', 'WebView2')) {
        Test-Presence "core.$($registration.ToLowerInvariant())" 'CoreWindows' $true 'Registration' @($registration) $true
    }
    Test-Command 'core.terminal' 'CoreWindows' $true 'wt.exe' @('--version')
    Test-Command 'core.winget' 'CoreWindows' $true 'winget.exe' @('--info')
    Test-Presence 'core.store' 'CoreWindows' $true 'Appx' @('Microsoft.WindowsStore') $true
    Test-Presence 'core.appinstaller' 'CoreWindows' $true 'Appx' @('Microsoft.DesktopAppInstaller') $true
    if ($PostLoginSmokeCommand) {
        Test-Command 'core.postlogin-smoke' 'CoreWindows' $true 'powershell.exe' @('-NoProfile', '-NonInteractive', '-Command', $PostLoginSmokeCommand)
    } else {
        Add-AcceptanceResult 'core.postlogin-smoke' 'CoreWindows' ($Depth -eq 'Release') 'NotRun' 'Post-login smoke hook not supplied.'
    }

    $lean = $ExpectedState -eq 'LeanDaw'
    $removalAppx = [ordered]@{
        'removal.bing' = 'Microsoft.Bing*'; 'removal.widgets' = 'MicrosoftWindows.Client.WebExperience'
        'removal.webexperience' = 'MicrosoftWindows.Client.WebExperience'
        'removal.copilot' = 'Microsoft.Copilot'; 'removal.feedback' = 'Microsoft.WindowsFeedbackHub'
        'removal.ai' = '*AI*'; 'removal.xbox' = 'Microsoft.Xbox*'; 'removal.consumer-appx' = 'Microsoft.Clipchamp*'
    }
    foreach ($entry in $removalAppx.GetEnumerator()) {
        Test-DeclaredPresence $entry.Key 'Appx' @($entry.Value)
    }
    foreach ($entry in ([ordered]@{
        'removal.search-package' = 'Microsoft-Windows-Search-*'
        'removal.defender-package' = 'Windows-Defender-*'
        'removal.defender-component-package' = 'Microsoft-Windows-Windows-Defender-*'
        'removal.coreai-package' = 'Microsoft-Windows-Client-CoreAI-*'
        'removal.aix-package' = 'Microsoft-Windows-Client-AIX-*'
    }).GetEnumerator()) {
        Test-DeclaredPresence $entry.Key 'Package' @($entry.Value)
    }
    foreach ($entry in ([ordered]@{
        'removal.search-systemapp' = '*Search*'
        'removal.coreai-systemapp' = '*CoreAI*'
        'removal.aix-systemapp' = '*AIX*'
    }).GetEnumerator()) {
        Test-DeclaredPresence $entry.Key 'SystemApp' @($entry.Value)
    }
    foreach ($entry in @(
        @{ Id = 'removal.search'; Name = 'WSearch' }, @{ Id = 'removal.defender'; Name = 'WinDefend' },
        @{ Id = 'removal.telemetry'; Name = 'DiagTrack' }
    )) {
        Test-DeclaredService $entry.Id $entry.Name
    }
    $registryStates = @(
        @{ Id = 'removal.smartscreen'; Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'EnableSmartScreen'; LeanValue = 0 },
        @{ Id = 'removal.uac'; Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'EnableLUA'; LeanValue = 0 },
        @{ Id = 'removal.gamedvr'; Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name = 'AllowGameDVR'; LeanValue = 0 },
        @{ Id = 'removal.consumer-content'; Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures'; LeanValue = 1 }
        @{ Id = 'removal.bing-policy'; Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; LeanValue = 1 }
    )
    foreach ($entry in $registryStates) {
        try {
            $probe = & $ProbeProvider.Registry $entry.Path $entry.Name
            $stateMatches = if ($lean) { $probe.Exists -and $probe.Value -eq $entry.LeanValue } else { -not $probe.Exists -or $probe.Value -ne $entry.LeanValue }
            Add-AcceptanceResult $entry.Id 'DeclaredState' $true $(if ($stateMatches) { 'Pass' } else { 'Fail' }) ([string]$probe.Evidence)
        } catch { Add-AcceptanceResult $entry.Id 'DeclaredState' $true 'Fail' $_.Exception.Message }
    }
    Test-DeclaredPresence 'removal.onedrive' 'File' @("$env:SystemRoot\System32\OneDriveSetup.exe")
    foreach ($taskPath in @(
        '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
        '\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask',
        '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'
    )) {
        try {
            $task = & $ProbeProvider.Task $taskPath
            $id = "removal.task.$(($taskPath.Split('\')[-1]).ToLowerInvariant())"
            if ($lean) {
                Add-AcceptanceResult $id 'DeclaredState' $true $(if (-not $task.Present -or -not $task.Enabled) { 'Pass' } else { 'Fail' }) ([string]$task.Evidence)
            } elseif (-not $task.Present) {
                Add-AcceptanceResult $id 'DeclaredState' $false 'NotRun' 'Task is not present in this StockControl source.'
            } else {
                Add-AcceptanceResult $id 'DeclaredState' $true $(if ($task.Enabled) { 'Pass' } else { 'Fail' }) ([string]$task.Evidence)
            }
        } catch { Add-AcceptanceResult "removal.task.$(($taskPath.Split('\')[-1]).ToLowerInvariant())" 'DeclaredState' $true 'Fail' $_.Exception.Message }
    }

    foreach ($featureName in @('ServicesForNFS-ClientOnly', 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform', 'Microsoft-Hyper-V-All')) {
        Test-Presence "protected.feature.$($featureName.ToLowerInvariant())" 'Protected' $true 'Feature' @($featureName) $true
    }
    foreach ($serviceName in @('WerSvc', 'PcaSvc', 'SysMain')) {
        Test-ServiceAvailability "protected.service.$($serviceName.ToLowerInvariant())" 'Protected' $true $serviceName $true
    }
    if ($Depth -eq 'Release') {
        try {
            $werProbe = & $ProbeProvider.WerCrash
            Add-AcceptanceResult 'protected.wer-crashdump' 'Protected' $true $(if ($werProbe.Success) { 'Pass' } else { 'Fail' }) ([string]$werProbe.Evidence)
        } catch { Add-AcceptanceResult 'protected.wer-crashdump' 'Protected' $true 'Fail' $_.Exception.Message }
    } else {
        Add-AcceptanceResult 'protected.wer-crashdump' 'Protected' $false 'NotRun' 'Release-depth controlled crash probe.'
    }
    Test-Presence 'protected.onesettings' 'Protected' $true 'File' @("$env:SystemRoot\System32\OneSettingsClient.dll") $true
    Test-Presence 'protected.featureconfig' 'Protected' $true 'File' @("$env:SystemRoot\System32\FlightSettings.dll") $true
    try {
        $oneSettingsTask = & $ProbeProvider.Task '\Microsoft\Windows\Flighting\OneSettings\RefreshCache'
        Add-AcceptanceResult 'protected.task.onesettings-refreshcache' 'Protected' $true $(if ($oneSettingsTask.Present -and $oneSettingsTask.Enabled) { 'Pass' } else { 'Fail' }) ([string]$oneSettingsTask.Evidence)
    } catch { Add-AcceptanceResult 'protected.task.onesettings-refreshcache' 'Protected' $true 'Fail' $_.Exception.Message }
    Test-Command 'protected.mitigations' 'Protected' $true 'powershell.exe' @('-NoProfile', '-NonInteractive', '-Command', 'Get-ProcessMitigation -System')

    $developerCommands = [ordered]@{
        'developer.git' = @('git.exe', '--version'); 'developer.powershell' = @('pwsh.exe', '--version')
        'developer.node' = @('node.exe', '--version'); 'developer.bun' = @('bun.exe', '--version')
        'developer.python' = @('python.exe', '--version'); 'developer.rust' = @('rustc.exe', '--version')
        'developer.cargo' = @('cargo.exe', '--version'); 'developer.buildtools' = @('where.exe', 'MSBuild.exe')
        'developer.cuda' = @('nvidia-smi.exe', '--query-gpu=name,driver_version', '--format=csv,noheader')
        'developer.onnx' = @('python.exe', '-c', 'import onnxruntime; print(onnxruntime.__version__)')
        'developer.directml' = @('python.exe', '-c', 'import onnxruntime as o; assert "DmlExecutionProvider" in o.get_available_providers()')
    }
    foreach ($entry in $developerCommands.GetEnumerator()) {
        Test-Command $entry.Key 'Developer' ($Depth -eq 'Release') $entry.Value[0] @($entry.Value | Select-Object -Skip 1)
    }

    $commercial = @(
        @{ Id = 'daw.ableton'; Value = $AbletonPath; Kind = 'File' },
        @{ Id = 'daw.vst3'; Value = @($Vst3Path); Kind = 'Paths' },
        @{ Id = 'daw.latencymon'; Value = $LatencyMonReportPath; Kind = 'File' },
        @{ Id = 'daw.smoke'; Value = $SmokeCommand; Kind = 'Command' }
    )
    foreach ($entry in $commercial) {
        $required = $Depth -eq 'Release'
        if (-not $entry.Value -or @($entry.Value).Count -eq 0) {
            Add-AcceptanceResult $entry.Id 'DAW' $required 'NotRun' 'Evidence hook not supplied.'
            continue
        }
        if ($entry.Kind -eq 'Paths') {
            $pathProbes = @($entry.Value | ForEach-Object { & $ProbeProvider.File $_ })
            Add-AcceptanceResult $entry.Id 'DAW' $required $(if (@($pathProbes | Where-Object { -not $_.Present }).Count -eq 0) { 'Pass' } else { 'Fail' }) (($pathProbes.Evidence) -join '; ')
        } elseif ($entry.Kind -eq 'Command') {
            Test-Command $entry.Id 'DAW' $required 'powershell.exe' @('-NoProfile', '-NonInteractive', '-Command', [string]$entry.Value)
        } else {
            Test-Presence $entry.Id 'DAW' $required 'File' @([string]$entry.Value) $true
        }
    }
    Test-Command 'daw.asio' 'DAW' ($Depth -eq 'Release') 'powershell.exe' @('-NoProfile', '-NonInteractive', '-Command', '$asio = @(Get-ChildItem Registry::HKEY_LOCAL_MACHINE\SOFTWARE\ASIO,Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\ASIO -ErrorAction SilentlyContinue); if ($asio.Count -eq 0) { throw ''No ASIO device registration found.'' }; $asio | Select-Object PSChildName')

    $failedRequired = @($results | Where-Object { $_.Required -and $_.Status -ne 'Pass' })
    $document = [pscustomobject][ordered]@{
        SchemaVersion = '1.0'
        HarnessVersion = '1.5.0'
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        ExpectedState = $ExpectedState
        Depth = $Depth
        IsAccepted = $failedRequired.Count -eq 0
        Summary = [pscustomobject]@{ Passed = @($results | Where-Object Status -eq 'Pass').Count; Failed = @($results | Where-Object Status -eq 'Fail').Count; NotRun = @($results | Where-Object Status -eq 'NotRun').Count; RequiredFailures = $failedRequired.Count }
        Results = @($results)
    }
    $parent = Split-Path -Parent $OutputPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }
    $document | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
    $logPath = [IO.Path]::ChangeExtension($OutputPath, '.log')
    @("WinUtil installed acceptance $($document.HarnessVersion)", "Mode=$ExpectedState Depth=$Depth Accepted=$($document.IsAccepted)") + @($results | ForEach-Object { "[$($_.Status)] required=$($_.Required) $($_.Id): $($_.Evidence)" }) | Set-Content -LiteralPath $logPath -Encoding utf8
    [pscustomobject]@{ IsAccepted = $document.IsAccepted; ExitCode = $(if ($document.IsAccepted) { 0 } else { 1 }); JsonPath = $OutputPath; LogPath = $logPath; Document = $document }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $OutputPath) { throw 'OutputPath is required when invoking the acceptance harness.' }
    $result = Invoke-WinUtilInstalledAcceptance -ExpectedState $ExpectedState -Depth $Depth -OutputPath $OutputPath -AbletonPath $AbletonPath -Vst3Path $Vst3Path -LatencyMonReportPath $LatencyMonReportPath -SmokeCommand $SmokeCommand -PostLoginSmokeCommand $PostLoginSmokeCommand -ProbeProvider $ProbeProvider
    if ($PassThru) { $result }
    exit $result.ExitCode
}
