<#
.SYNOPSIS
    LiteDeploy Component Synchronization & Distribution Engine.

.DESCRIPTION
    Automates the synchronization of LiteDeploy PowerShell modules and engine components
    from the development repository structure (numbered folders) to the published share layout:
      Engine\Scripts\Runtime\          flat domain LiteDeploy.*.ps1
      Engine\Scripts\Runtime\UI\       Runtime UI (.ps1 / .xaml)
      Engine\Scripts\Admin\            flat LiteDeploy.Admin.*.ps1
      Engine\Scripts\Admin\UI\         Admin UI
      Tools\                           share tools (e.g. WinPECT) from repo Tools\
    Numbered folders remain repo/dev organization only.

.PARAMETER DeploymentShare
    Target root path of the deployment share (e.g. '\\Server\DeploymentShare$' or 'D:\DeploymentShare').

.PARAMETER WinPEStagingPath
    Target root path of the mounted WinPE image (e.g. 'C:\WinPE_Build\Mount' or 'C:\WinPE_Build\Staging').
    Copies Boot, Environment, Logs, and Hardware into the WinPE bootstrap tree.

.PARAMETER WinPEInjectionPath
    Target subfolder path inside WinPE staging for LiteDeploy scripts.
    Default: '~LiteDeploy' (also supports 'Windows\System32').

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
    [string]$WinPEInjectionPath = "~LiteDeploy",

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
        ComponentId          = "Admin.Build"
        Name                 = "LiteDeploy Admin Build"
        Version              = "2.0.0"
        Category             = "Admin"
        TargetEnvironment    = "Host"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("Logs")
        Description          = "Builds/publishes deployable LiteDeploy artifacts, WinPE bootstrap staging, and share sync (formerly SyncComponents)."
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
    # Resolve repository root from Engine\Scripts\Admin\<component>
    $cursor = $PSScriptRoot
    for ($i = 0; $i -lt 8; $i++) {
        if (-not $cursor) { break }
        $check = Resolve-Path -Path $cursor -ErrorAction SilentlyContinue
        if ($check) {
            $engineScripts = Join-Path $check.Path "Engine\Scripts"
            $gitDir = Join-Path $check.Path ".git"
            if ((Test-Path -LiteralPath $engineScripts) -and (Test-Path -LiteralPath $gitDir)) {
                return $check.Path
            }
        }
        $parent = Split-Path -Parent $cursor
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
    return (Get-Location).Path
}

