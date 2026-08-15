Describe 'Offline image policy resolver' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        . (Join-Path $repoRoot 'functions/private/Resolve-WinUtilOfflineImagePolicy.ps1')

        function New-TestInventory {
            param ([object[]]$Items)
            [pscustomobject]@{
                SchemaVersion = '1.0'
                Source = [pscustomobject]@{ ImagePath = 'install.wim'; ImageIndex = 6; ImageName = 'Windows 11 Pro' }
                Items = $Items
            }
        }

        function New-TestItem {
            param ([string]$Kind, [string]$Identity, [string]$Name = '')
            if (-not $Name) { $Name = $Identity }
            [pscustomobject]@{ Kind = $Kind; Name = $Name; Identity = $Identity; State = 'Installed' }
        }
    }

    It 'resolves exact matches and leaves an unknown package manual and kept' {
        $known = New-TestItem AppX 'Microsoft.WindowsFeedbackHub_1.0.0.0_neutral_~_8wekyb3d8bbwe' 'Microsoft.WindowsFeedbackHub'
        $unknown = New-TestItem Package 'Contoso.Unknown-Package~31bf~amd64~~10.0.1.0'
        $inventory = New-TestInventory @($known, $unknown)
        $policy = @([pscustomobject]@{
            Id = 'feedback'; Action = 'Remove'; Risk = 'Safe'; Reason = 'Not required.'
            Targets = @([pscustomobject]@{ Kind = 'AppX'; Match = 'Microsoft.WindowsFeedbackHub'; MatchType = 'Exact' })
        })

        $plan = Resolve-WinUtilOfflineImagePolicy -Inventory $inventory -Policy $policy
        ($plan.Decisions | Where-Object Identity -eq $known.Identity).Action | Should -Be 'Remove'
        $unknownDecision = $plan.Decisions | Where-Object Identity -eq $unknown.Identity
        $unknownDecision.Action | Should -Be 'Manual'
        $unknownDecision.Reason | Should -Match 'kept unless explicitly overridden'
    }

    It 'uses controlled wildcard and version-insensitive matching' {
        $v1 = New-TestItem Package 'Microsoft-Windows-Client-AIX-Package~31bf3856ad364e35~amd64~~10.0.26100.1'
        $v2 = New-TestItem Package 'Microsoft-Windows-Client-AIX-LanguagePack~31bf3856ad364e35~amd64~en-US~10.0.26100.2'
        $appx = New-TestItem AppX 'Microsoft.XboxApp_48.100.1.0_neutral_~_8wekyb3d8bbwe'
        $inventory = New-TestInventory @($v1, $v2, $appx)
        $policy = @(
            [pscustomobject]@{
                Id = 'aix'; Action = 'Remove'; Risk = 'Moderate'; Reason = 'Remove AI payload.'
                Targets = @([pscustomobject]@{
                    Kind = 'Package'; Match = 'Microsoft-Windows-Client-AIX-Package~31bf3856ad364e35~amd64~~10.0.22000.1'; MatchType = 'VersionInsensitive'
                })
            },
            [pscustomobject]@{
                Id = 'xbox'; Action = 'Remove'; Risk = 'Moderate'; Reason = 'Remove Xbox apps.'
                Targets = @([pscustomobject]@{ Kind = 'AppX'; Match = 'Microsoft.XboxApp_*'; MatchType = 'Wildcard' })
            }
        )

        $plan = Resolve-WinUtilOfflineImagePolicy -Inventory $inventory -Policy $policy
        ($plan.Decisions | Where-Object Identity -eq $v1.Identity).Action | Should -Be 'Remove'
        ($plan.Decisions | Where-Object Identity -eq $v2.Identity).Action | Should -Be 'Manual'
        ($plan.Decisions | Where-Object Identity -eq $appx.Identity).Action | Should -Be 'Remove'
    }

    It 'applies manual overrides but resolves protection after removal and overrides' {
        $nfs = New-TestItem Feature 'ServicesForNFS-ClientOnly'
        $inventory = New-TestInventory @($nfs)
        $policy = @(
            [pscustomobject]@{
                Id = 'remove-features'; Action = 'Remove'; Risk = 'Moderate'; Reason = 'Broad removal.'
                Targets = @([pscustomobject]@{ Kind = 'Feature'; Match = '*NFS*'; MatchType = 'Wildcard' })
            },
            [pscustomobject]@{
                Id = 'protect-nfs'; Action = 'Protected'; Risk = 'High'; Reason = 'Required for development.'
                Targets = @([pscustomobject]@{ Kind = 'Feature'; Match = 'ServicesForNFS-ClientOnly'; MatchType = 'Exact' })
            }
        )
        $override = @([pscustomobject]@{ Identity = $nfs.Identity; Action = 'Remove'; Reason = 'Expert request.' })

        $plan = Resolve-WinUtilOfflineImagePolicy -Inventory $inventory -Policy $policy -ManualOverride $override
        $plan.Decisions[0].Action | Should -Be 'Protected'
        $plan.Decisions[0].PolicyId | Should -Be 'protect-nfs'
    }

    It 'allows a manual override for an unknown inventory entry' {
        $unknown = New-TestItem SystemApp 'Contoso.UnknownSystemApp'
        $inventory = New-TestInventory @($unknown)
        $override = @([pscustomobject]@{ Identity = $unknown.Identity; Action = 'Keep'; Reason = 'User inspected it.' })

        $plan = Resolve-WinUtilOfflineImagePolicy -Inventory $inventory -Policy @() -ManualOverride $override
        $plan.Decisions[0].Action | Should -Be 'Keep'
        $plan.Decisions[0].PolicyId | Should -Be 'manual-override'
    }

    It 'rejects an ambiguous high-risk wildcard' {
        $inventory = New-TestInventory @(
            (New-TestItem Package 'Microsoft-Windows-Client-AIX-One~31bf~amd64~~10.0.1.0'),
            (New-TestItem Package 'Microsoft-Windows-Client-AIX-Two~31bf~amd64~~10.0.1.0')
        )
        $policy = @([pscustomobject]@{
            Id = 'high-risk-aix'; Action = 'Remove'; Risk = 'High'; Reason = 'High-risk removal.'
            Targets = @([pscustomobject]@{ Kind = 'Package'; Match = 'Microsoft-Windows-Client-AIX-*'; MatchType = 'Wildcard' })
        })

        { Resolve-WinUtilOfflineImagePolicy -Inventory $inventory -Policy $policy } |
            Should -Throw '*is ambiguous (2 matches)*'
    }

    It 'formats a human-readable non-destructive dry-run plan' {
        $item = New-TestItem Capability 'OpenSSH.Client~~~~0.0.1.0'
        $inventory = New-TestInventory @($item)
        $plan = Resolve-WinUtilOfflineImagePolicy -Inventory $inventory -Policy @()

        $text = Format-WinUtilOfflineImagePlan -ResolvedPlan $plan
        $text | Should -Match 'Image: install\.wim \[index 6\] Windows 11 Pro'
        $text | Should -Match 'MANUAL\s+Capability\s+OpenSSH\.Client'
        $text | Should -Not -Match 'Remove-Windows'
    }
}
