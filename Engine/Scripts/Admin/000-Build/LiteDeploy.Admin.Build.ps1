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

function Assert-LiteDeploySafeCleanTarget {
    <#
    .SYNOPSIS
        Validates that a target directory is safe for -Clean removal (not a drive root, shallow path, or reparse point).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        throw "Refusing to clean an empty target path."
    }

    $trimmed = $TargetPath.Trim().TrimEnd('\', '/')
    if ($trimmed -match '^[A-Za-z]:$') {
        throw "Safety gate blocked -Clean on drive root '$TargetPath'."
    }

    $segments = @($trimmed -split '[\\/]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($segments.Count -lt 2) {
        throw "Safety gate blocked -Clean on shallow path '$TargetPath' (minimum 2 path segments required)."
    }

    if (Test-Path -LiteralPath $TargetPath) {
        $item = Get-Item -LiteralPath $TargetPath -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Safety gate blocked -Clean on reparse point / junction '$TargetPath'."
        }
    }

    return $true
}

function New-LiteDeployReleaseManifest {
    <#
    .SYNOPSIS
        Generates ReleaseManifest.json containing SHA-256 digests for published Runtime scripts and UI assets.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RuntimeDirectory
    )

    $manifestPath = Join-Path $RuntimeDirectory "ReleaseManifest.json"
    if (-not $PSCmdlet.ShouldProcess($manifestPath, "Write ReleaseManifest.json SHA-256 integrity manifest")) {
        Write-SyncLog " [DRY-RUN] Would generate integrity manifest: Engine\Scripts\Runtime\ReleaseManifest.json" -Level "INFO" -ForegroundColor DarkGray
        return $null
    }

    if (-not (Test-Path -LiteralPath $RuntimeDirectory -PathType Container)) {
        return $null
    }

    $entries = New-Object System.Collections.Generic.List[object]
    $files = @(Get-ChildItem -LiteralPath $RuntimeDirectory -Recurse -File -ErrorAction Stop |
        Where-Object { $_.Name -ne 'ReleaseManifest.json' -and $_.Extension -in @('.ps1', '.xaml', '.json') } |
        Sort-Object FullName)

    foreach ($file in $files) {
        $rel = $file.FullName.Substring($RuntimeDirectory.Length).TrimStart('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
        $entries.Add([PSCustomObject]@{
            RelativePath = $rel
            SHA256       = $hash
            Length       = [int64]$file.Length
        })
    }

    $manifestObj = [PSCustomObject]@{
        SchemaVersion    = "1.0"
        GeneratedTimeUtc = [DateTime]::UtcNow.ToString("o")
        Files            = @($entries.ToArray())
    }

    $json = $manifestObj | ConvertTo-Json -Depth 5
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($manifestPath, $json, $utf8NoBom)
    Write-SyncLog " [MANIFEST] Generated Engine\Scripts\Runtime\ReleaseManifest.json ($($entries.Count) files hashed)" -Level "SUCCESS" -ForegroundColor Green
    return $manifestPath
}

