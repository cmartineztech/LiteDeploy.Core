<#
.SYNOPSIS
    LiteDeploy FullOS Engine — First-boot and reboot resume orchestrator (architecture v2).

.DESCRIPTION
    Dedicated FullOS execution engine. First launch is HKLM\...\Run\LiteDeployFullOS at
    interactive logon (Audit Admin or Domain Join AutoLogon). That Run value is staged in
    unattend specialize (Image) when the workflow has actions — not via auditUser.
    FullOS may re-arm the same Run key for mid-deploy reboot survival. Stock Setup\CmdLine
    (sysprep) is left alone; FullOS kills the sysprep.exe process. Only a LiteDeploy-owned
    Setup CmdLine (legacy) is cleared to stop reboot loops.
    On direct execution, before resume, writes HKCU\Console\%%Startup DelegationConsole
    and DelegationTerminal ({B23D10C0-E52E-411E-9D5B-C09FDF709C7D}) so later consoles
    hand off to Windows Terminal. The window that already launched FullOS is unchanged.

    Responsibilities:
      1. Loads FullOS dependencies (Session, Hardware, Packages, HostShell).
      2. Loads and updates DeploymentState.json (increments resume count, sets Phase 5).
      3. Unseals WinPECT secrets in-memory (interactive admin context).
      4. Reconnects the DeploymentShare persistently as Z: with in-memory PSCredential.
      5. Configures remote log mirroring back to the deployment share under the deployment UID.
      6. Re-arms HKLM Run for reboot survival; kills sysprep.exe; clears Run on finish.
      7. Displays live interactive monitor in the current console at completion.
      8. Orchestrates package installations (LiteDeploy.Packages.ps1).

.PARAMETER LocalRootName
    Name of the staged deployment root on the OS volume (default: '~LiteDeploy').

.PARAMETER OsDriveLetter
    System drive letter (default: $env:SystemDrive).

.PARAMETER StatePath
    Optional explicit path to DeploymentState.json.

.PARAMETER Metadata
    Returns standardized component metadata.

.NOTES
    LiteDeploy Core Component Standard v2.0
    PowerShell Version: 5.1+
    Strict Mode: Version 2.0
#>

[CmdletBinding()]
param(
    [string]$LocalRootName = '~LiteDeploy',

    [string]$OsDriveLetter = $env:SystemDrive,

    [string]$StatePath = '',

    [switch]$ResumeFullOS,

    [switch]$ForceDirect,

    [switch]$Metadata
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ==============================================================================
# 1. COMPONENT METADATA
# ==============================================================================

function Get-LiteDeployComponentMetadata {
    return [PSCustomObject]@{
        ComponentId          = "OS.Engine"
        Name                 = "LiteDeploy FullOS Engine"
        Version              = "2.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "FullOS"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("Environment", "Session", "Hardware", "Packages")
        Description          = "Interactive FullOS orchestrator (HKLM Run at logon; specialize-staged): WinPECT unseal, Z: reconnect, log mirror, live monitor, package install."
    }
}

$script:OSMetadata = Get-LiteDeployComponentMetadata

function Get-LiteDeployOSMetadata {
    return $script:OSMetadata
}

if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

# Load Environment if not already present
if (-not (Get-Command Get-LiteDeployRuntimePaths -ErrorAction SilentlyContinue)) {
    $environmentScript = Join-Path $PSScriptRoot 'LiteDeploy.Environment.ps1'
    if (Test-Path -LiteralPath $environmentScript -PathType Leaf) {
        . $environmentScript
        # Prevent generic metadata function pollution from imported Environment
        function script:Get-LiteDeployComponentMetadata { return $script:OSMetadata }
    }
}

# ==============================================================================
# 2. COMPONENT LOADER
# ==============================================================================

function Import-LiteDeployFullOSComponent {
    <#
    .SYNOPSIS
        Dot-sources one Runtime component from the active Runtime root (or $PSScriptRoot).
        Exports declared functions into Global scope so callers retain them regardless
        of scope depth.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$RuntimeRoot = $PSScriptRoot
    )
    if ($Name -eq 'Environment' -or $Name -eq 'BootConfig' -or $Name -eq 'Engine' -or $Name -eq 'FullOS') { return }
    $relative = $null
    if ($global:LiteDeployPathSettings -and $global:LiteDeployPathSettings.ProductionFiles.Contains($Name)) {
        $relative = [string]$global:LiteDeployPathSettings.ProductionFiles[$Name]
    }
    else {
        $relative = "LiteDeploy.$Name.ps1"
    }
    $path = Join-Path $RuntimeRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required FullOS component missing: $Name ($path)"
    }
    $funcsBefore = @(Get-ChildItem function:)
    . $path
    $funcsAfter = @(Get-ChildItem function:)
    $newFuncs = $funcsAfter | Where-Object { $name = $_.Name; -not ($funcsBefore | Where-Object { $_.Name -eq $name }) }
    foreach ($fn in $newFuncs) {
        Set-Item -Path ('Function:Global:' + $fn.Name) -Value $fn.ScriptBlock -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# 3. LEGACY CLEANUP + INTERACTIVE PROBE
# ==============================================================================

function Clear-LiteDeployFullOSLegacyScheduledTasks {
    <#
    .SYNOPSIS
        Removes obsolete LiteDeploy FullOS scheduled tasks from older builds (HKLM Run is resume now).
    #>
    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($taskName in @('LiteDeploy_SystemEngine', 'LiteDeploy_ResumeEngine', 'LiteDeploy_InteractiveProbe')) {
        try {
            $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($null -ne $existing) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
                $removed.Add($taskName)
            }
        }
        catch {}
    }
    return [pscustomobject]@{
        Success = $true
        Removed = @($removed.ToArray())
        Count   = $removed.Count
    }
}

function Collect-LiteDeployFullOSPantherLogs {
    <#
    .SYNOPSIS
        Best-effort collection of first-boot Windows Setup/Panther logs from running FullOS
        ($env:windir\Panther\setupact.log & setuperr.log) into local WorkLogs\<Engine>\FullOS-Panther.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$LocalLogDir = "",
        [Parameter(Mandatory = $false)]
        [string]$PantherSourceDir = "",
        [Parameter(Mandatory = $false)]
        $DeploymentState = $null,
        [Parameter(Mandatory = $false)]
        [string]$Engine = ""
    )

    # Determine target imaging engine folder (Dism or Setup) case-insensitively
    $targetEngineFolder = $null
    $rawEngine = $Engine
    if ([string]::IsNullOrWhiteSpace($rawEngine)) {
        if ($DeploymentState) {
            $osInstall = Get-LiteDeployStateProperty -InputObject $DeploymentState -Name 'OSInstall' -Default $null
            if ($osInstall) {
                $rawEngine = Get-LiteDeployStateProperty -InputObject $osInstall -Name 'Engine' -Default $null
            }
        }
        if ([string]::IsNullOrWhiteSpace($rawEngine) -and (Get-Variable -Name LiteDeployDeployment -Scope Global -ValueOnly -ErrorAction SilentlyContinue)) {
            $osInstall = Get-LiteDeployStateProperty -InputObject $global:LiteDeployDeployment -Name 'OSInstall' -Default $null
            if ($osInstall) {
                $rawEngine = Get-LiteDeployStateProperty -InputObject $osInstall -Name 'Engine' -Default $null
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($rawEngine)) {
        $trimmedEngine = $rawEngine.Trim()
        if ($trimmedEngine -match '^(?i)dism(\.exe)?$') {
            $targetEngineFolder = 'Dism'
        }
        elseif ($trimmedEngine -match '^(?i)setup(\.exe)?$') {
            $targetEngineFolder = 'Setup'
        }
        else {
            Write-LiteDeployLog "Warning: Unknown OSInstall.Engine '$rawEngine'; skipping FullOS Panther collection to avoid misclassifying engine logs." -Level 'WARNING' -Component 'OS.Engine'
            return $null
        }
    }
    else {
        Write-LiteDeployLog "Warning: No valid OSInstall.Engine found in deployment state; skipping FullOS Panther collection to avoid misclassifying engine logs." -Level 'WARNING' -Component 'OS.Engine'
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($LocalLogDir)) {
        $localRoot = if (Get-Variable -Name LiteDeployLocalRoot -Scope Global -ValueOnly -ErrorAction SilentlyContinue) {
            $global:LiteDeployLocalRoot
        } elseif (Get-Command Get-LiteDeployRoot -ErrorAction SilentlyContinue) {
            Get-LiteDeployRoot
        } else {
            $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "C:" }
            Join-Path $sysDrive "~LiteDeploy"
        }
        $LocalLogDir = Join-Path $localRoot "WorkLogs"
    }

    if ([string]::IsNullOrWhiteSpace($PantherSourceDir)) {
        $overridePanther = Get-Variable -Name LiteDeployFullOSPantherSourceDir -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if ($overridePanther) {
            $PantherSourceDir = [string]$overridePanther
        } else {
            $winDir = if ($env:windir) { $env:windir } elseif ($env:SystemRoot) { $env:SystemRoot } else { "C:\Windows" }
            $PantherSourceDir = Join-Path $winDir "Panther"
        }
    }

    if (-not (Test-Path -LiteralPath $PantherSourceDir -PathType Container -ErrorAction SilentlyContinue)) {
        return $null
    }

    $destFolder = Join-Path (Join-Path $LocalLogDir $targetEngineFolder) "FullOS-Panther"
    $destFolderCreated = (Test-Path -LiteralPath $destFolder -PathType Container -ErrorAction SilentlyContinue)
    $collectedFiles = @()

    foreach ($logName in @("setupact.log", "setuperr.log")) {
        $sourceFile = Join-Path $PantherSourceDir $logName
        if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf -ErrorAction SilentlyContinue)) {
            continue
        }

        try {
            if (-not $destFolderCreated) {
                if (-not (Test-Path -LiteralPath $destFolder)) {
                    $null = New-Item -Path $destFolder -ItemType Directory -Force -ErrorAction Stop
                }
                $destFolderCreated = $true
            }
            $targetFile = Join-Path $destFolder $logName
            Copy-Item -LiteralPath $sourceFile -Destination $targetFile -Force -ErrorAction Stop
            $collectedFiles += $targetFile
        }
        catch {
            Write-LiteDeployLog "Warning: Could not copy FullOS Panther log '$sourceFile': $($_.Exception.Message)" -Level 'WARNING' -Component 'OS.Engine'
        }
    }

    if ($collectedFiles.Count -gt 0) {
        Write-LiteDeployLog "Collected $($collectedFiles.Count) FullOS Panther log file(s) into '$destFolder'." -Level 'INFO' -Component 'OS.Engine'
    }

    return $destFolder
}

