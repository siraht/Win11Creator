[CmdletBinding()]
param (
    [string]$SourceIsoPath,
    [ValidateRange(1, 2147483647)][int]$ImageIndex = 1,
    [Alias('Profile')][ValidateSet('default-winutil', 'lean-daw', 'lean-daw-defender-retained')][string]$ComponentProfile,
    [string]$OutputIsoPath,
    [string]$WorkDirectory,
    [string]$OscdimgPath,
    [string]$DriverDirectory = '',
    [switch]$ExpertMode,
    [switch]$RemoveWorkDirectoryOnSuccess
)

$script:WinUtilRepositoryRoot = Split-Path -Parent $PSScriptRoot
foreach ($sourceFile in @(
    'functions/private/Import-WinUtilComponentPolicy.ps1',
    'functions/private/Test-WinUtilComponentSafety.ps1',
    'functions/private/Resolve-WinUtilOfflineImagePolicy.ps1',
    'functions/private/Resolve-WinUtilComponentPolicyPlan.ps1',
    'functions/private/Test-WinUtilWindowsImageSupport.ps1',
    'functions/private/Get-WinUtilInstallImage.ps1',
    'functions/private/Get-WinUtilOfflineImageInventory.ps1',
    'functions/private/Get-WinUtilOfflineSystemSelect.ps1',
    'functions/private/Invoke-WinUtilOfflineServicingTransaction.ps1',
    'functions/private/Invoke-WinUtilISOScript.ps1',
    'functions/private/Invoke-WinUtilRobocopy.ps1',
    'functions/private/Publish-WinUtilBuildArtifact.ps1'
)) {
    . (Join-Path $script:WinUtilRepositoryRoot $sourceFile)
}

