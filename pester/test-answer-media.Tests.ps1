BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:repoRoot 'tools/New-WinUtilTestAnswerMedia.ps1')

    function New-TestCredential {
        param ([string]$UserName = 'WinUtilTest', [string]$Password = 'Fixture-Secret-42!')
        [pscredential]::new($UserName, (ConvertTo-SecureString $Password -AsPlainText -Force))
    }
}

Describe 'Ephemeral Hyper-V test answer media' {
    It 'TestAnswerMedia_GeneratesExactGptEditionAccountAndReadinessContract' {
        $capture = [pscustomobject]@{ Xml = $null; StagingPath = $null }
        $builder = {
            param ($SourceDirectory, $DestinationPath, $ToolPath)
            $capture.StagingPath = $SourceDirectory
            $capture.Xml = Get-Content -LiteralPath (Join-Path $SourceDirectory 'autounattend.xml') -Raw
            Set-Content -LiteralPath $DestinationPath -Value 'fixture ISO bytes'
            [pscustomobject]@{ ExitCode = 0; Output = 'built' }
        }.GetNewClosure()
        $output = Join-Path $TestDrive 'answer.iso'
        $result = New-WinUtilTestAnswerMedia -OutputPath $output -Edition 'Windows 11 Pro' -GuestCredential (New-TestCredential) -MediaBuilder $builder

        $result.MediaVersion | Should -Be '1.0.0'
        $result.Edition | Should -Be 'Windows 11 Pro'
        $result.Sha256 | Should -Match '^[A-F0-9]{64}$'
        Test-Path -LiteralPath $capture.StagingPath | Should -BeFalse
        [xml]$answer = $capture.Xml
        $ns = [Xml.XmlNamespaceManager]::new($answer.NameTable)
        $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        $answer.SelectSingleNode('//u:Disk/u:WillWipeDisk', $ns).InnerText | Should -Be 'true'
        $answer.SelectSingleNode('//u:CreatePartition[u:Order="1"]/u:Type', $ns).InnerText | Should -Be 'EFI'
        $answer.SelectSingleNode('//u:CreatePartition[u:Order="2"]/u:Type', $ns).InnerText | Should -Be 'MSR'
        $answer.SelectSingleNode('//u:InstallTo/u:DiskID', $ns).InnerText | Should -Be '0'
        $answer.SelectSingleNode('//u:InstallTo/u:PartitionID', $ns).InnerText | Should -Be '3'
        $answer.SelectSingleNode('//u:MetaData/u:Value', $ns).InnerText | Should -Be 'Windows 11 Pro'
        $answer.SelectSingleNode('//u:LocalAccount/u:Name', $ns).InnerText | Should -Be 'WinUtilTest'
        $answer.SelectSingleNode('//u:AutoLogon/u:Username', $ns).InnerText | Should -Be 'WinUtilTest'
        $answer.SelectSingleNode('//u:FirstLogonCommands/u:SynchronousCommand/u:CommandLine', $ns).InnerText | Should -Match 'first-logon\.ready'
    }

    It 'TestAnswerMedia_MalformedEdition_PlantedNegative' {
        { New-WinUtilTestAnswerMedia -OutputPath (Join-Path $TestDrive 'bad-edition.iso') -Edition 'Windows 11 Pro<script>' -GuestCredential (New-TestCredential) -MediaBuilder { } } |
            Should -Throw '*does not match*'
    }

    It 'TestAnswerMedia_MalformedCredential_PlantedNegative' {
        { New-WinUtilTestAnswerMedia -OutputPath (Join-Path $TestDrive 'bad-user.iso') -Edition 'Windows 11 Pro' -GuestCredential (New-TestCredential -UserName 'Administrator') -MediaBuilder { } } |
            Should -Throw '*non-reserved local account name*'
    }

    It 'TestAnswerMedia_MediaGenerationFailureRemovesPartialMedia_PlantedNegative' {
        $output = Join-Path $TestDrive 'partial.iso'
        $builder = {
            param ($SourceDirectory, $DestinationPath)
            Set-Content -LiteralPath $DestinationPath -Value partial
            [pscustomobject]@{ ExitCode = 7; Output = 'planted failure' }
        }
        { New-WinUtilTestAnswerMedia -OutputPath $output -Edition 'Windows 11 Pro' -GuestCredential (New-TestCredential) -MediaBuilder $builder } |
            Should -Throw '*exit code 7*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'TestAnswerMedia_ResultAndFailureNeverExposeCredentialSecret' {
        $secret = 'DoNotLeak-9851!'
        $output = Join-Path $TestDrive 'no-secret.iso'
        $result = New-WinUtilTestAnswerMedia -OutputPath $output -Edition 'Windows 11 Pro' -GuestCredential (New-TestCredential -Password $secret) -MediaBuilder {
            param ($SourceDirectory, $DestinationPath)
            Set-Content -LiteralPath $DestinationPath -Value media
            [pscustomobject]@{ ExitCode = 0; Output = 'builder output' }
        }
        ($result | ConvertTo-Json -Depth 4) | Should -Not -Match ([regex]::Escape($secret))

        $failureText = try {
            New-WinUtilTestAnswerMedia -OutputPath (Join-Path $TestDrive 'failed-secret.iso') -Edition 'Windows 11 Pro' -GuestCredential (New-TestCredential -Password $secret) -MediaBuilder { [pscustomobject]@{ ExitCode = 3; Output = $secret } }
        } catch { $_ | Out-String }
        $failureText | Should -Not -Match ([regex]::Escape($secret))
    }
}