function Show-LiteDeployOSProbe {
    <#
    .SYNOPSIS
        Displays the FullOS live interactive monitor in the current console.
    .DESCRIPTION
        Renders session context and deployment engine state directly in the current console.
        Periodically terminates Audit Mode sysprep.exe so LiteDeploy owns the desktop.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [psobject]$DeploymentState = $null,

        [Parameter(Mandatory = $false)]
        [psobject]$ResumeResult = $null,

        [Parameter(Mandatory = $false)]
        [string]$LocalRoot = '',

        [Parameter(Mandatory = $false)]
        [string]$StatePath = '',

        [Parameter(Mandatory = $false)]
        [switch]$Once,

        [Parameter(Mandatory = $false)]
        [int]$RefreshSeconds = 2,

        [Parameter(Mandatory = $false)]
        [int]$MaxIterations = 0
    )

    $resolvedLocalRoot = if (-not [string]::IsNullOrWhiteSpace($LocalRoot)) {
        $LocalRoot
    } elseif ($ResumeResult -and $ResumeResult.PSObject.Properties['LocalRoot'] -and $ResumeResult.LocalRoot) {
        $ResumeResult.LocalRoot
    } else {
        $drive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
        Join-Path "$($drive.TrimEnd('\'))\" '~LiteDeploy'
    }

    $resolvedStatePath = if (-not [string]::IsNullOrWhiteSpace($StatePath)) {
        $StatePath
    } elseif ($ResumeResult -and $ResumeResult.PSObject.Properties['StatePath'] -and $ResumeResult.StatePath) {
        $ResumeResult.StatePath
    } else {
        Join-Path $resolvedLocalRoot 'DeploymentState.json'
    }

    $logDir = Join-Path $resolvedLocalRoot 'WorkLogs'
    $executionLog = Join-Path $logDir 'LiteDeploy.Execution.log'

    $who = try { [System.Security.Principal.WindowsIdentity]::GetCurrent() } catch { $null }
    $sessionId = try { (Get-Process -Id $PID).SessionId } catch { 0 }
    $userName = if ($who -and $who.Name) { $who.Name } elseif ($env:USERNAME) { $env:USERNAME } else { '(unknown)' }
    $isInteractive = [Environment]::UserInteractive

    try { Clear-Host } catch {}

    $iteration = 0
    while ($true) {
        $iteration++

        try { $null = Stop-LiteDeployAuditModeSysprep } catch {}

        # Live refresh: read state file from disk on every tick
        $st = $null
        if (Test-Path -LiteralPath $resolvedStatePath -PathType Leaf) {
            try {
                $st = if (Get-Command Read-LiteDeployStateFile -ErrorAction SilentlyContinue) {
                    Read-LiteDeployStateFile -Path $resolvedStatePath
                } elseif (Get-Command Get-LiteDeployState -ErrorAction SilentlyContinue) {
                    Get-LiteDeployState -Path $resolvedStatePath
                } else {
                    Get-Content -LiteralPath $resolvedStatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                }
            } catch {
                $st = $null
            }
        }

        # Fallback to in-memory snapshot if state file is absent, unreadable, or invalid
        if ($null -eq $st) {
            if ($DeploymentState) {
                $st = $DeploymentState
            } elseif ($ResumeResult -and $ResumeResult.PSObject.Properties['DeploymentState'] -and $ResumeResult.DeploymentState) {
                $st = $ResumeResult.DeploymentState
            }
        }

        $uid = '(none)'
        $status = '(none)'
        $currentStep = '(none)'
        $resumeCount = if ($ResumeResult -and $ResumeResult.PSObject.Properties['ResumeCount'] -and $null -ne $ResumeResult.ResumeCount) { [string]$ResumeResult.ResumeCount } else { '0' }
        $deployType = if ($ResumeResult -and $ResumeResult.PSObject.Properties['DeploymentType'] -and $ResumeResult.DeploymentType) { [string]$ResumeResult.DeploymentType } else { '(unknown)' }
        $networkPath = if ($ResumeResult -and $ResumeResult.PSObject.Properties['NetworkPath'] -and $ResumeResult.NetworkPath) { [string]$ResumeResult.NetworkPath } else { '(none)' }
        $shareDrive = if ($ResumeResult -and $ResumeResult.PSObject.Properties['ShareDrive'] -and $ResumeResult.ShareDrive) { [string]$ResumeResult.ShareDrive } else { '(none)' }
        $remoteLog = if ($ResumeResult -and $ResumeResult.PSObject.Properties['RemoteLogDir'] -and $ResumeResult.RemoteLogDir) { [string]$ResumeResult.RemoteLogDir } else { '(none)' }
        $computerName = '(none)'
        $workflowName = '(none)'
        $osApplied = '(unknown)'

        if ($st) {
            if ($st.PSObject.Properties['DeploymentUid'] -and $st.DeploymentUid) { $uid = [string]$st.DeploymentUid }
            if ($st.PSObject.Properties['Status'] -and $st.Status) { $status = [string]$st.Status }
            $exec = if ($st.PSObject.Properties['Execution']) { $st.Execution } else { $null }
            if ($exec) {
                if ($exec.PSObject.Properties['CurrentStep'] -and $exec.CurrentStep) { $currentStep = [string]$exec.CurrentStep }
                if ($exec.PSObject.Properties['ResumeCount']) { $resumeCount = [string]$exec.ResumeCount }
                if ($exec.PSObject.Properties['RemoteLogDir'] -and $exec.RemoteLogDir) { $remoteLog = [string]$exec.RemoteLogDir }
                $share = if ($exec.PSObject.Properties['FullOSShare']) { $exec.FullOSShare } else { $null }
                if ($share) {
                    if ($share.PSObject.Properties['DeploymentType'] -and $share.DeploymentType) { $deployType = [string]$share.DeploymentType }
                    if ($share.PSObject.Properties['NetworkPath'] -and $share.NetworkPath) { $networkPath = [string]$share.NetworkPath }
                    if ($share.PSObject.Properties['DriveLetter'] -and $share.DriveLetter) { $shareDrive = [string]$share.DriveLetter }
                }
            }
            $boot = if ($st.PSObject.Properties['BootObject']) { $st.BootObject } else { $null }
            if ($boot) {
                if ($deployType -eq '(unknown)' -and $boot.PSObject.Properties['DeploymentType'] -and $boot.DeploymentType) {
                    $deployType = [string]$boot.DeploymentType
                }
                if ($networkPath -eq '(none)' -and $boot.PSObject.Properties['NetworkPath'] -and $boot.NetworkPath) {
                    $networkPath = [string]$boot.NetworkPath
                }
            }
            $wf = if ($st.PSObject.Properties['Workflow']) { $st.Workflow } else { $null }
            if ($wf -and $wf.PSObject.Properties['SelectionData'] -and $wf.SelectionData) {
                $sel = $wf.SelectionData
                if ($sel.PSObject.Properties['ComputerName'] -and $sel.ComputerName) { $computerName = [string]$sel.ComputerName }
                if ($sel.PSObject.Properties['WorkflowName'] -and $sel.WorkflowName) { $workflowName = [string]$sel.WorkflowName }
            }
            if ($computerName -eq '(none)' -and $boot) {
                if ($boot.PSObject.Properties['ComputerSetup'] -and $boot.ComputerSetup) {
                    $cs = $boot.ComputerSetup
                    if ($cs.PSObject.Properties['ComputerName'] -and $cs.ComputerName) { $computerName = [string]$cs.ComputerName }
                }
                elseif ($boot.PSObject.Properties['ComputerName'] -and $boot.ComputerName) {
                    $computerName = [string]$boot.ComputerName
                }
            }
            if ($computerName -eq '(none)' -and $st.PSObject.Properties['SelectionData'] -and $st.SelectionData) {
                $sel = $st.SelectionData
                if ($sel.PSObject.Properties['ComputerName'] -and $sel.ComputerName) { $computerName = [string]$sel.ComputerName }
            }
            $os = if ($st.PSObject.Properties['OSInstall']) { $st.OSInstall } else { $null }
            if ($os -and $os.PSObject.Properties['Applied']) {
                $osApplied = [string][bool]$os.Applied
            }
            if ($st.PSObject.Properties['LogLocations'] -and $st.LogLocations) {
                if ($st.LogLocations.PSObject.Properties['RemoteLogDir'] -and $st.LogLocations.RemoteLogDir -and $remoteLog -eq '(none)') {
                    $remoteLog = [string]$st.LogLocations.RemoteLogDir
                }
                if ($st.LogLocations.PSObject.Properties['LocalExecutionLog'] -and $st.LogLocations.LocalExecutionLog) {
                    $executionLog = [string]$st.LogLocations.LocalExecutionLog
                }
            }
        }

        $zReady = $false
        if ($shareDrive -ne '(none)') {
            $zReady = Test-Path -LiteralPath (($shareDrive.TrimEnd('\') + '\')) -PathType Container -ErrorAction SilentlyContinue
        }

        if ($iteration -gt 1) {
            try { Clear-Host } catch {}
        }

        try {
            if ($host.UI.RawUI) {
                $host.UI.RawUI.WindowTitle = ('LiteDeploy FullOS - Live Monitor | {0}' -f $uid)
            }
        } catch {}

        Write-Host ''
        Write-Host '  =====================================================================' -ForegroundColor Cyan
        Write-Host '               LiteDeploy FullOS - Live Interactive Monitor            ' -ForegroundColor White
        Write-Host '  =====================================================================' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  Session Context:' -ForegroundColor Yellow
        Write-Host ('    User Account : {0} (Session ID: {1})' -f $userName, $sessionId)
        Write-Host ('    Interactive  : {0}' -f $isInteractive)
        Write-Host ('    Sysprep Watch: Active (background sweep)' ) -ForegroundColor Green
        $shieldActive = $false
        try {
            $sm = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\LiteDeploy\FullOS' -Name 'ShieldingActive' -ErrorAction SilentlyContinue
            if ($sm -and [int]$sm.ShieldingActive -eq 1) { $shieldActive = $true }
        } catch {}
        if ($shieldActive) {
            Write-Host ('    Shielding    : Active (GPO frozen, CAD/Notices suppressed)' ) -ForegroundColor Yellow
        }
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
        Write-Host ('    State File   : {0}' -f $resolvedStatePath)
        Write-Host ('    Local Root   : {0}' -f $resolvedLocalRoot)
        Write-Host ('    Execution Log: {0}' -f $executionLog)
        Write-Host ''
        Write-Host '  ---------------------------------------------------------------------' -ForegroundColor DarkGray
        Write-Host '  [Shell kept OPEN for inspection. Press Ctrl+C for interactive prompt]' -ForegroundColor Green
        Write-Host ('  Last update  : {0}' -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor DarkGray

        if ($Once -or ($MaxIterations -gt 0 -and $iteration -ge $MaxIterations)) {
            break
        }

        Start-Sleep -Seconds $RefreshSeconds
    }
}

function Stop-LiteDeployAuditModeSysprep {
    <#
    .SYNOPSIS
        Terminates Audit Mode System Preparation Tool UI (sysprep.exe) across all sessions.
    #>
    [CmdletBinding()]
    param()

    $killed = 0
    foreach ($proc in @(Get-Process -Name 'sysprep' -ErrorAction SilentlyContinue)) {
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            $killed++
        }
        catch {
            try {
                & taskkill.exe /F /PID $proc.Id /T 2>$null
                $killed++
            }
            catch {}
        }
    }

    try {
        $null = & taskkill.exe /F /IM sysprep.exe /T 2>$null
    }
    catch {}

    return $killed
}

# ==============================================================================
# 3b. REBOOT SURVIVAL — HKLM Run (interactive logon), NOT Setup CmdLine
# ==============================================================================
# Setup\CmdLine + SetupType=2 causes Windows Setup-continue reboot loops when
# re-armed across failures. Use HKLM\...\Run so FullOS starts as the Autologon
# Administrator on each interactive logon instead.

function Set-LiteDeployFullOSHighPerformance {
    <#
    .SYNOPSIS
        Sets the active power scheme to High Performance and disables AC/DC sleep and display timeouts.
    .DESCRIPTION
        Applies universally across all deployment workflows in FullOS (Standard, Intune, Domain Join)
        to prevent system suspension, standby, and screen locking during software installations.
        Activates scheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c (or duplicates it if missing) and
        sets monitor, disk, standby, and hibernate timeouts to 0 on both AC and DC power.
    .OUTPUTS
        [pscustomobject] containing Success, SchemeSet, TimeoutsConfigured, and Messages.
    .NOTES
        Safe to invoke under all credentials and environments. Non-destructive.
    #>
    [CmdletBinding()]
    param()

    $result = [pscustomobject]@{
        Success            = $true
        SchemeSet          = $false
        TimeoutsConfigured = $false
        HighPerfGuid       = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
        Messages           = New-Object System.Collections.Generic.List[string]
    }

    try {
        $highPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
        $setOut = & powercfg.exe /setactive $highPerfGuid 2>&1
        if ($LASTEXITCODE -eq 0) {
            $result.SchemeSet = $true
            $result.Messages.Add("Activated High Performance power scheme ($highPerfGuid).")
        }
        else {
            # Scheme might not be imported; duplicate built-in High Performance scheme
            $dupOut = & powercfg.exe /duplicatescheme $highPerfGuid 2>&1
            if ($LASTEXITCODE -eq 0 -and $dupOut -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                $newGuid = $Matches[1]
                & powercfg.exe /setactive $newGuid 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $result.SchemeSet = $true
                    $result.HighPerfGuid = $newGuid
                    $result.Messages.Add("Duplicated and activated High Performance power scheme ($newGuid).")
                }
            }
            if (-not $result.SchemeSet) {
                $result.Messages.Add("Could not activate High Performance power scheme: $setOut")
            }
        }

        # Zero out AC and DC timeouts so machine does not sleep, hibernate, turn off disk, or blank display
        $timeouts = @(
            'monitor-timeout-ac', 'disk-timeout-ac', 'standby-timeout-ac', 'hibernate-timeout-ac',
            'monitor-timeout-dc', 'disk-timeout-dc', 'standby-timeout-dc', 'hibernate-timeout-dc'
        )
        foreach ($t in $timeouts) {
            & powercfg.exe /change $t 0 2>&1 | Out-Null
        }
        $result.TimeoutsConfigured = $true
        $result.Messages.Add("Configured power timeouts (monitor, disk, standby, hibernate set to 0 on AC/DC).")
    }
    catch {
        $result.Success = $false
        $result.Messages.Add("Power configuration exception: $($_.Exception.Message)")
    }

    return $result
}

function Enable-LiteDeployFullOSShielding {
    <#
    .SYNOPSIS
        Applies environment shielding (GPO freeze, AutoLogon preservation, CAD and LegalNotice suppression).
    .DESCRIPTION
        When FullOS executes under a non-builtin Administrator account (e.g. ephemeral service account
        LD-<UID> in Domain Join), background domain Group Policies can re-enable UAC, enforce CAD,
        display modal legal notice dialogues, or kill AutoLogon before packages finish.
        This function:
          1. Freezes background GPO refresh (DisableGPO = 1).
          2. Backs up and blanks interactive legalnoticecaption and legalnoticetext.
          3. Suppresses Ctrl+Alt+Del (DisableCAD = 1).
          4. Suppresses Lock Screen and screen savers (NoLockScreen = 1).
          5. Preserves AutoLogon count at 999.
    .PARAMETER UserName
        The active interactive identity username (e.g. LD-<UID>) recorded in the shielding marker.
    .OUTPUTS
        [pscustomobject] containing Success, GpoFrozen, LegalNoticeBlank, CadDisabled, LockScreenBlank, AutoLogonArmed, and Message.
    .NOTES
        All modified properties are backed up to HKLM:\SOFTWARE\LiteDeploy\FullOS\ShieldingBackup for cleanup.
    #>
    [CmdletBinding()]
    param(
        [string]$UserName = ''
    )

    $markerKey = 'HKLM:\SOFTWARE\LiteDeploy\FullOS'
    $backupKey = 'HKLM:\SOFTWARE\LiteDeploy\FullOS\ShieldingBackup'
    $systemPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    $legalNoticeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $winlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $personalizationKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'
    $desktopKey = 'HKCU:\Control Panel\Desktop'

    $shieldResult = [pscustomobject]@{
        Success          = $true
        GpoFrozen        = $false
        LegalNoticeBlank = $false
        CadDisabled      = $false
        LockScreenBlank  = $false
        AutoLogonArmed   = $false
        UserName         = $UserName
        Message          = ''
    }

    try {
        foreach ($k in @($markerKey, $backupKey, $systemPolicyKey, $legalNoticeKey, $winlogonKey, $personalizationKey)) {
            if (-not (Test-Path -LiteralPath $k)) {
                $null = New-Item -Path $k -Force -ErrorAction Stop
            }
        }

        # 1. Freeze GPO background refresh (DisableGPO = 1)
        $existingGpo = (Get-ItemProperty -LiteralPath $systemPolicyKey -Name 'DisableGPO' -ErrorAction SilentlyContinue)
        if ($existingGpo -and $null -ne $existingGpo.DisableGPO) {
            Set-ItemProperty -LiteralPath $backupKey -Name 'DisableGPO' -Value [int]$existingGpo.DisableGPO -Type DWord -Force -ErrorAction SilentlyContinue
        }
        Set-ItemProperty -LiteralPath $systemPolicyKey -Name 'DisableGPO' -Value 1 -Type DWord -Force -ErrorAction Stop
        $shieldResult.GpoFrozen = $true

        # 2. Backup and blank legal notice caption and text
        $existingCaption = (Get-ItemProperty -LiteralPath $legalNoticeKey -Name 'legalnoticecaption' -ErrorAction SilentlyContinue)
        $existingText = (Get-ItemProperty -LiteralPath $legalNoticeKey -Name 'legalnoticetext' -ErrorAction SilentlyContinue)
        if ($existingCaption -and $existingCaption.legalnoticecaption) {
            Set-ItemProperty -LiteralPath $backupKey -Name 'legalnoticecaption' -Value [string]$existingCaption.legalnoticecaption -Type String -Force -ErrorAction SilentlyContinue
        }
        if ($existingText -and $existingText.legalnoticetext) {
            Set-ItemProperty -LiteralPath $backupKey -Name 'legalnoticetext' -Value [string]$existingText.legalnoticetext -Type String -Force -ErrorAction SilentlyContinue
        }
        Set-ItemProperty -LiteralPath $legalNoticeKey -Name 'legalnoticecaption' -Value '' -Type String -Force -ErrorAction Stop
        Set-ItemProperty -LiteralPath $legalNoticeKey -Name 'legalnoticetext' -Value '' -Type String -Force -ErrorAction Stop
        $shieldResult.LegalNoticeBlank = $true

        # 3. Suppress Ctrl+Alt+Del (DisableCAD = 1)
        $existingCad = (Get-ItemProperty -LiteralPath $winlogonKey -Name 'DisableCAD' -ErrorAction SilentlyContinue)
        if ($existingCad -and $null -ne $existingCad.DisableCAD) {
            Set-ItemProperty -LiteralPath $backupKey -Name 'DisableCAD' -Value [int]$existingCad.DisableCAD -Type DWord -Force -ErrorAction SilentlyContinue
        }
        Set-ItemProperty -LiteralPath $winlogonKey -Name 'DisableCAD' -Value 1 -Type DWord -Force -ErrorAction Stop
        $shieldResult.CadDisabled = $true

        # 4. Suppress Lock Screen & Screen Saver
        $existingLock = (Get-ItemProperty -LiteralPath $personalizationKey -Name 'NoLockScreen' -ErrorAction SilentlyContinue)
        if ($existingLock -and $null -ne $existingLock.NoLockScreen) {
            Set-ItemProperty -LiteralPath $backupKey -Name 'NoLockScreen' -Value [int]$existingLock.NoLockScreen -Type DWord -Force -ErrorAction SilentlyContinue
        }
        Set-ItemProperty -LiteralPath $personalizationKey -Name 'NoLockScreen' -Value 1 -Type DWord -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $desktopKey) {
            Set-ItemProperty -LiteralPath $desktopKey -Name 'ScreenSaveActive' -Value '0' -Type String -Force -ErrorAction SilentlyContinue
        }
        $shieldResult.LockScreenBlank = $true

        # 5. Preserve AutoLogon with high count
        Set-ItemProperty -LiteralPath $winlogonKey -Name 'AutoAdminLogon' -Value '1' -Type String -Force -ErrorAction Stop
        Set-ItemProperty -LiteralPath $winlogonKey -Name 'AutoLogonCount' -Value 999 -Type DWord -Force -ErrorAction Stop
        $shieldResult.AutoLogonArmed = $true

        # 6. Mark shielding active
        Set-ItemProperty -LiteralPath $markerKey -Name 'ShieldingActive' -Value 1 -Type DWord -Force -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($UserName)) {
            Set-ItemProperty -LiteralPath $markerKey -Name 'ShieldingUser' -Value $UserName -Type String -Force -ErrorAction Stop
        }

        $shieldResult.Message = 'Environment shielded: DisableGPO=1, LegalNotices blanked, DisableCAD=1, NoLockScreen=1, AutoLogonCount=999.'
    }
    catch {
        $shieldResult.Success = $false
        $shieldResult.Message = "Shielding error: $($_.Exception.Message)"
    }

    return $shieldResult
}

