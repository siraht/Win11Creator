#===========================================================================
# Tests - Policy-driven setup action consumer
#===========================================================================

Describe 'Policy-driven setup action consumer' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:isoScriptPath = Join-Path $script:repoRoot 'functions/private/Invoke-WinUtilISOScript.ps1'
        $script:template = Get-Content -LiteralPath (Join-Path $script:repoRoot 'tools/autounattend.xml') -Raw
        . $script:isoScriptPath

        function New-TestActionBundle {
            param ([object[]]$SetupActions = @(), [object[]]$RegistryActions = @())
            [pscustomobject]@{
                SchemaVersion = '1.0'
                IsAllowed = $true
                Safety = [pscustomobject]@{ IsAllowed = $true; Conflicts = @() }
                RegistryActions = $RegistryActions
                SetupActions = $SetupActions
            }
        }

        function New-TestTaskAction {
            param ([string]$TaskPath)
            [pscustomobject]@{
                Mechanism = 'schtasks-change-disable'
                Phase = 'specialize'
                Executable = 'schtasks.exe'
                Arguments = @('/Change', '/TN', $TaskPath, '/Disable')
                SourceComponentId = 'telemetry-consumer-content'
            }
        }
    }

    It 'SetupConsumer_DefaultCompatibilityDoesNotInjectBlanketPostInstall' {
        $contentRoot = Join-Path ([IO.Path]::GetTempPath()) "WinUtilDefaultSetup_$([guid]::NewGuid())"
        try {
            New-Item -Path $contentRoot -ItemType Directory -Force | Out-Null
            Invoke-WinUtilISOScript -ISOContentsDir $contentRoot -AutoUnattendXml $script:template -InstallEditionId 'Professional' -InstallImageIndex 6

            [xml]$answerFile = Get-Content -LiteralPath (Join-Path $contentRoot 'autounattend.xml') -Raw
            $nsMgr = New-Object System.Xml.XmlNamespaceManager($answerFile.NameTable)
            $nsMgr.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
            $nsMgr.AddNamespace('sg', 'https://schneegans.de/windows/unattend-generator/')
            $answerFile.SelectSingleNode('//sg:File[@path="C:\Windows\Setup\Scripts\WinUtil-PostInstall.ps1"]', $nsMgr) | Should -BeNullOrEmpty
            $answerFile.SelectSingleNode('//sg:File[@path="C:\Windows\Setup\Scripts\WinUtil-PolicySetup.ps1"]', $nsMgr) | Should -BeNullOrEmpty
            $answerFile.SelectSingleNode('//sg:File[@path="C:\Windows\Setup\Scripts\FirstLogon.ps1"]', $nsMgr).InnerText | Should -Not -Match 'WinUtil-PostInstall|Remove-Appx|TaskCache'
            $answerFile.SelectSingleNode('/u:unattend/u:settings[@pass="windowsPE"]/u:component[@name="Microsoft-Windows-Setup"]/u:ImageInstall/u:OSImage/u:InstallFrom/u:MetaData/u:Value', $nsMgr).InnerText | Should -Be '6'
        } finally {
            Remove-Item -LiteralPath $contentRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'SetupConsumer_StagesExactQuotedTaskDisableAtSpecialize' {
        $contentRoot = Join-Path ([IO.Path]::GetTempPath()) "WinUtilPolicySetup_$([guid]::NewGuid())"
        $taskPath = '\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask'
        $bundle = New-TestActionBundle -SetupActions @((New-TestTaskAction -TaskPath $taskPath))
        try {
            New-Item -Path $contentRoot -ItemType Directory -Force | Out-Null
            Invoke-WinUtilISOScript -ISOContentsDir $contentRoot -AutoUnattendXml $script:template -InstallEditionId 'Professional' -ActionBundle $bundle

            [xml]$answerFile = Get-Content -LiteralPath (Join-Path $contentRoot 'autounattend.xml') -Raw
            $nsMgr = New-Object System.Xml.XmlNamespaceManager($answerFile.NameTable)
            $nsMgr.AddNamespace('sg', 'https://schneegans.de/windows/unattend-generator/')
            $policyScript = $answerFile.SelectSingleNode('//sg:File[@path="C:\Windows\Setup\Scripts\WinUtil-PolicySetup.ps1"]', $nsMgr).InnerText
            ($policyScript -replace "`r`n", "`n") | Should -Be ("`$ErrorActionPreference = 'Stop'`n& `"`$env:SystemRoot\System32\schtasks.exe`" /Change /TN '$taskPath' /Disable")
            $answerFile.SelectSingleNode('//sg:File[@path="C:\Windows\Setup\Scripts\Specialize.ps1"]', $nsMgr).InnerText | Should -Match ([regex]::Escape("& 'C:\Windows\Setup\Scripts\WinUtil-PolicySetup.ps1';"))
            Get-Content -LiteralPath (Join-Path $contentRoot 'sources\$OEM$\$$\Setup\Scripts\WinUtil-PolicySetup.ps1') -Raw | Should -Match ([regex]::Escape("/TN '$taskPath' /Disable"))
        } finally {
            Remove-Item -LiteralPath $contentRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'SetupConsumer_UnsafeTaskPath_PlantedNegative' {
        $bundle = New-TestActionBundle -SetupActions @((New-TestTaskAction -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\*'))
        { Invoke-WinUtilISOScript -ISOContentsDir ([IO.Path]::GetTempPath()) -AutoUnattendXml $script:template -InstallEditionId 'Professional' -ActionBundle $bundle } |
            Should -Throw '*Unsafe scheduled-task path*wildcards*not allowed*'
    }

    It 'SetupConsumer_UnsafeCommand_PlantedNegative' {
        $action = New-TestTaskAction -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'
        $action.Executable = 'powershell.exe'
        $bundle = New-TestActionBundle -SetupActions @($action)
        { Invoke-WinUtilISOScript -ISOContentsDir ([IO.Path]::GetTempPath()) -AutoUnattendXml $script:template -InstallEditionId 'Professional' -ActionBundle $bundle } |
            Should -Throw '*only exact schtasks disable intents are accepted*'
    }

    It 'SetupConsumer_MissingRegistryStaging_PlantedNegative' {
        $registryAction = [pscustomobject]@{ Action = 'Set'; Hive = 'SOFTWARE'; Key = 'Policies\Test'; Name = 'Enabled'; Type = 'REG_DWORD'; Value = 1 }
        $bundle = New-TestActionBundle -RegistryActions @($registryAction)
        { Invoke-WinUtilISOScript -ISOContentsDir ([IO.Path]::GetTempPath()) -AutoUnattendXml $script:template -InstallEditionId 'Professional' -ActionBundle $bundle } |
            Should -Throw '*has no concrete offline transaction consumer*'
    }

    It 'SetupConsumer_LeanScriptPreservesProtectedInfrastructure' {
        $actions = @(
            New-TestTaskAction -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'
            New-TestTaskAction -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask'
        )
        $bundle = New-TestActionBundle -SetupActions $actions
        $contentRoot = Join-Path ([IO.Path]::GetTempPath()) "WinUtilProtectedSetup_$([guid]::NewGuid())"
        try {
            New-Item -Path $contentRoot -ItemType Directory -Force | Out-Null
            Invoke-WinUtilISOScript -ISOContentsDir $contentRoot -AutoUnattendXml $script:template -InstallEditionId 'Professional' -ActionBundle $bundle
            $policyScript = Get-Content -LiteralPath (Join-Path $contentRoot 'sources\$OEM$\$$\Setup\Scripts\WinUtil-PolicySetup.ps1') -Raw
            $policyScript | Should -Not -Match 'Windows Error Reporting|Application Experience|BITS|wuauserv|UsoSvc|WaaSMedicSvc|Remove-Item|TaskCache|/Delete'
        } finally {
            Remove-Item -LiteralPath $contentRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
