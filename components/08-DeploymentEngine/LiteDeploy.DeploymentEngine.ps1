<#
.SYNOPSIS
    LiteDeploy Deployment Engine — WinPE orchestration entry point.

.DESCRIPTION
    Called by BootInitializer with an in-memory BootObject (including the share
    PSCredential). Orchestrates Phase A from the deployment plan:

        PreCheck (structured result)
            → SelectWorkflow (structured selection)
            → Initialize deployment state (stub for Setup /NoReboot)

    UI scripts close and return results; they do not start their successors.
    Setup, disk wipe, WinPECT handoff, and FullOS resume are not implemented yet.

.PARAMETER BootObject
    Boot payload from Get-LiteDeployBootConfig. Must remain in the same process
    so the PSCredential is never serialized or placed on a command line.

.PARAMETER Resume
    FullOS resume mode (planned). Not implemented on this branch.

.PARAMETER StatePath
    Path to DeploymentState.json for resume (planned).

.NOTES
    Compatible with Set-StrictMode 2.0 and Windows PowerShell 5.1 / WinPE.
    Production layout: sibling of PreCheck and SelectWorkflow under Engine\Scripts.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [psobject]$BootObject = $null,

    [Parameter(Mandatory = $false)]
    [switch]$Resume,

    [Parameter(Mandatory = $false)]
    [string]$StatePath = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if ($Resume) {
    Write-Warning "LiteDeploy.DeploymentEngine -Resume is not implemented yet."
    return [PSCustomObject]@{
        Status  = "NotImplemented"
        Phase   = "FullOSResume"
        Message = "FullOS engine resume is planned; this test branch only orchestrates WinPE Phase A."
    }
}

if ($BootObject) {
    $global:LiteDeployBootObject = $BootObject
}
elseif (Test-Path Variable:global:LiteDeployBootObject) {
    $BootObject = $global:LiteDeployBootObject
}

if (-not $BootObject) {
    throw "LiteDeploy.DeploymentEngine.ps1 requires -BootObject from BootInitializer (or `$global:LiteDeployBootObject)."
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

function Write-EngineLog {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Cyan
    )
    if ($Message) {
        Write-Host " [ENGINE]  $Message" -ForegroundColor $ForegroundColor
    }
    try {
        $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "X:" }
        $logDir = Join-Path $sysDrive "~LiteDeploy\WorkLogs"
        if (-not (Test-Path -LiteralPath $logDir)) {
            $null = New-Item -Path $logDir -ItemType Directory -Force -ErrorAction SilentlyContinue
        }
        $logFile = Join-Path $logDir "LiteDeploy.Engine.log"
        $now = Get-Date
        $line = "{0} [{1}] {2}" -f $now.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ"), $Level.ToUpper(), $Message
        Add-Content -LiteralPath $logFile -Value $line -ErrorAction SilentlyContinue
    }
    catch {}
}

function Resolve-EngineSiblingScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $candidates = [System.Collections.Generic.List[string]]::new()

    # Production: all engine scripts are siblings under Engine\Scripts.
    $candidates.Add((Join-Path $PSScriptRoot $FileName))

    # Same folder as BootInitializer's resolved EngineScriptPath (may point here).
    if ($BootObject -and $BootObject.PSObject.Properties['EngineScriptPath'] -and $BootObject.EngineScriptPath) {
        $engineFolder = Split-Path -Parent ([string]$BootObject.EngineScriptPath)
        if ($engineFolder) {
            $candidates.Add((Join-Path $engineFolder $FileName))
        }
    }

    # Development repository layout (numbered component folders).
    switch -Wildcard ($FileName) {
        "LiteDeploy.PreCheck.ps1" {
            $candidates.Add((Join-Path $PSScriptRoot "..\06-PreCheck\$FileName"))
        }
        "LiteDeploy.SelectWorkFlow.ps1" {
            $candidates.Add((Join-Path $PSScriptRoot "..\07-SelectWorkflow\$FileName"))
        }
    }

    # Mounted share / media root from BootObject.
    if ($BootObject -and $BootObject.PSObject.Properties['DriveLetter'] -and $BootObject.DriveLetter) {
        $root = [string]$BootObject.DriveLetter
        $candidates.Add((Join-Path $root "Engine\Scripts\$FileName"))
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
        }
    }

    return $null
}

