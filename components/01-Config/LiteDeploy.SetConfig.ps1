<#
.SYNOPSIS
    Generates LiteDeploy.json configuration for BootWim, DeploymentShare, or Media modes.

.DESCRIPTION
    Generates a target LiteDeploy.json configuration file managed via PowerShell
    objects and configurable variables with inline comments.

    Supported Modes:
    - BootWim         : Type = "Network", NetworkPath = Mandatory UNC path (e.g. "\\Server\Share$")
    - DeploymentShare : Type = "Network", NetworkPath = Mandatory UNC path (e.g. "\\Server\Share$")
    - Media           : Type = "Media",   NetworkPath = null

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
    Default: 'LiteDeploy.json' in current working directory.

.EXAMPLE
    .\LiteDeploy-Config.ps1 -Mode DeploymentShare -NetworkPath "\\Server01\Share$" -Environment "Production"

.EXAMPLE
    .\LiteDeploy-Config.ps1 -Mode Media -Comment "Custom offline USB config"

.EXAMPLE
    .\LiteDeploy-Config.ps1 -Mode BootWim -NetworkPath "\\PXEServer\DeploymentShare$" -Environment "Production" -Comment "PXE WIM Boot Configuration"
#>

[CmdletBinding()]
param(
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
$SkipPreCheck                = $false                  # Set $true to bypass hardware pre-checks
$WorkingRootName             = "~LiteDeploy"           # Default Working Root Directory Name
$PromptForComputerName        = $true                  # Prompt operator for computer name during deployment
$PromptForComputerDescription = $true                  # Prompt operator for computer description during deployment

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
        'WorkingRootName' = $WorkingRootName        # Working root folder name (~LiteDeploy)
        'ComputerSetup'   = [ordered]@{
            'PromptForComputerName'        = $PromptForComputerName
            'PromptForComputerDescription' = $PromptForComputerDescription
        }
    }

    # Offline USB / ISO Media Configuration
    'Media'           = [ordered]@{
        'Type'            = "Media"                 # Standalone Media deployment mode
        'NetworkPath'     = $null                   # Network path is null for offline media deployments
        'WorkingRootName' = $WorkingRootName        # Working root folder name (~LiteDeploy)
        'ComputerSetup'   = [ordered]@{
            'PromptForComputerName'        = $PromptForComputerName
            'PromptForComputerDescription' = $PromptForComputerDescription
        }
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

# Construct full LiteDeploy PSObject
$ConfigObject = [ordered]@{
    '$schemaVersion' = $SchemaVersion    # Version tag for LiteDeploy engine
    'Metadata'       = [ordered]@{
        'Name'        = $AppName               # Name of the deployment package
        'Environment' = $EffectiveEnvironment  # Environment target (null unless specified via -Environment)
        'Version'     = $AppVersion            # Package version (default 1.0)
    }
    'Startup'        = [ordered]@{
        'SkipPreCheck' = $SkipPreCheck   # Hardware pre-check toggle
    }
    'Deployment'     = $TargetDeployment
    '_Comments'      = $Comment          # Blank by default unless -Comment parameter is passed
}

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
if ($ConfigObject.Deployment.Contains('WorkingRootName')) {
    Write-Host " WorkingRootName  : $($ConfigObject.Deployment.WorkingRootName)"
    Write-Host " PromptCompName   : $($ConfigObject.Deployment.ComputerSetup.PromptForComputerName)"
    Write-Host " PromptCompDesc   : $($ConfigObject.Deployment.ComputerSetup.PromptForComputerDescription)"
}
Write-Host " Comment          : $(if ([string]::IsNullOrWhiteSpace($ConfigObject._Comments)) { '(blank)' } else { $ConfigObject._Comments })"
Write-Host " Output File      : $ResolvedOutputPath"
Write-Host "==================================================" -ForegroundColor Cyan

return $ResolvedOutputPath
