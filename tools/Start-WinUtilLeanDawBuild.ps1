[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'
$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Test-WinUtilAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-WinUtilAdministrator {
    if (Test-WinUtilAdministrator) { return $true }

    $arguments = @(
        '-NoLogo'
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        ('"{0}"' -f $PSCommandPath)
    )
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

function Select-WinUtilSourceIso {
    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    try {
        $dialog.Title = 'Select the official Windows 11 25H2 ISO'
        $dialog.Filter = 'Windows ISO (*.iso)|*.iso'
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return '' }
        return $dialog.FileName
    } finally {
        $dialog.Dispose()
    }
}

function Select-WinUtilOutputIso {
    while ($true) {
        $dialog = [System.Windows.Forms.SaveFileDialog]::new()
        try {
            $dialog.Title = 'Save the Lean DAW Windows ISO'
            $dialog.Filter = 'Windows ISO (*.iso)|*.iso'
            $dialog.DefaultExt = 'iso'
            $dialog.AddExtension = $true
            $dialog.FileName = 'Win11-Lean-DAW-Defender-Retained.iso'
            $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
            $dialog.OverwritePrompt = $false
            if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return '' }
            if (-not (Test-Path -LiteralPath $dialog.FileName)) { return $dialog.FileName }
            Show-WinUtilMessage -Title 'Choose a new filename' -Icon Warning `
                -Text 'That output file already exists. Choose a new filename so an existing ISO is never overwritten.'
        } finally {
            $dialog.Dispose()
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
        "The selected drive has only $availableGiB GB free. A safe build normally needs at least 50 GB.`n`nChoose a different location?",
        'Low disk space',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return $answer -eq [System.Windows.Forms.DialogResult]::No
}

function Find-WinUtilOscdimg {
    $command = Get-Command oscdimg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }

    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits')
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages')
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
        "The ISO packaging tool is not installed. Install Microsoft's oscdimg automatically with WinGet?",
        'Install ISO packaging tool',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return '' }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'WinGet is unavailable. Install Windows ADK Deployment Tools, then run Build-LeanDAW.cmd again.'
    }
    & $winget.Source install --exact --id Microsoft.OSCDIMG --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "WinGet could not install oscdimg (exit code $LASTEXITCODE)." }
    Find-WinUtilOscdimg
}

function Select-WinUtilImageIndex {
    param (
        [Parameter(Mandatory)][object[]]$Editions
    )

    if ($Editions.Count -eq 1) { return [int]$Editions[0].ImageIndex }

    $form = [System.Windows.Forms.Form]::new()
    $label = [System.Windows.Forms.Label]::new()
    $list = [System.Windows.Forms.ComboBox]::new()
    $button = [System.Windows.Forms.Button]::new()
    try {
        $form.Text = 'Choose Windows edition'
        $form.StartPosition = 'CenterScreen'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MinimizeBox = $false
        $form.MaximizeBox = $false
        $form.ClientSize = [Drawing.Size]::new(520, 135)

        $label.Text = 'Choose the Windows edition to customize:'
        $label.AutoSize = $true
        $label.Location = [Drawing.Point]::new(15, 15)
        $form.Controls.Add($label)

        $list.DropDownStyle = 'DropDownList'
        $list.Location = [Drawing.Point]::new(15, 42)
        $list.Size = [Drawing.Size]::new(490, 28)
        foreach ($edition in $Editions) {
            [void]$list.Items.Add(('{0}: {1}' -f $edition.ImageIndex, $edition.ImageName))
        }
        $list.SelectedIndex = 0
        $form.Controls.Add($list)

        $button.Text = 'Continue'
        $button.Location = [Drawing.Point]::new(405, 88)
        $button.Size = [Drawing.Size]::new(100, 30)
        $button.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.AcceptButton = $button
        $form.Controls.Add($button)

        if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return 0 }
        return [int]$Editions[$list.SelectedIndex].ImageIndex
    } finally {
        $form.Dispose()
    }
}

function Get-WinUtilSelectedImageIndex {
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
        Select-WinUtilImageIndex -Editions @($support.Editions)
    } finally {
        if ($mounted) { & $BuildProvider.DismountIso $SourceIsoPath }
    }
}

function Invoke-WinUtilLeanDawLauncher {
    if ($env:OS -ne 'Windows_NT') { throw 'Build-LeanDAW.cmd must be run on Windows.' }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    if (-not (Request-WinUtilAdministrator)) { return }

    . (Join-Path $script:RepositoryRoot 'tools\Invoke-WinUtilWindowsBuild.ps1')

    $sourceIso = Select-WinUtilSourceIso
    if (-not $sourceIso) { return }
    do {
        $outputIso = Select-WinUtilOutputIso
        if (-not $outputIso) { return }
    } while (-not (Confirm-WinUtilOutputCapacity -OutputIsoPath $outputIso))

    $oscdimg = Find-WinUtilOscdimg
    if (-not $oscdimg) { $oscdimg = Install-WinUtilOscdimg }
    if (-not $oscdimg) { throw 'oscdimg is required. Install Windows ADK Deployment Tools, then run Build-LeanDAW.cmd again.' }

    $provider = Get-WinUtilWindowsBuildProvider
    $imageIndex = Get-WinUtilSelectedImageIndex -SourceIsoPath $sourceIso -BuildProvider $provider
    if ($imageIndex -lt 1) { return }

    $outputDirectory = Split-Path ([IO.Path]::GetFullPath($outputIso)) -Parent
    $workDirectory = Join-Path $outputDirectory ('.WinUtil-LeanDAW-work-{0}' -f [guid]::NewGuid().ToString('N'))

    Write-Host ''
    Write-Host 'Building the Lean DAW ISO with Defender retained.' -ForegroundColor Cyan
    Write-Host 'This can take 30-90 minutes. Do not close this window.' -ForegroundColor Yellow
    Write-Host "Output: $outputIso"
    Write-Host ''

    $result = & (Join-Path $script:RepositoryRoot 'tools\Invoke-WinUtilWindowsBuild.ps1') `
        -SourceIsoPath $sourceIso `
        -ImageIndex $imageIndex `
        -ComponentProfile lean-daw-defender-retained `
        -ExpertMode `
        -OutputIsoPath $outputIso `
        -WorkDirectory $workDirectory `
        -OscdimgPath $oscdimg

    if (-not $result -or -not (Test-Path -LiteralPath $result.OutputIsoPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $result.EvidenceDirectory -PathType Container)) {
        throw 'The build did not publish both the ISO and its evidence directory.'
    }

    if (Test-Path -LiteralPath $workDirectory -PathType Container) {
        try { Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction Stop } catch {
            Write-Warning "The ISO succeeded, but temporary work could not be removed: $_"
        }
    }

    Show-WinUtilMessage -Title 'Lean DAW ISO complete' -Text "The ISO and verification evidence are ready:`n`n$($result.OutputIsoPath)"
    Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $result.OutputIsoPath)
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-WinUtilLeanDawLauncher
    } catch {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            Show-WinUtilMessage -Title 'Lean DAW build stopped' -Icon Error -Text $_.Exception.Message
        } catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
        }
        exit 1
    }
}
