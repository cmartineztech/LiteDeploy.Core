<#
.SYNOPSIS
    Standardized component template for LiteDeploy PowerShell modules and scripts.

.DESCRIPTION
    Provides a unified template featuring standard metadata discovery, semantic versioning,
    PowerShell 5.1 / WinPE compatibility guards, structured error handling, and LogWriter integration.

.PARAMETER Metadata
    Switch to output component metadata (Id, Name, Version, Category, Environment) as a PSCustomObject.

.EXAMPLE
    .\LiteDeploy.SampleComponent.ps1 -Metadata
    Returns the component metadata object without executing the main payload.

.NOTES
    LiteDeploy Component Standard v1.0
    PowerShell Version: 5.1+
    Strict Mode: Version 2.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Metadata,

    [Parameter(Mandatory = $false)]
    [psobject]$BootObject = $null
)

# Enforce strict execution discipline across all environments (WinPE & FullOS)
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ==============================================================================
# REGION 1: COMPONENT METADATA & VERSION CONTROL
# ==============================================================================

function Get-LiteDeployComponentMetadata {
    <#
    .SYNOPSIS
        Returns standardized component metadata for inventory discovery and version management.
    #>
    return [PSCustomObject]@{
        ComponentId          = "SampleComponent"           # Unique identifier: alphanumeric, no spaces
        Name                 = "LiteDeploy Sample"         # Friendly display name
        Version              = "1.0.0"                     # Semantic versioning (MAJOR.MINOR.PATCH)
        Category             = "Runtime"                   # "Admin" or "Runtime"
        TargetEnvironment    = "WinPE"                     # "WinPE", "FullOS", "Host", or "Universal"
        MinPowerShellVersion = "5.1"                       # Minimum supported PowerShell version
        Author               = "LiteDeploy Team"           # Maintainer / Author
        Dependencies         = @("LogWriter")              # Sibling component IDs required
        Description          = "Template blueprint for LiteDeploy standardized components."
    }
}

# Fast-exit for automated inventory scanners or version queries
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
    
    # Forward to centralized LogWriter if loaded, otherwise output cleanly to console
    if (Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue) {
        Write-LiteDeployLog -Message $Message -Level $Level -Component $meta.ComponentId -ForegroundColor $ForegroundColor
    }
    else {
        Write-Host " [$($Level.PadRight(7))] $Message" -ForegroundColor $ForegroundColor
    }
}

# ==============================================================================
# REGION 3: CORE LOGIC & BUSINESS FUNCTIONS
# ==============================================================================

function Invoke-ComponentPayload {
    param(
        [psobject]$Context
    )
    
    Write-ComponentLog "Starting component execution..." -Level "INIT" -ForegroundColor Cyan
    
    # --------------------------------------------------------------------------
    # TODO: Implement component-specific logic here
    # --------------------------------------------------------------------------
    
    Write-ComponentLog "Component execution completed successfully." -Level "SUCCESS" -ForegroundColor Green
    
    return [PSCustomObject]@{
        Success = $true
        Status  = "Completed"
        Payload = $null
    }
}

# ==============================================================================
# REGION 4: EXECUTION & STANDALONE HANDOFF
# ==============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-ComponentPayload -Context $BootObject
        return $result
    }
    catch {
        Write-ComponentLog "Execution error: $($_.Exception.Message)" -Level "ERROR" -ForegroundColor Red
        throw $_
    }
}
