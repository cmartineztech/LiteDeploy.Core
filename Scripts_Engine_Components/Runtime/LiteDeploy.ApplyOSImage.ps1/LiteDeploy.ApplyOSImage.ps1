<#
.SYNOPSIS
    Applies a Windows operating system image using the Windows Setup (setup.exe) engine with /NoReboot, /DiagnosticPrompt enable, and automated unattended answer file generation.

.DESCRIPTION
    LiteDeploy Runtime component that orchestrates Windows Setup during WinPE deployment.
    Before applying the OS image, it automatically generates a customized answer file (default: X:\unattended.xml)
    by performing string key substitution on an XML template (e.g. Autopilot.xml) using properties from BootConfig.json,
    SelectWorkflow, and DiskFormat. It then executes setup.exe with /NoReboot, /DiagnosticPrompt enable, /ImageIndex <index>,
    and /Unattend:<path>, validates the exit code, verifies offline installation artifacts on the target drive, and returns a structured status object.

.PARAMETER SetupPath
    Full or relative path to setup.exe on the deployment share or local media.
    If ImagePath is passed instead, setup.exe will be resolved from the OS media folder.

.PARAMETER ImagePath
    Alternative path to install.wim/esd or OS root directory. Used to resolve setup.exe if SetupPath is omitted.

.PARAMETER UnattendPath
    Explicit path to an existing unattended answer file. If omitted, an answer file is automatically generated.

.PARAMETER TemplateUnattendPath
    Path to the XML template used for substitution (e.g. "Z:\Content\Unattend\Autopilot.xml").
    If omitted, automatically resolves from the connected deployment share (Z:\Content\Unattend\Autopilot.xml), media root, or host.

.PARAMETER GeneratedUnattendPath
    Destination file path for the generated answer file. Default: "X:\unattended.xml".

.PARAMETER ImageIndex
    WIM/ESD image index to install (e.g. 1, 2, 6). Typically selected during SelectWorkflow.
    If 0 or omitted, the component resolves the index from WorkflowSelection ($WorkflowSelection.WorkflowTag.Index), defaulting to 1.

.PARAMETER Destination
    Target OS partition mount or drive letter (e.g. "W:\" or "W:"). Default: "W:\".

.PARAMETER WorkflowSelection
    Optional PSCustomObject containing technician selections from SelectWorkflow (ComputerName, TargetDiskIndex, WorkflowTag, etc.).

.PARAMETER DiskResult
    Optional PSCustomObject containing partition results from DiskFormat (DiskNumber, OSPartitionNumber, etc.).

.PARAMETER BootConfig
    Optional configuration object or hashtable loaded from BootConfig.json containing ComputerSetup properties.

.PARAMETER AdditionalArguments
    Optional array of additional command-line arguments to pass directly to setup.exe.

.PARAMETER BootObject
    Optional LiteDeploy runtime context object passed from BootInitializer or DeploymentEngine.

.PARAMETER Metadata
    Switch to output component metadata as a PSCustomObject without executing setup.exe.

.EXAMPLE
    .\LiteDeploy.ApplyOSImage.ps1 `
        -SetupPath "Z:\Content\OperatingSystems\win11_25H2\setup.exe" `
        -ImageIndex 6 `
        -TemplateUnattendPath "Z:\Content\Unattend\Autopilot.xml" `
        -WorkflowSelection $workflowResult `
        -DiskResult $diskResult `
        -Destination "W:\"

.EXAMPLE
    .\LiteDeploy.ApplyOSImage.ps1 -Metadata

.NOTES
    LiteDeploy Component Standard v1.0
    PowerShell Version: 5.1+
    Strict Mode: Version 2.0
    Target Environment: WinPE
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Metadata,

    [Parameter(Mandatory = $false)]
    [string]$SetupPath = "",

    [Parameter(Mandatory = $false)]
    [string]$ImagePath = "",

    [Parameter(Mandatory = $false)]
    [int]$ImageIndex = 0,

    [Parameter(Mandatory = $false)]
    [string]$UnattendPath = "",

    [Parameter(Mandatory = $false)]
    [string]$TemplateUnattendPath = "",

    [Parameter(Mandatory = $false)]
    [string]$GeneratedUnattendPath = "X:\unattended.xml",

    [Parameter(Mandatory = $false)]
    [string]$Destination = "W:\",

    [Parameter(Mandatory = $false)]
    [psobject]$WorkflowSelection = $null,

    [Parameter(Mandatory = $false)]
    [psobject]$DiskResult = $null,

    [Parameter(Mandatory = $false)]
    [psobject]$BootConfig = $null,

    [Parameter(Mandatory = $false)]
    [string[]]$AdditionalArguments = @(),

    [Parameter(Mandatory = $false)]
    [psobject]$BootObject = $null
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ==============================================================================
# REGION 1: COMPONENT METADATA & VERSION CONTROL
# ==============================================================================

function Get-LiteDeployComponentMetadata {
    <#
    .SYNOPSIS
        Returns standardized component metadata for inventory discovery and version management.
    #>
    return [PSCustomObject]@{
        ComponentId          = "ApplyOSImage"
        Name                 = "LiteDeploy OS Image Applier (Setup.exe)"
        Version              = "1.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "WinPE"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("LogWriter")
        Description          = "Applies Windows operating system using the Windows Setup (Setup.exe) engine with /NoReboot and automated unattended answer file generation."
    }
}

if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

# ==============================================================================
# REGION 2: LOGGING & DIAGNOSTIC INTEGRATION
# ==============================================================================

function Write-ComponentLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("INFO", "SUCCESS", "INIT", "CHECK", "WARNING", "RETRY", "ERROR")]
        [string]$Level = "INFO",
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::White
    )
    $meta = Get-LiteDeployComponentMetadata

    if (Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue) {
        Write-LiteDeployLog -Message $Message -Level $Level -Component $meta.ComponentId -ForegroundColor $ForegroundColor
    }
    else {
        Write-Host " [$($Level.PadRight(7))] $Message" -ForegroundColor $ForegroundColor
    }
}

