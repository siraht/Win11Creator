[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'
$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:PowerShellExe = if ($env:SystemRoot) {
    Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
} else {
    'powershell.exe'
}
. (Join-Path $script:RepositoryRoot 'tools/Invoke-WinUtilWindowsBuild.ps1')
. (Join-Path $script:RepositoryRoot 'tools/Invoke-WinUtilIsoRepair.ps1')

function Test-WinUtilAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-WinUtilAdministrator {
    if (Test-WinUtilAdministrator) { return $true }

    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    try {
        Start-Process -FilePath $script:PowerShellExe -ArgumentList $arguments -Verb RunAs | Out-Null
        return $false
    } catch {
        throw 'Administrator approval is required to service a Windows image.'
    }
}

function Show-WinUtilMessage {
    param (
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Title,
        [ValidateSet('Information', 'Warning', 'Error')][string]$Icon = 'Information'
    )

    [System.Windows.Forms.MessageBox]::Show(
        $Text,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        ([System.Windows.Forms.MessageBoxIcon]$Icon)
    ) | Out-Null
}

function Get-WinUtilLauncherProfile {
    $definitions = @(
        [pscustomobject]@{
            Id = 'lean-daw-defender-retained'; IsAvailable = $true; ExpertMode = $true
            SuggestedFileName = 'Win11-Lean-DAW-Defender-Retained.iso'; UnavailableReason = ''
        }
        [pscustomobject]@{
            Id = 'default-winutil'; IsAvailable = $true; ExpertMode = $false
            SuggestedFileName = 'Win11-Default-WinUtil.iso'; UnavailableReason = ''
        }
        [pscustomobject]@{
            Id = 'lean-daw'; IsAvailable = $false; ExpertMode = $true
            SuggestedFileName = 'Win11-Lean-DAW.iso'
            UnavailableReason = 'Unavailable: Windows 11 25H2 exposes no supported removable Defender AV-core target. Choose the Defender-retained profile.'
        }
    )

    foreach ($definition in $definitions) {
        $profilePath = Join-Path (Join-Path $script:RepositoryRoot 'policy/profiles') "$($definition.Id).json"
        $profileDocument = Get-Content -LiteralPath $profilePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        [pscustomobject][ordered]@{
            Id = $definition.Id
            Name = [string]$profileDocument.name
            Description = [string]$profileDocument.description
            IsAvailable = [bool]$definition.IsAvailable
            ExpertMode = [bool]$definition.ExpertMode
            SuggestedFileName = [string]$definition.SuggestedFileName
            UnavailableReason = [string]$definition.UnavailableReason
        }
    }
}

function Confirm-WinUtilOutputCapacity {
    param ([Parameter(Mandatory)][string]$OutputIsoPath)

    try {
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($OutputIsoPath))
        $drive = [IO.DriveInfo]::new($root)
        $availableGiB = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    } catch {
        return $true
    }
    if ($availableGiB -ge 50) { return $true }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "The selected drive has only $availableGiB GB free. A safe build normally needs at least 50 GB.`n`nContinue anyway?",
        'Low disk space',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return $answer -eq [System.Windows.Forms.DialogResult]::Yes
}

function Find-WinUtilOscdimg {
    $command = Get-Command oscdimg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }

    $roots = @(
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Windows Kits' })
        $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages' })
    )
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $match = Get-ChildItem -LiteralPath $root -Recurse -Filter oscdimg.exe -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($match) { return $match.FullName }
    }
    return ''
}

function Install-WinUtilOscdimg {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Microsoft's ISO packaging tool is not installed. Install it automatically with WinGet?",
        'Install ISO packaging tool',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return '' }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'WinGet is unavailable. Install Windows ADK Deployment Tools, then reopen Build-LeanDAW.cmd.'
    }
    & $winget.Source install --exact --id Microsoft.OSCDIMG --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "WinGet could not install oscdimg (exit code $LASTEXITCODE)." }
    Find-WinUtilOscdimg
}

function Get-WinUtilSupportedEdition {
    param (
        [Parameter(Mandatory)][string]$SourceIsoPath,
        [Parameter(Mandatory)][hashtable]$BuildProvider
    )

    $mounted = $false
    try {
        $mediaRoot = & $BuildProvider.MountIso $SourceIsoPath
        $mounted = $true
        $sourceImage = Get-WinUtilInstallImage -MediaRoot $mediaRoot
        $metadata = @(& $BuildProvider.GetImageMetadata $sourceImage.Path)
        $support = Test-WinUtilWindowsImageSupport -ImageMetadata $metadata
        if (-not $support.IsSupported) { throw "Unsupported source media: $($support.Reason)" }
        return @($support.Editions)
    } finally {
        if ($mounted) { & $BuildProvider.DismountIso $SourceIsoPath }
    }
}