function Get-RepoComponentFiles {
    param([string]$RepoRoot)

    $componentsRoot = Join-Path $RepoRoot "Engine\Scripts"
    if (-not (Test-Path -LiteralPath $componentsRoot)) {
        throw "Engine\\Scripts directory not found at '$componentsRoot'."
    }

    $adminFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $adminUiFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $runtimeFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $uiFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $uiAssets = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $winpeBootstrap = [System.Collections.Generic.List[object]]::new()

    # Admin: numbered folders — domain scripts vs 090-UI
    $adminDir = Join-Path $componentsRoot "Admin"
    if (Test-Path -LiteralPath $adminDir) {
        Get-ChildItem -Path $adminDir -Recurse -File -Filter "LiteDeploy.Admin*.ps1" | Where-Object {
            $_.Name -notlike "*.Tests.ps1" -and $_.Name -notlike "Test-*" -and
            $_.FullName -match '(?i)[\\/]Admin[\\/]\d{3}-'
        } | ForEach-Object {
            if ($_.Name -match '(?i)\.Admin\.UI\.') {
                $adminUiFiles.Add($_)
            }
            else {
                $adminFiles.Add($_)
            }
        }
    }

    $runtimeDir = Join-Path $componentsRoot "Runtime"
    if (Test-Path -LiteralPath $runtimeDir) {
        Get-ChildItem -Path $runtimeDir -Recurse -File -Filter "*.ps1" | Where-Object {
            $_.Name -notlike "*.Tests.ps1" -and $_.Name -notlike "Test-*" -and
            $_.Name -notlike "*.Draft.ps1" -and
            $_.FullName -match '(?i)[\\/]Runtime[\\/]\d{3}-'
        } | ForEach-Object {
            if ($_.Name -like 'LiteDeploy.UI.*') {
                $uiFiles.Add($_)
            }
            else {
                $runtimeFiles.Add($_)
            }
        }

        Get-ChildItem -Path $runtimeDir -Recurse -File -Filter "*.xaml" | Where-Object {
            $_.FullName -match '(?i)[\\/]Runtime[\\/]\d{3}-'
        } | ForEach-Object {
            $uiAssets.Add($_)
        }

        # FullOS SetupComplete.cmd lives beside Engine (published flat into Runtime\, not Admin).
        Get-ChildItem -Path $runtimeDir -Recurse -File -Filter "SetupComplete.cmd" | Where-Object {
            $_.FullName -match '(?i)[\\/]Runtime[\\/]\d{3}-'
        } | ForEach-Object {
            $runtimeFiles.Add($_)
        }
    }

    # WinPE bootstrap payload map (structured ~LiteDeploy layout)
    $bootstrapMap = @(
        @{ Name = "LiteDeploy.Boot.ps1";         Dest = "Boot\LiteDeploy.Boot.ps1" }
        @{ Name = "LiteDeploy.Logs.ps1";         Dest = "Runtime\LiteDeploy.Logs.ps1" }
        @{ Name = "LiteDeploy.Environment.ps1";  Dest = "Runtime\LiteDeploy.Environment.ps1" }
        @{ Name = "LiteDeploy.Hardware.ps1";     Dest = "Runtime\LiteDeploy.Hardware.ps1" }
    )
    foreach ($entry in $bootstrapMap) {
        $match = @($runtimeFiles | Where-Object { $_.Name -eq $entry.Name } | Select-Object -First 1)
        if ($match.Count -gt 0 -and $match[0]) {
            $winpeBootstrap.Add([PSCustomObject]@{ File = $match[0]; DestRelative = $entry.Dest })
        }
    }

    return [PSCustomObject]@{
        AdminScripts   = $adminFiles
        AdminUiScripts = $adminUiFiles
        RuntimeScripts = $runtimeFiles
        UiScripts      = $uiFiles
        UiAssets       = $uiAssets
        RuntimeAssets  = $uiAssets
        WinPEBootstrap = $winpeBootstrap
        WinPEScripts   = @($winpeBootstrap | ForEach-Object { $_.File })
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
        [bool]$CleanTarget = $false,
        [string]$RepoRoot = ""
    )

    Write-SyncLog "------------------------------------------------------------------" -Level "INFO" -ForegroundColor Cyan
    Write-SyncLog "Syncing components to Deployment Share: '$SharePath'..." -Level "INFO" -ForegroundColor Cyan
    Write-SyncLog "------------------------------------------------------------------" -Level "INFO" -ForegroundColor Cyan

    # Published share layout (numbered folders stay in the git repo only):
    #   Engine\Scripts\Runtime\       flat domain LiteDeploy.*.ps1
    #   Engine\Scripts\Runtime\UI\    Runtime UI
    #   Engine\Scripts\Admin\         flat LiteDeploy.Admin.*.ps1
    #   Engine\Scripts\Admin\UI\      Admin UI
    $runtimeDest = Join-Path $SharePath "Engine\Scripts\Runtime"
    $runtimeUiDest = Join-Path $runtimeDest "UI"
    $adminDest = Join-Path $SharePath "Engine\Scripts\Admin"
    $adminUiDest = Join-Path $adminDest "UI"

    foreach ($dir in @($runtimeDest, $runtimeUiDest, $adminDest, $adminUiDest)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -Path $dir -ItemType Directory -Force
            Write-SyncLog "Created directory: '$dir'" -Level "INFO" -ForegroundColor DarkGray
        }
        elseif ($CleanTarget) {
            Write-SyncLog "Cleaning target directory '$dir'..." -Level "WARNING" -ForegroundColor Yellow
            Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.ps1', '.xaml', '.cmd' } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            # Remove leftover numbered/dev folders if a prior sync mirrored the tree here
            Get-ChildItem -Path $dir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne 'UI' } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $copyCount = 0

    foreach ($file in $Components.RuntimeScripts) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $runtimeDest $file.Name) -Force
        Write-SyncLog " [RUNTIME] Copied $($file.Name) -> Engine\Scripts\Runtime\" -Level "SUCCESS" -ForegroundColor Green
        $copyCount++
    }

    # Compat alias: older WinPE BootInitializer launches LiteDeploy.DeploymentEngine.ps1 -BootObject ...
    # Always publish the v2 Engine under that name (overwrite any legacy monolith copy).
    $engineDest = Join-Path $runtimeDest "LiteDeploy.Engine.ps1"
    $compatDest = Join-Path $runtimeDest "LiteDeploy.DeploymentEngine.ps1"
    if (Test-Path -LiteralPath $engineDest -PathType Leaf) {
        Copy-Item -LiteralPath $engineDest -Destination $compatDest -Force
        Write-SyncLog " [RUNTIME] Published Engine as LiteDeploy.DeploymentEngine.ps1 (BootInitializer compat)" -Level "WARNING" -ForegroundColor Yellow
        $copyCount++
    }

    $uiScripts = if ($Components.PSObject.Properties['UiScripts']) { $Components.UiScripts } else { @() }
    foreach ($file in $uiScripts) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $runtimeUiDest $file.Name) -Force
        Write-SyncLog " [UI]      Copied $($file.Name) -> Engine\Scripts\Runtime\UI\" -Level "SUCCESS" -ForegroundColor Green
        $copyCount++
    }

    $uiAssets = if ($Components.PSObject.Properties['UiAssets']) { $Components.UiAssets } else { $Components.RuntimeAssets }
    foreach ($file in $uiAssets) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $runtimeUiDest $file.Name) -Force
        Write-SyncLog " [UI]      Copied $($file.Name) -> Engine\Scripts\Runtime\UI\" -Level "SUCCESS" -ForegroundColor Green
        $copyCount++
    }

    foreach ($file in $Components.AdminScripts) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $adminDest $file.Name) -Force
        Write-SyncLog " [ADMIN]   Copied $($file.Name) -> Engine\Scripts\Admin\" -Level "SUCCESS" -ForegroundColor Green
        $copyCount++
    }

    $adminUi = if ($Components.PSObject.Properties['AdminUiScripts']) { $Components.AdminUiScripts } else { @() }
    foreach ($file in $adminUi) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $adminUiDest $file.Name) -Force
        Write-SyncLog " [ADMIN UI] Copied $($file.Name) -> Engine\Scripts\Admin\UI\" -Level "SUCCESS" -ForegroundColor Green
        $copyCount++
    }

    $toolsCopied = Sync-LiteDeployToolsToShare -SharePath $SharePath -RepoRoot $RepoRoot -CleanTarget $CleanTarget
    $copyCount += $toolsCopied

    Write-SyncLog "Deployment Share sync complete ($copyCount files copied)." -Level "SUCCESS" -ForegroundColor Green
}