function Sync-DeploymentShareTarget {
    [CmdletBinding(SupportsShouldProcess = $true)]
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

    if ($CleanTarget) {
        [void](Assert-LiteDeploySafeCleanTarget -TargetPath $SharePath)
    }

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
            if ($PSCmdlet.ShouldProcess($dir, "Create directory")) {
                $null = New-Item -Path $dir -ItemType Directory -Force
                Write-SyncLog "Created directory: '$dir'" -Level "INFO" -ForegroundColor DarkGray
            }
            else {
                Write-SyncLog " [DRY-RUN] Would create directory: '$dir'" -Level "INFO" -ForegroundColor DarkGray
            }
        }
        elseif ($CleanTarget) {
            [void](Assert-LiteDeploySafeCleanTarget -TargetPath $dir)
            if ($PSCmdlet.ShouldProcess($dir, "Clean target directory")) {
                Write-SyncLog "Cleaning target directory '$dir'..." -Level "WARNING" -ForegroundColor Yellow
                Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                    Where-Object {
                        (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -and
                        ($_.Extension -in '.ps1', '.xaml', '.cmd', '.json')
                    } |
                    Remove-Item -Force -ErrorAction SilentlyContinue
                # Remove leftover numbered/dev folders if a prior sync mirrored the tree here (skipping reparse points)
                Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.Name -ne 'UI' -and
                        (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)
                    } |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
            else {
                Write-SyncLog " [DRY-RUN] Would clean target directory '$dir'" -Level "INFO" -ForegroundColor DarkGray
            }
        }
    }

    $copyCount = 0

    foreach ($file in $Components.RuntimeScripts) {
        $destFile = Join-Path $runtimeDest $file.Name
        if ($PSCmdlet.ShouldProcess($destFile, "Copy runtime script $($file.Name)")) {
            Copy-Item -LiteralPath $file.FullName -Destination $destFile -Force
            Write-SyncLog " [RUNTIME] Copied $($file.Name) -> Engine\Scripts\Runtime\" -Level "SUCCESS" -ForegroundColor Green
            $copyCount++
        }
        else {
            Write-SyncLog " [DRY-RUN] Would copy $($file.Name) -> Engine\Scripts\Runtime\" -Level "INFO" -ForegroundColor DarkGray
        }
    }

    # Compat alias: older WinPE BootInitializer launches LiteDeploy.DeploymentEngine.ps1 -BootObject ...
    # Always source directly from the authoritative LiteDeploy.Engine.ps1 component file.
    $engineSource = @($Components.RuntimeScripts | Where-Object { $_.Name -ieq 'LiteDeploy.Engine.ps1' } | Select-Object -First 1)
    $compatDest = Join-Path $runtimeDest "LiteDeploy.DeploymentEngine.ps1"
    if ($engineSource.Count -gt 0 -and (Test-Path -LiteralPath $engineSource[0].FullName -PathType Leaf)) {
        if ($PSCmdlet.ShouldProcess($compatDest, "Publish LiteDeploy.Engine.ps1 as LiteDeploy.DeploymentEngine.ps1")) {
            Copy-Item -LiteralPath $engineSource[0].FullName -Destination $compatDest -Force
            Write-SyncLog " [RUNTIME] Published Engine as LiteDeploy.DeploymentEngine.ps1 (BootInitializer compat)" -Level "WARNING" -ForegroundColor Yellow
            $copyCount++
        }
        else {
            Write-SyncLog " [DRY-RUN] Would publish Engine as LiteDeploy.DeploymentEngine.ps1" -Level "INFO" -ForegroundColor DarkGray
        }
    }

    $uiScripts = if ($Components.PSObject.Properties['UiScripts']) { $Components.UiScripts } else { @() }
    foreach ($file in $uiScripts) {
        $destFile = Join-Path $runtimeUiDest $file.Name
        if ($PSCmdlet.ShouldProcess($destFile, "Copy UI script $($file.Name)")) {
            Copy-Item -LiteralPath $file.FullName -Destination $destFile -Force
            Write-SyncLog " [UI]      Copied $($file.Name) -> Engine\Scripts\Runtime\UI\" -Level "SUCCESS" -ForegroundColor Green
            $copyCount++
        }
        else {
            Write-SyncLog " [DRY-RUN] Would copy $($file.Name) -> Engine\Scripts\Runtime\UI\" -Level "INFO" -ForegroundColor DarkGray
        }
    }

    $uiAssets = if ($Components.PSObject.Properties['UiAssets']) { $Components.UiAssets } else { $Components.RuntimeAssets }
    foreach ($file in $uiAssets) {
        $destFile = Join-Path $runtimeUiDest $file.Name
        if ($PSCmdlet.ShouldProcess($destFile, "Copy UI asset $($file.Name)")) {
            Copy-Item -LiteralPath $file.FullName -Destination $destFile -Force
            Write-SyncLog " [UI]      Copied $($file.Name) -> Engine\Scripts\Runtime\UI\" -Level "SUCCESS" -ForegroundColor Green
            $copyCount++
        }
        else {
            Write-SyncLog " [DRY-RUN] Would copy $($file.Name) -> Engine\Scripts\Runtime\UI\" -Level "INFO" -ForegroundColor DarkGray
        }
    }

    foreach ($file in $Components.AdminScripts) {
        $destFile = Join-Path $adminDest $file.Name
        if ($PSCmdlet.ShouldProcess($destFile, "Copy Admin script $($file.Name)")) {
            Copy-Item -LiteralPath $file.FullName -Destination $destFile -Force
            Write-SyncLog " [ADMIN]   Copied $($file.Name) -> Engine\Scripts\Admin\" -Level "SUCCESS" -ForegroundColor Green
            $copyCount++
        }
        else {
            Write-SyncLog " [DRY-RUN] Would copy $($file.Name) -> Engine\Scripts\Admin\" -Level "INFO" -ForegroundColor DarkGray
        }
    }

    $adminUi = if ($Components.PSObject.Properties['AdminUiScripts']) { $Components.AdminUiScripts } else { @() }
    foreach ($file in $adminUi) {
        $destFile = Join-Path $adminUiDest $file.Name
        if ($PSCmdlet.ShouldProcess($destFile, "Copy Admin UI asset $($file.Name)")) {
            Copy-Item -LiteralPath $file.FullName -Destination $destFile -Force
            Write-SyncLog " [ADMIN UI] Copied $($file.Name) -> Engine\Scripts\Admin\UI\" -Level "SUCCESS" -ForegroundColor Green
            $copyCount++
        }
        else {
            Write-SyncLog " [DRY-RUN] Would copy $($file.Name) -> Engine\Scripts\Admin\UI\" -Level "INFO" -ForegroundColor DarkGray
        }
    }

    $toolsCopied = Sync-LiteDeployToolsToShare -SharePath $SharePath -RepoRoot $RepoRoot -CleanTarget $CleanTarget -WhatIf:$WhatIfPreference -Confirm:$ConfirmPreference
    $copyCount += $toolsCopied

    $null = New-LiteDeployReleaseManifest -RuntimeDirectory $runtimeDest -WhatIf:$WhatIfPreference -Confirm:$ConfirmPreference

    Write-SyncLog "Deployment Share sync complete ($copyCount files copied)." -Level "SUCCESS" -ForegroundColor Green
}

