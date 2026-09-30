<#
.SYNOPSIS
    LiteDeploy Component Synchronization & Distribution Engine.

.DESCRIPTION
    Automates the synchronization of LiteDeploy PowerShell modules and engine components
    from the development repository structure to:
    1. Production Deployment Share layout (Engine\Scripts\Admin and Engine\Scripts\Runtime).
    2. WinPE Image Builder / Staging directory (injected ~LiteDeploy scripts, startnet.cmd, etc.).
    3. Offline Media Root (USB / ISO standalone layout).

.PARAMETER DeploymentShare
    Target root path of the deployment share (e.g. '\\Server\DeploymentShare$' or 'D:\DeploymentShare').
    Copies Admin scripts to Engine\Scripts\Admin\ and Runtime scripts to Engine\Scripts\Runtime\.

.PARAMETER WinPEStagingPath
    Target root path of the mounted WinPE image (e.g. 'C:\WinPE_Build\Mount' or 'C:\WinPE_Build\Staging').
    Copies core bootstrap runtime components (BootInitializer, LogWriter, HostShell) into the WinPE tree.

.PARAMETER WinPEInjectionPath
    Target subfolder path inside WinPE staging for LiteDeploy scripts.
    Default: '~LiteDeploy\Scripts' (also supports 'Windows\System32').

.PARAMETER MediaRoot
    Target root path of an offline USB media or standalone ISO staging directory.
    Synchronizes both Engine scripts and directory layout (Config, Content, WorkFlows).

.PARAMETER Clean
    Removes existing script files in the destination target directories before copying.

.PARAMETER Overwrite
    Overwrites existing files at destination (default: $true).

.PARAMETER Metadata
    Outputs standardized component metadata and exits immediately.

.EXAMPLE
    .\LiteDeploy.SyncComponents.ps1 -DeploymentShare "D:\DeploymentShare"

.EXAMPLE
    .\LiteDeploy.SyncComponents.ps1 -WinPEStagingPath "C:\WinPE_Build\Mount" -Clean

.EXAMPLE
    .\LiteDeploy.SyncComponents.ps1 -DeploymentShare "\\Server\DeploymentShare$" -WinPEStagingPath "C:\WinPE_Build\Mount"

.NOTES
    LiteDeploy Core Component Standard v1.0
    Target Environment: Host
    PowerShell Version: 5.1+
    Strict Mode: Version 2.0
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$DeploymentShare = "",

    [Parameter(Mandatory = $false)]
    [string]$WinPEStagingPath = "",

    [Parameter(Mandatory = $false)]
    [string]$WinPEInjectionPath = "~LiteDeploy\Scripts",

    [Parameter(Mandatory = $false)]
    [string]$MediaRoot = "",

    [Parameter(Mandatory = $false)]
    [switch]$Clean,

    [Parameter(Mandatory = $false)]
    [bool]$Overwrite = $true,

    [Parameter(Mandatory = $false)]
    [switch]$Metadata
)

# Enforce strict execution discipline
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ==============================================================================
# 1. COMPONENT METADATA & VERSION CONTROL
# ==============================================================================

function Get-LiteDeployComponentMetadata {
    <#
    .SYNOPSIS
        Returns standardized component metadata for inventory discovery and version management.
    #>
    return [PSCustomObject]@{
        ComponentId          = "SyncComponents"
        Name                 = "LiteDeploy Component Sync Engine"
        Version              = "1.0.0"
        Category             = "Admin"
        TargetEnvironment    = "Host"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("LogWriter")
        Description          = "Synchronizes repository scripts to deployment shares, WinPE boot images, and offline media layouts."
    }
}

# Fast-exit for automated inventory scanners or version queries
if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

# ==============================================================================
# 2. LOGGING INTEGRATION
# ==============================================================================