# ==============================================================================
# REGION 3: PATH RESOLUTION & DISCOVERY
# ==============================================================================

function Resolve-SetupExecutable {
    param(
        [string]$ExplicitSetupPath,
        [string]$AlternativeImagePath,
        [psobject]$BootCtx
    )

    $candidates = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($ExplicitSetupPath)) {
        $candidates.Add($ExplicitSetupPath)
    }

    if (-not [string]::IsNullOrWhiteSpace($AlternativeImagePath)) {
        if ($AlternativeImagePath -match '(?i)setup\.exe$') {
            $candidates.Add($AlternativeImagePath)
        }
        elseif ($AlternativeImagePath -match '(?i)sources\\install\.(wim|esd|swm)$') {
            $osFolder = Split-Path -Parent (Split-Path -Parent $AlternativeImagePath)
            $candidates.Add((Join-Path $osFolder "setup.exe"))
        }
        else {
            $candidates.Add((Join-Path $AlternativeImagePath "setup.exe"))
        }
    }

    # Determine connected deployment share drive letter (Z: by default in WinPE)
    $shareDrive = if ($BootCtx -and $BootCtx.PSObject.Properties['DriveLetter'] -and $BootCtx.DriveLetter) {
        $BootCtx.DriveLetter.TrimEnd('\')
    } elseif (Test-Path -LiteralPath "Z:\") {
        "Z:"
    } else {
        $null
    }

    foreach ($cand in $candidates) {
        # Check candidate relative to share drive first
        if ($shareDrive) {
            $comb = "$($shareDrive.TrimEnd('\'))\$($cand.TrimStart('\'))"
            if (Test-Path -LiteralPath $comb) {
                return (Resolve-Path -LiteralPath $comb).Path
            }
        }

        if (Test-Path -LiteralPath $cand) {
            return (Resolve-Path -LiteralPath $cand).Path
        }

        if ($BootCtx -and $BootCtx.PSObject.Properties['NetworkPath'] -and $BootCtx.NetworkPath) {
            $comb = "$($BootCtx.NetworkPath.TrimEnd('\'))\$($cand.TrimStart('\'))"
            if (Test-Path -LiteralPath $comb) {
                return (Resolve-Path -LiteralPath $comb).Path
            }
        }

        $cwdCandidate = Join-Path (Get-Location).Path $cand
        if (Test-Path -LiteralPath $cwdCandidate) {
            return (Resolve-Path -LiteralPath $cwdCandidate).Path
        }
    }

    return $null
}

