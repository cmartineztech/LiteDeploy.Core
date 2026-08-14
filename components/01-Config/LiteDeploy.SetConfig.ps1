<#
.SYNOPSIS
    Generates LiteDeploy configurations (BootConfig, etc.) for BootWim, DeploymentShare, or Media modes.

.DESCRIPTION
    Generates a target BootConfig.json configuration file managed via PowerShell
    objects and configurable variables with inline comments.

    Supported Modes:
    - BootWim         : Type = "Network", NetworkPath = Mandatory UNC path (e.g. "\\Server\Share$")
    - DeploymentShare : Type = "Network", NetworkPath = Mandatory UNC path (e.g. "\\Server\Share$")
    - Media           : Type = "Media",   NetworkPath = null

.PARAMETER BootConfig
    Switch specifying that BootConfig.json configuration is being generated.
    Allows extending LiteDeploy.SetConfig.ps1 with additional configuration target switches in the future.

.PARAMETER Mode
    Deployment mode to generate configuration for.
    Allowed values: 'BootWim', 'DeploymentShare', 'Media'.
    Default: 'DeploymentShare'

.PARAMETER NetworkPath
    UNC Network Share Path. Mandatory when Mode is 'BootWim' or 'DeploymentShare'.

.PARAMETER Environment
    Optional environment name (e.g. 'Production', 'Staging', 'Dev'). Defaults to null if omitted.

.PARAMETER Comment
    Optional comment note to include in the output JSON. If not specified, _Comments will be blank ("").

.PARAMETER OutputPath
    Target file path for the generated configuration file.
    Default: 'BootConfig.json' in current working directory.

.EXAMPLE
    .\LiteDeploy.SetConfig.ps1 -BootConfig -Mode DeploymentShare -NetworkPath "\\Server01\Share$" -Environment "Production"

.EXAMPLE
    .\LiteDeploy.SetConfig.ps1 -BootConfig -Mode Media -Comment "Custom offline USB config"

.EXAMPLE
    .\LiteDeploy.SetConfig.ps1 -BootConfig -Mode BootWim -NetworkPath "\\PXEServer\DeploymentShare$" -Environment "Production" -Comment "PXE WIM Boot Configuration"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$BootConfig,

    [Parameter(Mandatory = $false, Position = 0)]
    [ValidateSet('BootWim', 'DeploymentShare', 'Media')]
    [string]$Mode = 'DeploymentShare',

    [Parameter(Mandatory = $false)]
    [string]$NetworkPath = "",

    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [string]$Environment = $null,

    [Parameter(Mandatory = $false)]
    [string]$Comment = "",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ==============================================================================
# CONFIGURATION VARIABLES & PRESETS (Manageable PS Objects with Comments)
# ==============================================================================

# Global Settings (Change variables here as needed)
$SchemaVersion               = "1.0"                   # LiteDeploy Schema Version
$AppName                     = "LiteDeploy"            # Target Application Name
$AppVersion                  = "1.0"                   # Default Package Version
$SkipHardwarePreCheck        = $false                  # Set $true to bypass hardware pre-checks
$SkipHardwareRequirments     = $false                  # Set $true to bypass hardware requirements check
$LocalRootName               = "~LiteDeploy"           # Default Local Root Directory Name
$PromptForComputerName        = $true                  # Prompt operator for computer name during deployment
$ComputerNamePrefix           = $null                  # Optional computer name prefix (e.g. "DESK-", or null if none)
$MaxComputerNameLength        = 15                     # Maximum allowed computer name character length (NetBIOS max 15)
$PromptForComputerDescription = $true                  # Prompt operator for computer description during deployment
$Language                     = "en-US"                # Default system language locale
$KeyboardLocale               = "0409:00000409"        # Default keyboard layout / input locale (US English)
$TimeZone                     = "Eastern Standard Time"# Default system time zone
$AutoDetectDrivers            = $true                  # Auto-detect driver pack by WMI Make/Model
$AllowManualSelection         = $true                  # Allow technician to manually select driver pack
$AutoOnlineDownloadOnMedia    = $true                  # Enable on-the-fly driver downloading when on Media