function Disable-LiteDeployFullOSShielding {
    <#
    .SYNOPSIS
        Removes environment shielding, restores original policies from backup, and triggers group policy refresh.
    .DESCRIPTION
        Invoked during final FullOS completion and cleanup (Clear-LiteDeployFullOSRunKey).
        Restores DisableGPO, NoLockScreen, and legal notice registry values from
        HKLM:\SOFTWARE\LiteDeploy\FullOS\ShieldingBackup, removes shielding markers, and
        optionally executes 'gpupdate.exe /force' in the background to apply corporate policies.
    .PARAMETER SkipGpUpdate
        If specified, bypasses launching gpupdate.exe /force.
    .OUTPUTS
        [pscustomobject] containing Success, ShieldingRemoved, GpoUnfrozen, LegalNoticesRestored, LockScreenRestored, GpUpdateTriggered, and Message.
    .NOTES
        Safe no-op when ShieldingActive marker is not present.
    #>
    [CmdletBinding()]
    param(
        [switch]$SkipGpUpdate
    )

    $markerKey = 'HKLM:\SOFTWARE\LiteDeploy\FullOS'
    $backupKey = 'HKLM:\SOFTWARE\LiteDeploy\FullOS\ShieldingBackup'
    $systemPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    $legalNoticeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $winlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $personalizationKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'

    $result = [pscustomobject]@{
        Success              = $true
        ShieldingRemoved     = $false
        GpoUnfrozen          = $false
        LegalNoticesRestored = $false
        LockScreenRestored   = $false
        GpUpdateTriggered    = $false
        Message              = ''
    }

    try {
        $shieldActive = $false
        if (Test-Path -LiteralPath $markerKey) {
            $m = Get-ItemProperty -LiteralPath $markerKey -Name 'ShieldingActive' -ErrorAction SilentlyContinue
            if ($m -and [int]$m.ShieldingActive -eq 1) { $shieldActive = $true }
        }

        if (-not $shieldActive -and -not (Test-Path -LiteralPath $backupKey)) {
            $result.Message = 'No active shielding marker or backup found; nothing to unshield.'
            return $result
        }

        # 1. Unfreeze GPO (restore original or remove DisableGPO)
        if (Test-Path -LiteralPath $systemPolicyKey) {
            $gpoBackup = $null
            if (Test-Path -LiteralPath $backupKey) {
                $gpoBackup = Get-ItemProperty -LiteralPath $backupKey -Name 'DisableGPO' -ErrorAction SilentlyContinue
            }
            if ($gpoBackup -and $null -ne $gpoBackup.DisableGPO) {
                Set-ItemProperty -LiteralPath $systemPolicyKey -Name 'DisableGPO' -Value [int]$gpoBackup.DisableGPO -Type DWord -Force -ErrorAction SilentlyContinue
            }
            else {
                Remove-ItemProperty -LiteralPath $systemPolicyKey -Name 'DisableGPO' -Force -ErrorAction SilentlyContinue
            }
            $result.GpoUnfrozen = $true
        }

        # 2. Restore Lock Screen (NoLockScreen)
        if (Test-Path -LiteralPath $personalizationKey) {
            $lockBackup = $null
            if (Test-Path -LiteralPath $backupKey) {
                $lockBackup = Get-ItemProperty -LiteralPath $backupKey -Name 'NoLockScreen' -ErrorAction SilentlyContinue
            }
            if ($lockBackup -and $null -ne $lockBackup.NoLockScreen) {
                Set-ItemProperty -LiteralPath $personalizationKey -Name 'NoLockScreen' -Value [int]$lockBackup.NoLockScreen -Type DWord -Force -ErrorAction SilentlyContinue
            }
            else {
                Remove-ItemProperty -LiteralPath $personalizationKey -Name 'NoLockScreen' -Force -ErrorAction SilentlyContinue
            }
            $result.LockScreenRestored = $true
        }

        # 3. Restore CAD (DisableCAD)
        if (Test-Path -LiteralPath $winlogonKey) {
            $cadBackup = $null
            if (Test-Path -LiteralPath $backupKey) {
                $cadBackup = Get-ItemProperty -LiteralPath $backupKey -Name 'DisableCAD' -ErrorAction SilentlyContinue
            }
            if ($cadBackup -and $null -ne $cadBackup.DisableCAD) {
                Set-ItemProperty -LiteralPath $winlogonKey -Name 'DisableCAD' -Value [int]$cadBackup.DisableCAD -Type DWord -Force -ErrorAction SilentlyContinue
            }
            else {
                Remove-ItemProperty -LiteralPath $winlogonKey -Name 'DisableCAD' -Force -ErrorAction SilentlyContinue
            }
        }

        # 4. Restore Legal Notices if backed up
        if (Test-Path -LiteralPath $backupKey) {
            $backup = Get-ItemProperty -LiteralPath $backupKey -ErrorAction SilentlyContinue
            if ($backup) {
                if ($backup.PSObject.Properties['legalnoticecaption']) {
                    Set-ItemProperty -LiteralPath $legalNoticeKey -Name 'legalnoticecaption' -Value [string]$backup.legalnoticecaption -Type String -Force -ErrorAction SilentlyContinue
                }
                if ($backup.PSObject.Properties['legalnoticetext']) {
                    Set-ItemProperty -LiteralPath $legalNoticeKey -Name 'legalnoticetext' -Value [string]$backup.legalnoticetext -Type String -Force -ErrorAction SilentlyContinue
                }
                $result.LegalNoticesRestored = $true
            }
            Remove-Item -LiteralPath $backupKey -Recurse -Force -ErrorAction SilentlyContinue
        }

        # 5. Clean up AutoLogon password if left in registry
        if (Test-Path -LiteralPath $winlogonKey) {
            Remove-ItemProperty -LiteralPath $winlogonKey -Name 'DefaultPassword' -Force -ErrorAction SilentlyContinue
        }

        # 6. Remove shielding markers
        if (Test-Path -LiteralPath $markerKey) {
            Remove-ItemProperty -LiteralPath $markerKey -Name 'ShieldingActive' -Force -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $markerKey -Name 'ShieldingUser' -Force -ErrorAction SilentlyContinue
        }
        $result.ShieldingRemoved = $true

        # 7. Trigger gpupdate /force in background if not skipped
        if (-not $SkipGpUpdate) {
            try {
                $p = Start-Process -FilePath 'gpupdate.exe' -ArgumentList '/force' -NoNewWindow -PassThru -ErrorAction SilentlyContinue
                $result.GpUpdateTriggered = ($null -ne $p)
            }
            catch {}
        }

        $result.Message = 'Shielding removed: GPO un-frozen, legal notices restored, CAD/LockScreen restored, gpupdate triggered.'
    }
    catch {
        $result.Success = $false
        $result.Message = "Unshielding error: $($_.Exception.Message)"
    }

    return $result
}

