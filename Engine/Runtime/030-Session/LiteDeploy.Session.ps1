<#
.SYNOPSIS
    LiteDeploy Session - unified deployment state, RAM IPC, logging, and artifact synchronization (architecture v2).

.DESCRIPTION
    Owns the deployment state document (DeploymentState.json), RAM memory-map IPC for the Progress UI,
    console output, Microsoft CMTrace logging, destination resolution (local / share / OS volume), and
    artifact synchronization and verification across WinPE and FullOS.

    Console format (tag padded to a fixed column so Level scans easily):
        [BOOT]     Initializing environment
        [SUCCESS]  Hardware check passed
        [WARNING]  Retrying network

    Messages that already begin with whitespace or a [TAG] are printed as-is (legacy callers
    and continuation lines). An empty Message prints a blank spacer line and is not written to the log.

    Public API:
      Logging & Mirrors:
        Write-LiteDeployLog [-Message] [-Level] [-Component] ...
        Clear-LiteDeployLog [-LogPath] [-LogFileName]
        Get-LiteDeployLogPath [-CustomPath] [-FileName]
        Initialize-LiteDeployDeploymentShareLogDir -RuntimePaths -DeploymentUid
        Sync-LiteDeployLogsToShare -RuntimePaths [-RemoteLogDir]
        Resolve-LiteDeployShareUncPath [-Path]
        Verify-LiteDeployLogSync -LocalPath -RemoteDirectory [-SubPath]
        Write-LiteDeployDiagnosticLogLocation -LocalPath [-RemoteLogDir] [-RelativePath] [-OsLogDir] [-Component]
        Sync-LiteDeployArtifactsToOsVolume -RuntimePaths -OsDriveLetter [-DeploymentState] [-LocalRootName]

      State & Progress:
        New-LiteDeployDeploymentObject [-Uid] [-BootCtx] [-RemoteLogDir] [-DeferUid]
        Save-LiteDeployDeploymentState -DeploymentState [-Path] [-NoRemote] [-PassThru]
        Save-LiteDeployState                           # Alias of Save-LiteDeployDeploymentState
        Get-LiteDeployState [-Path] [-FromFile]
        Update-LiteDeployState [-Status] [-CurrentPhase] [-CurrentStep] [-PercentComplete] [-AddError] [-Property] ...
        Set-LiteDeployState                            # Alias of Update-LiteDeployState
        Resume-LiteDeployState [-Path] [-DeploymentUid] [-BootObject] [-Force] ...
        Test-LiteDeployState [-State] [-Path] [-Persisted] [-Detailed]
        Get-DeploymentStateFromFile [-Path] [-DefaultState]

    SECURITY:
      Credentials and sensitive tokens are NEVER persisted or logged. Serialization omits any property
      matching sensitive patterns (Password, Secret, Token, Key, Credential) as well as PSCredential and
      SecureString instances. The in-memory object is never mutated by serialization. All logged error and
      state texts pass through a regex redaction filter.

    Usage:
        . "Z:\Engine\Runtime\LiteDeploy.Session.ps1"    # load logging & state functions
        .\LiteDeploy.Session.ps1 -Message "Hello" -Level SUCCESS
        .\LiteDeploy.Session.ps1                       # non-destructive summary
        .\LiteDeploy.Session.ps1 -Metadata             # component metadata only

    ComponentId: Session

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

.PARAMETER StatePath
    State file to inspect (standalone mode). Defaults to $env:SystemDrive\~LiteDeploy\DeploymentState.json.

.PARAMETER Metadata
    Outputs standardized component metadata and exits immediately.

.NOTES
    LiteDeploy Component Standard v2.0
    Target Environment: Universal (WinPE / FullOS)
    PowerShell Version: 5.1+
    Strict Mode: Version 2.0
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
    [string]$Component = "Session",

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
    [string]$StatePath = "",

    [Parameter(Mandatory = $false)]
    [switch]$Metadata
)

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
        ComponentId          = "Session"
        Name                 = "LiteDeploy Session"
        Version              = "2.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "Universal"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @()
        Description          = "Unified session controller: deployment state JSON, RAM IPC, console and CMTrace logging, and artifact synchronization across WinPE and FullOS."
    }
}

if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

# ==============================================================================
# 2. CONSTANTS & GLOBALS
# ==============================================================================

# Console tag column width: longest tag "[SUCCESS]" / "[WARNING]" (9) + 2 spaces.
$global:LiteDeployLogTagWidth = 11

$global:LiteDeployStateFileName = "DeploymentState.json"

# Named memory map: Engine publishes JSON here; Progress (separate process) reads it from RAM.
# WinPE X:\ file persist remains a durable fallback / reboot handoff.
$global:LiteDeployStateMemoryMapName = "Local\LiteDeploy.DeploymentState"
$global:LiteDeployStateMemoryMapCapacity = 1048576  # 1 MB
$global:LiteDeployStateMemoryMap = $null
$global:LiteDeployStateMemoryAccessor = $null

$global:LiteDeployStateKnownStatuses = @(
    "Initializing", "HardwarePreCheck", "WorkflowSelection", "ReadyForDeployment",
    "DiskPreparation", "ReadyForStaging", "ApplyingOSImage", "OSImageApplied",
    "Staging", "Completed", "FullOS", "Cancelled", "Failed"
)

# WinPE "Completed" means imaging/handoff finished; FullOS continues under Status FullOS.
$global:LiteDeployStateTerminalStatuses = @("Cancelled", "Failed")

# Pipeline phases (Engine): 1 PreCheck, 2 Workflow, 3 Disk, 4 OS image, 5 post-install / FullOS.
$global:LiteDeployStatePhaseNames = @{
    1 = "HardwarePreCheck"
    2 = "WorkflowSelection"
    3 = "DiskPreparation"
    4 = "OSInstallation"
    5 = "FullOS"
}

# Status written when a Failed/Cancelled deployment is resumed at a given phase.
$global:LiteDeployStatePhaseStatus = @{
    1 = "HardwarePreCheck"
    2 = "WorkflowSelection"
    3 = "DiskPreparation"
    4 = "ApplyingOSImage"
    5 = "FullOS"
}

# Property names that must never be serialized (exact, case-insensitive).
$global:LiteDeployStateSensitiveNamePattern = '^(credentials?|ps?credential|networkcredential|[a-z_]*password|[a-z_]*secret|[a-z_]*token|apikey|privatekey)$'

$global:LiteDeployStateMaxDepth = 8
$script:InSyncLiteDeployLogsToShare = $false

# ==============================================================================
# 3. INTERNAL HELPERS: REDACTION, LOGGING FORMAT, PROPERTY ACCESS
# ==============================================================================

function Protect-LiteDeployStateText {
    <#
    .SYNOPSIS
        Redacts password/secret/token style key-value pairs from free text before logging or storing.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return "" }

    $clean = [regex]::Replace(
        $Text,
        '(?i)((?:pass(?:word|wd)?|pwd|secret|token|api[-_ ]?key|credential)\s*[=:]\s*)("[^"]*"|''[^'']*''|[^\s;,]+)',
        '$1***')
    $clean = [regex]::Replace(
        $clean,
        '(?i)(-(?:password|passwd|pwd|secret|token|apikey)\s+)("[^"]*"|''[^'']*''|\S+)',
        '$1***')
    return $clean
}

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

    # Blank spacer, pre-indented/continuation lines pass through unchanged.
    if ($NoPrefix -or [string]::IsNullOrWhiteSpace($Message) -or $Message -match '^\s{2,}[^\[]') {
        return $Message
    }

    # Strip manual [TAG] prefix from console line only for known levels (retain domain tags like [UEFI]/[LEGACY])
    $clean = $Message -replace '(?i)^\s*\[(INFO|SUCCESS|INIT|CHECK|NOTICE|WARNING|RETRY|ERROR|DEBUG|BOOT|NETWORK|ENGINE)\]\s*', ''

    $tag = "[{0}]" -f $Level.ToUpper()
    $width = 11
    if (Get-Variable -Name LiteDeployLogTagWidth -Scope Global -ErrorAction SilentlyContinue) {
        $width = [int]$global:LiteDeployLogTagWidth
    }
    return ($tag.PadRight($width) + $clean)
}

function Get-LiteDeployStateProperty {
    <#
    .SYNOPSIS
        StrictMode-safe, case-insensitive property/key read. Returns $Default when missing or $null.
        Array values are enumerated to the pipeline: wrap array reads in @(...).
    #>
    param(
        $InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in @($InputObject.Keys)) {
            if ([string]$key -ieq $Name) {
                $dictValue = $InputObject[$key]
                if ($null -eq $dictValue) { return $Default }
                return $dictValue
            }
        }
        return $Default
    }

    foreach ($prop in $InputObject.PSObject.Properties) {
        if ($prop.Name -ieq $Name) {
            $propValue = $prop.Value
            if ($null -eq $propValue) { return $Default }
            return $propValue
        }
    }
    return $Default
}

function Test-LiteDeployStateHasProperty {
    param(
        $InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) { return $false }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in @($InputObject.Keys)) {
            if ([string]$key -ieq $Name) { return $true }
        }
        return $false
    }

    foreach ($prop in $InputObject.PSObject.Properties) {
        if ($prop.Name -ieq $Name) { return $true }
    }
    return $false
}

function Set-LiteDeployStateMember {
    <#
    .SYNOPSIS
        Sets (or adds) a single property/key on a PSCustomObject or dictionary.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Target,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        $Value
    )

    if ($Target -is [System.Collections.IDictionary]) {
        $Target[$Name] = $Value
        return
    }

    foreach ($prop in $Target.PSObject.Properties) {
        if ($prop.Name -ieq $Name) {
            $prop.Value = $Value
            return
        }
    }

    Add-Member -InputObject $Target -MemberType NoteProperty -Name $Name -Value $Value -Force
}

