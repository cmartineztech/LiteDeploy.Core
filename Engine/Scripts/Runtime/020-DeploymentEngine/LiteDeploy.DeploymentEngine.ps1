<#
.SYNOPSIS
    LiteDeploy Orchestration & Deployment Engine for WinPE.

.DESCRIPTION
    Main pipeline orchestrator for LiteDeploy. Coordinates and sequences pre-flight system
    assessment (HardwarePreCheck), technician configuration (WorkflowSelection), and deployment execution,
    passing state safely across phases while keeping in-memory credentials secure.

.PARAMETER BootObject
    The in-memory bootstrap PSCustomObject provided by BootInitializer containing
    network configuration, share mount status, drive letters, and secure credentials.

.PARAMETER SkipPreCheck
    Switch to bypass the HardwarePreCheck hardware/network readiness assessment and launch
    directly into Workflow Selection (useful for testing and rapid re-deployments).

.PARAMETER Metadata
    Outputs the standardized component metadata PSCustomObject and exits immediately.

.EXAMPLE
    .\LiteDeploy.DeploymentEngine.ps1 -BootObject $global:LiteDeployBootObject

.NOTES
    LiteDeploy Core Component Standard v1.0
    Target Environment: WinPE
    PowerShell Version: 5.1+
    Strict Mode: Version 2.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [psobject]$BootObject = $null,

    [Parameter(Mandatory = $false)]
    [switch]$SkipPreCheck,

    [Parameter(Mandatory = $false)]
    [switch]$Metadata
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
        ComponentId          = "DeploymentEngine"
        Name                 = "LiteDeploy Deployment Engine"
        Version              = "1.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "WinPE"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("LogWriter", "HardwarePreCheck", "WorkflowSelection", "DiskPreparation", "OSInstallation", "Progress")
        Description          = "Runtime pipeline orchestrator: sequences HardwarePreCheck, WorkflowSelection, and deployment execution."
    }
}

# Fast-exit for automated inventory scanners or version queries
if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

# ==============================================================================
# 2. RUNTIME ENVIRONMENT GUARDS & LOGGING
# ==============================================================================

# Ensure Single-Threaded Apartment (STA) mode for WPF child components
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    if ($BootObject) {
        throw "LiteDeploy.DeploymentEngine.ps1 must be invoked from the BootInitializer STA process when BootObject is supplied. Relaunching would discard in-memory credentials."
    }
    $powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path $powershellExe)) { $powershellExe = "powershell.exe" }
    & $powershellExe -STA -ExecutionPolicy Bypass -File "$PSCommandPath" @args
    return
}

# Re-link or persist BootObject globally in the STA session
if ($BootObject) {
    $global:LiteDeployBootObject = $BootObject
}
elseif (Test-Path Variable:global:LiteDeployBootObject) {
    $BootObject = $global:LiteDeployBootObject
}

# ==============================================================================
# 2. COMPONENT RESOLUTION & LOGWRITER IMPORT
# ==============================================================================

function Resolve-RuntimeComponent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComponentName,
        [Parameter(Mandatory = $true)]
        [string]$ScriptFileName
    )

    $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "X:" }
    $candidates = [System.Collections.Generic.List[string]]::new()

    # 1. Local relative / script directory
    $candidates.Add((Join-Path $PSScriptRoot $ScriptFileName))
    $candidates.Add((Join-Path $PSScriptRoot "Runtime\$ScriptFileName"))
    $candidates.Add((Join-Path $PSScriptRoot "..\Runtime\$ScriptFileName"))
    $candidates.Add((Join-Path $PSScriptRoot "..\$ComponentName\$ScriptFileName"))
    $candidates.Add((Join-Path $PSScriptRoot "..\\$ScriptFileName"))

    # 2. WinPE RAM root (~LiteDeploy\Engine\Scripts\...)
    $candidates.Add((Join-Path $sysDrive "~LiteDeploy\Engine\Scripts\Runtime\$ScriptFileName"))
    $candidates.Add((Join-Path $sysDrive "~LiteDeploy\Engine\Scripts\$ScriptFileName"))
    $candidates.Add((Join-Path $sysDrive "Engine\Scripts\Runtime\$ScriptFileName"))
    $candidates.Add((Join-Path $sysDrive "Engine\Scripts\$ScriptFileName"))

    # 3. Active deployment share or offline media drive
    if ($BootObject -and $BootObject.PSObject.Properties['DriveLetter'] -and $BootObject.DriveLetter) {
        $dl = $BootObject.DriveLetter.TrimEnd('\')
        $candidates.Add("$dl\Engine\Scripts\Runtime\$ScriptFileName")
        $candidates.Add("$dl\Engine\Scripts\$ScriptFileName")
        $candidates.Add("$dl\~LiteDeploy\Engine\Scripts\Runtime\$ScriptFileName")
        $candidates.Add("$dl\~LiteDeploy\Engine\Scripts\$ScriptFileName")
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }

    return $null
}

