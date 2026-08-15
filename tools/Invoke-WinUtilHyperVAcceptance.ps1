[CmdletBinding()]
param (
    [string]$IsoPath,
    [string]$UnattendIsoPath,
    [ValidateSet('StockControl', 'LeanDaw')][string]$ExpectedState,
    [ValidateSet('Quick', 'Release')][string]$Depth = 'Release',
    [string]$VMName,
    [string]$SwitchName,
    [string]$VhdPath,
    [string]$OutputDirectory,
    [pscredential]$GuestCredential,
    [ValidateRange(1, 1440)][int]$InstallTimeoutMinutes = 90,
    [ValidateRange(2GB, 128GB)][long]$MemoryStartupBytes = 4GB,
    [ValidateRange(32GB, 2TB)][long]$VhdSizeBytes = 80GB,
    [ValidateRange(1, 64)][int]$ProcessorCount = 4,
    [string]$AbletonPath,
    [string[]]$Vst3Path,
    [string]$LatencyMonReportPath,
    [string]$SmokeCommand,
    [string]$PostLoginSmokeCommand,
    [hashtable]$VMProvider,
    [switch]$KeepVM,
    [switch]$PassThru
)

function Get-WinUtilHyperVProvider {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    @{
        AssertHost = {
            param ($SwitchName)
            Import-Module Hyper-V -ErrorAction Stop
            if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) { throw "Hyper-V switch '$SwitchName' does not exist." }
        }
        AssertTargets = {
            param ($VMName, $VhdPath)
            if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) { throw "VM '$VMName' already exists." }
            if (Test-Path -LiteralPath $VhdPath) { throw "VHD path '$VhdPath' already exists." }
        }
        CreateVM = {
            param ($VMName, $SwitchName, $VhdPath, $VhdSizeBytes, $MemoryStartupBytes, $ProcessorCount, $IsoPath, $UnattendIsoPath)
            $vm = New-VM -Name $VMName -Generation 2 -MemoryStartupBytes $MemoryStartupBytes -NewVHDPath $VhdPath -NewVHDSizeBytes $VhdSizeBytes -SwitchName $SwitchName -ErrorAction Stop
            Set-VMProcessor -VMName $VMName -Count $ProcessorCount -ErrorAction Stop
            Set-VM -VMName $VMName -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -CheckpointType Disabled -ErrorAction Stop
            Enable-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface' -ErrorAction Stop
            $installDrive = Add-VMDvdDrive -VMName $VMName -Path $IsoPath -Passthru -ErrorAction Stop
            Add-VMDvdDrive -VMName $VMName -Path $UnattendIsoPath -ErrorAction Stop | Out-Null
            Set-VMFirmware -VMName $VMName -FirstBootDevice $installDrive -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -ErrorAction Stop
            $vm
        }
        StartVM = { param ($VMName) Start-VM -Name $VMName -ErrorAction Stop | Out-Null }
        GetVMState = { param ($VMName) [string](Get-VM -Name $VMName -ErrorAction Stop).State }
        TestGuestReady = {
            param ($VMName, [pscredential]$GuestCredential)
            try {
                $ready = Invoke-Command -VMName $VMName -Credential $GuestCredential -ScriptBlock { Test-Path -LiteralPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" } -ErrorAction Stop
                [bool]$ready
            } catch { $false }
        }
        CopyToGuest = {
            param ($VMName, [pscredential]$GuestCredential, $SourcePath, $DestinationPath)
            $session = New-PSSession -VMName $VMName -Credential $GuestCredential -ErrorAction Stop
            try {
                Invoke-Command -Session $session -ScriptBlock { New-Item -Path 'C:\ProgramData\WinUtilAcceptance' -ItemType Directory -Force | Out-Null }
                Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -ToSession $session -Force -ErrorAction Stop
            } finally { Remove-PSSession -Session $session }
        }
        InvokeGuestAcceptance = {
            param ($VMName, [pscredential]$GuestCredential, $HarnessPath, $ExpectedState, $Depth, $GuestOutputPath, $AbletonPath, $Vst3Path, $LatencyMonReportPath, $SmokeCommand, $PostLoginSmokeCommand)
            Invoke-Command -VMName $VMName -Credential $GuestCredential -ErrorAction Stop -ScriptBlock {
                param ($HarnessPath, $ExpectedState, $Depth, $GuestOutputPath, $AbletonPath, $Vst3Path, $LatencyMonReportPath, $SmokeCommand, $PostLoginSmokeCommand)
                & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $HarnessPath -ExpectedState $ExpectedState -Depth $Depth -OutputPath $GuestOutputPath -AbletonPath $AbletonPath -Vst3Path $Vst3Path -LatencyMonReportPath $LatencyMonReportPath -SmokeCommand $SmokeCommand -PostLoginSmokeCommand $PostLoginSmokeCommand
                [pscustomobject]@{ ExitCode = $LASTEXITCODE }
            } -ArgumentList $HarnessPath, $ExpectedState, $Depth, $GuestOutputPath, $AbletonPath, $Vst3Path, $LatencyMonReportPath, $SmokeCommand, $PostLoginSmokeCommand
        }
        CopyFromGuest = {
            param ($VMName, [pscredential]$GuestCredential, $SourcePath, $DestinationPath)
            $session = New-PSSession -VMName $VMName -Credential $GuestCredential -ErrorAction Stop
            try { Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -FromSession $session -Force -ErrorAction Stop } finally { Remove-PSSession -Session $session }
        }
        RemoveVM = {
            param ($VMName, $VhdPath)
            $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
            if ($vm) {
                if ($vm.State -ne 'Off') { Stop-VM -Name $VMName -TurnOff -Force -ErrorAction SilentlyContinue }
                Remove-VM -Name $VMName -Force -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $VhdPath) { Remove-Item -LiteralPath $VhdPath -Force -ErrorAction Stop }
        }
        Now = { [DateTime]::UtcNow }
        Delay = { param ($Seconds) Start-Sleep -Seconds $Seconds }
    }
}

