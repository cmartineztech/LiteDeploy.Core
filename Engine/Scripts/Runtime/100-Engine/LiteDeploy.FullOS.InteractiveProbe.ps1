#requires -Version 5.1
<#
.SYNOPSIS
    Temporary FullOS interactive logon probe (Audit Mode / Administrator).
.DESCRIPTION
    Runs in a second independent PowerShell window started by FullOS (or legacy
    AtLogOn task). Reads DeploymentState.json, optionally loads Environment + Logs
    from the staged Runtime folder, shows deployment info, and writes a probe log.
    Closes Audit Mode sysprep.exe so the probe (later Progress) owns the desktop.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$isFirstInstance = $false
$probeMutex = $null
try {
    $probeMutex = New-Object System.Threading.Mutex($true, "Global\LiteDeploy_InteractiveProbe_Mutex", [ref]$isFirstInstance)
}
catch {
    $isFirstInstance = $true
}

if (-not $isFirstInstance) {
    Write-Host "[INFO] Another instance of LiteDeploy Interactive Monitor is already running in this session. Exiting duplicate." -ForegroundColor Yellow
    exit 0
}

$runtimeDir = $PSScriptRoot
# …\~LiteDeploy\Engine\Scripts\Runtime  →  …\~LiteDeploy
$localRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $runtimeDir))
if ((Split-Path -Leaf $localRoot) -ne '~LiteDeploy') {
    $localRoot = Join-Path $env:SystemDrive '~LiteDeploy'
}
$probeStatePath = Join-Path $localRoot 'DeploymentState.json'
$script:probeStatePath = $probeStatePath
$script:statePath = $probeStatePath
$logDir = Join-Path $localRoot 'WorkLogs'
$null = New-Item -Path $logDir -ItemType Directory -Force -ErrorAction SilentlyContinue
$probeLog = Join-Path $logDir 'LiteDeploy.InteractiveProbe.log'

function Write-ProbeLine {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'o'), $Level, $Message
    Add-Content -LiteralPath $probeLog -Value $line -Encoding UTF8
    if (Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue) {
        try {
            Write-LiteDeployLog -Message $Message -Level $Level -Component 'InteractiveProbe' -ErrorAction SilentlyContinue
        }
        catch {}
    }
}

function Stop-LiteDeployAuditModeSysprep {
    <#
    .SYNOPSIS
        Ends Audit Mode System Preparation Tool UI (sysprep.exe) in this logon session.
    #>
    $stopped = New-Object System.Collections.Generic.List[string]
    foreach ($proc in @(Get-Process -Name 'sysprep' -ErrorAction SilentlyContinue)) {
        try {
            $info = 'PID={0} SessionId={1} Path={2}' -f $proc.Id, $proc.SessionId, $(if ($proc.Path) { $proc.Path } else { '(unknown)' })
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            $stopped.Add($info)
            Write-ProbeLine "Stopped Audit Mode sysprep.exe ($info)" 'SUCCESS'
        }
        catch {
            try {
                & taskkill.exe /F /PID $proc.Id /T 2>$null
                $stopped.Add("PID=$($proc.Id) (taskkill)")
                Write-ProbeLine "Killed sysprep.exe via taskkill (PID=$($proc.Id))" 'SUCCESS'
            }
            catch {
                Write-ProbeLine "Could not stop sysprep.exe PID=$($proc.Id): $($_.Exception.Message)" 'WARNING'
            }
        }
    }

    # Proactive sweep with taskkill across process tree
    try {
        $null = & taskkill.exe /F /IM sysprep.exe /T 2>$null
    }
    catch {}

    return @($stopped.ToArray())
}

# Optional: Environment + Logs from staged Runtime (same folder as this script).
$envScript = Join-Path $runtimeDir 'LiteDeploy.Environment.ps1'
$logsScript = Join-Path $runtimeDir 'LiteDeploy.Logs.ps1'
$stateScript = Join-Path $runtimeDir 'LiteDeploy.State.ps1'
if (Test-Path -LiteralPath $envScript -PathType Leaf) {
    try { . $envScript } catch { Write-ProbeLine "Environment load skipped: $($_.Exception.Message)" 'WARNING' }
}
if (Test-Path -LiteralPath $logsScript -PathType Leaf) {
    try { . $logsScript } catch { Write-ProbeLine "Logs load skipped: $($_.Exception.Message)" 'WARNING' }
}
if (Test-Path -LiteralPath $stateScript -PathType Leaf) {
    try {
        . $stateScript -StatePath $probeStatePath
        $script:statePath = $probeStatePath
    } catch {
        Write-ProbeLine "State helpers load skipped: $($_.Exception.Message)" 'WARNING'
    }
}