function Get-WinUtilBuildProgress {
    param (
        [AllowEmptyString()][string]$LogText = '',
        [switch]$IsComplete
    )

    if ($IsComplete) { return [pscustomobject]@{ Percent = 100; Stage = 'Complete'; Detail = 'ISO and evidence are ready.' } }
    $stages = @(
        @{ Pattern = 'Repaired ISO creation completed'; Percent = 99; Stage = 'Finalizing'; Detail = 'Cleaning temporary repair files.' }
        @{ Pattern = 'Build artifact and evidence publication completed'; Percent = 99; Stage = 'Finalizing'; Detail = 'Cleaning temporary build files.' }
        @{ Pattern = 'hashing output and publishing build evidence'; Percent = 95; Stage = 'Verifying'; Detail = 'Hashing the ISO and publishing evidence.' }
        @{ Pattern = 'Creating the bootable ISO'; Percent = 88; Stage = 'Packaging'; Detail = 'Creating the bootable ISO.' }
        @{ Pattern = 'Creating the repaired dual BIOS/UEFI bootable ISO'; Percent = 80; Stage = 'Packaging'; Detail = 'Repackaging the repaired bootable ISO.' }
        @{ Pattern = 'Committing the offline servicing transaction'; Percent = 78; Stage = 'Committing'; Detail = 'Saving the serviced Windows image.' }
        @{ Pattern = 'component-store-scan-health completed'; Percent = 73; Stage = 'Health checks'; Detail = 'Deep component-store scan passed.' }
        @{ Pattern = 'component-store-check-health completed'; Percent = 69; Stage = 'Health checks'; Detail = 'Component-store health check passed.' }
        @{ Pattern = 'component-cleanup completed'; Percent = 63; Stage = 'Servicing'; Detail = 'Component cleanup completed.' }
        @{ Pattern = 'Written autounattend.xml'; Percent = 52; Stage = 'Servicing'; Detail = 'Applying offline policy and setup actions.' }
        @{ Pattern = 'Resolved .* offline mutations ready'; Percent = 42; Stage = 'Planning'; Detail = 'Resolved profile and safety policy.' }
        @{ Pattern = 'Applied and verified repair'; Percent = 65; Stage = 'Repairing'; Detail = 'The selected ISO repair was applied and verified.' }
        @{ Pattern = 'Copied source media and released'; Percent = 40; Stage = 'Inspecting'; Detail = 'Source media copied and ready for repair.' }
        @{ Pattern = 'Mounting copied install.wim'; Percent = 32; Stage = 'Analyzing'; Detail = 'Mounting and inventorying the selected edition.' }
        @{ Pattern = 'Copied Windows setup media'; Percent = 27; Stage = 'Preparing media'; Detail = 'Source media copy completed.' }
        @{ Pattern = 'Copying Windows setup media'; Percent = 15; Stage = 'Preparing media'; Detail = 'Copying Windows setup files.' }
        @{ Pattern = 'Copying ISO contents into the isolated repair workspace'; Percent = 20; Stage = 'Preparing media'; Detail = 'Copying the existing ISO without servicing its Windows image.' }
        @{ Pattern = 'Validated source edition'; Percent = 10; Stage = 'Validating'; Detail = 'Source edition is supported.' }
        @{ Pattern = 'Starting ISO repair'; Percent = 5; Stage = 'Starting'; Detail = 'Preparing the isolated repair workspace.' }
        @{ Pattern = 'Starting noninteractive'; Percent = 5; Stage = 'Starting'; Detail = 'Preparing the isolated build workspace.' }
    )
    foreach ($stage in $stages) {
        if ($LogText -match $stage.Pattern) {
            return [pscustomobject]@{ Percent = $stage.Percent; Stage = $stage.Stage; Detail = $stage.Detail }
        }
    }
    [pscustomobject]@{ Percent = 2; Stage = 'Starting'; Detail = 'Initializing the build.' }
}

