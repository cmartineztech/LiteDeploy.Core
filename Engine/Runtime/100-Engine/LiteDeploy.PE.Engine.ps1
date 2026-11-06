<#
.SYNOPSIS
    LiteDeploy Engine — WinPE install pipeline (architecture v2).

.DESCRIPTION
    Dedicated WinPE execution engine:
      Precheck → WorkflowSelection → Disk → Image → Driver/Unattend staging → Handoff

    FullOS post-imaging tasks (credential unseal, Z: mapping, log mirroring, packages)
    are handled by LiteDeploy.FullOS.ps1. If invoked with -ResumeFullOS for backward
    compatibility, this engine delegates directly to LiteDeploy.FullOS.ps1.

.PARAMETER BootObject
    WinPE: bootstrap object from Boot (network, Z: mount, in-memory credentials).

.PARAMETER ResumeFullOS
    FullOS backward compatibility: delegates directly to LiteDeploy.FullOS.ps1.

.EXAMPLE
    # WinPE
    .\LiteDeploy.Engine.ps1 -BootObject $global:LiteDeployBootObject

.EXAMPLE
    # FullOS backward compatibility
    .\LiteDeploy.Engine.ps1 -ResumeFullOS -LocalRootName '~LiteDeploy'

.NOTES
    LiteDeploy Core Component Standard v2.0
    PowerShell Version: 5.1+
    Strict Mode: Version 2.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [psobject]$BootObject = $null,

    [Parameter(Mandatory = $false)]
    [switch]$SkipPreCheck,

# Show verified paths and the execution plan without loading phases or opening UI.
    [switch]$ValidateOnly,

    [Parameter(Mandatory = $false)]
    [switch]$Metadata,

    # FullOS first-boot resume (Setup CmdLine / FullOS.ps1; Engine -ResumeFullOS remains for compat).
    [switch]$ResumeFullOS,

    [string]$LocalRootName = '~LiteDeploy',

    [string]$OsDriveLetter = $env:SystemDrive,

    [string]$StatePath = ''
)

# Enforce strict execution discipline across WinPE runtime
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
        ComponentId          = "Engine"
        Name                 = "LiteDeploy Engine"
        Version              = "2.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "WinPE"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("Environment", "Logs", "Hardware", "State", "Drivers", "Disk", "Image", "UI.HardwarePrecheck", "UI.WorkflowSelection", "UI.Progress")
        Description          = "WinPE imaging pipeline orchestrator (Precheck, Selection, Disk, Image, Handoff)."
    }
}

# Fast-exit for automated inventory scanners or version queries
if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

# Keep Engine's identity before loading components with their own metadata function.
$script:EngineMetadata = Get-LiteDeployComponentMetadata

# REQUIREMENTS BY ENVIRONMENT
# Names belong here; Environment owns their file locations. Shared names are added to each list.
# FullOS resume: Setup CmdLine -> LiteDeploy.FullOS.ps1 (Engine -ResumeFullOS remains for compat)
$EngineRequirements = [pscustomobject]@{
    Shared = @(
        'Environment'                  # Path definitions and environment detection; loaded first.
        'BootConfig'                   # Deployment configuration (share-rooted after Z:).
        'Logs'                         # Console and file logging.
        'State'                        # Deployment state and progress data.
    )
    WinPE = @(
        'Hardware'                     # Inventory and readiness checks.
        'Drivers'                      # Driver detection for selection, not installation.
        'HardwarePrecheck'             # Readiness screen and its markup.
        'HardwarePrecheckView'
        'WorkflowSelection'            # OS, computer, disk, and driver choices.
        'WorkflowSelectionView'
        'DriverPicker'                 # Driver folder browser and its markup.
        'DriverPickerView'
        'HostShell'                    # Console window controls.
        'Progress'                     # Separate deployment progress display.
        'Disk'                         # Prepare the explicitly selected target disk.
        'Image'                        # Run Windows Setup.
    )
    FullOS = @(
        'Hardware'                     # Inventory helpers available after reboot.
        'Packages'                     # Application/script execution after reboot.
        'HostShell'                    # Console controls when needed.
    )
    FullOSOptional = @(
        'Progress'                     # Optional display for an interactive session.
    )
    FullOSImplemented = $true
}

# 2. STARTUP: Environment supplies the one path configuration.
if ($ResumeFullOS) {
    # FullOS bootstrap path — no BootObject from WinPE.
}
elseif (-not $BootObject) {
    throw 'Engine requires -BootObject from Boot. No deployment source is assumed.'
}
if (-not $ResumeFullOS -and -not $ValidateOnly -and [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Run Engine in the Boot Windows PowerShell -STA session.'
}
# Production can load its adjacent Environment. In development, load Environment once first.
# This is the only bootstrap dependency; every other path comes from its named map.
if (-not (Get-Command Get-LiteDeployRuntimePaths -ErrorAction SilentlyContinue)) {
    $environmentScript = Join-Path $PSScriptRoot 'LiteDeploy.Environment.ps1'
    if (-not (Test-Path -LiteralPath $environmentScript -PathType Leaf)) {
        throw 'Load LiteDeploy.Environment.ps1 with -Mode Development before running a source component.'
    }
    . $environmentScript
}

# ==============================================================================
# FULLOS DELEGATION - backward compatibility
# ==============================================================================
if ($ResumeFullOS) {
    if ($MyInvocation.InvocationName -eq '.') {
        return
    }
    $fullOsScript = Join-Path $PSScriptRoot 'LiteDeploy.FullOS.ps1'
    if (Test-Path -LiteralPath $fullOsScript -PathType Leaf) {
        & $fullOsScript -LocalRootName $LocalRootName -OsDriveLetter $OsDriveLetter -StatePath $StatePath
        return
    }
    throw "LiteDeploy.FullOS.ps1 not found beside Engine at '$fullOsScript'. FullOS resume cannot proceed without the FullOS engine."
}

# ==============================================================================
# WINPE — imaging pipeline (requires -BootObject)
# ==============================================================================
$requiredComponentNames = $EngineRequirements.Shared + $EngineRequirements.WinPE
$RuntimePaths = Get-LiteDeployRuntimePaths -BootObject $BootObject -RequiredComponents $requiredComponentNames
$RequiredFiles = $RuntimePaths.RequiredFiles
$requiredFilesResult = Test-LiteDeployRequiredFiles -Paths $RequiredFiles
if (-not $requiredFilesResult.Ok) {
    throw ("Required files are missing:`n - " + ($requiredFilesResult.Missing -join "`n - "))
}

# Boot normally supplies parsed configuration. Read the declared file once only if it did not.
$EngineBootConfig = if ($BootObject.PSObject.Properties['Config'] -and $null -ne $BootObject.Config) {
    $BootObject.Config
} else {
    Get-Content -LiteralPath $RequiredFiles.BootConfig -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
if ($null -eq $EngineBootConfig -or $EngineBootConfig -isnot [pscustomobject]) {
    throw "Boot configuration must be a JSON object: $($RequiredFiles.BootConfig)"
}

# Reject unsupported imaging configuration before UI, state writes, or disk formatting.
$selectedImageEngine = & $RequiredFiles.Image -BootConfig $EngineBootConfig -ValidateEngineOnly
if ($ValidateOnly) {
    # No credentials/configuration are returned. This is a file/config check, not a deployment test.
    [pscustomobject]@{
        Valid = $true
        Mode = $RuntimePaths.Mode
        DeploymentRoot = $RuntimePaths.DeploymentRoot
        RuntimeRoot = $RuntimePaths.RuntimeRoot
        RequiredFiles = $RequiredFiles
        RequirementsByEnvironment = $EngineRequirements
        ValidationProfile = 'WinPE'
        ImageEngine = $selectedImageEngine
        HelpersToLoad = @('Logs', 'Hardware', 'State', 'Drivers', 'HostShell')
        Phases = @('HardwarePrecheck', 'WorkflowSelection', 'Progress', 'Disk (destructive)', 'Image', 'Log/state handoff')
    }
    return
}

# 3. LOAD SHARED HELPERS ONCE, AT SCRIPT SCOPE.
# Dot-source exposes functions without running standalone actions. Keep this order visible.
# Disk and Image are NOT imported here: each runs once, at its deployment phase below.
$engineBootObject = $BootObject
try {
    # Write-LiteDeployLog: shared console/CMTrace logging.
    if (-not (Get-Command Sync-LiteDeployArtifactsToOsVolume -ErrorAction SilentlyContinue)) { . $RequiredFiles.Logs }
    # Hardware inventory used by precheck and selection.
    if (-not (Get-Command Get-HardwareInventory -ErrorAction SilentlyContinue)) { . $RequiredFiles.Hardware }
    # New-LiteDeployDeploymentObject / Save-LiteDeployDeploymentState.
    if (-not (Get-Command New-LiteDeployDeploymentObject -ErrorAction SilentlyContinue)) { . $RequiredFiles.State }
    # Driver detection used by WorkflowSelection, not driver installation.
    if (-not (Get-Command Get-SystemDriverDetection -ErrorAction SilentlyContinue)) { . $RequiredFiles.Drivers }
    # Console controls; no window action during import.
    if (-not (Get-Command Set-LiteDeployHostShellWindow -ErrorAction SilentlyContinue)) { . $RequiredFiles.HostShell }
}
finally {
    # Script parameter blocks share this scope; keep Boot's original object intact.
    $BootObject = $engineBootObject
}
$global:LiteDeployBootObject = $BootObject
$global:LiteDeployRuntimeRoot = $RuntimePaths.RuntimeRoot

# 4. ENGINE HELPERS: session ID, progress process, and result validation.
# The ordered deployment steps begin at Start-LiteDeployPipeline below.

function Get-LiteDeployUid {
    <#
    .SYNOPSIS
        Generates a short, collision-resistant deployment UID (e.g., 260806-A3F1).
    #>
    $bytes = [Byte[]]::new(2)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $hex = [System.BitConverter]::ToString($bytes) -replace '-'

    return "$((Get-Date).ToString('yyMMdd'))-$hex"
}

# Progress host (separate STA process) — topmost while Disk/Image run; polls DeploymentState.json.
# Disk / Image / UI wizards run in-process via Invoke-LiteDeployEngineScript (&) so Engine try/catch owns failures.
# Progress cannot share that model (WPF needs its own STA message loop), so Engine owns it as PassThru + stderr log + health checks.
$global:LiteDeployProgressProcess = $null
$global:LiteDeployProgressStdErrLog = $null
$global:LiteDeployProgressStdOutLog = $null

function Get-LiteDeployProgressHostLogDir {
    $null = New-Item -Path $RuntimePaths.LocalLogDirectory -ItemType Directory -Force -ErrorAction Stop
    return $RuntimePaths.LocalLogDirectory
}

function Get-LiteDeployProgressHostCrashText {
    <#
    .SYNOPSIS
        Returns stderr/stdout captured from the Progress host process (if any).
    #>
    $chunks = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($global:LiteDeployProgressStdErrLog, $global:LiteDeployProgressStdOutLog)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $text = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop)
            if (-not [string]::IsNullOrWhiteSpace($text)) { $chunks.Add($text.Trim()) }
        }
        catch {}
    }
    if ($chunks.Count -eq 0) { return "" }
    return ($chunks -join "`n")
}

