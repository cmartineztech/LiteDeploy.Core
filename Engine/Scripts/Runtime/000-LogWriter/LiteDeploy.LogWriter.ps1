<#
.SYNOPSIS
    LiteDeploy Core Log Writer Module.

.DESCRIPTION
    Standalone logging component for LiteDeploy Core.
    Writes color-coded console output and appends Microsoft CMTrace XML entries to
    $env:SystemDrive\~LiteDeploy\WorkLogs\LiteDeploy.Execution.log.
    Dot-source the script to load Write-LiteDeployLog, or call it once with -Message.

.PARAMETER Message
    The log message text to record.

.PARAMETER Level
    Severity level: INFO, SUCCESS, INIT, CHECK, WARNING, RETRY, ERROR. Defaults to "INFO".

.PARAMETER Component
    Subsystem component name tag (e.g. "BootInitializer", "HardwarePreCheck", "WorkflowSelection", "Progress").

.PARAMETER ForegroundColor
    Console color for the line. When White (default), color is selected from -Level.

.PARAMETER LogFileName
    CMTrace log file name. Defaults to "LiteDeploy.Execution.log".

.PARAMETER LogPath
    Target directory override. Defaults to "$env:SystemDrive\~LiteDeploy\WorkLogs".

.PARAMETER NoConsole
    When specified, suppresses console screen output and writes only to the log file.

.NOTES
    Compatible with Set-StrictMode 2.0, PowerShell 5.1+, and WinPE 5.1/10/11.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$Message = "",

    [Parameter(Mandatory = $false, Position = 1)]
    [ValidateSet("INFO", "SUCCESS", "INIT", "CHECK", "WARNING", "RETRY", "ERROR")]
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
    [switch]$Metadata
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ==============================================================================
# COMPONENT METADATA
# ==============================================================================

function Get-LiteDeployComponentMetadata {
    return [PSCustomObject]@{
        ComponentId          = "LogWriter"
        Name                 = "LiteDeploy Logging Engine"
        Version              = "1.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "Universal"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @()
        Description          = "Provides CMTrace-compatible XML logging across WinPE and FullOS."
    }
}

if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

function Get-LiteDeployLogPath {
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Message = "",

        [Parameter(Mandatory = $false, Position = 1)]
        [ValidateSet("INFO", "SUCCESS", "INIT", "CHECK", "NOTICE", "WARNING", "RETRY", "ERROR")]
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
        [switch]$NoConsole
    )

    Set-StrictMode -Version 2.0

    # Same console pattern as BootInitializer: print the message as-is.
    # When ForegroundColor is left at White, pick a color from -Level.
    $selectedColor = $ForegroundColor
    if ($ForegroundColor -eq [System.ConsoleColor]::White) {
        $selectedColor = switch ($Level.ToUpper()) {
            "SUCCESS" { [System.ConsoleColor]::Green }
            "INIT"    { [System.ConsoleColor]::DarkGray }
            "CHECK"   { [System.ConsoleColor]::Cyan }
            "NOTICE"  { [System.ConsoleColor]::Yellow }
            "WARNING" { [System.ConsoleColor]::Yellow }
            "RETRY"   { [System.ConsoleColor]::DarkYellow }
            "ERROR"   { [System.ConsoleColor]::Red }
            default   { [System.ConsoleColor]::White }
        }
    }

    # Empty Message ("") still prints a blank console spacer; CMTrace skips whitespace-only below.
    if (-not $NoConsole) {
        Write-Host $Message -ForegroundColor $selectedColor
    }

    # CMTrace XML — local clock + real UTC offset; UTF-8; safe message; PID as thread
    try {
        $targetLogFile = Get-LiteDeployLogPath -CustomPath $LogPath -FileName $LogFileName
        $cleanMsg = $Message.Trim() -replace '[\r\n]+', ' '
        $cleanMsg = $cleanMsg.Replace(']LOG]!>', ']LOG] !>')
        if (-not [string]::IsNullOrWhiteSpace($cleanMsg)) {
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

            $callingFile = "LiteDeploy.LogWriter.ps1"
            if ($MyInvocation.ScriptName) {
                $callingFile = Split-Path -Leaf $MyInvocation.ScriptName
            }

            $logEntry = "<![LOG[$cleanMsg]LOG]!><time=""$timeStr"" date=""$dateStr"" component=""$Component"" context="""" type=""$typeCode"" thread=""$PID"" file=""$callingFile"">"
            Add-Content -Path $targetLogFile -Value $logEntry -Encoding utf8 -ErrorAction SilentlyContinue

            # Optional live mirror to the deployment share / media log directory
            $remoteLogDir = ""
            if (Test-Path "Variable:global:LiteDeployRemoteLogDir") {
                $remoteLogDir = $global:LiteDeployRemoteLogDir
            }
            elseif (Test-Path "Variable:global:LiteDeployDeployment") {
                if ($global:LiteDeployDeployment -and $global:LiteDeployDeployment.PSObject.Properties['LogLocations'] -and $global:LiteDeployDeployment.LogLocations.RemoteLogDir) {
                    $remoteLogDir = $global:LiteDeployDeployment.LogLocations.RemoteLogDir
                }
            }

            if ($remoteLogDir -and (Test-Path -LiteralPath $remoteLogDir -ErrorAction SilentlyContinue)) {
                $remoteLogFile = Join-Path $remoteLogDir $LogFileName
                Add-Content -Path $remoteLogFile -Value $logEntry -Encoding utf8 -ErrorAction SilentlyContinue
            }
        }
    }
    catch {}
}

function Clear-LiteDeployLog {
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
    catch {}
}

# Standalone execution when invoked directly with parameters
if ($MyInvocation.InvocationName -ne '.' -and -not [string]::IsNullOrWhiteSpace($Message)) {
    Write-LiteDeployLog -Message $Message -Level $Level -Component $Component -ForegroundColor $ForegroundColor -LogFileName $LogFileName -LogPath $LogPath -NoConsole:$NoConsole
}