function Sync-LiteDeployToolsToShare {
    <#
    .SYNOPSIS
        Publishes repo Tools\ (WinPECT, etc.) to DeploymentShare\Tools\.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
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
        if ($PSCmdlet.ShouldProcess($toolsDst, "Create directory Engine\Tools")) {
            $null = New-Item -Path $toolsDst -ItemType Directory -Force
            Write-SyncLog "Created directory: 'Engine\Tools'" -Level "INFO" -ForegroundColor DarkGray
        }
        else {
            Write-SyncLog " [DRY-RUN] Would create directory: 'Engine\Tools'" -Level "INFO" -ForegroundColor DarkGray
        }
    }

    Write-SyncLog "Syncing Tools from '$toolsSrc' -> '$toolsDst'..." -Level "INFO" -ForegroundColor Cyan
    $copyCount = 0

    # Tools\README.md
    $readmeSrc = Join-Path $toolsSrc 'README.md'
    if (Test-Path -LiteralPath $readmeSrc -PathType Leaf) {
        $readmeDst = Join-Path $toolsDst 'README.md'
        if ($PSCmdlet.ShouldProcess($readmeDst, "Copy Tools README.md")) {
            Copy-Item -LiteralPath $readmeSrc -Destination $readmeDst -Force
            Write-SyncLog " [TOOLS]   Copied README.md -> Engine\Tools\" -Level "SUCCESS" -ForegroundColor Green
            $copyCount++
        }
        else {
            Write-SyncLog " [DRY-RUN] Would copy README.md -> Engine\Tools\" -Level "INFO" -ForegroundColor DarkGray
        }
    }

    # Each tool folder (WinPECT, DeployVault, …)
    foreach ($toolDir in @(Get-ChildItem -LiteralPath $toolsSrc -Directory -ErrorAction SilentlyContinue)) {
        $destTool = Join-Path $toolsDst $toolDir.Name
        if ($CleanTarget -and (Test-Path -LiteralPath $destTool -PathType Container)) {
            [void](Assert-LiteDeploySafeCleanTarget -TargetPath $destTool)
            if ($PSCmdlet.ShouldProcess($destTool, "Clean tool directory $($toolDir.Name)")) {
                Write-SyncLog "Cleaning Engine\Tools\$($toolDir.Name)..." -Level "WARNING" -ForegroundColor Yellow
                Remove-Item -LiteralPath $destTool -Recurse -Force -ErrorAction SilentlyContinue
            }
            else {
                Write-SyncLog " [DRY-RUN] Would clean Engine\Tools\$($toolDir.Name)" -Level "INFO" -ForegroundColor DarkGray
            }
        }
        if (-not (Test-Path -LiteralPath $destTool -PathType Container)) {
            if ($PSCmdlet.ShouldProcess($destTool, "Create tool directory $($toolDir.Name)")) {
                $null = New-Item -Path $destTool -ItemType Directory -Force
            }
        }

        foreach ($file in @(Get-ChildItem -LiteralPath $toolDir.FullName -Recurse -File -ErrorAction SilentlyContinue)) {
            $rel = $file.FullName.Substring($toolDir.FullName.Length).TrimStart('\', '/')
            $destFile = Join-Path $destTool $rel
            $destParent = Split-Path -Parent $destFile
            if (-not (Test-Path -LiteralPath $destParent -PathType Container)) {
                if ($PSCmdlet.ShouldProcess($destParent, "Create directory $destParent")) {
                    $null = New-Item -Path $destParent -ItemType Directory -Force
                }
            }
            if ($PSCmdlet.ShouldProcess($destFile, "Copy tool file $($toolDir.Name)\$rel")) {
                Copy-Item -LiteralPath $file.FullName -Destination $destFile -Force
                Write-SyncLog " [TOOLS]   Copied $($toolDir.Name)\$rel -> Engine\Tools\$($toolDir.Name)\" -Level "SUCCESS" -ForegroundColor Green
                $copyCount++
            }
            else {
                Write-SyncLog " [DRY-RUN] Would copy $($toolDir.Name)\$rel -> Engine\Tools\$($toolDir.Name)\" -Level "INFO" -ForegroundColor DarkGray
            }
        }
    }

    if ($copyCount -lt 1 -and (-not $WhatIfPreference)) {
        Write-SyncLog "Engine\Tools\ present but no files copied." -Level "WARNING" -ForegroundColor Yellow
    }

    return $copyCount
}

