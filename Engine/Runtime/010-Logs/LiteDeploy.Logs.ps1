<#
.SYNOPSIS
    LiteDeploy Logs - unified console + CMTrace logging component (architecture v2).

.DESCRIPTION
    Writes color-coded, column-aligned console output and appends Microsoft CMTrace
    XML entries to the WinPE/FullOS RAM (or system) path:
      1) Local  : $env:SystemDrive\~LiteDeploy\WorkLogs\LiteDeploy.Execution.log
    Each entry is also mirrored when the target directory exists:
      2) Share  : $global:LiteDeployRemoteLogDir / LogLocations.RemoteLogDir
      3) OS vol : $global:LiteDeployOsLogDir / LogLocations.OfflineOsLogDir (e.g. W:\~LiteDeploy\WorkLogs)

    Console format (tag padded to a fixed column so Level scans easily):
        [BOOT]     Initializing environment
        [SUCCESS]  Hardware check passed
        [WARNING]  Retrying network

    Messages that already begin with whitespace or a [TAG] are printed as-is (legacy callers
    and continuation lines). An empty Message prints a blank spacer line and is not written to the log.

    Usage:
        . "Z:\Engine\Scripts\Runtime\LiteDeploy.Logs.ps1"     # load Write-LiteDeployLog
        .\LiteDeploy.Logs.ps1 -Message "Hello" -Level SUCCESS  # write one entry
        .\LiteDeploy.Logs.ps1                                  # show log path + metadata (non-destructive)
        .\LiteDeploy.Logs.ps1 -Metadata                        # component metadata only

    ComponentId: Logs

.PARAMETER Message
    Log message text. Empty string prints a console spacer only.

.PARAMETER Level
    INFO, SUCCESS, INIT, CHECK, NOTICE, WARNING, RETRY, ERROR, BOOT, NETWORK, ENGINE.

.PARAMETER Component
    Subsystem name recorded in the CMTrace component attribute.

.PARAMETER ForegroundColor
    Console color. When White (default) the color is chosen from -Level.

.PARAMETER LogFileName
    Log file name. Defaults to LiteDeploy.Execution.log.

.PARAMETER LogPath
    Target directory override. Defaults to $env:SystemDrive\~LiteDeploy\WorkLogs.

.PARAMETER NoConsole
    Write to the log file only.

.PARAMETER NoPrefix
    Suppress the [LEVEL] console prefix for this entry.

.NOTES
    PowerShell 5.1, WinPE 5.1/10/11, Set-StrictMode -Version 2.0 compatible.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [AllowEmptyString()]
    [string]$Message = "",

    [Parameter(Mandatory = $false, Position = 1)]
    [ValidateSet("INFO", "SUCCESS", "INIT", "CHECK", "NOTICE", "WARNING", "RETRY", "ERROR", "BOOT", "NETWORK", "ENGINE")]
    [string]$Level = "INFO",

    [Parameter(Mandatory = $false, Position = 2)]
    [string]$Component = "LiteDeploy",

    [Parameter(Mandatory = $false)]
    [System.ConsoleColor]$ForegroundColor = [System.ConsoleColor]::White,

    [Parameter(Mandatory = $false)]
    [string]$LogFileName = "LiteDeploy.Execution.log",

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "",

    [Parameter(Mandatory = $false)]
    [switch]$NoConsole,

    [Parameter(Mandatory = $false)]
    [switch]$NoPrefix,

    [Parameter(Mandatory = $false)]
    [switch]$Metadata
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ==============================================================================
# COMPONENT METADATA
# ==============================================================================

function Get-LiteDeployComponentMetadata {
    return [PSCustomObject]@{
        ComponentId          = "Logs"
        Name                 = "LiteDeploy Logs"
        Version              = "2.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "Universal"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @()
        Description          = "Aligned console output and CMTrace-compatible logging with optional remote mirror across WinPE and FullOS."
    }
}

if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

# ==============================================================================
# INTERNAL HELPERS
# ==============================================================================

# Console tag column width: longest tag "[SUCCESS]" / "[WARNING]" (9) + 2 spaces.
# Must be $global: — Engine dotsources Logs then invokes Disk/UI with "& script.ps1";
# $script: vars inside log helpers resolve to the *caller* script scope under StrictMode.
$global:LiteDeployLogTagWidth = 11