function Get-LiteDeployFullOSRunCommand {
    <#
    .SYNOPSIS
        Builds the HKLM Run command that launches FullOS at interactive logon.
    #>
    param(
        [string]$LocalRootName = '~LiteDeploy',
        [string]$OsDriveLetter = $env:SystemDrive
    )

    $drive = ($OsDriveLetter -replace '[\\/]+$', '').Trim()
    if ([string]::IsNullOrWhiteSpace($drive)) { $drive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' } }
    if ($drive.Length -eq 1) { $drive += ':' }
    $fullOsPath = Join-Path "$drive\" ($LocalRootName.TrimStart('\') + '\Engine\Runtime\LiteDeploy.OS.Engine.ps1')
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return ('"{0}" -NoProfile -STA -ExecutionPolicy Bypass -File "{1}" -LocalRootName "{2}" -OsDriveLetter "{3}"' -f `
            $powerShell, $fullOsPath, $LocalRootName, $drive)
}

function Set-LiteDeployFullOSRunKey {
    <#
    .SYNOPSIS
        Arms HKLM Run so FullOS relaunches at Administrator Autologon after reboot.
    #>
    param(
        [string]$LocalRootName = '~LiteDeploy',
        [string]$OsDriveLetter = $env:SystemDrive,
        [string]$ValueName = 'LiteDeployFullOS',
        [string]$RunKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )

    $cmd = Get-LiteDeployFullOSRunCommand -LocalRootName $LocalRootName -OsDriveLetter $OsDriveLetter
    if (-not (Test-Path -LiteralPath $RunKey)) {
        $null = New-Item -Path $RunKey -Force -ErrorAction Stop
    }
    Set-ItemProperty -LiteralPath $RunKey -Name $ValueName -Value $cmd -Type String -Force -ErrorAction Stop

    return [pscustomobject]@{
        Success      = $true
        RunKey       = $RunKey
        ValueName    = $ValueName
        Command      = $cmd
        LocalRootName = $LocalRootName
        OsDriveLetter = $OsDriveLetter
    }
}

function Set-LiteDeployFullOSAutoLogon {
    <#
    .SYNOPSIS
        Re-arms Winlogon AutoAdminLogon before a mid-deployment reboot.
    .DESCRIPTION
        Windows purges DefaultPassword from Winlogon upon initial interactive logon, and Active Directory
        domain join alters DefaultDomainName to the domain NetBIOS name.
        Before an intermediate restart (e.g. exit code 3010), this function restores unattended logon
        by re-injecting DefaultPassword, DefaultUserName, forcing DefaultDomainName = '.' (or local computer),
        and setting AutoAdminLogon = '1' with AutoLogonCount = 999.
        Credentials can be supplied directly or retrieved in memory via WinPECT ('LocalServiceAccount').
    .PARAMETER UserName
        The local user account to logon as (e.g. 'LD-<UID>' or 'Administrator').
    .PARAMETER Password
        Plain text password to inject into DefaultPassword.
    .PARAMETER Domain
        Default domain for Winlogon (default: '.' to enforce local machine authentication).
    .PARAMETER LocalRoot
        Path to local ~LiteDeploy directory to resolve WinPECT 'LocalServiceAccount' secret if Password is not supplied.
    .OUTPUTS
        [pscustomobject] containing Success, UserName, Domain, AutoLogonArmed, and Message.
    #>
    [CmdletBinding()]
    param(
        [string]$UserName = '',
        [string]$Password = '',
        [string]$Domain = '.',
        [string]$LocalRoot = ''
    )

    $result = [pscustomobject]@{
        Success        = $true
        UserName       = $UserName
        Domain         = $Domain
        AutoLogonArmed = $false
        Message        = ''
    }

    try {
        $winlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        if (-not (Test-Path -LiteralPath $winlogonKey)) {
            $null = New-Item -Path $winlogonKey -Force -ErrorAction Stop
        }

        # If Password was not supplied, try retrieving 'LocalServiceAccount' from WinPECT in memory
        if ([string]::IsNullOrWhiteSpace($Password) -and -not [string]::IsNullOrWhiteSpace($LocalRoot)) {
            if (Get-Command Get-LiteDeployFullOSSecret -ErrorAction SilentlyContinue) {
                $sec = Get-LiteDeployFullOSSecret -LocalRoot $LocalRoot -SecretId 'LocalServiceAccount'
                if ($sec -and $sec.Success -and $sec.Credential) {
                    if ([string]::IsNullOrWhiteSpace($UserName)) {
                        $UserName = $sec.UserName
                        $result.UserName = $UserName
                    }
                    $Password = $sec.Credential.GetNetworkCredential().Password
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($UserName)) {
            # Check current identity or Winlogon DefaultUserName
            $existing = Get-ItemProperty -LiteralPath $winlogonKey -Name 'DefaultUserName' -ErrorAction SilentlyContinue
            if ($existing -and $existing.PSObject.Properties['DefaultUserName'] -and -not [string]::IsNullOrWhiteSpace($existing.DefaultUserName)) {
                $UserName = [string]$existing.DefaultUserName
                $result.UserName = $UserName
            }
        }

        Set-ItemProperty -LiteralPath $winlogonKey -Name 'AutoAdminLogon' -Value '1' -Type String -Force -ErrorAction Stop
        Set-ItemProperty -LiteralPath $winlogonKey -Name 'AutoLogonCount' -Value 999 -Type DWord -Force -ErrorAction Stop

        if (-not [string]::IsNullOrWhiteSpace($UserName)) {
            Set-ItemProperty -LiteralPath $winlogonKey -Name 'DefaultUserName' -Value $UserName -Type String -Force -ErrorAction Stop
        }

        if (-not [string]::IsNullOrWhiteSpace($Password)) {
            Set-ItemProperty -LiteralPath $winlogonKey -Name 'DefaultPassword' -Value $Password -Type String -Force -ErrorAction Stop
        }

        if (-not [string]::IsNullOrWhiteSpace($Domain)) {
            Set-ItemProperty -LiteralPath $winlogonKey -Name 'DefaultDomainName' -Value $Domain -Type String -Force -ErrorAction Stop
        }

        $result.AutoLogonArmed = $true
        $result.Message = "Winlogon AutoAdminLogon armed for user '$UserName' (Domain='$Domain', Count=999)."
    }
    catch {
        $result.Success = $false
        $result.Message = "Failed to set Winlogon AutoLogon: $($_.Exception.Message)"
    }

    return $result
}

function Restore-LiteDeployFullOSUacBypass {
    <#
    .SYNOPSIS
        Restores EnableLUA=1 when Domain Join specialize marked UacBypassed (temporary UAC off for FullOS).
    .NOTES
        A reboot after restore is required for UAC to apply again. Safe no-op when marker is absent.
    #>
    $markerKey = 'HKLM:\SOFTWARE\LiteDeploy\FullOS'
    $policyKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $restored = $false
    $markerCleared = $false

    try {
        $marker = $null
        if (Test-Path -LiteralPath $markerKey) {
            $marker = Get-ItemProperty -LiteralPath $markerKey -Name 'UacBypassed' -ErrorAction SilentlyContinue
        }
        if ($marker -and [int]$marker.UacBypassed -eq 1) {
            if (-not (Test-Path -LiteralPath $policyKey)) {
                $null = New-Item -Path $policyKey -Force -ErrorAction Stop
            }
            Set-ItemProperty -LiteralPath $policyKey -Name 'EnableLUA' -Value 1 -Type DWord -Force -ErrorAction Stop
            $restored = $true
            Remove-ItemProperty -LiteralPath $markerKey -Name 'UacBypassed' -Force -ErrorAction SilentlyContinue
            $markerCleared = $true
        }
    }
    catch {
        return [pscustomobject]@{
            Success        = $false
            Restored       = $restored
            MarkerCleared  = $markerCleared
            Message        = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        Success       = $true
        Restored      = $restored
        MarkerCleared = $markerCleared
        Message       = $(if ($restored) { 'EnableLUA restored to 1 (reboot required for UAC).' } else { 'No UacBypassed marker; nothing to restore.' })
    }
}

function Clear-LiteDeployFullOSRunKey {
    <#
    .SYNOPSIS
        Removes the HKLM Run value so FullOS stops auto-launching at logon.
        Also restores temporary Domain Join UAC bypass (EnableLUA) and removes environment shielding.
    #>
    param(
        [string]$ValueName = 'LiteDeployFullOS',
        [string]$RunKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )

    $uac = Restore-LiteDeployFullOSUacBypass
    $shielding = Disable-LiteDeployFullOSShielding

    if (-not (Test-Path -LiteralPath $RunKey)) {
        return [pscustomobject]@{ Success = $true; Cleared = $false; Message = 'Run key not present.'; UacRestore = $uac; ShieldingRestore = $shielding }
    }
    $existing = Get-ItemProperty -LiteralPath $RunKey -Name $ValueName -ErrorAction SilentlyContinue
    if ($null -eq $existing -or -not ($existing.PSObject.Properties.Name -contains $ValueName)) {
        return [pscustomobject]@{ Success = $true; Cleared = $false; Message = 'Run value not present.'; UacRestore = $uac; ShieldingRestore = $shielding }
    }
    Remove-ItemProperty -LiteralPath $RunKey -Name $ValueName -Force -ErrorAction Stop
    return [pscustomobject]@{ Success = $true; Cleared = $true; ValueName = $ValueName; RunKey = $RunKey; UacRestore = $uac; ShieldingRestore = $shielding }
}

function Test-LiteDeployOwnedSetupCmdLine {
    <#
    .SYNOPSIS
        True when Setup\CmdLine points at LiteDeploy FullOS (legacy hijack), not stock sysprep.
    #>
    param([string]$RegistryRoot = 'HKLM:\SYSTEM\Setup')

    if (-not (Test-Path -LiteralPath $RegistryRoot)) { return $false }
    try {
        $cmd = [string](Get-ItemProperty -LiteralPath $RegistryRoot -Name 'CmdLine' -ErrorAction Stop).CmdLine
    }
    catch {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }
    # Stock Audit continue is typically sysprep.exe — leave that alone.
    if ($cmd -match '(?i)sysprep(\.exe)?') { return $false }
    return ($cmd -match '(?i)LiteDeploy\.FullOS\.ps1|~LiteDeploy')
}

function Clear-LiteDeployFullOSSetupCmdLine {
    <#
    .SYNOPSIS
        Clears Setup continue only when CmdLine was hijacked to LiteDeploy FullOS.
        Leaves stock sysprep Setup\CmdLine intact; FullOS kills sysprep.exe instead.
    #>
    param(
        [string]$RegistryRoot = 'HKLM:\SYSTEM\Setup',
        [switch]$Force
    )

    if (-not (Test-Path -LiteralPath $RegistryRoot)) {
        return [pscustomobject]@{ Success = $true; Cleared = $false; Message = 'Setup key not present.' }
    }

    $owned = Test-LiteDeployOwnedSetupCmdLine -RegistryRoot $RegistryRoot
    if (-not $Force -and -not $owned) {
        return [pscustomobject]@{
            Success      = $true
            Cleared      = $false
            RegistryRoot = $RegistryRoot
            Message      = 'Setup CmdLine left unchanged (stock sysprep or empty).'
        }
    }

    Set-ItemProperty -LiteralPath $RegistryRoot -Name 'SetupType' -Value 0 -Type DWord -Force -ErrorAction Stop
    try {
        Set-ItemProperty -LiteralPath $RegistryRoot -Name 'CmdLine' -Value '' -Type String -Force -ErrorAction Stop
    }
    catch {
        Remove-ItemProperty -LiteralPath $RegistryRoot -Name 'CmdLine' -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        Success      = $true
        Cleared      = $true
        RegistryRoot = $RegistryRoot
        SetupType    = 0
        Message      = 'Cleared LiteDeploy-owned Setup CmdLine.'
    }
}

# Legacy aliases kept so older call sites / docs referring to "SetupCmdLine arm" still resolve to Run.
function Set-LiteDeployFullOSSetupCmdLine {
    <#
    .SYNOPSIS
        Legacy compatibility shim: redirects Setup\CmdLine arming to Set-LiteDeployFullOSRunKey.
    .DESCRIPTION
        Arming Setup\CmdLine caused Windows Setup-continue reboot loops. LiteDeploy FullOS
        standardized on HKLM\...\Run for interactive Administrator logon resume. This shim
        clears any legacy LiteDeploy Setup CmdLine hijack and arms HKLM Run instead.
    #>
    param(
        [string]$LocalRootName = '~LiteDeploy',
        [string]$OsDriveLetter = $env:SystemDrive,
        [string]$FullOSPath = '',
        [string]$RegistryRoot = 'HKLM:\SYSTEM\Setup'
    )
    # Do not arm Setup continue — that caused reboot loops. Arm HKLM Run; only clear LiteDeploy hijacks.
    $null = Clear-LiteDeployFullOSSetupCmdLine -RegistryRoot $RegistryRoot
    return Set-LiteDeployFullOSRunKey -LocalRootName $LocalRootName -OsDriveLetter $OsDriveLetter
}

# ==============================================================================
# 4. SHARE CONNECTION HELPER
# ==============================================================================

function Get-LiteDeployFullOSSecret {
    <#
    .SYNOPSIS
        Retrieves a secret in memory: tries WinPECT CredentialTransfer.bin in-memory decryption first,
        then falls back to CLIXML if present. Never writes plaintext or DPAPI to disk.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][string]$SecretId
    )

    $packagePath = Join-Path $LocalRoot 'Content\Credentials\CredentialTransfer.bin'
    if (Test-Path -LiteralPath $packagePath -PathType Leaf) {
        $winpectEngine = Join-Path $LocalRoot 'Engine\Tools\WinPECT\WinPECredentialTransfer.ps1'
        if (-not (Test-Path -LiteralPath $winpectEngine -PathType Leaf)) {
            $winpectEngine = Join-Path $LocalRoot 'Tools\WinPECT\WinPECredentialTransfer.ps1'
        }
        if (Test-Path -LiteralPath $winpectEngine -PathType Leaf) {
            if (-not (Get-Command Read-WPCTCredentialTransfer -ErrorAction SilentlyContinue)) {
                . $winpectEngine
            }
            if (Get-Command Read-WPCTCredentialTransfer -ErrorAction SilentlyContinue) {
                $subKeys = @('LiteDeploy\CredentialTransfer', 'WinPECredentialTransfer\Bootstrap')
                $lastReadError = $null
                foreach ($subKey in $subKeys) {
                    try {
                        $read = Read-WPCTCredentialTransfer `
                            -SecretFilePath $packagePath `
                            -RegistrySubKey $subKey `
                            -ErrorAction Stop
                        if ($read -and $read.Success -and $read.Payload) {
                            $found = @($read.Payload.Secrets) | Where-Object { $_.Id -eq $SecretId }
                            if ($found) {
                                $user = [string]$found.Username
                                $sec = ConvertTo-SecureString ([string]$found.Password) -AsPlainText -Force
                                return [pscustomobject]@{
                                    Success    = $true
                                    Id         = $SecretId
                                    UserName   = $user
                                    Credential = (New-Object System.Management.Automation.PSCredential($user, $sec))
                                    Source     = 'WinPECT.InMemory'
                                }
                            }
                        }
                    }
                    catch {
                        $lastReadError = $_.Exception.Message
                    }
                }
            }
        }
    }

    # Fallback to CLIXML if present
    $clixmlPath = Join-Path $LocalRoot ("Content\Credentials\{0}.xml" -f $SecretId)
    if (Test-Path -LiteralPath $clixmlPath -PathType Leaf) {
        try {
            $credObj = Import-Clixml -LiteralPath $clixmlPath -ErrorAction Stop
            if ($credObj -is [System.Management.Automation.PSCredential]) {
                return [pscustomobject]@{
                    Success    = $true
                    Id         = $SecretId
                    UserName   = $credObj.UserName
                    Credential = $credObj
                    Source     = 'CLIXML'
                }
            }
        }
        catch {}
    }

    $detailMsg = if ($lastReadError) { " (WinPECT error: $lastReadError)" } else { '' }
    return [pscustomobject]@{
        Success = $false
        Id      = $SecretId
        Message = "Secret '$SecretId' not found in WinPECT package or CLIXML$detailMsg."
    }
}

