Describe 'Offline servicing transaction boundary' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        . (Join-Path $repoRoot 'functions/private/Invoke-WinUtilOfflineServicingTransaction.ps1')

        function Get-WindowsImage { param([switch]$Mounted, $ErrorAction) }
        function Mount-WindowsImage { param($ImagePath, $Index, $Path, $ErrorAction) }
        function Dismount-WindowsImage { param($Path, [switch]$Save, [switch]$Discard, $ErrorAction) }
        function Get-WinUtilOfflineImageInventory { }
        function Remove-AppxProvisionedPackage { param($Path, $PackageName, $ErrorAction) }
        function Remove-WindowsCapability { param($Path, $Name, $ErrorAction) }
        function Disable-WindowsOptionalFeature { param($Path, $FeatureName, [switch]$Remove, $ErrorAction) }
        function Remove-WindowsPackage { param($Path, $PackageName, $ErrorAction) }

        function New-TransactionInventory {
            param ([object[]]$Items)
            [pscustomobject]@{
                SchemaVersion = '1.0'
                Source = [pscustomobject]@{ ImagePath = 'install.wim'; ImageIndex = 6; ImageName = 'Windows 11 Pro'; MountedImagePath = 'mount' }
                Items = $Items
            }
        }

        function New-TransactionDecision {
            param ([string]$Kind, [string]$Identity, [string]$Action)
            [pscustomobject]@{ Kind = $Kind; Name = $Identity; Identity = $Identity; Action = $Action; PolicyId = 'test'; Risk = 'Safe'; Reason = 'Test.' }
        }
    }

    BeforeEach {
        $script:testRoot = Join-Path ([IO.Path]::GetTempPath()) "WinUtilOfflineTransaction_$([guid]::NewGuid())"
        $script:wimPath = Join-Path $script:testRoot 'iso_contents/sources/install.wim'
        $script:mountPath = Join-Path $script:testRoot 'wim_mount'
        $script:manifestPath = Join-Path $script:testRoot 'manifests'
        New-Item -Path (Split-Path $script:wimPath -Parent) -ItemType Directory -Force | Out-Null
        Set-Content -Path $script:wimPath -Value 'copied mock wim'

        $script:beforeItems = @(
            [pscustomobject]@{ Kind = 'AppX'; Name = 'Remove.App'; Identity = 'Remove.App_1.0_neutral_test'; State = 'Provisioned' },
            [pscustomobject]@{ Kind = 'AppX'; Name = 'Keep.App'; Identity = 'Keep.App_1.0_neutral_test'; State = 'Provisioned' },
            [pscustomobject]@{ Kind = 'Capability'; Name = 'Remove.Capability'; Identity = 'Remove.Capability~~~~0.0.1.0'; State = 'Installed' },
            [pscustomobject]@{ Kind = 'Feature'; Name = 'DisableFeature'; Identity = 'DisableFeature'; State = 'Enabled' },
            [pscustomobject]@{ Kind = 'Package'; Name = 'Remove.Package'; Identity = 'Remove.Package~test'; State = 'Installed' }
        )
        $script:afterItems = @($script:beforeItems | Where-Object Identity -in @('Keep.App_1.0_neutral_test', 'DisableFeature'))
        $script:afterItems[1] = [pscustomobject]@{ Kind = 'Feature'; Name = 'DisableFeature'; Identity = 'DisableFeature'; State = 'Disabled' }
        $script:inventoryCall = 0
        $script:dismCalls = [System.Collections.Generic.List[string]]::new()

        Mock Get-WindowsImage { @() } -ParameterFilter { $Mounted }
        Mock Mount-WindowsImage { }
        Mock Dismount-WindowsImage { }
        Mock Get-WinUtilOfflineImageInventory {
            $script:inventoryCall++
            if ($script:inventoryCall -eq 1) { return New-TransactionInventory $script:beforeItems }
            return New-TransactionInventory $script:afterItems
        }
        Mock Remove-AppxProvisionedPackage { }
        Mock Remove-WindowsCapability { }
        Mock Disable-WindowsOptionalFeature { }
        Mock Remove-WindowsPackage { }

        function dism.exe {
            param ([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
            $script:dismCalls.Add(($Arguments -join '|'))
            $global:LASTEXITCODE = 0
        }
    }

    AfterEach {
        Remove-Item Function:\dism.exe -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'mounts once, services supported removals, cleans reversibly, and commits once' {
        $plan = [pscustomobject]@{
            SchemaVersion = '1.0'
            Decisions = @(
                (New-TransactionDecision AppX 'Remove.App_1.0_neutral_test' Remove),
                (New-TransactionDecision AppX 'Keep.App_1.0_neutral_test' Keep),
                (New-TransactionDecision AppX 'Protected.App_1.0_neutral_test' Protected),
                (New-TransactionDecision AppX 'Manual.App_1.0_neutral_test' Manual),
                (New-TransactionDecision Capability 'Remove.Capability~~~~0.0.1.0' Remove),
                (New-TransactionDecision Feature 'DisableFeature' Disable),
                (New-TransactionDecision Package 'Remove.Package~test' Remove)
            )
        }

        Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath | Out-Null

        Should -Invoke Mount-WindowsImage -Times 1 -Exactly -ParameterFilter { $ImagePath -eq $script:wimPath -and $Index -eq 6 -and $Path -eq $script:mountPath }
        Should -Invoke Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $Path -eq $script:mountPath -and $Save }
        Should -Invoke Dismount-WindowsImage -Times 0 -Exactly -ParameterFilter { $Discard }
        Should -Invoke Remove-AppxProvisionedPackage -Times 1 -Exactly -ParameterFilter { $PackageName -eq 'Remove.App_1.0_neutral_test' }
        Should -Invoke Remove-WindowsCapability -Times 1 -Exactly -ParameterFilter { $Name -eq 'Remove.Capability~~~~0.0.1.0' }
        Should -Invoke Disable-WindowsOptionalFeature -Times 1 -Exactly -ParameterFilter { $FeatureName -eq 'DisableFeature' -and -not $Remove }
        Should -Invoke Remove-WindowsPackage -Times 1 -Exactly -ParameterFilter { $PackageName -eq 'Remove.Package~test' }
        $script:dismCalls.Count | Should -Be 1
        $script:dismCalls[0] | Should -Match '/Cleanup-Image\|/StartComponentCleanup'
        $script:dismCalls[0] | Should -Not -Match 'ResetBase|WinSxS'
    }

    It 'never mutates protected, manual, or keep decisions' {
        $plan = [pscustomobject]@{
            SchemaVersion = '1.0'
            Decisions = @(
                (New-TransactionDecision AppX 'Keep.App' Keep),
                (New-TransactionDecision Capability 'Manual.Capability' Manual),
                (New-TransactionDecision Feature 'ProtectedFeature' Protected)
            )
        }

        Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath | Out-Null

        Should -Invoke Remove-AppxProvisionedPackage -Times 0 -Exactly
        Should -Invoke Remove-WindowsCapability -Times 0 -Exactly
        Should -Invoke Disable-WindowsOptionalFeature -Times 0 -Exactly
        Should -Invoke Remove-WindowsPackage -Times 0 -Exactly
    }

    It 'persists before, after, and diff manifests before committing' {
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Decisions = @() }
        Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath | Out-Null

        foreach ($name in 'ImageInventory.before.json', 'ImageInventory.after.json', 'ImageInventory.diff.json') {
            Test-Path (Join-Path $script:manifestPath $name) | Should -BeTrue
            { Get-Content (Join-Path $script:manifestPath $name) -Raw | ConvertFrom-Json } | Should -Not -Throw
        }
        (Get-Content (Join-Path $script:manifestPath 'ImageInventory.diff.json') -Raw | ConvertFrom-Json).Changes.Count | Should -Be 4
    }

    It 'discards the mount and never commits when a servicing action fails' {
        Mock Remove-WindowsPackage { throw 'injected package failure' }
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Decisions = @((New-TransactionDecision Package 'Remove.Package~test' Remove)) }

        { Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath } |
            Should -Throw '*injected package failure*'

        Should -Invoke Mount-WindowsImage -Times 1 -Exactly
        Should -Invoke Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $Path -eq $script:mountPath -and $Discard }
        Should -Invoke Dismount-WindowsImage -Times 0 -Exactly -ParameterFilter { $Save }
    }

    It 'discards a stale registered mount before using the mount path' {
        Mock Get-WindowsImage { @([pscustomobject]@{ Path = $script:mountPath; MountStatus = 'Invalid' }) } -ParameterFilter { $Mounted }
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Decisions = @() }

        Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath | Out-Null

        Should -Invoke Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $Path -eq $script:mountPath -and $Discard }
        Should -Invoke Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $Path -eq $script:mountPath -and $Save }
    }

    It 'fails closed before mounting an unsupported mutating kind' {
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Decisions = @((New-TransactionDecision SystemApp 'SearchHost' Remove)) }

        { Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath } |
            Should -Throw "*kind 'SystemApp' cannot be safely serviced offline*"
        Should -Invoke Mount-WindowsImage -Times 0 -Exactly
    }
}
