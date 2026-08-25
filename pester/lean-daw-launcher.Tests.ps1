BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:commandLauncher = Get-Content -LiteralPath (Join-Path $script:repoRoot 'Build-LeanDAW.cmd') -Raw
    $script:launcherPath = Join-Path $script:repoRoot 'tools/Start-WinUtilLeanDawBuild.ps1'
    $script:powershellLauncher = Get-Content -LiteralPath $script:launcherPath -Raw
    . $script:launcherPath
}

Describe 'Win11 Creator human launcher' {
    It 'provides one root command file that starts the persistent PowerShell interface' {
        $script:commandLauncher | Should -Match ([regex]::Escape('tools\Start-WinUtilLeanDawBuild.ps1'))
        $script:commandLauncher | Should -Match ([regex]::Escape('-ExecutionPolicy Bypass'))
        $script:powershellLauncher | Should -Match ([regex]::Escape("'Win11 Creator - ISO Builder'"))
        $script:powershellLauncher | Should -Match ([regex]::Escape("[void]`$form.ShowDialog()"))
    }

    It 'keeps all required build configuration in one window' {
        foreach ($label in 'Source ISO', 'Windows edition', 'Profile', 'Output ISO', 'Driver folder') {
            $script:powershellLauncher | Should -Match ([regex]::Escape($label))
        }
        $script:powershellLauncher | Should -Match ([regex]::Escape('[System.Windows.Forms.OpenFileDialog]'))
        $script:powershellLauncher | Should -Match ([regex]::Escape('[System.Windows.Forms.SaveFileDialog]'))
        $script:powershellLauncher | Should -Match ([regex]::Escape('[System.Windows.Forms.FolderBrowserDialog]'))
    }

    It 'integrates repair as a task in the same launcher without another command file' {
        $rootCommandFiles = @(Get-ChildItem -LiteralPath $script:repoRoot -Filter '*.cmd' -File)

        $script:powershellLauncher | Should -Match ([regex]::Escape("'Build customized ISO', 'Repair existing ISO'"))
        $script:powershellLauncher | Should -Match ([regex]::Escape('Get-WinUtilIsoRepairDefinition'))
        $script:powershellLauncher | Should -Match ([regex]::Escape("tools\Invoke-WinUtilIsoRepair.ps1"))
        @($rootCommandFiles.Name | Where-Object { $_ -match 'Repair' }) | Should -HaveCount 0
    }

    It 'offers only buildable profiles while explaining the unsupported Defender-removal profile' {
        $profiles = @(Get-WinUtilLauncherProfile)

        $profiles.Id | Should -Be @('lean-daw-defender-retained', 'default-winutil', 'lean-daw')
        ($profiles | Where-Object Id -eq 'lean-daw-defender-retained').IsAvailable | Should -BeTrue
        ($profiles | Where-Object Id -eq 'lean-daw-defender-retained').ExpertMode | Should -BeTrue
        ($profiles | Where-Object Id -eq 'default-winutil').IsAvailable | Should -BeTrue
        ($profiles | Where-Object Id -eq 'lean-daw').IsAvailable | Should -BeFalse
        ($profiles | Where-Object Id -eq 'lean-daw').UnavailableReason | Should -Match 'no supported removable Defender AV-core target'
    }

    It 'discovers supported media editions and never overwrites an existing ISO' {
        $script:powershellLauncher | Should -Match ([regex]::Escape('Test-WinUtilWindowsImageSupport'))
        $script:powershellLauncher | Should -Match ([regex]::Escape('$editionBox.Items.Add'))
        $script:powershellLauncher | Should -Match ([regex]::Escape("if (Test-Path -LiteralPath `$outputBox.Text)"))
        $script:powershellLauncher | Should -Match ([regex]::Escape('Confirm-WinUtilOutputCapacity'))
        $script:powershellLauncher | Should -Match 'availableGiB\s+-ge\s+50'
    }

    It 'tracks the asynchronous build in place with a live log and durable result links' {
        $script:powershellLauncher | Should -Match ([regex]::Escape('[PowerShell]::Create()'))
        $script:powershellLauncher | Should -Match ([regex]::Escape('$powerShell.BeginInvoke()'))
        $script:powershellLauncher | Should -Match ([regex]::Escape('WinUtil_Win11ISO.log'))
        $script:powershellLauncher | Should -Match ([regex]::Escape('Get-WinUtilBuildProgress'))
        $script:powershellLauncher | Should -Match ([regex]::Escape("'Open ISO location'"))
        $script:powershellLauncher | Should -Match ([regex]::Escape("'Open evidence'"))
        $script:powershellLauncher | Should -Match ([regex]::Escape("'The ISO build is still running."))
    }

    It 'maps durable build stages to monotonic progress and completion' {
        (Get-WinUtilBuildProgress -LogText 'Starting noninteractive build').Percent | Should -Be 5
        (Get-WinUtilBuildProgress -LogText 'Starting noninteractive build; Copying Windows setup media').Percent | Should -Be 15
        (Get-WinUtilBuildProgress -LogText 'Mounting copied install.wim').Percent | Should -Be 32
        (Get-WinUtilBuildProgress -LogText 'Creating the bootable ISO').Percent | Should -Be 88
        (Get-WinUtilBuildProgress -LogText 'hashing output and publishing build evidence').Percent | Should -Be 95
        $complete = Get-WinUtilBuildProgress -IsComplete
        $complete.Percent | Should -Be 100
        $complete.Stage | Should -Be 'Complete'
    }

    It 'passes selected configuration to the builder and cleans only successful temporary work' {
        $script:powershellLauncher | Should -Match ([regex]::Escape("AddParameter('ComponentProfile', [string]`$selectedOption.Id)"))
        $script:powershellLauncher | Should -Match ([regex]::Escape("AddParameter('ImageIndex', [int]`$edition.ImageIndex)"))
        $script:powershellLauncher | Should -Match ([regex]::Escape("AddParameter('DriverDirectory', `$driversBox.Text)"))
        $script:powershellLauncher | Should -Match ([regex]::Escape("AddParameter('RemoveWorkDirectoryOnSuccess', `$true)"))
        $script:powershellLauncher | Should -Match ([regex]::Escape('$result.EvidenceDirectory'))
    }
}