function Write-SyncLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("INFO", "SUCCESS", "INIT", "CHECK", "WARNING", "RETRY", "ERROR")]
        [string]$Level = "INFO",
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::White
    )
    if (Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue) {
        Write-LiteDeployLog -Message $Message -Level $Level -Component "SyncComponents" -ForegroundColor $ForegroundColor
    }
    else {
        $prefix = switch ($Level) {
            "SUCCESS" { "[SUCCESS]" }
            "ERROR" { "  [ERROR]" }
            "WARNING" { "[WARNING]" }
            "INIT" { "   [INIT]" }
            "CHECK" { "  [CHECK]" }
            default { "   [INFO]" }
        }
        Write-Host "$prefix $Message" -ForegroundColor $ForegroundColor
    }
}

# ==============================================================================
# 3. REPOSITORY COMPONENT INVENTORY & DISCOVERY
# ==============================================================================

function Get-RepoRootPath {
    # Resolve repository root from script root
    $candidates = @(
        (Join-Path $PSScriptRoot "..\.."),
        (Join-Path $PSScriptRoot ".."),
        $PSScriptRoot
    )
    foreach ($cand in $candidates) {
        $check = Resolve-Path -Path $cand -ErrorAction SilentlyContinue
        if ($check -and (Test-Path -LiteralPath (Join-Path $check.Path "Scripts_Engine_Components"))) {
            return $check.Path
        }
    }
    # Fallback to current directory
    return (Get-Location).Path
}

function Get-RepoComponentFiles {
    param([string]$RepoRoot)

    $componentsRoot = Join-Path $RepoRoot "Scripts_Engine_Components"
    if (-not (Test-Path -LiteralPath $componentsRoot)) {
        throw "Scripts_Engine_Components directory not found at '$componentsRoot'."
    }

    $adminFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $runtimeFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $winpeFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

    # Discover Admin Scripts
    $adminDir = Join-Path $componentsRoot "Admin"
    if (Test-Path -LiteralPath $adminDir) {
        Get-ChildItem -Path $adminDir -Recurse -File -Filter "*.ps1" | Where-Object {
            $_.Name -notlike "*.Tests.ps1" -and $_.Name -notlike "Test-*"
        } | ForEach-Object { $adminFiles.Add($_) }
    }

    # Discover Runtime Scripts
    $runtimeDir = Join-Path $componentsRoot "Runtime"
    if (Test-Path -LiteralPath $runtimeDir) {
        Get-ChildItem -Path $runtimeDir -Recurse -File -Filter "*.ps1" | Where-Object {
            $_.Name -notlike "*.Tests.ps1" -and $_.Name -notlike "Test-*"
        } | ForEach-Object { 
            $runtimeFiles.Add($_)

            # Mark components specifically required inside the WinPE boot wim image
            if ($_.Name -in @(
                    "LiteDeploy.BootInitilizer.ps1",
                    "LiteDeploy.LogWriter.ps1",
                    "LiteDeploy.HostShell.ps1",
                    "LiteDeploy.DeploymentEngine.ps1"
                )) {
                $winpeFiles.Add($_)
            }
        }
    }

    return [PSCustomObject]@{
        AdminScripts   = $adminFiles
        RuntimeScripts = $runtimeFiles
        WinPEScripts   = $winpeFiles
    }
}

# ==============================================================================
# 4. SYNCHRONIZATION WORKFLOWS
# ==============================================================================