function Get-WinUtilWindowsBuildProvider {
    @{
        MountIso = {
            param($path)
            Mount-DiskImage -ImagePath $path -ErrorAction Stop | Out-Null
            $deadline = [DateTime]::UtcNow.AddSeconds(60)
            do {
                $volume = Get-DiskImage -ImagePath $path -ErrorAction Stop | Get-Volume -ErrorAction Stop
                if ($volume.DriveLetter) { return "$($volume.DriveLetter):" }
                if ([DateTime]::UtcNow -ge $deadline) { throw 'Timed out waiting for the source ISO drive letter.' }
                Start-Sleep -Milliseconds 500
            } while ($true)
        }
        DismountIso = { param($path) Dismount-DiskImage -ImagePath $path -ErrorAction Stop | Out-Null }
        GetImageMetadata = {
            param($path)

            $basicImages = @(Get-WindowsImage -ImagePath $path -ErrorAction Stop)
            if ($basicImages.Count -eq 0) { throw 'The install image did not report any image indexes.' }
            $seenIndexes = [System.Collections.Generic.HashSet[int]]::new()
            foreach ($basicImage in $basicImages) {
                $rawIndex = [string]$basicImage.ImageIndex
                $index = 0
                if ([string]::IsNullOrWhiteSpace($rawIndex) -or -not [int]::TryParse($rawIndex, [ref]$index) -or $index -lt 1) {
                    throw "The install image reported an invalid image index '$rawIndex'."
                }
                if (-not $seenIndexes.Add($index)) { throw "The install image reported duplicate image index $index." }

                $details = @(Get-WindowsImage -ImagePath $path -Index $index -ErrorAction Stop)
                if ($details.Count -ne 1 -or [int]$details[0].ImageIndex -ne $index) {
                    throw "Image index $index did not return one matching detailed metadata record."
                }
                $details[0]
            }
        }
        CopyMedia = { param($source, $destination) Invoke-WinUtilRobocopy -Source $source -Destination $destination | Out-Null }
        ExportEsd = {
            param($source, $index, $destination)
            Export-WinUtilEsdImageToWim -SourceImagePath $source -SourceImageIndex $index -DestinationImagePath $destination
        }
        StartSession = {
            param($image, $index, $name, $mount, $log)
            Start-WinUtilOfflineServicingSession -InstallImagePath $image -ImageIndex $index -ImageName $name -MountPath $mount -Log $log
        }
        StopSession = { param($session) Stop-WinUtilOfflineServicingSession -Session $session }
        GetSystemSelect = { param($mount) Get-WinUtilOfflineSystemSelect -MountedImagePath $mount }
        PrepareMedia = {
            param($arguments)
            Invoke-WinUtilISOScript @arguments
        }
        CreateIso = {
            param($executable, $arguments)
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                # Native tools commonly write progress to stderr. Capture it as evidence and
                # decide success from the process exit code instead of PowerShell's adapter.
                $ErrorActionPreference = 'Continue'
                $nativeOutput = @(& $executable @arguments 2>&1)
                $exitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
            $output = @(
                foreach ($record in $nativeOutput) {
                    $text = if ($record -is [System.Management.Automation.ErrorRecord]) {
                        [string]$record.Exception.Message
                    } else {
                        [string]$record
                    }
                    if (-not [string]::IsNullOrWhiteSpace($text)) { $text.TrimEnd() }
                }
            )
            [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
        }
        PublishArtifact = {
            param($output, $manifests, $log)
            Publish-WinUtilBuildArtifact -OutputPath $output -ManifestDirectory $manifests -BuildLogPath $log
        }
    }
}

function Get-WinUtilWindowsEditionId {
    param ([Parameter(Mandatory)][string]$ImageName)

    $normalizedName = ($ImageName -replace '^Windows\s+11\s+', '').Trim()
    $editionMap = @{
        'Home Single Language' = 'CoreSingleLanguage'; 'Home N' = 'CoreN'; 'Home' = 'Core'
        'Pro for Workstations N' = 'ProfessionalWorkstationN'; 'Pro for Workstations' = 'ProfessionalWorkstation'
        'Pro Education N' = 'ProfessionalEducationN'; 'Pro Education' = 'ProfessionalEducation'
        'Pro N' = 'ProfessionalN'; 'Pro' = 'Professional'; 'Education N' = 'EducationN'; 'Education' = 'Education'
        'Enterprise LTSC N' = 'EnterpriseSN'; 'Enterprise LTSC' = 'EnterpriseS'
        'Enterprise Evaluation' = 'EnterpriseEval'; 'Enterprise N' = 'EnterpriseN'; 'Enterprise' = 'Enterprise'
    }
    if (-not $editionMap.ContainsKey($normalizedName)) { throw "Unsupported Windows edition name '$ImageName'." }
    return $editionMap[$normalizedName]
}

function Invoke-WinUtilWindowsBuild {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$SourceIsoPath,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ImageIndex,
        [Parameter(Mandatory)][Alias('Profile')][ValidateSet('default-winutil', 'lean-daw', 'lean-daw-defender-retained')][string]$ComponentProfile,
        [Parameter(Mandatory)][string]$OutputIsoPath,
        [Parameter(Mandatory)][string]$WorkDirectory,
        [Parameter(Mandatory)][string]$OscdimgPath,
        [string]$DriverDirectory = '',
        [switch]$ExpertMode,
        [switch]$RemoveWorkDirectoryOnSuccess,
        [hashtable]$BuildProvider
    )

    foreach ($inputPath in @($SourceIsoPath, $OutputIsoPath, $WorkDirectory, $OscdimgPath)) {
        if ([string]::IsNullOrWhiteSpace($inputPath)) { throw 'Build paths cannot be empty.' }
    }
    if ([IO.Path]::GetExtension($SourceIsoPath) -ine '.iso' -or -not (Test-Path -LiteralPath $SourceIsoPath -PathType Leaf) -or
        (Get-Item -LiteralPath $SourceIsoPath).Length -eq 0) { throw "Official source ISO was not found or is empty: $SourceIsoPath" }
    if (-not (Test-Path -LiteralPath $OscdimgPath -PathType Leaf)) { throw "oscdimg.exe was not found: $OscdimgPath" }
    if ($DriverDirectory -and -not (Test-Path -LiteralPath $DriverDirectory -PathType Container)) { throw "Driver directory was not found: $DriverDirectory" }
    if (Test-Path -LiteralPath $WorkDirectory) { throw "Work directory already exists; refusing stale state: $WorkDirectory" }
    if (Test-Path -LiteralPath $OutputIsoPath) { throw "Output ISO already exists; refusing stale output: $OutputIsoPath" }
    $outputParent = Split-Path ([IO.Path]::GetFullPath($OutputIsoPath)) -Parent
    if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) { throw "Output directory was not found: $outputParent" }

    if (-not $BuildProvider) { $BuildProvider = Get-WinUtilWindowsBuildProvider }
    foreach ($boundary in 'MountIso', 'DismountIso', 'GetImageMetadata', 'CopyMedia', 'ExportEsd', 'StartSession', 'StopSession', 'GetSystemSelect', 'PrepareMedia', 'CreateIso', 'PublishArtifact') {
        if (-not $BuildProvider.ContainsKey($boundary) -or $BuildProvider[$boundary] -isnot [scriptblock]) {
            throw "BuildProvider boundary '$boundary' must be a scriptblock."
        }
    }

    $schemaPath = Join-Path $script:WinUtilRepositoryRoot 'policy/component-policy.schema.json'
    try { $policySchema = Get-Content -LiteralPath $schemaPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch {
        throw "Canonical component policy schema could not be read: $_"
    }
    if ([string]$policySchema.'$id' -ne 'urn:winutil:schema:component-policy:1') { throw 'Canonical component policy schema v1 is required.' }
    $catalog = Import-WinUtilComponentPolicy -Path (Join-Path $script:WinUtilRepositoryRoot 'policy/component-catalog.json')
    $selectedProfileDocument = Import-WinUtilComponentPolicy -Path (Join-Path $script:WinUtilRepositoryRoot "policy/profiles/$ComponentProfile.json") -Catalog $catalog
    $autoUnattendXml = Get-Content -LiteralPath (Join-Path $script:WinUtilRepositoryRoot 'tools/autounattend.xml') -Raw -ErrorAction Stop

    $workCreated = $false
    $mounted = $false
    $session = $null
    try {
        New-Item -Path $WorkDirectory -ItemType Directory -ErrorAction Stop | Out-Null
        $workCreated = $true
        $logPath = Join-Path $WorkDirectory 'WinUtil_Win11ISO.log'
        $log = { param($message) Add-Content -LiteralPath $logPath -Value "[$(Get-Date -Format 'HH:mm:ss')] $message" }.GetNewClosure()
        & $log "Starting noninteractive '$ComponentProfile' build from '$SourceIsoPath'."

        $mediaRoot = & $BuildProvider.MountIso $SourceIsoPath
        $mounted = $true
        $sourceImage = Get-WinUtilInstallImage -MediaRoot $mediaRoot
        $imageMetadata = @(& $BuildProvider.GetImageMetadata $sourceImage.Path)
        $support = Test-WinUtilWindowsImageSupport -ImageMetadata $imageMetadata
        if (-not $support.IsSupported) { throw "Unsupported source media: $($support.Reason)" }
        $selectedMetadata = @($support.Editions | Where-Object { [int]$_.ImageIndex -eq $ImageIndex })
        if ($selectedMetadata.Count -ne 1) { throw "Image index $ImageIndex is not one unambiguous supported edition." }
        $imageName = [string]$selectedMetadata[0].ImageName
        $editionId = Get-WinUtilWindowsEditionId -ImageName $imageName
        & $log "Validated source edition '$imageName' at index $ImageIndex."

        $isoContents = Join-Path $WorkDirectory 'iso_contents'
        New-Item -Path $isoContents -ItemType Directory -ErrorAction Stop | Out-Null
        & $log 'Copying Windows setup media into the isolated work directory.'
        & $BuildProvider.CopyMedia $mediaRoot $isoContents
        & $log 'Copied Windows setup media.'
        $copiedImage = Get-WinUtilInstallImage -MediaRoot $isoContents
        $localWim = [string]$copiedImage.Path
        $serviceIndex = $ImageIndex
        if ([string]$copiedImage.Format -eq 'ESD') {
            $export = & $BuildProvider.ExportEsd $localWim $ImageIndex (Join-Path $isoContents 'sources/install.wim')
            if (-not $export -or [int]$export.DestinationIndex -ne 1 -or -not (Test-Path -LiteralPath $export.DestinationPath -PathType Leaf)) {
                throw 'Selected ESD export did not produce a validated single-index WIM.'
            }
            Remove-Item -LiteralPath $localWim -Force -ErrorAction Stop
            $localWim = [string]$export.DestinationPath
            $serviceIndex = 1
            $imageName = [string]$export.Name
        }
        Set-ItemProperty -LiteralPath $localWim -Name IsReadOnly -Value $false -ErrorAction Stop
        $session = & $BuildProvider.StartSession $localWim $serviceIndex $imageName (Join-Path $WorkDirectory 'wim_mount') $log
        if (-not $session -or [string]$session.State -ne 'Mounted') { throw 'Offline analysis did not return one mounted servicing session.' }
        $offlineSystemSelect = & $BuildProvider.GetSystemSelect $session.MountPath
        $resolution = Resolve-WinUtilComponentPolicyPlan -Inventory $session.Inventory -Catalog $catalog -ComponentProfile $selectedProfileDocument -OfflineSystemSelect $offlineSystemSelect -ExpertMode:$ExpertMode
        if (-not $resolution.Safety.IsAllowed -or -not $resolution.ActionBundle.IsReady -or -not $resolution.ActionBundle.IsAllowed) {
            throw "Resolved '$ComponentProfile' plan is not ready or allowed."
        }
        $mutationCount = @($resolution.ResolvedPlan.Decisions | Where-Object Action -in @('Remove', 'Disable')).Count
        & $log "Resolved '$ComponentProfile' with $mutationCount offline mutations ready to apply."

        $manifestDirectory = Join-Path $WorkDirectory 'manifests'
        $prepareArguments = @{
            ISOContentsDir = $isoContents; AutoUnattendXml = $autoUnattendXml; InstallEditionId = $editionId
            InstallImagePath = $localWim; InstallImageIndex = $serviceIndex; ResolvedPlan = $resolution.ResolvedPlan
            ActionBundle = $resolution.ActionBundle; RegistryAction = @($resolution.ActionBundle.RegistryActions)
            ManifestDirectory = $manifestDirectory; DriverDirectory = $DriverDirectory
            OfflineServicingSession = $session; Log = $log
        }
        & $BuildProvider.PrepareMedia $prepareArguments
        if ([string]$session.State -ne 'Committed') { throw 'Offline servicing did not commit the analyzed image session.' }

        & $BuildProvider.DismountIso $SourceIsoPath
        $mounted = $false
        $bootData = "2#p0,e,b`"$isoContents\boot\etfsboot.com`"#pEF,e,b`"$isoContents\efi\microsoft\boot\efisys.bin`""
        $oscdimgArguments = @('-m', '-o', '-u2', '-udfver102', "-bootdata:$bootData", '-lCTOS_MODIFIED', $isoContents, $OutputIsoPath)
        & $log 'Creating the bootable ISO with oscdimg.'
        $isoResult = & $BuildProvider.CreateIso $OscdimgPath $oscdimgArguments
        if ($null -eq $isoResult -or $null -eq $isoResult.ExitCode) { throw 'oscdimg did not return an exit code.' }
        $isoOutput = @($isoResult.Output | ForEach-Object { [string]$_ })
        foreach ($line in $isoOutput) { & $log "oscdimg: $line" }
        if ([int]$isoResult.ExitCode -ne 0) {
            $outputEvidence = if ($isoOutput.Count -gt 0) { " Output: $($isoOutput -join [Environment]::NewLine)" } else { '' }
            throw "oscdimg failed with exit code $($isoResult.ExitCode).$outputEvidence"
        }
        if (-not (Test-Path -LiteralPath $OutputIsoPath -PathType Leaf) -or (Get-Item -LiteralPath $OutputIsoPath).Length -eq 0) {
            throw 'oscdimg reported success but the output ISO is missing or empty.'
        }
        & $log 'ISO packaging completed; hashing output and publishing build evidence.'
        $publication = & $BuildProvider.PublishArtifact $OutputIsoPath $manifestDirectory $logPath
        if (-not $publication -or -not (Test-Path -LiteralPath $publication.EvidenceDirectory -PathType Container)) {
            throw 'Build artifact publication did not return durable evidence.'
        }
        & $log 'Build artifact and evidence publication completed successfully.'
        $cleanupWarning = ''
        if ($RemoveWorkDirectoryOnSuccess -and (Test-Path -LiteralPath $WorkDirectory -PathType Container)) {
            try {
                Remove-Item -LiteralPath $WorkDirectory -Recurse -Force -ErrorAction Stop
            } catch {
                $cleanupWarning = "The ISO succeeded, but temporary work could not be removed: $_"
                Write-Warning $cleanupWarning
            }
        }
        return [pscustomobject][ordered]@{
            Profile = $ComponentProfile; ImageIndex = $ImageIndex; ImageName = $imageName; OutputIsoPath = [IO.Path]::GetFullPath($OutputIsoPath)
            WorkDirectory = [IO.Path]::GetFullPath($WorkDirectory); EvidenceDirectory = [string]$publication.EvidenceDirectory
            WorkDirectoryRetained = Test-Path -LiteralPath $WorkDirectory -PathType Container
            CleanupWarning = $cleanupWarning
        }
    } catch {
        if ($session -and [string]$session.State -eq 'Mounted') {
            try { & $BuildProvider.StopSession $session } catch { Write-Warning "Failed to discard mounted session: $_" }
        }
        if (Test-Path -LiteralPath $OutputIsoPath) { Remove-Item -LiteralPath $OutputIsoPath -Force -ErrorAction SilentlyContinue }
        if ($workCreated -and (Test-Path -LiteralPath $WorkDirectory)) { Remove-Item -LiteralPath $WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    } finally {
        if ($mounted) {
            try { & $BuildProvider.DismountIso $SourceIsoPath } catch { Write-Warning "Failed to dismount source ISO: $_" }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-WinUtilWindowsBuild @PSBoundParameters
}