$who = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$sessionId = (Get-Process -Id $PID).SessionId

# Initial sysprep termination sweep
$sysprepStopped = @(Stop-LiteDeployAuditModeSysprep)

# Background timer: checks and kills sysprep.exe every 500ms so it never stays open
$sysprepTimer = New-Object System.Timers.Timer
$sysprepTimer.Interval = 500
$sysprepTimer.AutoReset = $true
$null = Register-ObjectEvent -InputObject $sysprepTimer -EventName Elapsed -SourceIdentifier 'LiteDeploy_SysprepWatch' -Action {
    Stop-LiteDeployAuditModeSysprep | Out-Null
}
$sysprepTimer.Start()

# Read belonging deployment state (WinPE/FullOS handoff).
$deployment = $null
$uid = '(none)'
$status = '(none)'
$deployType = '(unknown)'
$networkPath = '(none)'
$shareDrive = '(none)'
$remoteLog = '(none)'
$currentStep = '(none)'
$resumeCount = '0'
$computerName = '(none)'
$workflowName = '(none)'
$osApplied = '(unknown)'

function Update-ProbeStateData {
    $targetPath = if (-not [string]::IsNullOrWhiteSpace($script:probeStatePath)) {
        $script:probeStatePath
    } elseif (-not [string]::IsNullOrWhiteSpace($script:statePath)) {
        $script:statePath
    } else {
        Join-Path $localRoot 'DeploymentState.json'
    }

    if (-not [string]::IsNullOrWhiteSpace($targetPath) -and (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
        try {
            $st = if (Get-Command Read-LiteDeployStateFile -ErrorAction SilentlyContinue) {
                Read-LiteDeployStateFile -Path $targetPath
            }
            else {
                Get-Content -LiteralPath $targetPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            }
            if ($st) {
                $script:deployment = $st
                $global:LiteDeployDeployment = $st
                if ($st.PSObject.Properties['DeploymentUid'] -and $st.DeploymentUid) { $script:uid = [string]$st.DeploymentUid }
                if ($st.PSObject.Properties['Status'] -and $st.Status) { $script:status = [string]$st.Status }
                $exec = if ($st.PSObject.Properties['Execution']) { $st.Execution } else { $null }
                if ($exec) {
                    if ($exec.PSObject.Properties['CurrentStep'] -and $exec.CurrentStep) { $script:currentStep = [string]$exec.CurrentStep }
                    if ($exec.PSObject.Properties['ResumeCount']) { $script:resumeCount = [string]$exec.ResumeCount }
                    if ($exec.PSObject.Properties['RemoteLogDir'] -and $exec.RemoteLogDir) { $script:remoteLog = [string]$exec.RemoteLogDir }
                    $share = if ($exec.PSObject.Properties['FullOSShare']) { $exec.FullOSShare } else { $null }
                    if ($share) {
                        if ($share.PSObject.Properties['DeploymentType'] -and $share.DeploymentType) { $script:deployType = [string]$share.DeploymentType }
                        if ($share.PSObject.Properties['NetworkPath'] -and $share.NetworkPath) { $script:networkPath = [string]$share.NetworkPath }
                        if ($share.PSObject.Properties['DriveLetter'] -and $share.DriveLetter) { $script:shareDrive = [string]$share.DriveLetter }
                    }
                }
                $boot = if ($st.PSObject.Properties['BootObject']) { $st.BootObject } else { $null }
                if ($boot) {
                    if ($script:deployType -eq '(unknown)' -and $boot.PSObject.Properties['DeploymentType'] -and $boot.DeploymentType) {
                        $script:deployType = [string]$boot.DeploymentType
                    }
                    if ($script:networkPath -eq '(none)' -and $boot.PSObject.Properties['NetworkPath'] -and $boot.NetworkPath) {
                        $script:networkPath = [string]$boot.NetworkPath
                    }
                }
                $wf = if ($st.PSObject.Properties['Workflow']) { $st.Workflow } else { $null }
                if ($wf -and $wf.PSObject.Properties['SelectionData'] -and $wf.SelectionData) {
                    $sel = $wf.SelectionData
                    if ($sel.PSObject.Properties['ComputerName'] -and $sel.ComputerName) { $script:computerName = [string]$sel.ComputerName }
                    if ($sel.PSObject.Properties['WorkflowName'] -and $sel.WorkflowName) { $script:workflowName = [string]$sel.WorkflowName }
                }
                $os = if ($st.PSObject.Properties['OSInstall']) { $st.OSInstall } else { $null }
                if ($os -and $os.PSObject.Properties['Applied']) {
                    $script:osApplied = [string][bool]$os.Applied
                }
                if ($st.PSObject.Properties['LogLocations'] -and $st.LogLocations -and
                    $st.LogLocations.PSObject.Properties['RemoteLogDir'] -and $st.LogLocations.RemoteLogDir -and
                    $script:remoteLog -eq '(none)') {
                    $script:remoteLog = [string]$st.LogLocations.RemoteLogDir
                }
            }
        }
        catch {
            Write-ProbeLine "Failed to read state: $($_.Exception.Message)" 'WARNING'
        }
    }
}

Update-ProbeStateData

$zReady = $false
if ($shareDrive -ne '(none)') {
    $zReady = Test-Path -LiteralPath (($shareDrive.TrimEnd('\') + '\')) -PathType Container -ErrorAction SilentlyContinue
}

Write-ProbeLine ("Probe session User={0} SID={1} SessionId={2} UID={3} Status={4}" -f `
        $env:USERNAME, $who.User.Value, $sessionId, $uid, $status)

$isInteractive = [Environment]::UserInteractive
$host.UI.RawUI.WindowTitle = ('LiteDeploy FullOS - Live Monitor | {0}' -f $uid)

# ==============================================================================
# PERSISTENT LIVE MONITOR LOOP (Keeps shell open indefinitely for inspection)
# ==============================================================================

$lastRefresh = [DateTime]::MinValue

while ($true) {
    # Direct kill sweep on every tick
    $null = Stop-LiteDeployAuditModeSysprep

    if ((Get-Date) -ge $lastRefresh.AddSeconds(2)) {
        $lastRefresh = Get-Date
        Update-ProbeStateData

        if ($shareDrive -ne '(none)') {
            $zReady = Test-Path -LiteralPath (($shareDrive.TrimEnd('\') + '\')) -PathType Container -ErrorAction SilentlyContinue
        }

        Clear-Host
        Write-Host ''
        Write-Host '  =====================================================================' -ForegroundColor Cyan
        Write-Host '               LiteDeploy FullOS - Live Interactive Monitor            ' -ForegroundColor White
        Write-Host '  =====================================================================' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  Session Context:' -ForegroundColor Yellow
        Write-Host ('    User Account : {0} (Session ID: {1})' -f $env:USERNAME, $sessionId)
        Write-Host ('    Interactive  : {0}' -f $isInteractive)
        Write-Host ('    Sysprep Watch: Active (background timer + active sweep)' ) -ForegroundColor Green
        Write-Host ''
        Write-Host '  Deployment Engine State:' -ForegroundColor Yellow
        Write-Host ('    UID          : {0}' -f $uid)
        Write-Host ('    Status       : {0}' -f $status) -ForegroundColor $(if ($status -eq 'Completed') { 'Green' } else { 'Cyan' })
        Write-Host ('    Current Step : {0}' -f $currentStep) -ForegroundColor White
        Write-Host ('    Resume Count : {0}' -f $resumeCount)
        Write-Host ('    Deploy Type  : {0}' -f $deployType)
        Write-Host ('    Workflow     : {0}' -f $workflowName)
        Write-Host ('    ComputerName : {0}' -f $computerName)
        Write-Host ('    OS Applied   : {0}' -f $osApplied)
        Write-Host ('    Share Mount  : {0} -> {1} (Accessible: {2})' -f $shareDrive, $networkPath, $zReady) -ForegroundColor $(if ($zReady) { 'Green' } else { 'DarkYellow' })
        Write-Host ('    Remote Logs  : {0}' -f $remoteLog)
        Write-Host ('    State File   : {0}' -f $statePath)
        Write-Host ('    Local Root   : {0}' -f $localRoot)
        Write-Host ('    Probe Log    : {0}' -f $probeLog)
        Write-Host ''
        Write-Host '  ---------------------------------------------------------------------' -ForegroundColor DarkGray
        Write-Host '  [Shell kept OPEN for inspection. Press Ctrl+C for interactive prompt]' -ForegroundColor Green
        Write-Host ('  Last update  : {0}' -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor DarkGray
    }

    Start-Sleep -Milliseconds 500
}