function Resolve-UnattendTemplate {
    param(
        [string]$ExplicitTemplatePath,
        [psobject]$BootCtx
    )

    # 1. Direct explicit path check if supplied
    if (-not [string]::IsNullOrWhiteSpace($ExplicitTemplatePath)) {
        if (Test-Path -LiteralPath $ExplicitTemplatePath) {
            return (Resolve-Path -LiteralPath $ExplicitTemplatePath).Path
        }
    }

    # Determine connected deployment share drive letter (Z: by default in WinPE)
    $shareDrive = if ($BootCtx -and $BootCtx.PSObject.Properties['DriveLetter'] -and $BootCtx.DriveLetter) {
        $BootCtx.DriveLetter.TrimEnd('\')
    } elseif (Test-Path -LiteralPath "Z:\") {
        "Z:"
    } else {
        $null
    }

    # 2. If explicit relative path was supplied, check against share drive or working directory
    if (-not [string]::IsNullOrWhiteSpace($ExplicitTemplatePath)) {
        if ($shareDrive) {
            $cand = "$($shareDrive.TrimEnd('\'))\$($ExplicitTemplatePath.TrimStart('\'))"
            if (Test-Path -LiteralPath $cand) {
                return (Resolve-Path -LiteralPath $cand).Path
            }
        }
        $cwdCand = Join-Path (Get-Location).Path $ExplicitTemplatePath
        if (Test-Path -LiteralPath $cwdCand) {
            return (Resolve-Path -LiteralPath $cwdCand).Path
        }
    }

    # 3. Discovery candidates ordered by priority:
    #    Priority 1: Connected Deployment Share (Z:\Content\Unattend\Autopilot.xml)
    #    Priority 2: UNC Network Path
    #    Priority 3: Repository / Layout relative paths
    #    Priority 4: Local Server / Host fallback (C:\DeploymentShare\...)
    $candidates = [System.Collections.Generic.List[string]]::new()

    if ($shareDrive) {
        $candidates.Add("$($shareDrive.TrimEnd('\'))\Content\Unattend\Autopilot.xml")
        $candidates.Add("$($shareDrive.TrimEnd('\'))\Autopilot.xml")
    }
    $candidates.Add("Z:\Content\Unattend\Autopilot.xml")
    $candidates.Add("Z:\Autopilot.xml")

    if ($BootCtx -and $BootCtx.PSObject.Properties['NetworkPath'] -and $BootCtx.NetworkPath) {
        $candidates.Add("$($BootCtx.NetworkPath.TrimEnd('\'))\Content\Unattend\Autopilot.xml")
    }

    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    if ($scriptDir) {
        $candidates.Add((Join-Path $scriptDir "..\..\..\DeploymentShare_Layout\Content\Unattend\Autopilot.xml"))
        $candidates.Add((Join-Path $scriptDir "..\..\..\Content\Unattend\Autopilot.xml"))
    }

    # Host fallback
    $candidates.Add("C:\DeploymentShare\Content\Unattend\Autopilot.xml")
    $candidates.Add("Content\Unattend\Autopilot.xml")

    foreach ($cand in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($cand) -and (Test-Path -LiteralPath $cand)) {
            return (Resolve-Path -LiteralPath $cand).Path
        }
    }

    return $null
}

# ==============================================================================
# REGION 4: AUTOMATED UNATTENDED GENERATION & STRING KEY SUBSTITUTION
# ==============================================================================

