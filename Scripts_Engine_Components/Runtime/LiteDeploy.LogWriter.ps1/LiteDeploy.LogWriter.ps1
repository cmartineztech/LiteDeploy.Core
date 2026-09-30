<#
.SYNOPSIS
    LiteDeploy Core Log Writer Module.

.DESCRIPTION
    Standalone enterprise logging module for LiteDeploy Core components.
    Provides dual output: real-time color-coded console rendering and live
    background log writing in Microsoft CMTrace.exe native XML format to
    $env:SystemDrive\~LiteDeploy\WorkLogs\LiteDeploy.log.

.PARAMETER Message
    The log message text to record.

.PARAMETER Level
    Severity level: INFO, SUCCESS, INIT, WARNING, RETRY, ERROR. Defaults to "INFO".

.PARAMETER Component
    Subsystem component name tag (e.g. "BootInitilizer", "PreCheck", "SelectWorkflow", "Progress").

.PARAMETER ForegroundColor
    Optional ConsoleColor override. If omitted, color is dynamically selected based on Level.

.PARAMETER LogFileName
    Master log file name. Defaults to "LiteDeploy.log".

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
    [ValidateSet("INFO", "SUCCESS", "INIT", "WARNING", "RETRY", "ERROR")]
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
$ErrorActionPreference = "Stop"

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
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [Parameter(Mandatory = $false, Position = 1)]
        [ValidateSet("INFO", "SUCCESS", "INIT", "WARNING", "RETRY", "ERROR")]
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

    # Determine dynamic console color if default white was passed
    $selectedColor = $ForegroundColor
    if ($ForegroundColor -eq [System.ConsoleColor]::White) {
        $selectedColor = switch ($Level.ToUpper()) {
            "SUCCESS" { [System.ConsoleColor]::Green }
            "INIT"    { [System.ConsoleColor]::DarkGray }
            "WARNING" { [System.ConsoleColor]::Yellow }
            "RETRY"   { [System.ConsoleColor]::DarkYellow }
            "ERROR"   { [System.ConsoleColor]::Red }
            default   { [System.ConsoleColor]::White }
        }
    }

    # 1. Real-Time Console Output
    if (-not $NoConsole -and $Message) {
        Write-Host $Message -ForegroundColor $selectedColor
    }

    # 2. CMTrace Native XML Log Writing
    try {
        $targetLogFile = Get-LiteDeployLogPath -CustomPath $LogPath -FileName $LogFileName
        $cleanMsg = $Message.Trim()
        if (-not [string]::IsNullOrWhiteSpace($cleanMsg)) {
            $now = Get-Date
            $timeStr = $now.ToString("HH:mm:ss.fff") + "+000"
            $dateStr = $now.ToString("MM-dd-yyyy")
            $typeCode = switch ($Level.ToUpper()) {
                "ERROR"   { "3" }
                "WARNING" { "2" }
                "RETRY"   { "2" }
                default   { "1" }
            }
            
            $callingFile = "LiteDeploy.LogWriter.ps1"
            if ($MyInvocation.ScriptName) {
                $callingFile = Split-Path -Leaf $MyInvocation.ScriptName
            }

            # Official Microsoft CMTrace.exe XML Log Format
            $logEntry = "<![LOG[$cleanMsg]LOG]!><time=""$timeStr"" date=""$dateStr"" component=""$Component"" context="""" type=""$typeCode"" thread=""1"" file=""$callingFile"">"
            Add-Content -Path $targetLogFile -Value $logEntry -ErrorAction SilentlyContinue

            # Modern Newline-Delimited JSON (NDJSON) Log Format
            $jsonFileName = [System.IO.Path]::ChangeExtension($LogFileName, ".json")
            $targetJsonFile = Get-LiteDeployLogPath -CustomPath $LogPath -FileName $jsonFileName
            $isoTimestamp = $now.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            $jsonRecord = [ordered]@{
                timestamp = $isoTimestamp
                level     = $Level.ToUpper()
                type      = [int]$typeCode
                component = $Component
                message   = $cleanMsg
                file      = $callingFile
            }
            $jsonEntry = $jsonRecord | ConvertTo-Json -Compress
            Add-Content -Path $targetJsonFile -Value $jsonEntry -ErrorAction SilentlyContinue
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
        $jsonFileName = [System.IO.Path]::ChangeExtension($LogFileName, ".json")
        $targetJsonFile = Get-LiteDeployLogPath -CustomPath $LogPath -FileName $jsonFileName
        if (Test-Path -LiteralPath $targetJsonFile) {
            Remove-Item -LiteralPath $targetJsonFile -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}
}

# Standalone execution when invoked directly with parameters
if ($MyInvocation.InvocationName -ne '.' -and -not [string]::IsNullOrWhiteSpace($Message)) {
    Write-LiteDeployLog -Message $Message -Level $Level -Component $Component -ForegroundColor $ForegroundColor -LogFileName $LogFileName -LogPath $LogPath -NoConsole:$NoConsole
}