function Sync-WinPEStagingTarget {
    [CmdletBinding(SupportsShouldProcess = $true)]
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

    if ($CleanTarget) {
        [void](Assert-LiteDeploySafeCleanTarget -TargetPath $targetRoot)
    }

    if (-not (Test-Path -LiteralPath $targetRoot)) {
        if ($PSCmdlet.ShouldProcess($targetRoot, "Create WinPE bootstrap root")) {
            $null = New-Item -Path $targetRoot -ItemType Directory -Force
            Write-SyncLog "Created WinPE bootstrap root: '$targetRoot'" -Level "INFO" -ForegroundColor DarkGray
        }
        else {
            Write-SyncLog " [DRY-RUN] Would create WinPE bootstrap root: '$targetRoot'" -Level "INFO" -ForegroundColor DarkGray
        }
    }
    elseif ($CleanTarget) {
        if ($PSCmdlet.ShouldProcess($targetRoot, "Clean WinPE bootstrap root")) {
            Write-SyncLog "Cleaning WinPE bootstrap root '$targetRoot'..." -Level "WARNING" -ForegroundColor Yellow
            Get-ChildItem -LiteralPath $targetRoot -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object {
                    (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -and
                    ($_.Extension -in '.ps1', '.xaml', '.json')
                } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-SyncLog " [DRY-RUN] Would clean WinPE bootstrap root '$targetRoot'" -Level "INFO" -ForegroundColor DarkGray
        }
    }

    foreach ($sub in @("Boot", "Runtime", "UI", "Config")) {
        $p = Join-Path $targetRoot $sub
        if (-not (Test-Path -LiteralPath $p)) {
            if ($PSCmdlet.ShouldProcess($p, "Create WinPE subdirectory $sub")) {
                $null = New-Item -Path $p -ItemType Directory -Force
            }
        }
    }

    $copyCount = 0

    # Structured bootstrap: Boot + Logs/Environment/Hardware only (single source of truth copies)
    if ($Components.PSObject.Properties['WinPEBootstrap']) {
        foreach ($entry in $Components.WinPEBootstrap) {
            $destFile = Join-Path $targetRoot $entry.DestRelative
            $destDir = Split-Path -Parent $destFile
            if (-not (Test-Path -LiteralPath $destDir)) {
                if ($PSCmdlet.ShouldProcess($destDir, "Create directory $destDir")) {
                    $null = New-Item -Path $destDir -ItemType Directory -Force
                }
            }
            if ($PSCmdlet.ShouldProcess($destFile, "Inject WinPE bootstrap file $($entry.File.Name)")) {
                Copy-Item -LiteralPath $entry.File.FullName -Destination $destFile -Force
                Write-SyncLog " [WINPE]   Injected $($entry.File.Name) -> $InjectionSubfolder\$($entry.DestRelative)" -Level "SUCCESS" -ForegroundColor Green
                $copyCount++
            }
            else {
                Write-SyncLog " [DRY-RUN] Would inject $($entry.File.Name) -> $InjectionSubfolder\$($entry.DestRelative)" -Level "INFO" -ForegroundColor DarkGray
            }
        }
    }

    Write-SyncLog "WinPE Staging sync complete ($copyCount bootstrap files injected)." -Level "SUCCESS" -ForegroundColor Green
}

function Sync-MediaRootTarget {
    [CmdletBinding(SupportsShouldProcess = $true)]
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

    if ($CleanTarget) {
        [void](Assert-LiteDeploySafeCleanTarget -TargetPath $MediaRootPath)
    }

    # Sync Engine publish layouts on media (flat + Scripts\Runtime tree)
    Sync-DeploymentShareTarget -SharePath $MediaRootPath -Components $Components -CleanTarget $CleanTarget -RepoRoot $RepoRoot -WhatIf:$WhatIfPreference -Confirm:$ConfirmPreference

    # Ensure Media standard folders exist (Config, Content, WorkFlows)
    $mediaDirs = @("Config", "Content\OperatingSystems", "Content\Drivers", "Content\Packages", "WorkFlows", "WorkLogs\Deployments")
    foreach ($dir in $mediaDirs) {
        $p = Join-Path $MediaRootPath $dir
        if (-not (Test-Path -LiteralPath $p)) {
            if ($PSCmdlet.ShouldProcess($p, "Create media directory $dir")) {
                $null = New-Item -Path $p -ItemType Directory -Force
                Write-SyncLog "Created media directory: '$dir'" -Level "INFO" -ForegroundColor DarkGray
            }
            else {
                Write-SyncLog " [DRY-RUN] Would create media directory: '$dir'" -Level "INFO" -ForegroundColor DarkGray
            }
        }
    }

    Write-SyncLog "Media Root sync complete." -Level "SUCCESS" -ForegroundColor Green
}

# ==============================================================================
# 5. MAIN EXECUTION CONTROLLER
# ==============================================================================

function Start-LiteDeploySync {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

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
        Sync-DeploymentShareTarget -SharePath $DeploymentShare -Components $components -CleanTarget $Clean -RepoRoot $repoRoot -WhatIf:$WhatIfPreference -Confirm:$ConfirmPreference
    }

    # Execute WinPE Staging Sync
    if (-not [string]::IsNullOrWhiteSpace($WinPEStagingPath)) {
        Sync-WinPEStagingTarget -StagingPath $WinPEStagingPath -InjectionSubfolder $WinPEInjectionPath -Components $components -CleanTarget $Clean -WhatIf:$WhatIfPreference -Confirm:$ConfirmPreference
    }

    # Execute Media Root Sync
    if (-not [string]::IsNullOrWhiteSpace($MediaRoot)) {
        Sync-MediaRootTarget -MediaRootPath $MediaRoot -Components $components -RepoRoot $repoRoot -CleanTarget $Clean -WhatIf:$WhatIfPreference -Confirm:$ConfirmPreference
    }

    Write-Host ""
    Write-SyncLog "All synchronization tasks completed successfully." -Level "SUCCESS" -ForegroundColor Green
}

# Run synchronization when executed directly
if ($MyInvocation.InvocationName -ne '.') {
    Start-LiteDeploySync -WhatIf:$WhatIfPreference -Confirm:$ConfirmPreference
}