function Sync-DeploymentShareTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SharePath,
        [Parameter(Mandatory = $true)]
        [psobject]$Components,
        [bool]$CleanTarget = $false
    )

    Write-SyncLog "------------------------------------------------------------------" -Level "INFO" -ForegroundColor Cyan
    Write-SyncLog "Syncing components to Deployment Share: '$SharePath'..." -Level "INFO" -ForegroundColor Cyan
    Write-SyncLog "------------------------------------------------------------------" -Level "INFO" -ForegroundColor Cyan

    $adminDest = Join-Path $SharePath "Engine\Scripts\Admin"
    $runtimeDest = Join-Path $SharePath "Engine\Scripts\Runtime"

    # Ensure target directories exist
    foreach ($dir in @($adminDest, $runtimeDest)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -Path $dir -ItemType Directory -Force
            Write-SyncLog "Created directory: '$dir'" -Level "INFO" -ForegroundColor DarkGray
        }
        elseif ($CleanTarget) {
            Write-SyncLog "Cleaning target directory '$dir'..." -Level "WARNING" -ForegroundColor Yellow
            Get-ChildItem -Path $dir -File -Filter "*.ps1" | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }

    $copyCount = 0

    # Copy Admin Components
    foreach ($file in $Components.AdminScripts) {
        $destFile = Join-Path $adminDest $file.Name
        Copy-Item -LiteralPath $file.FullName -Destination $destFile -Force
        Write-SyncLog " [ADMIN]   Copied $($file.Name) -> Engine\Scripts\Admin\" -Level "SUCCESS" -ForegroundColor Green
        $copyCount++
    }

    # Copy Runtime Components
    foreach ($file in $Components.RuntimeScripts) {
        $destFile = Join-Path $runtimeDest $file.Name
        Copy-Item -LiteralPath $file.FullName -Destination $destFile -Force
        Write-SyncLog " [RUNTIME] Copied $($file.Name) -> Engine\Scripts\Runtime\" -Level "SUCCESS" -ForegroundColor Green
        $copyCount++
    }

    Write-SyncLog "Deployment Share sync complete ($copyCount files copied)." -Level "SUCCESS" -ForegroundColor Green
}

function Sync-WinPEStagingTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StagingPath,
        [string]$InjectionSubfolder = "~LiteDeploy\Scripts",
        [Parameter(Mandatory = $true)]
        [psobject]$Components,
        [bool]$CleanTarget = $false
    )

    Write-SyncLog "------------------------------------------------------------------" -Level "INFO" -ForegroundColor Cyan
    Write-SyncLog "Syncing components to WinPE Staging: '$StagingPath'..." -Level "INFO" -ForegroundColor Cyan
    Write-SyncLog "------------------------------------------------------------------" -Level "INFO" -ForegroundColor Cyan

    $targetScriptsDir = Join-Path $StagingPath $InjectionSubfolder

    if (-not (Test-Path -LiteralPath $targetScriptsDir)) {
        $null = New-Item -Path $targetScriptsDir -ItemType Directory -Force
        Write-SyncLog "Created WinPE scripts directory: '$targetScriptsDir'" -Level "INFO" -ForegroundColor DarkGray
    }
    elseif ($CleanTarget) {
        Write-SyncLog "Cleaning WinPE script directory '$targetScriptsDir'..." -Level "WARNING" -ForegroundColor Yellow
        Get-ChildItem -Path $targetScriptsDir -File -Filter "*.ps1" | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $copyCount = 0

    # Inject required WinPE bootstrap components
    foreach ($file in $Components.WinPEScripts) {
        $destFile = Join-Path $targetScriptsDir $file.Name
        Copy-Item -LiteralPath $file.FullName -Destination $destFile -Force
        Write-SyncLog " [WINPE]   Injected $($file.Name) -> $InjectionSubfolder\" -Level "SUCCESS" -ForegroundColor Green
        $copyCount++
    }

    # Also copy all runtime components so standalone/offline execution works seamlessly
    foreach ($file in $Components.RuntimeScripts) {
        $destFile = Join-Path $targetScriptsDir $file.Name
        if (-not (Test-Path -LiteralPath $destFile)) {
            Copy-Item -LiteralPath $file.FullName -Destination $destFile -Force
            Write-SyncLog " [WINPE]   Injected $($file.Name) -> $InjectionSubfolder\" -Level "SUCCESS" -ForegroundColor Green
            $copyCount++
        }
    }

    Write-SyncLog "WinPE Staging sync complete ($copyCount files injected)." -Level "SUCCESS" -ForegroundColor Green
}