function Connect-LiteDeployFullOSDeploymentShare {
    <#
    .SYNOPSIS
        Maps the DeploymentShare to Z: in the current user session using native PowerShell
        cmdlets and in-memory PSCredential (never exposing credentials to net.exe or process args).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][string]$NetworkPath,
        [string]$DriveLetter = 'Z:',
        [string]$CredentialId = 'DeploymentShare'
    )

    $cleanDrive = $DriveLetter.TrimEnd('\').TrimEnd(':') + ':'
    $driveName = $cleanDrive.TrimEnd(':')
    if ([string]::IsNullOrWhiteSpace($NetworkPath) -or $NetworkPath -notmatch '^\\\\') {
        throw "NetworkPath must be a UNC path (got '$NetworkPath')."
    }

    $secretResult = Get-LiteDeployFullOSSecret -LocalRoot $LocalRoot -SecretId $CredentialId
    if (-not $secretResult.Success) {
        throw "Cannot connect DeploymentShare: $($secretResult.Message)"
    }

    $credential = $secretResult.Credential
    $userName = $secretResult.UserName

    try {
        # Ensure EnableLinkedConnections so Explorer and elevated admin share drive Z:
        try {
            $policiesKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
            if (Test-Path -LiteralPath $policiesKey) {
                Set-ItemProperty -Path $policiesKey -Name 'EnableLinkedConnections' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            }
        }
        catch {}

        # Clean up any existing mapping on the drive letter
        if (Get-Command Remove-SmbMapping -ErrorAction SilentlyContinue) {
            try { Remove-SmbMapping -LocalPath $cleanDrive -Force -UpdateProfile -ErrorAction SilentlyContinue } catch {}
        }
        if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
            try { Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue } catch {}
        }

        $mapped = $false
        $lastError = ''

        # 1) Method A: Native New-SmbMapping with in-memory PSCredential
        if (Get-Command New-SmbMapping -ErrorAction SilentlyContinue) {
            try {
                $null = New-SmbMapping `
                    -LocalPath $cleanDrive `
                    -RemotePath $NetworkPath `
                    -Credential $credential `
                    -Persistent $true `
                    -ErrorAction Stop
                if (Test-Path -LiteralPath "$cleanDrive\" -PathType Container) {
                    $mapped = $true
                }
                else {
                    # Partial map (common under SYSTEM) — remove before New-PSDrive or "resource type" errors.
                    try { Remove-SmbMapping -LocalPath $cleanDrive -Force -UpdateProfile -ErrorAction SilentlyContinue } catch {}
                    $lastError = 'New-SmbMapping created mapping but path is not accessible.'
                }
            }
            catch {
                $lastError = "New-SmbMapping exception: $_"
                try { Remove-SmbMapping -LocalPath $cleanDrive -Force -UpdateProfile -ErrorAction SilentlyContinue } catch {}
            }
        }

        # 2) Method B: Native New-PSDrive with -Persist and in-memory PSCredential
        if (-not $mapped) {
            try {
                if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
                    try { Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue } catch {}
                }
                $null = New-PSDrive `
                    -Name $driveName `
                    -PSProvider FileSystem `
                    -Root $NetworkPath `
                    -Credential $credential `
                    -Persist `
                    -Scope Global `
                    -ErrorAction Stop
                if (Test-Path -LiteralPath "$cleanDrive\" -PathType Container) {
                    $mapped = $true
                }
            }
            catch {
                $lastError = "New-PSDrive exception: $_"
            }
        }

        if (-not (Test-Path -LiteralPath "$cleanDrive\" -PathType Container)) {
            throw "Mapped $cleanDrive but path is not accessible. Last error: $lastError"
        }

        return [pscustomobject]@{
            Success      = $true
            DriveLetter  = $cleanDrive
            NetworkPath  = $NetworkPath
            CredentialId = $CredentialId
            UserName     = $userName
            Source       = $secretResult.Source
        }
    }
    finally {
        $credential = $null
        $secretResult = $null
    }
}