function Test-LiteDeployProgressHost {
    <#
    .SYNOPSIS
        True when the Progress host process is still running.
    #>
    param([switch]$WarnIfDead)

    if ($global:LiteDeployProgressProcess -and -not $global:LiteDeployProgressProcess.HasExited) {
        return $true
    }
    return $false
}

function Stop-LiteDeployProgressHost {
    <#
    .SYNOPSIS
        Stops the Progress UI process when it is safe to dismiss (success), or when -Force is set.
    #>
    param(
        [switch]$Force
    )

    $proc = $null
    if ($global:LiteDeployProgressProcess -and -not $global:LiteDeployProgressProcess.HasExited) {
        $proc = $global:LiteDeployProgressProcess
    }
    elseif (Test-Path Variable:global:LiteDeployProgressProcess) {
        $g = $global:LiteDeployProgressProcess
        if ($g -and -not $g.HasExited) { $proc = $g }
    }

    if (-not $proc) {
        $global:LiteDeployProgressProcess = $null
        return
    }

    if (-not $Force) {
        # Give the host a moment to self-close on Completed / OSImageApplied.
        try { $null = $proc.WaitForExit(4000) } catch {}
    }

    if (-not $proc.HasExited) {
        try { $proc.CloseMainWindow() | Out-Null } catch {}
        try { $null = $proc.WaitForExit(1500) } catch {}
    }
    if (-not $proc.HasExited) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
    }

    $global:LiteDeployProgressProcess = $null
}

function Invoke-LiteDeployEngineScript {
    <#
    .SYNOPSIS
        Runs a Runtime phase script in-process (&) so Engine try/catch controls failure.
    .NOTES
        Prefer this over Start-Process for Disk / Image / domain scripts that must share BootObject,
        credentials, and StrictMode-safe $global: state. Not for Progress (WPF STA host).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [hashtable]$ArgumentTable = @{},

        [string]$PhaseName = "Phase",

        [switch]$RequireProgressHost
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "$PhaseName script was not found: $ScriptPath"
    }

    if ($RequireProgressHost) {
        $null = Test-LiteDeployProgressHost -WarnIfDead
    }

    return (& $ScriptPath @ArgumentTable)
}

