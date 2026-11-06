<#
.SYNOPSIS
    Applies a Windows operating system image using the Windows Setup (setup.exe) or DISM (dism.exe) engine with automated unattended answer file generation.

.DESCRIPTION
    LiteDeploy Runtime component that orchestrates Windows Setup or DISM imaging during WinPE deployment.
    Before applying the OS image, it automatically generates a customized answer file (default: X:\unattended.xml)
    by performing string key substitution on an XML template (e.g. DomainJoin.xml) using properties from BootConfig.json,
    WorkflowSelection, and DiskPreparation.
    
    When a workflow is active, it strictly looks for the specific unattended template defined in the workflow's unattendPath
    and reports only the exact searched locations if missing.
    When deploying directly from the OS catalog without a workflow, unattended answer files are optional.

.PARAMETER SetupPath
    Full or relative path to setup.exe on the deployment share or local media.
    If ImagePath is passed instead, setup.exe will be resolved from the OS media folder.

.PARAMETER ImagePath
    Alternative path to install.wim/esd or OS root directory. Used to resolve setup.exe or DISM apply file.

.PARAMETER UnattendPath
    Explicit path to an existing unattended answer file. If omitted, an answer file is automatically generated.

.PARAMETER TemplateUnattendPath
    Path to the XML template used for substitution (e.g. "Content\Unattend\DomainJoin.xml").
    If omitted, automatically resolves from the workflow or connected deployment share.

.PARAMETER GeneratedUnattendPath
    Destination file path for the generated answer file. Default: "X:\unattended.xml".

.PARAMETER Destination
    Target OS partition mount or drive letter (e.g. "W:\" or "W:"). Default: "W:\".

.PARAMETER WorkflowSelection
    Optional PSCustomObject containing technician selections from WorkflowSelection (ComputerName, TargetDiskIndex, WorkflowTag, etc.).

.PARAMETER DiskResult
    Optional PSCustomObject containing partition results from DiskPreparation (DiskNumber, OSPartitionNumber, etc.).

.PARAMETER BootConfig
    Optional configuration object or hashtable loaded from BootConfig.json containing ComputerSetup properties.

.PARAMETER DriverPath
    Optional path to drivers to inject.

.PARAMETER AdditionalArguments
    Optional array of additional command-line arguments to pass directly to setup.exe or dism.exe.

.PARAMETER BootObject
    Optional LiteDeploy runtime context object passed from BootInitializer or DeploymentEngine.

.PARAMETER ExecuteSetup
    Standalone only. Without this switch the script is read-only: it resolves/tests setup.exe/dism.exe,
    the image file, and the unattend template, then returns the result. Imaging is launched
    only when -ExecuteSetup is passed.

.PARAMETER Metadata
    Switch to output component metadata as a PSCustomObject without executing setup.exe.

.PARAMETER ValidateEngineOnly
    Check ComputerSetup.ImageEngine only; no media access, files, or processes.

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
    [string]$DriverPath = "",

    [Parameter(Mandatory = $false)]
    [string[]]$AdditionalArguments = @(),

    [Parameter(Mandatory = $false)]
    [psobject]$BootObject = $null,

    [Parameter(Mandatory = $false)]
    [switch]$ExecuteSetup,

    [Parameter(Mandatory = $false)]
    [switch]$ValidateEngineOnly
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
        ComponentId          = "Image"
        Name                 = "LiteDeploy Image"
        Version              = "2.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "WinPE"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("Logs", "Workflow")
        Description          = "Applies Windows operating system using Windows Setup (setup.exe) or DISM (dism.exe) with automated unattended answer file generation."
    }
}

if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

# ==============================================================================
# REGION 2: LOGGING UTILITIES & ENGINE RESOLUTION
# ==============================================================================

function Write-ComponentLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$Level = "INFO",
        [System.ConsoleColor]$ForegroundColor = [System.ConsoleColor]::White
    )

    if (Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue) {
        Write-LiteDeployLog -Component "Image" -Message $Message -Level $Level
    }
    else {
        Write-Host " [$($Level.PadRight(7))] $Message" -ForegroundColor $ForegroundColor
    }
}

function Resolve-LiteDeployImageEngine {
    param(
        [psobject]$Configuration = $null,
        [psobject]$WorkflowSelection = $null
    )

    $engineName = $null
    $engineSpecified = $false

    # 1. Check if workflow overrides ImageEngine first (highest precedence)
    if ($WorkflowSelection) {
        $wfSetup = if ($WorkflowSelection.PSObject.Properties['WorkflowTag'] -and $WorkflowSelection.WorkflowTag -and ($WorkflowSelection.WorkflowTag -isnot [string]) -and $WorkflowSelection.WorkflowTag.PSObject.Properties['ComputerSetup']) {
            $WorkflowSelection.WorkflowTag.ComputerSetup
        }
        elseif ($WorkflowSelection.PSObject.Properties['ComputerSetup']) {
            $WorkflowSelection.ComputerSetup
        }
        else { $null }

        if ($wfSetup -is [System.Collections.IDictionary] -and $wfSetup.Contains('ImageEngine')) {
            $engineName = [string]$wfSetup['ImageEngine']
            $engineSpecified = $true
        }
        elseif ($wfSetup -and $wfSetup.PSObject.Properties['ImageEngine']) {
            $engineName = [string]$wfSetup.ImageEngine
            $engineSpecified = $true
        }
    }

    # 2. Fall back to BootConfig
    if (-not $engineSpecified) {
        $computerSetup = if ($Configuration -is [System.Collections.IDictionary]) {
            if ($Configuration.Contains('ComputerSetup')) { $Configuration['ComputerSetup'] } else { $null }
        }
        elseif ($Configuration -and $Configuration.PSObject.Properties['ComputerSetup']) {
            $Configuration.ComputerSetup
        }
        else { $null }

        if ($computerSetup -is [System.Collections.IDictionary]) {
            if ($computerSetup.Contains('ImageEngine')) {
                $engineName = [string]$computerSetup['ImageEngine']
                $engineSpecified = $true
            }
        }
        elseif ($computerSetup -and $computerSetup.PSObject.Properties['ImageEngine']) {
            $engineName = [string]$computerSetup.ImageEngine
            $engineSpecified = $true
        }
    }

    if (-not $engineSpecified) {
        return 'setup.exe'
    }

    if ([string]::IsNullOrWhiteSpace($engineName)) {
        throw "Unsupported ComputerSetup.ImageEngine '$engineName'. Supported engines: setup.exe, dism.exe."
    }

    switch ($engineName.Trim().ToLowerInvariant()) {
        'setup.exe' { return 'setup.exe' }
        'setup'     { return 'setup.exe' }
        'dism.exe'  { return 'dism.exe' }
        'dism'      { return 'dism.exe' }
        default     { throw "Unsupported ComputerSetup.ImageEngine '$engineName'. Supported engines: setup.exe, dism.exe." }
    }
}

function Get-LiteDeployComputerSetupObject {
    <#
    .SYNOPSIS
        Returns ComputerSetup from WorkflowTag (preferred) or BootConfig/Configuration.
    #>
    param(
        [psobject]$Configuration = $null,
        [psobject]$WorkflowSelection = $null
    )

    if ($WorkflowSelection) {
        $wfSetup = if ($WorkflowSelection.PSObject.Properties['WorkflowTag'] -and $WorkflowSelection.WorkflowTag -and ($WorkflowSelection.WorkflowTag -isnot [string]) -and $WorkflowSelection.WorkflowTag.PSObject.Properties['ComputerSetup']) {
            $WorkflowSelection.WorkflowTag.ComputerSetup
        }
        elseif ($WorkflowSelection.PSObject.Properties['ComputerSetup']) {
            $WorkflowSelection.ComputerSetup
        }
        else { $null }

        if ($null -ne $wfSetup) { return $wfSetup }
    }

    if ($Configuration -is [System.Collections.IDictionary]) {
        if ($Configuration.Contains('ComputerSetup')) { return $Configuration['ComputerSetup'] }
        return $null
    }

    if ($Configuration -and $Configuration.PSObject.Properties['ComputerSetup']) {
        return $Configuration.ComputerSetup
    }

    return $null
}

function Test-LiteDeploySkipSetupHardwareRequirements {
    <#
    .SYNOPSIS
        True when ComputerSetup.SkipSetupHardwareRequirements is enabled.
        Workflow override takes precedence; falls back to BootConfig baseline.
    #>
    param(
        [psobject]$Configuration = $null,
        [psobject]$WorkflowSelection = $null
    )

    # 1. Check Workflow override first
    if ($WorkflowSelection) {
        $wfSetup = if ($WorkflowSelection.PSObject.Properties['WorkflowTag'] -and $WorkflowSelection.WorkflowTag -and ($WorkflowSelection.WorkflowTag -isnot [string]) -and $WorkflowSelection.WorkflowTag.PSObject.Properties['ComputerSetup']) {
            $WorkflowSelection.WorkflowTag.ComputerSetup
        }
        elseif ($WorkflowSelection.PSObject.Properties['ComputerSetup']) {
            $WorkflowSelection.ComputerSetup
        }
        else { $null }

        if ($wfSetup -is [System.Collections.IDictionary] -and $wfSetup.Contains('SkipSetupHardwareRequirements')) {
            return [bool]$wfSetup['SkipSetupHardwareRequirements']
        }
        elseif ($wfSetup -and $wfSetup.PSObject.Properties['SkipSetupHardwareRequirements']) {
            return [bool]$wfSetup.SkipSetupHardwareRequirements
        }
    }

    # 2. Fall back to BootConfig baseline
    $cfgSetup = if ($Configuration -is [System.Collections.IDictionary] -and $Configuration.Contains('ComputerSetup')) {
        $Configuration['ComputerSetup']
    }
    elseif ($Configuration -and $Configuration.PSObject.Properties['ComputerSetup']) {
        $Configuration.ComputerSetup
    }
    else { $null }

    if ($cfgSetup -is [System.Collections.IDictionary] -and $cfgSetup.Contains('SkipSetupHardwareRequirements')) {
        return [bool]$cfgSetup['SkipSetupHardwareRequirements']
    }
    elseif ($cfgSetup -and $cfgSetup.PSObject.Properties['SkipSetupHardwareRequirements']) {
        return [bool]$cfgSetup.SkipSetupHardwareRequirements
    }

    return $false
}