# ==============================================================================
# 5. STATE CONTEXT HELPER
# ==============================================================================

function Get-LiteDeployFullOSContextFromState {
    <#
    .SYNOPSIS
        Builds FullOS resume inputs from DeploymentState.json (source of truth after WinPE).
    #>
    param(
        [Parameter(Mandatory = $true)][psobject]$DeploymentState,
        [string]$DefaultLocalRootName = '~LiteDeploy',
        [string]$DefaultDriveLetter = 'Z:',
        [string]$DefaultCredentialId = 'DeploymentShare'
    )

    $boot = Get-LiteDeployStateProperty -InputObject $DeploymentState -Name 'BootObject' -Default $null
    $execution = Get-LiteDeployStateProperty -InputObject $DeploymentState -Name 'Execution' -Default $null
    $logLocations = Get-LiteDeployStateProperty -InputObject $DeploymentState -Name 'LogLocations' -Default $null
    $share = Get-LiteDeployStateProperty -InputObject $execution -Name 'FullOSShare' -Default $null
    $credHandoff = Get-LiteDeployStateProperty -InputObject $execution -Name 'CredentialHandoff' -Default $null
    $payload = Get-LiteDeployStateProperty -InputObject $execution -Name 'FullOSPayload' -Default $null

    $offlineRoot = [string](Get-LiteDeployStateProperty -InputObject $logLocations -Name 'OfflineOsRoot' -Default '')
    $localRootName = $DefaultLocalRootName
    if (-not [string]::IsNullOrWhiteSpace($offlineRoot)) {
        $leaf = Split-Path -Leaf $offlineRoot.TrimEnd('\')
        if (-not [string]::IsNullOrWhiteSpace($leaf)) { $localRootName = $leaf }
    }
    elseif ($boot) {
        $fromBoot = [string](Get-LiteDeployStateProperty -InputObject $boot -Name 'LocalRootName' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($fromBoot)) { $localRootName = $fromBoot }
    }

    $deploymentType = [string](Get-LiteDeployStateProperty -InputObject $share -Name 'DeploymentType' -Default '')
    if ([string]::IsNullOrWhiteSpace($deploymentType)) {
        $deploymentType = [string](Get-LiteDeployStateProperty -InputObject $boot -Name 'DeploymentType' -Default 'Media')
    }

    $networkPath = [string](Get-LiteDeployStateProperty -InputObject $share -Name 'NetworkPath' -Default '')
    if ([string]::IsNullOrWhiteSpace($networkPath)) {
        $networkPath = [string](Get-LiteDeployStateProperty -InputObject $boot -Name 'NetworkPath' -Default '')
    }

    if ($deploymentType -ne 'Network' -and -not [string]::IsNullOrWhiteSpace($networkPath)) {
        $deploymentType = 'Network'
    }

    $shareDrive = [string](Get-LiteDeployStateProperty -InputObject $share -Name 'DriveLetter' -Default $DefaultDriveLetter)
    if ([string]::IsNullOrWhiteSpace($shareDrive)) { $shareDrive = $DefaultDriveLetter }

    $credentialId = [string](Get-LiteDeployStateProperty -InputObject $share -Name 'CredentialId' -Default $DefaultCredentialId)
    if ([string]::IsNullOrWhiteSpace($credentialId)) { $credentialId = $DefaultCredentialId }

    $remoteLogDir = [string](Get-LiteDeployStateProperty -InputObject $execution -Name 'RemoteLogDir' -Default '')
    if ([string]::IsNullOrWhiteSpace($remoteLogDir)) {
        $remoteLogDir = [string](Get-LiteDeployStateProperty -InputObject $logLocations -Name 'RemoteLogDir' -Default '')
    }

    $uid = [string](Get-LiteDeployStateProperty -InputObject $DeploymentState -Name 'DeploymentUid' -Default '')
    $credStaged = [bool](Get-LiteDeployStateProperty -InputObject $credHandoff -Name 'Staged' -Default $false)
    $secretIds = @(Get-LiteDeployStateProperty -InputObject $credHandoff -Name 'SecretIds' -Default @())
    $reconnect = $true
    if ($null -ne $share -and $share.PSObject.Properties['ReconnectOnBoot']) {
        $reconnect = [bool]$share.ReconnectOnBoot
    }
    else {
        $reconnect = ($deploymentType -eq 'Network')
    }

    return [pscustomobject]@{
        DeploymentUid     = $uid
        Status            = [string](Get-LiteDeployStateProperty -InputObject $DeploymentState -Name 'Status' -Default '')
        CurrentStep       = [string](Get-LiteDeployStateProperty -InputObject $execution -Name 'CurrentStep' -Default '')
        DeploymentType    = $deploymentType
        NetworkPath       = $networkPath
        ShareDriveLetter  = $shareDrive
        CredentialId      = $credentialId
        ReconnectOnBoot   = $reconnect
        LocalRootName     = $localRootName
        OfflineOsRoot     = $offlineRoot
        RemoteLogDir      = $remoteLogDir
        CredentialStaged  = $credStaged
        SecretIds         = @($secretIds)
        CredentialHandoff = $credHandoff
        FullOSPayload     = $payload
        FullOSShare       = $share
        BootObject        = $boot
        Workflow          = (Get-LiteDeployStateProperty -InputObject $DeploymentState -Name 'Workflow' -Default $null)
        OSInstall         = (Get-LiteDeployStateProperty -InputObject $DeploymentState -Name 'OSInstall' -Default $null)
        Disk              = (Get-LiteDeployStateProperty -InputObject $DeploymentState -Name 'Disk' -Default $null)
    }
}

# ==============================================================================
# 6. FULLOS RESUME ORCHESTRATOR
# ==============================================================================

function Start-LiteDeployFullOSResume {
    <#
    .SYNOPSIS
        FullOS Engine pipeline driven by DeploymentState.json.
    #>
    param(
        [string]$LocalRootName = '~LiteDeploy',
        [string]$OsDriveLetter = $env:SystemDrive,
        [string]$StatePath = '',
        [string]$RuntimeRoot = $PSScriptRoot,
        [switch]$ForceDirect
    )

    $drive = ($OsDriveLetter -replace '[\\/]+$', '').Trim()
    if ($drive.Length -eq 1) { $drive += ':' }
    $localRoot = Join-Path "$drive\" $LocalRootName
    $null = New-Item -Path (Join-Path $localRoot 'WorkLogs') -ItemType Directory -Force -ErrorAction SilentlyContinue

    foreach ($name in @('Session', 'Hardware', 'Packages', 'HostShell')) {
        Import-LiteDeployFullOSComponent -Name $name -RuntimeRoot $RuntimeRoot
    }

    if ([string]::IsNullOrWhiteSpace($StatePath)) {
        $StatePath = Join-Path $localRoot 'DeploymentState.json'
    }

    function Write-FullOSLog {
        param(
            [string]$Message,
            [string]$Level = 'INFO',
            [switch]$NoConsole,
            [switch]$NoPrefix,
            [string]$Component = 'OS.Engine'
        )
        if (Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue) {
            Write-LiteDeployLog -Message $Message -Level $Level -Component $Component -NoConsole:$NoConsole -NoPrefix:$NoPrefix
        }
        else {
            if (-not $NoConsole) {
                Write-Host ('[{0}] [{1}] {2}' -f (Get-Date -Format 'o'), $Level, $Message)
            }
        }
    }

    $meta = if ($script:OSMetadata) { $script:OSMetadata } else { Get-LiteDeployOSMetadata }
    if ($null -eq $meta) {
        $meta = Get-LiteDeployComponentMetadata
    }

    Write-FullOSLog "$($meta.Name) v$($meta.Version)" -Level 'INIT'

    Write-FullOSLog "FullOS initialization starting." -Level 'INFO'
    Write-FullOSLog "StatePath=$StatePath RuntimeRoot=$RuntimeRoot" -Level 'INFO' -NoConsole

    # Universal High Performance power plan: applies to all deployment workflows in FullOS
    try {
        $powerResult = Set-LiteDeployFullOSHighPerformance
        Write-FullOSLog ("Power configuration: SchemeSet={0}, TimeoutsConfigured={1}" -f $powerResult.SchemeSet, $powerResult.TimeoutsConfigured) -Level 'INFO'
    }
    catch {
        Write-FullOSLog "Power configuration warning: $_" -Level 'WARNING'
    }

    # Leave stock Setup\CmdLine (sysprep) alone. Only clear a legacy LiteDeploy FullOS hijack.
    try {
        $clearedSetup = Clear-LiteDeployFullOSSetupCmdLine
        Write-FullOSLog ("Setup CmdLine check: {0}" -f $(if ($clearedSetup.Message) { $clearedSetup.Message } else { "Cleared=$($clearedSetup.Cleared)" })) -Level 'INFO'
    }
    catch {
        Write-FullOSLog "Setup CmdLine check failed: $_" -Level 'WARNING'
    }

    # Kill Audit Mode sysprep GUI so FullOS/probe own the desktop (do not rewrite Setup registry)
    $killedSysprep = Stop-LiteDeployAuditModeSysprep
    Write-FullOSLog ("Sysprep process kill sweep: {0} instance(s)." -f $killedSysprep) -Level 'INFO'

    # Remove obsolete LiteDeploy scheduled tasks from older builds (resume is HKLM Run only)
    try {
        $legacyTasks = Clear-LiteDeployFullOSLegacyScheduledTasks
        if ($legacyTasks.Count -gt 0) {
            Write-FullOSLog ("Removed legacy scheduled task(s): {0}" -f ($legacyTasks.Removed -join ', ')) -Level 'INFO'
        }
    }
    catch {
        Write-FullOSLog "Legacy scheduled-task cleanup failed: $_" -Level 'WARNING'
    }

    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $isSystem = $currentIdentity.IsSystem -or ($currentIdentity.User.Value -eq 'S-1-5-18')

    # Arm HKLM Run for interactive Administrator Autologon after reboots
    $runKey = $null
    try {
        $runKey = Set-LiteDeployFullOSRunKey -LocalRootName $LocalRootName -OsDriveLetter $drive
        Write-FullOSLog ("HKLM Run armed ({0}): {1}" -f $runKey.ValueName, $runKey.Command) -Level 'SUCCESS'
    }
    catch {
        Write-FullOSLog "Failed to arm HKLM Run resume key: $_" -Level 'WARNING'
    }

    if ($isSystem) {
        # Legacy LiteDeploy Setup CmdLine entry as SYSTEM — defer to Administrator via Run.
        Write-FullOSLog 'Invoked as NT AUTHORITY\SYSTEM. HKLM Run armed; exiting so Administrator Autologon owns FullOS. Stock sysprep Setup left intact.' -Level 'NOTICE'
        return [pscustomobject]@{
            Success   = $true
            Deferred  = $true
            Identity  = 'SYSTEM'
            RunKey    = $runKey
            Message   = 'FullOS deferred to HKLM Run at Administrator logon; Setup sysprep CmdLine preserved.'
        }
    }

    Write-FullOSLog "Executing FullOS engine in interactive user session ($($currentIdentity.Name))." -Level 'SUCCESS'

    # Environment shielding: when running under non-Administrator (e.g. ephemeral LD-* account) or UAC bypass
    $isBuiltinAdmin = ($currentIdentity.Name -match '(?i)\\Administrator$|^Administrator$')
    $uacMarkerPresent = $false
    try {
        $m = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\LiteDeploy\FullOS' -Name 'UacBypassed' -ErrorAction SilentlyContinue
        if ($m -and [int]$m.UacBypassed -eq 1) { $uacMarkerPresent = $true }
    } catch {}

    if (-not $isBuiltinAdmin -or $uacMarkerPresent) {
        try {
            $shieldResult = Enable-LiteDeployFullOSShielding -UserName $currentIdentity.Name
            Write-FullOSLog ("FullOS Environment Shielding enabled ({0}): {1}" -f $currentIdentity.Name, $shieldResult.Message) -Level 'SUCCESS'
        }
        catch {
            Write-FullOSLog "Environment Shielding activation warning: $_" -Level 'WARNING'
        }
    }

    # 1) Load state first — everything else is derived from it.
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        throw "DeploymentState.json not found at '$StatePath'. FullOS cannot resume without WinPE handoff state."
    }

    $deployment = Read-LiteDeployStateFile -Path $StatePath
    if ($null -eq $deployment) {
        throw "DeploymentState.json at '$StatePath' is empty or unreadable."
    }

    $ctx = Get-LiteDeployFullOSContextFromState -DeploymentState $deployment -DefaultLocalRootName $LocalRootName
    if (-not [string]::IsNullOrWhiteSpace($ctx.LocalRootName) -and $ctx.LocalRootName -ne $LocalRootName) {
        $LocalRootName = $ctx.LocalRootName
        $localRoot = Join-Path "$drive\" $LocalRootName
        Write-FullOSLog "LocalRootName from state OfflineOsRoot: $LocalRootName"
    }

    $previousStatus = [string]$ctx.Status
    $resumeCount = 0
    $execution = Get-LiteDeployStateProperty -InputObject $deployment -Name 'Execution' -Default $null
    [void][int]::TryParse([string](Get-LiteDeployStateProperty -InputObject $execution -Name 'ResumeCount' -Default 0), [ref]$resumeCount)
    $resumeCount++

    $deployment | Add-Member -NotePropertyName Status -NotePropertyValue 'FullOS' -Force
    $deployment | Add-Member -NotePropertyName CurrentPhase -NotePropertyValue 5 -Force
    $deployment | Add-Member -NotePropertyName EndTime -NotePropertyValue $null -Force
    if ($execution) {
        $execution | Add-Member -NotePropertyName ResumeCount -NotePropertyValue $resumeCount -Force
        $execution | Add-Member -NotePropertyName LastResumedTime -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        $execution | Add-Member -NotePropertyName ResumedFromStatus -NotePropertyValue $previousStatus -Force
        $execution | Add-Member -NotePropertyName CurrentStep -NotePropertyValue 'FullOSResumed' -Force
    }
    $global:LiteDeployDeployment = $deployment
    Save-LiteDeployDeploymentState -DeploymentState $deployment
    $entryType = if ($resumeCount -le 1 -or $previousStatus -eq 'Completed') { 'InitialEntry' } else { 'ReEntry' }
    $reason = 'Unknown'
    Write-FullOSLog ("State active: Entry={0} (resume #{1}, Reason={2}) UID={3} previousStatus={4} type={5}" -f `
            $entryType, $resumeCount, $reason, $ctx.DeploymentUid, $previousStatus, $ctx.DeploymentType) -Level 'SUCCESS'

    # 2) WinPECT in-memory readiness (zero disk footprint)
    $credDir = Join-Path $localRoot 'Content\Credentials'
    $packagePath = Join-Path $credDir 'CredentialTransfer.bin'
    $hasWinpectPackage = (Test-Path -LiteralPath $packagePath -PathType Leaf)
    $clixml = @(Get-ChildItem -LiteralPath $credDir -Filter '*.xml' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    if ($hasWinpectPackage) {
        Write-FullOSLog "WinPECT package ready for in-memory decryption (zero disk footprint)." -Level 'SUCCESS'
    }
    elseif ($clixml.Count -gt 0) {
        Write-FullOSLog ("Credential files available: {0}" -f ($clixml -join ', ')) -Level 'INFO'
    }
    else {
        Write-FullOSLog 'No WinPECT package or credential files found; continuing with local resources.' -Level 'INFO'
    }

    # 3) Network (from state): reconnect share every boot, then mirror logs to state's UID folder.
    $shareMap = $null
    $runtimePaths = $null
    $remoteLogDir = $null
    $logsMirrored = $false
    $deploymentType = [string]$ctx.DeploymentType
    $networkPath = [string]$ctx.NetworkPath
    $shareDrive = [string]$ctx.ShareDriveLetter
    $credentialId = [string]$ctx.CredentialId

    if ($deploymentType -ne 'Network' -or -not $ctx.ReconnectOnBoot) {
        Write-FullOSLog ("DeploymentType={0} ReconnectOnBoot={1}; skipping DeploymentShare reconnect / share log mirror." -f $deploymentType, $ctx.ReconnectOnBoot) -Level 'INFO'
    }
    elseif ([string]::IsNullOrWhiteSpace($networkPath)) {
        Write-FullOSLog 'State NetworkPath is empty; cannot reconnect share or mirror logs.' -Level 'WARNING'
    }
    elseif (-not $hasWinpectPackage -and ($clixml -notcontains "$credentialId.xml")) {
        Write-FullOSLog ("Cannot reconnect {0}: missing WinPECT package or Content\Credentials\{1}.xml (state CredentialId)." -f $shareDrive, $credentialId) -Level 'WARNING'
    }
    else {
        Write-FullOSLog "Reconnecting DeploymentShare from state: $networkPath -> $shareDrive ..."
        try {
            $shareMap = Connect-LiteDeployFullOSDeploymentShare `
                -LocalRoot $localRoot `
                -NetworkPath $networkPath `
                -DriveLetter $shareDrive `
                -CredentialId $credentialId
            Write-FullOSLog ("DeploymentShare connected: {0} = {1} (user {2})" -f $shareMap.DriveLetter, $shareMap.NetworkPath, $shareMap.UserName) -Level 'SUCCESS'
            $global:LiteDeployShareDrive = $shareMap.DriveLetter
            $global:LiteDeployNetworkPath = $shareMap.NetworkPath
        }
        catch {
            Write-FullOSLog ("DeploymentShare connection FAILED: {0}" -f $_.Exception.Message) -Level 'ERROR'
            throw $_
        }

        $fullOsBoot = [pscustomobject]@{
            DeploymentType = 'Network'
            DriveLetter    = $shareMap.DriveLetter
            NetworkPath    = $shareMap.NetworkPath
            LocalRootName  = $LocalRootName
            ConfigPath     = (Join-Path $shareMap.DriveLetter 'Config\BootConfig.json')
            ConfigFound    = (Test-Path -LiteralPath (Join-Path $shareMap.DriveLetter 'Config\BootConfig.json') -PathType Leaf)
            ShareMounted   = $true
            AppName        = $(if ($ctx.BootObject) { Get-LiteDeployStateProperty -InputObject $ctx.BootObject -Name 'AppName' -Default 'LiteDeploy' } else { 'LiteDeploy' })
            Environment    = $(if ($ctx.BootObject) { Get-LiteDeployStateProperty -InputObject $ctx.BootObject -Name 'Environment' -Default '' } else { '' })
            Credential     = $null
        }
        $global:LiteDeployBootObject = $fullOsBoot
        if ($deployment.PSObject.Properties['BootObject']) {
            # Keep persisted BootObject fields; overlay live share mount (never store Credential).
            $deployment.BootObject | Add-Member -NotePropertyName DriveLetter -NotePropertyValue $shareMap.DriveLetter -Force
            $deployment.BootObject | Add-Member -NotePropertyName ShareMounted -NotePropertyValue $true -Force
            $deployment.BootObject | Add-Member -NotePropertyName NetworkPath -NotePropertyValue $shareMap.NetworkPath -Force
            $deployment.BootObject | Add-Member -NotePropertyName DeploymentType -NotePropertyValue 'Network' -Force
        }

        $runtimePaths = Get-LiteDeployRuntimePaths `
            -BootObject $fullOsBoot `
            -RequiredComponents @('Environment', 'BootConfig', 'Session', 'Hardware', 'Packages', 'HostShell')
        $global:LiteDeployRuntimeRoot = $runtimePaths.RuntimeRoot
        Write-FullOSLog ("RuntimePaths ready. DeploymentRoot={0} RuntimeRoot={1} LocalLogs={2}" -f `
                $runtimePaths.DeploymentRoot, $runtimePaths.RuntimeRoot, $runtimePaths.LocalLogDirectory)

        # Remote log dir: prefer state UID under reconnected DeploymentLogRoot (drive-letter safe).
        if (-not [string]::IsNullOrWhiteSpace($ctx.DeploymentUid)) {
            $remoteLogDir = Join-Path $runtimePaths.DeploymentLogRoot $ctx.DeploymentUid
        }
        elseif (-not [string]::IsNullOrWhiteSpace($ctx.RemoteLogDir)) {
            $leaf = Split-Path -Leaf $ctx.RemoteLogDir.TrimEnd('\')
            $remoteLogDir = if ($leaf -and $leaf -ne 'Deployments') {
                Join-Path $runtimePaths.DeploymentLogRoot $leaf
            } else {
                $ctx.RemoteLogDir
            }
        }
        else {
            $remoteLogDir = $runtimePaths.DeploymentLogRoot
        }

        try {
            $null = New-Item -Path $remoteLogDir -ItemType Directory -Force -ErrorAction Stop
            $global:LiteDeployRemoteLogDir = $remoteLogDir
            if ($execution) {
                $execution | Add-Member -NotePropertyName RemoteLogDir -NotePropertyValue $remoteLogDir -Force
                $execution | Add-Member -NotePropertyName CurrentStep -NotePropertyValue 'FullOSShareConnected' -Force
            }
            $logLocations = Get-LiteDeployStateProperty -InputObject $deployment -Name 'LogLocations' -Default $null
            if ($logLocations) {
                $logLocations | Add-Member -NotePropertyName RemoteLogDir -NotePropertyValue $remoteLogDir -Force
                $logLocations | Add-Member -NotePropertyName RemoteExecutionLog -NotePropertyValue (Join-Path $remoteLogDir 'LiteDeploy.Execution.log') -Force
                $logLocations | Add-Member -NotePropertyName RemoteDeploymentState -NotePropertyValue (Join-Path $remoteLogDir 'DeploymentState.json') -Force
            }
            $global:LiteDeployDeployment = $deployment
            Save-LiteDeployDeploymentState -DeploymentState $deployment

            # Best-effort collection of first-boot Panther logs before sync
            $fullOsPantherDir = Collect-LiteDeployFullOSPantherLogs -LocalLogDir $runtimePaths.LocalLogDirectory -DeploymentState $deployment

            Sync-LiteDeployLogsToShare -RuntimePaths $runtimePaths -RemoteLogDir $remoteLogDir
            $logsMirrored = $true
            Write-FullOSLog "Share log mirror enabled from state: $($runtimePaths.LocalLogDirectory) -> $remoteLogDir" -Level 'SUCCESS'

            if ($fullOsPantherDir -and (Test-Path -LiteralPath $fullOsPantherDir -PathType Container)) {
                $engineRel = Split-Path -Leaf (Split-Path -Parent $fullOsPantherDir)
                $relSubPath = Join-Path $engineRel "FullOS-Panther"
                if (Get-Command Write-LiteDeployDiagnosticLogLocation -ErrorAction SilentlyContinue) {
                    $null = Write-LiteDeployDiagnosticLogLocation `
                        -LocalPath $fullOsPantherDir `
                        -RemoteLogDir $remoteLogDir `
                        -RelativePath $relSubPath `
                        -Component "OS.Engine"
                }
            }
        }
        catch {
            Write-FullOSLog "Share connected but log mirror failed: $_. Local logs remain at $($runtimePaths.LocalLogDirectory)." -Level 'WARNING'
            $global:LiteDeployRemoteLogDir = $null
        }
    }

    if (-not $logsMirrored) {
        $localLogDir = if ($runtimePaths) { $runtimePaths.LocalLogDirectory } else { Join-Path $localRoot 'WorkLogs' }
        $fullOsPantherDir = Collect-LiteDeployFullOSPantherLogs -LocalLogDir $localLogDir -DeploymentState $deployment
        if ($fullOsPantherDir -and (Test-Path -LiteralPath $fullOsPantherDir -PathType Container)) {
            $engineRel = Split-Path -Leaf (Split-Path -Parent $fullOsPantherDir)
            $relSubPath = Join-Path $engineRel "FullOS-Panther"
            if (Get-Command Write-LiteDeployDiagnosticLogLocation -ErrorAction SilentlyContinue) {
                $null = Write-LiteDeployDiagnosticLogLocation `
                    -LocalPath $fullOsPantherDir `
                    -RemoteLogDir "" `
                    -RelativePath $relSubPath `
                    -Component "OS.Engine"
            }
        }
    }

    if (Get-Command Get-LiteDeployPackages -ErrorAction SilentlyContinue) {
        Write-FullOSLog 'Packages component loaded (orchestration pending; use state Workflow / future action list).'
    }

    if ($execution -and $runKey) {
        $execution | Add-Member -NotePropertyName FullOSRunKey -NotePropertyValue ([pscustomobject]@{
                ValueName         = $runKey.ValueName
                Command           = $runKey.Command
                RegisteredTimeUtc = [DateTime]::UtcNow.ToString('o')
            }) -Force
        $execution | Add-Member -NotePropertyName CurrentStep -NotePropertyValue 'FullOSRunKeyArmed' -Force
        $global:LiteDeployDeployment = $deployment
        Save-LiteDeployDeploymentState -DeploymentState $deployment
    }

    # Final sweep against Audit Mode sysprep GUI
    $null = Stop-LiteDeployAuditModeSysprep

    Write-FullOSLog 'FullOS initialization completed. Package orchestration is pending.' -Level 'SUCCESS'
    Write-FullOSLog 'HKLM Run remains armed for mid-deploy reboots; package runner will clear on final success.' -Level 'INFO' -NoConsole
    return [pscustomobject]@{
        Success          = $true
        Context          = $ctx
        LocalRoot        = $localRoot
        StatePath        = $StatePath
        CredentialFiles  = $clixml
        CredentialDir    = $credDir
        DeploymentType   = $deploymentType
        ShareMapped      = [bool]$shareMap
        ShareDrive       = $(if ($shareMap) { $shareMap.DriveLetter } else { $null })
        NetworkPath      = $networkPath
        RemoteLogDir     = $remoteLogDir
        LogsMirrored     = $logsMirrored
        RunKey           = $runKey
        RuntimePaths     = $runtimePaths
        DeploymentUid    = $ctx.DeploymentUid
        ResumeCount      = $resumeCount
        WinpectReady     = $hasWinpectPackage
        DeploymentState  = $deployment
    }
}