function Get-WinUtilBuildForm {
    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'Win11 Creator - ISO Builder'
    $form.StartPosition = 'CenterScreen'
    $form.Size = [Drawing.Size]::new(1040, 820)
    $form.MinimumSize = [Drawing.Size]::new(940, 720)
    $form.BackColor = [Drawing.Color]::FromArgb(245, 247, 250)
    $form.Font = [Drawing.Font]::new('Segoe UI', 9)

    $header = [System.Windows.Forms.Panel]::new()
    $header.Dock = 'Top'
    $header.Height = 82
    $header.BackColor = [Drawing.Color]::FromArgb(24, 35, 58)
    $form.Controls.Add($header)

    $title = [System.Windows.Forms.Label]::new()
    $title.Text = 'Build a Windows 11 Creator ISO'
    $title.ForeColor = [Drawing.Color]::White
    $title.Font = [Drawing.Font]::new('Segoe UI Semibold', 20)
    $title.AutoSize = $true
    $title.Location = [Drawing.Point]::new(22, 13)
    $header.Controls.Add($title)

    $subtitle = [System.Windows.Forms.Label]::new()
    $subtitle.Text = 'Configure, track, verify, and open the finished image from one window.'
    $subtitle.ForeColor = [Drawing.Color]::FromArgb(194, 204, 220)
    $subtitle.AutoSize = $true
    $subtitle.Location = [Drawing.Point]::new(25, 51)
    $header.Controls.Add($subtitle)

    $taskLabel = [System.Windows.Forms.Label]::new()
    $taskLabel.Text = 'Task'
    $taskLabel.ForeColor = [Drawing.Color]::FromArgb(194, 204, 220)
    $taskLabel.Location = [Drawing.Point]::new(720, 12)
    $taskLabel.Size = [Drawing.Size]::new(55, 22)
    $taskLabel.Anchor = 'Top, Right'
    $header.Controls.Add($taskLabel)

    $taskBox = [System.Windows.Forms.ComboBox]::new()
    $taskBox.DropDownStyle = 'DropDownList'
    $taskBox.Items.AddRange(@('Build customized ISO', 'Repair existing ISO'))
    $taskBox.Location = [Drawing.Point]::new(775, 9)
    $taskBox.Size = [Drawing.Size]::new(205, 28)
    $taskBox.Anchor = 'Top, Right'
    $header.Controls.Add($taskBox)

    $configuration = [System.Windows.Forms.GroupBox]::new()
    $configuration.Text = 'Build configuration'
    $configuration.Location = [Drawing.Point]::new(18, 94)
    $configuration.Size = [Drawing.Size]::new(986, 260)
    $configuration.Anchor = 'Top, Left, Right'
    $form.Controls.Add($configuration)

    function Add-ConfigurationRow {
        param ([string]$Label, [int]$Y, $Control, $Button)
        $rowLabel = [System.Windows.Forms.Label]::new()
        $rowLabel.Text = $Label
        $rowLabel.Location = [Drawing.Point]::new(16, $Y + 5)
        $rowLabel.Size = [Drawing.Size]::new(110, 24)
        $configuration.Controls.Add($rowLabel)
        $Control.Location = [Drawing.Point]::new(128, $Y)
        $Control.Size = [Drawing.Size]::new(708, 27)
        $Control.Anchor = 'Top, Left, Right'
        $configuration.Controls.Add($Control)
        if ($Button) {
            $Button.Location = [Drawing.Point]::new(850, $Y - 1)
            $Button.Size = [Drawing.Size]::new(116, 29)
            $Button.Anchor = 'Top, Right'
            $configuration.Controls.Add($Button)
        }
        return $rowLabel
    }

    $sourceBox = [System.Windows.Forms.TextBox]::new()
    $sourceBox.ReadOnly = $true
    $sourceButton = [System.Windows.Forms.Button]::new()
    $sourceButton.Text = 'Choose ISO...'
    $null = Add-ConfigurationRow -Label 'Source ISO' -Y 28 -Control $sourceBox -Button $sourceButton

    $editionBox = [System.Windows.Forms.ComboBox]::new()
    $editionBox.DropDownStyle = 'DropDownList'
    $analyzeButton = [System.Windows.Forms.Button]::new()
    $analyzeButton.Text = 'Analyze ISO'
    $analyzeButton.Enabled = $false
    $editionLabel = Add-ConfigurationRow -Label 'Windows edition' -Y 66 -Control $editionBox -Button $analyzeButton

    $profileBox = [System.Windows.Forms.ComboBox]::new()
    $profileBox.DropDownStyle = 'DropDownList'
    $profileBox.DisplayMember = 'Name'
    $profileLabel = Add-ConfigurationRow -Label 'Profile' -Y 104 -Control $profileBox -Button $null

    $outputBox = [System.Windows.Forms.TextBox]::new()
    $outputBox.ReadOnly = $true
    $outputButton = [System.Windows.Forms.Button]::new()
    $outputButton.Text = 'Choose output...'
    $null = Add-ConfigurationRow -Label 'Output ISO' -Y 142 -Control $outputBox -Button $outputButton

    $driversBox = [System.Windows.Forms.TextBox]::new()
    $driversBox.ReadOnly = $true
    $driversButton = [System.Windows.Forms.Button]::new()
    $driversButton.Text = 'Optional...'
    $driversLabel = Add-ConfigurationRow -Label 'Driver folder' -Y 180 -Control $driversBox -Button $driversButton

    $profileSummary = [System.Windows.Forms.Label]::new()
    $profileSummary.Location = [Drawing.Point]::new(128, 216)
    $profileSummary.Size = [Drawing.Size]::new(838, 36)
    $profileSummary.Anchor = 'Top, Left, Right'
    $profileSummary.ForeColor = [Drawing.Color]::FromArgb(61, 70, 89)
    $configuration.Controls.Add($profileSummary)

    $progressPanel = [System.Windows.Forms.Panel]::new()
    $progressPanel.Location = [Drawing.Point]::new(18, 368)
    $progressPanel.Size = [Drawing.Size]::new(986, 104)
    $progressPanel.Anchor = 'Top, Left, Right'
    $progressPanel.BackColor = [Drawing.Color]::White
    $form.Controls.Add($progressPanel)

    $stageLabel = [System.Windows.Forms.Label]::new()
    $stageLabel.Text = 'Ready to configure'
    $stageLabel.Font = [Drawing.Font]::new('Segoe UI Semibold', 12)
    $stageLabel.Location = [Drawing.Point]::new(15, 11)
    $stageLabel.Size = [Drawing.Size]::new(700, 26)
    $progressPanel.Controls.Add($stageLabel)

    $detailLabel = [System.Windows.Forms.Label]::new()
    $detailLabel.Text = 'Choose a source ISO, analyze its editions, and select an output location.'
    $detailLabel.ForeColor = [Drawing.Color]::FromArgb(92, 101, 116)
    $detailLabel.Location = [Drawing.Point]::new(17, 38)
    $detailLabel.Size = [Drawing.Size]::new(950, 22)
    $detailLabel.Anchor = 'Top, Left, Right'
    $progressPanel.Controls.Add($detailLabel)

    $progressBar = [System.Windows.Forms.ProgressBar]::new()
    $progressBar.Location = [Drawing.Point]::new(17, 69)
    $progressBar.Size = [Drawing.Size]::new(950, 18)
    $progressBar.Anchor = 'Top, Left, Right'
    $progressPanel.Controls.Add($progressBar)

    $logLabel = [System.Windows.Forms.Label]::new()
    $logLabel.Text = 'Live build log'
    $logLabel.Font = [Drawing.Font]::new('Segoe UI Semibold', 10)
    $logLabel.Location = [Drawing.Point]::new(18, 485)
    $logLabel.AutoSize = $true
    $form.Controls.Add($logLabel)

    $logBox = [System.Windows.Forms.RichTextBox]::new()
    $logBox.Location = [Drawing.Point]::new(18, 510)
    $logBox.Size = [Drawing.Size]::new(986, 210)
    $logBox.Anchor = 'Top, Bottom, Left, Right'
    $logBox.ReadOnly = $true
    $logBox.BackColor = [Drawing.Color]::FromArgb(20, 25, 35)
    $logBox.ForeColor = [Drawing.Color]::FromArgb(218, 225, 235)
    $logBox.Font = [Drawing.Font]::new('Consolas', 9)
    $logBox.Text = "Waiting for configuration.`r`n"
    $form.Controls.Add($logBox)

    $buildButton = [System.Windows.Forms.Button]::new()
    $buildButton.Text = 'Build ISO'
    $buildButton.Font = [Drawing.Font]::new('Segoe UI Semibold', 10)
    $buildButton.BackColor = [Drawing.Color]::FromArgb(40, 112, 224)
    $buildButton.ForeColor = [Drawing.Color]::White
    $buildButton.FlatStyle = 'Flat'
    $buildButton.Location = [Drawing.Point]::new(18, 734)
    $buildButton.Size = [Drawing.Size]::new(150, 38)
    $buildButton.Anchor = 'Bottom, Left'
    $form.Controls.Add($buildButton)

    $openIsoButton = [System.Windows.Forms.Button]::new()
    $openIsoButton.Text = 'Open ISO location'
    $openIsoButton.Enabled = $false
    $openIsoButton.Location = [Drawing.Point]::new(180, 734)
    $openIsoButton.Size = [Drawing.Size]::new(150, 38)
    $openIsoButton.Anchor = 'Bottom, Left'
    $form.Controls.Add($openIsoButton)

    $openEvidenceButton = [System.Windows.Forms.Button]::new()
    $openEvidenceButton.Text = 'Open evidence'
    $openEvidenceButton.Enabled = $false
    $openEvidenceButton.Location = [Drawing.Point]::new(342, 734)
    $openEvidenceButton.Size = [Drawing.Size]::new(150, 38)
    $openEvidenceButton.Anchor = 'Bottom, Left'
    $form.Controls.Add($openEvidenceButton)

    $state = [pscustomobject]@{
        Build = $null
        Editions = @()
        AnalyzedSource = ''
        LastLog = ''
        LastSuggestedOutput = ''
        Mode = 'Build'
        RepairInspection = $null
    }

    $profiles = @(Get-WinUtilLauncherProfile)
    $repairs = @(Get-WinUtilIsoRepairDefinition)
    foreach ($profileOption in $profiles) { [void]$profileBox.Items.Add($profileOption) }
    $profileBox.SelectedIndex = 0
    $taskBox.SelectedIndex = 0

    $setStatus = {
        param ([string]$Stage, [string]$Detail, [Drawing.Color]$Color)
        $stageLabel.Text = $Stage
        $stageLabel.ForeColor = $Color
        $detailLabel.Text = $Detail
    }.GetNewClosure()

    $updateReady = {
        $selection = $profileBox.SelectedItem
        $sourceReady = $sourceBox.Text -and $state.AnalyzedSource -eq $sourceBox.Text
        if ($state.Mode -eq 'Build') { $sourceReady = $sourceReady -and $editionBox.SelectedIndex -ge 0 }
        $outputReady = -not [string]::IsNullOrWhiteSpace($outputBox.Text)
        $selectionReady = $selection -and ($state.Mode -eq 'Repair' -or $selection.IsAvailable)
        $buildButton.Enabled = $null -eq $state.Build -and $sourceReady -and $outputReady -and $selectionReady
    }.GetNewClosure()

    $updateProfile = {
        $selection = $profileBox.SelectedItem
        if (-not $selection) { return }
        if ($state.Mode -eq 'Repair' -or $selection.IsAvailable) {
            $profileSummary.ForeColor = [Drawing.Color]::FromArgb(61, 70, 89)
            $profileSummary.Text = $selection.Description
        } else {
            $profileSummary.ForeColor = [Drawing.Color]::FromArgb(180, 72, 52)
            $profileSummary.Text = $selection.UnavailableReason
        }
        if (-not $outputBox.Text -or $outputBox.Text -eq $state.LastSuggestedOutput) {
            $directory = if ($outputBox.Text) { Split-Path $outputBox.Text -Parent } else { [Environment]::GetFolderPath('Desktop') }
            $suggestedName = if ($state.Mode -eq 'Repair') { 'Win11-Repaired.iso' } else { $selection.SuggestedFileName }
            $state.LastSuggestedOutput = Join-Path $directory $suggestedName
            $outputBox.Text = $state.LastSuggestedOutput
        }
        & $updateReady
    }.GetNewClosure()

    $setMode = {
        $state.Mode = if ($taskBox.SelectedIndex -eq 1) { 'Repair' } else { 'Build' }
        $state.AnalyzedSource = ''
        $state.Editions = @()
        $state.RepairInspection = $null
        $editionBox.Items.Clear()
        $profileBox.Items.Clear()
        if ($state.Mode -eq 'Repair') {
            $editionLabel.Text = 'Repair status'
            $profileLabel.Text = 'Repair operation'
            $driversLabel.Visible = $false
            $driversBox.Visible = $false
            $driversButton.Visible = $false
            $analyzeButton.Text = 'Inspect ISO'
            $buildButton.Text = 'Repair & Repackage'
            foreach ($repairOption in $repairs) { [void]$profileBox.Items.Add($repairOption) }
            & $setStatus 'Ready to inspect' 'Choose the existing customized ISO, inspect it, and choose a new output filename.' ([Drawing.Color]::FromArgb(40, 112, 224))
        } else {
            $editionLabel.Text = 'Windows edition'
            $profileLabel.Text = 'Profile'
            $driversLabel.Visible = $true
            $driversBox.Visible = $true
            $driversButton.Visible = $true
            $analyzeButton.Text = 'Analyze ISO'
            $buildButton.Text = 'Build ISO'
            foreach ($profileOption in $profiles) { [void]$profileBox.Items.Add($profileOption) }
            & $setStatus 'Ready to configure' 'Choose a source ISO, analyze its editions, and select an output location.' ([Drawing.Color]::FromArgb(40, 112, 224))
        }
        if ($profileBox.Items.Count -gt 0) { $profileBox.SelectedIndex = 0 }
        $analyzeButton.Enabled = -not [string]::IsNullOrWhiteSpace($sourceBox.Text)
        & $updateProfile
        & $updateReady
    }.GetNewClosure()

    $setConfigurationEnabled = {
        param ([bool]$Enabled)
        $taskBox.Enabled = $Enabled
        $sourceButton.Enabled = $Enabled
        $analyzeButton.Enabled = $Enabled -and -not [string]::IsNullOrWhiteSpace($sourceBox.Text)
        $profileBox.Enabled = $Enabled
        $outputButton.Enabled = $Enabled
        $driversButton.Enabled = $Enabled
        $editionBox.Enabled = $Enabled
        if (-not $Enabled) { $buildButton.Enabled = $false } else { & $updateReady }
    }.GetNewClosure()

    $sourceButton.Add_Click({
        $dialog = [System.Windows.Forms.OpenFileDialog]::new()
        try {
            $dialog.Title = 'Select the official Windows 11 25H2 ISO'
            $dialog.Filter = 'Windows ISO (*.iso)|*.iso'
            $dialog.CheckFileExists = $true
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $sourceBox.Text = $dialog.FileName
                $state.AnalyzedSource = ''
                $state.Editions = @()
                $state.RepairInspection = $null
                $editionBox.Items.Clear()
                $analyzeButton.Enabled = $true
                $nextAction = if ($state.Mode -eq 'Repair') { 'Click Inspect ISO to validate that the selected repair applies.' } else { 'Click Analyze ISO to validate the image and load its Windows editions.' }
                & $setStatus 'Source selected' $nextAction ([Drawing.Color]::FromArgb(40, 112, 224))
                & $updateReady
            }
        } finally { $dialog.Dispose() }
    }.GetNewClosure())

    $analyzeButton.Add_Click({
        $form.UseWaitCursor = $true
        $analysisDetail = if ($state.Mode -eq 'Repair') { 'Mounting the ISO read-only and checking the selected repair.' } else { 'Mounting the source read-only and validating Windows 11 25H2 metadata.' }
        & $setStatus 'Analyzing source ISO' $analysisDetail ([Drawing.Color]::FromArgb(40, 112, 224))
        $form.Refresh()
        try {
            if ($state.Mode -eq 'Repair') {
                $repairSelection = $profileBox.SelectedItem
                if (-not $repairSelection) { throw 'Select a repair operation first.' }
                $repairProvider = Get-WinUtilIsoRepairProvider
                $repairMounted = $false
                try {
                    $repairMediaRoot = & $repairProvider.MountIso $sourceBox.Text
                    $repairMounted = $true
                    $state.RepairInspection = & $repairSelection.Test $repairMediaRoot
                } finally {
                    if ($repairMounted) { & $repairProvider.DismountIso $sourceBox.Text }
                }
                if (-not $state.RepairInspection -or $state.RepairInspection.IsApplicable -ne $true) {
                    throw 'The selected repair is not applicable to this ISO.'
                }
                $editionBox.Items.Clear()
                [void]$editionBox.Items.Add(('Applicable to image index {0}' -f $state.RepairInspection.ImageIndex))
                $editionBox.SelectedIndex = 0
                $state.AnalyzedSource = $sourceBox.Text
                & $setStatus 'Repair is applicable' 'The ISO can be repaired without repeating Windows image servicing.' ([Drawing.Color]::FromArgb(34, 126, 76))
            } else {
                $provider = Get-WinUtilWindowsBuildProvider
                $state.Editions = @(Get-WinUtilSupportedEdition -SourceIsoPath $sourceBox.Text -BuildProvider $provider)
                $editionBox.Items.Clear()
                foreach ($edition in $state.Editions) {
                    [void]$editionBox.Items.Add(('{0}: {1}' -f $edition.ImageIndex, $edition.ImageName))
                }
                if ($editionBox.Items.Count -eq 0) { throw 'The source ISO contains no selectable editions.' }
                $editionBox.SelectedIndex = 0
                $state.AnalyzedSource = $sourceBox.Text
                & $setStatus 'Source ISO ready' "$($editionBox.Items.Count) supported edition(s) found. Review the configuration and build when ready." ([Drawing.Color]::FromArgb(34, 126, 76))
            }
        } catch {
            $state.AnalyzedSource = ''
            $state.Editions = @()
            $state.RepairInspection = $null
            $editionBox.Items.Clear()
            & $setStatus 'Source analysis failed' $_.Exception.Message ([Drawing.Color]::FromArgb(185, 54, 54))
            Show-WinUtilMessage -Title 'Source ISO rejected' -Icon Error -Text $_.Exception.Message
        } finally {
            $form.UseWaitCursor = $false
            & $updateReady
        }
    }.GetNewClosure())

    $taskBox.Add_SelectedIndexChanged({ if (-not $state.Build) { & $setMode } }.GetNewClosure())
    $profileBox.Add_SelectedIndexChanged({
        if ($state.Mode -eq 'Repair') {
            $state.AnalyzedSource = ''
            $state.RepairInspection = $null
            $editionBox.Items.Clear()
        }
        & $updateProfile
    }.GetNewClosure())
    $editionBox.Add_SelectedIndexChanged({ & $updateReady }.GetNewClosure())

    $outputButton.Add_Click({
        $selectedOption = $profileBox.SelectedItem
        $dialog = [System.Windows.Forms.SaveFileDialog]::new()
        try {
            $dialog.Title = 'Save the customized Windows ISO'
            $dialog.Filter = 'Windows ISO (*.iso)|*.iso'
            $dialog.DefaultExt = 'iso'
            $dialog.AddExtension = $true
            $dialog.FileName = if ($state.Mode -eq 'Repair') { 'Win11-Repaired.iso' } elseif ($selectedOption) { $selectedOption.SuggestedFileName } else { 'Win11-Custom.iso' }
            $dialog.InitialDirectory = if ($outputBox.Text) { Split-Path $outputBox.Text -Parent } else { [Environment]::GetFolderPath('Desktop') }
            $dialog.OverwritePrompt = $false
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                if (Test-Path -LiteralPath $dialog.FileName) {
                    Show-WinUtilMessage -Title 'Choose a new filename' -Icon Warning -Text 'That ISO already exists. Existing output is never overwritten.'
                    return
                }
                $outputBox.Text = $dialog.FileName
                $state.LastSuggestedOutput = $dialog.FileName
                & $updateReady
            }
        } finally { $dialog.Dispose() }
    }.GetNewClosure())

    $driversButton.Add_Click({
        $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
        try {
            $dialog.Description = 'Optional: choose a folder containing drivers to inject. Cancel to leave drivers unchanged.'
            $dialog.ShowNewFolderButton = $false
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $driversBox.Text = $dialog.SelectedPath }
        } finally { $dialog.Dispose() }
    }.GetNewClosure())

    $timer = [System.Windows.Forms.Timer]::new()
    $timer.Interval = 600
    $timer.Add_Tick({
        if (-not $state.Build) { return }
        $build = $state.Build
        if (Test-Path -LiteralPath $build.LogPath -PathType Leaf) {
            try {
                $text = Get-Content -LiteralPath $build.LogPath -Raw -ErrorAction Stop
                if ($text -ne $state.LastLog) {
                    $state.LastLog = $text
                    $logBox.Text = $text
                    $logBox.SelectionStart = $logBox.TextLength
                    $logBox.ScrollToCaret()
                }
                $progress = Get-WinUtilBuildProgress -LogText $text
                $progressBar.Value = [math]::Min(99, [math]::Max(0, $progress.Percent))
                & $setStatus $progress.Stage $progress.Detail ([Drawing.Color]::FromArgb(40, 112, 224))
            } catch { $null = $_ }
        }
        if (-not $build.AsyncResult.IsCompleted) { return }

        $timer.Stop()
        $result = $null
        $failure = $null
        try {
            $items = @($build.PowerShell.EndInvoke($build.AsyncResult))
            $result = @($items | Where-Object { $_.PSObject.Properties['OutputIsoPath'] }) | Select-Object -Last 1
            if (-not $result) { throw 'The build completed without returning an ISO result.' }
            if (-not (Test-Path -LiteralPath $result.OutputIsoPath -PathType Leaf)) {
                throw 'The operation did not publish its output ISO.'
            }
            if ($build.Mode -eq 'Build' -and -not (Test-Path -LiteralPath $result.EvidenceDirectory -PathType Container)) {
                throw 'The build did not publish its evidence directory.'
            }
        } catch {
            $failure = $_.Exception.Message
            $pipelineErrors = @($build.PowerShell.Streams.Error)
            if ($pipelineErrors.Count -gt 0) { $failure = $pipelineErrors[-1].Exception.Message }
        } finally {
            $build.PowerShell.Dispose()
            $state.Build = $null
            & $setConfigurationEnabled $true
        }

        if ($failure) {
            $progressBar.Value = 0
            & $setStatus 'Build stopped' $failure ([Drawing.Color]::FromArgb(185, 54, 54))
            Show-WinUtilMessage -Title 'ISO build stopped' -Icon Error -Text $failure
            return
        }

        $progress = Get-WinUtilBuildProgress -IsComplete
        if ($build.Mode -eq 'Repair') { $progress.Detail = 'The repaired ISO is ready.' }
        $progressBar.Value = $progress.Percent
        & $setStatus $progress.Stage $progress.Detail ([Drawing.Color]::FromArgb(34, 126, 76))
        $openIsoButton.Tag = $result.OutputIsoPath
        $openIsoButton.Enabled = $true
        if ($build.Mode -eq 'Build') {
            $openEvidenceButton.Tag = $result.EvidenceDirectory
            $openEvidenceButton.Enabled = $true
        } else {
            $openEvidenceButton.Tag = $null
            $openEvidenceButton.Enabled = $false
        }
        if ($result.CleanupWarning) {
            Show-WinUtilMessage -Title 'ISO complete with cleanup warning' -Icon Warning -Text "$($progress.Detail)`n`n$($result.CleanupWarning)"
        } else {
            $completionText = if ($build.Mode -eq 'Repair') { 'The repaired ISO is ready.' } else { 'The ISO and verification evidence are ready.' }
            Show-WinUtilMessage -Title 'ISO operation complete' -Text "$completionText`n`n$($result.OutputIsoPath)"
        }
    }.GetNewClosure())

    $buildButton.Add_Click({
        $selectedOption = $profileBox.SelectedItem
        if (-not $selectedOption) {
            Show-WinUtilMessage -Title 'Selection required' -Icon Warning -Text 'Select a profile or repair operation.'
            return
        }
        if ($state.Mode -eq 'Build' -and -not $selectedOption.IsAvailable) {
            Show-WinUtilMessage -Title 'Profile unavailable' -Icon Warning -Text $selectedOption.UnavailableReason
            return
        }
        if ($state.AnalyzedSource -ne $sourceBox.Text -or ($state.Mode -eq 'Build' -and $editionBox.SelectedIndex -lt 0) -or
            ($state.Mode -eq 'Repair' -and -not $state.RepairInspection)) {
            Show-WinUtilMessage -Title 'Analyze the source first' -Icon Warning -Text 'Choose and analyze or inspect the source ISO before continuing.'
            return
        }
        if (-not $outputBox.Text) {
            Show-WinUtilMessage -Title 'Choose an output' -Icon Warning -Text 'Choose where the finished ISO should be saved.'
            return
        }
        if (Test-Path -LiteralPath $outputBox.Text) {
            Show-WinUtilMessage -Title 'Output already exists' -Icon Warning -Text 'Choose a new ISO filename; existing output is never overwritten.'
            return
        }
        if ($state.Mode -eq 'Build' -and $driversBox.Text -and -not (Test-Path -LiteralPath $driversBox.Text -PathType Container)) {
            Show-WinUtilMessage -Title 'Driver folder missing' -Icon Warning -Text 'The selected driver folder no longer exists.'
            return
        }
        if (-not (Confirm-WinUtilOutputCapacity -OutputIsoPath $outputBox.Text)) { return }

        try {
            & $setStatus 'Checking prerequisites' 'Locating the Microsoft ISO packaging tool.' ([Drawing.Color]::FromArgb(40, 112, 224))
            $form.Refresh()
            $oscdimg = Find-WinUtilOscdimg
            if (-not $oscdimg) { $oscdimg = Install-WinUtilOscdimg }
            if (-not $oscdimg) { throw 'oscdimg is required. Install Windows ADK Deployment Tools, then reopen the launcher.' }

            $outputDirectory = Split-Path ([IO.Path]::GetFullPath($outputBox.Text)) -Parent
            $powerShell = [PowerShell]::Create()
            if ($state.Mode -eq 'Repair') {
                $workDirectory = Join-Path $outputDirectory ('.WinUtil-repair-{0}' -f [guid]::NewGuid().ToString('N'))
                $logPath = Join-Path $workDirectory 'WinUtil_ISORepair.log'
                [void]$powerShell.AddCommand((Join-Path $script:RepositoryRoot 'tools\Invoke-WinUtilIsoRepair.ps1'))
                [void]$powerShell.AddParameter('SourceIsoPath', $sourceBox.Text)
                [void]$powerShell.AddParameter('OutputIsoPath', $outputBox.Text)
                [void]$powerShell.AddParameter('WorkDirectory', $workDirectory)
                [void]$powerShell.AddParameter('OscdimgPath', $oscdimg)
                [void]$powerShell.AddParameter('RepairId', @([string]$selectedOption.Id))
                [void]$powerShell.AddParameter('RemoveWorkDirectoryOnSuccess', $true)
                $operationStatus = "Repairing with '$($selectedOption.Name)'. Do not close this window."
            } else {
                $edition = $state.Editions[$editionBox.SelectedIndex]
                $workDirectory = Join-Path $outputDirectory ('.WinUtil-build-{0}' -f [guid]::NewGuid().ToString('N'))
                $logPath = Join-Path $workDirectory 'WinUtil_Win11ISO.log'
                [void]$powerShell.AddCommand((Join-Path $script:RepositoryRoot 'tools\Invoke-WinUtilWindowsBuild.ps1'))
                [void]$powerShell.AddParameter('SourceIsoPath', $sourceBox.Text)
                [void]$powerShell.AddParameter('ImageIndex', [int]$edition.ImageIndex)
                [void]$powerShell.AddParameter('ComponentProfile', [string]$selectedOption.Id)
                [void]$powerShell.AddParameter('OutputIsoPath', $outputBox.Text)
                [void]$powerShell.AddParameter('WorkDirectory', $workDirectory)
                [void]$powerShell.AddParameter('OscdimgPath', $oscdimg)
                [void]$powerShell.AddParameter('RemoveWorkDirectoryOnSuccess', $true)
                if ($selectedOption.ExpertMode) { [void]$powerShell.AddParameter('ExpertMode', $true) }
                if ($driversBox.Text) { [void]$powerShell.AddParameter('DriverDirectory', $driversBox.Text) }
                $operationStatus = "Building $($selectedOption.Name) for $($edition.ImageName). Do not close this window."
            }

            $state.Build = [pscustomobject]@{
                PowerShell = $powerShell
                AsyncResult = $powerShell.BeginInvoke()
                LogPath = $logPath
                Mode = $state.Mode
            }
            $state.LastLog = ''
            $logBox.Text = "Operation queued. Waiting for the first durable log entry...`r`n"
            $progressBar.Value = 2
            $openIsoButton.Enabled = $false
            $openEvidenceButton.Enabled = $false
            & $setConfigurationEnabled $false
            & $setStatus 'Starting' $operationStatus ([Drawing.Color]::FromArgb(40, 112, 224))
            $timer.Start()
        } catch {
            if ($state.Build -and $state.Build.PowerShell) { $state.Build.PowerShell.Dispose() }
            $state.Build = $null
            & $setConfigurationEnabled $true
            & $setStatus 'Could not start build' $_.Exception.Message ([Drawing.Color]::FromArgb(185, 54, 54))
            Show-WinUtilMessage -Title 'Could not start build' -Icon Error -Text $_.Exception.Message
        }
    }.GetNewClosure())

    $openIsoButton.Add_Click({
        if ($openIsoButton.Tag) { Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $openIsoButton.Tag) }
    }.GetNewClosure())
    $openEvidenceButton.Add_Click({
        if ($openEvidenceButton.Tag) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $openEvidenceButton.Tag) }
    }.GetNewClosure())

    $form.Add_FormClosing({
        param ($closingForm, $closingEvent)
        $null = $closingForm
        if ($state.Build) {
            $closingEvent.Cancel = $true
            Show-WinUtilMessage -Title 'Build in progress' -Icon Warning -Text 'The ISO build is still running. Wait for completion or failure cleanup before closing this window.'
        }
    }.GetNewClosure())

    & $setMode
    return $form
}

function Invoke-WinUtilLeanDawLauncher {
    if ($env:OS -ne 'Windows_NT') { throw 'Build-LeanDAW.cmd must be run on Windows.' }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    if (-not (Request-WinUtilAdministrator)) { return }

    $form = Get-WinUtilBuildForm
    try { [void]$form.ShowDialog() } finally { $form.Dispose() }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-WinUtilLeanDawLauncher
    } catch {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            Show-WinUtilMessage -Title 'Win11 Creator could not start' -Icon Error -Text $_.Exception.Message
        } catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
        }
        exit 1
    }
}
