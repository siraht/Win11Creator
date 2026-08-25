[CmdletBinding()]
param (
    [string]$SourceIsoPath,
    [string]$OutputIsoPath,
    [string]$WorkDirectory,
    [string]$OscdimgPath,
    [string[]]$RepairId = @('evaluation-product-key'),
    [switch]$RemoveWorkDirectoryOnSuccess
)

$script:WinUtilRepairRepositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:WinUtilRepairRepositoryRoot 'functions/private/Invoke-WinUtilRobocopy.ps1')

function Get-WinUtilIsoRepairDefinition {
    @(
        [pscustomobject][ordered]@{
            Id = 'evaluation-product-key'
            Name = 'Repair Enterprise Evaluation product-key validation'
            Description = 'Remove the synthesized Retail edition override while preserving the selected WIM index and key-free answer file.'
            Test = {
                param ([string]$MediaRoot)

                $answerPath = Join-Path $MediaRoot 'autounattend.xml'
                if (-not (Test-Path -LiteralPath $answerPath -PathType Leaf)) {
                    throw 'The ISO has no root autounattend.xml; the Evaluation repair cannot prove its selected image.'
                }
                try { [xml]$answer = Get-Content -LiteralPath $answerPath -Raw -ErrorAction Stop } catch {
                    throw "The ISO answer file is invalid: $_"
                }
                $namespace = New-Object System.Xml.XmlNamespaceManager($answer.NameTable)
                $namespace.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
                if ($answer.SelectNodes('//u:ProductKey', $namespace).Count -ne 0) {
                    throw 'The ISO answer file contains a product key; this repair will not silently remove or replace it.'
                }
                $indexNodes = @($answer.SelectNodes('/u:unattend/u:settings[@pass="windowsPE"]/u:component[@name="Microsoft-Windows-Setup"]/u:ImageInstall/u:OSImage/u:InstallFrom/u:MetaData[u:Key="/IMAGE/INDEX"]/u:Value', $namespace))
                $imageIndex = 0
                if ($indexNodes.Count -ne 1 -or -not [int]::TryParse([string]$indexNodes[0].InnerText, [ref]$imageIndex) -or $imageIndex -lt 1) {
                    throw 'The ISO answer file does not pin one valid /IMAGE/INDEX; refusing an ambiguous edition repair.'
                }

                $eiCfgPath = Join-Path $MediaRoot 'sources/ei.cfg'
                $pidPath = Join-Path $MediaRoot 'sources/PID.txt'
                $hasRetailEvaluationOverride = $false
                if (Test-Path -LiteralPath $eiCfgPath -PathType Leaf) {
                    $editionConfig = Get-Content -LiteralPath $eiCfgPath -Raw -ErrorAction Stop
                    $hasRetailEvaluationOverride = $editionConfig -match '(?im)^\s*Enterprise(?:N)?Eval\s*$' -and
                        $editionConfig -match '(?ims)^\s*\[Channel\]\s*\r?\n\s*Retail\s*$'
                }
                [pscustomobject][ordered]@{
                    IsApplicable = $hasRetailEvaluationOverride -or (Test-Path -LiteralPath $pidPath -PathType Leaf)
                    ImageIndex = $imageIndex
                    HasRetailEvaluationOverride = $hasRetailEvaluationOverride
                    HasPidFile = Test-Path -LiteralPath $pidPath -PathType Leaf
                }
            }
            Apply = {
                param ([string]$MediaRoot, $Inspection, [scriptblock]$Log)

                if ($Inspection.HasRetailEvaluationOverride) {
                    Remove-Item -LiteralPath (Join-Path $MediaRoot 'sources/ei.cfg') -Force -ErrorAction Stop
                    & $Log 'Removed the synthesized Retail sources\ei.cfg from Enterprise Evaluation media.'
                }
                if ($Inspection.HasPidFile) {
                    Remove-Item -LiteralPath (Join-Path $MediaRoot 'sources/PID.txt') -Force -ErrorAction Stop
                    & $Log 'Removed sources\PID.txt so Setup cannot force a stale product key.'
                }
            }
        }
    )
}