# ==============================================================================
# 7. OS PROBE GUARD & ENTRY ORCHESTRATION
# ==============================================================================

function Test-LiteDeployShouldLaunchOSProbe {
    <#
    .SYNOPSIS
        Evaluates whether the interactive OS Probe monitor should launch after FullOS resume.
    .DESCRIPTION
        Returns $true only when:
          1) Resume succeeded ($ResumeResult.Success is $true).
          2) Resume was NOT deferred ($ResumeResult.Deferred is not $true).
          3) Host session is interactive ([Environment]::UserInteractive is $true).
          4) Process is NOT running as NT AUTHORITY\SYSTEM (SID S-1-5-18).
        Safely evaluates optional properties under Set-StrictMode -Version 2.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $ResumeResult,

        [Parameter(Mandatory = $false)]
        $Identity = $null,

        [Parameter(Mandatory = $false)]
        $UserInteractive = $null
    )

    if ($null -eq $ResumeResult) { return $false }

    # StrictMode-safe check for Success
    $isSuccess = $false
    if ($ResumeResult -is [System.Management.Automation.PSObject] -or $ResumeResult -is [hashtable]) {
        if ($ResumeResult.PSObject.Properties['Success'] -and $ResumeResult.Success) {
            $isSuccess = $true
        }
    }
    if (-not $isSuccess) { return $false }

    # StrictMode-safe check for Deferred
    if ($ResumeResult.PSObject.Properties['Deferred'] -and $ResumeResult.Deferred) {
        return $false
    }

    # UserInteractive check
    $interactive = if ($null -ne $UserInteractive) { [bool]$UserInteractive } else { [Environment]::UserInteractive }
    if (-not $interactive) { return $false }

    # Real Windows identity check
    try {
        $current = if ($null -ne $Identity) { $Identity } else { [System.Security.Principal.WindowsIdentity]::GetCurrent() }
        if ($null -ne $current) {
            $isSys = $false
            if ($current.PSObject.Properties['IsSystem'] -and $current.IsSystem) {
                $isSys = $true
            }
            elseif ($current.PSObject.Properties['User'] -and $current.User -and $current.User.Value -eq 'S-1-5-18') {
                $isSys = $true
            }
            elseif ($current.PSObject.Properties['Sid'] -and $current.Sid -eq 'S-1-5-18') {
                $isSys = $true
            }
            elseif ($current.PSObject.Properties['Name'] -and $current.Name -match '(?i)SYSTEM') {
                $isSys = $true
            }
            if ($isSys) { return $false }
        }
    }
    catch {
        return $false
    }

    return $true
}