function Sync-MediaRootTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MediaRootPath,
        [Parameter(Mandatory = $true)]
        [psobject]$Components,
        [string]$RepoRoot,
        [bool]$CleanTarget = $false
    )

    Write-SyncLog "------------------------------------------------------------------" -Level "INFO" -ForegroundColor Cyan
    Write-SyncLog "Syncing components to Media Root: '$MediaRootPath'..." -Level "INFO" -ForegroundColor Cyan
    Write-SyncLog "------------------------------------------------------------------" -Level "INFO" -ForegroundColor Cyan

    # Sync Engine\Scripts on media
    Sync-DeploymentShareTarget -SharePath $MediaRootPath -Components $Components -CleanTarget $CleanTarget

    # Ensure Media standard folders exist (Config, Content, WorkFlows)
    $mediaDirs = @("Config", "Content\OperatingSystems", "Content\Drivers", "Content\Packages", "WorkFlows", "WorkLogs\Deployments")
    foreach ($dir in $mediaDirs) {
        $p = Join-Path $MediaRootPath $dir
        if (-not (Test-Path -LiteralPath $p)) {
            $null = New-Item -Path $p -ItemType Directory -Force
            Write-SyncLog "Created media directory: '$dir'" -Level "INFO" -ForegroundColor DarkGray
        }
    }

    Write-SyncLog "Media Root sync complete." -Level "SUCCESS" -ForegroundColor Green
}

# ==============================================================================
# 5. MAIN EXECUTION CONTROLLER
# ==============================================================================

function Start-LiteDeploySync {
    if ([string]::IsNullOrWhiteSpace($DeploymentShare) -and 
        [string]::IsNullOrWhiteSpace($WinPEStagingPath) -and 
        [string]::IsNullOrWhiteSpace($MediaRoot)) {
        
        Write-Host ""
        Write-Host "==========================================================================" -ForegroundColor Cyan
        Write-Host "             LiteDeploy Component Synchronization Engine v1.0             " -ForegroundColor White
        Write-Host "==========================================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host " Please specify at least one target parameter:" -ForegroundColor Yellow
        Write-Host "   -DeploymentShare  <Path>   : Sync to production deployment share" -ForegroundColor White
        Write-Host "   -WinPEStagingPath <Path>   : Sync to WinPE mount/staging directory" -ForegroundColor White
        Write-Host "   -MediaRoot        <Path>   : Sync to offline USB/ISO media root" -ForegroundColor White
        Write-Host ""
        Write-Host " Example:" -ForegroundColor Cyan
        Write-Host "   .\LiteDeploy.SyncComponents.ps1 -DeploymentShare `"D:\DeploymentShare`"" -ForegroundColor Gray
        Write-Host "   .\LiteDeploy.SyncComponents.ps1 -WinPEStagingPath `"C:\WinPE_Build\Mount`"" -ForegroundColor Gray
        Write-Host ""
        return
    }

    $repoRoot = Get-RepoRootPath
    Write-SyncLog "Repository Root detected at '$repoRoot'." -Level "INIT" -ForegroundColor Cyan

    $components = Get-RepoComponentFiles -RepoRoot $repoRoot
    Write-SyncLog "Discovered: $($components.AdminScripts.Count) Admin scripts, $($components.RuntimeScripts.Count) Runtime scripts." -Level "INFO" -ForegroundColor DarkCyan

    # Execute Deployment Share Sync
    if (-not [string]::IsNullOrWhiteSpace($DeploymentShare)) {
        Sync-DeploymentShareTarget -SharePath $DeploymentShare -Components $components -CleanTarget $Clean
    }

    # Execute WinPE Staging Sync
    if (-not [string]::IsNullOrWhiteSpace($WinPEStagingPath)) {
        Sync-WinPEStagingTarget -StagingPath $WinPEStagingPath -InjectionSubfolder $WinPEInjectionPath -Components $components -CleanTarget $Clean
    }

    # Execute Media Root Sync
    if (-not [string]::IsNullOrWhiteSpace($MediaRoot)) {
        Sync-MediaRootTarget -MediaRootPath $MediaRoot -Components $components -RepoRoot $repoRoot -CleanTarget $Clean
    }

    Write-Host ""
    Write-SyncLog "All synchronization tasks completed successfully." -Level "SUCCESS" -ForegroundColor Green
}

# Run synchronization
Start-LiteDeploySync
