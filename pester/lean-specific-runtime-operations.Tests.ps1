Describe 'Lean-specific runtime operations' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $script:repoRoot 'functions/private/Import-WinUtilComponentPolicy.ps1')
        . (Join-Path $script:repoRoot 'functions/private/Test-WinUtilComponentSafety.ps1')
        . (Join-Path $script:repoRoot 'functions/private/Resolve-WinUtilOfflineImagePolicy.ps1')
        . (Join-Path $script:repoRoot 'functions/private/Resolve-WinUtilComponentPolicyPlan.ps1')
        . (Join-Path $script:repoRoot 'functions/private/Invoke-WinUtilISOScript.ps1')
        $policyRoot = Join-Path $script:repoRoot 'policy'
        $script:catalog = Import-WinUtilComponentPolicy -Path (Join-Path $policyRoot 'component-catalog.json')
        $script:lean = Import-WinUtilComponentPolicy -Path (Join-Path $policyRoot 'profiles/lean-daw.json') -Catalog $script:catalog
        $script:inventory = [pscustomobject]@{ SchemaVersion = '1.0'; Source = [pscustomobject]@{ ImagePath = 'install.wim'; ImageIndex = 1 }; Items = @() }
        $script:template = Get-Content -LiteralPath (Join-Path $script:repoRoot 'tools/autounattend.xml') -Raw
    }

    It 'blocks Lean Defender removal when mounted inventory exposes no supported target' {
        $result = Resolve-WinUtilComponentPolicyPlan -Inventory $script:inventory -Catalog $script:catalog -Profile $script:lean -OfflineSystemSelect ([pscustomobject]@{ Current = 1 }) -ExpertMode
        $result.ActionBundle.IsReady | Should -BeFalse
        $result.ActionBundle.SecurityOperations | Should -HaveCount 1
        $result.ActionBundle.SecurityOperations[0].Operation | Should -Be 'RemoveDefenderOffline'
        $result.Safety.Conflicts | Where-Object {
            $_.ComponentId -eq 'defender' -and $_.Severity -eq 'unsupported-operation' -and $_.IsBlocking
        } | Should -HaveCount 1
    }

    It 'does not mistake default definitions or Sense MDE payloads for the Defender antivirus core' {
        $inventory = [pscustomobject]@{
            SchemaVersion = '1.0'; Source = $script:inventory.Source
            Items = @(
                [pscustomobject]@{ Kind = 'Feature'; Name = 'Windows-Defender-Default-Definitions'; Identity = 'Windows-Defender-Default-Definitions'; State = 'Enabled' }
                [pscustomobject]@{ Kind = 'Capability'; Name = 'Microsoft.Windows.Sense.Client~~~~'; Identity = 'Microsoft.Windows.Sense.Client~~~~'; State = 'Installed' }
                [pscustomobject]@{ Kind = 'Package'; Name = 'Microsoft-Windows-SenseClient-FoD-Package'; Identity = 'Microsoft-Windows-SenseClient-FoD-Package~31bf~amd64~~10.0.26100.6584'; State = 'Installed' }
            )
        }
        $result = Resolve-WinUtilComponentPolicyPlan -Inventory $inventory -Catalog $script:catalog -Profile $script:lean -OfflineSystemSelect ([pscustomobject]@{ Current = 1 }) -ExpertMode
        $result.ActionBundle.IsReady | Should -BeFalse
        $result.ActionBundle.SecurityOperations[0].Targets | Should -HaveCount 0
        @($result.ResolvedPlan.Decisions | Where-Object PolicyId -eq defender) | Should -HaveCount 0
    }

    It 'catalogs no speculative Defender feature or servicing-package wildcard' {
        $defender = $script:catalog.components | Where-Object id -eq defender
        @($defender.targets | Where-Object kind -in @('feature', 'package', 'capability')) | Should -HaveCount 0
    }

    It 'wires SecurityOperations into both one-mount transaction paths' {
        $isoSource = Get-Content -LiteralPath (Join-Path $script:repoRoot 'functions/private/Invoke-WinUtilISOScript.ps1') -Raw
        ([regex]::Matches($isoSource, [regex]::Escape('-SecurityOperation @($ActionBundle.SecurityOperations)'))).Count | Should -Be 2
    }

    It 'resolves OneDrive provisioning cleanup to the exact built-in uninstaller' {
        $result = Resolve-WinUtilComponentPolicyPlan -Inventory $script:inventory -Catalog $script:catalog -Profile $script:lean -ActionOverrides @{ defender = 'keep' } -OfflineSystemSelect ([pscustomobject]@{ Current = 1 }) -ExpertMode
        $action = @($result.ActionBundle.SetupActions | Where-Object SourceComponentId -eq onedrive)
        $action | Should -HaveCount 1
        $action[0].Mechanism | Should -Be 'onedrive-built-in-uninstaller'
        $action[0].Executable | Should -Be 'OneDriveSetup.exe'
        $action[0].Arguments | Should -Be @('/uninstall')
    }

    It 'resolves Copilot provisioned AppX removal together with its reprovisioning policy' {
        $inventory = [pscustomobject]@{
            SchemaVersion = '1.0'; Source = $script:inventory.Source
            Items = @([pscustomobject]@{ Kind = 'AppX'; Name = 'Microsoft.Copilot'; Identity = 'Microsoft.Copilot_1.0.0.0_neutral_~_8wekyb3d8bbwe'; State = 'Provisioned' })
        }
        $result = Resolve-WinUtilComponentPolicyPlan -Inventory $inventory -Catalog $script:catalog -Profile $script:lean -ActionOverrides @{ defender = 'keep' } -OfflineSystemSelect ([pscustomobject]@{ Current = 1 }) -ExpertMode
        ($result.ResolvedPlan.Decisions | Where-Object PolicyId -eq copilot).Action | Should -Be 'Remove'
        $result.ActionBundle.RegistryActions | Where-Object {
            $_.SourceComponentId -eq 'copilot' -and $_.Name -eq 'TurnOffWindowsCopilot' -and $_.Value -eq 1
        } | Should -HaveCount 1
    }

    It 'rejects planted retargeting of privileged Lean operations' {
        $invalidOneDrive = $script:catalog | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        (($invalidOneDrive.components | Where-Object id -eq onedrive).targets | Where-Object kind -eq setup).match = 'cmd.exe'
        { Test-WinUtilComponentPolicy -Policy $invalidOneDrive -ThrowOnError } | Should -Throw '*exact OneDriveSetup.exe target*'

        $invalidDefender = $script:catalog | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        (($invalidDefender.components | Where-Object id -eq defender).targets | Where-Object kind -eq security).match = 'all-security'
        { Test-WinUtilComponentPolicy -Policy $invalidDefender -ThrowOnError } | Should -Throw '*exact microsoft-defender-platform security target*'
    }

    It 'stages only the exact OneDrive built-in uninstall command' {
        $contentRoot = Join-Path ([IO.Path]::GetTempPath()) "WinUtilOneDrive_$([guid]::NewGuid())"
        $bundle = [pscustomobject]@{
            SchemaVersion = '1.0'; IsAllowed = $true; RegistryActions = @()
            SetupActions = @([pscustomobject]@{ Mechanism = 'onedrive-built-in-uninstaller'; Phase = 'specialize'; Executable = 'OneDriveSetup.exe'; Arguments = @('/uninstall'); SourceComponentId = 'onedrive' })
        }
        try {
            New-Item -Path $contentRoot -ItemType Directory -Force | Out-Null
            Invoke-WinUtilISOScript -ISOContentsDir $contentRoot -AutoUnattendXml $script:template -InstallEditionId Professional -ActionBundle $bundle
            $policyScript = Get-Content -LiteralPath (Join-Path $contentRoot 'sources\$OEM$\$$\Setup\Scripts\WinUtil-PolicySetup.ps1') -Raw
            $policyScript | Should -Match ([regex]::Escape('& "$env:SystemRoot\System32\OneDriveSetup.exe" /uninstall'))
        } finally { Remove-Item -LiteralPath $contentRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects a planted arbitrary executable disguised as OneDrive cleanup' {
        $bundle = [pscustomobject]@{
            SchemaVersion = '1.0'; IsAllowed = $true; RegistryActions = @()
            SetupActions = @([pscustomobject]@{ Mechanism = 'onedrive-built-in-uninstaller'; Phase = 'specialize'; Executable = 'powershell.exe'; Arguments = @('-Command', 'remove'); SourceComponentId = 'onedrive' })
        }
        { Invoke-WinUtilISOScript -ISOContentsDir ([IO.Path]::GetTempPath()) -AutoUnattendXml $script:template -InstallEditionId Professional -ActionBundle $bundle } |
            Should -Throw '*only the built-in OneDriveSetup.exe /uninstall intent is accepted*'
    }

    It 'keeps a Search SystemApp fail closed instead of deleting its directory' {
        $transactionSource = Get-Content -LiteralPath (Join-Path $script:repoRoot 'functions/private/Invoke-WinUtilOfflineServicingTransaction.ps1') -Raw
        $transactionSource | Should -Match ([regex]::Escape('cannot be safely serviced offline'))
        $transactionSource | Should -Not -Match 'Remove-Item.+SystemApps'
    }
}
