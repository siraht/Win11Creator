BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:commandLauncher = Get-Content -LiteralPath (Join-Path $script:repoRoot 'Build-LeanDAW.cmd') -Raw
    $script:powershellLauncher = Get-Content -LiteralPath (Join-Path $script:repoRoot 'tools/Start-WinUtilLeanDawBuild.ps1') -Raw
}

Describe 'Lean DAW human launcher' {
    It 'provides one root command file that starts the guided PowerShell launcher' {
        $script:commandLauncher | Should -Match ([regex]::Escape('tools\Start-WinUtilLeanDawBuild.ps1'))
        $script:commandLauncher | Should -Match ([regex]::Escape('-ExecutionPolicy Bypass'))
    }

    It 'requests elevation and uses file dialogs instead of requiring build paths' {
        $script:powershellLauncher | Should -Match ([regex]::Escape('-Verb RunAs'))
        $script:powershellLauncher | Should -Match ([regex]::Escape('[System.Windows.Forms.OpenFileDialog]'))
        $script:powershellLauncher | Should -Match ([regex]::Escape('[System.Windows.Forms.SaveFileDialog]'))
    }

    It 'always selects the Defender-retained Lean profile in Expert mode' {
        $script:powershellLauncher | Should -Match 'ComponentProfile\s+lean-daw-defender-retained'
        $script:powershellLauncher | Should -Match '(?m)^\s*-ExpertMode\s*`?\s*$'
        $script:powershellLauncher | Should -Not -Match 'ComponentProfile\s+lean-daw(?:\s|`)'
    }

    It 'discovers supported media editions and never overwrites an existing ISO' {
        $script:powershellLauncher | Should -Match ([regex]::Escape('Test-WinUtilWindowsImageSupport'))
        $script:powershellLauncher | Should -Match ([regex]::Escape('Select-WinUtilImageIndex'))
        $script:powershellLauncher | Should -Match ([regex]::Escape("if (-not (Test-Path -LiteralPath `$dialog.FileName))"))
        $script:powershellLauncher | Should -Match ([regex]::Escape('Confirm-WinUtilOutputCapacity'))
        $script:powershellLauncher | Should -Match 'availableGiB\s+-ge\s+50'
    }

    It 'requires publication before cleaning its uniquely owned work directory' {
        $script:powershellLauncher | Should -Match ([regex]::Escape("'.WinUtil-LeanDAW-work-{0}'"))
        $script:powershellLauncher | Should -Match ([regex]::Escape('$result.EvidenceDirectory'))
        $script:powershellLauncher | Should -Match ([regex]::Escape('Remove-Item -LiteralPath $workDirectory -Recurse -Force'))
    }
}
