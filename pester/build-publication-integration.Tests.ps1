#===========================================================================
# Tests - Win11 Creator publication ordering
#===========================================================================

Describe 'Win11 Creator output publication ordering' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:isoSource = Get-Content -LiteralPath (Join-Path $script:repoRoot 'functions/private/Invoke-WinUtilISO.ps1') -Raw
        $script:usbSource = Get-Content -LiteralPath (Join-Path $script:repoRoot 'functions/private/Invoke-WinUtilISOUSB.ps1') -Raw
    }

    It 'publishes required evidence after ISO creation and before the success message' {
        $processSuccess = $script:isoSource.IndexOf('if ($proc.ExitCode -eq 0)')
        $publish = $script:isoSource.IndexOf('Publish-WinUtilBuildArtifact', $processSuccess)
        $ready = $script:isoSource.IndexOf('ISO exported successfully!', $processSuccess)

        $processSuccess | Should -BeGreaterThan -1
        $publish | Should -BeGreaterThan $processSuccess
        $ready | Should -BeGreaterThan $publish
    }

    It 'publishes required evidence after USB copying and before the ready message' {
        $copied = $script:usbSource.IndexOf('Files copied to USB.')
        $publish = $script:usbSource.IndexOf('Publish-WinUtilBuildArtifact', $copied)
        $ready = $script:usbSource.IndexOf('USB drive is ready for use.', $copied)

        $copied | Should -BeGreaterThan -1
        $publish | Should -BeGreaterThan $copied
        $ready | Should -BeGreaterThan $publish
    }

    It 'injects publisher dependencies into both isolated runspaces using function bodies' {
        foreach ($source in $script:isoSource, $script:usbSource) {
            $source | Should -Match '\$\{function:Read-WinUtilOfflineManifest\}\.ToString\(\)'
            $source | Should -Match '\$\{function:Publish-WinUtilBuildArtifact\}\.ToString\(\)'
            $source | Should -Match 'WinUtil_Win11ISO\.log'
        }
    }
}