function Get-LiteDeployLogColor {
    param([string]$Level)
    switch ($Level.ToUpper()) {
        "SUCCESS" { return [System.ConsoleColor]::Green }
        "INIT"    { return [System.ConsoleColor]::DarkGray }
        "CHECK"   { return [System.ConsoleColor]::Cyan }
        "NOTICE"  { return [System.ConsoleColor]::Yellow }
        "WARNING" { return [System.ConsoleColor]::Yellow }
        "RETRY"   { return [System.ConsoleColor]::DarkYellow }
        "ERROR"   { return [System.ConsoleColor]::Red }
        "BOOT"    { return [System.ConsoleColor]::Cyan }
        "NETWORK" { return [System.ConsoleColor]::Magenta }
        "ENGINE"  { return [System.ConsoleColor]::Gray }
        default   { return [System.ConsoleColor]::White }
    }
}

function Format-LiteDeployLogLine {
    <#
    .SYNOPSIS
        Builds the console line: "[LEVEL]" padded to a fixed column followed by the message.
    #>
    param(
        [AllowEmptyString()][string]$Message = "",
        [string]$Level = "INFO",
        [switch]$NoPrefix
    )

    # Blank spacer, pre-indented/continuation lines, and messages with their own [TAG] pass through unchanged.
    if ($NoPrefix -or [string]::IsNullOrWhiteSpace($Message) -or $Message -match '^\s' -or $Message -match '^\[[A-Za-z]+\]') {
        return $Message
    }

    $tag = "[{0}]" -f $Level.ToUpper()
    $width = 11
    if (Get-Variable -Name LiteDeployLogTagWidth -Scope Global -ErrorAction SilentlyContinue) {
        $width = [int]$global:LiteDeployLogTagWidth
    }
    return ($tag.PadRight($width) + $Message)
}

function Get-LiteDeployRemoteLogDirectory {
    # Deployment share / media mirror (StrictMode-safe).
    $g = Get-Variable -Name LiteDeployRemoteLogDir -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($g) {
        return [string]$g
    }

    $dep = Get-Variable -Name LiteDeployDeployment -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($dep -and $dep.PSObject.Properties['LogLocations'] -and $dep.LogLocations -and
        $dep.LogLocations.PSObject.Properties['RemoteLogDir'] -and $dep.LogLocations.RemoteLogDir) {
        return [string]$dep.LogLocations.RemoteLogDir
    }
    return ""
}

function Get-LiteDeployOsLogDirectory {
    # Offline Windows OS volume mirror (e.g. W:\~LiteDeploy\WorkLogs) after Disk prep.
    $g = Get-Variable -Name LiteDeployOsLogDir -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($g) {
        return [string]$g
    }

    $dep = Get-Variable -Name LiteDeployDeployment -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($dep -and $dep.PSObject.Properties['LogLocations'] -and $dep.LogLocations -and
        $dep.LogLocations.PSObject.Properties['OfflineOsLogDir'] -and $dep.LogLocations.OfflineOsLogDir) {
        return [string]$dep.LogLocations.OfflineOsLogDir
    }
    return ""
}

function Write-LiteDeployLogMirrorEntry {
    param(
        [string]$Directory,
        [string]$FileName,
        [string]$LogEntry
    )

    if ([string]::IsNullOrWhiteSpace($Directory) -or [string]::IsNullOrWhiteSpace($LogEntry)) {
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $Directory -ErrorAction SilentlyContinue)) {
            $null = New-Item -Path $Directory -ItemType Directory -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $Directory -ErrorAction SilentlyContinue) {
            $target = Join-Path $Directory $FileName
            Add-Content -Path $target -Value $LogEntry -Encoding utf8 -ErrorAction SilentlyContinue
        }
    }
    catch {}
}

# ==============================================================================
# PUBLIC API
# ==============================================================================