function Invoke-LiteDeployFullOSResumeEntryPoint {
    <#
    .SYNOPSIS
        Orchestrates FullOS resume entry sequence: terminal delegation, resume execution,
        mandatory cleanup (finally), and conditional probe launch.
    #>
    [CmdletBinding()]
    param(
        [string]$LocalRootName = '~LiteDeploy',
        [string]$OsDriveLetter = $env:SystemDrive,
        [string]$StatePath = '',
        [string]$RuntimeRoot = $PSScriptRoot,
        [switch]$ForceDirect,
        [switch]$SkipTerminalDelegation
    )

    if (-not $SkipTerminalDelegation) {
        # Hand the console host to Windows Terminal for this user before resume work starts.
        try {
            $Path = 'HKCU:\Console\%%Startup'
            $GUID = '{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}'
            New-Item -Path $Path -Force | Out-Null
            Set-ItemProperty -Path $Path -Name DelegationConsole -Value $GUID
            Set-ItemProperty -Path $Path -Name DelegationTerminal -Value $GUID
        }
        catch {}
    }

    $resumeResult = $null
    try {
        $resumeResult = Start-LiteDeployFullOSResume -LocalRootName $LocalRootName -OsDriveLetter $OsDriveLetter -StatePath $StatePath -RuntimeRoot $RuntimeRoot -ForceDirect:$ForceDirect
    }
    finally {
        # Only strip a LiteDeploy-owned Setup CmdLine hijack — never wipe stock sysprep.
        try { $null = Clear-LiteDeployFullOSSetupCmdLine } catch {}
        # Keep sysprep GUI from reclaiming the desktop if it respawned during the run.
        try { $null = Stop-LiteDeployAuditModeSysprep } catch {}
    }

    if (Test-LiteDeployShouldLaunchOSProbe -ResumeResult $resumeResult) {
        $localRootArg = if ($resumeResult.PSObject.Properties['LocalRoot']) { $resumeResult.LocalRoot } else { '' }
        $statePathArg = if ($resumeResult.PSObject.Properties['StatePath']) { $resumeResult.StatePath } else { '' }
        Show-LiteDeployOSProbe -ResumeResult $resumeResult -LocalRoot $localRootArg -StatePath $statePathArg
    }

    return $resumeResult
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-LiteDeployFullOSResumeEntryPoint -LocalRootName $LocalRootName -OsDriveLetter $OsDriveLetter -StatePath $StatePath -RuntimeRoot $PSScriptRoot -ForceDirect:$ForceDirect
}