function Get-WinUtilIsoRepairProvider {
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
        CopyMedia = { param($source, $destination) Invoke-WinUtilRobocopy -Source $source -Destination $destination | Out-Null }
        CreateIso = {
            param($executable, $arguments)
            $previousErrorActionPreference = $ErrorActionPreference
            try {
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
    }
}

function Invoke-WinUtilIsoRepair {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$SourceIsoPath,
        [Parameter(Mandatory)][string]$OutputIsoPath,
        [Parameter(Mandatory)][string]$WorkDirectory,
        [Parameter(Mandatory)][string]$OscdimgPath,
        [Parameter(Mandatory)][string[]]$RepairId,
        [switch]$RemoveWorkDirectoryOnSuccess,
        [hashtable]$RepairProvider
    )

    if ([IO.Path]::GetExtension($SourceIsoPath) -ine '.iso' -or -not (Test-Path -LiteralPath $SourceIsoPath -PathType Leaf) -or
        (Get-Item -LiteralPath $SourceIsoPath).Length -eq 0) { throw "Source ISO was not found or is empty: $SourceIsoPath" }
    if (-not (Test-Path -LiteralPath $OscdimgPath -PathType Leaf)) { throw "oscdimg.exe was not found: $OscdimgPath" }
    if (Test-Path -LiteralPath $WorkDirectory) { throw "Work directory already exists; refusing stale state: $WorkDirectory" }
    if (Test-Path -LiteralPath $OutputIsoPath) { throw "Output ISO already exists; refusing stale output: $OutputIsoPath" }
    $outputParent = Split-Path ([IO.Path]::GetFullPath($OutputIsoPath)) -Parent
    if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) { throw "Output directory was not found: $outputParent" }
    if ($RepairId.Count -eq 0) { throw 'Select at least one ISO repair.' }

    $definitions = @(Get-WinUtilIsoRepairDefinition)
    $definitionIds = @($definitions.Id)
    if (@($definitionIds | Select-Object -Unique).Count -ne $definitionIds.Count) { throw 'ISO repair definitions contain duplicate IDs.' }
    $selectedDefinitions = @()
    foreach ($selectedId in $RepairId) {
        $definitionMatches = @($definitions | Where-Object Id -eq $selectedId)
        if ($definitionMatches.Count -ne 1) { throw "Unknown ISO repair '$selectedId'." }
        if ($selectedDefinitions.Id -contains $selectedId) { throw "ISO repair '$selectedId' was selected more than once." }
        $selectedDefinitions += $definitionMatches[0]
    }

    if (-not $RepairProvider) { $RepairProvider = Get-WinUtilIsoRepairProvider }
    foreach ($boundary in 'MountIso', 'DismountIso', 'CopyMedia', 'CreateIso') {
        if (-not $RepairProvider.ContainsKey($boundary) -or $RepairProvider[$boundary] -isnot [scriptblock]) {
            throw "RepairProvider boundary '$boundary' must be a scriptblock."
        }
    }

    $mounted = $false
    $workCreated = $false
    try {
        New-Item -Path $WorkDirectory -ItemType Directory -ErrorAction Stop | Out-Null
        $workCreated = $true
        $logPath = Join-Path $WorkDirectory 'WinUtil_ISORepair.log'
        $log = { param($message) Add-Content -LiteralPath $logPath -Value "[$(Get-Date -Format 'HH:mm:ss')] $message" }.GetNewClosure()
        & $log "Starting ISO repair from '$SourceIsoPath'."

        $mediaRoot = & $RepairProvider.MountIso $SourceIsoPath
        $mounted = $true
        $copiedMedia = Join-Path $WorkDirectory 'iso_contents'
        New-Item -Path $copiedMedia -ItemType Directory -ErrorAction Stop | Out-Null
        & $log 'Copying ISO contents into the isolated repair workspace.'
        & $RepairProvider.CopyMedia $mediaRoot $copiedMedia
        & $RepairProvider.DismountIso $SourceIsoPath
        $mounted = $false
        & $log 'Copied source media and released its read-only mount.'

        $applied = @()
        foreach ($definition in $selectedDefinitions) {
            & $log "Inspecting repair '$($definition.Name)'."
            $inspection = & $definition.Test $copiedMedia
            if (-not $inspection -or $inspection.IsApplicable -ne $true) {
                throw "Repair '$($definition.Name)' is not applicable to this ISO; no output was created."
            }
            & $definition.Apply $copiedMedia $inspection $log
            $postInspection = & $definition.Test $copiedMedia
            if ($postInspection.IsApplicable -eq $true) { throw "Repair '$($definition.Name)' did not reach its required state." }
            $applied += [string]$definition.Id
            & $log "Applied and verified repair '$($definition.Name)'."
        }

        $bootData = "2#p0,e,b`"$copiedMedia\boot\etfsboot.com`"#pEF,e,b`"$copiedMedia\efi\microsoft\boot\efisys.bin`""
        $oscdimgArguments = @('-m', '-o', '-u2', '-udfver102', "-bootdata:$bootData", '-lCTOS_REPAIRED', $copiedMedia, $OutputIsoPath)
        & $log 'Creating the repaired dual BIOS/UEFI bootable ISO.'
        $isoResult = & $RepairProvider.CreateIso $OscdimgPath $oscdimgArguments
        if ($null -eq $isoResult -or $null -eq $isoResult.ExitCode) { throw 'oscdimg did not return an exit code.' }
        $isoOutput = @($isoResult.Output | ForEach-Object { [string]$_ })
        foreach ($line in $isoOutput) { & $log "oscdimg: $line" }
        if ([int]$isoResult.ExitCode -ne 0) { throw "oscdimg failed with exit code $($isoResult.ExitCode). $($isoOutput -join ' ')".Trim() }
        if (-not (Test-Path -LiteralPath $OutputIsoPath -PathType Leaf) -or (Get-Item -LiteralPath $OutputIsoPath).Length -eq 0) {
            throw 'oscdimg reported success but the repaired ISO is missing or empty.'
        }
        & $log 'Repaired ISO creation completed successfully.'

        $cleanupWarning = ''
        if ($RemoveWorkDirectoryOnSuccess -and (Test-Path -LiteralPath $WorkDirectory -PathType Container)) {
            try {
                Remove-Item -LiteralPath $WorkDirectory -Recurse -Force -ErrorAction Stop
            } catch {
                $cleanupWarning = "The repaired ISO succeeded, but temporary work could not be removed: $_"
                Write-Warning $cleanupWarning
            }
        }
        [pscustomobject][ordered]@{
            SourceIsoPath = [IO.Path]::GetFullPath($SourceIsoPath)
            OutputIsoPath = [IO.Path]::GetFullPath($OutputIsoPath)
            AppliedRepairIds = @($applied)
            WorkDirectoryRetained = Test-Path -LiteralPath $WorkDirectory -PathType Container
            CleanupWarning = $cleanupWarning
        }
    } catch {
        if (Test-Path -LiteralPath $OutputIsoPath) { Remove-Item -LiteralPath $OutputIsoPath -Force -ErrorAction SilentlyContinue }
        if ($workCreated -and (Test-Path -LiteralPath $WorkDirectory)) { Remove-Item -LiteralPath $WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    } finally {
        if ($mounted) {
            try { & $RepairProvider.DismountIso $SourceIsoPath } catch { Write-Warning "Failed to dismount source ISO: $_" }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-WinUtilIsoRepair @PSBoundParameters
}
