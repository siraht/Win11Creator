[CmdletBinding()]
param (
    [ValidateSet('StockControl', 'LeanDaw')][string]$ExpectedState = 'StockControl',
    [ValidateSet('Quick', 'Release')][string]$Depth = 'Quick',
    [string]$OutputPath,
    [string]$AbletonPath,
    [string[]]$Vst3Path,
    [string]$LatencyMonReportPath,
    [string]$SmokeCommand,
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
            [pscustomobject]@{ Present = $LASTEXITCODE -eq 0 -and $result -match 'State\s*:'; Evidence = $result.Trim() }
        }
        File = {
            param ([string]$Path)
            $present = Test-Path -LiteralPath $Path
            $version = if ($present) { [Diagnostics.FileVersionInfo]::GetVersionInfo($Path).FileVersion } else { $null }
            [pscustomobject]@{ Present = $present; Evidence = "$Path version=$version" }
        }
        Registration = {
            param ([string]$Target)
            switch ($Target) {
                'Start' { $value = @(Get-AppxPackage -AllUsers -Name 'Microsoft.Windows.StartMenuExperienceHost' -ErrorAction SilentlyContinue).Count -gt 0 }
                'Explorer' { $value = Test-Path -LiteralPath "$env:SystemRoot\explorer.exe" }
                'Settings' { $value = Test-Path -LiteralPath 'Registry::HKEY_CLASSES_ROOT\ms-settings' }
                'WebView2' { $value = Test-Path -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F1E7E5A1-5E70-4A20-BA76-02E5215AC9F5}' }
                default { $value = $false }
            }
            [pscustomobject]@{ Present = $value; Evidence = "$Target registration=$value" }
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
        [hashtable]$ProbeProvider
    )

    if (-not $ProbeProvider) { $ProbeProvider = Get-WinUtilInstalledProbeProvider }
    foreach ($boundary in @('Command', 'Registry', 'Appx', 'Service', 'Feature', 'File', 'Registration')) {
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
        param ([string]$Id, [string]$Area, [bool]$Required, [string]$FilePath, [string[]]$Arguments)
        try {
            $probe = & $ProbeProvider.Command $FilePath $Arguments
            Add-AcceptanceResult $Id $Area $Required $(if ($probe.Success) { 'Pass' } else { 'Fail' }) ([string]$probe.Evidence)
        } catch {
            Add-AcceptanceResult $Id $Area $Required 'Fail' $_.Exception.Message
        }
    }

    Test-Command 'servicing.dism-checkhealth' 'Servicing' $true 'dism.exe' @('/Online', '/Cleanup-Image', '/CheckHealth')
    if ($Depth -eq 'Release') {
        Test-Command 'servicing.dism-scanhealth' 'Servicing' $true 'dism.exe' @('/Online', '/Cleanup-Image', '/ScanHealth')
        Test-Command 'servicing.component-cleanup' 'Servicing' $true 'dism.exe' @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    } else {
        Add-AcceptanceResult 'servicing.dism-scanhealth' 'Servicing' $false 'NotRun' 'Release-depth probe.'
        Add-AcceptanceResult 'servicing.component-cleanup' 'Servicing' $false 'NotRun' 'Release-depth probe.'
    }
    Test-Command 'servicing.winre' 'Servicing' ($Depth -eq 'Release') 'reagentc.exe' @('/info')
    foreach ($serviceName in @('wuauserv', 'BITS', 'UsoSvc', 'WaaSMedicSvc')) {
        Test-Presence "update.service.$($serviceName.ToLowerInvariant())" 'WindowsUpdate' $true 'Service' @($serviceName) $true
    }
    Test-Command 'update.scan' 'WindowsUpdate' $true 'powershell.exe' @('-NoProfile', '-NonInteractive', '-Command', '$session = New-Object -ComObject Microsoft.Update.Session; $search = $session.CreateUpdateSearcher().Search(''IsInstalled=0 and IsHidden=0''); "UpdateScan count=$($search.Updates.Count) result=$($search.ResultCode)"')

    foreach ($registration in @('Start', 'Explorer', 'Settings', 'WebView2')) {
        Test-Presence "core.$($registration.ToLowerInvariant())" 'CoreWindows' $true 'Registration' @($registration) $true
    }
    Test-Command 'core.terminal' 'CoreWindows' $true 'wt.exe' @('--version')
    Test-Command 'core.winget' 'CoreWindows' $true 'winget.exe' @('--info')
    Test-Presence 'core.store' 'CoreWindows' $true 'Appx' @('Microsoft.WindowsStore') $true
    Test-Presence 'core.appinstaller' 'CoreWindows' $true 'Appx' @('Microsoft.DesktopAppInstaller') $true

    $lean = $ExpectedState -eq 'LeanDaw'
    $removalAppx = [ordered]@{
        'removal.bing' = 'Microsoft.Bing*'; 'removal.widgets' = 'MicrosoftWindows.Client.WebExperience'
        'removal.webexperience' = 'MicrosoftWindows.Client.WebExperience'
        'removal.copilot' = 'Microsoft.Copilot'; 'removal.feedback' = 'Microsoft.WindowsFeedbackHub'
        'removal.ai' = '*AI*'; 'removal.xbox' = 'Microsoft.Xbox*'; 'removal.consumer-appx' = 'Microsoft.Clipchamp*'
    }
    foreach ($entry in $removalAppx.GetEnumerator()) {
        Test-Presence $entry.Key 'DeclaredState' $true 'Appx' @($entry.Value) (-not $lean)
    }
    foreach ($entry in @(
        @{ Id = 'removal.search'; Name = 'WSearch' }, @{ Id = 'removal.defender'; Name = 'WinDefend' },
        @{ Id = 'removal.telemetry'; Name = 'DiagTrack' }
    )) {
        Test-Presence $entry.Id 'DeclaredState' $true 'Service' @($entry.Name) (-not $lean)
    }
    $registryStates = @(
        @{ Id = 'removal.smartscreen'; Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'EnableSmartScreen'; LeanValue = 0 },
        @{ Id = 'removal.uac'; Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'EnableLUA'; LeanValue = 0 },
        @{ Id = 'removal.gamedvr'; Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name = 'AllowGameDVR'; LeanValue = 0 },
        @{ Id = 'removal.consumer-content'; Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures'; LeanValue = 1 }
    )
    foreach ($entry in $registryStates) {
        try {
            $probe = & $ProbeProvider.Registry $entry.Path $entry.Name
            $stateMatches = if ($lean) { $probe.Exists -and $probe.Value -eq $entry.LeanValue } else { -not $probe.Exists -or $probe.Value -ne $entry.LeanValue }
            Add-AcceptanceResult $entry.Id 'DeclaredState' $true $(if ($stateMatches) { 'Pass' } else { 'Fail' }) ([string]$probe.Evidence)
        } catch { Add-AcceptanceResult $entry.Id 'DeclaredState' $true 'Fail' $_.Exception.Message }
    }
    Test-Presence 'removal.onedrive' 'DeclaredState' $true 'File' @("$env:SystemRoot\SysWOW64\OneDriveSetup.exe") (-not $lean)

    foreach ($featureName in @('ServicesForNFS-ClientOnly', 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform', 'Microsoft-Hyper-V-All')) {
        Test-Presence "protected.feature.$($featureName.ToLowerInvariant())" 'Protected' $true 'Feature' @($featureName) $true
    }
    foreach ($serviceName in @('WerSvc', 'PcaSvc', 'SysMain')) {
        Test-Presence "protected.service.$($serviceName.ToLowerInvariant())" 'Protected' $true 'Service' @($serviceName) $true
    }
    Test-Presence 'protected.onesettings' 'Protected' $true 'Appx' @('*OneSettings*') $true
    Test-Presence 'protected.featureconfig' 'Protected' $true 'File' @("$env:SystemRoot\System32\FeatureConfigManager.dll") $true
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
        HarnessVersion = '1.0.0'
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
    $result = Invoke-WinUtilInstalledAcceptance -ExpectedState $ExpectedState -Depth $Depth -OutputPath $OutputPath -AbletonPath $AbletonPath -Vst3Path $Vst3Path -LatencyMonReportPath $LatencyMonReportPath -SmokeCommand $SmokeCommand -ProbeProvider $ProbeProvider
    if ($PassThru) { $result }
    exit $result.ExitCode
}