function Invoke-WinUtilHyperVAcceptance {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][string]$UnattendIsoPath,
        [Parameter(Mandatory)][ValidateSet('StockControl', 'LeanDaw')][string]$ExpectedState,
        [ValidateSet('Quick', 'Release')][string]$Depth = 'Release',
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$SwitchName,
        [Parameter(Mandatory)][string]$VhdPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [ValidateRange(1, 1440)][int]$InstallTimeoutMinutes = 90,
        [ValidateRange(2GB, 128GB)][long]$MemoryStartupBytes = 4GB,
        [ValidateRange(32GB, 2TB)][long]$VhdSizeBytes = 80GB,
        [ValidateRange(1, 64)][int]$ProcessorCount = 4,
        [string]$AbletonPath,
        [string[]]$Vst3Path,
        [string]$LatencyMonReportPath,
        [string]$SmokeCommand,
        [Parameter(Mandatory)][string]$PostLoginSmokeCommand,
        [hashtable]$VMProvider,
        [switch]$KeepVM
    )

    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) { throw "Generated ISO '$IsoPath' does not exist." }
    if (-not (Test-Path -LiteralPath $UnattendIsoPath -PathType Leaf)) { throw "Unattend ISO '$UnattendIsoPath' does not exist." }
    if (Test-Path -LiteralPath $OutputDirectory) {
        if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw "Output directory '$OutputDirectory' must be empty to prevent stale evidence." }
    } else { New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null }
    if (-not $VMProvider) { $VMProvider = Get-WinUtilHyperVProvider }
    foreach ($boundary in @('AssertHost', 'AssertTargets', 'CreateVM', 'StartVM', 'GetVMState', 'TestGuestReady', 'CopyToGuest', 'InvokeGuestAcceptance', 'CopyFromGuest', 'RemoveVM', 'Now', 'Delay')) {
        if (-not $VMProvider.ContainsKey($boundary) -or $VMProvider[$boundary] -isnot [scriptblock]) { throw "VMProvider boundary '$boundary' must be a scriptblock." }
    }

    $logPath = Join-Path $OutputDirectory 'hyperv-acceptance.log'
    $provisioningAttempted = $false
    $accepted = $false
    $failure = $null
    try {
        & $VMProvider.AssertHost $SwitchName
        & $VMProvider.AssertTargets $VMName $VhdPath
        $isoHash = (Get-FileHash -LiteralPath $IsoPath -Algorithm SHA256).Hash
        $unattendHash = (Get-FileHash -LiteralPath $UnattendIsoPath -Algorithm SHA256).Hash
        Add-Content -LiteralPath $logPath -Value "[$(& $VMProvider.Now)] Creating VM '$VMName' from '$IsoPath' SHA256=$isoHash; answer ISO SHA256=$unattendHash."
        $provisioningAttempted = $true
        & $VMProvider.CreateVM $VMName $SwitchName $VhdPath $VhdSizeBytes $MemoryStartupBytes $ProcessorCount $IsoPath $UnattendIsoPath | Out-Null
        & $VMProvider.StartVM $VMName
        Add-Content -LiteralPath $logPath -Value "[$(& $VMProvider.Now)] VM started; waiting for clean install and PowerShell Direct."

        $deadline = (& $VMProvider.Now).AddMinutes($InstallTimeoutMinutes)
        $guestReady = $false
        while ((& $VMProvider.Now) -lt $deadline) {
            $state = & $VMProvider.GetVMState $VMName
            if ($state -eq 'Off') { throw "VM '$VMName' powered off before guest acceptance became available." }
            if (& $VMProvider.TestGuestReady $VMName $GuestCredential) { $guestReady = $true; break }
            & $VMProvider.Delay 10
        }
        if (-not $guestReady) { throw "Timed out after $InstallTimeoutMinutes minute(s) waiting for clean Windows installation in VM '$VMName'." }

        $hostHarnessPath = Join-Path $PSScriptRoot 'Invoke-WinUtilInstalledAcceptance.ps1'
        if (-not (Test-Path -LiteralPath $hostHarnessPath -PathType Leaf)) { throw "Installed acceptance harness '$hostHarnessPath' is missing." }
        $guestRoot = 'C:\ProgramData\WinUtilAcceptance'
        $guestHarnessPath = "$guestRoot\Invoke-WinUtilInstalledAcceptance.ps1"
        $guestJsonPath = "$guestRoot\installed-acceptance.json"
        $guestLogPath = "$guestRoot\installed-acceptance.log"
        & $VMProvider.CopyToGuest $VMName $GuestCredential $hostHarnessPath $guestHarnessPath
        $guestResult = & $VMProvider.InvokeGuestAcceptance $VMName $GuestCredential $guestHarnessPath $ExpectedState $Depth $guestJsonPath $AbletonPath $Vst3Path $LatencyMonReportPath $SmokeCommand $PostLoginSmokeCommand
        & $VMProvider.CopyFromGuest $VMName $GuestCredential $guestJsonPath (Join-Path $OutputDirectory 'installed-acceptance.json')
        & $VMProvider.CopyFromGuest $VMName $GuestCredential $guestLogPath (Join-Path $OutputDirectory 'installed-acceptance.log')

        $hostJsonPath = Join-Path $OutputDirectory 'installed-acceptance.json'
        $hostLogPath = Join-Path $OutputDirectory 'installed-acceptance.log'
        if (-not (Test-Path -LiteralPath $hostJsonPath -PathType Leaf) -or -not (Test-Path -LiteralPath $hostLogPath -PathType Leaf)) { throw 'Guest acceptance evidence was not retrieved completely.' }
        try { $document = Get-Content -LiteralPath $hostJsonPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch { throw "Guest acceptance JSON is invalid: $($_.Exception.Message)" }
        if ([int]$guestResult.ExitCode -ne 0 -or $document.IsAccepted -ne $true) { throw "Guest installed acceptance failed with exit code $($guestResult.ExitCode)." }
        $accepted = $true
        Add-Content -LiteralPath $logPath -Value "[$(& $VMProvider.Now)] Guest installed acceptance passed."
    } catch {
        $failure = $_.Exception.Message
        Add-Content -LiteralPath $logPath -Value "[$(& $VMProvider.Now)] FAILED: $failure"
    } finally {
        if ($provisioningAttempted -and -not $KeepVM) {
            try { & $VMProvider.RemoveVM $VMName $VhdPath; Add-Content -LiteralPath $logPath -Value "[$(& $VMProvider.Now)] Removed test VM and VHD." } catch {
                $accepted = $false
                $cleanupFailure = "Cleanup failed: $($_.Exception.Message)"
                $failure = if ($failure) { "$failure $cleanupFailure" } else { $cleanupFailure }
                Add-Content -LiteralPath $logPath -Value "[$(& $VMProvider.Now)] FAILED: $cleanupFailure"
            }
        }
    }
    [pscustomobject]@{ IsAccepted = $accepted; ExitCode = $(if ($accepted) { 0 } else { 1 }); Failure = $failure; OutputDirectory = $OutputDirectory; LogPath = $logPath; VMName = $VMName; VMRetained = [bool]$KeepVM }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-WinUtilHyperVAcceptance -IsoPath $IsoPath -UnattendIsoPath $UnattendIsoPath -ExpectedState $ExpectedState -Depth $Depth -VMName $VMName -SwitchName $SwitchName -VhdPath $VhdPath -OutputDirectory $OutputDirectory -GuestCredential $GuestCredential -InstallTimeoutMinutes $InstallTimeoutMinutes -MemoryStartupBytes $MemoryStartupBytes -VhdSizeBytes $VhdSizeBytes -ProcessorCount $ProcessorCount -AbletonPath $AbletonPath -Vst3Path $Vst3Path -LatencyMonReportPath $LatencyMonReportPath -SmokeCommand $SmokeCommand -PostLoginSmokeCommand $PostLoginSmokeCommand -VMProvider $VMProvider -KeepVM:$KeepVM
    if ($PassThru) { $result }
    exit $result.ExitCode
}