function Sync-LiteDeployToolsToShare {
    <#
    .SYNOPSIS
        Publishes repo Tools\ (WinPECT, etc.) to DeploymentShare\Tools\.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SharePath,

        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [bool]$CleanTarget = $false
    )

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        Write-SyncLog "RepoRoot not set; skipping Tools sync." -Level "WARNING" -ForegroundColor Yellow
        return 0
    }

    $toolsSrc = Join-Path $RepoRoot 'Engine\Tools'
    if (-not (Test-Path -LiteralPath $toolsSrc -PathType Container)) {
        $toolsSrc = Join-Path $RepoRoot 'Tools'
    }
    if (-not (Test-Path -LiteralPath $toolsSrc -PathType Container)) {
        Write-SyncLog "No repo Engine\Tools\ folder at '$toolsSrc'; skipping Tools sync." -Level "WARNING" -ForegroundColor Yellow
        return 0
    }

    $toolsDst = Join-Path (Join-Path $SharePath 'Engine') 'Tools'
    if (-not (Test-Path -LiteralPath $toolsDst -PathType Container)) {
        $null = New-Item -Path $toolsDst -ItemType Directory -Force
        Write-SyncLog "Created directory: 'Engine\Tools'" -Level "INFO" -ForegroundColor DarkGray
    }

    Write-SyncLog "Syncing Tools from '$toolsSrc' -> '$toolsDst'..." -Level "INFO" -ForegroundColor Cyan
    $copyCount = 0

    # Tools\README.md
    $readmeSrc = Join-Path $toolsSrc 'README.md'
    if (Test-Path -LiteralPath $readmeSrc -PathType Leaf) {
        Copy-Item -LiteralPath $readmeSrc -Destination (Join-Path $toolsDst 'README.md') -Force
        Write-SyncLog " [TOOLS]   Copied README.md -> Engine\Tools\" -Level "SUCCESS" -ForegroundColor Green
        $copyCount++
    }

    # Each tool folder (WinPECT, DeployVault, …)
    foreach ($toolDir in @(Get-ChildItem -LiteralPath $toolsSrc -Directory -ErrorAction SilentlyContinue)) {
        $destTool = Join-Path $toolsDst $toolDir.Name
        if ($CleanTarget -and (Test-Path -LiteralPath $destTool -PathType Container)) {
            Write-SyncLog "Cleaning Engine\Tools\$($toolDir.Name)..." -Level "WARNING" -ForegroundColor Yellow
            Remove-Item -LiteralPath $destTool -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path -LiteralPath $destTool -PathType Container)) {
            $null = New-Item -Path $destTool -ItemType Directory -Force
        }

        foreach ($file in @(Get-ChildItem -LiteralPath $toolDir.FullName -Recurse -File -ErrorAction SilentlyContinue)) {
            $rel = $file.FullName.Substring($toolDir.FullName.Length).TrimStart('\', '/')
            $destFile = Join-Path $destTool $rel
            $destParent = Split-Path -Parent $destFile
            if (-not (Test-Path -LiteralPath $destParent -PathType Container)) {
                $null = New-Item -Path $destParent -ItemType Directory -Force
            }
            Copy-Item -LiteralPath $file.FullName -Destination $destFile -Force
            Write-SyncLog " [TOOLS]   Copied $($toolDir.Name)\$rel -> Engine\Tools\$($toolDir.Name)\" -Level "SUCCESS" -ForegroundColor Green
            $copyCount++
        }
    }

    if ($copyCount -lt 1) {
        Write-SyncLog "Engine\Tools\ present but no files copied." -Level "WARNING" -ForegroundColor Yellow
    }

    return $copyCount
}