function Set-LiteDeploySetupHardwareRequirementBypass {
    <#
    .SYNOPSIS
        Applies WinPE LabConfig and MoSetup registry bypasses so Setup.exe can ignore Windows hardware requirements.
    #>
    [CmdletBinding()]
    param()

    try {
        # 1. HKLM:\SYSTEM\Setup\LabConfig
        $labPath = 'HKLM:\SYSTEM\Setup\LabConfig'
        if (-not (Test-Path -LiteralPath $labPath)) {
            $null = New-Item -Path $labPath -Force -ErrorAction Stop
        }

        $labSettings = @(
            'BypassTPMCheck',
            'BypassSecureBootCheck',
            'BypassCPUCheck',
            'BypassRAMCheck',
            'BypassStorageCheck',
            'BypassDiskCheck'
        )

        foreach ($name in $labSettings) {
            Set-ItemProperty -Path $labPath -Name $name -Value 1 -Type DWord -Force -ErrorAction Stop | Out-Null
        }

        # 2. HKLM:\SYSTEM\Setup\MoSetup
        $moSetupPath = 'HKLM:\SYSTEM\Setup\MoSetup'
        if (-not (Test-Path -LiteralPath $moSetupPath)) {
            $null = New-Item -Path $moSetupPath -Force -ErrorAction Stop
        }

        Set-ItemProperty -Path $moSetupPath -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -Value 1 -Type DWord -Force -ErrorAction Stop | Out-Null

        Write-ComponentLog "SkipSetupHardwareRequirements=true: applied LabConfig and MoSetup bypasses (WinPE registry only)." -Level "WARNING" -ForegroundColor Yellow
        return $true
    }
    catch {
        Write-ComponentLog "SkipSetupHardwareRequirements: failed to apply LabConfig/MoSetup bypasses: $($_.Exception.Message)" -Level "ERROR" -ForegroundColor Red
        throw
    }
}

# ==============================================================================
# REGION 3: PATH RESOLUTION & DISCOVERY
# ==============================================================================