function Start-LiteDeployProgressHost {
    <#
    .SYNOPSIS
        Launches UI.Progress as a topmost STA host that reads state from RAM (memory-map) + file.
    .NOTES
        Progress stays out-of-process (WPF STA). Engine still controls it:
          - PassThru process handle
          - stderr/stdout captured under X:\~LiteDeploy\WorkLogs\
          - settle check + one automatic restart if the host dies on startup
          - Test-LiteDeployProgressHost during Disk/Image
        Failure statuses stay visible (Progress does not auto-close on Failed/Cancelled).
    #>
    param(
        [string]$StatePath = "",
        [ValidateSet("Auto", "FullOS", "WinPE")]
        [string]$Environment = "Auto",
        [ValidateSet("Light", "Dark")]
        [string]$Theme = "Light",
        [switch]$WinPE
    )

    # Progress UI is disabled
    return $null

    # Replace any prior host so Disk/Image always own a single topmost window.
    Stop-LiteDeployProgressHost -Force

    # Ensure the RAM map has a fresh snapshot before Progress attaches.
    if ($global:LiteDeployDeployment -and (Get-Command Save-LiteDeployDeploymentState -ErrorAction SilentlyContinue)) {
        try { Save-LiteDeployDeploymentState -DeploymentState $global:LiteDeployDeployment } catch {}
    }

    $powershellExe = $RuntimePaths.PowerShellExe
    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) { throw "Windows PowerShell missing: $powershellExe" }

    $logDir = Get-LiteDeployProgressHostLogDir
    $global:LiteDeployProgressStdErrLog = $RuntimePaths.ProgressStdErr
    $global:LiteDeployProgressStdOutLog = $RuntimePaths.ProgressStdOut
    foreach ($logPath in @($global:LiteDeployProgressStdErrLog, $global:LiteDeployProgressStdOutLog)) {
        try {
            if (Test-Path -LiteralPath $logPath -PathType Leaf) {
                Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
            }
        }
        catch {}
    }

    # Avoid -NonInteractive (can interfere with WPF). Capture streams so Engine can report startup crashes.
    if ($useWinPE) {
        $argString = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$progressScript`" -StatePath `"$StatePath`" -WinPE -Theme $Theme -TopMost On"
    }
    else {
        $argString = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$progressScript`" -StatePath `"$StatePath`" -Environment FullOS -Theme $Theme -TopMost On"
    }

    $modeLabel = if ($useWinPE) { "WinPE" } else { "FullOS" }
    $maxAttempts = 2

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            # Hidden: no blue/black PowerShell console for the Progress host — only the WPF window.
            $proc = Start-Process -FilePath $powershellExe -ArgumentList $argString -PassThru `
                -RedirectStandardError $global:LiteDeployProgressStdErrLog `
                -RedirectStandardOutput $global:LiteDeployProgressStdOutLog `
                -WindowStyle Hidden -ErrorAction Stop
            $global:LiteDeployProgressProcess = $proc

            # Settle: catch immediate parameter/parse crashes (flashing console).
            Start-Sleep -Milliseconds 800
            if ($proc.HasExited) {
                $detail = Get-LiteDeployProgressHostCrashText
                $exitCode = $proc.ExitCode
                Write-LiteDeployLog (
                    "Progress host exited early (attempt $attempt/$maxAttempts, exit=$exitCode)." +
                    $(if ($detail) { " $detail" } else { " See $($global:LiteDeployProgressStdErrLog)" })
                ) -Level "WARNING" -ForegroundColor Yellow -Component "Engine"
                $global:LiteDeployProgressProcess = $null
                if ($attempt -lt $maxAttempts) {
                    Start-Sleep -Milliseconds 300
                    continue
                }
                return $null
            }

            # Console window remains open (not minimized)
            # if (Get-Command Set-LiteDeployHostShellWindow -ErrorAction SilentlyContinue) {
            #     try { Set-LiteDeployHostShellWindow -Action Minimize } catch {}
            # }

            Write-LiteDeployLog "Progress host started (PID $($proc.Id), TopMost, $modeLabel, hidden console, RAM state map + $StatePath)." -Level "INIT" -ForegroundColor Cyan -Component "Engine"
            return $proc
        }
        catch {
            Write-LiteDeployLog "Could not start Progress host (attempt $attempt/$maxAttempts): $_" -Level "WARNING" -ForegroundColor Yellow -Component "Engine"
            $global:LiteDeployProgressProcess = $null
            if ($attempt -ge $maxAttempts) { return $null }
        }
    }

    return $null
}

# ==============================================================================
# 5. ORCHESTRATION PIPELINE
# ==============================================================================

function Write-LiteDeployEnginePauseNotice {
    Write-Host ""
    Write-LiteDeployLog " [NOTICE]  Deployment halted." -Level "WARNING" -ForegroundColor Yellow -Component "Engine"
    Write-LiteDeployLog "           To restart this process, run 'startnet' below." -Level "WARNING" -ForegroundColor Yellow -Component "Engine"
    Write-Host ""
}

function Get-LiteDeploySelectedDiskNumber {
    <#
    .SYNOPSIS
        Enforces the WorkflowSelection result contract before any disk action.
    #>
    param([Parameter(Mandatory = $true)][psobject]$WorkflowResult, [psobject]$ComputerSetup = $null)
    if (-not $WorkflowResult.PSObject.Properties['Passed'] -or
        $WorkflowResult.Passed -isnot [bool] -or -not $WorkflowResult.Passed) {
        throw 'Expected a WorkflowSelection object with Passed = true.'
    }
    # Only an explicit false selects fixed Disk 0. Missing policy still requires a selection.
    $driveSelection = if ($ComputerSetup -is [System.Collections.IDictionary]) { $ComputerSetup['DriveSelection'] }
        elseif ($ComputerSetup -and $ComputerSetup.PSObject.Properties['DriveSelection']) { $ComputerSetup.DriveSelection }

    $diskNumber = -1
    if (-not $WorkflowResult.PSObject.Properties['TargetDiskIndex'] -or
        -not [int]::TryParse([string]$WorkflowResult.TargetDiskIndex, [ref]$diskNumber) -or $diskNumber -lt 0) {
        throw 'WorkflowSelection must return an explicit non-negative TargetDiskIndex. No default disk is selected.'
    }
    if ($driveSelection -is [bool] -and -not $driveSelection) {
        if ($diskNumber -ne 0) {
            throw 'DriveSelection=false requires Disk 0, but a different disk was confirmed. Reopen WorkflowSelection and confirm the target again.'
        }
        return 0
    }
    return $diskNumber
}
# ------------------------------------------------------------------------------
# WINPE handoff helpers (Runtime/Tools staging, WinPECT export, reboot)
# ------------------------------------------------------------------------------

function Sync-LiteDeployFullOSPayloadToOsVolume {
    <#
    .SYNOPSIS
        Copies Engine\Scripts\Runtime and Tools onto the OS volume (no SetupComplete.cmd).
    .NOTES
        Never copies Engine\Scripts\Admin. Tools\BunWinPeSuite heavy build artifacts are skipped.
        FullOS first launch is HKLM Run (staged in unattend specialize when actions > 0); FullOS may re-arm Run for reboots.
        Layout:
          <Os>:\~LiteDeploy\Engine\Scripts\Runtime\
          <Os>:\~LiteDeploy\Engine\Tools\
          <Os>:\~LiteDeploy\Content\Credentials\   (WinPECT — see credential handoff)
    #>
    param(
        [Parameter(Mandatory = $true)][psobject]$RuntimePaths,
        [Parameter(Mandatory = $true)][string]$OsDriveLetter,
        [string]$LocalRootName = '~LiteDeploy'
    )

    $drive = ($OsDriveLetter -replace '[\\/]+$', '').Trim()
    if ($drive -notmatch '^[A-Za-z]:?$') { throw "Invalid OS drive letter '$OsDriveLetter'." }
    if ($drive.Length -eq 1) { $drive += ':' }
    if ([string]::IsNullOrWhiteSpace($LocalRootName) -or $LocalRootName -match '[\\/:]' -or $LocalRootName -in @('.', '..')) {
        throw 'LocalRootName must be one directory name.'
    }

    $windowsPath = Join-Path "$drive\" 'Windows'
    if (-not (Test-Path -LiteralPath $windowsPath -PathType Container)) {
        throw "Target Windows directory is missing: $windowsPath"
    }

    $shareRoot = $RuntimePaths.DeploymentRoot
    $srcRuntime = Join-Path $shareRoot 'Engine\Scripts\Runtime'
    if (-not (Test-Path -LiteralPath $srcRuntime -PathType Container)) {
        throw "Published Runtime folder missing on share: $srcRuntime"
    }

    $targetRoot = Join-Path "$drive\" $LocalRootName
    $destRuntime = Join-Path $targetRoot 'Engine\Scripts\Runtime'
    $destTools = Join-Path $targetRoot 'Engine\Tools'

    $null = New-Item -Path $destRuntime -ItemType Directory -Force -ErrorAction Stop

    # Runtime only (flat published scripts + UI). Never Admin.
    Copy-Item -Path (Join-Path $srcRuntime '*') -Destination $destRuntime -Recurse -Force -ErrorAction Stop

    $srcTools = Join-Path $shareRoot 'Engine\Tools'
    if (-not (Test-Path -LiteralPath $srcTools -PathType Container)) {
        $srcTools = Join-Path $shareRoot 'Tools'
    }
    $toolsCopied = 0
    if (Test-Path -LiteralPath $srcTools -PathType Container) {
        $null = New-Item -Path $destTools -ItemType Directory -Force -ErrorAction Stop
        $excludeDirPattern = '(?i)(^|\\)(node_modules|Results|Catalogs|CatalogWork|Packs|\.git)(\\|$)'
        foreach ($file in @(Get-ChildItem -LiteralPath $srcTools -Recurse -File -Force -ErrorAction Stop)) {
            $relative = $file.FullName.Substring($srcTools.Length).TrimStart('\', '/')
            if ($relative -match $excludeDirPattern) { continue }
            if ($relative -match '(?i)^BunWinPeSuite\\' -and $file.Extension -match '(?i)^\.(exe|zip|7z)$') { continue }
            $targetFile = Join-Path $destTools $relative
            $targetParent = Split-Path -Parent $targetFile
            if (-not (Test-Path -LiteralPath $targetParent)) {
                $null = New-Item -Path $targetParent -ItemType Directory -Force -ErrorAction Stop
            }
            Copy-Item -LiteralPath $file.FullName -Destination $targetFile -Force -ErrorAction Stop
            $toolsCopied++
        }
    }

    # Remove legacy SetupComplete trampoline if a prior build left one on the OS volume.
    $legacySetupComplete = Join-Path $windowsPath 'Setup\Scripts\SetupComplete.cmd'
    if (Test-Path -LiteralPath $legacySetupComplete -PathType Leaf) {
        Remove-Item -LiteralPath $legacySetupComplete -Force -ErrorAction SilentlyContinue
    }

    $engineDest = Join-Path $destRuntime 'LiteDeploy.Engine.ps1'
    $fullOsDest = Join-Path $destRuntime 'LiteDeploy.FullOS.ps1'
    if (-not (Test-Path -LiteralPath $engineDest -PathType Leaf)) {
        throw "Engine missing after Runtime copy: $engineDest"
    }
    if (-not (Test-Path -LiteralPath $fullOsDest -PathType Leaf)) {
        throw "FullOS missing after Runtime copy: $fullOsDest"
    }

    return [pscustomobject]@{
        Success            = $true
        TargetRoot         = $targetRoot
        RuntimeDestination = $destRuntime
        ToolsDestination   = $destTools
        ToolsFilesCopied   = $toolsCopied
        EnginePath         = $engineDest
        FullOSPath         = $fullOsDest
        Message            = "Staged Runtime + Tools (no Admin) under $targetRoot; SetupComplete not staged"
    }
}

function Set-LiteDeployOfflineSetupCmdLine {
    <#
    .SYNOPSIS
        Mounts the offline SYSTEM hive and sets Setup\CmdLine + SetupType=2 to launch FullOS.
    .NOTES
        Replaces Sysprep continue. Uses %SystemDrive% in CmdLine so WinPE volume letters are not baked in.
        Does not touch the SOFTWARE hive used by WinPECT credential handoff.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$OsDriveLetter,
        [string]$LocalRootName = '~LiteDeploy',
        [string]$MountName = 'LDSetup'
    )

    $drive = ($OsDriveLetter -replace '[\\/]+$', '').Trim()
    if ($drive.Length -eq 1) { $drive += ':' }
    $windowsPath = Join-Path "$drive\" 'Windows'
    $hivePath = Join-Path $windowsPath 'System32\Config\SYSTEM'
    if (-not (Test-Path -LiteralPath $hivePath -PathType Leaf)) {
        throw "Offline SYSTEM hive not found: $hivePath"
    }

    $cmdLine = ('cmd.exe /c %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%SystemDrive%\{0}\Engine\Scripts\Runtime\LiteDeploy.FullOS.ps1" -LocalRootName "{0}" -OsDriveLetter %SystemDrive%' -f $LocalRootName)
    $registryRoot = "HKLM:\$MountName\Setup"
    $loaded = $false

    try {
        # Unload a leftover mount from a prior failed handoff.
        & reg.exe unload "HKLM\$MountName" 2>$null | Out-Null
        & reg.exe load "HKLM\$MountName" $hivePath | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "reg.exe load failed with exit code $LASTEXITCODE for $hivePath"
        }
        $loaded = $true

        if (-not (Test-Path -LiteralPath $registryRoot)) {
            $null = New-Item -Path $registryRoot -Force -ErrorAction Stop
        }
        Set-ItemProperty -LiteralPath $registryRoot -Name 'CmdLine' -Value $cmdLine -Type String -Force -ErrorAction Stop
        Set-ItemProperty -LiteralPath $registryRoot -Name 'SetupType' -Value 2 -Type DWord -Force -ErrorAction Stop

        return [pscustomobject]@{
            Success      = $true
            HivePath     = $hivePath
            MountName    = $MountName
            RegistryRoot = $registryRoot
            CmdLine      = $cmdLine
            SetupType    = 2
            Message      = "Offline SYSTEM hive Setup CmdLine armed (SetupType=2) for FullOS."
        }
    }
    finally {
        if ($loaded) {
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
            & reg.exe unload "HKLM\$MountName" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-LiteDeployLog "reg.exe unload HKLM\$MountName failed with exit code $LASTEXITCODE" -Level WARNING -Component Engine
            }
        }
    }
}

function Complete-LiteDeployWinPECredentialHandoff {
    <#
    .SYNOPSIS
        Stages in-memory credentials onto the OS volume via Tools\WinPECT (WinPECT).
    .NOTES
        Credentials are never written to DeploymentState. Only secret Ids and package path are recorded.
        Skips cleanly when no PSCredential is available (DeployVault integration may populate SecretMap later).
    #>
    param(
        [psobject]$DeploymentState,
        [psobject]$RuntimePaths,
        [string]$OsDriveLetter,
        [string]$LocalRootName,
        [psobject]$BootCtx = $null
    )

    $wrapper = Join-Path $RuntimePaths.DeploymentRoot 'Engine\Tools\WinPECT\LiteDeploy.WinPECT.ps1'
    if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) {
        $wrapper = Join-Path $RuntimePaths.DeploymentRoot 'Tools\WinPECT\LiteDeploy.WinPECT.ps1'
    }
    if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) {
        Write-LiteDeployLog "WinPECT wrapper not found at $wrapper; credential handoff skipped." -Level WARNING -Component Engine
        return [pscustomobject]@{ Success = $true; Skipped = $true; Message = 'WinPECT tools missing on share.' }
    }

    . $wrapper

    # StrictMode: unset globals throw if read directly — use Get-Variable.
    $secretMap = $null
    $secretMapVar = Get-Variable -Name LiteDeploySecretMap -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $secretMapVar -and $secretMapVar.Value -is [hashtable] -and $secretMapVar.Value.Count -gt 0) {
        $secretMap = $secretMapVar.Value
    }
    elseif ($BootCtx -and $BootCtx.PSObject.Properties['SecretMap'] -and $BootCtx.SecretMap -is [hashtable]) {
        $secretMap = $BootCtx.SecretMap
    }

    $shareCred = $null
    if ($BootCtx -and $BootCtx.PSObject.Properties['Credential'] -and $BootCtx.Credential -is [System.Management.Automation.PSCredential]) {
        $shareCred = $BootCtx.Credential
    }
    else {
        $credVar = Get-Variable -Name LiteDeployCredential -Scope Global -ErrorAction SilentlyContinue
        if ($null -ne $credVar -and $credVar.Value -is [System.Management.Automation.PSCredential]) {
            $shareCred = $credVar.Value
        }
    }

    $workflowRequiredIds = @()
    if ($DeploymentState -and $DeploymentState.PSObject.Properties['Workflow'] -and $DeploymentState.Workflow -and
        $DeploymentState.Workflow.PSObject.Properties['RequiredCredentialIds']) {
        $workflowRequiredIds = @($DeploymentState.Workflow.RequiredCredentialIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    # Enforce only Ids we actually hold in memory. Unmet workflow Ids wait for DeployVault.
    $availableIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ($secretMap) { foreach ($k in @($secretMap.Keys)) { $null = $availableIds.Add([string]$k) } }
    if ($null -ne $shareCred) { $null = $availableIds.Add('DeploymentShare') }
    $enforceRequired = @($workflowRequiredIds | Where-Object { $availableIds.Contains($_) })
    $missingRequired = @($workflowRequiredIds | Where-Object { -not $availableIds.Contains($_) })
    if ($missingRequired.Count -gt 0) {
        Write-LiteDeployLog ("Workflow RequiredCredentialIds not in memory (skipped until DeployVault): {0}" -f ($missingRequired -join ', ')) -Level WARNING -Component Engine
    }

    $exportParams = @{
        OsDriveLetter     = $OsDriveLetter
        LocalRootName     = $LocalRootName
        RequiredSecretIds = $enforceRequired
        AllowOverwrite    = $true
        SkipToolStaging   = $true   # Engine\Tools\WinPECT already copied by Sync-LiteDeployFullOSPayloadToOsVolume
    }
    if ($secretMap) { $exportParams['SecretMap'] = $secretMap }
    if ($null -ne $shareCred) { $exportParams['ShareCredential'] = $shareCred }

    $export = Export-LiteDeployWinPECTCredentials @exportParams

    if ($export.Skipped) {
        Write-LiteDeployLog $export.Message -Level INFO -Component Engine
        return $export
    }

    if (-not $export.Success) {
        throw "WinPECT credential handoff failed: $($export.Message)"
    }

    $handoffInfo = [pscustomobject]@{
        Staged          = $true
        SecretIds       = @($export.SecretIds)
        SecretFilePath  = [string]$export.SecretFilePath
        RegistrySubKey  = [string]$export.RegistrySubKey
        StagedToolsDir  = [string]$export.StagedToolsDir
        TransferId      = $(if ($export.TransferId) { [string]$export.TransferId } else { $null })
        StagedTimeUtc   = [DateTime]::UtcNow.ToString('o')
    }
    $DeploymentState.Execution | Add-Member -NotePropertyName CredentialHandoff -NotePropertyValue $handoffInfo -Force
    Write-LiteDeployLog ("WinPECT credential handoff staged ({0}): {1}" -f (@($export.SecretIds) -join ', '), $export.SecretFilePath) -Level SUCCESS -Component Engine
    return $export
}

function Complete-LiteDeployWinPEHandoff {
    <#
    .SYNOPSIS
        Persists a reboot request and verified OS-volume artifacts before requesting WinPE reboot.
    #>
    param([psobject]$DeploymentState, [psobject]$RuntimePaths, [string]$OsDriveLetter, [string]$LocalRootName, [psobject]$BootCtx = $null)
    if (-not (Test-LiteDeployWinPE)) { throw 'Automatic deployment reboot is only supported in WinPE.' }
    if ($DeploymentState.Status -ne 'Completed' -or -not $DeploymentState.OSInstall.Applied) {
        throw 'Reboot requires successful OS imaging.'
    }
    if ($OsDriveLetter -notmatch '^[A-Za-z]:?\\?$') { throw 'Reboot requires the explicit installed OS volume.' }
    $windowsPath = Join-Path ($OsDriveLetter.TrimEnd('\').TrimEnd(':') + ':\') 'Windows'
    if (-not (Test-Path -LiteralPath $windowsPath -PathType Container)) { throw 'Target Windows directory is missing; automatic reboot cancelled.' }
    $rebootTool = Join-Path $env:SystemRoot 'System32\wpeutil.exe'
    if (-not (Test-Path -LiteralPath $rebootTool -PathType Leaf)) { throw 'wpeutil.exe is missing; automatic reboot unavailable.' }

    $DeploymentState.Execution.CurrentStep = 'FullOSPayloadStaging'
    Write-LiteDeployLog 'Staging Engine Runtime + Tools (no Admin) onto the installed OS volume.' -Level NOTICE -Component Engine
    $payload = Sync-LiteDeployFullOSPayloadToOsVolume `
        -RuntimePaths $RuntimePaths `
        -OsDriveLetter $OsDriveLetter `
        -LocalRootName $LocalRootName
    $DeploymentState.Execution | Add-Member -NotePropertyName FullOSPayload -NotePropertyValue ([pscustomobject]@{
            Staged             = $true
            RuntimeDestination = [string]$payload.RuntimeDestination
            ToolsDestination   = [string]$payload.ToolsDestination
            EnginePath         = [string]$payload.EnginePath
            FullOSPath         = [string]$payload.FullOSPath
            ToolsFilesCopied   = [int]$payload.ToolsFilesCopied
            StagedTimeUtc      = [DateTime]::UtcNow.ToString('o')
        }) -Force
    Write-LiteDeployLog $payload.Message -Level SUCCESS -Component Engine
    Write-LiteDeployLog 'HKLM Run LiteDeployFullOS is staged by Image specialize (when actions > 0); FullOS may re-arm it at interactive logon — not offline in WinPE.' -Level INFO -Component Engine

    # Persist share target for FullOS Z: remount (never persist passwords — only UNC + drive + secret Id).
    $networkPath = $null
    if ($BootCtx -and $BootCtx.PSObject.Properties['NetworkPath'] -and $BootCtx.NetworkPath) {
        $networkPath = [string]$BootCtx.NetworkPath
    }
    elseif ($EngineBootConfig -and $EngineBootConfig.PSObject.Properties['Deployment'] -and $EngineBootConfig.Deployment -and
        $EngineBootConfig.Deployment.PSObject.Properties['NetworkPath'] -and $EngineBootConfig.Deployment.NetworkPath) {
        $networkPath = [string]$EngineBootConfig.Deployment.NetworkPath
    }
    $deploymentType = 'Media'
    if ($BootCtx -and $BootCtx.PSObject.Properties['DeploymentType'] -and $BootCtx.DeploymentType) {
        $deploymentType = [string]$BootCtx.DeploymentType
    }
    elseif ($networkPath) {
        $deploymentType = 'Network'
    }
    $DeploymentState.Execution | Add-Member -NotePropertyName FullOSShare -NotePropertyValue ([pscustomobject]@{
            DeploymentType = $deploymentType
            NetworkPath    = $networkPath
            DriveLetter    = 'Z:'
            CredentialId   = 'DeploymentShare'
            CredentialDir  = (Join-Path $LocalRootName 'Content\Credentials')
            ReconnectOnBoot = ($deploymentType -eq 'Network')
        }) -Force
    if ($deploymentType -eq 'Network' -and $networkPath) {
        Write-LiteDeployLog "FullOS (Network): reconnect Z: each boot and mirror logs to the share ($networkPath)." -Level INFO -Component Engine
    }
    elseif ($deploymentType -eq 'Media') {
        Write-LiteDeployLog 'FullOS (Media): no DeploymentShare reconnect; logs stay local/OS-volume only.' -Level INFO -Component Engine
    }

    $DeploymentState.Execution.CurrentStep = 'CredentialHandoff'
    Write-LiteDeployLog 'Staging WinPECT credential handoff onto the installed OS volume (when credentials are in memory).' -Level NOTICE -Component Engine
    $null = Complete-LiteDeployWinPECredentialHandoff `
        -DeploymentState $DeploymentState `
        -RuntimePaths $RuntimePaths `
        -OsDriveLetter $OsDriveLetter `
        -LocalRootName $LocalRootName `
        -BootCtx $BootCtx

    $DeploymentState.Execution.CurrentStep = 'RebootRequested'
    $DeploymentState.Execution | Add-Member -NotePropertyName RebootRequestedTime -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    Write-LiteDeployLog 'WinPE imaging completed. Reboot requested; verifying logs and state on the installed OS volume before restarting.' -Level NOTICE -Component Engine
    Save-LiteDeployDeploymentState -DeploymentState $DeploymentState
    Sync-LiteDeployLogsToShare -RuntimePaths $RuntimePaths -RemoteLogDir $DeploymentState.Execution.RemoteLogDir
    $handoff = Sync-LiteDeployArtifactsToOsVolume -RuntimePaths $RuntimePaths -OsDriveLetter $OsDriveLetter -DeploymentState $DeploymentState -LocalRootName $LocalRootName
    if (-not $handoff.Success -or -not $handoff.StateCopied -or $handoff.LogsCopied -lt 1) {
        throw "Reboot cancelled: logs/state handoff failed. $($handoff.Message)"
    }
    # All required writes precede this call. A requested reboot is not proof the next OS started.
    $process = Start-Process -FilePath $rebootTool -ArgumentList 'Reboot' -Wait -PassThru -NoNewWindow -ErrorAction Stop
    if ($process.ExitCode -ne 0) { throw "WinPE reboot command failed with exit code $($process.ExitCode)." }
}
# ------------------------------------------------------------------------------
# WINPE pipeline
# ------------------------------------------------------------------------------

function Start-LiteDeployPipeline {
    # Readiness is not yet a deployment. Keep its logs/state local and clear old mirrors.
    $deploymentUid = ''
    $remoteLogDir = ''
    $global:LiteDeployRemoteLogDir = ''
    $global:LiteDeployOsLogDir = ''
    $deployment = New-LiteDeployDeploymentObject -DeferUid -BootCtx $BootObject
    $global:LiteDeployDeployment = $deployment

    # Shared UI theme from BootConfig.Ui.Theme — PreCheck, WorkflowSelection, Progress all use this.
    $uiTheme = Get-LiteDeployUiTheme -BootConfig $EngineBootConfig
    if ($deployment.PSObject.Properties["Ui"] -and $deployment.Ui) {
        $deployment.Ui.Theme = $uiTheme
    }
    else {
        $deployment | Add-Member -NotePropertyName Ui -NotePropertyValue ([PSCustomObject]@{ Theme = $uiTheme }) -Force
    }
    $global:LiteDeployUiTheme = $uiTheme
    Save-LiteDeployDeploymentState -DeploymentState $deployment

    Write-LiteDeployLog "================================================================" -Level "INIT" -ForegroundColor Cyan -Component "Engine"
    Write-LiteDeployLog "$($script:EngineMetadata.Name) v$($script:EngineMetadata.Version)" -Level "INIT" -ForegroundColor Cyan -Component "Engine"
    Write-LiteDeployLog "Source        : $($RuntimePaths.DeploymentRoot)" -Level "INIT" -Component "Engine"
    Write-LiteDeployLog "Runtime       : $($RuntimePaths.RuntimeRoot) [$($RuntimePaths.Mode)]" -Level "INIT" -Component "Engine"
    Write-LiteDeployLog "BootConfig    : $($RequiredFiles.BootConfig)" -Level "INIT" -Component "Engine"
    Write-LiteDeployLog "Deployment UID: assigned when WorkflowSelection launches" -Level "INIT" -Component "Engine"
    Write-LiteDeployLog "UI Theme      : $uiTheme (BootConfig.Ui.Theme)" -Level "INIT" -ForegroundColor Cyan -Component "Engine"
    if ($remoteLogDir) {
        Write-LiteDeployLog "Remote Logs   : $remoteLogDir" -Level "INIT" -ForegroundColor Green -Component "Engine"
    }
    Write-LiteDeployLog "================================================================" -Level "INIT" -ForegroundColor Cyan -Component "Engine"

    try {
        # Console window remains open (not minimized) so technician can view real-time logs
        # if (Get-Command Set-LiteDeployHostShellWindow -ErrorAction SilentlyContinue) {
        #     try { Set-LiteDeployHostShellWindow -Action Minimize } catch {}
        # }

        # --------------------------------------------------------------------------
        # PHASE 1: PRE-CHECK (Hardware, Network, and Readiness Assessment)
        # --------------------------------------------------------------------------
        # Input: the verified config path/object. Expect: Passed and Inventory.
        # Stop here on failure/cancellation; no disk work has run.
        $preCheckPassed = $false
        $deployment.CurrentPhase = 1

        if ($SkipPreCheck) {
            Write-LiteDeployLog "SkipPreCheck switch specified. Bypassing Phase 1 (HardwarePreCheck)." -Level "WARNING" -ForegroundColor Yellow -Component "Engine"
            $preCheckPassed = $true
            $deployment.HardwarePreCheck.Passed = $true
            $deployment.HardwarePreCheck.CompletedTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
        }
        else {
            $deployment.Status = "HardwarePreCheck"
            Save-LiteDeployDeploymentState -DeploymentState $deployment

            $preCheckScript = $RequiredFiles.HardwarePrecheck

Write-LiteDeployLog "Phase 1: Launching System Readiness Pre-Check..." -Level "CHECK" -ForegroundColor Cyan -Component "Engine"
            try {
                $bootConfigPath = $RequiredFiles.BootConfig
                if ([string]::IsNullOrWhiteSpace($bootConfigPath) -or -not (Test-Path -LiteralPath $bootConfigPath -PathType Leaf)) {
                    throw "BootConfig.json was not found (declared Environment path); HardwarePreCheck requires -BootConfigPath."
                }

                # Execute HardwarePreCheck in the current STA process; theme from BootConfig.Ui.Theme.
                $precheckResult = & $preCheckScript -BootConfigPath $bootConfigPath -BootConfig $EngineBootConfig -RuntimeFiles $RequiredFiles -Theme $uiTheme

                # Only an explicit successful result allows the next screen.
                # Null output, a bare boolean, or a stale global flag cannot pass readiness.
                $preCheckPassed = $precheckResult -and
                    $precheckResult.PSObject.Properties['Passed'] -and
                    $precheckResult.Passed -is [bool] -and $precheckResult.Passed
                if ($preCheckPassed -and $precheckResult.PSObject.Properties['Inventory']) {
                    $global:LiteDeployHardwareInventory = $precheckResult.Inventory
                }
            }
            catch {
                Write-LiteDeployLog "Phase 1: Unhandled exception during HardwarePreCheck execution: $_" -Level "ERROR" -ForegroundColor Red -Component "Engine"
                $deployment.Status = "Failed"
                $deployment.Execution.Errors += "HardwarePreCheckException: $_"
                $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                Save-LiteDeployDeploymentState -DeploymentState $deployment
                return $deployment
            }

            if (-not $preCheckPassed) {
                Write-LiteDeployLog "Phase 1: HardwarePreCheck did not pass or was cancelled by user. Halting deployment pipeline." -Level "WARNING" -ForegroundColor Yellow -Component "Engine"
                $deployment.Status = "Cancelled"
                $deployment.HardwarePreCheck.Passed = $false
                $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                Save-LiteDeployDeploymentState -DeploymentState $deployment
                return $deployment
            }

            $deployment.HardwarePreCheck.Passed = $true
            $deployment.HardwarePreCheck.CompletedTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            Write-LiteDeployLog "Phase 1: System Readiness Pre-Check completed successfully." -Level "SUCCESS" -ForegroundColor Green -Component "Engine"
        }

        # --------------------------------------------------------------------------
        # PHASE 2: WORKFLOW SELECTION (Computer Identity, OS Workflow, Disk, Drivers)
        # --------------------------------------------------------------------------
        $deployment.CurrentPhase = 2
        $deployment.Status = "WorkflowSelection"
        Save-LiteDeployDeploymentState -DeploymentState $deployment

        $workflowScript = $RequiredFiles.WorkflowSelection

Write-LiteDeployLog "Phase 2: Launching Workflow Selection Wizard..." -Level "INIT" -ForegroundColor Cyan -Component "Engine"
        $workflowResult = $null
        try {
            $bootConfigPath = $RequiredFiles.BootConfig
            if ([string]::IsNullOrWhiteSpace($bootConfigPath) -or -not (Test-Path -LiteralPath $bootConfigPath -PathType Leaf)) {
                throw "BootConfig.json was not found (declared Environment path); WorkflowSelection requires -BootConfigPath."
            }

            # Environment already resolved the source; reuse the same config object in both screens.
            $deploymentSharePath = $RuntimePaths.DeploymentRoot
            $bootConfigObj = $EngineBootConfig

            # Give the selection screen its ID; cancellation still creates no share folder.
            $deploymentUid = Get-LiteDeployUid
            $deployment.DeploymentUid = $deploymentUid
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            Write-LiteDeployLog "Deployment UID: $deploymentUid" -Level INIT -Component Engine

            # Execute WorkflowSelection directly in the current STA PowerShell process (same Ui.Theme).
            $workflowResult = & $workflowScript `
                -BootConfigPath $bootConfigPath `
                -BootConfig $bootConfigObj `
                -RuntimeFiles $RequiredFiles `
                -DeploymentSharePath $deploymentSharePath `
                -DeploymentUid $deploymentUid `
                -Theme $uiTheme
        }
        catch {
            Write-LiteDeployLog "Phase 2: Unhandled exception during WorkflowSelection execution: $_" -Level "ERROR" -ForegroundColor Red -Component "Engine"
            $deployment.Status = "Failed"
            $deployment.Execution.Errors += "WorkflowSelectionException: $_"
            $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            return $deployment
        }

        # Expect a result object with Passed and an explicit TargetDiskIndex.
        # Cancellation stops here; malformed successful results are rejected before Disk.
        $deploymentRequested = $workflowResult -and
            $workflowResult.PSObject.Properties['Passed'] -and
            $workflowResult.Passed -is [bool] -and $workflowResult.Passed

        if (-not $deploymentRequested) {
            Write-LiteDeployLog "Phase 2: Workflow selection was cancelled by technician. Halting deployment pipeline." -Level "WARNING" -ForegroundColor Yellow -Component "Engine"
            $deployment.Status = "Cancelled"
            $deployment.Workflow.Confirmed = $false
            $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            return $deployment
        }

        try {
            # Adopt exactly the configuration the technician confirmed, including F5 reloads.
            if (-not $workflowResult.PSObject.Properties['BootConfig'] -or
                $null -eq $workflowResult.BootConfig -or $workflowResult.BootConfig -isnot [pscustomobject]) {
                throw 'WorkflowSelection must return its effective BootConfig object. Reopen selection using the current runtime.'
            }
            $EngineBootConfig = $workflowResult.BootConfig
            $BootObject | Add-Member -NotePropertyName Config -NotePropertyValue $EngineBootConfig -Force
            $deployment.BootObject = $BootObject
            # F5 can change ImageEngine too; reject unsupported engines before disk preparation.
            $null = & $RequiredFiles.Image -BootConfig $EngineBootConfig -ValidateEngineOnly
            $computerSetup = if ($EngineBootConfig.PSObject.Properties['ComputerSetup']) { $EngineBootConfig.ComputerSetup } else { $null }
            $targetDiskIndex = Get-LiteDeploySelectedDiskNumber -WorkflowResult $workflowResult -ComputerSetup $computerSetup
            $workflowResult | Add-Member -NotePropertyName TargetDiskIndex -NotePropertyValue $targetDiskIndex -Force
        }
        catch {
            Write-LiteDeployLog "WorkflowSelection returned an invalid target: $_" -Level ERROR -Component Engine
            $deployment.Status = 'Failed'
            $deployment.Execution.Errors += "InvalidWorkflowSelection: $_"
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            return $deployment
        }
        # Only a passed selection with a valid target gets a deployment log folder.
        # Copy the existing local boot/pre-check logs, then enable subsequent mirroring.
        $remoteLogDir = Initialize-LiteDeployDeploymentShareLogDir -RuntimePaths $RuntimePaths -DeploymentUid $deploymentUid
        $global:LiteDeployRemoteLogDir = $remoteLogDir
        $deployment.Execution.RemoteLogDir = $remoteLogDir
        $deployment.LogLocations.RemoteLogDir = $remoteLogDir
        $deployment.LogLocations.RemoteExecutionLog = if ($remoteLogDir) { Join-Path $remoteLogDir 'LiteDeploy.Execution.log' } else { '' }
        $deployment.LogLocations.RemoteDeploymentState = if ($remoteLogDir) { Join-Path $remoteLogDir 'DeploymentState.json' } else { '' }
        $deployment.Workflow.Confirmed = $true
        $deployment.Workflow.SelectionData = $workflowResult | Select-Object * -ExcludeProperty BootConfig
        $deployment.Workflow.CompletedTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        $deployment.Status = "ReadyForDeployment"
        Save-LiteDeployDeploymentState -DeploymentState $deployment
        Sync-LiteDeployLogsToShare -RuntimePaths $RuntimePaths -RemoteLogDir $deployment.Execution.RemoteLogDir

        $workflowName = if ($workflowResult.PSObject.Properties["WorkflowName"] -and $workflowResult.WorkflowName) {
            [string]$workflowResult.WorkflowName
        } else { "-" }
        $computerName = if ($workflowResult.PSObject.Properties["ComputerName"] -and $workflowResult.ComputerName) {
            [string]$workflowResult.ComputerName
        } else { "-" }
        $diskIndex = if ($workflowResult.PSObject.Properties["TargetDiskIndex"] -and $null -ne $workflowResult.TargetDiskIndex) {
            [string]$workflowResult.TargetDiskIndex
        } else { "-" }
        $diskModel = if ($workflowResult.PSObject.Properties["TargetDiskModel"] -and $workflowResult.TargetDiskModel) {
            [string]$workflowResult.TargetDiskModel
        } else { "" }
        $diskLabel = if ($diskModel) { "Disk $diskIndex ($diskModel)" } else { "Disk $diskIndex" }
        $drivers = if ($workflowResult.PSObject.Properties["DriverFolderPath"] -and $workflowResult.DriverFolderPath) {
            [string]$workflowResult.DriverFolderPath
        } else {
            "Standard OS In-Box Drivers (Windows Default)"
        }

        Write-LiteDeployLog " [SUCCESS] WorkflowSelection confirmed." -Level "SUCCESS" -ForegroundColor Green -Component "Engine"
        Write-LiteDeployLog (" [INFO]    Workflow: {0}" -f $workflowName) -Level "INFO" -Component "Engine"
        Write-LiteDeployLog (" [INFO]    Computer: {0} | {1}" -f $computerName, $diskLabel) -Level "INFO" -Component "Engine"
        Write-LiteDeployLog (" [INFO]    Drivers: {0}" -f $drivers) -Level "INFO" -Component "Engine"

        # --------------------------------------------------------------------------
        # PHASE 3: DISK PREPARATION (Wipe, Layout, Format, Recovery Flags)
        # --------------------------------------------------------------------------
        # Input: the confirmed disk number and firmware layout. Expect: Success and OSDriveLetter.
        # This is the first destructive phase. The explicit ConfirmDestroy argument is below.
        $deployment.CurrentPhase = 3
        $deployment.Status = "DiskPreparation"
        $deployment.Execution.CurrentStep = "FormattingTargetDisk"
        $deployment.Execution.PercentComplete = 25
        Save-LiteDeployDeploymentState -DeploymentState $deployment

        # Topmost Progress host for Disk + Image (RAM state; same BootConfig.Ui.Theme as prior UI).
        if (Test-LiteDeployWinPE) {
            $null = Start-LiteDeployProgressHost -StatePath $RuntimePaths.StatePath -WinPE -Theme $uiTheme
        }
        else {
            $null = Start-LiteDeployProgressHost -StatePath $RuntimePaths.StatePath -Environment FullOS -Theme $uiTheme
        }

        $diskScript = $RequiredFiles.Disk

# Target disk was explicitly validated immediately after workflow confirmation.

        # Resolve firmware boot mode (UEFI vs LEGACY)
        $detectedBootMode = "UEFI"
        if ($env:firmware_type -and ($env:firmware_type -match "(?i)Legacy|BIOS")) {
            $detectedBootMode = "LEGACY"
        }

        # Temporary OS staging drive letter in WinPE (defaults to "W")
        $osStagingDriveLetter = "W"

        Write-LiteDeployLog "Phase 3: Formatting Disk $targetDiskIndex for $detectedBootMode deployment (Staging: ${osStagingDriveLetter}:)..." -Level "INIT" -ForegroundColor Cyan -Component "Engine"

        $diskResult = $null
        try {
            $diskResult = Invoke-LiteDeployEngineScript -ScriptPath $diskScript -PhaseName "Disk" -ArgumentTable @{
                DiskNumber         = $targetDiskIndex
                BootMode           = $detectedBootMode
                OSTempDriveLetter  = $osStagingDriveLetter
                ConfirmDestroy     = $true
            }
        }
        catch {
            Write-LiteDeployLog "Phase 3 Failed: Unhandled exception during disk formatting: $_" -Level "ERROR" -ForegroundColor Red -Component "Engine"
            $deployment.Status = "Failed"
            $deployment.Execution.Errors += "DiskPreparationException: $_"
            $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            return $deployment
        }

        if (-not $diskResult -or -not $diskResult.Success) {
            Write-LiteDeployLog "Phase 3 Failed: Disk formatting did not succeed." -Level "ERROR" -ForegroundColor Red -Component "Engine"
            $deployment.Status = "Failed"
            $deployment.Execution.Errors += "DiskPreparationFailed"
            $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            return $deployment
        }

        $deployment.Disk.Formatted               = $true
        $deployment.Disk.DiskNumber              = $diskResult.DiskNumber
        $deployment.Disk.BootMode                = $diskResult.BootMode
        $deployment.Disk.OSPartitionNumber       = $diskResult.OSPartitionNumber
        $deployment.Disk.OSDriveLetter           = $diskResult.OSDriveLetter
        $deployment.Disk.SystemPartitionNumber   = $diskResult.SystemPartitionNumber
        $deployment.Disk.RecoveryPartitionNumber = $diskResult.RecoveryPartitionNumber
        $deployment.Disk.TotalSizeGB             = $diskResult.TotalSizeGB
        $deployment.Disk.CompletedTime           = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

        $deployment.Status = "ReadyForStaging"
        $deployment.Execution.PercentComplete = 30

        # Enable live triple-mirror: RAM + deployment share + OS volume (W:\~LiteDeploy).
        $localRootName = "~LiteDeploy"
        if ($BootObject -and $BootObject.PSObject.Properties["LocalRootName"] -and $BootObject.LocalRootName) {
            $localRootName = [string]$BootObject.LocalRootName
        }
        $osEnable = Sync-LiteDeployArtifactsToOsVolume -RuntimePaths $RuntimePaths `
            -OsDriveLetter $diskResult.OSDriveLetter `
            -DeploymentState $deployment `
            -LocalRootName $localRootName
        if ($osEnable.Success -and $osEnable.TargetRoot) {
            $global:LiteDeployOsRoot = $osEnable.TargetRoot
            $global:LiteDeployOsLogDir = Join-Path $osEnable.TargetRoot "WorkLogs"
            $global:LiteDeployOsStatePath = Join-Path $osEnable.TargetRoot "DeploymentState.json"
            Write-LiteDeployLog "Log/state mirror enabled on OS volume: $($osEnable.TargetRoot) (RAM + share + OS)." -Level "INIT" -ForegroundColor Cyan -Component "Engine"
        }

        Save-LiteDeployDeploymentState -DeploymentState $deployment
        Sync-LiteDeployLogsToShare -RuntimePaths $RuntimePaths -RemoteLogDir $deployment.Execution.RemoteLogDir

        Write-LiteDeployLog "Phase 3: Disk $targetDiskIndex formatted successfully ($($diskResult.TotalSizeGB) GB, OS at $($diskResult.OSDriveLetter))." -Level "SUCCESS" -ForegroundColor Green -Component "Engine"

        # --------------------------------------------------------------------------
        # PHASE 3.5: DRIVER STAGING & EXTRACTION
        # --------------------------------------------------------------------------
        $stagedDriverPath = $null
        $driverSelection = if ($workflowResult.PSObject.Properties['DriverFolderPath']) { [string]$workflowResult.DriverFolderPath } else { "" }

        if (-not [string]::IsNullOrWhiteSpace($driverSelection) -and $driverSelection -notlike "*Standard OS In-Box Drivers*") {
            Write-LiteDeployLog "Phase 3.5: Staging driver package for installation..." -Level "INIT" -ForegroundColor Cyan -Component "Engine"
            try {
                $driverDetection = if ($workflowResult.PSObject.Properties['DriverDetection']) { $workflowResult.DriverDetection } else { $null }
                if ($null -eq $driverDetection) {
                    $driverDetection = Get-SystemDriverDetection -ShareRoot $RuntimePaths.DeploymentRoot
                }

                # Honor custom path selected via folder picker in WorkflowSelection (only if different from auto-detection)
                $isAutoDetected = ($driverDetection -and $driverDetection.IsDetected -and ($driverSelection -eq $driverDetection.FullPath -or $driverSelection -eq $driverDetection.RelativePath))
                if (-not $isAutoDetected -and -not [string]::IsNullOrWhiteSpace($driverSelection) -and (Test-Path -LiteralPath $driverSelection)) {
                    $resolvedSel = (Resolve-Path -LiteralPath $driverSelection).Path
                    $isContainer = Test-Path -LiteralPath $resolvedSel -PathType Container
                    $driverDetection = [PSCustomObject]@{
                        IsDetected      = $true
                        SourceKind      = if ($isContainer) { "Content" } else { "Archive" }
                        FullPath        = $resolvedSel
                        RelativePath    = $driverSelection
                        Model           = "Custom"
                        Manufacturer    = "Custom"
                        ManufacturerKey = "Custom"
                        SHA256          = $null
                    }
                }

                $osDriverStagingDest = Join-Path $diskResult.OSDriveLetter "~LiteDeploy\Content\Drivers"
                $stageResult = Stage-LiteDeployDrivers -ShareRoot $RuntimePaths.DeploymentRoot -Detection $driverDetection -DestinationPath $osDriverStagingDest
                if ($stageResult -and ($stageResult.PSObject.Properties['Success'] -and $stageResult.Success) -and ($stageResult.PSObject.Properties['DriverPath'] -and $stageResult.DriverPath)) {
                    $stagedDriverPath = [string]$stageResult.DriverPath
                    Write-LiteDeployLog "Phase 3.5: Driver staging ready at '$stagedDriverPath'." -Level "SUCCESS" -ForegroundColor Green -Component "Engine"
                } else {
                    Write-LiteDeployLog "Phase 3.5: Driver staging completed with in-box fallback." -Level "INFO" -Component "Engine"
                }
            }
            catch {
                Write-LiteDeployLog "Phase 3.5: Driver staging encountered an error ($($_)). Continuing with in-box drivers." -Level "WARNING" -ForegroundColor Yellow -Component "Engine"
            }
        }

        # --------------------------------------------------------------------------
        # PHASE 4: OS IMAGE APPLICATION (Setup.exe Engine & Unattend Generation)
        # Input: selected media, image index, disk result, and loaded config. Expect Success/ExitCode/UnattendPath.
        # --------------------------------------------------------------------------
        $deployment.CurrentPhase = 4
        $deployment.Status = "ApplyingOSImage"
        $deployment.Execution.CurrentStep = "Applying OS image (setup.exe)"
        $deployment.Execution.PercentComplete = 35
        Save-LiteDeployDeploymentState -DeploymentState $deployment

        $imageScript = $RequiredFiles.Image

