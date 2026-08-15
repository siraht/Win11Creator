Describe 'Offline image inventory contract' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        . (Join-Path $repoRoot 'functions/private/Get-WinUtilOfflineImageInventory.ps1')

        $inputRecords = @{
            AppX = @([pscustomobject]@{
                DisplayName = 'Microsoft.WindowsFeedbackHub'
                PackageName = 'Microsoft.WindowsFeedbackHub_1.0.0.0_neutral_~_8wekyb3d8bbwe'
            })
            Capability = @([pscustomobject]@{ Name = 'OpenSSH.Client~~~~0.0.1.0'; State = 'Installed' })
            Feature = @([pscustomobject]@{ FeatureName = 'ServicesForNFS-ClientOnly'; State = 'Disabled' })
            Package = @([pscustomobject]@{
                PackageName = 'Microsoft-Windows-Client-AIX-Package~31bf3856ad364e35~amd64~~10.0.26100.1'
                PackageState = 'Installed'
            })
        }
        $systemApps = @([pscustomobject]@{
            Name = 'SearchHost'
            Identity = 'Windows.SystemApps.MicrosoftWindows.Client.CBS_SearchHost'
            State = 'Discovered'
        })
        $inventory = Get-WinUtilOfflineImageInventory `
            -MountedImagePath 'C:\mount' `
            -SourceImagePath 'D:\sources\install.wim' `
            -ImageIndex 6 `
            -ImageName 'Windows 11 Pro' `
            -InventoryInput $inputRecords `
            -SystemApp $systemApps
    }

    It 'publishes stable versioned source and index metadata' {
        $inventory.SchemaVersion | Should -Be '1.0'
        $inventory.Source.ImagePath | Should -Be 'D:\sources\install.wim'
        $inventory.Source.ImageIndex | Should -Be 6
        $inventory.Source.ImageName | Should -Be 'Windows 11 Pro'
        $inventory.Source.MountedImagePath | Should -Be 'C:\mount'
    }

    It 'normalizes all five supported discovery kinds' {
        @($inventory.Items).Count | Should -Be 5
        @($inventory.Items.Kind | Sort-Object) | Should -Be @('AppX', 'Capability', 'Feature', 'Package', 'SystemApp')
        foreach ($item in $inventory.Items) {
            $item.PSObject.Properties.Name | Should -Be @('Kind', 'Name', 'Identity', 'State')
            $item.Identity | Should -Not -BeNullOrEmpty
            $item.State | Should -Not -BeNullOrEmpty
        }
    }

    It 'round trips through JSON without losing the contract' {
        $copy = $inventory | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        $copy.SchemaVersion | Should -Be '1.0'
        $copy.Source.ImageIndex | Should -Be 6
        @($copy.Items).Count | Should -Be 5
    }

    It 'rejects a discovery record without an identity' {
        { ConvertTo-WinUtilImageInventoryItem -Kind Package -InputObject @([pscustomobject]@{}) } |
            Should -Throw '*did not contain an identity*'
    }
}