# Determine effective Environment value ($null if omitted, or passed string)
$EffectiveEnvironment = if ($PSBoundParameters.ContainsKey('Environment')) {
    $Environment
} else {
    $null
}

# Enforce mandatory NetworkPath validation for BootWim and DeploymentShare modes
if ($Mode -in 'BootWim', 'DeploymentShare') {
    if ([string]::IsNullOrWhiteSpace($NetworkPath)) {
        throw "NetworkPath parameter is MANDATORY when Mode is '$Mode'. Example: .\LiteDeploy-Config.ps1 -Mode $Mode -NetworkPath '\\Server01\DeploymentShare$'"
    }
}

# Determine effective NetworkPath value based on mode & input parameters
$EffectiveNetworkPath = switch ($Mode) {
    'BootWim'         { $NetworkPath }
    'DeploymentShare' { $NetworkPath }
    'Media'           { $null }
}

# Define mode-specific deployment settings as PowerShell Objects
$ModeConfigs = @{
    # Boot.wim / PXE Boot Configuration (Minimal deployment properties)
    'BootWim'         = [ordered]@{
        'Type'        = "Network"               # Network deployment mode for Boot.wim
        'NetworkPath' = $EffectiveNetworkPath   # Mandatory UNC Share path supplied via -NetworkPath
    }

    # Network Deployment Share Configuration (Full interactive deployment properties)
    'DeploymentShare' = [ordered]@{
        'Type'            = "Network"               # Network deployment mode for Deployment Share
        'NetworkPath'     = $EffectiveNetworkPath   # Mandatory UNC Share path supplied via -NetworkPath
        'LocalRootName'   = $LocalRootName          # Local root folder name (~LiteDeploy)
    }

    # Offline USB / ISO Media Configuration
    'Media'           = [ordered]@{
        'Type'            = "Media"                 # Standalone Media deployment mode
        'NetworkPath'     = $null                   # Network path is null for offline media deployments
        'LocalRootName'   = $LocalRootName          # Local root folder name (~LiteDeploy)
    }
}

# Validate selected mode
if (-not $ModeConfigs.ContainsKey($Mode)) {
    throw "Invalid deployment mode specified: '$Mode'. Supported modes: BootWim, DeploymentShare, Media."
}

# Default OutputPath to 'BootConfig.json' if omitted
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = "BootConfig.json"
}

# Resolve destination path relative to current PowerShell working directory ($PWD)
$ResolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$TargetFolder       = Split-Path -Path $ResolvedOutputPath -Parent

if ($TargetFolder -and (-not (Test-Path -LiteralPath $TargetFolder -PathType Container))) {
    New-Item -Path $TargetFolder -ItemType Directory -Force | Out-Null
}

# Extract mode configuration
$TargetDeployment = $ModeConfigs[$Mode]

# Construct full LiteDeploy PSObject based on deployment mode
$ConfigObject = [ordered]@{
    '$schemaVersion' = $SchemaVersion    # Version tag for LiteDeploy engine
    'Metadata'       = [ordered]@{
        'Name'        = $AppName               # Name of the deployment package
        'Environment' = $EffectiveEnvironment  # Environment target (null unless specified via -Environment)
        'Version'     = $AppVersion            # Package version (default 1.0)
    }
    'Deployment'     = $TargetDeployment
}

