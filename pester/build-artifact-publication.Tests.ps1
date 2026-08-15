#===========================================================================
# Tests - Durable Win11 Creator build artifact publication
#===========================================================================

Describe 'Durable build artifact publication' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $script:repoRoot 'functions/private/Publish-WinUtilBuildArtifact.ps1')
        $script:schema = Get-Content -LiteralPath (Join-Path $script:repoRoot 'schemas/winutil-offline-manifests.v1.schema.json') -Raw | ConvertFrom-Json
    }

    BeforeEach {
        $script:testRoot = Join-Path ([IO.Path]::GetTempPath()) "WinUtilPublication_$([guid]::NewGuid().ToString('N'))"
        $script:manifestDirectory = Join-Path $script:testRoot 'transaction-manifests'
        $script:outputPath = Join-Path $script:testRoot 'Win11.iso'
        $script:logPath = Join-Path $script:testRoot 'WinUtil_Win11ISO.log'
        New-Item -Path $script:manifestDirectory -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath $script:outputPath -Value 'completed iso bytes'
        Set-Content -LiteralPath $script:logPath -Value 'normal build log'
        $source = [ordered]@{ ImagePath = 'install.wim'; ImageIndex = 6; ImageName = 'Windows 11 Pro' }
        $manifestFixtures = [ordered]@{
            'ResolvedPlan.json' = [ordered]@{ SchemaVersion = '1.0'; ManifestType = 'ResolvedPlan'; Source = $source; Decisions = @() }
            'ImageInventory.before.json' = [ordered]@{ SchemaVersion = '1.0'; ManifestType = 'ImageInventoryBefore'; Source = $source; Items = @() }
            'ImageInventory.after.json' = [ordered]@{ SchemaVersion = '1.0'; ManifestType = 'ImageInventoryAfter'; Source = $source; Items = @() }
            'ImageInventory.diff.json' = [ordered]@{ SchemaVersion = '1.0'; ManifestType = 'ImageInventoryDiff'; Source = $source; Changes = @() }
        }
        $manifestFixtures.GetEnumerator() | ForEach-Object {
            $_.Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:manifestDirectory $_.Key)
        }
        Set-Content -LiteralPath (Join-Path $script:manifestDirectory 'ResolvedPlan.txt') -Value 'Image: install.wim [index 6] Windows 11 Pro'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'uses the checked-in v1 schema requirements for every produced JSON contract' {
        $contractMap = [ordered]@{
            resolvedPlan = 'ResolvedPlan.json'
            inventoryBefore = 'ImageInventory.before.json'
            inventoryAfter = 'ImageInventory.after.json'
            inventoryDiff = 'ImageInventory.diff.json'
        }
        foreach ($entry in $contractMap.GetEnumerator()) {
            $contract = $script:schema.'$defs'.($entry.Key)
            $manifest = Get-Content -LiteralPath (Join-Path $script:manifestDirectory $entry.Value) -Raw | ConvertFrom-Json
            foreach ($requiredProperty in @($contract.required)) {
                $manifest.PSObject.Properties.Name | Should -Contain $requiredProperty
            }
            $manifest.SchemaVersion | Should -Be $contract.properties.SchemaVersion.const
            $manifest.ManifestType | Should -Be $contract.properties.ManifestType.const
        }
    }

    It 'atomically publishes deterministic evidence names and SHA-256 digests' {
        $result = Publish-WinUtilBuildArtifact -OutputPath $script:outputPath -ManifestDirectory $script:manifestDirectory -BuildLogPath $script:logPath

        $result.EvidenceDirectory | Should -Be (Join-Path $script:testRoot 'Win11.WinUtil-build')
        Test-Path -LiteralPath $result.HashFile | Should -BeTrue
        foreach ($name in 'ResolvedPlan.json', 'ResolvedPlan.txt', 'ImageInventory.before.json', 'ImageInventory.after.json', 'ImageInventory.diff.json', 'WinUtil.build.log', 'SHA256SUMS.txt') {
            Test-Path -LiteralPath (Join-Path $result.EvidenceDirectory $name) -PathType Leaf | Should -BeTrue
        }
        $hashLines = @(Get-Content -LiteralPath $result.HashFile)
        $hashLines | Should -HaveCount 7
        $hashLines[0] | Should -Match '^[A-F0-9]{64} \*Win11\.iso$'
        @(Get-ChildItem -LiteralPath $script:testRoot -Directory -Filter '.*.pending-*').Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:manifestDirectory 'ResolvedPlan.json') | Should -BeTrue
    }

    It 'hashes a USB output tree before publishing evidence inside it' {
        $usbRoot = Join-Path $script:testRoot 'USB'
        New-Item -Path (Join-Path $usbRoot 'sources') -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $usbRoot 'bootmgr') -Value 'boot manager'
        Set-Content -LiteralPath (Join-Path $usbRoot 'sources/install.wim') -Value 'install image'

        $result = Publish-WinUtilBuildArtifact -OutputPath $usbRoot -ManifestDirectory $script:manifestDirectory -BuildLogPath $script:logPath

        $result.EvidenceDirectory | Should -Be (Join-Path $usbRoot 'WinUtil-build')
        (Get-Content -LiteralPath $result.HashFile)[0] | Should -Match '^[A-F0-9]{64} \*USB-CONTENT$'
    }

    It 'plants the negative that a missing required manifest cannot publish' {
        Remove-Item -LiteralPath (Join-Path $script:manifestDirectory 'ImageInventory.after.json')

        { Publish-WinUtilBuildArtifact -OutputPath $script:outputPath -ManifestDirectory $script:manifestDirectory -BuildLogPath $script:logPath } |
            Should -Throw '*Required ImageInventoryAfter manifest was not found*'
        Test-Path -LiteralPath (Join-Path $script:testRoot 'Win11.WinUtil-build') | Should -BeFalse
    }

    It 'rejects an empty completed output or build log' {
        Set-Content -LiteralPath $script:outputPath -Value '' -NoNewline
        { Publish-WinUtilBuildArtifact -OutputPath $script:outputPath -ManifestDirectory $script:manifestDirectory -BuildLogPath $script:logPath } |
            Should -Throw '*Completed output is empty*'

        Set-Content -LiteralPath $script:outputPath -Value 'completed iso bytes'
        Set-Content -LiteralPath $script:logPath -Value '' -NoNewline
        { Publish-WinUtilBuildArtifact -OutputPath $script:outputPath -ManifestDirectory $script:manifestDirectory -BuildLogPath $script:logPath } |
            Should -Throw '*build log was not found or is empty*'
    }

    It 'plants the negative that an invalid hash cleans partial publication' {
        $invalidHash = { param($path) $null = $path; 'not-a-sha256' }

        { Publish-WinUtilBuildArtifact -OutputPath $script:outputPath -ManifestDirectory $script:manifestDirectory -BuildLogPath $script:logPath -GetHash $invalidHash } |
            Should -Throw '*invalid digest*'
        Test-Path -LiteralPath (Join-Path $script:testRoot 'Win11.WinUtil-build') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:testRoot -Directory -Filter '.*.pending-*').Count | Should -Be 0
    }

    It 'plants the negative that a copy failure cleans partial publication without deleting transaction manifests' {
        $copyCount = 0
        $failingCopy = {
            param($source, $destination)
            $script:copyCount++
            if ($script:copyCount -eq 2) { throw 'injected copy failure' }
            Copy-Item -LiteralPath $source -Destination $destination -ErrorAction Stop
        }

        { Publish-WinUtilBuildArtifact -OutputPath $script:outputPath -ManifestDirectory $script:manifestDirectory -BuildLogPath $script:logPath -CopyFile $failingCopy } |
            Should -Throw '*injected copy failure*'
        Test-Path -LiteralPath (Join-Path $script:testRoot 'Win11.WinUtil-build') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:testRoot -Directory -Filter '.*.pending-*').Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:manifestDirectory 'ResolvedPlan.json') | Should -BeTrue
    }
}