# Automatically import LogWriter engine
$logWriterPath = Resolve-RuntimeComponent -ComponentName "000-LogWriter" -ScriptFileName "LiteDeploy.LogWriter.ps1"
if ($logWriterPath) {
    try {
        . $logWriterPath
    }
    catch {}
}

# Automatically import HostShell console geometry and window manager
$hostShellPath = Resolve-RuntimeComponent -ComponentName "000-HostShell" -ScriptFileName "LiteDeploy.HostShell.ps1"
if ($hostShellPath) {
    try {
        . $hostShellPath
    }
    catch {}
}

# Fallback logger if LogWriter is not loaded
if (-not (Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue)) {
    function Write-LiteDeployLog {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Message,
            [ValidateSet("INFO", "SUCCESS", "INIT", "CHECK", "WARNING", "RETRY", "ERROR")]
            [string]$Level = "INFO",
            [ConsoleColor]$ForegroundColor = [ConsoleColor]::White,
            [string]$Component = "DeploymentEngine",
            [switch]$NoConsole
        )
        if ($Message -and -not $NoConsole) {
            Write-Host " [$($Level.PadRight(7))] $Message" -ForegroundColor $ForegroundColor
        }

        try {
            $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "X:" }
            $logDir = Join-Path $sysDrive "~LiteDeploy\WorkLogs"
            if (-not (Test-Path -LiteralPath $logDir)) {
                $null = New-Item -Path $logDir -ItemType Directory -Force -ErrorAction SilentlyContinue
            }
            $logFile = Join-Path $logDir "LiteDeploy.Execution.log"
            $cleanMsg = $Message.Trim()
            if (-not [string]::IsNullOrWhiteSpace($cleanMsg)) {
                $now = Get-Date
                $timeStr = $now.ToString("HH:mm:ss.fff") + "+000"
                $dateStr = $now.ToString("MM-dd-yyyy")
                $typeCode = switch ($Level.ToUpper()) {
                    "ERROR" { "3" }
                    "WARNING" { "2" }
                    "RETRY" { "2" }
                    default { "1" }
                }
                $logEntry = "<![LOG[$cleanMsg]LOG]!><time=""$timeStr"" date=""$dateStr"" component=""$Component"" context="""" type=""$typeCode"" thread=""1"" file=""LiteDeploy.DeploymentEngine.ps1"">"
                Add-Content -Path $logFile -Value $logEntry -ErrorAction SilentlyContinue

                # Dual-write to remote share log directory if active
                if (Test-Path "Variable:global:LiteDeployRemoteLogDir") {
                    $rDir = $global:LiteDeployRemoteLogDir
                    if ($rDir -and (Test-Path -LiteralPath $rDir -ErrorAction SilentlyContinue)) {
                        $rFile = Join-Path $rDir "LiteDeploy.Execution.log"
                        Add-Content -Path $rFile -Value $logEntry -ErrorAction SilentlyContinue
                    }
                }
            }
        }
        catch {}
    }
}

# ==============================================================================
# 3. DEPLOYMENT UID & STATE MANAGEMENT
# ==============================================================================

function Get-LiteDeployUid {
    <#
    .SYNOPSIS
        Generates a short, collision-resistant deployment UID (e.g., 260930-A3F1).
    #>
    $bytes = [Byte[]]::new(2)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $hex = [System.BitConverter]::ToString($bytes) -replace '-'

    return "$((Get-Date).ToString('yyMMdd'))-$hex"
}

function Initialize-LiteDeployDeploymentShareLogDir {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DeploymentUid,
        [psobject]$BootCtx
    )

    $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "X:" }
    $localLogDir = Join-Path $sysDrive "~LiteDeploy\WorkLogs"

    $remoteShareDrive = if ($BootCtx -and $BootCtx.PSObject.Properties['DriveLetter'] -and $BootCtx.DriveLetter) {
        $BootCtx.DriveLetter.TrimEnd('\')
    } else {
        "Z:"
    }

    $localRootName = if ($BootCtx -and $BootCtx.PSObject.Properties['LocalRootName'] -and $BootCtx.LocalRootName) {
        $BootCtx.LocalRootName
    } else {
        "~LiteDeploy"
    }

    $cleanShareDrive = $remoteShareDrive.TrimEnd('\')

    try {
        if (Test-Path -LiteralPath "$cleanShareDrive\" -ErrorAction SilentlyContinue) {
            # Discover candidate log directories on the media/share:
            $candidateLogDirs = [System.Collections.Generic.List[string]]::new()

            # Priority 1: Derived from discovered BootConfig.json location on media
            # e.g., D:\~LiteDeploy\Config\BootConfig.json -> D:\~LiteDeploy\WorkLogs\Deployments\<Uid>
            if ($BootCtx -and $BootCtx.PSObject.Properties['ConfigPath'] -and $BootCtx.ConfigPath) {
                try {
                    $configDir = Split-Path -Parent $BootCtx.ConfigPath
                    $parentOfConfig = Split-Path -Parent $configDir
                    if ($parentOfConfig -and $parentOfConfig.TrimEnd('\') -ne $cleanShareDrive) {
                        $candidateLogDirs.Add([System.IO.Path]::Combine($parentOfConfig, "WorkLogs", "Deployments", $DeploymentUid))
                    }
                } catch {}
            }

            # Priority 2: <Drive>:\<LocalRootName>\WorkLogs\Deployments\<Uid> (e.g. D:\~LiteDeploy\WorkLogs\Deployments\<Uid>)
            $candidateLogDirs.Add([System.IO.Path]::Combine("$cleanShareDrive\", $localRootName, "WorkLogs", "Deployments", $DeploymentUid))

            # Priority 3: <Drive>:\WorkLogs\Deployments\<Uid> (e.g. Z:\WorkLogs\Deployments\<Uid>)
            $candidateLogDirs.Add([System.IO.Path]::Combine("$cleanShareDrive\", "WorkLogs", "Deployments", $DeploymentUid))

            foreach ($targetLogDir in $candidateLogDirs) {
                try {
                    # 1. Create target DeploymentId directory on deployment share / media
                    if (-not (Test-Path -LiteralPath $targetLogDir -ErrorAction SilentlyContinue)) {
                        $null = New-Item -Path $targetLogDir -ItemType Directory -Force -ErrorAction Stop
                    }

                    # 2. Copy initial generated logs from local RAM (X:\~LiteDeploy\WorkLogs and X:\LiteDeploy\Logs) to share/media
                    $sourceDirs = @(
                        $localLogDir,
                        (Join-Path $sysDrive "LiteDeploy\Logs"),
                        (Join-Path $env:TEMP "LiteDeploy\Logs")
                    )

                    foreach ($sDir in $sourceDirs) {
                        if (Test-Path -LiteralPath $sDir) {
                            Get-ChildItem -Path $sDir -File -Filter "LiteDeploy.*" -ErrorAction SilentlyContinue | ForEach-Object {
                                $targetFile = Join-Path $targetLogDir $_.Name
                                Copy-Item -LiteralPath $_.FullName -Destination $targetFile -Force -ErrorAction SilentlyContinue
                            }
                        }
                    }

                    Write-LiteDeployLog "Created and synchronized deployment logs to '$targetLogDir'." -Level "SUCCESS" -ForegroundColor Green -Component "DeploymentEngine"
                    return $targetLogDir
                }
                catch {
                    # If candidate failed (e.g. read-only or invalid subfolder), try next candidate
                    continue
                }
            }
        }
    }
    catch {
        Write-LiteDeployLog "Warning: Could not initialize deployment log directory on '$remoteShareDrive': $_" -Level "WARNING" -ForegroundColor Yellow -Component "DeploymentEngine"
    }

    return $null
}

function Sync-LiteDeployLogsToShare {
    param(
        [string]$RemoteLogDir
    )
    if ([string]::IsNullOrWhiteSpace($RemoteLogDir) -or -not (Test-Path -LiteralPath $RemoteLogDir -ErrorAction SilentlyContinue)) {
        return
    }
    try {
        $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "X:" }
        $localLogDir = Join-Path $sysDrive "~LiteDeploy\WorkLogs"
        if (Test-Path -LiteralPath $localLogDir) {
            Get-ChildItem -Path $localLogDir -File -Filter "LiteDeploy.*" -ErrorAction SilentlyContinue | ForEach-Object {
                $targetFile = Join-Path $RemoteLogDir $_.Name
                Copy-Item -LiteralPath $_.FullName -Destination $targetFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {}
}

function New-LiteDeployDeploymentObject {
    param(
        [string]$Uid,
        [psobject]$BootCtx,
        [string]$RemoteLogDir = ""
    )

    $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "X:" }
    $localLogDir = Join-Path $sysDrive "~LiteDeploy\WorkLogs"

    return [PSCustomObject]@{
        DeploymentUid = $Uid
        Status        = "Initializing"    # Initializing, HardwarePreCheck, WorkflowSelection, ReadyForDeployment, Staging, Completed, Cancelled, Failed
        CurrentPhase  = 0
        StartTime     = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        EndTime       = $null
        BootObject    = $BootCtx
        LogLocations  = [PSCustomObject]@{
            LocalLogDir               = $localLogDir
            RemoteLogDir              = $RemoteLogDir
            LocalExecutionLog         = (Join-Path $localLogDir "LiteDeploy.Execution.log")
            RemoteExecutionLog        = if ($RemoteLogDir) { Join-Path $RemoteLogDir "LiteDeploy.Execution.log" } else { "" }
            LocalDeploymentState      = (Join-Path $sysDrive "~LiteDeploy\DeploymentState.json")
            RemoteDeploymentState     = if ($RemoteLogDir) { Join-Path $RemoteLogDir "DeploymentState.json" } else { "" }
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
    }
}

function Save-LiteDeployDeploymentState {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$DeploymentState
    )

    try {
        $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "X:" }
        $stateDir = Join-Path $sysDrive "~LiteDeploy"
        if (-not (Test-Path -LiteralPath $stateDir)) {
            $null = New-Item -Path $stateDir -ItemType Directory -Force -ErrorAction SilentlyContinue
        }
        $stateFile = Join-Path $stateDir "DeploymentState.json"
        $json = $DeploymentState | ConvertTo-Json -Depth 6 -Compress
        Set-Content -Path $stateFile -Value $json -Force -ErrorAction SilentlyContinue

        # Mirror DeploymentState.json to deployment share if RemoteLogDir is active
        $remoteDir = if ($DeploymentState.PSObject.Properties['LogLocations'] -and $DeploymentState.LogLocations.RemoteLogDir) {
            $DeploymentState.LogLocations.RemoteLogDir
        } elseif ($DeploymentState.Execution.RemoteLogDir) {
            $DeploymentState.Execution.RemoteLogDir
        } else {
            ""
        }

        if ($remoteDir -and (Test-Path -LiteralPath $remoteDir -ErrorAction SilentlyContinue)) {
            $remoteStateFile = Join-Path $remoteDir "DeploymentState.json"
            Set-Content -Path $remoteStateFile -Value $json -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}
}

# ==============================================================================
# 4. ORCHESTRATION PIPELINE
# ==============================================================================

function Start-LiteDeployPipeline {
    # Generate unique, human-readable session deployment UID
    $deployUid = Get-LiteDeployUid

    # Create DeploymentId directory on Deployment Share and copy initial boot logs
    $remoteLogDir = Initialize-LiteDeployDeploymentShareLogDir -DeploymentUid $deployUid -BootCtx $BootObject

    # Export global pointers for runtime components and LogWriter
    $global:LiteDeployRemoteLogDir = $remoteLogDir

    $deployment = New-LiteDeployDeploymentObject -Uid $deployUid -BootCtx $BootObject -RemoteLogDir $remoteLogDir
    $global:LiteDeployDeployment = $deployment
    Save-LiteDeployDeploymentState -DeploymentState $deployment

    Write-LiteDeployLog "================================================================" -Level "INIT" -ForegroundColor Cyan -Component "DeploymentEngine"
    Write-LiteDeployLog "LiteDeploy Deployment Engine v1.0.0" -Level "INIT" -ForegroundColor Cyan -Component "DeploymentEngine"
    Write-LiteDeployLog "Deployment UID: $deployUid" -Level "INIT" -ForegroundColor Yellow -Component "DeploymentEngine"
    if ($remoteLogDir) {
        Write-LiteDeployLog "Remote Logs   : $remoteLogDir" -Level "INIT" -ForegroundColor Green -Component "DeploymentEngine"
    }
    Write-LiteDeployLog "================================================================" -Level "INIT" -ForegroundColor Cyan -Component "DeploymentEngine"

    try {
        # Hide/Minimize console window to focus UI dialogs
        if (Get-Command Set-HostShellWindow -ErrorAction SilentlyContinue) {
            try { Set-HostShellWindow -Action Minimize } catch {}
        }

        # --------------------------------------------------------------------------
        # PHASE 1: PRE-CHECK (Hardware, Network, and Readiness Assessment)
        # --------------------------------------------------------------------------
        $preCheckPassed = $false
        $deployment.CurrentPhase = 1

        if ($SkipPreCheck) {
            Write-LiteDeployLog "SkipPreCheck switch specified. Bypassing Phase 1 (HardwarePreCheck)." -Level "WARNING" -ForegroundColor Yellow -Component "DeploymentEngine"
            $preCheckPassed = $true
            $deployment.HardwarePreCheck.Passed = $true
            $deployment.HardwarePreCheck.CompletedTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
        }
        else {
            $deployment.Status = "HardwarePreCheck"
            Save-LiteDeployDeploymentState -DeploymentState $deployment

            $preCheckScript = Resolve-RuntimeComponent -ComponentName "030-HardwarePreCheck" -ScriptFileName "LiteDeploy.HardwarePreCheck.ps1"
            if (-not $preCheckScript) {
                Write-LiteDeployLog "Phase 1 Failed: 'LiteDeploy.HardwarePreCheck.ps1' could not be found." -Level "ERROR" -ForegroundColor Red -Component "DeploymentEngine"
                $deployment.Status = "Failed"
                $deployment.Execution.Errors += "HardwarePreCheckScriptNotFound"
                $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                Save-LiteDeployDeploymentState -DeploymentState $deployment
                return $deployment
            }

            Write-LiteDeployLog "Phase 1: Launching System Readiness Pre-Check..." -Level "CHECK" -ForegroundColor Cyan -Component "DeploymentEngine"
            try {
                # Execute HardwarePreCheck directly in the current STA PowerShell process
                $preCheckOutput = & $preCheckScript
        
                # HardwarePreCheck returns boolean ($true/$false) or exits when closed
                if ($preCheckOutput -is [bool]) {
                    $preCheckPassed = $preCheckOutput
                }
                elseif (Test-Path Variable:global:PreCheckPassed) {
                    $preCheckPassed = [bool]$global:PreCheckPassed
                }
                else {
                    $preCheckPassed = ($preCheckOutput -ne $false)
                }
            }
            catch {
                Write-LiteDeployLog "Phase 1: Unhandled exception during HardwarePreCheck execution: $_" -Level "ERROR" -ForegroundColor Red -Component "DeploymentEngine"
                $deployment.Status = "Failed"
                $deployment.Execution.Errors += "HardwarePreCheckException: $_"
                $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                Save-LiteDeployDeploymentState -DeploymentState $deployment
                return $deployment
            }

            if (-not $preCheckPassed) {
                Write-LiteDeployLog "Phase 1: HardwarePreCheck did not pass or was cancelled by user. Halting deployment pipeline." -Level "WARNING" -ForegroundColor Yellow -Component "DeploymentEngine"
                $deployment.Status = "Cancelled"
                $deployment.HardwarePreCheck.Passed = $false
                $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                Save-LiteDeployDeploymentState -DeploymentState $deployment
                return $deployment
            }

            $deployment.HardwarePreCheck.Passed = $true
            $deployment.HardwarePreCheck.CompletedTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            Write-LiteDeployLog "Phase 1: System Readiness Pre-Check completed successfully." -Level "SUCCESS" -ForegroundColor Green -Component "DeploymentEngine"
        }

        # --------------------------------------------------------------------------
        # PHASE 2: WORKFLOW SELECTION (Computer Identity, OS Workflow, Disk, Drivers)
        # --------------------------------------------------------------------------
        $deployment.CurrentPhase = 2
        $deployment.Status = "WorkflowSelection"
        Save-LiteDeployDeploymentState -DeploymentState $deployment

        $workflowScript = Resolve-RuntimeComponent -ComponentName "040-WorkflowSelection" -ScriptFileName "LiteDeploy.WorkflowSelection.ps1"
        if (-not $workflowScript) {
            Write-LiteDeployLog "Phase 2 Failed: 'LiteDeploy.WorkflowSelection.ps1' could not be found." -Level "ERROR" -ForegroundColor Red -Component "DeploymentEngine"
            $deployment.Status = "Failed"
            $deployment.Execution.Errors += "WorkflowSelectionScriptNotFound"
            $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            return $deployment
        }

        Write-LiteDeployLog "Phase 2: Launching Workflow Selection Wizard..." -Level "INIT" -ForegroundColor Cyan -Component "DeploymentEngine"
        $workflowOutput = $null
        try {
            # Execute WorkflowSelection directly in the current STA PowerShell process
            $workflowOutput = & $workflowScript
        }
        catch {
            Write-LiteDeployLog "Phase 2: Unhandled exception during WorkflowSelection execution: $_" -Level "ERROR" -ForegroundColor Red -Component "DeploymentEngine"
            $deployment.Status = "Failed"
            $deployment.Execution.Errors += "WorkflowSelectionException: $_"
            $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            return $deployment
        }

        # Evaluate WorkflowSelection result
        $deploymentRequested = $false
        if ($workflowOutput -is [bool]) {
            $deploymentRequested = $workflowOutput
        }
        elseif ($workflowOutput -and $workflowOutput.PSObject.Properties['DeploymentRequested']) {
            $deploymentRequested = [bool]$workflowOutput.DeploymentRequested
        }
        else {
            $deploymentRequested = ($workflowOutput -eq $true)
        }

        if (-not $deploymentRequested) {
            Write-LiteDeployLog "Phase 2: Workflow selection was cancelled by technician. Halting deployment pipeline." -Level "WARNING" -ForegroundColor Yellow -Component "DeploymentEngine"
            $deployment.Status = "Cancelled"
            $deployment.Workflow.Confirmed = $false
            $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            return $deployment
        }

        $deployment.Workflow.Confirmed = $true
        $deployment.Workflow.SelectionData = $workflowOutput
        $deployment.Workflow.CompletedTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        $deployment.Status = "ReadyForDeployment"
        Save-LiteDeployDeploymentState -DeploymentState $deployment
        Sync-LiteDeployLogsToShare -RemoteLogDir $deployment.Execution.RemoteLogDir

        Write-LiteDeployLog "Phase 2: Workflow configuration confirmed. Ready for deployment execution." -Level "SUCCESS" -ForegroundColor Green -Component "DeploymentEngine"

        # --------------------------------------------------------------------------
        # PHASE 3: DISK PREPARATION (Wipe, Layout, Format, Recovery Flags)
        # --------------------------------------------------------------------------
        $deployment.CurrentPhase = 3
        $deployment.Status = "DiskPreparation"
        $deployment.Execution.CurrentStep = "FormattingTargetDisk"
        $deployment.Execution.PercentComplete = 25
        Save-LiteDeployDeploymentState -DeploymentState $deployment

        $diskFormatScript = Resolve-RuntimeComponent -ComponentName "050-DiskPreparation" -ScriptFileName "LiteDeploy.DiskPreparation.ps1"
        if (-not $diskFormatScript) {
            Write-LiteDeployLog "Phase 3 Failed: 'LiteDeploy.DiskPreparation.ps1' could not be found." -Level "ERROR" -ForegroundColor Red -Component "DeploymentEngine"
            $deployment.Status = "Failed"
            $deployment.Execution.Errors += "DiskPreparationScriptNotFound"
            $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            return $deployment
        }

        # Resolve target disk index from workflow selection (default to 0)
        $targetDiskIndex = 0
        if ($workflowOutput -and $workflowOutput.PSObject.Properties['TargetDiskIndex'] -and ($null -ne $workflowOutput.TargetDiskIndex)) {
            $rawDisk = "$($workflowOutput.TargetDiskIndex)"
            if ($rawDisk -match '(\d+)') {
                $targetDiskIndex = [int]$matches[1]
            }
        }

        # Resolve firmware boot mode (UEFI vs LEGACY)
        $detectedBootMode = "UEFI"
        if ($env:firmware_type -and ($env:firmware_type -match "(?i)Legacy|BIOS")) {
            $detectedBootMode = "LEGACY"
        }

        # Temporary OS staging drive letter in WinPE (defaults to "W")
        $osStagingDriveLetter = "W"

        Write-LiteDeployLog "Phase 3: Formatting Disk $targetDiskIndex for $detectedBootMode deployment (Staging: ${osStagingDriveLetter}:)..." -Level "INIT" -ForegroundColor Cyan -Component "DeploymentEngine"

        $formatResult = $null
        try {
            $formatResult = & $diskFormatScript -DiskNumber $targetDiskIndex -BootMode $detectedBootMode -OSTempDriveLetter $osStagingDriveLetter -BootObject $BootObject
        }
        catch {
            Write-LiteDeployLog "Phase 3 Failed: Unhandled exception during disk formatting: $_" -Level "ERROR" -ForegroundColor Red -Component "DeploymentEngine"
            $deployment.Status = "Failed"
            $deployment.Execution.Errors += "DiskPreparationException: $_"
            $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            return $deployment
        }

        if (-not $formatResult -or -not $formatResult.Success) {
            Write-LiteDeployLog "Phase 3 Failed: Disk formatting did not succeed." -Level "ERROR" -ForegroundColor Red -Component "DeploymentEngine"
            $deployment.Status = "Failed"
            $deployment.Execution.Errors += "DiskPreparationFailed"
            $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            return $deployment
        }

        $deployment.Disk.Formatted               = $true
        $deployment.Disk.DiskNumber              = $formatResult.DiskNumber
        $deployment.Disk.BootMode                = $formatResult.BootMode
        $deployment.Disk.OSPartitionNumber       = $formatResult.OSPartitionNumber
        $deployment.Disk.OSDriveLetter           = $formatResult.OSDriveLetter
        $deployment.Disk.SystemPartitionNumber   = $formatResult.SystemPartitionNumber
        $deployment.Disk.RecoveryPartitionNumber = $formatResult.RecoveryPartitionNumber
        $deployment.Disk.TotalSizeGB             = $formatResult.TotalSizeGB
        $deployment.Disk.CompletedTime           = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

        $deployment.Status = "ReadyForStaging"
        $deployment.Execution.PercentComplete = 30
        Save-LiteDeployDeploymentState -DeploymentState $deployment
        Sync-LiteDeployLogsToShare -RemoteLogDir $deployment.Execution.RemoteLogDir

        Write-LiteDeployLog "Phase 3: Disk $targetDiskIndex formatted successfully ($($formatResult.TotalSizeGB) GB, OS at $($formatResult.OSDriveLetter))." -Level "SUCCESS" -ForegroundColor Green -Component "DeploymentEngine"

        # --------------------------------------------------------------------------
        # PHASE 4: OS IMAGE APPLICATION (Setup.exe Engine & Unattend Generation)
        # --------------------------------------------------------------------------
        $deployment.CurrentPhase = 4
        $deployment.Status = "ApplyingOSImage"
        $deployment.Execution.CurrentStep = "ApplyingOperatingSystem"
        $deployment.Execution.PercentComplete = 35
        Save-LiteDeployDeploymentState -DeploymentState $deployment

        $applyImageScript = Resolve-RuntimeComponent -ComponentName "080-OSInstallation" -ScriptFileName "LiteDeploy.OSInstallation.ps1"
        if (-not $applyImageScript) {
            Write-LiteDeployLog "Phase 4 Failed: 'LiteDeploy.OSInstallation.ps1' could not be found." -Level "ERROR" -ForegroundColor Red -Component "DeploymentEngine"
            $deployment.Status = "Failed"
            $deployment.Execution.Errors += "OSInstallationScriptNotFound"
            $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            return $deployment
        }

        # Extract selected OS SetupPath / ImagePath / ImageIndex from Workflow selection
        $selectedSetupPath  = ""
        $selectedImagePath  = ""
        $selectedImageIndex = 0
        if ($workflowOutput) {
            if ($workflowOutput.PSObject.Properties['WorkflowTag'] -and $workflowOutput.WorkflowTag) {
                $tag = $workflowOutput.WorkflowTag
                if ($tag.PSObject.Properties['SetupPath'] -and $tag.SetupPath) {
                    $selectedSetupPath = $tag.SetupPath
                }
                if ($tag.PSObject.Properties['ImagePath'] -and $tag.ImagePath) {
                    $selectedImagePath = $tag.ImagePath
                }
                if ($tag.PSObject.Properties['Index'] -and ($null -ne $tag.Index)) {
                    $selectedImageIndex = [int]$tag.Index
                }
            }
            if ($selectedImageIndex -le 0 -and $workflowOutput.PSObject.Properties['ImageIndex'] -and ($null -ne $workflowOutput.ImageIndex)) {
                $selectedImageIndex = [int]$workflowOutput.ImageIndex
            }
            if ($selectedImageIndex -le 0 -and $workflowOutput.PSObject.Properties['Index'] -and ($null -ne $workflowOutput.Index)) {
                $selectedImageIndex = [int]$workflowOutput.Index
            }
        }

        # Resolve BootConfig object if not already attached
        $bootConfigObj = if ($BootObject -and $BootObject.PSObject.Properties['Config']) {
            $BootObject.Config
        } else {
            $null
        }

        Write-LiteDeployLog "Phase 4: Initiating OS installation (Image Index: $(if ($selectedImageIndex -gt 0) { $selectedImageIndex } else { 1 })) on $($formatResult.OSDriveLetter) via Setup.exe..." -Level "INIT" -ForegroundColor Cyan -Component "DeploymentEngine"

        $deployment.OSInstall.StartedTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        Save-LiteDeployDeploymentState -DeploymentState $deployment

        $applyResult = $null
        try {
            $applyResult = & $applyImageScript `
                -SetupPath $selectedSetupPath `
                -ImagePath $selectedImagePath `
                -ImageIndex $selectedImageIndex `
                -Destination $formatResult.OSDriveLetter `
                -WorkflowSelection $workflowOutput `
                -DiskResult $formatResult `
                -BootConfig $bootConfigObj `
                -BootObject $BootObject
        }
        catch {
            Write-LiteDeployLog "Phase 4 Failed: Unhandled exception during OS image application: $_" -Level "ERROR" -ForegroundColor Red -Component "DeploymentEngine"
            $deployment.Status = "Failed"
            $deployment.Execution.Errors += "OSInstallationException: $_"
            $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            return $deployment
        }

        if (-not $applyResult -or -not $applyResult.Success) {
            Write-LiteDeployLog "Phase 4 Failed: OS image application did not succeed." -Level "ERROR" -ForegroundColor Red -Component "DeploymentEngine"
            $deployment.Status = "Failed"
            $deployment.Execution.Errors += "OSInstallationFailed"
            $deployment.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            return $deployment
        }

        $deployment.OSInstall.Applied         = $true
        $deployment.OSInstall.Engine          = $applyResult.Engine
        $deployment.OSInstall.SetupPath       = $applyResult.SetupPath
        $deployment.OSInstall.ImageIndex      = $applyResult.ImageIndex
        $deployment.OSInstall.UnattendPath    = $applyResult.UnattendPath
        $deployment.OSInstall.ExitCode        = $applyResult.ExitCode
        $deployment.OSInstall.DurationSeconds = $applyResult.DurationSeconds
        $deployment.OSInstall.CompletedTime   = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

        $deployment.Status = "OSImageApplied"
        $deployment.Execution.PercentComplete = 70
        Save-LiteDeployDeploymentState -DeploymentState $deployment
        Sync-LiteDeployLogsToShare -RemoteLogDir $deployment.Execution.RemoteLogDir

        Write-LiteDeployLog "Phase 4: Windows OS image applied successfully (Image Index: $($applyResult.ImageIndex)) in $($applyResult.DurationSeconds) seconds (Exit code: $($applyResult.ExitCode))." -Level "SUCCESS" -ForegroundColor Green -Component "DeploymentEngine"

        # --------------------------------------------------------------------------
        # PHASE 5: ORCHESTRATION SUMMARY / OFFLINE STAGING HANDOFF
        # --------------------------------------------------------------------------
        Write-LiteDeployLog "================================================================" -Level "SUCCESS" -ForegroundColor Green -Component "DeploymentEngine"
        Write-LiteDeployLog "LiteDeploy Pre-Flight, Disk Preparation & OS Apply Complete [UID: $deployUid]." -Level "SUCCESS" -ForegroundColor Green -Component "DeploymentEngine"
        Write-LiteDeployLog "Target Disk : Disk $targetDiskIndex ($detectedBootMode) | OS Partition: $($formatResult.OSDriveLetter)" -Level "SUCCESS" -ForegroundColor Green -Component "DeploymentEngine"
        Write-LiteDeployLog "OS Applied  : $($applyResult.SetupPath) (Exit Code: $($applyResult.ExitCode))" -Level "SUCCESS" -ForegroundColor Green -Component "DeploymentEngine"
        Write-LiteDeployLog "Unattend XML: $($applyResult.UnattendPath)" -Level "SUCCESS" -ForegroundColor Green -Component "DeploymentEngine"
        Write-LiteDeployLog "================================================================" -Level "SUCCESS" -ForegroundColor Green -Component "DeploymentEngine"

        return $deployment
        }
        finally {
            # Synchronize final logs to deployment share
            if ($deployment -and $deployment.Execution.RemoteLogDir) {
                Sync-LiteDeployLogsToShare -RemoteLogDir $deployment.Execution.RemoteLogDir
            }

            # Restore console window when exiting orchestration
            if (Get-Command Set-HostShellWindow -ErrorAction SilentlyContinue) {
                try { Set-HostShellWindow -Action Restore } catch {}
            }
        }
    }

# ==============================================================================
# 5. ENTRY POINT EXECUTION
# ==============================================================================

Start-LiteDeployPipeline
