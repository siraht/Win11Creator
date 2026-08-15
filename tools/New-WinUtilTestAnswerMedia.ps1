[CmdletBinding()]
param (
    [string]$OutputPath,
    [string]$Edition,
    [pscredential]$GuestCredential,
    [string]$OscdimgPath = 'oscdimg.exe',
    [scriptblock]$MediaBuilder,
    [switch]$PassThru
)

function New-WinUtilTestAnswerMedia {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 .()_-]{0,79}$')][string]$Edition,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [string]$OscdimgPath = 'oscdimg.exe',
        [scriptblock]$MediaBuilder
    )

    if (-not $PSCmdlet.ShouldProcess($OutputPath, 'Generate ephemeral Windows Setup answer ISO')) { return }
    $userName = $GuestCredential.UserName
    if ($userName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$' -or $userName -match '^(?i:administrator|defaultaccount|guest|wdagutilityaccount)$') {
        throw 'Guest credential user name must be a non-reserved local account name using 1-20 letters, digits, dot, underscore, or hyphen.'
    }
    if (Test-Path -LiteralPath $OutputPath) { throw "Answer-media output '$OutputPath' already exists." }
    $outputParent = Split-Path -Parent $OutputPath
    if (-not $outputParent) { throw 'Answer-media output must include a parent directory.' }
    if (-not (Test-Path -LiteralPath $outputParent)) { New-Item -Path $outputParent -ItemType Directory -Force | Out-Null }

    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($GuestCredential.Password)
    try { $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer) }
    if ([string]::IsNullOrWhiteSpace($plainPassword)) { throw 'Guest credential password must not be empty.' }
    $escapedPassword = [Security.SecurityElement]::Escape($plainPassword)
    $escapedEdition = [Security.SecurityElement]::Escape($Edition)
    $escapedUserName = [Security.SecurityElement]::Escape($userName)

    $answerXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <DiskConfiguration>
        <Disk wcm:action="add"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>100</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
        <WillShowUI>OnError</WillShowUI>
      </DiskConfiguration>
      <ImageInstall><OSImage>
        <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>$escapedEdition</Value></MetaData></InstallFrom>
        <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
        <WillShowUI>OnError</WillShowUI>
      </OSImage></ImageInstall>
      <UserData><AcceptEula>true</AcceptEula></UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><ComputerName>*</ComputerName></component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale></component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE><HideEULAPage>true</HideEULAPage><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC></OOBE>
      <UserAccounts><LocalAccounts><LocalAccount wcm:action="add"><Name>$escapedUserName</Name><DisplayName>$escapedUserName</DisplayName><Group>Administrators</Group><Password><Value>$escapedPassword</Value><PlainText>true</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts>
      <AutoLogon><Enabled>true</Enabled><LogonCount>1</LogonCount><Username>$escapedUserName</Username><Password><Value>$escapedPassword</Value><PlainText>true</PlainText></Password></AutoLogon>
      <FirstLogonCommands><SynchronousCommand wcm:action="add"><Order>1</Order><Description>Signal WinUtil validation readiness</Description><CommandLine>cmd.exe /c mkdir C:\ProgramData\WinUtilAcceptance 2&gt;nul &amp; echo ready&gt;C:\ProgramData\WinUtilAcceptance\first-logon.ready</CommandLine></SynchronousCommand></FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@

    $stagingDirectory = Join-Path ([IO.Path]::GetTempPath()) "WinUtilAnswer_$([guid]::NewGuid().ToString('N'))"
    $generated = $false
    try {
        New-Item -Path $stagingDirectory -ItemType Directory -Force | Out-Null
        $answerPath = Join-Path $stagingDirectory 'autounattend.xml'
        Set-Content -LiteralPath $answerPath -Value $answerXml -Encoding utf8
        [xml](Get-Content -LiteralPath $answerPath -Raw) | Out-Null
        if (-not $MediaBuilder) {
            $MediaBuilder = {
                param ($SourceDirectory, $DestinationPath, $ToolPath)
                $output = & $ToolPath '-n' '-m' '-o' '-u2' '-udfver102' '-lWINUTIL_ANSWER' '-t01/01/2000,00:00:00' $SourceDirectory $DestinationPath 2>&1 | Out-String
                [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
            }
        }
        $build = & $MediaBuilder $stagingDirectory $OutputPath $OscdimgPath
        if ([int]$build.ExitCode -ne 0) { throw "Answer-media generation failed with exit code $($build.ExitCode)." }
        if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf) -or (Get-Item -LiteralPath $OutputPath).Length -eq 0) { throw 'Answer-media generator did not produce a nonempty ISO.' }
        $generated = $true
        [pscustomobject]@{ SchemaVersion = '1.0'; MediaVersion = '1.0.0'; Path = $OutputPath; Edition = $Edition; Sha256 = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash }
    } finally {
        $plainPassword = $null
        $escapedPassword = $null
        $answerXml = $null
        if (Test-Path -LiteralPath $stagingDirectory) { Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue }
        if (-not $generated -and (Test-Path -LiteralPath $OutputPath)) { Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue }
    }
}

function Remove-WinUtilTestAnswerMedia {
    [CmdletBinding(SupportsShouldProcess)]
    param ([Parameter(Mandatory)][string]$Path)
    if ($PSCmdlet.ShouldProcess($Path, 'Remove ephemeral Windows Setup answer ISO') -and (Test-Path -LiteralPath $Path -PathType Leaf)) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = New-WinUtilTestAnswerMedia -OutputPath $OutputPath -Edition $Edition -GuestCredential $GuestCredential -OscdimgPath $OscdimgPath -MediaBuilder $MediaBuilder
    if ($PassThru) { $result }
}
