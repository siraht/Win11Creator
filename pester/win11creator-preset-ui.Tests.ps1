Describe 'Win11 Creator component preset UI' {
    BeforeAll { $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }

    It 'defines and wires dedicated WPF import and export controls' {
        [xml]$xaml = Get-Content (Join-Path $repoRoot 'xaml/inputXML.xaml') -Raw
        $main = Get-Content (Join-Path $repoRoot 'scripts/main.ps1') -Raw
        foreach ($name in @('WPFWin11ISOPresetImportButton', 'WPFWin11ISOPresetExportButton')) {
            @($xaml.SelectNodes("//*[@Name='$name']")).Count | Should -Be 1
            $main | Should -Match ([regex]::Escape("$name.Add_Click"))
        }
        $main | Should -Match 'Invoke-WinUtilComponentPresetImportDialog'
        $main | Should -Match 'Invoke-WinUtilComponentPresetExportDialog'
    }
}