function Sync-WinPEStagingTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StagingPath,
        [string]$InjectionSubfolder = "~LiteDeploy",
        [Parameter(Mandatory = $true)]
        [psobject]$Components,
        [bool]$CleanTarget = $false
    )

    Write-SyncLog "------------------------------------------------------------------" -Level "INFO" -ForegroundColor Cyan
    Write-SyncLog "Syncing components to WinPE Staging: '$StagingPath'..." -Level "INFO" -ForegroundColor Cyan
    Write-SyncLog "------------------------------------------------------------------" -Level "INFO" -ForegroundColor Cyan

    $targetRoot = Join-Path $StagingPath $InjectionSubfolder

    if (-not (Test-Path -LiteralPath $targetRoot)) {
        $null = New-Item -Path $targetRoot -ItemType Directory -Force
        Write-SyncLog "Created WinPE bootstrap root: '$targetRoot'" -Level "INFO" -ForegroundColor DarkGray
    }
    elseif ($CleanTarget) {
        Write-SyncLog "Cleaning WinPE bootstrap root '$targetRoot'..." -Level "WARNING" -ForegroundColor Yellow
        Get-ChildItem -Path $targetRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.ps1', '.xaml', '.json' } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    foreach ($sub in @("Boot", "Runtime", "UI", "Config")) {
        $p = Join-Path $targetRoot $sub
        if (-not (Test-Path -LiteralPath $p)) {
            $null = New-Item -Path $p -ItemType Directory -Force
        }
    }

    $copyCount = 0

    # Structured bootstrap: Boot + Logs/Environment/Hardware only (single source of truth copies)
    if ($Components.PSObject.Properties['WinPEBootstrap']) {
        foreach ($entry in $Components.WinPEBootstrap) {
            $destFile = Join-Path $targetRoot $entry.DestRelative
            $destDir = Split-Path -Parent $destFile
            if (-not (Test-Path -LiteralPath $destDir)) {
                $null = New-Item -Path $destDir -ItemType Directory -Force
            }
            Copy-Item -LiteralPath $entry.File.FullName -Destination $destFile -Force
            Write-SyncLog " [WINPE]   Injected $($entry.File.Name) -> $InjectionSubfolder\$($entry.DestRelative)" -Level "SUCCESS" -ForegroundColor Green
            $copyCount++
        }
    }

    Write-SyncLog "WinPE Staging sync complete ($copyCount bootstrap files injected)." -Level "SUCCESS" -ForegroundColor Green
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

    # Sync Engine publish layouts on media (flat + Scripts\Runtime tree)
    Sync-DeploymentShareTarget -SharePath $MediaRootPath -Components $Components -CleanTarget $CleanTarget -RepoRoot $RepoRoot

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
    Write-SyncLog "Discovered: $($components.AdminScripts.Count) Admin scripts, $($components.RuntimeScripts.Count) Runtime scripts, $($components.RuntimeAssets.Count) Runtime assets." -Level "INFO" -ForegroundColor DarkCyan

    # Execute Deployment Share Sync
    if (-not [string]::IsNullOrWhiteSpace($DeploymentShare)) {
        Sync-DeploymentShareTarget -SharePath $DeploymentShare -Components $components -CleanTarget $Clean -RepoRoot $repoRoot
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