function Get-LiteDeployImageDeploymentRoot {
    <#
    .SYNOPSIS
        Resolves the active deployment root using the Environment component contract and BootObject context.
    #>
    param([psobject]$BootCtx = $null)

    if ($BootCtx) {
        if ($BootCtx.PSObject.Properties['DeploymentRoot'] -and $BootCtx.DeploymentRoot) {
            return [string]$BootCtx.DeploymentRoot
        }
        if ($BootCtx.PSObject.Properties['DeploymentType'] -and $BootCtx.DeploymentType -eq 'Media') {
            $srcDrive = if ($BootCtx.PSObject.Properties['MediaDriveLetter'] -and $BootCtx.MediaDriveLetter) { [string]$BootCtx.MediaDriveLetter } else { [string]$BootCtx.DriveLetter }
            $localRoot = if ($BootCtx.PSObject.Properties['LocalRootName'] -and $BootCtx.LocalRootName) { [string]$BootCtx.LocalRootName } else { '~LiteDeploy' }
            return Join-Path ($srcDrive.TrimEnd('\') + '\') $localRoot
        }
        if ($BootCtx.PSObject.Properties['DriveLetter'] -and $BootCtx.DriveLetter) {
            $dl = [string]$BootCtx.DriveLetter
            return if ($dl -match '^[A-Za-z]:$') { "$dl\" } else { $dl }
        }
        if ($BootCtx.PSObject.Properties['NetworkPath'] -and $BootCtx.NetworkPath) {
            return [string]$BootCtx.NetworkPath
        }
    }

    if (Get-Variable -Name 'LiteDeployPathSettings' -Scope Global -ErrorAction SilentlyContinue) {
        $settings = $global:LiteDeployPathSettings
        if ($settings -and $settings.PSObject.Properties['ComponentRoot'] -and $settings.ComponentRoot) {
            return (Split-Path -Parent $settings.ComponentRoot)
        }
    }

    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    if ($scriptDir) {
        $candidateRoot = Join-Path $scriptDir "..\..\..\..\DeploymentShare"
        if (Test-Path -LiteralPath $candidateRoot) {
            return (Resolve-Path -LiteralPath $candidateRoot).Path
        }
    }

    return (Get-Location).Path
}

function Resolve-LiteDeployImageContentPath {
    <#
    .SYNOPSIS
        Resolves a content path against the active deployment root using Environment standards.
    #>
    param(
        [string]$Path = "",
        [psobject]$BootCtx = $null
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $cleanPath = $Path.Trim()
    if ($cleanPath -match '^[A-Za-z]:[\\/]' -or $cleanPath -match '^\\\\') {
        return $cleanPath
    }

    $deploymentRoot = Get-LiteDeployImageDeploymentRoot -BootCtx $BootCtx

    if (Get-Command Resolve-LiteDeployContentPath -ErrorAction SilentlyContinue) {
        return (Resolve-LiteDeployContentPath -Path $cleanPath -DeploymentRoot $deploymentRoot)
    }

    return Join-Path $deploymentRoot ($cleanPath.Replace('/', '\').TrimStart('\'))
}

function Resolve-SetupExecutable {
    param(
        [string]$ExplicitSetupPath = "",
        [string]$AlternativeImagePath = "",
        [psobject]$BootCtx = $null
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitSetupPath)) {
        $resolved = Resolve-LiteDeployImageContentPath -Path $ExplicitSetupPath -BootCtx $BootCtx
        if (Test-Path -LiteralPath $resolved -PathType Leaf) {
            return (Resolve-Path -LiteralPath $resolved).Path
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($AlternativeImagePath)) {
        if ($AlternativeImagePath -match '(?i)setup\.exe$') {
            $resolved = Resolve-LiteDeployImageContentPath -Path $AlternativeImagePath -BootCtx $BootCtx
            if (Test-Path -LiteralPath $resolved -PathType Leaf) {
                return (Resolve-Path -LiteralPath $resolved).Path
            }
        }
        elseif ($AlternativeImagePath -match '(?i)sources\\install\.(wim|esd|swm)$') {
            $osFolder = Split-Path -Parent (Split-Path -Parent $AlternativeImagePath)
            $resolved = Resolve-LiteDeployImageContentPath -Path (Join-Path $osFolder "setup.exe") -BootCtx $BootCtx
            if (Test-Path -LiteralPath $resolved -PathType Leaf) {
                return (Resolve-Path -LiteralPath $resolved).Path
            }
        }
        else {
            $resolved = Resolve-LiteDeployImageContentPath -Path (Join-Path $AlternativeImagePath "setup.exe") -BootCtx $BootCtx
            if (Test-Path -LiteralPath $resolved -PathType Leaf) {
                return (Resolve-Path -LiteralPath $resolved).Path
            }
        }
    }

    return $null
}

function Resolve-LiteDeployImageFile {
    <#
    .SYNOPSIS
        Finds install.wim/esd/swm for a media root, sources folder, or direct image path. Read-only.
    #>
    param(
        [string]$ImagePath = "",
        [string]$SetupPath = "",
        [psobject]$BootCtx = $null
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($ImagePath)) {
        if ($ImagePath -match '(?i)\.(wim|esd|swm)$') {
            $candidates.Add($ImagePath)
        }
        else {
            foreach ($ext in @("wim", "esd", "swm")) {
                $candidates.Add((Join-Path $ImagePath "sources\install.$ext"))
                $candidates.Add((Join-Path $ImagePath "install.$ext"))
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($SetupPath)) {
        $mediaRoot = Split-Path -Parent $SetupPath
        foreach ($ext in @("wim", "esd", "swm")) {
            $candidates.Add((Join-Path $mediaRoot "sources\install.$ext"))
        }
    }

    foreach ($cand in $candidates) {
        if ([string]::IsNullOrWhiteSpace($cand)) { continue }
        $resolved = Resolve-LiteDeployImageContentPath -Path $cand -BootCtx $BootCtx
        if (Test-Path -LiteralPath $resolved -PathType Leaf) {
            return (Resolve-Path -LiteralPath $resolved).Path
        }
    }

    return $null
}

function Resolve-UnattendTemplate {
    param(
        [string]$ExplicitTemplatePath = "",
        [psobject]$BootCtx = $null,
        [psobject]$WorkflowSelection = $null
    )

    # =========================================================================
    # 1. WORKFLOW MODE: Strict evaluation (only search explicit workflow path)
    # =========================================================================
    if ($WorkflowSelection) {
        $tag = if ($WorkflowSelection.PSObject.Properties['WorkflowTag'] -and $WorkflowSelection.WorkflowTag -and ($WorkflowSelection.WorkflowTag -isnot [string])) {
            $WorkflowSelection.WorkflowTag
        }
        else { $WorkflowSelection }

        $wfId = if ($tag.PSObject.Properties['WorkflowId'] -and $tag.WorkflowId) { [string]$tag.WorkflowId }
        elseif ($tag.PSObject.Properties['Id'] -and $tag.Id) { [string]$tag.Id }
        else { "" }

        $wfName = if ($tag.PSObject.Properties['WorkflowName'] -and $tag.WorkflowName) { [string]$tag.WorkflowName }
        elseif ($tag.PSObject.Properties['Name'] -and $tag.Name) { [string]$tag.Name }
        else { "Workflow" }

        $targetTemplate = $ExplicitTemplatePath
        if ([string]::IsNullOrWhiteSpace($targetTemplate)) {
            if ($tag.PSObject.Properties['UnattendPath'] -and $tag.UnattendPath) {
                $targetTemplate = [string]$tag.UnattendPath
            }
            elseif ($WorkflowSelection.PSObject.Properties['UnattendPath'] -and $WorkflowSelection.UnattendPath) {
                $targetTemplate = [string]$WorkflowSelection.UnattendPath
            }
        }

        if ([string]::IsNullOrWhiteSpace($targetTemplate)) {
            throw "Workflow '$wfName' ($wfId) does not specify an 'unattendPath'. Workflows must explicitly define an unattended answer file template."
        }

        # Resolve expected path directly against deployment root via Environment component standard
        $expectedPath = Resolve-LiteDeployImageContentPath -Path $targetTemplate -BootCtx $BootCtx

        if (Test-Path -LiteralPath $expectedPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $expectedPath).Path
        }

        throw "Unattended template '$targetTemplate' specified by workflow '$wfName' ($wfId) was not found at '$expectedPath'."
    }

    # =========================================================================
    # 2. AD-HOC / OS CATALOG MODE (No workflow active)
    # =========================================================================
    if (-not [string]::IsNullOrWhiteSpace($ExplicitTemplatePath)) {
        $expectedPath = Resolve-LiteDeployImageContentPath -Path $ExplicitTemplatePath -BootCtx $BootCtx
        if (Test-Path -LiteralPath $expectedPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $expectedPath).Path
        }
    }

    # Fallback to default catalog templates (Standard.xml, Unattend.xml)
    $defaultTemplates = @('Content\Unattend\Standard.xml', 'Content\Unattend\Unattend.xml', 'Standard.xml', 'Unattend.xml')
    foreach ($tName in $defaultTemplates) {
        $cand = Resolve-LiteDeployImageContentPath -Path $tName -BootCtx $BootCtx
        if (Test-Path -LiteralPath $cand -PathType Leaf) {
            return (Resolve-Path -LiteralPath $cand).Path
        }
    }

    Write-ComponentLog "No unattended template found for direct OS catalog imaging. Proceeding without answer file." -Level "INFO"
    return $null
}

# ==============================================================================
# REGION 4: UNATTENDED ANSWER FILE GENERATION & SUBSTITUTION
# ==============================================================================

function New-LiteDeployUnattendXml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplateFile,
        [Parameter(Mandatory = $true)]
        [string]$TargetOutputFile,
        [psobject]$ConfigObj = $null,
        [psobject]$WorkflowData = $null,
        [psobject]$DiskData = $null,
        [psobject]$BootCtx = $null
    )

    Write-ComponentLog "Generating unattended answer file from template: $TemplateFile" -Level "INIT" -ForegroundColor Cyan

    $effectiveConfig = if ($ConfigObj) { $ConfigObj } elseif ($BootCtx -and $BootCtx.PSObject.Properties['Config']) { $BootCtx.Config } elseif ($BootCtx) { $BootCtx } else { $null }

    # Extract substitution variables with safe defaults
    $compName = ""
    if ($WorkflowData -and $WorkflowData.PSObject.Properties['ComputerName'] -and $WorkflowData.ComputerName) {
        $compName = [string]$WorkflowData.ComputerName
    }
    elseif ($effectiveConfig -and $effectiveConfig.PSObject.Properties['ComputerName'] -and $effectiveConfig.ComputerName) {
        $compName = [string]$effectiveConfig.ComputerName
    }

    $compDesc = ""
    if ($WorkflowData -and $WorkflowData.PSObject.Properties['ComputerDescription'] -and $WorkflowData.ComputerDescription) {
        $compDesc = [string]$WorkflowData.ComputerDescription
    }
    elseif ($effectiveConfig -and $effectiveConfig.PSObject.Properties['ComputerDescription'] -and $effectiveConfig.ComputerDescription) {
        $compDesc = [string]$effectiveConfig.ComputerDescription
    }

    $diskId = 0
    if ($DiskData -and $DiskData.PSObject.Properties['DiskNumber'] -and ($null -ne $DiskData.DiskNumber)) {
        $diskId = [int]$DiskData.DiskNumber
    }
    elseif ($WorkflowData -and $WorkflowData.PSObject.Properties['TargetDiskIndex'] -and ($null -ne $WorkflowData.TargetDiskIndex)) {
        $diskId = [int]$WorkflowData.TargetDiskIndex
    }

    $partitionId = 3
    if ($DiskData -and $DiskData.PSObject.Properties['OSPartitionNumber'] -and ($null -ne $DiskData.OSPartitionNumber)) {
        $partitionId = [int]$DiskData.OSPartitionNumber
    }

    # Regional & Localization defaults
    $lang = "en-US"
    $keyboard = "0409:00000409"
    $timeZone = "Eastern Standard Time"
    $regOwner = ""
    $regOrg = ""
    $workgroup = ""
    $domain = ""
    $machineOU = ""

    # Check for Regional configuration
    if ($effectiveConfig) {
        $reg = if ($effectiveConfig -is [System.Collections.IDictionary]) {
            if ($effectiveConfig.Contains('Regional')) { $effectiveConfig['Regional'] } else { $null }
        }
        elseif ($effectiveConfig.PSObject.Properties['Regional']) {
            $effectiveConfig.Regional
        }
        else { $null }

        if ($reg) {
            if ($reg -is [System.Collections.IDictionary]) {
                if ($reg.Contains('Language') -and $reg['Language']) { $lang = [string]$reg['Language'] }
                if ($reg.Contains('KeyboardLayout') -and $reg['KeyboardLayout']) { $keyboard = [string]$reg['KeyboardLayout'] }
                if ($reg.Contains('TimeZone') -and $reg['TimeZone']) { $timeZone = [string]$reg['TimeZone'] }
            }
            else {
                if ($reg.PSObject.Properties['Language'] -and $reg.Language) { $lang = [string]$reg.Language }
                if ($reg.PSObject.Properties['KeyboardLayout'] -and $reg.KeyboardLayout) { $keyboard = [string]$reg.KeyboardLayout }
                if ($reg.PSObject.Properties['TimeZone'] -and $reg.TimeZone) { $timeZone = [string]$reg.TimeZone }
            }
        }
    }

    # Check for ComputerSetup configuration
    $cs = if ($effectiveConfig -is [System.Collections.IDictionary]) {
        if ($effectiveConfig.Contains('ComputerSetup')) { [pscustomobject]$effectiveConfig['ComputerSetup'] } else { $null }
    }
    elseif ($effectiveConfig -and $effectiveConfig.PSObject.Properties['ComputerSetup']) {
        [pscustomobject]$effectiveConfig.ComputerSetup
    }
    else { $null }

    if ($null -ne $cs) {
        if ($cs.PSObject.Properties['Language'] -and $cs.Language) { $lang = [string]$cs.Language }
        if ($cs.PSObject.Properties['KeyboardLocale'] -and $cs.KeyboardLocale) { $keyboard = [string]$cs.KeyboardLocale }
        if ($cs.PSObject.Properties['TimeZone'] -and $cs.TimeZone) { $timeZone = [string]$cs.TimeZone }
        if ($cs.PSObject.Properties['RegisteredOrganization'] -and ($null -ne $cs.RegisteredOrganization)) { $regOrg = [string]$cs.RegisteredOrganization }
        if ($cs.PSObject.Properties['RegisteredOwner'] -and ($null -ne $cs.RegisteredOwner)) { $regOwner = [string]$cs.RegisteredOwner }
        if ($cs.PSObject.Properties['JoinWorkGroup'] -and ($null -ne $cs.JoinWorkGroup)) { $workgroup = [string]$cs.JoinWorkGroup }
        elseif ($cs.PSObject.Properties['JoinWorkgroup'] -and ($null -ne $cs.JoinWorkgroup)) { $workgroup = [string]$cs.JoinWorkgroup }
        if ($cs.PSObject.Properties['JoinDomain'] -and ($null -ne $cs.JoinDomain)) { $domain = [string]$cs.JoinDomain }
        if ($cs.PSObject.Properties['MachineObjectOU'] -and ($null -ne $cs.MachineObjectOU)) { $machineOU = [string]$cs.MachineObjectOU }
        if ($cs.PSObject.Properties['PromptForComputerName'] -and $cs.PromptForComputerName -ne $true) { $compName = '' }
        if ($cs.PSObject.Properties['PromptForComputerDescription'] -and $cs.PromptForComputerDescription -ne $true) { $compDesc = '' }
    }

    if ([string]::IsNullOrWhiteSpace($workgroup)) {
        if ($effectiveConfig -is [System.Collections.IDictionary]) {
            if ($effectiveConfig.Contains('JoinWorkGroup') -and ($null -ne $effectiveConfig['JoinWorkGroup'])) { $workgroup = [string]$effectiveConfig['JoinWorkGroup'] }
            elseif ($effectiveConfig.Contains('JoinWorkgroup') -and ($null -ne $effectiveConfig['JoinWorkgroup'])) { $workgroup = [string]$effectiveConfig['JoinWorkgroup'] }
        }
        elseif ($effectiveConfig) {
            if ($effectiveConfig.PSObject.Properties['JoinWorkGroup'] -and ($null -ne $effectiveConfig.JoinWorkGroup)) { $workgroup = [string]$effectiveConfig.JoinWorkGroup }
            elseif ($effectiveConfig.PSObject.Properties['JoinWorkgroup'] -and ($null -ne $effectiveConfig.JoinWorkgroup)) { $workgroup = [string]$effectiveConfig.JoinWorkgroup }
        }
    }

    if ([string]::IsNullOrWhiteSpace($domain)) {
        if ($effectiveConfig -is [System.Collections.IDictionary]) {
            if ($effectiveConfig.Contains('JoinDomain') -and ($null -ne $effectiveConfig['JoinDomain'])) { $domain = [string]$effectiveConfig['JoinDomain'] }
        }
        elseif ($effectiveConfig) {
            if ($effectiveConfig.PSObject.Properties['JoinDomain'] -and ($null -ne $effectiveConfig.JoinDomain)) { $domain = [string]$effectiveConfig.JoinDomain }
        }
    }

    if ([string]::IsNullOrWhiteSpace($machineOU)) {
        if ($effectiveConfig -is [System.Collections.IDictionary]) {
            if ($effectiveConfig.Contains('MachineObjectOU') -and ($null -ne $effectiveConfig['MachineObjectOU'])) { $machineOU = [string]$effectiveConfig['MachineObjectOU'] }
        }
        elseif ($effectiveConfig) {
            if ($effectiveConfig.PSObject.Properties['MachineObjectOU'] -and ($null -ne $effectiveConfig.MachineObjectOU)) { $machineOU = [string]$effectiveConfig.MachineObjectOU }
        }
    }

    if ([string]::IsNullOrWhiteSpace($domain) -and $WorkflowData -and $WorkflowData.PSObject.Properties['JoinDomain'] -and $WorkflowData.JoinDomain) {
        $domain = [string]$WorkflowData.JoinDomain
    }
    if ([string]::IsNullOrWhiteSpace($machineOU) -and $WorkflowData -and $WorkflowData.PSObject.Properties['MachineObjectOU'] -and $WorkflowData.MachineObjectOU) {
        $machineOU = [string]$WorkflowData.MachineObjectOU
    }

    Write-ComponentLog "Substituted Properties:" -Level "INFO"
    Write-ComponentLog " - ComputerName           : $compName" -Level "INFO"
    Write-ComponentLog " - Target Disk / Partition: Disk $diskId, Partition $partitionId" -Level "INFO"
    Write-ComponentLog " - Language / Locales     : $lang (Keyboard: $keyboard)" -Level "INFO"
    Write-ComponentLog " - TimeZone               : $timeZone" -Level "INFO"
    Write-ComponentLog " - RegisteredOrganization : $(if ($regOrg) { $regOrg } else { '(blank)' })" -Level "INFO"
    Write-ComponentLog " - RegisteredOwner        : $(if ($regOwner) { $regOwner } else { '(blank)' })" -Level "INFO"
    Write-ComponentLog " - JoinWorkgroup          : $(if ($workgroup) { $workgroup } else { '(blank)' })" -Level "INFO"
    Write-ComponentLog " - JoinDomain             : $(if ($domain) { $domain } else { '(blank)' })" -Level "INFO"
    Write-ComponentLog " - MachineObjectOU        : $(if ($machineOU) { $machineOU } else { '(blank)' })" -Level "INFO"

    # Read template content
    $templateContent = Get-Content -LiteralPath $TemplateFile -Raw -Encoding UTF8

    # Ensure missing ProductKey closing tag is repaired if template is older
    if ($templateContent -match '<ProductKey>\s*<!--[^>]*-->\s*<WillShowUI>Never</WillShowUI>\s*</UserData>') {
        $templateContent = $templateContent -replace '(<WillShowUI>Never</WillShowUI>\s*)', "`$1</ProductKey>`r`n        "
    }

    # Clean up residual <!--ImageIndex--> comment if present in template
    $generatedContent = $templateContent -replace '\s*<!--ImageIndex-->', ''

    # Resolve target architecture (default: amd64, arm64, x86)
    $arch = "amd64"
    $hwInvVar = Get-Variable -Name 'LiteDeployHardwareInventory' -Scope Global -ErrorAction SilentlyContinue
    if ($effectiveConfig -and $effectiveConfig.PSObject.Properties['Architecture'] -and $effectiveConfig.Architecture) {
        $arch = [string]$effectiveConfig.Architecture
    }
    elseif ($effectiveConfig -and $effectiveConfig.PSObject.Properties['ComputerSetup'] -and $effectiveConfig.ComputerSetup.PSObject.Properties['Architecture'] -and $effectiveConfig.ComputerSetup.Architecture) {
        $arch = [string]$effectiveConfig.ComputerSetup.Architecture
    }
    elseif ($hwInvVar -and $hwInvVar.Value -and $hwInvVar.Value.PSObject.Properties['Architecture'] -and $hwInvVar.Value.Architecture) {
        $rawArch = [string]$hwInvVar.Value.Architecture
        $arch = switch -Regex ($rawArch) {
            'ARM64|AARCH64' { 'arm64' }
            'X86|32' { 'x86' }
            default { 'amd64' }
        }
    }
    elseif (Test-Path env:PROCESSOR_ARCHITECTURE) {
        $arch = switch -Regex ($env:PROCESSOR_ARCHITECTURE) {
            'ARM64|AARCH64' { 'arm64' }
            'X86|32' { 'x86' }
            default { 'amd64' }
        }
    }

    # Perform string key substitutions
    $ownerXml = if (-not [string]::IsNullOrWhiteSpace($regOwner)) { '<RegisteredOwner>' + [Security.SecurityElement]::Escape($regOwner) + '</RegisteredOwner>' } else { '' }
    $orgXml = if (-not [string]::IsNullOrWhiteSpace($regOrg)) { '<RegisteredOrganization>' + [Security.SecurityElement]::Escape($regOrg) + '</RegisteredOrganization>' } else { '' }
    $computerNameXml = if ($compName) { '<ComputerName>' + [Security.SecurityElement]::Escape($compName) + '</ComputerName>' } else { '' }
    $workgroupXml = if (-not [string]::IsNullOrWhiteSpace($workgroup)) { '<JoinWorkgroup>' + [Security.SecurityElement]::Escape($workgroup.Trim()) + '</JoinWorkgroup>' } else { '' }
    $domainXml = if (-not [string]::IsNullOrWhiteSpace($domain)) { '<JoinDomain>' + [Security.SecurityElement]::Escape($domain.Trim()) + '</JoinDomain>' } else { '' }
    $machineOUXml = if (-not [string]::IsNullOrWhiteSpace($machineOU)) { '<MachineObjectOU>' + [Security.SecurityElement]::Escape($machineOU.Trim()) + '</MachineObjectOU>' } else { '' }

    $generatedContent = $templateContent `
        -replace '(?i)processorArchitecture="[^"]*"', "processorArchitecture=`"$arch`"" `
        -replace '<!--Architecture-->', $arch `
        -replace '<!--Arch-->', $arch `
        -replace '<!--DiskID-->', "<DiskID>$diskId</DiskID>" `
        -replace '<!--PartitionID-->', "<PartitionID>$partitionId</PartitionID>" `
        -replace '<!--SetupUILanguage-->', "<UILanguage>$lang</UILanguage>" `
        -replace '<!--UILanguage-->', "<UILanguage>$lang</UILanguage>" `
        -replace '<!--InputLocale-->', "<InputLocale>$keyboard</InputLocale>" `
        -replace '<!--SystemLocale-->', "<SystemLocale>$lang</SystemLocale>" `
        -replace '<!--UserLocale-->', "<UserLocale>$lang</UserLocale>" `
        -replace '<!--TimeZone-->', "<TimeZone>$timeZone</TimeZone>" `
        -replace '<!--Timezone-->', "<TimeZone>$timeZone</TimeZone>"

    # Literal replacement preserves dollar signs in registration text as well as XML escaping.
    $generatedContent = $generatedContent.Replace('<!--RegisteredOwner-->', $ownerXml).Replace('<!--RegisteredOrganization-->', $orgXml)
    $generatedContent = $generatedContent.Replace('<!--ComputerName-->', $computerNameXml)
    $generatedContent = $generatedContent.Replace('<!--JoinWorkGroup-->', $workgroupXml).Replace('<!--JoinWorkgroup-->', $workgroupXml)
    $generatedContent = $generatedContent.Replace('<!--JoinDomain-->', $domainXml)
    $generatedContent = $generatedContent.Replace('<!--MachineObjectOU-->', $machineOUXml)

    # Resolve Workflow provenance comment for header
    $wfTag = if ($WorkflowData -and $WorkflowData.PSObject.Properties['WorkflowTag'] -and $WorkflowData.WorkflowTag -and ($WorkflowData.WorkflowTag -isnot [string])) {
        $WorkflowData.WorkflowTag
    } else { $WorkflowData }

    $wfName = if ($wfTag -and $wfTag.PSObject.Properties['WorkflowName'] -and $wfTag.WorkflowName) { [string]$wfTag.WorkflowName }
    elseif ($wfTag -and $wfTag.PSObject.Properties['Name'] -and $wfTag.Name) { [string]$wfTag.Name }
    elseif ($WorkflowData -and $WorkflowData.PSObject.Properties['WorkflowName'] -and $WorkflowData.WorkflowName) { [string]$WorkflowData.WorkflowName }
    elseif ($WorkflowData -and $WorkflowData.PSObject.Properties['Name'] -and $WorkflowData.Name) { [string]$WorkflowData.Name }
    else { "OS Catalog (Direct)" }

    $wfId = if ($wfTag -and $wfTag.PSObject.Properties['WorkflowId'] -and $wfTag.WorkflowId) { [string]$wfTag.WorkflowId }
    elseif ($wfTag -and $wfTag.PSObject.Properties['Id'] -and $wfTag.Id) { [string]$wfTag.Id }
    elseif ($WorkflowData -and $WorkflowData.PSObject.Properties['WorkflowId'] -and $WorkflowData.WorkflowId) { [string]$WorkflowData.WorkflowId }
    elseif ($WorkflowData -and $WorkflowData.PSObject.Properties['Id'] -and $WorkflowData.Id) { [string]$WorkflowData.Id }
    else { "direct-catalog" }

    $templateLeaf = Split-Path -Path $TemplateFile -Leaf
    $genTimestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $workflowHeaderComment = "<!-- Generated by LiteDeploy Engine | Workflow: $wfName ($wfId) | Template: $templateLeaf | Date: $genTimestamp -->"

    if ($generatedContent -match '<!--WorkflowInfo-->') {
        $generatedContent = $generatedContent.Replace('<!--WorkflowInfo-->', $workflowHeaderComment)
    }
    elseif ($generatedContent -match '<\?xml[^\>]*\>') {
        $generatedContent = $generatedContent -replace '(\<\?xml[^\>]*\>\r?\n?)', "`$1$workflowHeaderComment`r`n"
    }

    # Workflow actions gate FullOS Run + Audit reseal (when their placeholders exist).
    # Selection object usually carries the catalog workflow on WorkflowTag.
    $workflowActionCount = 0
    $actionSources = @()
    if ($WorkflowData) {
        $actionSources += $WorkflowData
        if ($WorkflowData.PSObject.Properties['WorkflowTag'] -and $WorkflowData.WorkflowTag -and ($WorkflowData.WorkflowTag -isnot [string])) {
            $actionSources += $WorkflowData.WorkflowTag
        }
    }
    foreach ($actionSource in $actionSources) {
        foreach ($actionProp in @('actions', 'Actions')) {
            if ($actionSource.PSObject.Properties[$actionProp] -and $null -ne $actionSource.$actionProp) {
                $workflowActionCount = @($actionSource.$actionProp).Count
                break
            }
        }
        if ($workflowActionCount -gt 0) { break }
    }
    $hasFullOsActions = $workflowActionCount -gt 0
    Write-ComponentLog ("Workflow actions count={0}; FullOS Run / AuditMode placeholders will {1}." -f `
            $workflowActionCount, $(if ($hasFullOsActions) { 'be filled when present' } else { 'be cleared' })) -Level "INFO"

    # Specialize Order 1: always inject computer description into <!--ComputerDescription-->.
    if ([string]::IsNullOrWhiteSpace($compDesc)) {
        $compDesc = 'No Description'
    }
    $escapedCompDesc = [Security.SecurityElement]::Escape($compDesc)
    $computerDescriptionCommand = @"
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Set Computer Description</Description>
          <Path>cmd.exe /c reg add "HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" /v srvcomment /t REG_SZ /d "$escapedCompDesc" /f</Path>
        </RunSynchronousCommand>
"@
    if ($generatedContent -match '<!--ComputerDescription-->') {
        $generatedContent = $generatedContent -replace '<!--ComputerDescription-->', $computerDescriptionCommand
    }
    else {
        Write-ComponentLog "Unattend template missing <!--ComputerDescription--> placeholder; computer description was not staged." -Level "WARNING" -ForegroundColor Yellow
    }

    # Specialize Order 2: HKLM Run FullOS — short powershell.exe (no full System32 path; no nested \").
    # Gate: workflow actions > 0 + <!--LiteDeployFullOSRun--> (no hard kill-switch).
    $fullOsRunCommand = @"
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>LiteDeploy stage HKLM Run FullOS</Description>
          <Path>cmd.exe /c reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v LiteDeployFullOS /t REG_SZ /d "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File %SystemDrive%\~LiteDeploy\Engine\Scripts\Runtime\LiteDeploy.FullOS.ps1" /f</Path>
        </RunSynchronousCommand>
"@
    if ($generatedContent -match '<!--LiteDeployFullOSRun-->') {
        if ($hasFullOsActions) {
            $generatedContent = $generatedContent -replace '<!--LiteDeployFullOSRun-->', $fullOsRunCommand
            Write-ComponentLog "Staged HKLM Run\LiteDeployFullOS (short powershell.exe; workflow actions > 0)." -Level "SUCCESS" -ForegroundColor Green
        }
        else {
            $generatedContent = $generatedContent -replace '<!--LiteDeployFullOSRun-->', ''
            Write-ComponentLog "Cleared <!--LiteDeployFullOSRun--> (workflow actions count is 0)." -Level "INFO"
        }
    }

    # Specialize Order 3–4: temporary EnableLUA=0 only for non-Audit templates (no <!--AuditMode--> => Domain Join path).
    # FullOS restores EnableLUA=1 on cleanup (Clear-LiteDeployFullOSRunKey).
    $isNonAuditTemplate = $generatedContent -notmatch '<!--AuditMode-->'
    $disableUacCommand = @"
        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Description>LiteDeploy disable UAC for FullOS (temporary)</Description>
          <Path>cmd.exe /c reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA /t REG_DWORD /d 0 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Description>LiteDeploy mark UAC bypass for FullOS cleanup</Description>
          <Path>cmd.exe /c reg add "HKLM\SOFTWARE\LiteDeploy\FullOS" /v UacBypassed /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
"@
    if ($generatedContent -match '<!--DisableUacForFullOS-->') {
        if ($hasFullOsActions -and $isNonAuditTemplate) {
            $generatedContent = $generatedContent -replace '<!--DisableUacForFullOS-->', $disableUacCommand
            Write-ComponentLog "Staged temporary EnableLUA=0 (non-Audit template + actions > 0)." -Level "SUCCESS" -ForegroundColor Green
        }
        else {
            $generatedContent = $generatedContent -replace '<!--DisableUacForFullOS-->', ''
            Write-ComponentLog ("Cleared <!--DisableUacForFullOS--> (nonAudit={0}; actions={1})." -f $isNonAuditTemplate, $workflowActionCount) -Level "INFO"
        }
    }

    # oobeSystem Audit reseal — only when <!--AuditMode--> exists (and only with FullOS actions).
    $auditModeComponent = @"
    <component name="Microsoft-Windows-Deployment" processorArchitecture="$arch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <Reseal>
        <Mode>Audit</Mode>
      </Reseal>
    </component>
"@
    if ($generatedContent -match '<!--AuditMode-->') {
        if ($hasFullOsActions) {
            $generatedContent = $generatedContent -replace '<!--AuditMode-->', $auditModeComponent
            Write-ComponentLog "Staged Audit Mode reseal (<!--AuditMode--> + workflow actions > 0)." -Level "SUCCESS" -ForegroundColor Green
        }
        else {
            $generatedContent = $generatedContent -replace '<!--AuditMode-->', ''
            Write-ComponentLog "Cleared <!--AuditMode--> (workflow actions count is 0; OOBE will proceed)." -Level "INFO"
        }
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

    # Optional installation key: validate its shape, never print the value.
    $productKey = if ($cs -and $cs.PSObject.Properties['ProductKey']) { $cs.ProductKey } else { $null }
    if (-not [string]::IsNullOrWhiteSpace([string]$productKey)) {
        $productKey = ([string]$productKey).Trim().ToUpperInvariant()
        if ($productKey -cmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') {
            $setupComponents = $testXml.SelectNodes("/*[local-name()='unattend']/*[local-name()='settings'][@pass='windowsPE']/*[local-name()='component'][@name='Microsoft-Windows-Setup']")
            if ($setupComponents.Count -gt 0) {
                foreach ($setupComponent in $setupComponents) {
                    $keyNode = $setupComponent
                    foreach ($elementName in @('UserData', 'ProductKey', 'Key')) {
                        $child = $keyNode.SelectSingleNode("*[local-name()='$elementName']")
                        if ($null -eq $child) {
                            $child = $testXml.CreateElement($keyNode.Prefix, $elementName, $keyNode.NamespaceURI)
                            $null = $keyNode.AppendChild($child)
                        }
                        $keyNode = $child
                    }
                    $keyNode.InnerText = $productKey
                }
                $generatedContent = $testXml.OuterXml
            }
        }
        else {
            Write-ComponentLog 'ComputerSetup.ProductKey has an invalid format; the configured key was not added.' -Level WARNING
        }
    }

    # Determine effective target path (fallback to TEMP if target drive does not exist in testing)
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
# REGION 5: SETUP.EXE & DISM.EXE EXECUTION ENGINES
# ==============================================================================

function Get-LiteDeploySetupArguments {
    <#
    .SYNOPSIS
        Builds the setup.exe argument string (/NoReboot /DiagnosticPrompt enable /ImageIndex /InstallFrom /Unattend /InstallDrivers).
    #>
    [CmdletBinding()]
    param(
        [string]$ImagePath = "",
        [int]$ImageIndex = 1,
        [string]$UnattendPath = "",
        [string]$DriverPath = "",
        [string[]]$ExtraArgs = @()
    )

    $displayIndex = if ($ImageIndex -gt 0) { $ImageIndex } else { 1 }
    $argsList = [System.Collections.Generic.List[string]]::new()
    $argsList.Add("/NoReboot")
    $argsList.Add("/DiagnosticPrompt enable")
    $argsList.Add("/ImageIndex $displayIndex")

    if (-not [string]::IsNullOrWhiteSpace($ImagePath) -and (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
        $argsList.Add("/InstallFrom `"$ImagePath`"")
    }

    if (-not [string]::IsNullOrWhiteSpace($UnattendPath)) {
        $argsList.Add("/Unattend:`"$UnattendPath`"")
    }

    if (-not [string]::IsNullOrWhiteSpace($DriverPath) -and (Test-Path -LiteralPath $DriverPath -PathType Container)) {
        $argsList.Add("/InstallDrivers `"$DriverPath`"")
    }

    if ($ExtraArgs -and $ExtraArgs.Count -gt 0) {
        foreach ($arg in $ExtraArgs) {
            if (-not [string]::IsNullOrWhiteSpace($arg)) {
                $argsList.Add($arg)
            }
        }
    }

    return ($argsList -join " ")
}

function Invoke-SetupEngine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedSetupPath,
        [string]$EffectiveUnattendPath = "",
        [Parameter(Mandatory = $true)]
        [string]$NormalizedDestination,
        [string]$ResolvedImagePath = "",
        [int]$SelectedImageIndex = 0,
        [string]$DriverFolder = "",
        [string[]]$ExtraArgs = @()
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-ComponentLog "================================================================" -Level "INIT" -ForegroundColor Cyan
    Write-ComponentLog "Starting Windows Setup Engine (Setup.exe)..." -Level "INIT" -ForegroundColor Cyan
    Write-ComponentLog "Setup Binary : $ResolvedSetupPath" -Level "INFO"

    try {
        $setupVersion = (Get-Item -LiteralPath $ResolvedSetupPath).VersionInfo.ProductVersion
        Write-ComponentLog "Setup Version: $setupVersion" -Level "INFO"
    }
    catch {}

    if (-not [string]::IsNullOrWhiteSpace($ResolvedImagePath)) {
        Write-ComponentLog "Image File   : $ResolvedImagePath" -Level "INFO"
    }

    $displayIndex = if ($SelectedImageIndex -gt 0) { $SelectedImageIndex } else { 1 }
    Write-ComponentLog "Image Index  : $displayIndex" -Level "INFO"
    Write-ComponentLog "Target Drive : $NormalizedDestination" -Level "INFO"
    if (-not [string]::IsNullOrWhiteSpace($EffectiveUnattendPath)) {
        Write-ComponentLog "Unattend XML : $EffectiveUnattendPath" -Level "INFO"
    }
    if (-not [string]::IsNullOrWhiteSpace($DriverFolder)) {
        Write-ComponentLog "Driver Path  : $DriverFolder" -Level "INFO"
    }

    $argumentsString = Get-LiteDeploySetupArguments `
        -ImagePath $ResolvedImagePath `
        -ImageIndex $displayIndex `
        -UnattendPath $EffectiveUnattendPath `
        -DriverPath $DriverFolder `
        -ExtraArgs $ExtraArgs

    Write-ComponentLog "Command Line : $ResolvedSetupPath $argumentsString" -Level "INFO"
    Write-ComponentLog "Launching Windows Setup process. Please wait..." -Level "INIT" -ForegroundColor Cyan

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $ResolvedSetupPath
    $processInfo.WorkingDirectory = Split-Path -Parent $ResolvedSetupPath
    $processInfo.Arguments = $argumentsString
    $processInfo.UseShellExecute = $false

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
    $btDir = Join-Path $NormalizedDestination "`$Windows.~BT"
    $hasArtifacts = (Test-Path -LiteralPath $windowsDir) -or (Test-Path -LiteralPath $btDir)

    if (-not $hasArtifacts) {
        Write-ComponentLog "Warning: Neither '$windowsDir' nor '$btDir' was found on target destination '$NormalizedDestination'." -Level "WARNING" -ForegroundColor Yellow
    }
    else {
        Write-ComponentLog "Verified offline Windows installation artifacts on target destination '$NormalizedDestination'." -Level "SUCCESS" -ForegroundColor Green
    }

    Write-ComponentLog "OSInstallation (Setup.exe) finished successfully." -Level "SUCCESS" -ForegroundColor Green
    Write-ComponentLog "================================================================" -Level "SUCCESS" -ForegroundColor Green

    return [PSCustomObject]@{
        Success         = $true
        Engine          = "setup.exe"
        SetupPath       = $ResolvedSetupPath
        ImagePath       = $ResolvedImagePath
        ImageIndex      = $displayIndex
        UnattendPath    = $EffectiveUnattendPath
        Destination     = $NormalizedDestination
        ExitCode        = $exitCode
        DurationSeconds = $durationSec
        CompletedTime   = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    }
}

function Invoke-DismEngine {
    <#
    .SYNOPSIS
        Applies a Windows OS image via DISM (/Apply-Image), sets up the BCD bootloader via bcdboot.exe,
        injects staged drivers via DISM (/Add-Driver), and stages unattended answer files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedImagePath,
        [string]$EffectiveUnattendPath = "",
        [Parameter(Mandatory = $true)]
        [string]$NormalizedDestination,
        [int]$SelectedImageIndex = 1,
        [psobject]$DiskData = $null,
        [string]$DriverFolder = "",
        [string[]]$ExtraArgs = @()
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-ComponentLog "================================================================" -Level "INIT" -ForegroundColor Cyan
    Write-ComponentLog "Starting Windows DISM Imaging Engine (dism.exe)..." -Level "INIT" -ForegroundColor Cyan
    Write-ComponentLog "Image File   : $ResolvedImagePath" -Level "INFO"

    $displayIndex = if ($SelectedImageIndex -gt 0) { $SelectedImageIndex } else { 1 }
    Write-ComponentLog "Image Index  : $displayIndex" -Level "INFO"
    Write-ComponentLog "Target Drive : $NormalizedDestination" -Level "INFO"
    if (-not [string]::IsNullOrWhiteSpace($EffectiveUnattendPath)) {
        Write-ComponentLog "Unattend XML : $EffectiveUnattendPath" -Level "INFO"
    }
    if (-not [string]::IsNullOrWhiteSpace($DriverFolder)) {
        Write-ComponentLog "Driver Path  : $DriverFolder" -Level "INFO"
    }

    # 1. Apply OS Image via dism.exe /Apply-Image
    Write-ComponentLog "Applying OS image via DISM (/Apply-Image)..." -Level "INIT" -ForegroundColor Cyan
    $cleanDest = $NormalizedDestination.TrimEnd('\')
    $applyArgs = "/Apply-Image /ImageFile:`"$ResolvedImagePath`" /Index:$displayIndex /ApplyDir:$cleanDest\"
    if ($ExtraArgs -and $ExtraArgs.Count -gt 0) {
        $applyArgs += " " + ($ExtraArgs -join " ")
    }
    Write-ComponentLog "Command Line : dism.exe $applyArgs" -Level "INFO"

    $proc = Start-Process -FilePath "dism.exe" -ArgumentList $applyArgs -Wait -PassThru -NoNewWindow
    $exitCode = $proc.ExitCode

    if ($exitCode -ne 0) {
        $hexCode = "0x{0:X8}" -f $exitCode
        Write-ComponentLog "DISM /Apply-Image failed with exit code $exitCode ($hexCode)." -Level "ERROR" -ForegroundColor Red
        throw "DISM Apply-Image failed with exit code $exitCode ($hexCode)."
    }
    Write-ComponentLog "DISM /Apply-Image completed successfully." -Level "SUCCESS" -ForegroundColor Green

    # 2. Configure BCD Bootloader via bcdboot.exe
    Write-ComponentLog "Configuring system bootloader (bcdboot.exe)..." -Level "INIT" -ForegroundColor Cyan
    $windowsDir = Join-Path "$cleanDest\" "Windows"
    $targetDiskNum = if ($DiskData -and $DiskData.PSObject.Properties['DiskNumber'] -and ($null -ne $DiskData.DiskNumber)) { [int]$DiskData.DiskNumber } else { 0 }
    $sysPartNum = if ($DiskData -and $DiskData.PSObject.Properties['SystemPartitionNumber'] -and ($null -ne $DiskData.SystemPartitionNumber)) { [int]$DiskData.SystemPartitionNumber } else { 1 }
    $bootMode = if ($DiskData -and $DiskData.PSObject.Properties['BootMode'] -and $DiskData.BootMode) { [string]$DiskData.BootMode } else { "UEFI" }
    $firmware = if ($bootMode -ieq "UEFI") { "UEFI" } else { "BIOS" }

    $tempBootDrive = "S:"
    $bootLetterAssigned = $false
    try {
        $sysPart = Get-Partition -DiskNumber $targetDiskNum -PartitionNumber $sysPartNum -ErrorAction SilentlyContinue
        if ($sysPart -and -not $sysPart.DriveLetter) {
            $null = Set-Partition -DiskNumber $targetDiskNum -PartitionNumber $sysPartNum -NewDriveLetter "S" -ErrorAction Stop
            $bootLetterAssigned = $true
        }
        elseif ($sysPart -and $sysPart.DriveLetter) {
            $tempBootDrive = "$($sysPart.DriveLetter):"
        }
    }
    catch {
        Write-ComponentLog "Note: Could not assign drive letter S: to system partition ($($_.Exception.Message)). Attempting bcdboot with default volume." -Level "WARNING"
    }

    try {
        $bcdArgs = "`"$windowsDir`" /s $tempBootDrive /f $firmware"
        Write-ComponentLog "Command Line : bcdboot.exe $bcdArgs" -Level "INFO"
        $bcdProc = Start-Process -FilePath "bcdboot.exe" -ArgumentList $bcdArgs -Wait -PassThru -NoNewWindow
        if ($bcdProc.ExitCode -ne 0) {
            Write-ComponentLog "bcdboot /f $firmware returned code $($bcdProc.ExitCode). Retrying with /f ALL..." -Level "WARNING"
            $bcdProc = Start-Process -FilePath "bcdboot.exe" -ArgumentList "`"$windowsDir`" /s $tempBootDrive /f ALL" -Wait -PassThru -NoNewWindow
        }
        if ($bcdProc.ExitCode -ne 0) {
            throw "bcdboot.exe failed with exit code $($bcdProc.ExitCode)."
        }
        Write-ComponentLog "Bootloader configuration completed successfully ($firmware mode)." -Level "SUCCESS" -ForegroundColor Green
    }
    finally {
        if ($bootLetterAssigned) {
            try {
                $null = Remove-PartitionAccessPath -DiskNumber $targetDiskNum -PartitionNumber $sysPartNum -AccessPath "S:" -ErrorAction SilentlyContinue
            }
            catch {}
        }
    }

    # 3. Inject offline drivers if staged driver folder is present
    if (-not [string]::IsNullOrWhiteSpace($DriverFolder) -and (Test-Path -LiteralPath $DriverFolder -PathType Container)) {
        Write-ComponentLog "Injecting offline drivers via DISM (/Add-Driver)..." -Level "INIT" -ForegroundColor Cyan
        $driverArgs = "/Image:$cleanDest\ /Add-Driver /Driver:`"$DriverFolder`" /Recurse"
        Write-ComponentLog "Command Line : dism.exe $driverArgs" -Level "INFO"
        $driverProc = Start-Process -FilePath "dism.exe" -ArgumentList $driverArgs -Wait -PassThru -NoNewWindow
        if ($driverProc.ExitCode -eq 0) {
            Write-ComponentLog "Offline drivers injected successfully." -Level "SUCCESS" -ForegroundColor Green
        }
        else {
            Write-ComponentLog "Warning: DISM /Add-Driver completed with exit code $($driverProc.ExitCode)." -Level "WARNING" -ForegroundColor Yellow
        }
    }

    # 4. Stage unattended answer file for first boot (OOBE / Specialize) if present
    if (-not [string]::IsNullOrWhiteSpace($EffectiveUnattendPath) -and (Test-Path -LiteralPath $EffectiveUnattendPath -PathType Leaf)) {
        $pantherDir = Join-Path $windowsDir "Panther"
        if (-not (Test-Path -LiteralPath $pantherDir -PathType Container)) {
            $null = New-Item -Path $pantherDir -ItemType Directory -Force -ErrorAction SilentlyContinue
        }
        $targetUnattend = Join-Path $pantherDir "unattend.xml"
        Write-ComponentLog "Staging unattended answer file to '$targetUnattend'..." -Level "INFO"
        Copy-Item -LiteralPath $EffectiveUnattendPath -Destination $targetUnattend -Force -ErrorAction SilentlyContinue
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $stopwatch.Stop()
    $durationSec = [int]$stopwatch.Elapsed.TotalSeconds

    # 5. Validate offline Windows installation artifacts
    $hasArtifacts = (Test-Path -LiteralPath $windowsDir)
    if (-not $hasArtifacts) {
        Write-ComponentLog "Warning: '$windowsDir' was not found on target destination '$NormalizedDestination'." -Level "WARNING" -ForegroundColor Yellow
    }
    else {
        Write-ComponentLog "Verified offline Windows installation artifacts on target destination '$NormalizedDestination'." -Level "SUCCESS" -ForegroundColor Green
    }

    Write-ComponentLog "OSInstallation (dism.exe) finished successfully in $durationSec seconds." -Level "SUCCESS" -ForegroundColor Green
    Write-ComponentLog "================================================================" -Level "SUCCESS" -ForegroundColor Green

    return [PSCustomObject]@{
        Success         = $true
        Engine          = "dism.exe"
        SetupPath       = $null
        ImagePath       = $ResolvedImagePath
        ImageIndex      = $displayIndex
        UnattendPath    = $EffectiveUnattendPath
        Destination     = $NormalizedDestination
        ExitCode        = $exitCode
        DurationSeconds = $durationSec
        CompletedTime   = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    }
}

# ==============================================================================
# REGION 6: v2 API HELPERS & VALIDATION
# ==============================================================================

function Get-LiteDeployImage {
    <#
    .SYNOPSIS
        Resolves setup.exe from -SetupPath / -ImagePath (share drive, UNC, or cwd). Read-only.
    #>
    [CmdletBinding()]
    param(
        [string]$SetupPath = "",
        [string]$ImagePath = "",
        [psobject]$BootCtx = $null
    )

    return Resolve-SetupExecutable -ExplicitSetupPath $SetupPath -AlternativeImagePath $ImagePath -BootCtx $BootCtx
}

function Get-LiteDeployImageInfo {
    <#
    .SYNOPSIS
        Lists editions/indexes in a WIM/ESD (Get-WindowsImage, else dism /Get-WimInfo). Read-only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,
        [psobject]$BootCtx = $null
    )

    $file = Resolve-LiteDeployImageFile -ImagePath $ImagePath -BootCtx $BootCtx
    if (-not $file) { throw "Image file (install.wim/esd/swm) could not be resolved from '$ImagePath'." }

    if (Get-Command Get-WindowsImage -ErrorAction SilentlyContinue) {
        return @(Get-WindowsImage -ImagePath $file -ErrorAction Stop | ForEach-Object {
            [PSCustomObject]@{
                Index       = [int]$_.ImageIndex
                Name        = [string]$_.ImageName
                Description = [string]$_.ImageDescription
                SizeGB      = if ($_.ImageSize) { [math]::Round([double]$_.ImageSize / 1GB, 2) } else { $null }
                ImageFile   = $file
            }
        })
    }

    $dism = Join-Path $env:SystemRoot "System32\dism.exe"
    if (-not (Test-Path -LiteralPath $dism -PathType Leaf)) { $dism = "dism.exe" }
    $lines = @(& $dism /English /Get-WimInfo "/WimFile:$file" 2>&1 | ForEach-Object { [string]$_ })

    $items = [System.Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($line in $lines) {
        if ($line -match '^\s*Index\s*:\s*(\d+)') {
            if ($null -ne $current) { $items.Add([PSCustomObject]$current) }
            $current = [ordered]@{ Index = [int]$Matches[1]; Name = ""; Description = ""; SizeGB = $null; ImageFile = $file }
        }
        elseif ($null -ne $current -and $line -match '^\s*Name\s*:\s*(.*)$') { $current.Name = $Matches[1].Trim() }
        elseif ($null -ne $current -and $line -match '^\s*Description\s*:\s*(.*)$') { $current.Description = $Matches[1].Trim() }
        elseif ($null -ne $current -and $line -match '^\s*Size\s*:\s*([\d,\.]+)\s*bytes') {
            $current.SizeGB = [math]::Round(([double]($Matches[1] -replace ',', '')) / 1GB, 2)
        }
    }
    if ($null -ne $current) { $items.Add([PSCustomObject]$current) }
    return @($items.ToArray())
}

function Select-LiteDeployImage {
    <#
    .SYNOPSIS
        Picks the image index to install. Priority: -Index, WorkflowSelection (WorkflowTag.Index / ImageIndex / Index),
        -Name match against -ImageInfo, then 1. Read-only.
    #>
    [CmdletBinding()]
    param(
        [int]$Index = 0,
        [string]$Name = "",
        [object[]]$ImageInfo = @(),
        [psobject]$WorkflowSelection = $null
    )

    $resolved = $Index
    $source = "Parameter"

    if ($resolved -le 0 -and $WorkflowSelection) {
        $source = "WorkflowSelection"
        if ($WorkflowSelection.PSObject.Properties['WorkflowTag'] -and $WorkflowSelection.WorkflowTag -and ($WorkflowSelection.WorkflowTag -isnot [string]) -and $WorkflowSelection.WorkflowTag.PSObject.Properties['Index'] -and ($null -ne $WorkflowSelection.WorkflowTag.Index)) {
            $resolved = [int]$WorkflowSelection.WorkflowTag.Index
        }
        elseif ($WorkflowSelection.PSObject.Properties['ImageIndex'] -and ($null -ne $WorkflowSelection.ImageIndex)) {
            $resolved = [int]$WorkflowSelection.ImageIndex
        }
        elseif ($WorkflowSelection.PSObject.Properties['Index'] -and ($null -ne $WorkflowSelection.Index)) {
            $resolved = [int]$WorkflowSelection.Index
        }
    }

    if ($resolved -le 0 -and -not [string]::IsNullOrWhiteSpace($Name) -and @($ImageInfo).Count -gt 0) {
        $match = @($ImageInfo | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
        if ($match.Count -eq 0) {
            $match = @($ImageInfo | Where-Object { $_.Name -like "*$Name*" } | Select-Object -First 1)
        }
        if ($match.Count -gt 0) { $resolved = [int]$match[0].Index; $source = "Name" }
    }

    if ($resolved -le 0) { $resolved = 1; $source = "Default" }

    $selected = $null
    if (@($ImageInfo).Count -gt 0) {
        $found = @($ImageInfo | Where-Object { [int]$_.Index -eq $resolved } | Select-Object -First 1)
        if ($found.Count -gt 0) { $selected = $found[0] }
    }

    return [PSCustomObject]@{
        Index  = $resolved
        Name   = if ($selected) { $selected.Name } else { $Name }
        Source = $source
        Image  = $selected
    }
}

function New-LiteDeployUnattend {
    <#
    .SYNOPSIS
        Generates the unattend answer file from a template (writes -OutputPath; default X:\unattended.xml).
    #>
    [CmdletBinding()]
    param(
        [string]$TemplatePath = "",
        [string]$OutputPath = "X:\unattended.xml",
        [psobject]$BootConfig = $null,
        [psobject]$WorkflowSelection = $null,
        [psobject]$DiskResult = $null,
        [psobject]$BootCtx = $null
    )

    $template = Resolve-UnattendTemplate -ExplicitTemplatePath $TemplatePath -BootCtx $BootCtx -WorkflowSelection $WorkflowSelection
    if (-not $template) {
        throw "Could not resolve an unattended template (e.g. DomainJoin.xml). Pass -TemplatePath."
    }
    return New-LiteDeployUnattendXml -TemplateFile $template -TargetOutputFile $OutputPath -ConfigObj $BootConfig -WorkflowData $WorkflowSelection -DiskData $DiskResult -BootCtx $BootCtx
}

function Start-LiteDeployImage {
    <#
    .SYNOPSIS
        EXECUTES setup.exe (Invoke-SetupEngine). This is the only v2 wrapper that applies an image.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedSetupPath,
        [string]$EffectiveUnattendPath = "",
        [Parameter(Mandatory = $true)]
        [string]$NormalizedDestination,
        [string]$ResolvedImagePath = "",
        [int]$SelectedImageIndex = 1,
        [string[]]$ExtraArgs = @()
    )

    return Invoke-SetupEngine `
        -ResolvedSetupPath $ResolvedSetupPath `
        -EffectiveUnattendPath $EffectiveUnattendPath `
        -NormalizedDestination $NormalizedDestination `
        -ResolvedImagePath $ResolvedImagePath `
        -SelectedImageIndex $SelectedImageIndex `
        -ExtraArgs $ExtraArgs
}

function Test-LiteDeployImage {
    <#
    .SYNOPSIS
        Read-only validation of setup.exe, image file, and unattend template paths.
    #>
    [CmdletBinding()]
    param(
        [string]$SetupPath = "",
        [string]$ImagePath = "",
        [string]$TemplateUnattendPath = "",
        [string]$UnattendPath = "",
        [psobject]$BootCtx = $null,
        [psobject]$WorkflowSelection = $null
    )

    $setup = Resolve-SetupExecutable -ExplicitSetupPath $SetupPath -AlternativeImagePath $ImagePath -BootCtx $BootCtx
    $imageFile = Resolve-LiteDeployImageFile -ImagePath $ImagePath -SetupPath $(if ($setup) { $setup } else { "" }) -BootCtx $BootCtx

    $unattend = $null
    $unattendSource = "None"
    if (-not [string]::IsNullOrWhiteSpace($UnattendPath) -and (Test-Path -LiteralPath $UnattendPath -PathType Leaf)) {
        $unattend = (Resolve-Path -LiteralPath $UnattendPath).Path
        $unattendSource = "Existing"
    }
    else {
        try {
            $unattend = Resolve-UnattendTemplate -ExplicitTemplatePath $TemplateUnattendPath -BootCtx $BootCtx -WorkflowSelection $WorkflowSelection
            if ($unattend) { $unattendSource = "Template" }
        }
        catch {
            $unattendSource = "Error: $($_.Exception.Message)"
        }
    }

    return [PSCustomObject]@{
        Passed         = [bool]($setup -and ($unattend -or (-not $WorkflowSelection)))
        SetupPath      = $setup
        SetupFound     = [bool]$setup
        ImageFile      = $imageFile
        ImageFileFound = [bool]$imageFile
        UnattendPath   = $unattend
        UnattendSource = $unattendSource
    }
}

# ==============================================================================
# REGION 7: STANDALONE EXECUTION ENTRY POINT
# (Skipped on dot-source '.')
# ==============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    $imageConfiguration = if ($BootConfig) { $BootConfig } elseif ($BootObject -and $BootObject.PSObject.Properties['Config']) { $BootObject.Config } else { $null }
    $selectedImageEngine = Resolve-LiteDeployImageEngine -Configuration $imageConfiguration -WorkflowSelection $WorkflowSelection
    if ($ValidateEngineOnly) { return $selectedImageEngine }

    # Normalize Destination drive letter
    $normalizedDest = $Destination
    if ($normalizedDest -match '^[a-zA-Z]:$') {
        $normalizedDest = "$normalizedDest\"
    }

    # Check if workflow tag supplies SetupPath/ImagePath when omitted
    if ($WorkflowSelection -and $WorkflowSelection.PSObject.Properties['WorkflowTag'] -and
        $WorkflowSelection.WorkflowTag -and ($WorkflowSelection.WorkflowTag -isnot [string])) {
        $tag = $WorkflowSelection.WorkflowTag
        if ([string]::IsNullOrWhiteSpace($SetupPath) -and $tag.PSObject.Properties['SetupPath'] -and $tag.SetupPath) {
            $SetupPath = [string]$tag.SetupPath
        }
        if ([string]::IsNullOrWhiteSpace($ImagePath) -and $tag.PSObject.Properties['ImagePath'] -and $tag.ImagePath) {
            $ImagePath = [string]$tag.ImagePath
        }
        if ([string]::IsNullOrWhiteSpace($ImagePath) -and $tag.PSObject.Properties['MediaRoot'] -and $tag.MediaRoot) {
            $ImagePath = [string]$tag.MediaRoot
        }
        if ([string]::IsNullOrWhiteSpace($SetupPath) -and $tag.PSObject.Properties['MediaRoot'] -and $tag.MediaRoot) {
            $SetupPath = Join-Path ([string]$tag.MediaRoot) "setup.exe"
        }
    }

    # Resolve index
    $resolvedIndex = $ImageIndex
    if ($resolvedIndex -le 0 -and $WorkflowSelection) {
        $tag = $null
        if ($WorkflowSelection.PSObject.Properties['WorkflowTag'] -and $WorkflowSelection.WorkflowTag -and
            ($WorkflowSelection.WorkflowTag -isnot [string])) {
            $tag = $WorkflowSelection.WorkflowTag
        }
        if ($tag -and $tag.PSObject.Properties['Index'] -and ($null -ne $tag.Index)) {
            $resolvedIndex = [int]$tag.Index
        }
        elseif ($WorkflowSelection.PSObject.Properties['ImageIndex'] -and ($null -ne $WorkflowSelection.ImageIndex)) {
            $resolvedIndex = [int]$WorkflowSelection.ImageIndex
        }
        elseif ($WorkflowSelection.PSObject.Properties['Index'] -and ($null -ne $WorkflowSelection.Index)) {
            $resolvedIndex = [int]$WorkflowSelection.Index
        }
    }
    if ($resolvedIndex -le 0) {
        $resolvedIndex = 1
    }

    # Resolve Unattend
    $finalUnattendPath = ""
    if (-not [string]::IsNullOrWhiteSpace($UnattendPath) -and (Test-Path -LiteralPath $UnattendPath)) {
        $finalUnattendPath = (Resolve-Path -LiteralPath $UnattendPath).Path
        Write-ComponentLog "Using existing unattended answer file: $finalUnattendPath" -Level "INFO"
    }
    else {
        $resolvedTemplate = Resolve-UnattendTemplate -ExplicitTemplatePath $TemplateUnattendPath -BootCtx $BootObject -WorkflowSelection $WorkflowSelection
        if ($resolvedTemplate) {
            $finalUnattendPath = New-LiteDeployUnattendXml `
                -TemplateFile $resolvedTemplate `
                -TargetOutputFile $GeneratedUnattendPath `
                -ConfigObj $BootConfig `
                -WorkflowData $WorkflowSelection `
                -DiskData $DiskResult `
                -BootCtx $BootObject
        }
    }

    switch ($selectedImageEngine) {
        'setup.exe' {
            if (-not $ExecuteSetup) {
                Write-Host "LiteDeploy.Image - resolve/test mode (read-only). Pass -ExecuteSetup to launch setup.exe." -ForegroundColor Cyan
                $test = Test-LiteDeployImage `
                    -SetupPath $SetupPath `
                    -ImagePath $ImagePath `
                    -TemplateUnattendPath $TemplateUnattendPath `
                    -UnattendPath $UnattendPath `
                    -BootCtx $BootObject `
                    -WorkflowSelection $WorkflowSelection
                $test | Format-List | Out-Host
                return $test
            }

            $resolvedSetup = Resolve-SetupExecutable -ExplicitSetupPath $SetupPath -AlternativeImagePath $ImagePath -BootCtx $BootObject
            $resolvedImage = Resolve-LiteDeployImageFile -ImagePath $ImagePath -SetupPath $SetupPath -BootCtx $BootObject

            if (-not (Test-Path -LiteralPath $normalizedDest)) {
                throw "Target destination directory '$normalizedDest' does not exist or is not accessible."
            }

            if (-not $resolvedSetup) {
                throw "Windows Setup binary (setup.exe) could not be resolved from SetupPath: '$SetupPath' or ImagePath: '$ImagePath'."
            }

            if (Test-LiteDeploySkipSetupHardwareRequirements -Configuration $imageConfiguration -WorkflowSelection $WorkflowSelection) {
                $null = Set-LiteDeploySetupHardwareRequirementBypass
            }

            try {
                $result = Invoke-SetupEngine `
                    -ResolvedSetupPath $resolvedSetup `
                    -EffectiveUnattendPath $finalUnattendPath `
                    -NormalizedDestination $normalizedDest `
                    -ResolvedImagePath $(if ($resolvedImage) { $resolvedImage } else { "" }) `
                    -SelectedImageIndex $resolvedIndex `
                    -DriverFolder $DriverPath `
                    -ExtraArgs $AdditionalArguments

                return $result
            }
            catch {
                Write-ComponentLog "Image apply failed: $($_.Exception.Message)" -Level "ERROR" -ForegroundColor Red
                throw $_
            }
        }

        'dism.exe' {
            if (-not $ExecuteSetup) {
                Write-Host "LiteDeploy.Image - resolve/test mode (read-only). Pass -ExecuteSetup to launch dism.exe." -ForegroundColor Cyan
                $test = Test-LiteDeployImage `
                    -SetupPath $SetupPath `
                    -ImagePath $ImagePath `
                    -TemplateUnattendPath $TemplateUnattendPath `
                    -UnattendPath $UnattendPath `
                    -BootCtx $BootObject `
                    -WorkflowSelection $WorkflowSelection
                $test | Format-List | Out-Host
                return $test
            }

            $resolvedImage = Resolve-LiteDeployImageFile -ImagePath $ImagePath -SetupPath $SetupPath -BootCtx $BootObject

            if (-not (Test-Path -LiteralPath $normalizedDest)) {
                throw "Target destination directory '$normalizedDest' does not exist or is not accessible."
            }

            if (-not $resolvedImage) {
                throw "Windows Image file (install.wim/esd) could not be resolved from ImagePath: '$ImagePath' or SetupPath: '$SetupPath'."
            }

            try {
                $result = Invoke-DismEngine `
                    -ResolvedImagePath $resolvedImage `
                    -EffectiveUnattendPath $finalUnattendPath `
                    -NormalizedDestination $normalizedDest `
                    -SelectedImageIndex $resolvedIndex `
                    -DiskData $DiskResult `
                    -DriverFolder $DriverPath `
                    -ExtraArgs $AdditionalArguments

                return $result
            }
            catch {
                Write-ComponentLog "Image apply (DISM) failed: $($_.Exception.Message)" -Level "ERROR" -ForegroundColor Red
                throw $_
            }
        }
    }
}
