Describe 'Offline servicing transaction boundary' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        . (Join-Path $repoRoot 'functions/private/Invoke-WinUtilOfflineServicingTransaction.ps1')
        . (Join-Path $repoRoot 'functions/private/Invoke-WinUtilISOScript.ps1')
        $script:autoUnattendPath = Join-Path $repoRoot 'tools/autounattend.xml'

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
        $script:regCalls = [System.Collections.Generic.List[string]]::new()

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
            if ($Arguments -contains '/CheckHealth' -or $Arguments -contains '/ScanHealth') {
                'No component store corruption detected.'
            }
        }
        function reg.exe {
            param ([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
            $script:regCalls.Add(($Arguments -join '|'))
            $global:LASTEXITCODE = 0
        }
    }

    AfterEach {
        Remove-Item Function:\dism.exe -ErrorAction SilentlyContinue
        Remove-Item Function:\reg.exe -ErrorAction SilentlyContinue
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
        $script:dismCalls.Count | Should -Be 3
        $script:dismCalls | Should -Contain ($script:dismCalls | Where-Object { $_ -match '/Cleanup-Image\|/StartComponentCleanup' })
        $script:dismCalls | Where-Object { $_ -match '/CheckHealth' } | Should -HaveCount 1
        $script:dismCalls | Where-Object { $_ -match '/ScanHealth' } | Should -HaveCount 1
        ($script:dismCalls -join "`n") | Should -Not -Match 'ResetBase|WinSxS'
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

    It 'persists the versioned plan, dry run, before, after, and diff contracts before committing' {
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Decisions = @() }
        Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath | Out-Null

        $expectedTypes = [ordered]@{
            'ResolvedPlan.json' = 'ResolvedPlan'
            'ImageInventory.before.json' = 'ImageInventoryBefore'
            'ImageInventory.after.json' = 'ImageInventoryAfter'
            'ImageInventory.diff.json' = 'ImageInventoryDiff'
        }
        foreach ($entry in $expectedTypes.GetEnumerator()) {
            $name = $entry.Key
            Test-Path (Join-Path $script:manifestPath $name) | Should -BeTrue
            $manifest = Get-Content (Join-Path $script:manifestPath $name) -Raw | ConvertFrom-Json
            $manifest.SchemaVersion | Should -Be '1.0'
            $manifest.ManifestType | Should -Be $entry.Value
        }
        (Get-Item (Join-Path $script:manifestPath 'ResolvedPlan.txt')).Length | Should -BeGreaterThan 0
        (Get-Content (Join-Path $script:manifestPath 'ImageInventory.diff.json') -Raw | ConvertFrom-Json).Changes.Count | Should -Be 4
    }

    It 'refuses stale manifest evidence before mounting or changing it' {
        New-Item -Path $script:manifestPath -ItemType Directory | Out-Null
        $stalePath = Join-Path $script:manifestPath 'existing-evidence.txt'
        Set-Content -LiteralPath $stalePath -Value 'previous build evidence'
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Decisions = @() }

        { Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath } |
            Should -Throw '*destination already exists*refusing stale evidence*'

        (Get-Content -LiteralPath $stalePath -Raw).Trim() | Should -Be 'previous build evidence'
        @(Get-ChildItem -LiteralPath $script:manifestPath -Force).Count | Should -Be 1
        Should -Invoke Mount-WindowsImage -Times 0 -Exactly
        Should -Invoke Dismount-WindowsImage -Times 0 -Exactly
    }

    It 'leaves no partial final set and preserves unrelated data on a concurrent publication failure' {
        $unrelatedPath = Join-Path $script:testRoot 'unrelated-build'
        New-Item -Path $unrelatedPath -ItemType Directory | Out-Null
        Set-Content -LiteralPath (Join-Path $unrelatedPath 'keep.txt') -Value 'keep me'
        $publishWithRace = {
            param($source, $destination)
            $sourceFiles = @(Get-ChildItem -LiteralPath $source -File)
            $sourceFiles.Count | Should -Be 5
            New-Item -Path $destination -ItemType Directory -ErrorAction Stop | Out-Null
            Set-Content -LiteralPath (Join-Path $destination 'concurrent.txt') -Value 'another publisher'
            throw 'injected concurrent destination'
        }
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Decisions = @() }

        { Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath -PublishManifestSet $publishWithRace } |
            Should -Throw '*image was committed*atomic manifest publication failed*concurrent destination*'

        Should -Invoke Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $Save }
        Should -Invoke Dismount-WindowsImage -Times 0 -Exactly -ParameterFilter { $Discard }
        @(Get-ChildItem -LiteralPath $script:manifestPath -Force).Name | Should -Be @('concurrent.txt')
        (Get-Content -LiteralPath (Join-Path $unrelatedPath 'keep.txt') -Raw).Trim() | Should -Be 'keep me'
        @(Get-ChildItem -LiteralPath $script:testRoot -Directory -Force | Where-Object Name -Like '.manifests.pending-*').Count | Should -Be 0
    }

    It 'loads only an explicitly requested offline registry hive and unloads it' {
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Decisions = @() }
        $registryAction = @([pscustomobject]@{
            Hive = 'SOFTWARE'; Key = 'Policies\WinUtil'; Action = 'Set'; Name = 'Enabled'; Type = 'REG_DWORD'; Value = 1
        })

        Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath -RegistryAction $registryAction | Out-Null

        $script:regCalls.Count | Should -Be 3
        $script:regCalls[0] | Should -Match '^load\|HKLM\\WinUtilOfflineSoftware\|.*SOFTWARE$'
        $script:regCalls[1] | Should -Match '^add\|HKLM\\WinUtilOfflineSoftware\\Policies\\WinUtil\|/v\|Enabled\|/t\|REG_DWORD\|/d\|1\|/f$'
        $script:regCalls[2] | Should -Be 'unload|HKLM\WinUtilOfflineSoftware'
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

    It 'finds and discards a partial mount when mounting throws' {
        $script:mountAttempted = $false
        Mock Get-WindowsImage {
            if ($script:mountAttempted) { return @([pscustomobject]@{ Path = $script:mountPath; MountStatus = 'Invalid' }) }
            return @()
        } -ParameterFilter { $Mounted }
        Mock Mount-WindowsImage {
            $script:mountAttempted = $true
            throw 'injected mount failure'
        }
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Decisions = @() }

        { Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath } |
            Should -Throw '*injected mount failure*'

        Should -Invoke Get-WindowsImage -Times 2 -Exactly -ParameterFilter { $Mounted }
        Should -Invoke Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $Path -eq $script:mountPath -and $Discard }
        Should -Invoke Dismount-WindowsImage -Times 0 -Exactly -ParameterFilter { $Save }
    }

    It 'removes pending success manifests and discards when commit fails' {
        Mock Dismount-WindowsImage { throw 'injected commit failure' } -ParameterFilter { $Save }
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Decisions = @() }

        { Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath } |
            Should -Throw '*injected commit failure*'

        Should -Invoke Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $Save }
        Should -Invoke Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $Discard }
        @(Get-ChildItem -LiteralPath $script:manifestPath -File -ErrorAction SilentlyContinue).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $script:manifestPath -Directory -ErrorAction SilentlyContinue).Count | Should -Be 0
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

    It 'blocks a resolved plan whose safety evaluation is not allowed' {
        $plan = [pscustomobject]@{
            SchemaVersion = '1.0'
            Safety = [pscustomobject]@{ IsAllowed = $false; Conflicts = @('blocked') }
            Decisions = @()
        }

        { Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath } |
            Should -Throw '*safety evaluation is blocking*'
        Should -Invoke Mount-WindowsImage -Times 0 -Exactly
    }

    It 'routes driver injection and the resolved plan through one transaction mount' {
        $contentRoot = Join-Path $script:testRoot 'iso_contents'
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Decisions = @() }
        $script:transactionDriverDirectory = ''
        Mock Invoke-WinUtilOfflineServicingTransaction {
            $script:transactionDriverDirectory = $DriverDirectory
        }
        Mock Start-Process {
            $destinationMatch = [regex]::Match([string]$ArgumentList, '/destination:"([^"]+)"')
            $fixturePath = Join-Path $destinationMatch.Groups[1].Value 'storage_pkg'
            New-Item -Path $fixturePath -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $fixturePath 'iaStorAC.inf') -Value "[Version]`r`nClass=SCSIAdapter" -Encoding ASCII
            [pscustomobject]@{ ExitCode = 0 }
        } -ParameterFilter { $FilePath -eq 'dism.exe' }

        function dism.exe {
            param ([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
            $script:dismCalls.Add(($Arguments -join '|'))
            $global:LASTEXITCODE = 0
            if ($Arguments -contains '/Get-WimInfo') {
                'Languages : en-US'
                'Installation : Client'
                'Edition : Professional'
                'ProductSuite : Terminal Server'
                'ProductType : WinNT'
            }
        }

        Invoke-WinUtilISOScript -ISOContentsDir $contentRoot -AutoUnattendXml (Get-Content $script:autoUnattendPath -Raw) -InjectCurrentSystemDrivers $true -InstallImagePath $script:wimPath -InstallImageIndex 6 -ResolvedPlan $plan -ManifestDirectory $script:manifestPath

        Should -Invoke Invoke-WinUtilOfflineServicingTransaction -Times 1 -Exactly -ParameterFilter {
            $InstallImagePath -eq $script:wimPath -and $ImageIndex -eq 6 -and $ResolvedPlan -eq $plan -and $DriverDirectory
        }
        $script:transactionDriverDirectory | Should -Not -BeNullOrEmpty
        @($script:dismCalls | Where-Object { $_ -match '/Mount-Image|/Unmount-Image|/Add-Driver' }).Count | Should -Be 0
    }

    It 'uses one mount across analysis inventory and the servicing commit' {
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Safety = [pscustomobject]@{ IsAllowed = $true }; Decisions = @() }
        $session = Start-WinUtilOfflineServicingSession -InstallImagePath $script:wimPath -ImageIndex 6 -ImageName 'Windows 11 Pro' -MountPath $script:mountPath
        $session.Inventory.Source.ImagePath = $script:wimPath

        Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath -Session $session | Out-Null

        Should -Invoke Mount-WindowsImage -Times 1 -Exactly
        Should -Invoke Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $Save }
        $session.State | Should -Be 'Committed'
    }

    It 'marks an existing session discarded when servicing fails' {
        $session = Start-WinUtilOfflineServicingSession -InstallImagePath $script:wimPath -ImageIndex 6 -ImageName 'Windows 11 Pro' -MountPath $script:mountPath
        $session.Inventory.Source.ImagePath = $script:wimPath
        Mock Remove-WindowsPackage { throw 'session mutation failure' }
        $plan = [pscustomobject]@{
            SchemaVersion = '1.0'; Safety = [pscustomobject]@{ IsAllowed = $true }
            Decisions = @((New-TransactionDecision Package 'Remove.Package~test' Remove))
        }

        { Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath -Session $session } |
            Should -Throw '*session mutation failure*'
        $session.State | Should -Be 'Discarded'
    }

    It 'conservatively discards when session mount inspection fails' {
        $session = [pscustomobject]@{ State = 'Mounted'; MountPath = $script:mountPath }
        Mock Get-WindowsImage { throw 'inspection failure' } -ParameterFilter { $Mounted }

        Stop-WinUtilOfflineServicingSession -Session $session

        Should -Invoke Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $Discard }
        $session.State | Should -Be 'Discarded'
    }

    It 'services resolved Defender feature and package targets through the dedicated operation' {
        $feature = [pscustomobject]@{ Kind = 'Feature'; Name = 'Windows-Defender-Feature'; Identity = 'Windows-Defender-Feature'; State = 'Enabled' }
        $package = [pscustomobject]@{ Kind = 'Package'; Name = 'Microsoft-Windows-Windows-Defender-Package'; Identity = 'Microsoft-Windows-Windows-Defender-Package~31bf~amd64~~10.0.26200.1'; State = 'Installed' }
        $script:beforeItems = @($feature, $package)
        $script:afterItems = @([pscustomobject]@{ Kind = 'Feature'; Name = $feature.Name; Identity = $feature.Identity; State = 'DisabledWithPayloadRemoved' })
        $decisions = @(
            (New-TransactionDecision Feature $feature.Identity Remove),
            (New-TransactionDecision Package $package.Identity Remove)
        )
        foreach ($defenderDecision in $decisions) { $defenderDecision.PolicyId = 'defender' }
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Safety = [pscustomobject]@{ IsAllowed = $true }; Decisions = $decisions }
        $operation = [pscustomobject]@{ Operation = 'RemoveDefenderOffline'; SourceComponentId = 'defender'; Targets = @(
            [pscustomobject]@{ Kind = 'Feature'; Identity = $feature.Identity },
            [pscustomobject]@{ Kind = 'Package'; Identity = $package.Identity }
        ) }

        Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath -SecurityOperation $operation | Out-Null

        Should -Invoke Disable-WindowsOptionalFeature -Times 1 -Exactly -ParameterFilter { $FeatureName -eq $feature.Identity -and $Remove }
        Should -Invoke Remove-WindowsPackage -Times 1 -Exactly -ParameterFilter { $PackageName -eq $package.Identity }
        Should -Invoke Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $Save }
    }

    It 'rejects missing, duplicate, and non-Defender security targets before mounting' {
        $defenderDecision = New-TransactionDecision Package 'Microsoft-Windows-Windows-Defender-Package~test' Remove
        $defenderDecision.PolicyId = 'defender'
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Safety = [pscustomobject]@{ IsAllowed = $true }; Decisions = @($defenderDecision) }
        $missing = [pscustomobject]@{ Operation = 'RemoveDefenderOffline'; SourceComponentId = 'defender'; Targets = @() }
        { Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath -SecurityOperation $missing } |
            Should -Throw '*requires at least one resolved Defender*'
        { Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath } |
            Should -Throw '*require the dedicated RemoveDefenderOffline*'

        $target = [pscustomobject]@{ Kind = 'Package'; Identity = $defenderDecision.Identity }
        $duplicate = [pscustomobject]@{ Operation = 'RemoveDefenderOffline'; SourceComponentId = 'defender'; Targets = @($target, $target) }
        { Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath -SecurityOperation $duplicate } |
            Should -Throw '*duplicate target*'

        $retarget = [pscustomobject]@{ Operation = 'RemoveDefenderOffline'; SourceComponentId = 'not-defender'; Targets = @($target) }
        { Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath -SecurityOperation $retarget } |
            Should -Throw '*exact RemoveDefenderOffline contract sourced by defender*'

        $updateDecision = New-TransactionDecision Package 'Microsoft-Windows-WindowsUpdate-Package~test' Remove
        $updateDecision.PolicyId = 'defender'
        $updatePlan = [pscustomobject]@{ SchemaVersion = '1.0'; Safety = [pscustomobject]@{ IsAllowed = $true }; Decisions = @($updateDecision) }
        $updateOperation = [pscustomobject]@{ Operation = 'RemoveDefenderOffline'; SourceComponentId = 'defender'; Targets = @([pscustomobject]@{ Kind = 'Package'; Identity = $updateDecision.Identity }) }
        { Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $updatePlan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath -SecurityOperation $updateOperation } |
            Should -Throw '*overlaps protected servicing or Windows Update*'
        Should -Invoke Mount-WindowsImage -Times 0 -Exactly
    }

    It 'discards instead of committing when Defender after-state verification is partial' {
        $package = [pscustomobject]@{ Kind = 'Package'; Name = 'Microsoft-Windows-Windows-Defender-Package'; Identity = 'Microsoft-Windows-Windows-Defender-Package~test'; State = 'Installed' }
        $script:beforeItems = @($package)
        $script:afterItems = @($package)
        $decision = New-TransactionDecision Package $package.Identity Remove
        $decision.PolicyId = 'defender'
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Safety = [pscustomobject]@{ IsAllowed = $true }; Decisions = @($decision) }
        $operation = [pscustomobject]@{ Operation = 'RemoveDefenderOffline'; SourceComponentId = 'defender'; Targets = @([pscustomobject]@{ Kind = 'Package'; Identity = $package.Identity }) }

        { Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath -SecurityOperation $operation } |
            Should -Throw '*verification failed*remains*'
        Should -Invoke Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $Discard }
        Should -Invoke Dismount-WindowsImage -Times 0 -Exactly -ParameterFilter { $Save }
    }

    It 'discards when a successful generic cmdlet is a no-op' {
        $app = [pscustomobject]@{ Kind = 'AppX'; Name = 'Microsoft.Copilot'; Identity = 'Microsoft.Copilot_1.0_neutral_test'; State = 'Provisioned' }
        $script:beforeItems = @($app)
        $script:afterItems = @($app)
        $decision = New-TransactionDecision AppX $app.Identity Remove
        $decision.PolicyId = 'copilot'
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Safety = [pscustomobject]@{ IsAllowed = $true }; Decisions = @($decision) }

        { Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath } |
            Should -Throw '*verification failed*remains provisioned*'
        Should -Invoke Remove-AppxProvisionedPackage -Times 1 -Exactly
        Should -Invoke Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $Discard }
        Should -Invoke Dismount-WindowsImage -Times 0 -Exactly -ParameterFilter { $Save }
    }

    It 'discards when protected collateral disappears' {
        $remove = [pscustomobject]@{ Kind = 'Package'; Name = 'Microsoft-Windows-Client-AIX-Package'; Identity = 'Microsoft-Windows-Client-AIX-Package~test'; State = 'Installed' }
        $protected = [pscustomobject]@{ Kind = 'Package'; Name = 'Microsoft-Windows-Client-CBS-Package'; Identity = 'Microsoft-Windows-Client-CBS-Package~test'; State = 'Installed' }
        $script:beforeItems = @($remove, $protected)
        $script:afterItems = @()
        $removeDecision = New-TransactionDecision Package $remove.Identity Remove
        $removeDecision.PolicyId = 'windows-ai'
        $protectedDecision = New-TransactionDecision Package $protected.Identity Protected
        $protectedDecision.PolicyId = 'client-cbs'
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Safety = [pscustomobject]@{ IsAllowed = $true }; Decisions = @($removeDecision, $protectedDecision) }

        { Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath } |
            Should -Throw '*collateral verification failed*Protected*Client-CBS*'
        Should -Invoke Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $Discard }
    }

    It 'enforces absent Lean concept targets while preserving WebView2 and Client CBS' {
        $conceptItems = @(
            [pscustomobject]@{ Kind = 'AppX'; Name = 'MicrosoftWindows.Client.WebExperience'; Identity = 'WebExperience_1.0'; State = 'Provisioned'; PolicyId = 'widgets-webexperience' }
            [pscustomobject]@{ Kind = 'AppX'; Name = 'Microsoft.Copilot'; Identity = 'Copilot_1.0'; State = 'Provisioned'; PolicyId = 'copilot' }
            [pscustomobject]@{ Kind = 'AppX'; Name = 'Microsoft.WindowsFeedbackHub'; Identity = 'Feedback_1.0'; State = 'Provisioned'; PolicyId = 'feedback-hub' }
            [pscustomobject]@{ Kind = 'AppX'; Name = 'Microsoft.BingNews'; Identity = 'BingNews_1.0'; State = 'Provisioned'; PolicyId = 'consumer-appx' }
            [pscustomobject]@{ Kind = 'AppX'; Name = 'Microsoft.XboxApp'; Identity = 'Xbox_1.0'; State = 'Provisioned'; PolicyId = 'xbox-gaming' }
            [pscustomobject]@{ Kind = 'AppX'; Name = 'Microsoft.OneDriveSync'; Identity = 'OneDrive_1.0'; State = 'Provisioned'; PolicyId = 'onedrive' }
            [pscustomobject]@{ Kind = 'Package'; Name = 'Microsoft-Windows-Client-AIX-Package'; Identity = 'AIX~test'; State = 'Installed'; PolicyId = 'windows-ai' }
            [pscustomobject]@{ Kind = 'Package'; Name = 'Microsoft-Windows-OneDrive-Package'; Identity = 'OneDrivePackage~test'; State = 'Installed'; PolicyId = 'onedrive' }
        )
        $protectedItems = @(
            [pscustomobject]@{ Kind = 'Package'; Name = 'Microsoft-Windows-WebView2Runtime-Package'; Identity = 'WebView2~test'; State = 'Installed'; PolicyId = 'webview2' }
            [pscustomobject]@{ Kind = 'Package'; Name = 'Microsoft-Windows-Client-CBS-Package'; Identity = 'ClientCBS~test'; State = 'Installed'; PolicyId = 'client-cbs' }
        )
        $script:beforeItems = @($conceptItems) + @($protectedItems)
        $script:afterItems = @($protectedItems)
        $decisions = @($conceptItems | ForEach-Object {
            $decision = New-TransactionDecision $_.Kind $_.Identity Remove; $decision.PolicyId = $_.PolicyId; $decision
        }) + @($protectedItems | ForEach-Object {
            $decision = New-TransactionDecision $_.Kind $_.Identity Protected; $decision.PolicyId = $_.PolicyId; $decision
        })
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Safety = [pscustomobject]@{ IsAllowed = $true }; Decisions = $decisions }

        Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath | Out-Null

        Should -Invoke Remove-AppxProvisionedPackage -Times 6 -Exactly
        Should -Invoke Remove-WindowsPackage -Times 2 -Exactly
        Should -Invoke Remove-WindowsPackage -Times 0 -Exactly -ParameterFilter { $PackageName -in @('WebView2~test', 'ClientCBS~test') }
        Should -Invoke Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $Save }
    }

    It 'runs CheckHealth without ScanHealth when no servicing package is removed' {
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Safety = [pscustomobject]@{ IsAllowed = $true }; Decisions = @() }

        Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath | Out-Null

        $script:dismCalls | Where-Object { $_ -match '/CheckHealth' } | Should -HaveCount 1
        $script:dismCalls | Where-Object { $_ -match '/ScanHealth' } | Should -HaveCount 0
        Should -Invoke Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $Save }
    }

    It 'discards when DISM health output reports a repairable component store' {
        function dism.exe {
            param ([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
            $script:dismCalls.Add(($Arguments -join '|'))
            $global:LASTEXITCODE = 0
            if ($Arguments -contains '/CheckHealth') { 'The component store is repairable.' }
        }
        $plan = [pscustomobject]@{ SchemaVersion = '1.0'; Safety = [pscustomobject]@{ IsAllowed = $true }; Decisions = @() }

        { Invoke-WinUtilOfflineServicingTransaction -InstallImagePath $script:wimPath -ImageIndex 6 -ResolvedPlan $plan -MountPath $script:mountPath -ManifestDirectory $script:manifestPath } |
            Should -Throw '*component-store corruption*discarded*'
        Should -Invoke Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $Discard }
        Should -Invoke Dismount-WindowsImage -Times 0 -Exactly -ParameterFilter { $Save }
    }
}