function Set-LiteDeployStateValue {
    <#
    .SYNOPSIS
        Sets a value using a dotted path (e.g. 'Disk.Formatted'), creating intermediate objects as needed.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Object,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        $Value
    )

    $parts = @($Path.Split('.') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts.Count -eq 0) {
        throw "State property path '$Path' is empty."
    }

    $leaf = [string]$parts[$parts.Count - 1]
    if ($leaf -match $global:LiteDeployStateSensitiveNamePattern) {
        throw "Refusing to store sensitive property '$leaf' in deployment state."
    }

    $cursor = $Object
    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        $segment = [string]$parts[$i]
        $next = Get-LiteDeployStateProperty -InputObject $cursor -Name $segment
        if ($null -eq $next) {
            $next = [PSCustomObject]@{}
            Set-LiteDeployStateMember -Target $cursor -Name $segment -Value $next
        }
        $cursor = $next
    }

    Set-LiteDeployStateMember -Target $cursor -Name $leaf -Value $Value
}

function Get-LiteDeployStateTimestamp {
    return (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
}

function New-LiteDeployStateUid {
    $bytes = New-Object byte[] 2
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $hex = [System.BitConverter]::ToString($bytes) -replace '-'
    return ("{0}-{1}" -f (Get-Date).ToString('yyMMdd'), $hex)
}

function Get-LiteDeployStateSystemDrive {
    $sysDrive = if ($env:SystemDrive) { [string]$env:SystemDrive } else { "X:" }
    return $sysDrive.TrimEnd('\')
}

function Get-LiteDeployStateFilePath {
    <#
    .SYNOPSIS
        Default local state file: <SystemDrive>\~LiteDeploy\DeploymentState.json
        In WinPE this is on the RAM disk (X:).
    #>
    return ("{0}\~LiteDeploy\{1}" -f (Get-LiteDeployStateSystemDrive), $global:LiteDeployStateFileName)
}

function Get-LiteDeployLiveState {
    $live = Get-Variable -Name LiteDeployDeployment -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $live) { return $live }
    return $null
}

# ==============================================================================
# 4. CONSOLIDATED DESTINATIONS (LOCAL, SHARE, OS VOLUME)
# ==============================================================================

function Get-LiteDeployStateRemoteDirectory {
    <#
    .SYNOPSIS
        Returns the share-side log directory recorded in a state object or global variable ('' when none).
    #>
    param($State = $null)

    if ($State) {
        $logLocations = Get-LiteDeployStateProperty -InputObject $State -Name "LogLocations"
        $remote = Get-LiteDeployStateProperty -InputObject $logLocations -Name "RemoteLogDir"
        if (-not [string]::IsNullOrWhiteSpace([string]$remote)) { return [string]$remote }

        $execution = Get-LiteDeployStateProperty -InputObject $State -Name "Execution"
        $remote = Get-LiteDeployStateProperty -InputObject $execution -Name "RemoteLogDir"
        if (-not [string]::IsNullOrWhiteSpace([string]$remote)) { return [string]$remote }
    }

    $g = Get-Variable -Name LiteDeployRemoteLogDir -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($g) { return [string]$g }

    $dep = Get-Variable -Name LiteDeployDeployment -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($dep -and $dep.PSObject.Properties['LogLocations'] -and $dep.LogLocations -and
        $dep.LogLocations.PSObject.Properties['RemoteLogDir'] -and $dep.LogLocations.RemoteLogDir) {
        return [string]$dep.LogLocations.RemoteLogDir
    }
    return ""
}

function Get-LiteDeployRemoteLogDirectory {
    <#
    .SYNOPSIS
        Deployment share / media mirror directory (consolidated with Get-LiteDeployStateRemoteDirectory).
    #>
    param($State = $null)
    return (Get-LiteDeployStateRemoteDirectory -State $State)
}

function Get-LiteDeployStateOsPaths {
    <#
    .SYNOPSIS
        Resolves offline Windows OS volume paths for state/log mirroring (e.g. W:\~LiteDeploy).
    #>
    param($State = $null)

    $result = [PSCustomObject]@{
        Root      = ""
        LogDir    = ""
        StatePath = ""
    }

    $gRoot = Get-Variable -Name LiteDeployOsRoot -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    $gLogs = Get-Variable -Name LiteDeployOsLogDir -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    $gState = Get-Variable -Name LiteDeployOsStatePath -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($gRoot) { $result.Root = [string]$gRoot }
    if ($gLogs) { $result.LogDir = [string]$gLogs }
    if ($gState) { $result.StatePath = [string]$gState }

    if (-not $State) {
        $State = Get-LiteDeployLiveState
    }

    if ($State) {
        $logLocations = Get-LiteDeployStateProperty -InputObject $State -Name "LogLocations"
        if ($logLocations) {
            $root = Get-LiteDeployStateProperty -InputObject $logLocations -Name "OfflineOsRoot"
            $logs = Get-LiteDeployStateProperty -InputObject $logLocations -Name "OfflineOsLogDir"
            $statePath = Get-LiteDeployStateProperty -InputObject $logLocations -Name "OfflineOsDeploymentState"
            if (-not $result.Root -and $root) { $result.Root = [string]$root }
            if (-not $result.LogDir -and $logs) { $result.LogDir = [string]$logs }
            if (-not $result.StatePath -and $statePath) { $result.StatePath = [string]$statePath }
        }
    }

    if (-not $result.StatePath -and $result.Root) {
        $result.StatePath = Join-Path $result.Root $global:LiteDeployStateFileName
    }
    if (-not $result.LogDir -and $result.Root) {
        $result.LogDir = Join-Path $result.Root "WorkLogs"
    }

    return $result
}

function Get-LiteDeployOsLogDirectory {
    <#
    .SYNOPSIS
        Offline Windows OS volume mirror directory (consolidated with Get-LiteDeployStateOsPaths).
    #>
    param($State = $null)
    $paths = Get-LiteDeployStateOsPaths -State $State
    return [string]$paths.LogDir
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
# 5. CORE LOGGING ENGINE
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
        $overrideDir = Get-Variable -Name LiteDeploySessionLogDir -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($overrideDir)) {
            $CustomPath = [string]$overrideDir
        } else {
            $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "X:" }
            $CustomPath = Join-Path $sysDrive "~LiteDeploy\WorkLogs"
        }
    }
    if (-not (Test-Path -LiteralPath $CustomPath)) {
        $null = New-Item -Path $CustomPath -ItemType Directory -Force -ErrorAction SilentlyContinue
    }
    return (Join-Path $CustomPath $FileName)
}