function Get-EngineProperty {
    param(
        $InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Test-PreCheckContinue {
    param([psobject]$Result)

    if ($null -eq $Result) { return $false }

    # Structured contract (preferred).
    $continueRequested = Get-EngineProperty -InputObject $Result -Name "ContinueRequested"
    $preCheckPassed = Get-EngineProperty -InputObject $Result -Name "PreCheckPassed"
    if ($null -ne $continueRequested -or $null -ne $preCheckPassed) {
        return ([bool]$continueRequested -and [bool]$preCheckPassed)
    }

    # Legacy boolean return (standalone / older PreCheck).
    if ($Result -is [bool]) { return [bool]$Result }
    return $false
}

function Test-WorkflowSelectionConfirmed {
    param([psobject]$Result)

    if ($null -eq $Result) { return $false }

    $requested = Get-EngineProperty -InputObject $Result -Name "DeploymentRequested"
    if ($null -ne $requested) { return [bool]$requested }

    # Legacy boolean return.
    if ($Result -is [bool]) { return [bool]$Result }
    return $false
}

function Initialize-DeploymentStateStub {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$BootObject,

        [Parameter(Mandatory = $true)]
        [psobject]$Selection
    )

    $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "X:" }
    $stateRoot = Join-Path $sysDrive "~LiteDeploy\State"
    if (-not (Test-Path -LiteralPath $stateRoot)) {
        $null = New-Item -Path $stateRoot -ItemType Directory -Force
    }

    $deploymentId = "LD-{0}" -f (Get-Date).ToUniversalTime().ToString("yyMMdd-HHmmss")

    # Selection JSON: IDs and non-secret technician choices only. Never credentials.
    $selectionRecord = [ordered]@{
        schemaVersion         = "0.1-test"
        deploymentId          = $deploymentId
        computerName          = [string](Get-EngineProperty $Selection "ComputerName")
        computerDescription   = [string](Get-EngineProperty $Selection "ComputerDescription")
        workflowName          = [string](Get-EngineProperty $Selection "WorkflowName")
        workflowTag           = [string](Get-EngineProperty $Selection "WorkflowTag")
        osId                  = (Get-EngineProperty $Selection "OsId")
        editionId             = (Get-EngineProperty $Selection "EditionId")
        workflowId            = (Get-EngineProperty $Selection "WorkflowId")
        diskNumber            = (Get-EngineProperty $Selection "DiskNumber")
        diskModel             = [string](Get-EngineProperty $Selection "DiskModel")
        driverFolderPath      = [string](Get-EngineProperty $Selection "DriverFolderPath")
        autoDetectDrivers     = [bool](Get-EngineProperty $Selection "AutoDetectDrivers")
        requiredCredentialIds = @()
        sourceConfigPath      = [string](Get-EngineProperty $BootObject "ConfigPath")
        deploymentType        = [string](Get-EngineProperty $BootObject "DeploymentType")
        networkPath           = [string](Get-EngineProperty $BootObject "NetworkPath")
        createdAtUtc          = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    }

    $selectionPath = Join-Path $stateRoot "DeploymentSelection.json"
    ($selectionRecord | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $selectionPath -Encoding UTF8 -Force

    $stateRecord = [ordered]@{
        schemaVersion   = "0.1-test"
        deploymentId    = $deploymentId
        phase           = "Initialized"
        status          = "Pending"
        environment     = "WinPE"
        productName     = "LiteDeploy"
        workflowName    = $selectionRecord.workflowName
        computerName    = $selectionRecord.computerName
        computerModel   = $selectionRecord.diskModel
        currentStep     = "Selection captured — Setup /NoReboot not implemented on this branch"
        message         = "WinPE Phase A complete. Deployment engine stub stopped before disk modification."
        stepPercent     = 0
        overallPercent  = 0
        source          = if ($selectionRecord.deploymentType -eq "Media") { "Local (Media)" } else { $selectionRecord.networkPath }
        updatedAtUtc    = $selectionRecord.createdAtUtc
    }

    $stateFile = Join-Path $stateRoot "DeploymentState.json"
    ($stateRecord | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $stateFile -Encoding UTF8 -Force

    return [PSCustomObject]@{
        DeploymentId  = $deploymentId
        SelectionPath = $selectionPath
        StatePath     = $stateFile
        Phase         = "Initialized"
    }
}

# ------------------------------------------------------------------------------
# Phase A orchestration
# ------------------------------------------------------------------------------

Write-EngineLog "Deployment engine starting (WinPE Phase A orchestration)." -Level "INFO"

$preCheckPath = Resolve-EngineSiblingScript -FileName "LiteDeploy.PreCheck.ps1"
if (-not $preCheckPath) {
    throw "LiteDeploy.PreCheck.ps1 was not found beside the engine or under components/06-PreCheck."
}

$selectWorkflowPath = Resolve-EngineSiblingScript -FileName "LiteDeploy.SelectWorkFlow.ps1"
if (-not $selectWorkflowPath) {
    throw "LiteDeploy.SelectWorkFlow.ps1 was not found beside the engine or under components/07-SelectWorkflow."
}

Write-EngineLog "Invoking PreCheck: $preCheckPath" -Level "INFO"
$preCheckResult = & $preCheckPath -BootObject $BootObject

if (-not (Test-PreCheckContinue -Result $preCheckResult)) {
    $status = Get-EngineProperty $preCheckResult "Status"
    if (-not $status) { $status = "CancelledOrFailed" }
    Write-EngineLog "PreCheck did not continue (Status=$status). Stopping without disk changes." -Level "WARNING" -ForegroundColor Yellow
    return [PSCustomObject]@{
        Status          = $status
        Phase           = "PreCheck"
        PreCheckResult  = $preCheckResult
        Selection       = $null
        State           = $null
        Message         = "Deployment stopped after PreCheck; no disk modifications were attempted."
    }
}

Write-EngineLog "PreCheck Continue accepted. Invoking SelectWorkflow: $selectWorkflowPath" -Level "INFO" -ForegroundColor Green
$selection = & $selectWorkflowPath -BootObject $BootObject

if (-not (Test-WorkflowSelectionConfirmed -Result $selection)) {
    Write-EngineLog "Workflow selection cancelled. Stopping without disk changes." -Level "WARNING" -ForegroundColor Yellow
    return [PSCustomObject]@{
        Status         = "Cancelled"
        Phase          = "SelectWorkflow"
        PreCheckResult = $preCheckResult
        Selection      = $selection
        State          = $null
        Message        = "Technician cancelled workflow selection; no disk modifications were attempted."
    }
}

Write-EngineLog "Selection confirmed. Initializing deployment state stub (no Setup yet)." -Level "INFO" -ForegroundColor Green
$stateInfo = Initialize-DeploymentStateStub -BootObject $BootObject -Selection $selection

Write-EngineLog "State written: $($stateInfo.StatePath)" -Level "INFO"
Write-EngineLog "Selection written: $($stateInfo.SelectionPath)" -Level "INFO"
Write-EngineLog "Phase B (Setup /NoReboot, handoff, reboot) is not implemented on this test branch." -Level "WARNING" -ForegroundColor Yellow

return [PSCustomObject]@{
    Status         = "Initialized"
    Phase          = "Initialized"
    DeploymentId   = $stateInfo.DeploymentId
    PreCheckResult = $preCheckResult
    Selection      = $selection
    State          = $stateInfo
    Message        = "WinPE Phase A complete. Engine stub stopped before destructive work."
}