# Extract selected OS SetupPath / ImagePath / ImageIndex from Workflow selec        $selectedSetupPath = ""
        $selectedImagePath = ""
        $selectedMediaRoot = ""
        $selectedTemplateUnattendPath = ""
        $selectedImageIndex = 0

        if ($workflowResult) {
            $tag = $null
            if ($workflowResult.PSObject.Properties['WorkflowTag'] -and $null -ne $workflowResult.WorkflowTag) {
                $tag = $workflowResult.WorkflowTag
                # Guard: older UI typed WorkflowTag as [string] and destroyed the Tag object.
                if ($tag -is [string]) { $tag = $null }
            }
            if ($tag -and $tag.PSObject) {
                if ($tag.PSObject.Properties['SetupPath'] -and $tag.SetupPath) {
                    $selectedSetupPath = [string]$tag.SetupPath
                }
                if ($tag.PSObject.Properties['ImagePath'] -and $tag.ImagePath) {
                    $selectedImagePath = [string]$tag.ImagePath
                }
                if ($tag.PSObject.Properties['MediaRoot'] -and $tag.MediaRoot) {
                    $selectedMediaRoot = [string]$tag.MediaRoot
                }
                if ($tag.PSObject.Properties['UnattendPath'] -and $tag.UnattendPath) {
                    $selectedTemplateUnattendPath = [string]$tag.UnattendPath
                }
                if ($tag.PSObject.Properties['Index'] -and ($null -ne $tag.Index)) {
                    $selectedImageIndex = [int]$tag.Index
                }
            }
            foreach ($propName in @('SetupPath', 'ImagePath', 'MediaRoot', 'UnattendPath')) {
                if ($workflowResult.PSObject.Properties[$propName] -and $workflowResult.$propName) {
                    switch ($propName) {
                        'SetupPath'     { if (-not $selectedSetupPath)  { $selectedSetupPath  = [string]$workflowResult.SetupPath } }
                        'ImagePath'     { if (-not $selectedImagePath)  { $selectedImagePath  = [string]$workflowResult.ImagePath } }
                        'MediaRoot'     { if (-not $selectedMediaRoot)  { $selectedMediaRoot  = [string]$workflowResult.MediaRoot } }
                        'UnattendPath'  { if (-not $selectedTemplateUnattendPath) { $selectedTemplateUnattendPath = [string]$workflowResult.UnattendPath } }
                    }
                }
            }
            if ($selectedImageIndex -le 0 -and $workflowResult.PSObject.Properties['ImageIndex'] -and ($null -ne $workflowResult.ImageIndex)) {
                $selectedImageIndex = [int]$workflowResult.ImageIndex
            }
            if ($selectedImageIndex -le 0 -and $workflowResult.PSObject.Properties['Index'] -and ($null -ne $workflowResult.Index)) {
                $selectedImageIndex = [int]$workflowResult.Index
            }
        }

        # Environment owns path composition; reuse the source chosen at startup.
        $selectedSetupPath = Resolve-LiteDeployContentPath -Path $selectedSetupPath -DeploymentRoot $RuntimePaths.DeploymentRoot
        $selectedImagePath = Resolve-LiteDeployContentPath -Path $selectedImagePath -DeploymentRoot $RuntimePaths.DeploymentRoot
        $selectedMediaRoot = Resolve-LiteDeployContentPath -Path $selectedMediaRoot -DeploymentRoot $RuntimePaths.DeploymentRoot
        if ($selectedTemplateUnattendPath) {
            $selectedTemplateUnattendPath = Resolve-LiteDeployContentPath -Path $selectedTemplateUnattendPath -DeploymentRoot $RuntimePaths.DeploymentRoot
        }

        if (-not $selectedSetupPath -and $selectedMediaRoot) {
            $selectedSetupPath = Join-Path $selectedMediaRoot "setup.exe"
        }
        if (-not $selectedImagePath -and $selectedMediaRoot) {
            $selectedImagePath = $selectedMediaRoot
        }

        $effectiveEngineName = "Setup.exe"
        if ($workflowResult -and $workflowResult.PSObject.Properties['WorkflowTag'] -and $workflowResult.WorkflowTag -and 
            $workflowResult.WorkflowTag.PSObject.Properties['ComputerSetup'] -and $workflowResult.WorkflowTag.ComputerSetup) {
            $wfSetup = $workflowResult.WorkflowTag.ComputerSetup
            if ($wfSetup -is [System.Collections.IDictionary] -and $wfSetup.Contains('ImageEngine') -and $wfSetup['ImageEngine']) {
                $effectiveEngineName = [string]$wfSetup['ImageEngine']
            }
            elseif ($wfSetup.PSObject.Properties['ImageEngine'] -and $wfSetup.ImageEngine) {
                $effectiveEngineName = [string]$wfSetup.ImageEngine
            }
        }
        if ($effectiveEngineName -ieq "Setup.exe" -and $bootConfigObj -and $bootConfigObj.PSObject.Properties['ComputerSetup'] -and $bootConfigObj.ComputerSetup) {
            $bcSetup = $bootConfigObj.ComputerSetup
            if ($bcSetup -is [System.Collections.IDictionary] -and $bcSetup.Contains('ImageEngine') -and $bcSetup['ImageEngine']) {
                $effectiveEngineName = [string]$bcSetup['ImageEngine']
            }
            elseif ($bcSetup.PSObject.Properties['ImageEngine'] -and $bcSetup.ImageEngine) {
                $effectiveEngineName = [string]$bcSetup.ImageEngine
            }
        }

        Write-LiteDeployLog "Phase 4: Initiating OS installation (Image Index: $(if ($selectedImageIndex -gt 0) { $selectedImageIndex } else { 1 })) on $($diskResult.OSDriveLetter) via $effectiveEngineName..." -Level "INIT" -ForegroundColor Cyan -Component "Engine"

        $deployment.OSInstall.StartedTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        Save-LiteDeployDeploymentState -DeploymentState $deployment

        $imageResult = $null
        try {
            $imageResult = Invoke-LiteDeployEngineScript -ScriptPath $imageScript -PhaseName "Image" -ArgumentTable @{
                SetupPath             = $selectedSetupPath
                ImagePath             = $selectedImagePath
                ImageIndex            = $selectedImageIndex
                Destination           = $diskResult.OSDriveLetter
                DriverPath            = $stagedDriverPath
                TemplateUnattendPath  = $selectedTemplateUnattendPath
                WorkflowSelection     = $workflowResult
                DiskResult            = $diskResult
                BootConfig            = $bootConfigObj
                BootObject            = $BootObject
                ExecuteSetup          = $true
            }
        }
        catch {
            Write-LiteDeployLog "Phase 4 Failed: Unhandled exception during OS image application: $_" -Level "ERROR" -ForegroundColor Red -Component "Engine"
            $deployment.Status = "Failed"
            $deployment.Execution.Errors += "OSInstallationException: $_"
            $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            return $deployment
        }

        if (-not $imageResult -or -not $imageResult.Success) {
            Write-LiteDeployLog "Phase 4 Failed: OS image application did not succeed." -Level "ERROR" -ForegroundColor Red -Component "Engine"
            $deployment.Status = "Failed"
            $deployment.Execution.Errors += "OSInstallationFailed"
            $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            return $deployment
        }

        $deployment.OSInstall.Applied         = $true
        $deployment.OSInstall.Engine          = $imageResult.Engine
        $deployment.OSInstall.SetupPath       = $(if ($imageResult.PSObject.Properties['SetupPath'] -and $imageResult.SetupPath) { [string]$imageResult.SetupPath } else { $null })
        $deployment.OSInstall.ImagePath       = $(if ($imageResult.PSObject.Properties['ImagePath'] -and $imageResult.ImagePath) { [string]$imageResult.ImagePath } else { $null })
        $deployment.OSInstall.ImageIndex      = $imageResult.ImageIndex
        $deployment.OSInstall.UnattendPath    = $imageResult.UnattendPath
        $deployment.OSInstall.ExitCode        = $imageResult.ExitCode
        $deployment.OSInstall.DurationSeconds = $imageResult.DurationSeconds
        $deployment.OSInstall.CompletedTime   = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

        $deployment.Status = "OSImageApplied"
        $deployment.Execution.PercentComplete = 70
        Save-LiteDeployDeploymentState -DeploymentState $deployment
        Sync-LiteDeployLogsToShare -RuntimePaths $RuntimePaths -RemoteLogDir $deployment.Execution.RemoteLogDir

        Write-LiteDeployLog "Phase 4: Windows OS image applied successfully (Image Index: $($imageResult.ImageIndex)) in $($imageResult.DurationSeconds) seconds (Exit code: $($imageResult.ExitCode))." -Level "SUCCESS" -ForegroundColor Green -Component "Engine"

        # --------------------------------------------------------------------------
        # PHASE 5: ORCHESTRATION SUMMARY / OFFLINE STAGING HANDOFF
        # --------------------------------------------------------------------------
        $deployment.Status = "Completed"
        $deployment.Execution.CurrentStep = "OSImageApplied"
        $deployment.Execution.PercentComplete = 100
        $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        Save-LiteDeployDeploymentState -DeploymentState $deployment
        Sync-LiteDeployLogsToShare -RuntimePaths $RuntimePaths -RemoteLogDir $deployment.Execution.RemoteLogDir

        # Hand off logs + state onto the imaged OS volume (W:\~LiteDeploy) for FullOS resume.
        $osDriveForHandoff = $null
        if ($diskResult -and $diskResult.PSObject.Properties["OSDriveLetter"] -and $diskResult.OSDriveLetter) {
            $osDriveForHandoff = [string]$diskResult.OSDriveLetter
        }
        elseif ($deployment -and $deployment.PSObject.Properties["Disk"] -and $deployment.Disk -and $deployment.Disk.PSObject.Properties["OSDriveLetter"] -and $deployment.Disk.OSDriveLetter) {
            $osDriveForHandoff = [string]$deployment.Disk.OSDriveLetter
        }
        else {
            $osDriveForHandoff = ""
        }

        $localRootName = "~LiteDeploy"
        if ($BootObject -and $BootObject.PSObject.Properties["LocalRootName"] -and $BootObject.LocalRootName) {
            $localRootName = [string]$BootObject.LocalRootName
        }

        $appliedTarget = if ($imageResult -and $imageResult.PSObject.Properties['ImagePath'] -and $imageResult.ImagePath) {
            [string]$imageResult.ImagePath
        } elseif ($imageResult -and $imageResult.PSObject.Properties['SetupPath'] -and $imageResult.SetupPath) {
            [string]$imageResult.SetupPath
        } else {
            "Windows Image"
        }

        Write-LiteDeployLog "================================================================" -Level "SUCCESS" -ForegroundColor Green -Component "Engine"
        Write-LiteDeployLog "LiteDeploy Pre-Flight, Disk Preparation & OS Apply Complete [UID: $deploymentUid]." -Level "SUCCESS" -ForegroundColor Green -Component "Engine"
        Write-LiteDeployLog "Target Disk : Disk $targetDiskIndex ($detectedBootMode) | OS Partition: $($diskResult.OSDriveLetter)" -Level "SUCCESS" -ForegroundColor Green -Component "Engine"
        Write-LiteDeployLog "OS Applied  : $appliedTarget (Exit Code: $($imageResult.ExitCode))" -Level "SUCCESS" -ForegroundColor Green -Component "Engine"
        Write-LiteDeployLog "Unattend XML: $($imageResult.UnattendPath)" -Level "SUCCESS" -ForegroundColor Green -Component "Engine"
        Write-LiteDeployLog "================================================================" -Level "SUCCESS" -ForegroundColor Green -Component "Engine"

        try {
            Stop-LiteDeployProgressHost
            Complete-LiteDeployWinPEHandoff -DeploymentState $deployment -RuntimePaths $RuntimePaths -OsDriveLetter $osDriveForHandoff -LocalRootName $localRootName -BootCtx $BootObject
        }
        catch {
            $deployment.Status = 'Failed'
            $deployment.Execution.CurrentStep = 'HandoffOrRebootFailed'
            $deployment.Execution.Errors += "HandoffOrReboot: $_"
            Write-LiteDeployLog "Automatic restart stopped: $_" -Level ERROR -Component Engine
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            # Best effort to retain the failure too; never retry reboot from this catch.
            $null = Sync-LiteDeployArtifactsToOsVolume -RuntimePaths $RuntimePaths -OsDriveLetter $osDriveForHandoff -DeploymentState $deployment -LocalRootName $localRootName
        }
        return $deployment
        }
        finally {
            # Synchronize final logs to deployment share
            if ($deployment -and $deployment.Execution.RemoteLogDir) {
                Sync-LiteDeployLogsToShare -RuntimePaths $RuntimePaths -RemoteLogDir $deployment.Execution.RemoteLogDir
            }

            # Progress: dismiss on success; leave Failed/Cancelled window on top for the technician.
            if ($deployment -and $deployment.Status -in @("Failed", "Cancelled")) {
                # Ensure Progress has the terminal status on disk before we stop touching it.
                try { Save-LiteDeployDeploymentState -DeploymentState $deployment } catch {}
            }
            else {
                Stop-LiteDeployProgressHost
            }

            # Restore console window when exiting orchestration
            if (Get-Command Set-LiteDeployHostShellWindow -ErrorAction SilentlyContinue) {
                try { Set-LiteDeployHostShellWindow -Action Restore } catch {}
            }

            # Soft halt (Failed / Cancelled): same restart guidance as BootInitializer
            if ($deployment -and $deployment.Status -in @("Failed", "Cancelled")) {
                Write-LiteDeployEnginePauseNotice
            }
        }
    }

# ==============================================================================
# ENTRY POINT — WinPE pipeline (FullOS already returned above when -ResumeFullOS)
# ==============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    Start-LiteDeployPipeline
}