function Write-LiteDeployLog {
    <#
    .SYNOPSIS
        Writes an aligned console line and a CMTrace XML entry (plus remote mirrors when configured).
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
        [string]$Component = "Session",

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

        # Do not decorate CMTrace log with banner divider lines (====)
        if ($cleanMsg -match '^={5,}') {
            return
        }

        # Strip manual [TAG] prefix from persisted log entry only for known levels (retain domain tags like [UEFI]/[LEGACY])
        $cleanMsg = $cleanMsg -replace '(?i)^\s*\[(INFO|SUCCESS|INIT|CHECK|NOTICE|WARNING|RETRY|ERROR|DEBUG|BOOT|NETWORK|ENGINE)\]\s*', ''
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
            "RETRY"   { "2" }
            "NOTICE"  { "1" }
            default   { "1" }
        }

        $callingFile = "LiteDeploy.Session.ps1"
        if ($MyInvocation.ScriptName) {
            $callingFile = Split-Path -Leaf $MyInvocation.ScriptName
        }

        $logEntry = "<![LOG[$cleanMsg]LOG]!><time=""$timeStr"" date=""$dateStr"" component=""$Component"" context="""" type=""$typeCode"" thread=""$PID"" file=""$callingFile"">"

        # 1) Local RAM / system drive (primary)
        Add-Content -Path $targetLogFile -Value $logEntry -Encoding utf8 -ErrorAction SilentlyContinue

        # 2) Deployment share / media
        Write-LiteDeployLogMirrorEntry -Directory (Get-LiteDeployRemoteLogDirectory) -FileName $LogFileName -LogEntry $logEntry

        # 3) Windows OS volume (W:\~LiteDeploy\WorkLogs) when mounted
        Write-LiteDeployLogMirrorEntry -Directory (Get-LiteDeployOsLogDirectory) -FileName $LogFileName -LogEntry $logEntry
    }
    catch {
        # Logging must never break the caller.
    }
}

function Clear-LiteDeployLog {
    <#
    .SYNOPSIS
        Deletes the local log file (remote mirrors are left untouched).
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

function Write-LiteDeployStateLog {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO",

        [switch]$NoConsole
    )

    $text = Protect-LiteDeployStateText -Text $Message
    try {
        Write-LiteDeployLog -Message $text -Level $Level -Component "Session" -NoConsole:$NoConsole
    }
    catch {
        if (-not $NoConsole) {
            switch ($Level) {
                "WARNING" { Write-Warning $text }
                "ERROR"   { Write-Warning $text }
                default   { Write-Verbose $text }
            }
        }
    }
}

# ==============================================================================
# 6. MEMORY-MAP IPC (RAM TRANSPORT FOR PROGRESS UI)
# ==============================================================================

function Get-LiteDeployStateMemoryMapName {
    return [string]$global:LiteDeployStateMemoryMapName
}

function Close-LiteDeployStateMemory {
    <#
    .SYNOPSIS
        Releases the publisher-side memory map handles (Engine process).
    #>
    try {
        if ($null -ne $global:LiteDeployStateMemoryAccessor) {
            $global:LiteDeployStateMemoryAccessor.Dispose()
        }
    } catch {}
    try {
        if ($null -ne $global:LiteDeployStateMemoryMap) {
            $global:LiteDeployStateMemoryMap.Dispose()
        }
    } catch {}
    $global:LiteDeployStateMemoryAccessor = $null
    $global:LiteDeployStateMemoryMap = $null
}

function Write-LiteDeployStateToMemory {
    <#
    .SYNOPSIS
        Publishes credential-free state JSON into a named memory-mapped region (RAM IPC for Progress).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Json
    )

    if ([string]::IsNullOrWhiteSpace($Json)) { return $false }

    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
        $needed = 4 + $bytes.Length
        if ($needed -gt $global:LiteDeployStateMemoryMapCapacity) {
            Write-LiteDeployStateLog -Message "State JSON exceeds RAM map capacity ($needed > $($global:LiteDeployStateMemoryMapCapacity))." -Level "WARNING"
            return $false
        }

        if ($null -eq $global:LiteDeployStateMemoryMap) {
            $global:LiteDeployStateMemoryMap = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateOrOpen(
                $global:LiteDeployStateMemoryMapName,
                [long]$global:LiteDeployStateMemoryMapCapacity
            )
            $global:LiteDeployStateMemoryAccessor = $global:LiteDeployStateMemoryMap.CreateViewAccessor(0, [long]$global:LiteDeployStateMemoryMapCapacity)
        }

        $accessor = $global:LiteDeployStateMemoryAccessor
        $accessor.Write(0, [int]$bytes.Length)
        $accessor.WriteArray(4, $bytes, 0, $bytes.Length)
        return $true
    }
    catch {
        Write-LiteDeployStateLog -Message "Could not publish state to RAM map: $($_.Exception.Message)" -Level "WARNING" -NoConsole
        return $false
    }
}

function Read-LiteDeployStateFromMemory {
    <#
    .SYNOPSIS
        Reads the latest state JSON from the named RAM map (Progress / secondary readers).
    #>
    param(
        [string]$MapName = ""
    )

    if ([string]::IsNullOrWhiteSpace($MapName)) {
        $MapName = $global:LiteDeployStateMemoryMapName
    }

    $mmf = $null
    $accessor = $null
    try {
        $mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting($MapName)
        $accessor = $mmf.CreateViewAccessor(0, [long]$global:LiteDeployStateMemoryMapCapacity)
        $length = $accessor.ReadInt32(0)
        if ($length -le 0 -or $length -gt ($global:LiteDeployStateMemoryMapCapacity - 4)) {
            return ""
        }
        $buffer = New-Object byte[] $length
        $read = $accessor.ReadArray(4, $buffer, 0, $length)
        if ($read -le 0) { return "" }
        return [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    }
    catch {
        return ""
    }
    finally {
        if ($null -ne $accessor) { try { $accessor.Dispose() } catch {} }
        if ($null -ne $mmf) { try { $mmf.Dispose() } catch {} }
    }
}

# ==============================================================================
# 7. SERIALIZATION, PERSISTENCE & FILE I/O
# ==============================================================================

function ConvertTo-LiteDeploySerializableObject {
    <#
    .SYNOPSIS
        Builds a credential-free, JSON-safe copy of an object graph (the original is never modified).
    #>
    param(
        $InputObject,
        [int]$Depth = 0
    )

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Security.SecureString] -or
        $InputObject -is [System.Management.Automation.PSCredential] -or
        $InputObject -is [System.Net.NetworkCredential]) {
        return $null
    }

    if ($InputObject -is [string] -or $InputObject -is [bool]) { return $InputObject }
    if ($InputObject -is [char]) { return [string]$InputObject }
    if ($InputObject -is [datetime]) { return $InputObject.ToString("o") }
    if ($InputObject -is [System.Enum]) { return $InputObject.ToString() }

    $inputType = $InputObject.GetType()
    if ($inputType.IsPrimitive -or $InputObject -is [decimal]) { return $InputObject }
    if ($InputObject -is [System.ValueType]) { return $InputObject.ToString() }

    if ($Depth -ge $global:LiteDeployStateMaxDepth) { return "[truncated]" }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $dictOut = [ordered]@{}
        foreach ($key in @($InputObject.Keys)) {
            $keyName = [string]$key
            if ($keyName -match $global:LiteDeployStateSensitiveNamePattern) { continue }
            if ($keyName -in @('RegisteredOrganization', 'RegisteredOwner', 'JoinWorkGroup', 'JoinWorkgroup', 'JoinDomain', 'MachineObjectOU') -and
                [string]::IsNullOrWhiteSpace([string]$InputObject[$key])) { continue }
            $dictOut[$keyName] = ConvertTo-LiteDeploySerializableObject -InputObject $InputObject[$key] -Depth ($Depth + 1)
        }
        return $dictOut
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($item in $InputObject) {
            $items.Add((ConvertTo-LiteDeploySerializableObject -InputObject $item -Depth ($Depth + 1)))
        }
        return ,($items.ToArray())
    }

    $isPropertyBag = ($InputObject -is [System.Management.Automation.PSCustomObject])
    if (-not $isPropertyBag) {
        $typeNames = @($InputObject.PSObject.TypeNames)
        if ($typeNames.Count -gt 0 -and ([string]$typeNames[0]) -like 'Deserialized*') {
            $isPropertyBag = $true
        }
    }

    if ($isPropertyBag) {
        $objOut = [ordered]@{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            if ($prop.Name -match $global:LiteDeployStateSensitiveNamePattern) { continue }
            $propValue = $null
            try { $propValue = $prop.Value } catch { $propValue = $null }
            if ($prop.Name -in @('RegisteredOrganization', 'RegisteredOwner', 'JoinWorkGroup', 'JoinWorkgroup', 'JoinDomain', 'MachineObjectOU') -and
                [string]::IsNullOrWhiteSpace([string]$propValue)) { continue }
            $objOut[$prop.Name] = ConvertTo-LiteDeploySerializableObject -InputObject $propValue -Depth ($Depth + 1)
        }
        return $objOut
    }

    return [string]$InputObject
}

function Write-LiteDeployStateFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -Path $directory -ItemType Directory -Force
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $tempPath = "$Path.tmp"
    try {
        [System.IO.File]::WriteAllText($tempPath, $Content, $utf8)
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    catch {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        [System.IO.File]::WriteAllText($Path, $Content, $utf8)
    }
}

function Read-LiteDeployStateFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $stream = $null
    $reader = $null
    $raw = ""
    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $raw = $reader.ReadToEnd()
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }

    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json -ErrorAction Stop)
}

function Get-LiteDeployStateNextPhase {
    param($State)

    $preCheck = Get-LiteDeployStateProperty -InputObject $State -Name "HardwarePreCheck"
    if (-not [bool](Get-LiteDeployStateProperty -InputObject $preCheck -Name "Passed" -Default $false)) { return 1 }

    $workflow = Get-LiteDeployStateProperty -InputObject $State -Name "Workflow"
    if (-not [bool](Get-LiteDeployStateProperty -InputObject $workflow -Name "Confirmed" -Default $false)) { return 2 }

    $disk = Get-LiteDeployStateProperty -InputObject $State -Name "Disk"
    if (-not [bool](Get-LiteDeployStateProperty -InputObject $disk -Name "Formatted" -Default $false)) { return 3 }

    $osInstall = Get-LiteDeployStateProperty -InputObject $State -Name "OSInstall"
    if (-not [bool](Get-LiteDeployStateProperty -InputObject $osInstall -Name "Applied" -Default $false)) { return 4 }

    return 5
}

# ==============================================================================
# 8. DEPLOYMENT OBJECT & LIFECYCLE
# ==============================================================================

function New-LiteDeployDeploymentObject {
    <#
    .SYNOPSIS
        Creates the deployment state object (structure identical to the Engine's).
    #>
    param(
        [string]$Uid = "",
        [psobject]$BootCtx = $null,
        [string]$RemoteLogDir = "",
        [switch]$DeferUid
    )

    if (-not $DeferUid -and [string]::IsNullOrWhiteSpace($Uid)) { $Uid = New-LiteDeployStateUid }

    $sysDrive = Get-LiteDeployStateSystemDrive
    $localLogDir = Join-Path $sysDrive "~LiteDeploy\WorkLogs"

    return [PSCustomObject]@{
        DeploymentUid = $Uid
        Status        = "Initializing"
        CurrentPhase  = 0
        StartTime     = (Get-LiteDeployStateTimestamp)
        EndTime       = $null
        BootObject    = $BootCtx
        LogLocations  = [PSCustomObject]@{
            LocalLogDir               = $localLogDir
            RemoteLogDir              = $RemoteLogDir
            LocalExecutionLog         = (Join-Path $localLogDir "LiteDeploy.Execution.log")
            RemoteExecutionLog        = if ($RemoteLogDir) { Join-Path $RemoteLogDir "LiteDeploy.Execution.log" } else { "" }
            LocalDeploymentState      = (Join-Path $sysDrive "~LiteDeploy\DeploymentState.json")
            RemoteDeploymentState     = if ($RemoteLogDir) { Join-Path $RemoteLogDir "DeploymentState.json" } else { "" }
            OfflineOsRoot             = ""
            OfflineOsLogDir           = ""
            OfflineOsDeploymentState  = ""
        }
        HardwarePreCheck      = [PSCustomObject]@{
            Passed        = $false
            CompletedTime = $null
        }
        Workflow      = [PSCustomObject]@{
            Confirmed     = $false
            SelectionData = $null
            CompletedTime = $null
        }
        Disk          = [PSCustomObject]@{
            Formatted               = $false
            DiskNumber              = $null
            BootMode                = $null
            OSPartitionNumber       = $null
            OSDriveLetter           = $null
            SystemPartitionNumber   = $null
            RecoveryPartitionNumber = $null
            TotalSizeGB             = $null
            CompletedTime           = $null
        }
        OSInstall     = [PSCustomObject]@{
            StartedTime     = $null
            CompletedTime   = $null
            Engine          = "Setup.exe"
            SetupPath       = $null
            ImagePath       = $null
            ImageIndex      = $null
            UnattendPath    = $null
            Applied         = $false
            ExitCode        = $null
            DurationSeconds = 0
        }
        Execution     = [PSCustomObject]@{
            CurrentStep     = "Initialized"
            PercentComplete = 0
            LocalLogDir     = $localLogDir
            RemoteLogDir    = $RemoteLogDir
            Errors          = @()
        }
        Ui            = [PSCustomObject]@{
            Theme = "Light"
        }
    }
}

function Save-LiteDeployDeploymentState {
    <#
    .SYNOPSIS
        Serializes deployment state to DeploymentState.json (local), RAM memory-map IPC,
        and mirrors it to the share log dir and offline OS volume.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$DeploymentState,

        [Parameter(Mandatory = $false)]
        [string]$Path = "",

        [Parameter(Mandatory = $false)]
        [switch]$NoRemote,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    $result = [PSCustomObject]@{
        Saved       = $false
        LocalPath   = ""
        RemoteSaved = $false
        RemotePath  = ""
        OsSaved     = $false
        OsPath      = ""
        Error       = ""
    }

    $json = $null
    try {
        $safeState = ConvertTo-LiteDeploySerializableObject -InputObject $DeploymentState
        $json = $safeState | ConvertTo-Json -Depth 10
    }
    catch {
        $result.Error = "Serialization failed: $($_.Exception.Message)"
        Write-LiteDeployStateLog -Message "Could not serialize deployment state: $($_.Exception.Message)" -Level "WARNING"
    }

    if ($null -ne $json) {
        # Primary live feed for Progress: named memory map (RAM IPC).
        $null = Write-LiteDeployStateToMemory -Json $json

        # 1) Local RAM / system drive
        $localPath = if ([string]::IsNullOrWhiteSpace($Path)) { Get-LiteDeployStateFilePath } else { $Path }
        $result.LocalPath = $localPath
        try {
            Write-LiteDeployStateFile -Path $localPath -Content $json
            $result.Saved = $true
        }
        catch {
            $result.Error = "Local write failed: $($_.Exception.Message)"
            Write-LiteDeployStateLog -Message "Could not write deployment state to '$localPath': $($_.Exception.Message)" -Level "WARNING"
        }

        # 2) Deployment share / media
        if (-not $NoRemote) {
            try {
                $remoteDir = Get-LiteDeployStateRemoteDirectory -State $DeploymentState
                if ($remoteDir -and (Test-Path -LiteralPath $remoteDir -ErrorAction SilentlyContinue)) {
                    $remotePath = Join-Path $remoteDir $global:LiteDeployStateFileName
                    $result.RemotePath = $remotePath
                    Write-LiteDeployStateFile -Path $remotePath -Content $json
                    $result.RemoteSaved = $true
                }
            }
            catch {
                Write-LiteDeployStateLog -Message "Could not mirror deployment state to the share: $($_.Exception.Message)" -Level "WARNING" -NoConsole
            }
        }

        # 3) Windows OS volume (W:\~LiteDeploy\DeploymentState.json) when mounted
        try {
            $osPaths = Get-LiteDeployStateOsPaths -State $DeploymentState
            if ($osPaths.StatePath) {
                $osParent = Split-Path -Parent $osPaths.StatePath
                if ($osParent -and -not (Test-Path -LiteralPath $osParent -ErrorAction SilentlyContinue)) {
                    $null = New-Item -Path $osParent -ItemType Directory -Force -ErrorAction SilentlyContinue
                }
                if ($osParent -and (Test-Path -LiteralPath $osParent -ErrorAction SilentlyContinue)) {
                    Write-LiteDeployStateFile -Path $osPaths.StatePath -Content $json
                    $result.OsPath = $osPaths.StatePath
                    $result.OsSaved = $true
                }
            }
        }
        catch {
            Write-LiteDeployStateLog -Message "Could not mirror deployment state to the OS volume: $($_.Exception.Message)" -Level "WARNING" -NoConsole
        }
    }

    if ($PassThru) { return $result }
}

function Get-LiteDeployState {
    <#
    .SYNOPSIS
        Returns the deployment state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Path = "",

        [Parameter(Mandatory = $false)]
        [switch]$FromFile
    )

    $targetPath = $Path
    if ([string]::IsNullOrWhiteSpace($targetPath)) {
        if (-not $FromFile) {
            $live = Get-LiteDeployLiveState
            if ($null -ne $live) { return $live }
        }
        $targetPath = Get-LiteDeployStateFilePath
    }

    try {
        $state = Read-LiteDeployStateFile -Path $targetPath
        if ($null -eq $state) {
            Write-Verbose "No deployment state found at '$targetPath'."
            return $null
        }
        return $state
    }
    catch {
        Write-LiteDeployStateLog -Message "Could not read deployment state '$targetPath': $($_.Exception.Message)" -Level "WARNING"
        return $null
    }
}

function Update-LiteDeployState {
    <#
    .SYNOPSIS
        Patches the deployment state and (by default) saves it. Alias: Set-LiteDeployState.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [psobject]$State = $null,

        [Parameter(Mandatory = $false)]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [int]$CurrentPhase,

        [Parameter(Mandatory = $false)]
        [string]$CurrentStep,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 100)]
        [int]$PercentComplete,

        [Parameter(Mandatory = $false)]
        [string[]]$AddError,

        [Parameter(Mandatory = $false)]
        [hashtable]$Property,

        [Parameter(Mandatory = $false)]
        [switch]$NoSave,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    $target = $State
    if ($null -eq $target) { $target = Get-LiteDeployLiveState }
    if ($null -eq $target) { $target = Get-LiteDeployState -FromFile }
    if ($null -eq $target) {
        throw "Update-LiteDeployState: no deployment state is available (supply -State or load one with Get-LiteDeployState/Resume-LiteDeployState)."
    }

    if ($PSBoundParameters.ContainsKey('Status')) {
        Set-LiteDeployStateValue -Object $target -Path "Status" -Value $Status
        if ($global:LiteDeployStateTerminalStatuses -contains $Status) {
            $existingEnd = Get-LiteDeployStateProperty -InputObject $target -Name "EndTime"
            if ([string]::IsNullOrWhiteSpace([string]$existingEnd)) {
                Set-LiteDeployStateValue -Object $target -Path "EndTime" -Value (Get-LiteDeployStateTimestamp)
            }
        }
    }
    if ($PSBoundParameters.ContainsKey('CurrentPhase')) {
        Set-LiteDeployStateValue -Object $target -Path "CurrentPhase" -Value $CurrentPhase
    }
    if ($PSBoundParameters.ContainsKey('CurrentStep')) {
        Set-LiteDeployStateValue -Object $target -Path "Execution.CurrentStep" -Value $CurrentStep
    }
    if ($PSBoundParameters.ContainsKey('PercentComplete')) {
        Set-LiteDeployStateValue -Object $target -Path "Execution.PercentComplete" -Value $PercentComplete
    }

    if ($PSBoundParameters.ContainsKey('AddError') -and $null -ne $AddError) {
        $execution = Get-LiteDeployStateProperty -InputObject $target -Name "Execution"
        $errorList = New-Object System.Collections.Generic.List[string]
        foreach ($existing in @(Get-LiteDeployStateProperty -InputObject $execution -Name "Errors" -Default @())) {
            if ($null -ne $existing) { $errorList.Add([string]$existing) }
        }
        foreach ($newError in $AddError) {
            if (-not [string]::IsNullOrWhiteSpace($newError)) {
                $errorList.Add((Protect-LiteDeployStateText -Text $newError))
            }
        }
        Set-LiteDeployStateValue -Object $target -Path "Execution.Errors" -Value ($errorList.ToArray())
    }

    if ($PSBoundParameters.ContainsKey('Property') -and $null -ne $Property) {
        foreach ($key in @($Property.Keys)) {
            Set-LiteDeployStateValue -Object $target -Path ([string]$key) -Value $Property[$key]
        }
    }

    if (-not $NoSave) {
        Save-LiteDeployDeploymentState -DeploymentState $target
    }

    if ($PassThru) { return $target }
}

function Resume-LiteDeployState {
    <#
    .SYNOPSIS
        Locates, validates, and re-activates a saved deployment state so the pipeline can continue.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path = "",

        [Parameter(Mandatory = $false)]
        [string]$DeploymentUid = "",

        [Parameter(Mandatory = $false)]
        [psobject]$BootObject = $null,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [switch]$NoActivate,

        [Parameter(Mandatory = $false)]
        [switch]$NoSave
    )

    $result = [PSCustomObject]@{
        Resumed         = $false
        Reason          = ""
        State           = $null
        Path            = ""
        DeploymentUid   = ""
        PreviousStatus  = ""
        Status          = ""
        CurrentPhase    = 0
        NextPhase       = 0
        NextPhaseName   = ""
        CompletedPhases = @()
        ResumeCount     = 0
    }

    $liveBoot = $BootObject
    if ($null -eq $liveBoot) {
        $liveBoot = Get-Variable -Name LiteDeployBootObject -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    }

    # ---- Build candidate list ------------------------------------------------
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $candidates.Add($Path)
    }
    else {
        $candidates.Add((Get-LiteDeployStateFilePath))

        $liveState = Get-LiteDeployLiveState
        if ($null -ne $liveState) {
            $liveRemote = Get-LiteDeployStateRemoteDirectory -State $liveState
            if ($liveRemote) { $candidates.Add((Join-Path $liveRemote $global:LiteDeployStateFileName)) }
        }

        if (-not [string]::IsNullOrWhiteSpace($DeploymentUid)) {
            $drive = [string](Get-LiteDeployStateProperty -InputObject $liveBoot -Name "DriveLetter" -Default "Z:")
            $drive = $drive.TrimEnd('\')
            $localRoot = [string](Get-LiteDeployStateProperty -InputObject $liveBoot -Name "LocalRootName" -Default "~LiteDeploy")
            $candidates.Add(("{0}\WorkLogs\Deployments\{1}\{2}" -f $drive, $DeploymentUid, $global:LiteDeployStateFileName))
            $candidates.Add(("{0}\{1}\WorkLogs\Deployments\{2}\{3}" -f $drive, $localRoot, $DeploymentUid, $global:LiteDeployStateFileName))
        }
    }

    $existing = @(
        $candidates | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf -ErrorAction SilentlyContinue } |
            ForEach-Object { Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue } |
            Sort-Object -Property LastWriteTime -Descending
    )

    if ($existing.Count -eq 0) {
        $result.Reason = "No saved deployment state file was found."
        return $result
    }

    # ---- Pick the newest valid candidate ------------------------------------
    $chosen = $null
    $chosenPath = ""
    $rejections = New-Object System.Collections.Generic.List[string]
    foreach ($file in $existing) {
        $loaded = $null
        try { $loaded = Read-LiteDeployStateFile -Path $file.FullName }
        catch {
            $rejections.Add("'$($file.FullName)' is not valid JSON")
            continue
        }
        if ($null -eq $loaded) {
            $rejections.Add("'$($file.FullName)' is empty")
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($DeploymentUid)) {
            $loadedUid = [string](Get-LiteDeployStateProperty -InputObject $loaded -Name "DeploymentUid" -Default "")
            if ($loadedUid -ine $DeploymentUid) {
                $rejections.Add("'$($file.FullName)' belongs to deployment '$loadedUid'")
                continue
            }
        }

        $check = Test-LiteDeployState -State $loaded -Persisted -Detailed
        if (-not $check.IsValid) {
            $rejections.Add("'$($file.FullName)' failed validation: " + ($check.Errors -join "; "))
            continue
        }

        $chosen = $loaded
        $chosenPath = $file.FullName
        break
    }

    if ($null -eq $chosen) {
        $result.Reason = "No valid deployment state found. " + ($rejections -join " | ")
        return $result
    }

    $uid = [string](Get-LiteDeployStateProperty -InputObject $chosen -Name "DeploymentUid" -Default "")
    $previousStatus = [string](Get-LiteDeployStateProperty -InputObject $chosen -Name "Status" -Default "")
    $result.Path = $chosenPath
    $result.DeploymentUid = $uid
    $result.PreviousStatus = $previousStatus
    $result.Status = $previousStatus
    $result.State = $chosen

    if ($previousStatus -eq "Completed" -and -not $Force) {
        $result.Reason = "Deployment '$uid' already completed; use -Force to resume anyway."
        return $result
    }

    # ---- Work out where to continue -----------------------------------------
    $nextPhase = Get-LiteDeployStateNextPhase -State $chosen
    $completed = New-Object System.Collections.Generic.List[string]
    for ($p = 1; $p -lt $nextPhase; $p++) { $completed.Add([string]$global:LiteDeployStatePhaseNames[$p]) }

    # ---- Re-attach live context and rewind terminal status -------------------
    if ($null -ne $liveBoot) {
        Set-LiteDeployStateMember -Target $chosen -Name "BootObject" -Value $liveBoot
    }

    if ($global:LiteDeployStateTerminalStatuses -contains $previousStatus) {
        Set-LiteDeployStateValue -Object $chosen -Path "EndTime" -Value $null
        if ($previousStatus -ne "Completed") {
            Set-LiteDeployStateValue -Object $chosen -Path "Status" -Value ([string]$global:LiteDeployStatePhaseStatus[$nextPhase])
        }
    }
    if ($nextPhase -le 4) {
        Set-LiteDeployStateValue -Object $chosen -Path "CurrentPhase" -Value $nextPhase
    }

    $execution = Get-LiteDeployStateProperty -InputObject $chosen -Name "Execution"
    $resumeCount = 0
    $parsedCount = 0
    if ([int]::TryParse([string](Get-LiteDeployStateProperty -InputObject $execution -Name "ResumeCount" -Default 0), [ref]$parsedCount)) {
        $resumeCount = $parsedCount
    }
    $resumeCount++
    Set-LiteDeployStateValue -Object $chosen -Path "Execution.ResumeCount" -Value $resumeCount
    Set-LiteDeployStateValue -Object $chosen -Path "Execution.LastResumedTime" -Value (Get-LiteDeployStateTimestamp)
    Set-LiteDeployStateValue -Object $chosen -Path "Execution.ResumedFromStatus" -Value $previousStatus

    # ---- Activate -------------------------------------------------------------
    if (-not $NoActivate) {
        $global:LiteDeployDeployment = $chosen
        $remoteDir = Get-LiteDeployStateRemoteDirectory -State $chosen
        if ($remoteDir -and (Test-Path -LiteralPath $remoteDir -ErrorAction SilentlyContinue)) {
            $global:LiteDeployRemoteLogDir = $remoteDir
        }
    }

    if (-not $NoSave) {
        Save-LiteDeployDeploymentState -DeploymentState $chosen
    }

    $result.Resumed = $true
    $result.Reason = "Resumed at phase $nextPhase ($($global:LiteDeployStatePhaseNames[$nextPhase]))."
    $result.State = $chosen
    $result.Status = [string](Get-LiteDeployStateProperty -InputObject $chosen -Name "Status" -Default "")
    $result.CurrentPhase = [int](Get-LiteDeployStateProperty -InputObject $chosen -Name "CurrentPhase" -Default 0)
    $result.NextPhase = $nextPhase
    $result.NextPhaseName = [string]$global:LiteDeployStatePhaseNames[$nextPhase]
    $result.CompletedPhases = $completed.ToArray()
    $result.ResumeCount = $resumeCount

    Write-LiteDeployStateLog -Message "Resumed deployment $uid at phase $nextPhase ($($result.NextPhaseName)); previous status '$previousStatus'." -Level "INFO"
    return $result
}

function Test-LiteDeployState {
    <#
    .SYNOPSIS
        Validates a deployment state object or state file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [psobject]$State = $null,

        [Parameter(Mandatory = $false)]
        [string]$Path = "",

        [Parameter(Mandatory = $false)]
        [switch]$Persisted,

        [Parameter(Mandatory = $false)]
        [switch]$Detailed
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $source = "InputObject"
    $subject = $State
    $fromFile = [bool]$Persisted

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $source = $Path
        $fromFile = $true
        try {
            $subject = Read-LiteDeployStateFile -Path $Path
            if ($null -eq $subject) { $errors.Add("State file '$Path' was not found or is empty.") }
        }
        catch {
            $subject = $null
            $errors.Add("State file '$Path' is not valid JSON: $($_.Exception.Message)")
        }
    }
    elseif ($null -eq $subject) {
        $subject = Get-LiteDeployState
        $source = "CurrentState"
        if ($null -eq $subject) { $errors.Add("No deployment state is available.") }
    }

    if ($null -ne $subject) {
        $required = @("DeploymentUid", "Status", "CurrentPhase", "StartTime", "LogLocations",
                      "HardwarePreCheck", "Workflow", "Disk", "OSInstall", "Execution")
        foreach ($name in $required) {
            if (-not (Test-LiteDeployStateHasProperty -InputObject $subject -Name $name)) {
                $errors.Add("Missing property '$name'.")
            }
        }

        $sections = @{
            HardwarePreCheck = "Passed"
            Workflow         = "Confirmed"
            Disk             = "Formatted"
            OSInstall        = "Applied"
            Execution        = "CurrentStep"
        }
        foreach ($sectionName in $sections.Keys) {
            $section = Get-LiteDeployStateProperty -InputObject $subject -Name $sectionName
            if ($null -ne $section -and -not (Test-LiteDeployStateHasProperty -InputObject $section -Name $sections[$sectionName])) {
                $errors.Add("Missing property '$sectionName.$($sections[$sectionName])'.")
            }
        }

        $uidValue = [string](Get-LiteDeployStateProperty -InputObject $subject -Name "DeploymentUid" -Default "")
        if (Test-LiteDeployStateHasProperty -InputObject $subject -Name "DeploymentUid") {
            if ([string]::IsNullOrWhiteSpace($uidValue)) { $errors.Add("DeploymentUid is empty.") }
        }

        $statusValue = [string](Get-LiteDeployStateProperty -InputObject $subject -Name "Status" -Default "")
        if ($statusValue -and ($global:LiteDeployStateKnownStatuses -notcontains $statusValue)) {
            $warnings.Add("Unrecognized Status '$statusValue'.")
        }

        $phaseRaw = Get-LiteDeployStateProperty -InputObject $subject -Name "CurrentPhase"
        if ($null -ne $phaseRaw) {
            $phaseParsed = 0
            if (-not [int]::TryParse([string]$phaseRaw, [ref]$phaseParsed) -or $phaseParsed -lt 0 -or $phaseParsed -gt 9) {
                $errors.Add("CurrentPhase '$phaseRaw' is not an integer between 0 and 9.")
            }
        }

        $startRaw = [string](Get-LiteDeployStateProperty -InputObject $subject -Name "StartTime" -Default "")
        if ($startRaw) {
            $startParsed = [datetime]::MinValue
            if (-not [datetime]::TryParse($startRaw, [ref]$startParsed)) {
                $warnings.Add("StartTime '$startRaw' is not a parseable date.")
            }
        }

        $execution = Get-LiteDeployStateProperty -InputObject $subject -Name "Execution"
        $percentRaw = Get-LiteDeployStateProperty -InputObject $execution -Name "PercentComplete"
        if ($null -ne $percentRaw) {
            $percentParsed = 0.0
            if (-not [double]::TryParse([string]$percentRaw, [ref]$percentParsed) -or $percentParsed -lt 0 -or $percentParsed -gt 100) {
                $errors.Add("Execution.PercentComplete '$percentRaw' is not a number between 0 and 100.")
            }
        }

        # Credentials must never be persisted.
        $boot = Get-LiteDeployStateProperty -InputObject $subject -Name "BootObject"
        $credential = Get-LiteDeployStateProperty -InputObject $boot -Name "Credential"
        if ($null -ne $credential) {
            if ($fromFile) { $errors.Add("Persisted state contains BootObject.Credential (credentials must never be written to disk).") }
            else { $warnings.Add("BootObject.Credential is present in memory; it is omitted when the state is saved.") }
        }
    }

    $isValid = ($errors.Count -eq 0)
    if (-not $Detailed) { return $isValid }

    return [PSCustomObject]@{
        IsValid  = $isValid
        Errors   = $errors.ToArray()
        Warnings = $warnings.ToArray()
        Source   = $source
    }
}

function Get-DeploymentStateFromFile {
    <#
    .SYNOPSIS
        Compatibility reader for the Progress UI: returns a UI-state hashtable built from a state file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Path = "",

        [Parameter(Mandatory = $false, Position = 1)]
        [hashtable]$DefaultState = $null
    )

    $state = if ($null -ne $DefaultState) { $DefaultState.Clone() } else { @{} }

    $targetPath = $Path
    if ([string]::IsNullOrWhiteSpace($targetPath)) { $targetPath = Get-LiteDeployStateFilePath }
    if (-not [System.IO.Path]::IsPathRooted($targetPath)) {
        $targetPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($targetPath)
    }

    try {
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) { return $state }

        $stream = $null
        $reader = $null
        $raw = ""
        try {
            $stream = New-Object System.IO.FileStream($targetPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            $raw = $reader.ReadToEnd()
        }
        finally {
            if ($null -ne $reader) { $reader.Dispose() }
            elseif ($null -ne $stream) { $stream.Dispose() }
        }
        if ([string]::IsNullOrWhiteSpace($raw)) { return $state }

        if ($raw -match '"Computer Model"') {
            $raw = $raw -replace '"Computer Model"\s*:', '"computerModel":'
        }
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $data) { return $state }

        if (Test-LiteDeployStateHasProperty -InputObject $data -Name "DeploymentUid") {
            # ---- Full DeploymentState.json schema -> UI keys ----
            $state['DeploymentId'] = [string](Get-LiteDeployStateProperty -InputObject $data -Name "DeploymentUid" -Default "")

            $status = Get-LiteDeployStateProperty -InputObject $data -Name "Status"
            if ($null -ne $status) { $state['Status'] = [string]$status }

            $phaseParsed = 0
            if ([int]::TryParse([string](Get-LiteDeployStateProperty -InputObject $data -Name "CurrentPhase" -Default 0), [ref]$phaseParsed) -and
                $global:LiteDeployStatePhaseNames.ContainsKey($phaseParsed)) {
                $state['Phase'] = [string]$global:LiteDeployStatePhaseNames[$phaseParsed]
            }

            $execution = Get-LiteDeployStateProperty -InputObject $data -Name "Execution"
            $step = Get-LiteDeployStateProperty -InputObject $execution -Name "CurrentStep"
            if ($null -ne $step) { $state['CurrentStep'] = [string]$step }

            $percentParsed = 0
            if ([int]::TryParse([string](Get-LiteDeployStateProperty -InputObject $execution -Name "PercentComplete"), [ref]$percentParsed)) {
                $state['OverallPercent'] = $percentParsed
            }

            $errorList = @(Get-LiteDeployStateProperty -InputObject $execution -Name "Errors" -Default @())
            if ($errorList.Count -gt 0) {
                $state['Message'] = Protect-LiteDeployStateText -Text ([string]$errorList[$errorList.Count - 1])
            }

            $workflow = Get-LiteDeployStateProperty -InputObject $data -Name "Workflow"
            $selection = Get-LiteDeployStateProperty -InputObject $workflow -Name "SelectionData"
            $workflowName = Get-LiteDeployStateProperty -InputObject $selection -Name "WorkflowName"
            if ($null -ne $workflowName) {
                $state['WorkflowName'] = [string]$workflowName
                $state['OperatingSystem'] = [string]$workflowName
            }
            $computerName = Get-LiteDeployStateProperty -InputObject $selection -Name "ComputerName"
            if ($null -ne $computerName) { $state['ComputerName'] = [string]$computerName }

            $boot = Get-LiteDeployStateProperty -InputObject $data -Name "BootObject"
            if ($null -ne $boot) {
                $isWinPE = Get-LiteDeployStateProperty -InputObject $boot -Name "IsWinPE"
                if ($null -ne $isWinPE) { $state['Environment'] = if ([bool]$isWinPE) { "WinPE" } else { "FullOS" } }
                $deployType = [string](Get-LiteDeployStateProperty -InputObject $boot -Name "DeploymentType" -Default "")
                if ($deployType -ieq "Network") { $state['Source'] = "Network Share" }
                elseif ($deployType -ieq "Media") { $state['Source'] = "Local (Media) Repository" }
            }
        }
        else {
            # ---- Progress schema (camelCase) -> UI keys ----
            $stringMap = [ordered]@{
                WindowTitle     = "windowTitle"
                ProductName     = "productName"
                WorkflowName    = "workflowName"
                Environment     = "environment"
                Status          = "status"
                Phase           = "phase"
                CurrentStep     = "currentStep"
                Message         = "message"
                LogMessage      = "logMessage"
                DeploymentId    = "deploymentId"
                ComputerName    = "computerName"
                ComputerModel   = "computerModel"
                OperatingSystem = "operatingSystem"
                Source          = "source"
            }
            foreach ($uiKey in $stringMap.Keys) {
                $value = Get-LiteDeployStateProperty -InputObject $data -Name $stringMap[$uiKey]
                if (($null -eq $value) -and $uiKey -eq "Source") {
                    $value = Get-LiteDeployStateProperty -InputObject $data -Name "repository"
                }
                if ($null -ne $value -and -not [string]::IsNullOrEmpty([string]$value)) { $state[$uiKey] = [string]$value }
            }

            $intMap = [ordered]@{ StepPercent = "stepPercent"; OverallPercent = "overallPercent" }
            foreach ($uiKey in $intMap.Keys) {
                $intParsed = 0
                $intRaw = Get-LiteDeployStateProperty -InputObject $data -Name $intMap[$uiKey]
                if ($null -ne $intRaw -and [int]::TryParse([string]$intRaw, [ref]$intParsed)) { $state[$uiKey] = $intParsed }
            }

            $overallText = [string](Get-LiteDeployStateProperty -InputObject $data -Name "overallText" -Default "")
            if ($overallText -match '(?:Action|Step)\s+(\d+)\s+of\s+(\d+)') {
                $state['StepNumber'] = [int]$Matches[1]
                $state['TotalSteps'] = [int]$Matches[2]
            }
        }
    }
    catch {
        # Compatibility reader: unreadable input yields defaults
    }

    return $state
}

# Aliases
Set-Alias -Name Save-LiteDeployState -Value Save-LiteDeployDeploymentState
Set-Alias -Name Set-LiteDeployState -Value Update-LiteDeployState

# ==============================================================================
# 9. ARTIFACT SYNCHRONIZATION AND OS HANDOFF
# ==============================================================================

function Initialize-LiteDeployDeploymentShareLogDir {
    param(
        [Parameter(Mandatory = $true)][psobject]$RuntimePaths,
        [Parameter(Mandatory = $true)][string]$DeploymentUid
    )

    $deploymentLogDirectory = Join-Path $RuntimePaths.DeploymentLogRoot $DeploymentUid
    $localLogDir = if ($RuntimePaths -and $RuntimePaths.PSObject.Properties['LocalLogDirectory'] -and $RuntimePaths.LocalLogDirectory) {
        [string]$RuntimePaths.LocalLogDirectory
    } else { "" }

    try {
        $null = New-Item -Path $deploymentLogDirectory -ItemType Directory -Force -ErrorAction Stop
        Sync-LiteDeployLogsToShare -RuntimePaths $RuntimePaths -RemoteLogDir $deploymentLogDirectory
        Write-LiteDeployLog "Deployment logs: $deploymentLogDirectory" -Level SUCCESS -Component "Session" -LogPath $localLogDir
        return $deploymentLogDirectory
    }
    catch {
        Write-LiteDeployLog "Cannot write deployment logs to '$deploymentLogDirectory': $_. Local logs remain at '$($RuntimePaths.LocalLogDirectory)'." -Level WARNING -Component "Session" -LogPath $localLogDir
        return $null
    }
}

function Sync-LiteDeployLogsToShare {
    param(
        [Parameter(Mandatory = $true)][psobject]$RuntimePaths,
        [string]$RemoteLogDir
    )

    if ([string]::IsNullOrWhiteSpace($RemoteLogDir)) {
        return
    }

    if (-not (Test-Path -LiteralPath $RemoteLogDir -ErrorAction SilentlyContinue)) {
        Write-LiteDeployLog "Warning: Remote deployment log directory '$RemoteLogDir' is inaccessible. Share log sync skipped." -Level WARNING -Component "Session"
        return
    }

    if (Get-Variable -Name InSyncLiteDeployLogsToShare -Scope Script -ValueOnly -ErrorAction SilentlyContinue) { return }
    $script:InSyncLiteDeployLogsToShare = $true
    $firstCopyError = $null

    try {
        $localLogDir = $RuntimePaths.LocalLogDirectory
        if (Test-Path -LiteralPath $localLogDir) {
            Get-ChildItem -Path $localLogDir -File -Filter "LiteDeploy.*" -ErrorAction SilentlyContinue | ForEach-Object {
                $targetFile = Join-Path $RemoteLogDir $_.Name
                try {
                    Copy-Item -LiteralPath $_.FullName -Destination $targetFile -Force -ErrorAction Stop
                }
                catch {
                    if (-not $firstCopyError) {
                        $firstCopyError = "Failed to copy '$($_.Name)' to '$RemoteLogDir': $($_.Exception.Message)"
                    }
                }
            }

            foreach ($subfolder in @('Setup', 'Dism')) {
                $localSub = Join-Path $localLogDir $subfolder
                if (Test-Path -LiteralPath $localSub -PathType Container) {
                    $remoteSub = Join-Path $RemoteLogDir $subfolder
                    if (-not (Test-Path -LiteralPath $remoteSub -PathType Container)) {
                        try {
                            $null = New-Item -Path $remoteSub -ItemType Directory -Force -ErrorAction Stop
                        }
                        catch {
                            if (-not $firstCopyError) {
                                $firstCopyError = "Failed to create directory '$remoteSub': $($_.Exception.Message)"
                            }
                            continue
                        }
                    }
                    Get-ChildItem -LiteralPath $localSub -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                        $relPath = $_.FullName.Substring($localSub.Length).TrimStart('\', '/')
                        $destFile = Join-Path $remoteSub $relPath
                        $destParent = Split-Path -Parent $destFile
                        if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
                            try {
                                $null = New-Item -Path $destParent -ItemType Directory -Force -ErrorAction Stop
                            }
                            catch {
                                if (-not $firstCopyError) {
                                    $firstCopyError = "Failed to create directory '$destParent': $($_.Exception.Message)"
                                }
                                return
                            }
                        }
                        try {
                            Copy-Item -LiteralPath $_.FullName -Destination $destFile -Force -ErrorAction Stop
                        }
                        catch {
                            if (-not $firstCopyError) {
                                $firstCopyError = "Failed to copy '$($_.FullName)' to '$destFile': $($_.Exception.Message)"
                            }
                        }
                    }
                }
            }
        }

        if ($firstCopyError) {
            Write-LiteDeployLog "Warning: Log sync to '$RemoteLogDir' encountered an error: $firstCopyError" -Level WARNING -Component "Session"
        }
    }
    catch {
        Write-LiteDeployLog "Warning: Log sync to '$RemoteLogDir' failed: $($_.Exception.Message)" -Level WARNING -Component "Session"
    }
    finally {
        $script:InSyncLiteDeployLogsToShare = $false
    }
}

function Resolve-LiteDeployShareUncPath {
    <#
    .SYNOPSIS
        Resolves a remote log directory or path to its UNC path (\\server\share\...)
        using mapped drive definitions or configured boot/deployment state.
        Preserves existing UNC paths and never invents server/share names.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path = ""
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    # Already a UNC path?
    if ($Path -match '^\\\\') {
        if (Get-Command Format-LiteDeployUNCPath -ErrorAction SilentlyContinue) {
            return (Format-LiteDeployUNCPath -Path $Path)
        }
        $clean = $Path.Trim() -replace '/', '\'
        return $clean.TrimEnd('\')
    }

    # Mapped drive letter (e.g. Z:\...)
    if ($Path -match '^([A-Za-z]):\\?(.*)$') {
        $driveLetter = $matches[1]
        $relative = $matches[2]

        # 1. Try Get-PSDrive DisplayRoot or Root
        try {
            $psDrive = Get-PSDrive -Name $driveLetter -PSProvider FileSystem -ErrorAction SilentlyContinue
            if ($psDrive) {
                $rootCandidate = ""
                if ($psDrive.DisplayRoot -and [string]$psDrive.DisplayRoot -match '^\\\\') {
                    $rootCandidate = [string]$psDrive.DisplayRoot
                }
                elseif ($psDrive.Root -and [string]$psDrive.Root -match '^\\\\') {
                    $rootCandidate = [string]$psDrive.Root
                }

                if ($rootCandidate) {
                    $cleanRoot = $rootCandidate.Trim() -replace '/', '\'
                    $cleanRoot = $cleanRoot.TrimEnd('\')
                    if ($relative) {
                        return (Join-Path $cleanRoot $relative)
                    } else {
                        return $cleanRoot
                    }
                }
            }
        }
        catch {}

        # 2. Check configured network root safely from boot context / deployment state
        $configuredNet = ""
        $dep = Get-Variable -Name LiteDeployDeployment -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        $boot = Get-Variable -Name LiteDeployBootObject -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if (-not $boot) {
            $boot = Get-Variable -Name LiteDeployBootContext -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        }

        if ($boot) {
            $netVal = Get-LiteDeployStateProperty -InputObject $boot -Name "NetworkPath" -Default ""
            if ($netVal) { $configuredNet = [string]$netVal }
        }
        if (-not $configuredNet -and $dep) {
            $exec = Get-LiteDeployStateProperty -InputObject $dep -Name "Execution"
            if ($exec) {
                $netVal = Get-LiteDeployStateProperty -InputObject $exec -Name "NetworkPath" -Default ""
                if ($netVal) { $configuredNet = [string]$netVal }
            }
        }

        if ($configuredNet -and $configuredNet -match '^\\\\') {
            $bootDrive = ""
            if ($boot) {
                $bDrive = Get-LiteDeployStateProperty -InputObject $boot -Name "DriveLetter" -Default ""
                if ($bDrive) { $bootDrive = [string]$bDrive }
            }
            $bootLetter = $bootDrive -replace '[:\\]', ''
            if (-not $bootLetter -or $bootLetter -ieq $driveLetter -or $driveLetter -ieq 'Z') {
                $cleanNet = $configuredNet.Trim() -replace '/', '\'
                $cleanNet = $cleanNet.TrimEnd('\')
                if ($relative) {
                    return (Join-Path $cleanNet $relative)
                } else {
                    return $cleanNet
                }
            }
        }

        # If UNC cannot be resolved, do not invent. Return path as-is.
        return $Path.TrimEnd('\')
    }

    return $Path.TrimEnd('\')
}

function Verify-LiteDeployLogSync {
    <#
    .SYNOPSIS
        Verifies that relevant current local native log files were actually copied
        to the destination directory and are not stale, using SHA256 hash checks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalPath,
        [Parameter(Mandatory = $true)]
        [string]$RemoteDirectory,
        [Parameter(Mandatory = $false)]
        [string]$SubPath = ""
    )

    if ([string]::IsNullOrWhiteSpace($RemoteDirectory) -or -not (Test-Path -LiteralPath $RemoteDirectory -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{
            Success         = $false
            Inaccessible    = $true
            VerifiedCount   = 0
            TotalLocalFiles = 0
            Missing         = @()
            Mismatched      = @()
            Reason          = "Remote directory is inaccessible or unconfigured"
        }
    }

    $targetRemoteDir = if ($SubPath) { Join-Path $RemoteDirectory $SubPath } else { $RemoteDirectory }

    # Determine local files to verify
    $localFiles = @()
    if (Test-Path -LiteralPath $LocalPath -PathType Leaf -ErrorAction SilentlyContinue) {
        $localFiles = @(Get-Item -LiteralPath $LocalPath -ErrorAction SilentlyContinue)
    }
    elseif (Test-Path -LiteralPath $LocalPath -PathType Container -ErrorAction SilentlyContinue) {
        $localFiles = @(Get-ChildItem -LiteralPath $LocalPath -File -Recurse -ErrorAction SilentlyContinue)
    }

    if ($localFiles.Count -eq 0) {
        return [PSCustomObject]@{
            Success         = $false
            Inaccessible    = $false
            VerifiedCount   = 0
            TotalLocalFiles = 0
            Missing         = @()
            Mismatched      = @()
            Reason          = "No current local native log files exist"
        }
    }

    $verifiedCount = 0
    $mismatched = @()
    $missing = @()

    foreach ($file in $localFiles) {
        $destFile = if (Test-Path -LiteralPath $LocalPath -PathType Leaf -ErrorAction SilentlyContinue) {
            if (Test-Path -LiteralPath $targetRemoteDir -PathType Leaf -ErrorAction SilentlyContinue) {
                $targetRemoteDir
            } else {
                Join-Path $targetRemoteDir $file.Name
            }
        }
        else {
            $rel = $file.FullName.Substring($LocalPath.Length).TrimStart('\', '/')
            Join-Path $targetRemoteDir $rel
        }

        if (-not (Test-Path -LiteralPath $destFile -PathType Leaf -ErrorAction SilentlyContinue)) {
            $missing += $destFile
            continue
        }

        # SHA256 Hash verification to guard against stale files
        try {
            $localHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            $remoteHash = (Get-FileHash -LiteralPath $destFile -Algorithm SHA256 -ErrorAction Stop).Hash
            if ($localHash -eq $remoteHash) {
                $verifiedCount++
            } else {
                $mismatched += $destFile
            }
        }
        catch {
            $mismatched += $destFile
        }
    }

    $allVerified = ($verifiedCount -gt 0 -and $missing.Count -eq 0 -and $mismatched.Count -eq 0)

    return [PSCustomObject]@{
        Success         = $allVerified
        Inaccessible    = $false
        VerifiedCount   = $verifiedCount
        TotalLocalFiles = $localFiles.Count
        Missing         = $missing
        Mismatched      = $mismatched
        Reason          = if ($allVerified) { "All files verified" } else { "Verification failed or stale" }
    }
}

function Write-LiteDeployDiagnosticLogLocation {
    <#
    .SYNOPSIS
        Presents technician-facing diagnostic log location after sync.
        Derives UNC path from configured share/drive mapping without hardcoding.
        Only confirms share save after verifying relevant files actually copied.
        Provides clear warnings and valid local/OS fallback on share failure or offline media.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalPath,
        [Parameter(Mandatory = $false)]
        [string]$RemoteLogDir = "",
        [Parameter(Mandatory = $false)]
        [string]$RelativePath = "",
        [Parameter(Mandatory = $false)]
        [string]$OsLogDir = "",
        [Parameter(Mandatory = $false)]
        [string]$Component = "Session"
    )

    $isWinPE = ($env:SystemDrive -ieq 'X:')
    if (Get-Command Test-LiteDeployWinPE -ErrorAction SilentlyContinue) {
        try { $isWinPE = (Test-LiteDeployWinPE) } catch {}
    }

    # If RemoteLogDir was configured
    if (-not [string]::IsNullOrWhiteSpace($RemoteLogDir)) {
        $remoteAccessible = Test-Path -LiteralPath $RemoteLogDir -ErrorAction SilentlyContinue
        if (-not $remoteAccessible) {
            $uncRemote = Resolve-LiteDeployShareUncPath -Path $RemoteLogDir
            Write-LiteDeployLog "Warning: Remote deployment log directory '$uncRemote' is inaccessible. Diagnostic logs could not be saved to share." -Level "WARNING" -Component $Component
        }
        else {
            $verifyResult = Verify-LiteDeployLogSync -LocalPath $LocalPath -RemoteDirectory $RemoteLogDir -SubPath $RelativePath
            if ($verifyResult.Success) {
                $sharePath = if ($RelativePath) { Join-Path $RemoteLogDir $RelativePath } else { $RemoteLogDir }
                $uncLocation = Resolve-LiteDeployShareUncPath -Path $sharePath
                Write-LiteDeployLog "Diagnostic logs saved to share: $uncLocation" -Level "SUCCESS" -ForegroundColor Green -Component $Component
                return $uncLocation
            }
            elseif ($verifyResult.VerifiedCount -gt 0 -and ($verifyResult.Missing.Count -gt 0 -or $verifyResult.Mismatched.Count -gt 0)) {
                Write-LiteDeployLog "Warning: Diagnostic log copy to share was partial ($($verifyResult.VerifiedCount)/$($verifyResult.TotalLocalFiles) files verified). Stale or missing files detected on share." -Level "WARNING" -Component $Component
            }
            elseif ($verifyResult.Reason -eq "No current local native log files exist") {
                Write-LiteDeployLog "Notice: No native diagnostic log files were found to save." -Level "NOTICE" -Component $Component
            }
            else {
                Write-LiteDeployLog "Warning: Diagnostic logs could not be verified on share (no current files copied or remote files stale)." -Level "WARNING" -Component $Component
            }
        }
    }

    # Fallback: check OS volume if available and verified
    if (-not [string]::IsNullOrWhiteSpace($OsLogDir) -and (Test-Path -LiteralPath $OsLogDir -PathType Container -ErrorAction SilentlyContinue)) {
        $osVerify = Verify-LiteDeployLogSync -LocalPath $LocalPath -RemoteDirectory $OsLogDir -SubPath $RelativePath
        if ($osVerify.Success) {
            $osPath = if ($RelativePath) { Join-Path $OsLogDir $RelativePath } else { $OsLogDir }
            $level = if ([string]::IsNullOrWhiteSpace($RemoteLogDir)) { "SUCCESS" } else { "INFO" }
            $msgPrefix = if ([string]::IsNullOrWhiteSpace($RemoteLogDir)) { "Diagnostic logs saved to OS volume:" } else { "Fallback diagnostic logs saved to OS volume:" }
            Write-LiteDeployLog "$msgPrefix $osPath" -Level $level -ForegroundColor Green -Component $Component
            return $osPath
        }
    }

    # Local fallback
    $rebootNotice = if ($isWinPE -or $LocalPath -like 'X:*') {
        " (Note: WinPE X: drive ramdisk does not persist after reboot)"
    } else { "" }
    $localMsgPrefix = if ([string]::IsNullOrWhiteSpace($RemoteLogDir)) { "Diagnostic logs available locally:" } else { "Fallback diagnostic logs available locally:" }
    Write-LiteDeployLog "$localMsgPrefix $LocalPath$rebootNotice" -Level "INFO" -Component $Component
    return $LocalPath
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

        foreach ($subfolder in @('Setup', 'Dism')) {
            $localSub = Join-Path $localLogDir $subfolder
            if (Test-Path -LiteralPath $localSub -PathType Container) {
                $osSub = Join-Path $targetLogs $subfolder
                if (-not (Test-Path -LiteralPath $osSub -PathType Container)) {
                    $null = New-Item -Path $osSub -ItemType Directory -Force -ErrorAction Stop
                }
                foreach ($subFile in Get-ChildItem -LiteralPath $localSub -File -Recurse -ErrorAction Stop) {
                    $relPath = $subFile.FullName.Substring($localSub.Length).TrimStart('\', '/')
                    $destFile = Join-Path $osSub $relPath
                    $destParent = Split-Path -Parent $destFile
                    if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
                        $null = New-Item -Path $destParent -ItemType Directory -Force -ErrorAction Stop
                    }
                    if ($subFile.FullName -ine $destFile) {
                        Copy-Item -LiteralPath $subFile.FullName -Destination $destFile -Force -ErrorAction Stop
                    }
                    if ((Get-FileHash -LiteralPath $subFile.FullName -Algorithm SHA256 -ErrorAction Stop).Hash -ne
                        (Get-FileHash -LiteralPath $destFile -Algorithm SHA256 -ErrorAction Stop).Hash) {
                        throw "Log verification failed: $($subFile.Name)."
                    }
                    $result.LogsCopied++
                }
            }
        }

        if ($DeploymentState) {
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

# ==============================================================================
# 10. STANDALONE EXECUTION
# ==============================================================================

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
        $displayStatePath = if ([string]::IsNullOrWhiteSpace($StatePath)) { Get-LiteDeployStateFilePath } else { $StatePath }

        Write-Host ""
        Write-Host ("{0} v{1} ({2})" -f $meta.Name, $meta.Version, $meta.ComponentId) -ForegroundColor Cyan
        Write-Host ("  Log file   : {0}" -f $logFile)
        Write-Host ("  Log exists : {0}" -f (Test-Path -LiteralPath $logFile))
        Write-Host ("  Remote dir : {0}" -f $(if ($remote) { $remote } else { "(not set)" }))
        Write-Host ("  State file : {0}" -f $displayStatePath)
        $hasState = Test-Path -LiteralPath $displayStatePath -PathType Leaf
        Write-Host ("  State exist: {0}" -f $hasState)

        if ($hasState) {
            $shown = Get-LiteDeployState -Path $displayStatePath
            if ($null -ne $shown) {
                $check = Test-LiteDeployState -State $shown -Persisted -Detailed
                $execution = Get-LiteDeployStateProperty -InputObject $shown -Name "Execution"
                $workflow = Get-LiteDeployStateProperty -InputObject $shown -Name "Workflow"
                $selection = Get-LiteDeployStateProperty -InputObject $workflow -Name "SelectionData"
                $disk = Get-LiteDeployStateProperty -InputObject $shown -Name "Disk"
                $osInstall = Get-LiteDeployStateProperty -InputObject $shown -Name "OSInstall"
                $logLocations = Get-LiteDeployStateProperty -InputObject $shown -Name "LogLocations"
                $phaseNumber = 0
                [void][int]::TryParse([string](Get-LiteDeployStateProperty -InputObject $shown -Name "CurrentPhase" -Default 0), [ref]$phaseNumber)
                $phaseLabel = if ($global:LiteDeployStatePhaseNames.ContainsKey($phaseNumber)) { " ($($global:LiteDeployStatePhaseNames[$phaseNumber]))" } else { "" }

                Write-Host ""
                Write-Host ("  Deployment : {0}" -f (Get-LiteDeployStateProperty -InputObject $shown -Name "DeploymentUid" -Default "-"))
                Write-Host ("  Status     : {0}" -f (Get-LiteDeployStateProperty -InputObject $shown -Name "Status" -Default "-"))
                Write-Host ("  Phase      : {0}{1}" -f $phaseNumber, $phaseLabel)
                Write-Host ("  Step       : {0} ({1}%)" -f (Get-LiteDeployStateProperty -InputObject $execution -Name "CurrentStep" -Default "-"), (Get-LiteDeployStateProperty -InputObject $execution -Name "PercentComplete" -Default 0))
                Write-Host ("  Started    : {0}" -f (Get-LiteDeployStateProperty -InputObject $shown -Name "StartTime" -Default "-"))
                Write-Host ("  Ended      : {0}" -f (Get-LiteDeployStateProperty -InputObject $shown -Name "EndTime" -Default "-"))
                Write-Host ("  Workflow   : {0}" -f (Get-LiteDeployStateProperty -InputObject $selection -Name "WorkflowName" -Default "-"))
                Write-Host ("  Computer   : {0}" -f (Get-LiteDeployStateProperty -InputObject $selection -Name "ComputerName" -Default "-"))
                Write-Host ("  Disk       : formatted={0}, disk={1}, mode={2}" -f (Get-LiteDeployStateProperty -InputObject $disk -Name "Formatted" -Default $false), (Get-LiteDeployStateProperty -InputObject $disk -Name "DiskNumber" -Default "-"), (Get-LiteDeployStateProperty -InputObject $disk -Name "BootMode" -Default "-"))
                Write-Host ("  OS install : applied={0}, exit code={1}" -f (Get-LiteDeployStateProperty -InputObject $osInstall -Name "Applied" -Default $false), (Get-LiteDeployStateProperty -InputObject $osInstall -Name "ExitCode" -Default "-"))
                Write-Host ("  Remote logs: {0}" -f (Get-LiteDeployStateProperty -InputObject $logLocations -Name "RemoteLogDir" -Default "(none)"))
                Write-Host ("  Next phase : {0}" -f (Get-LiteDeployStateNextPhase -State $shown))
                Write-Host ("  Valid      : {0}" -f $check.IsValid) -ForegroundColor $(if ($check.IsValid) { "Green" } else { "Red" })

                foreach ($problem in @($check.Errors)) { Write-Host ("    ERROR   {0}" -f (Protect-LiteDeployStateText -Text $problem)) -ForegroundColor Red }
                foreach ($note in @($check.Warnings)) { Write-Host ("    WARNING {0}" -f (Protect-LiteDeployStateText -Text $note)) -ForegroundColor Yellow }

                $recordedErrors = @(Get-LiteDeployStateProperty -InputObject $execution -Name "Errors" -Default @())
                if ($recordedErrors.Count -gt 0) {
                    Write-Host "  Errors recorded:" -ForegroundColor Yellow
                    foreach ($recorded in $recordedErrors) {
                        Write-Host ("    - {0}" -f (Protect-LiteDeployStateText -Text ([string]$recorded))) -ForegroundColor Yellow
                    }
                }
            }
        }
        Write-Host ("  Target env : {0}   PowerShell >= {1}" -f $meta.TargetEnvironment, $meta.MinPowerShellVersion)
        Write-Host "  Usage      : .\LiteDeploy.Session.ps1 [-Message ""text"" -Level SUCCESS] [-StatePath path]"
        Write-Host ""
    }
}