function Get-LiteDeployLogPath {
    <#
    .SYNOPSIS
        Returns the full log file path, creating the target directory when needed.
    #>
    param(
        [string]$CustomPath = "",
        [string]$FileName = "LiteDeploy.Execution.log"
    )

    if ([string]::IsNullOrWhiteSpace($CustomPath)) {
        $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "X:" }
        $CustomPath = Join-Path $sysDrive "~LiteDeploy\WorkLogs"
    }
    if (-not (Test-Path -LiteralPath $CustomPath)) {
        $null = New-Item -Path $CustomPath -ItemType Directory -Force -ErrorAction SilentlyContinue
    }
    return (Join-Path $CustomPath $FileName)
}

function Write-LiteDeployLog {
    <#
    .SYNOPSIS
        Writes an aligned console line and a CMTrace XML entry (plus remote mirror when configured).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [AllowEmptyString()]
        [string]$Message = "",

        [Parameter(Mandatory = $false, Position = 1)]
        [ValidateSet("INFO", "SUCCESS", "INIT", "CHECK", "NOTICE", "WARNING", "RETRY", "ERROR", "BOOT", "NETWORK", "ENGINE")]
        [string]$Level = "INFO",

        [Parameter(Mandatory = $false, Position = 2)]
        [string]$Component = "LiteDeploy",

        [Parameter(Mandatory = $false)]
        [System.ConsoleColor]$ForegroundColor = [System.ConsoleColor]::White,

        [Parameter(Mandatory = $false)]
        [string]$LogFileName = "LiteDeploy.Execution.log",

        [Parameter(Mandatory = $false)]
        [string]$LogPath = "",

        [Parameter(Mandatory = $false)]
        [switch]$NoConsole,

        [Parameter(Mandatory = $false)]
        [switch]$NoPrefix
    )

    Set-StrictMode -Version 2.0

    $selectedColor = $ForegroundColor
    if ($ForegroundColor -eq [System.ConsoleColor]::White) {
        $selectedColor = Get-LiteDeployLogColor -Level $Level
    }

    # Empty Message still prints a blank spacer; CMTrace skips whitespace-only entries below.
    if (-not $NoConsole) {
        Write-Host (Format-LiteDeployLogLine -Message $Message -Level $Level -NoPrefix:$NoPrefix) -ForegroundColor $selectedColor
    }

    try {
        $cleanMsg = $Message.Trim() -replace '[\r\n]+', ' '
        $cleanMsg = $cleanMsg.Replace(']LOG]!>', ']LOG] !>')
        if ([string]::IsNullOrWhiteSpace($cleanMsg)) {
            return
        }

        $targetLogFile = Get-LiteDeployLogPath -CustomPath $LogPath -FileName $LogFileName

        $now = Get-Date
        $utcOffsetMinutes = [int][System.TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
        $offsetSign = if ($utcOffsetMinutes -ge 0) { "+" } else { "-" }
        $timeStr = $now.ToString("HH:mm:ss.fff") + $offsetSign + [math]::Abs($utcOffsetMinutes).ToString()
        $dateStr = $now.ToString("MM-dd-yyyy")

        $typeCode = switch ($Level.ToUpper()) {
            "ERROR"   { "3" }
            "WARNING" { "2" }
            "NOTICE"  { "2" }
            "RETRY"   { "2" }
            default   { "1" }
        }

        $callingFile = "LiteDeploy.Logs.ps1"
        if ($MyInvocation.ScriptName) {
            $callingFile = Split-Path -Leaf $MyInvocation.ScriptName
        }

        $logEntry = "<![LOG[$cleanMsg]LOG]!><time=""$timeStr"" date=""$dateStr"" component=""$Component"" context="""" type=""$typeCode"" thread=""$PID"" file=""$callingFile"">"

        # 1) Local RAM / system drive (primary)
        Add-Content -Path $targetLogFile -Value $logEntry -Encoding utf8 -ErrorAction SilentlyContinue

        # 2) Deployment share / media
        Write-LiteDeployLogMirrorEntry -Directory (Get-LiteDeployRemoteLogDirectory) -FileName $LogFileName -LogEntry $logEntry

        # 3) Windows OS volume (W:\~LiteDeploy\WorkLogs) when Disk has mounted it
        Write-LiteDeployLogMirrorEntry -Directory (Get-LiteDeployOsLogDirectory) -FileName $LogFileName -LogEntry $logEntry
    }
    catch {
        # Logging must never break the caller.
    }
}

function Clear-LiteDeployLog {
    <#
    .SYNOPSIS
        Deletes the local log file (the remote mirror is left untouched).
    #>
    param(
        [string]$LogPath = "",
        [string]$LogFileName = "LiteDeploy.Execution.log"
    )

    try {
        $targetFile = Get-LiteDeployLogPath -CustomPath $LogPath -FileName $LogFileName
        if (Test-Path -LiteralPath $targetFile) {
            Remove-Item -LiteralPath $targetFile -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Ignore
    }
}

# ==============================================================================
# LOG SYNCHRONIZATION AND OS HANDOFF
# ==============================================================================

function Initialize-LiteDeployDeploymentShareLogDir {
    param(
        [Parameter(Mandatory = $true)][psobject]$RuntimePaths,
        [Parameter(Mandatory = $true)][string]$DeploymentUid)

    # One declared destination. Read-only media may reject it; keep local logs and report why.
    $deploymentLogDirectory = Join-Path $RuntimePaths.DeploymentLogRoot $DeploymentUid
    try {
        $null = New-Item -Path $deploymentLogDirectory -ItemType Directory -Force -ErrorAction Stop
        Sync-LiteDeployLogsToShare -RuntimePaths $RuntimePaths -RemoteLogDir $deploymentLogDirectory
        Write-LiteDeployLog "Deployment logs: $deploymentLogDirectory" -Level SUCCESS -Component Engine
        return $deploymentLogDirectory
    }
    catch {
        Write-LiteDeployLog "Cannot write deployment logs to '$deploymentLogDirectory': $_. Local logs remain at '$($RuntimePaths.LocalLogDirectory)'." -Level WARNING -Component Engine
        return $null
    }
}

function Sync-LiteDeployLogsToShare {
    param(
        [Parameter(Mandatory = $true)][psobject]$RuntimePaths,
        
        [string]$RemoteLogDir
    )
    if ([string]::IsNullOrWhiteSpace($RemoteLogDir) -or -not (Test-Path -LiteralPath $RemoteLogDir -ErrorAction SilentlyContinue)) {
        return
    }
    try {
        $localLogDir = $RuntimePaths.LocalLogDirectory
        if (Test-Path -LiteralPath $localLogDir) {
            Get-ChildItem -Path $localLogDir -File -Filter "LiteDeploy.*" -ErrorAction SilentlyContinue | ForEach-Object {
                $targetFile = Join-Path $RemoteLogDir $_.Name
                Copy-Item -LiteralPath $_.FullName -Destination $targetFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {}
}

function Sync-LiteDeployArtifactsToOsVolume {
    <#
    .SYNOPSIS
        Copies local logs and fresh sanitized state to the selected OS volume and verifies them.
    .NOTES
        The OS volume can be W: in WinPE and C: after boot. Never infer it from the host C:.
        Success requires the execution log, all enumerated local logs, and readable state.
    #>
    param(
        [Parameter(Mandatory = $true)][psobject]$RuntimePaths,
        [Parameter(Mandatory = $true)][string]$OsDriveLetter,
        [psobject]$DeploymentState = $null,
        [string]$LocalRootName = '~LiteDeploy'
    )
    $result = [pscustomobject]@{Success=$false; TargetRoot=''; LogsCopied=0; StateCopied=$false; Message=''}
    try {
        $drive = ($OsDriveLetter -replace '[\\/]+$', '').Trim()
        if ($drive -notmatch '^[A-Za-z]:?$') { throw "Invalid OS drive letter '$OsDriveLetter'." }
        if ($drive.Length -eq 1) { $drive += ':' }
        if (-not (Test-Path -LiteralPath "$drive\" -PathType Container)) { throw "OS volume '$drive' is not mounted." }
        if ([string]::IsNullOrWhiteSpace($LocalRootName) -or $LocalRootName -match '[\\/:]' -or $LocalRootName -in @('.', '..')) {
            throw 'LocalRootName must be one directory name.'
        }
        $targetRoot = Join-Path "$drive\" $LocalRootName
        $targetLogs = Join-Path $targetRoot 'WorkLogs'
        $stateDest = Join-Path $targetRoot 'DeploymentState.json'
        $result.TargetRoot = $targetRoot
        $null = New-Item -Path $targetLogs -ItemType Directory -Force -ErrorAction Stop

        $localLogDir = $RuntimePaths.LocalLogDirectory
        $executionLog = Join-Path $localLogDir 'LiteDeploy.Execution.log'
        if (-not (Test-Path -LiteralPath $executionLog -PathType Leaf)) { throw 'Local execution log is missing; handoff is incomplete.' }
        # Local logs are authoritative. Do not replace them with potentially stale share copies.
        foreach ($file in Get-ChildItem -LiteralPath $localLogDir -File -Filter 'LiteDeploy.*' -ErrorAction Stop) {
            $destination = Join-Path $targetLogs $file.Name
            if ($file.FullName -ine $destination) {
                Copy-Item -LiteralPath $file.FullName -Destination $destination -Force -ErrorAction Stop
            }
            if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash -ne
                (Get-FileHash -LiteralPath $destination -Algorithm SHA256 -ErrorAction Stop).Hash) {
                throw "Log verification failed: $($file.Name)."
            }
            $result.LogsCopied++
        }
        if ($DeploymentState) {
            # Stamp paths before serializing, so the disk copy includes its own handoff locations.
            $DeploymentState.LogLocations.OfflineOsRoot = $targetRoot
            $DeploymentState.LogLocations.OfflineOsLogDir = $targetLogs
            $DeploymentState.LogLocations.OfflineOsDeploymentState = $stateDest
            $safeState = ConvertTo-LiteDeploySerializableObject -InputObject $DeploymentState
            $stateJson = $safeState | ConvertTo-Json -Depth 10
        }
        else {
            $stateJson = Get-Content -LiteralPath $RuntimePaths.StatePath -Raw -ErrorAction Stop
        }
        $expected = $stateJson | ConvertFrom-Json -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string]$expected.DeploymentUid)) { throw 'State has no deployment ID.' }
        Set-Content -LiteralPath $stateDest -Value $stateJson -Encoding UTF8 -Force -ErrorAction Stop
        $storedJson = Get-Content -LiteralPath $stateDest -Raw -ErrorAction Stop
        $null = $storedJson | ConvertFrom-Json -ErrorAction Stop
        if ($storedJson.TrimEnd() -cne $stateJson.TrimEnd()) { throw 'OS-volume state verification failed.' }
        $result.StateCopied = $true
        $result.Success = $result.LogsCopied -gt 0
        $result.Message = "Verified $($result.LogsCopied) local log file(s) and deployment state at $targetRoot."
    }
    catch { $result.Message = $_.Exception.Message }
    return $result
}
if ($MyInvocation.InvocationName -ne '.') {
    if ($PSBoundParameters.ContainsKey('Message')) {
        Write-LiteDeployLog -Message $Message -Level $Level -Component $Component -ForegroundColor $ForegroundColor `
            -LogFileName $LogFileName -LogPath $LogPath -NoConsole:$NoConsole -NoPrefix:$NoPrefix
    }
    else {
        # Non-destructive summary
        $meta = Get-LiteDeployComponentMetadata
        $logFile = Get-LiteDeployLogPath -CustomPath $LogPath -FileName $LogFileName
        $remote = Get-LiteDeployRemoteLogDirectory

        Write-Host ""
        Write-Host ("{0} v{1} ({2})" -f $meta.Name, $meta.Version, $meta.ComponentId) -ForegroundColor Cyan
        Write-Host ("  Log file   : {0}" -f $logFile)
        Write-Host ("  Exists     : {0}" -f (Test-Path -LiteralPath $logFile))
        Write-Host ("  Remote dir : {0}" -f $(if ($remote) { $remote } else { "(not set)" }))
        Write-Host ("  Target env : {0}   PowerShell >= {1}" -f $meta.TargetEnvironment, $meta.MinPowerShellVersion)
        Write-Host "  Usage      : .\LiteDeploy.Logs.ps1 -Message ""text"" -Level SUCCESS [-Component Name]"
        Write-Host ""
    }
}