# Include Startup, ComputerSetup, and Drivers sections for DeploymentShare and Media modes
if ($Mode -ne 'BootWim') {
    $ConfigObject['Startup'] = [ordered]@{
        'SkipHardwarePreCheck'    = $SkipHardwarePreCheck     # Hardware pre-check toggle
        'SkipHardwareRequirments' = $SkipHardwareRequirments  # Hardware requirements toggle
    }
    $ConfigObject['ComputerSetup'] = [ordered]@{
        'PromptForComputerName'        = $PromptForComputerName
        'ComputerNamePrefix'           = $ComputerNamePrefix
        'MaxComputerNameLength'        = $MaxComputerNameLength
        'PromptForComputerDescription' = $PromptForComputerDescription
        'Language'                     = $Language
        'KeyboardLocale'               = $KeyboardLocale
        'TimeZone'                     = $TimeZone
    }
    $ConfigObject['Drivers'] = [ordered]@{
        'AutoDetectDrivers'         = $AutoDetectDrivers
        'AllowManualSelection'      = $AllowManualSelection
        'AutoOnlineDownloadOnMedia' = $AutoOnlineDownloadOnMedia
    }
}

# Always attach _Comments tag at the end
$ConfigObject['_Comments'] = $Comment # Blank by default unless -Comment parameter is passed

# Convert PowerShell Object to formatted JSON
$JsonContent = $ConfigObject | ConvertTo-Json -Depth 10

# Save generated JSON to output path
Set-Content -LiteralPath $ResolvedOutputPath -Value $JsonContent -Encoding UTF8 -Force

# Display generation status
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " LiteDeploy Configuration Generated Successfully" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " Mode             : $Mode"
Write-Host " Environment      : $(if ($null -eq $ConfigObject.Metadata.Environment) { 'null' } else { $ConfigObject.Metadata.Environment })"
Write-Host " Version          : $($ConfigObject.Metadata.Version)"
Write-Host " Type             : $($ConfigObject.Deployment.Type)"
Write-Host " NetworkPath      : $(if ($null -eq $ConfigObject.Deployment.NetworkPath) { 'null' } elseif ([string]::IsNullOrWhiteSpace($ConfigObject.Deployment.NetworkPath)) { '(blank)' } else { $ConfigObject.Deployment.NetworkPath })"
if ($ConfigObject.Deployment.Contains('LocalRootName')) {
    Write-Host " LocalRootName    : $($ConfigObject.Deployment.LocalRootName)"
}
if ($ConfigObject.Contains('Startup')) {
    Write-Host " SkipHwPreCheck   : $($ConfigObject.Startup.SkipHardwarePreCheck)"
    Write-Host " SkipHwReqs       : $($ConfigObject.Startup.SkipHardwareRequirments)"
}
if ($ConfigObject.Contains('ComputerSetup')) {
    Write-Host " PromptCompName   : $($ConfigObject.ComputerSetup.PromptForComputerName)"
    Write-Host " CompNamePrefix   : $(if ($null -eq $ConfigObject.ComputerSetup.ComputerNamePrefix) { 'null' } else { $ConfigObject.ComputerSetup.ComputerNamePrefix })"
    Write-Host " MaxCompNameLen   : $($ConfigObject.ComputerSetup.MaxComputerNameLength)"
    Write-Host " PromptCompDesc   : $($ConfigObject.ComputerSetup.PromptForComputerDescription)"
    Write-Host " Language         : $($ConfigObject.ComputerSetup.Language)"
    Write-Host " KeyboardLocale   : $($ConfigObject.ComputerSetup.KeyboardLocale)"
    Write-Host " TimeZone         : $($ConfigObject.ComputerSetup.TimeZone)"
}
if ($ConfigObject.Contains('Drivers')) {
    Write-Host " AutoDetectDrivers: $($ConfigObject.Drivers.AutoDetectDrivers)"
    Write-Host " AllowManualSel   : $($ConfigObject.Drivers.AllowManualSelection)"
    Write-Host " AutoOnlineOnMedia: $($ConfigObject.Drivers.AutoOnlineDownloadOnMedia)"
}
Write-Host " Comment          : $(if ([string]::IsNullOrWhiteSpace($ConfigObject._Comments)) { '(blank)' } else { $ConfigObject._Comments })"
Write-Host " Output File      : $ResolvedOutputPath"
Write-Host "==================================================" -ForegroundColor Cyan

return $ResolvedOutputPath