function New-LiteDeployUnattendXml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplateFile,

        [Parameter(Mandatory = $true)]
        [string]$TargetOutputFile,

        [psobject]$ConfigObj,
        [psobject]$WorkflowData,
        [psobject]$DiskData,
        [psobject]$BootCtx
    )

    Write-ComponentLog "Generating automated unattended answer file..." -Level "INIT" -ForegroundColor Cyan
    Write-ComponentLog "Unattend Template: $TemplateFile" -Level "INFO"

    if (-not (Test-Path -LiteralPath $TemplateFile)) {
        throw "Unattend template file '$TemplateFile' does not exist."
    }

    # 1. Resolve DiskID
    $diskId = 0
    if ($DiskData -and $DiskData.PSObject.Properties['DiskNumber'] -and ($null -ne $DiskData.DiskNumber)) {
        $diskId = [int]$DiskData.DiskNumber
    }
    elseif ($WorkflowData -and $WorkflowData.PSObject.Properties['TargetDiskIndex'] -and ($null -ne $WorkflowData.TargetDiskIndex)) {
        $rawDisk = "$($WorkflowData.TargetDiskIndex)"
        if ($rawDisk -match '(\d+)') {
            $diskId = [int]$matches[1]
        }
    }

    # 2. Resolve PartitionID (standard Windows partition on GPT is 3: ESP=1, MSR=2, OS=3)
    $partitionId = 3
    if ($DiskData -and $DiskData.PSObject.Properties['OSPartitionNumber'] -and ($null -ne $DiskData.OSPartitionNumber)) {
        $partitionId = [int]$DiskData.OSPartitionNumber
    }

    # 3. Resolve ComputerName
    $compName = ""
    if ($WorkflowData -and $WorkflowData.PSObject.Properties['ComputerName'] -and $WorkflowData.ComputerName) {
        $compName = $WorkflowData.ComputerName.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($compName)) {
        $prefix = "DESK-"
        if ($ConfigObj -and $ConfigObj.PSObject.Properties['ComputerSetup'] -and $ConfigObj.ComputerSetup.PSObject.Properties['ComputerNamePrefix'] -and $ConfigObj.ComputerSetup.ComputerNamePrefix) {
            $prefix = $ConfigObj.ComputerSetup.ComputerNamePrefix
        }
        $rnd = Get-Random -Minimum 1000 -Maximum 9999
        $compName = "$prefix$rnd"
    }

    # 4. Resolve ComputerDescription
    $compDesc = ""
    if ($WorkflowData -and $WorkflowData.PSObject.Properties['ComputerDescription'] -and $WorkflowData.ComputerDescription) {
        $compDesc = $WorkflowData.ComputerDescription.Trim()
    }

    # 5. Resolve Regional, Locale, TimeZone, and Registration properties from BootConfig
    $effectiveConfig = $null
    if ($ConfigObj) {
        $effectiveConfig = $ConfigObj
    }
    elseif ($BootCtx -and $BootCtx.PSObject.Properties['Config'] -and $BootCtx.Config) {
        $effectiveConfig = $BootCtx.Config
    }

    $lang      = "en-US"
    $keyboard  = "0409:00000409"
    $timeZone  = "Eastern Standard Time"
    $regOrg    = ""
    $regOwner  = ""

    if ($effectiveConfig -and $effectiveConfig.PSObject.Properties['ComputerSetup'] -and $effectiveConfig.ComputerSetup) {
        $cs = $effectiveConfig.ComputerSetup
        if ($cs.PSObject.Properties['Language'] -and $cs.Language) { $lang = $cs.Language }
        if ($cs.PSObject.Properties['KeyboardLocale'] -and $cs.KeyboardLocale) { $keyboard = $cs.KeyboardLocale }
        if ($cs.PSObject.Properties['TimeZone'] -and $cs.TimeZone) { $timeZone = $cs.TimeZone }
        if ($cs.PSObject.Properties['RegisteredOrganization'] -and ($null -ne $cs.RegisteredOrganization)) { $regOrg = $cs.RegisteredOrganization }
        if ($cs.PSObject.Properties['RegisteredOwner'] -and ($null -ne $cs.RegisteredOwner)) { $regOwner = $cs.RegisteredOwner }
    }

    Write-ComponentLog "Substituted Properties:" -Level "INFO"
    Write-ComponentLog " - ComputerName           : $compName" -Level "INFO"
    Write-ComponentLog " - Target Disk / Partition: Disk $diskId, Partition $partitionId" -Level "INFO"
    Write-ComponentLog " - Language / Locales     : $lang (Keyboard: $keyboard)" -Level "INFO"
    Write-ComponentLog " - TimeZone               : $timeZone" -Level "INFO"
    Write-ComponentLog " - RegisteredOrganization : $(if ($regOrg) { $regOrg } else { '(blank)' })" -Level "INFO"
    Write-ComponentLog " - RegisteredOwner        : $(if ($regOwner) { $regOwner } else { '(blank)' })" -Level "INFO"

    # Read template content
    $templateContent = Get-Content -LiteralPath $TemplateFile -Raw -Encoding UTF8

    # Ensure missing ProductKey closing tag is repaired if template is older
    if ($templateContent -match '<ProductKey>\s*<!--[^>]*-->\s*<WillShowUI>Never</WillShowUI>\s*</UserData>') {
        $templateContent = $templateContent -replace '(<WillShowUI>Never</WillShowUI>\s*)', "`$1</ProductKey>`r`n        "
    }

    # Clean up residual <!--ImageIndex--> comment if present in template
    $generatedContent = $templateContent -replace '\s*<!--ImageIndex-->', ''

    # Perform string key substitutions
    $ownerXml = if (-not [string]::IsNullOrWhiteSpace($regOwner)) { "<RegisteredOwner>$regOwner</RegisteredOwner>" } else { "" }
    $orgXml   = if (-not [string]::IsNullOrWhiteSpace($regOrg))   { "<RegisteredOrganization>$regOrg</RegisteredOrganization>" } else { "" }

    $generatedContent = $templateContent `
        -replace '<!--DiskID-->', "<DiskID>$diskId</DiskID>" `
        -replace '<!--PartitionID-->', "<PartitionID>$partitionId</PartitionID>" `
        -replace '<!--SetupUILanguage-->', "<UILanguage>$lang</UILanguage>" `
        -replace '<!--UILanguage-->', "<UILanguage>$lang</UILanguage>" `
        -replace '<!--InputLocale-->', "<InputLocale>$keyboard</InputLocale>" `
        -replace '<!--SystemLocale-->', "<SystemLocale>$lang</SystemLocale>" `
        -replace '<!--UserLocale-->', "<UserLocale>$lang</UserLocale>" `
        -replace '<!--ComputerName-->', "<ComputerName>$compName</ComputerName>" `
        -replace '<!--TimeZone-->', "<TimeZone>$timeZone</TimeZone>" `
        -replace '<!--Timezone-->', "<TimeZone>$timeZone</TimeZone>" `
        -replace '<!--RegisteredOwner-->', $ownerXml `
        -replace '<!--RegisteredOrganization-->', $orgXml

    # Handle ComputerDescription substitution
    if (-not [string]::IsNullOrWhiteSpace($compDesc)) {
        $deploymentComponent = @"
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Set Computer Description</Description>
          <Path>cmd.exe /c reg add "HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" /v srvcomment /t REG_SZ /d "$compDesc" /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
"@
        $generatedContent = $generatedContent -replace '<!--ComputerDescription-->', $deploymentComponent
    } else {
        $generatedContent = $generatedContent -replace '<!--ComputerDescription-->', ''
    }

    # Validate generated XML syntax
    try {
        [xml]$testXml = $generatedContent
        Write-ComponentLog "Unattended XML syntax validated successfully." -Level "SUCCESS" -ForegroundColor Green
    }
    catch {
        Write-ComponentLog "Unattended XML validation failed: $_" -Level "ERROR" -ForegroundColor Red
        throw "Failed to validate generated unattended XML: $_"
    }

    # Determine effective target path (fallback to TEMP if X: drive does not exist in testing)
    $effectiveOutputPath = $TargetOutputFile
    $targetDrive = Split-Path -Path $TargetOutputFile -Qualifier
    if ($targetDrive -and (-not (Test-Path -LiteralPath "$targetDrive\"))) {
        $fallbackDir = if ($env:TEMP) { $env:TEMP } else { "." }
        $effectiveOutputPath = Join-Path $fallbackDir (Split-Path -Leaf $TargetOutputFile)
        Write-ComponentLog "Target drive '$targetDrive' not available; using '$effectiveOutputPath'." -Level "WARNING" -ForegroundColor Yellow
    }

    $targetFolder = Split-Path -Path $effectiveOutputPath -Parent
    if ($targetFolder -and (-not (Test-Path -LiteralPath $targetFolder))) {
        $null = New-Item -Path $targetFolder -ItemType Directory -Force -ErrorAction SilentlyContinue
    }

    Set-Content -LiteralPath $effectiveOutputPath -Value $generatedContent -Encoding UTF8 -Force
    Write-ComponentLog "Unattended answer file written to: $effectiveOutputPath" -Level "SUCCESS" -ForegroundColor Green

    return $effectiveOutputPath
}

# ==============================================================================
# REGION 5: SETUP.EXE EXECUTION & VALIDATION
# ==============================================================================

function Invoke-SetupEngine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedSetupPath,
        [Parameter(Mandatory = $true)]
        [string]$EffectiveUnattendPath,
        [Parameter(Mandatory = $true)]
        [string]$NormalizedDestination,
        [int]$SelectedImageIndex = 0,
        [string[]]$ExtraArgs = @()
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-ComponentLog "================================================================" -Level "INIT" -ForegroundColor Cyan
    Write-ComponentLog "Starting Windows Setup Engine (Setup.exe)..." -Level "INIT" -ForegroundColor Cyan
    Write-ComponentLog "Setup Binary : $ResolvedSetupPath" -Level "INFO"

    try {
        $setupVersion = (Get-Item -LiteralPath $ResolvedSetupPath).VersionInfo.ProductVersion
        Write-ComponentLog "Setup Version: $setupVersion" -Level "INFO"
    } catch {}

    $displayIndex = if ($SelectedImageIndex -gt 0) { $SelectedImageIndex } else { 1 }
    Write-ComponentLog "Image Index  : $displayIndex" -Level "INFO"
    Write-ComponentLog "Target Drive : $NormalizedDestination" -Level "INFO"
    Write-ComponentLog "Unattend XML : $EffectiveUnattendPath" -Level "INFO"

    # Build Setup.exe arguments
    $argsList = [System.Collections.Generic.List[string]]::new()
    $argsList.Add("/NoReboot")
    $argsList.Add("/DiagnosticPrompt enable")
    $argsList.Add("/ImageIndex $displayIndex")
    $argsList.Add("/Unattend:`"$EffectiveUnattendPath`"")

    if ($ExtraArgs -and $ExtraArgs.Count -gt 0) {
        foreach ($arg in $ExtraArgs) {
            if (-not [string]::IsNullOrWhiteSpace($arg)) {
                $argsList.Add($arg)
            }
        }
    }

    $argumentsString = $argsList -join " "
    Write-ComponentLog "Command Line : $ResolvedSetupPath $argumentsString" -Level "INFO"
    Write-ComponentLog "Launching Windows Setup process. Please wait..." -Level "INIT" -ForegroundColor Cyan

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName         = $ResolvedSetupPath
    $processInfo.WorkingDirectory = Split-Path -Parent $ResolvedSetupPath
    $processInfo.Arguments        = $argumentsString
    $processInfo.UseShellExecute  = $false

    $setupProcess = [System.Diagnostics.Process]::Start($processInfo)
    $setupProcess.WaitForExit()
    $exitCode = $setupProcess.ExitCode

    $stopwatch.Stop()
    $durationSec = [int]$stopwatch.Elapsed.TotalSeconds

    $isSuccessCode = ($exitCode -eq 0 -or $exitCode -eq 3010)

    if (-not $isSuccessCode) {
        $hexCode = "0x{0:X8}" -f $exitCode
        Write-ComponentLog "Windows Setup failed with exit code $exitCode ($hexCode) after $durationSec seconds." -Level "ERROR" -ForegroundColor Red
        throw "Windows Setup failed with exit code $exitCode ($hexCode)."
    }

    Write-ComponentLog "Windows Setup completed with exit code $exitCode in $durationSec seconds." -Level "SUCCESS" -ForegroundColor Green

    # Validate offline Windows installation artifacts on target drive
    $windowsDir = Join-Path $NormalizedDestination "Windows"
    $btDir      = Join-Path $NormalizedDestination "`$Windows.~BT"
    $hasArtifacts = (Test-Path -LiteralPath $windowsDir) -or (Test-Path -LiteralPath $btDir)

    if (-not $hasArtifacts) {
        Write-ComponentLog "Warning: Neither '$windowsDir' nor '$btDir' was found on target destination '$NormalizedDestination'." -Level "WARNING" -ForegroundColor Yellow
    }
    else {
        Write-ComponentLog "Verified offline Windows installation artifacts on target destination '$NormalizedDestination'." -Level "SUCCESS" -ForegroundColor Green
    }

    Write-ComponentLog "ApplyOSImage (Setup.exe) finished successfully." -Level "SUCCESS" -ForegroundColor Green
    Write-ComponentLog "================================================================" -Level "SUCCESS" -ForegroundColor Green

    return [PSCustomObject]@{
        Success         = $true
        Engine          = "Setup.exe"
        SetupPath       = $ResolvedSetupPath
        ImageIndex      = $displayIndex
        UnattendPath    = $EffectiveUnattendPath
        Destination     = $NormalizedDestination
        ExitCode        = $exitCode
        DurationSeconds = $durationSec
        CompletedTime   = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    }
}

# ==============================================================================
# REGION 6: EXECUTION ENTRY POINT
# ==============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    # Normalize Destination drive letter
    $normalizedDest = $Destination
    if ($normalizedDest -match '^[a-zA-Z]:$') {
        $normalizedDest = "$normalizedDest\"
    }

    if (-not (Test-Path -LiteralPath $normalizedDest)) {
        throw "Target destination directory '$normalizedDest' does not exist or is not accessible."
    }

    # Resolve setup.exe executable path
    $resolvedSetup = Resolve-SetupExecutable -ExplicitSetupPath $SetupPath -AlternativeImagePath $ImagePath -BootCtx $BootObject
    if (-not $resolvedSetup) {
        throw "Windows Setup binary (setup.exe) could not be resolved from SetupPath: '$SetupPath' or ImagePath: '$ImagePath'."
    }

    # Resolve image index from parameter or workflow selection
    $resolvedIndex = $ImageIndex
    if ($resolvedIndex -le 0 -and $WorkflowSelection) {
        if ($WorkflowSelection.PSObject.Properties['WorkflowTag'] -and $WorkflowSelection.WorkflowTag -and $WorkflowSelection.WorkflowTag.PSObject.Properties['Index'] -and ($null -ne $WorkflowSelection.WorkflowTag.Index)) {
            $resolvedIndex = [int]$WorkflowSelection.WorkflowTag.Index
        } elseif ($WorkflowSelection.PSObject.Properties['ImageIndex'] -and ($null -ne $WorkflowSelection.ImageIndex)) {
            $resolvedIndex = [int]$WorkflowSelection.ImageIndex
        } elseif ($WorkflowSelection.PSObject.Properties['Index'] -and ($null -ne $WorkflowSelection.Index)) {
            $resolvedIndex = [int]$WorkflowSelection.Index
        }
    }
    if ($resolvedIndex -le 0) {
        $resolvedIndex = 1
    }

    # Resolve or generate Unattend answer file
    $finalUnattendPath = ""

    if (-not [string]::IsNullOrWhiteSpace($UnattendPath) -and (Test-Path -LiteralPath $UnattendPath)) {
        $finalUnattendPath = (Resolve-Path -LiteralPath $UnattendPath).Path
        Write-ComponentLog "Using existing unattended answer file: $finalUnattendPath" -Level "INFO"
    }
    else {
        # Auto-generate unattended file via template substitution
        $resolvedTemplate = Resolve-UnattendTemplate -ExplicitTemplatePath $TemplateUnattendPath -BootCtx $BootObject
        if (-not $resolvedTemplate) {
            throw "Could not resolve an unattended template (e.g. Autopilot.xml). Pass -TemplateUnattendPath or -UnattendPath."
        }

        $finalUnattendPath = New-LiteDeployUnattendXml `
            -TemplateFile $resolvedTemplate `
            -TargetOutputFile $GeneratedUnattendPath `
            -ConfigObj $BootConfig `
            -WorkflowData $WorkflowSelection `
            -DiskData $DiskResult `
            -BootCtx $BootObject
    }

    try {
        $result = Invoke-SetupEngine `
            -ResolvedSetupPath $resolvedSetup `
            -EffectiveUnattendPath $finalUnattendPath `
            -NormalizedDestination $normalizedDest `
            -SelectedImageIndex $resolvedIndex `
            -ExtraArgs $AdditionalArguments

        return $result
    }
    catch {
        Write-ComponentLog "ApplyOSImage failed: $($_.Exception.Message)" -Level "ERROR" -ForegroundColor Red
        throw $_
    }
}
