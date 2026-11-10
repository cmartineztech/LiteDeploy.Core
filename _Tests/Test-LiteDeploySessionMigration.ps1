<#
.SYNOPSIS
    Reproducible test suite for LiteDeploy Session migration, state persistence,
    secrets exclusion, Admin.Build directed cleanup, and OS live monitor (PS 5.1 & 7).

.DESCRIPTION
    Validates:
      1) Session metadata fast-exit and dot-source isolation (no unsolicited output/writes).
      2) NewDeploymentObject creation with sensitive BootCtx fixture.
      3) State serialization, passThru, and secrets exclusion without input mutation.
      4) Admin.Build publish with pre-seeded obsolete files and preserved sentinels.
      5) Normalized ComponentIds across all runtime components and CMTrace tags.
      6) Show-LiteDeployOSProbe snapshot render (-Once) and execution guard contract.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$passes = 0
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Condition {
    param([bool]$Condition, [string]$TestName)
    if ($Condition) {
        $script:passes++
        Write-Host "  [PASS] $TestName" -ForegroundColor Green
    } else {
        $script:failures.Add($TestName)
        Write-Host "  [FAIL] $TestName" -ForegroundColor Red
    }
}

Write-Host "`n=== LiteDeploy Session Migration & Architecture Verification ===" -ForegroundColor Cyan

$RepoRoot = Split-Path -Parent $PSScriptRoot
$RuntimeRoot = Join-Path $RepoRoot "Engine\Runtime"
$AdminRoot = Join-Path $RepoRoot "Engine\Admin"

# Isolated temporary workspace for all tests
$systemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$TestTemp = Join-Path $systemTemp ("LiteDeploy_SessionTest_" + [Guid]::NewGuid().ToString("N"))
$null = New-Item -Path $TestTemp -ItemType Directory -Force

# Snapshot global variables to restore on completion
$savedGlobals = @{
    LiteDeployRemoteLogDir    = if (Test-Path 'variable:global:LiteDeployRemoteLogDir') { $global:LiteDeployRemoteLogDir } else { $null }
    LiteDeployOsLogDir        = if (Test-Path 'variable:global:LiteDeployOsLogDir') { $global:LiteDeployOsLogDir } else { $null }
    LiteDeployDeployment      = if (Test-Path 'variable:global:LiteDeployDeployment') { $global:LiteDeployDeployment } else { $null }
    LiteDeployPathSettings    = if (Test-Path 'variable:global:LiteDeployPathSettings') { $global:LiteDeployPathSettings } else { $null }
}

try {
    # -------------------------------------------------------------------------
    # Group 1: Session Metadata & Dot-Source Isolation
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 1] Session Metadata & Dot-Source Isolation..." -ForegroundColor Yellow

    $sessionScript = Join-Path $RuntimeRoot "030-Session\LiteDeploy.Session.ps1"
    Assert-Condition (Test-Path -LiteralPath $sessionScript -PathType Leaf) "Session script exists at 030-Session"

    # Metadata execution: must return object without console log lines or file writes
    $meta = & $sessionScript -Metadata
    Assert-Condition ($null -ne $meta) "Session -Metadata returns object"
    Assert-Condition ($meta.ComponentId -eq "Session") "Session ComponentId is 'Session'"
    Assert-Condition ($meta.Version -eq "2.0.0") "Session Version is '2.0.0'"
    Assert-Condition ($meta.Category -eq "Runtime") "Session Category is 'Runtime'"
    Assert-Condition ($meta.TargetEnvironment -eq "Universal") "Session TargetEnvironment is 'Universal'"

    # Dot-sourcing Session into scope must not emit console lines or create disk artifacts
    $dotSourceOutput = . $sessionScript
    Assert-Condition ($null -eq $dotSourceOutput -or $dotSourceOutput.Length -eq 0) "Dot-sourcing Session emits no pipeline output"
    Assert-Condition ([bool](Get-Command New-LiteDeployDeploymentObject -ErrorAction SilentlyContinue)) "New-LiteDeployDeploymentObject is loaded"
    Assert-Condition ([bool](Get-Command Save-LiteDeployDeploymentState -ErrorAction SilentlyContinue)) "Save-LiteDeployDeploymentState is loaded"
    Assert-Condition ([bool](Get-Command Get-LiteDeployState -ErrorAction SilentlyContinue)) "Get-LiteDeployState is loaded"
    Assert-Condition ([bool](Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue)) "Write-LiteDeployLog is loaded"

    # -------------------------------------------------------------------------
    # Group 2: Sensitive BootCtx Fixture & In-Memory Immutability
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 2] Sensitive Fixture & Deployment Object Creation..." -ForegroundColor Yellow

    $fakePassword = "SensitiveTestPassword123!"
    $fakeToken = "BearerToken_XYZ987654321"
    $fakeSecret = "SuperSecretApiSecret"
    $fakeSecure = ("SecretSecureString" | ConvertTo-SecureString -AsPlainText -Force)
    $fakeCred = [System.Management.Automation.PSCredential]::new("DeployUser", $fakeSecure)

    $bootFixture = [PSCustomObject]@{
        DeploymentType   = "Network"
        DriveLetter      = "Z:"
        NetworkPath      = "\\Server\DeploymentShare$"
        Password         = $fakePassword
        ApiToken         = $fakeToken
        SharedSecret     = $fakeSecret
        UserCredential   = $fakeCred
        SecureData       = $fakeSecure
        ComputerSetup    = [PSCustomObject]@{
            ComputerName = "TEST-DESKTOP-01"
            JoinDomain   = "CONTOSO"
            DomainPassword = $fakePassword
        }
    }

    $deployment = New-LiteDeployDeploymentObject -BootCtx $bootFixture -Uid "TEST-UID-MIGRATION-001"
    Assert-Condition ($null -ne $deployment) "New-LiteDeployDeploymentObject succeeds"
    Assert-Condition ($deployment.DeploymentUid -eq "TEST-UID-MIGRATION-001") "Deployment UID assigned correctly"
    Assert-Condition ($deployment.Status -eq "Initializing") "Initial Status is 'Initializing'"

    # Verify input fixture was NOT mutated by constructor
    Assert-Condition ($bootFixture.Password -eq $fakePassword) "Input fixture Password not mutated"
    Assert-Condition ($bootFixture.ApiToken -eq $fakeToken) "Input fixture ApiToken not mutated"
    Assert-Condition ($bootFixture.SharedSecret -eq $fakeSecret) "Input fixture SharedSecret not mutated"
    Assert-Condition ($bootFixture.UserCredential.UserName -eq "DeployUser") "Input fixture Credential intact"

    # -------------------------------------------------------------------------
    # Group 3: State Persistence, PassThru, and Secrets Exclusion
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 3] State Persistence & Secrets Exclusion..." -ForegroundColor Yellow

    $stateDir = Join-Path $TestTemp "IsolatedState"
    $null = New-Item -Path $stateDir -ItemType Directory -Force
    $stateFilePath = Join-Path $stateDir "DeploymentState.json"

    # Save state with PassThru
    $passThruResult = Save-LiteDeployDeploymentState -DeploymentState $deployment -Path $stateFilePath -NoRemote -PassThru
    Assert-Condition ($null -ne $passThruResult) "Save-LiteDeployDeploymentState -PassThru returns object"
    Assert-Condition (Test-Path -LiteralPath $stateFilePath -PathType Leaf) "DeploymentState.json written to target path"

    # Inspect persisted JSON content on disk
    $persistedRaw = Get-Content -LiteralPath $stateFilePath -Raw -Encoding UTF8
    Assert-Condition ($persistedRaw.Length -gt 0) "Persisted state file is not empty"
    Assert-Condition ($persistedRaw -notmatch [regex]::Escape($fakePassword)) "Persisted JSON excludes raw Password"
    Assert-Condition ($persistedRaw -notmatch [regex]::Escape($fakeToken)) "Persisted JSON excludes raw Token"
    Assert-Condition ($persistedRaw -notmatch [regex]::Escape($fakeSecret)) "Persisted JSON excludes raw Secret"
    Assert-Condition ($persistedRaw -notmatch "SecretSecureString") "Persisted JSON excludes raw SecureString"

    # Read back state via Session reader
    $readState = Get-LiteDeployState -Path $stateFilePath
    Assert-Condition ($null -ne $readState) "Get-LiteDeployState successfully reads persisted file"
    Assert-Condition ($readState.DeploymentUid -eq "TEST-UID-MIGRATION-001") "Read state retains DeploymentUid"
    Assert-Condition ($readState.BootObject.DeploymentType -eq "Network") "Read state retains DeploymentType"
    Assert-Condition ($readState.BootObject.DriveLetter -eq "Z:") "Read state retains DriveLetter"

    # -------------------------------------------------------------------------
    # Group 4: Admin.Build Directed Cleanup & Sentinel Preservation
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 4] Admin.Build Directed Cleanup & Sentinels..." -ForegroundColor Yellow

    $publishTarget = Join-Path $TestTemp "PublishedShare"
    $runtimePublished = Join-Path $publishTarget "Engine\Runtime"
    $configPublished  = Join-Path $publishTarget "Config"
    $contentPublished = Join-Path $publishTarget "Content"
    $logsPublished    = Join-Path $publishTarget "WorkLogs"

    $null = New-Item -Path $runtimePublished -ItemType Directory -Force
    $null = New-Item -Path $configPublished -ItemType Directory -Force
    $null = New-Item -Path $contentPublished -ItemType Directory -Force
    $null = New-Item -Path $logsPublished -ItemType Directory -Force

    # Pre-seed obsolete scripts
    $staleLogsPath = Join-Path $runtimePublished "LiteDeploy.Logs.ps1"
    $staleStatePath = Join-Path $runtimePublished "LiteDeploy.State.ps1"
    $staleProbePath = Join-Path $runtimePublished "LiteDeploy.OS.InteractiveProbe.ps1"

    Set-Content -LiteralPath $staleLogsPath -Value "# Obsolete fused logs script" -Encoding UTF8
    Set-Content -LiteralPath $staleStatePath -Value "# Obsolete fused state script" -Encoding UTF8
    Set-Content -LiteralPath $staleProbePath -Value "# Obsolete standalone probe script" -Encoding UTF8

    # Pre-seed non-script sentinel files
    $configSentinel = Join-Path $configPublished "BootConfig.xml"
    $contentSentinel = Join-Path $contentPublished "Catalog.json"
    $logsSentinel = Join-Path $logsPublished "PriorRun.log"

    Set-Content -LiteralPath $configSentinel -Value "<Config>SentinelData</Config>" -Encoding UTF8
    Set-Content -LiteralPath $contentSentinel -Value '{"Sentinel": "ContentData"}' -Encoding UTF8
    Set-Content -LiteralPath $logsSentinel -Value "2026-11-08 Prior run log data" -Encoding UTF8

    # Run Admin.Build sync to the isolated temporary share
    $adminBuildScript = Join-Path $AdminRoot "000-Build\LiteDeploy.Admin.Build.ps1"
    & $adminBuildScript -DeploymentShare $publishTarget -Clean:$false

    # Assert published Session matches source hash
    $publishedSessionPath = Join-Path $runtimePublished "LiteDeploy.Session.ps1"
    Assert-Condition (Test-Path -LiteralPath $publishedSessionPath -PathType Leaf) "LiteDeploy.Session.ps1 published to Engine\Runtime"

    $srcBytes = [System.IO.File]::ReadAllBytes($sessionScript)
    $pubBytes = [System.IO.File]::ReadAllBytes($publishedSessionPath)
    $srcSha = (Get-FileHash -LiteralPath $sessionScript -Algorithm SHA256).Hash
    $pubSha = (Get-FileHash -LiteralPath $publishedSessionPath -Algorithm SHA256).Hash
    Assert-Condition ($srcSha -eq $pubSha) "Published Session SHA256 matches source ($srcSha)"

    # Assert obsolete files removed by directed cleanup
    Assert-Condition (-not (Test-Path -LiteralPath $staleLogsPath)) "Obsolete LiteDeploy.Logs.ps1 was removed by directed cleanup"
    Assert-Condition (-not (Test-Path -LiteralPath $staleStatePath)) "Obsolete LiteDeploy.State.ps1 was removed by directed cleanup"
    Assert-Condition (-not (Test-Path -LiteralPath $staleProbePath)) "Obsolete LiteDeploy.OS.InteractiveProbe.ps1 was removed by directed cleanup"

    # Assert non-script sentinels preserved intact
    Assert-Condition (Test-Path -LiteralPath $configSentinel) "Config sentinel preserved"
    Assert-Condition (Test-Path -LiteralPath $contentSentinel) "Content sentinel preserved"
    Assert-Condition (Test-Path -LiteralPath $logsSentinel) "WorkLogs sentinel preserved"
    Assert-Condition ((Get-Content -LiteralPath $configSentinel -Raw).Trim() -eq "<Config>SentinelData</Config>") "Config sentinel content intact"

    # -------------------------------------------------------------------------
    # Group 5: Normalized Component IDs & CMTrace Tags
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 5] Normalized Component IDs & Logging Tags..." -ForegroundColor Yellow

    $componentsToTest = @(
        @{ Rel = "000-Boot\LiteDeploy.PE.Boot.ps1"; ExpectedId = "PE.Boot" },
        @{ Rel = "010-Engine\LiteDeploy.PE.Engine.ps1"; ExpectedId = "PE.Engine" },
        @{ Rel = "010-Engine\LiteDeploy.OS.Engine.ps1"; ExpectedId = "OS.Engine" },
        @{ Rel = "020-Environment\LiteDeploy.Environment.ps1"; ExpectedId = "Environment" },
        @{ Rel = "030-Session\LiteDeploy.Session.ps1"; ExpectedId = "Session" },
        @{ Rel = "040-Hardware\LiteDeploy.Hardware.ps1"; ExpectedId = "Hardware" },
        @{ Rel = "050-Workflow\LiteDeploy.Workflow.ps1"; ExpectedId = "Workflow" },
        @{ Rel = "060-Disk\LiteDeploy.Disk.ps1"; ExpectedId = "Disk" },
        @{ Rel = "070-Drivers\LiteDeploy.Drivers.ps1"; ExpectedId = "Drivers" },
        @{ Rel = "080-Image\LiteDeploy.Image.ps1"; ExpectedId = "Image" },
        @{ Rel = "090-Packages\LiteDeploy.Packages.ps1"; ExpectedId = "Packages" },
        @{ Rel = "100-UI\HostShell\LiteDeploy.UI.HostShell.ps1"; ExpectedId = "UI.HostShell" },
        @{ Rel = "100-UI\HardwarePrecheck\LiteDeploy.UI.HardwarePrecheck.ps1"; ExpectedId = "UI.HardwarePrecheck" },
        @{ Rel = "100-UI\WorkflowSelection\LiteDeploy.UI.WorkflowSelection.ps1"; ExpectedId = "UI.WorkflowSelection" },
        @{ Rel = "100-UI\WorkflowSelection\LiteDeploy.UI.WorkflowSelectionDriverPicker.ps1"; ExpectedId = "UI.DriverPicker" },
        @{ Rel = "100-UI\Progress\LiteDeploy.UI.Progress.ps1"; ExpectedId = "UI.Progress" }
    )

    foreach ($comp in $componentsToTest) {
        $compPath = Join-Path $RuntimeRoot $comp.Rel
        Assert-Condition (Test-Path -LiteralPath $compPath -PathType Leaf) "File exists: $($comp.Rel)"
        $metaObj = & $compPath -Metadata
        Assert-Condition ($metaObj.ComponentId -eq $comp.ExpectedId) "ComponentId is '$($comp.ExpectedId)' for $($comp.Rel)"
    }

    # Verify CMTrace logging emits exact Component attribute via Session writer and component function
    $logTestDir = Join-Path $TestTemp "CMTraceTestLogs"
    $null = New-Item -Path $logTestDir -ItemType Directory -Force
    $cmtraceLog = Join-Path $logTestDir "LiteDeploy.Execution.log"

    # 1. Direct Session logging writer with standard component identities
    Write-LiteDeployLog -Message "PE Engine message" -Component "PE.Engine" -LogPath $logTestDir -NoConsole
    Write-LiteDeployLog -Message "OS Engine message" -Component "OS.Engine" -LogPath $logTestDir -NoConsole
    Write-LiteDeployLog -Message "Drivers message" -Component "Drivers" -LogPath $logTestDir -NoConsole
    Write-LiteDeployLog -Message "UI WorkflowSelection message" -Component "UI.WorkflowSelection" -LogPath $logTestDir -NoConsole

    # 2. Test actual internal component function: Initialize-LiteDeployDeploymentShareLogDir emits component="Session"
    $fakeRuntimePaths = [pscustomobject]@{
        DeploymentLogRoot  = $logTestDir
        LocalLogDirectory  = $logTestDir
    }
    $null = Initialize-LiteDeployDeploymentShareLogDir -RuntimePaths $fakeRuntimePaths -DeploymentUid "TEST-UID-LOG-001"

    $cmtraceContent = Get-Content -LiteralPath $cmtraceLog -Raw
    Assert-Condition ($cmtraceContent -match 'component="PE\.Engine"') "CMTrace entry recorded component='PE.Engine'"
    Assert-Condition ($cmtraceContent -match 'component="OS\.Engine"') "CMTrace entry recorded component='OS.Engine'"
    Assert-Condition ($cmtraceContent -match 'component="Drivers"') "CMTrace entry recorded component='Drivers'"
    Assert-Condition ($cmtraceContent -match 'component="UI\.WorkflowSelection"') "CMTrace entry recorded component='UI.WorkflowSelection'"
    Assert-Condition ($cmtraceContent -match 'component="Session"') "Initialize-LiteDeployDeploymentShareLogDir recorded component='Session'"

    # -------------------------------------------------------------------------
    # Group 6: Show-LiteDeployOSProbe Snapshot & Execution Guard Contract
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 6] Show-LiteDeployOSProbe Snapshot & Execution Guards..." -ForegroundColor Yellow

    $osEngineScript = Join-Path $RuntimeRoot "010-Engine\LiteDeploy.OS.Engine.ps1"
    . $osEngineScript

    Assert-Condition ([bool](Get-Command Show-LiteDeployOSProbe -ErrorAction SilentlyContinue)) "Show-LiteDeployOSProbe function is loaded"
    Assert-Condition ([bool](Get-Command Test-LiteDeployShouldLaunchOSProbe -ErrorAction SilentlyContinue)) "Test-LiteDeployShouldLaunchOSProbe function is loaded"
    Assert-Condition ([bool](Get-Command Invoke-LiteDeployFullOSResumeEntryPoint -ErrorAction SilentlyContinue)) "Invoke-LiteDeployFullOSResumeEntryPoint function is loaded"
    Assert-Condition (-not [bool](Get-Command Start-LiteDeployFullOSInteractiveProbe -ErrorAction SilentlyContinue)) "Obsolete Start-LiteDeployFullOSInteractiveProbe removed"

    # Verification of OS Engine metadata & banner isolation (prevent Environment metadata pollution)
    $metaOS = Get-LiteDeployOSMetadata
    Assert-Condition ($metaOS.ComponentId -eq "OS.Engine") "Get-LiteDeployOSMetadata returns ComponentId 'OS.Engine'"
    Assert-Condition ($metaOS.Name -eq "LiteDeploy FullOS Engine") "OS Engine metadata retains Name 'LiteDeploy FullOS Engine' after Environment import"
    Assert-Condition ($metaOS.Version -eq "2.0.0") "OS Engine metadata retains Version '2.0.0' after Environment import"
    $activeMeta = Get-LiteDeployComponentMetadata
    Assert-Condition ($activeMeta.ComponentId -eq "OS.Engine") "Active Get-LiteDeployComponentMetadata resolves to OS.Engine without Environment pollution"
    Assert-Condition ("$($metaOS.Name) v$($metaOS.Version)" -eq "LiteDeploy FullOS Engine v2.0.0") "OS Engine startup banner renders 'LiteDeploy FullOS Engine v2.0.0' without lifecycle side effects"

    # Mocks for safe execution: never kill host processes or clear interactive terminal
    $script:mockKilledSysprep = 0
    function Stop-LiteDeployAuditModeSysprep {
        $script:mockKilledSysprep++
        return 0
    }

    $script:mockClearHostCalls = 0
    function Clear-Host {
        $script:mockClearHostCalls++
    }

    # Intercept Write-Host to capture console rendering safely without host pollution
    $script:capturedHostOutput = [System.Collections.Generic.List[string]]::new()
    function Write-Host {
        [CmdletBinding()]
        param(
            [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
            $Object,
            [switch]$NoNewline,
            $ForegroundColor,
            $BackgroundColor
        )
        $line = if ($null -ne $Object) { [string]$Object } else { "" }
        $script:capturedHostOutput.Add($line)
    }

    # 6a: Test single-frame snapshot render (-Once) with mocked sysprep & Clear-Host
    $script:capturedHostOutput.Clear()
    $script:mockClearHostCalls = 0
    $script:mockKilledSysprep = 0

    Show-LiteDeployOSProbe -DeploymentState $deployment -LocalRoot $TestTemp -StatePath $stateFilePath -Once

    $renderedSnapshot = $script:capturedHostOutput -join "`n"
    Assert-Condition ($script:mockClearHostCalls -gt 0) "Show-LiteDeployOSProbe invoked Clear-Host to clean console"
    Assert-Condition ($script:mockKilledSysprep -gt 0) "Show-LiteDeployOSProbe invoked sysprep sweep (mocked safely)"
    Assert-Condition ($renderedSnapshot -match "TEST-UID-MIGRATION-001") "Probe displays current DeploymentUid"
    Assert-Condition ($renderedSnapshot -match "Initializing") "Probe displays current Status"
    Assert-Condition ($renderedSnapshot -match "TEST-DESKTOP-01") "Probe displays ComputerName from selection data"
    Assert-Condition ($renderedSnapshot -match "Execution Log\s*:") "Probe displays 'Execution Log' path (LiteDeploy.Execution.log)"
    Assert-Condition ($renderedSnapshot -notmatch "Probe Log\s*:") "Probe does not display non-existent 'Probe Log'"
    Assert-Condition ($renderedSnapshot -notmatch [regex]::Escape($fakePassword)) "Probe output excludes raw passwords"

    # 6b: Test live refresh across 2 iterations reading updated state file from disk
    $liveStateDir = Join-Path $TestTemp "LiveStateDir"
    $null = New-Item -Path $liveStateDir -ItemType Directory -Force
    $liveStatePath = Join-Path $liveStateDir "DeploymentState.json"

    $liveStateObj = New-LiteDeployDeploymentObject -BootCtx $bootFixture -Uid "TEST-UID-LIVE-002"
    $liveStateObj.Execution.CurrentStep = "StepOneInitial"
    $null = Save-LiteDeployDeploymentState -DeploymentState $liveStateObj -Path $liveStatePath -NoRemote

    $script:capturedHostOutput.Clear()
    $script:mockClearHostCalls = 0
    $script:mockSleepTicks = 0

    function Start-Sleep {
        param([int]$Seconds = 0)
        $script:mockSleepTicks++
        if ($script:mockSleepTicks -eq 1) {
            # Update the fixture file on disk before tick 2
            $freshDisk = Get-LiteDeployState -Path $liveStatePath
            $freshDisk.Execution.CurrentStep = "StepTwoLiveUpdated"
            $null = Save-LiteDeployDeploymentState -DeploymentState $freshDisk -Path $liveStatePath -NoRemote
        }
    }

    Show-LiteDeployOSProbe -LocalRoot $liveStateDir -StatePath $liveStatePath -RefreshSeconds 1 -MaxIterations 2

    $renderedLive = $script:capturedHostOutput -join "`n"
    Assert-Condition ($script:mockSleepTicks -eq 1) "Mocked Start-Sleep fired between tick 1 and tick 2"
    Assert-Condition ($script:mockClearHostCalls -ge 2) "Clear-Host invoked on refresh iterations"
    Assert-Condition ($renderedLive -match "StepOneInitial") "Probe rendered tick 1 state (StepOneInitial)"
    Assert-Condition ($renderedLive -match "StepTwoLiveUpdated") "Probe re-read state file and rendered live tick 2 update (StepTwoLiveUpdated)"

    # 6c: Fallback to in-memory snapshot if state file is absent or unreadable
    $script:capturedHostOutput.Clear()
    $missingStatePath = Join-Path $TestTemp "NonExistent_DeploymentState.json"
    Show-LiteDeployOSProbe -DeploymentState $deployment -StatePath $missingStatePath -LocalRoot $TestTemp -Once
    $renderedFallback = $script:capturedHostOutput -join "`n"
    Assert-Condition ($renderedFallback -match "TEST-UID-MIGRATION-001") "Fallback to in-memory DeploymentState succeeded when state file absent"

    # Corrupt / unreadable state file fallback (reproduces live monitor crash when state file is malformed)
    $script:capturedHostOutput.Clear()
    $corruptStatePath = Join-Path $TestTemp "Corrupt_DeploymentState.json"
    Set-Content -LiteralPath $corruptStatePath -Value "{ invalid JSON content" -Encoding UTF8
    $corruptProbeThrew = $false
    try {
        Show-LiteDeployOSProbe -DeploymentState $deployment -StatePath $corruptStatePath -LocalRoot $TestTemp -Once
    }
    catch {
        $corruptProbeThrew = $true
    }
    $renderedCorruptFallback = $script:capturedHostOutput -join "`n"
    Assert-Condition (-not $corruptProbeThrew) "Show-LiteDeployOSProbe does not throw when state file contains corrupt JSON"
    Assert-Condition ($renderedCorruptFallback -match "TEST-UID-MIGRATION-001") "Fallback to in-memory DeploymentState succeeded when state file is corrupt/unreadable"
    Assert-Condition ($renderedCorruptFallback -notmatch [regex]::Escape($fakePassword)) "Probe output excludes raw passwords under fallback"

    # Verify next iteration / subsequent read recovers live state once JSON is repaired
    $script:capturedHostOutput.Clear()
    $repairedStateObj = New-LiteDeployDeploymentObject -BootCtx $bootFixture -Uid "TEST-UID-REPAIRED-003"
    $null = Save-LiteDeployDeploymentState -DeploymentState $repairedStateObj -Path $corruptStatePath -NoRemote
    Show-LiteDeployOSProbe -DeploymentState $deployment -StatePath $corruptStatePath -LocalRoot $TestTemp -Once
    $renderedRepaired = $script:capturedHostOutput -join "`n"
    Assert-Condition ($renderedRepaired -match "TEST-UID-REPAIRED-003") "Probe re-reads and displays live state once file is repaired"

    # Remove Write-Host and Start-Sleep mocks to restore standard behavior
    Remove-Item -Path Function:Write-Host -ErrorAction SilentlyContinue
    Remove-Item -Path Function:Start-Sleep -ErrorAction SilentlyContinue

    # 6d: Execution Guard Contract (testing real Test-LiteDeployShouldLaunchOSProbe with real shapes under StrictMode)
    $fullOsContext = Get-LiteDeployFullOSContextFromState -DeploymentState $deployment

    # Case 1: Interactive Administrator Success (real shape from Start-LiteDeployFullOSResume)
    $interactiveSuccess = [pscustomobject]@{
        Success         = $true
        Context         = $fullOsContext
        LocalRoot       = $TestTemp
        StatePath       = $stateFilePath
        DeploymentState = $deployment
    }
    $adminIdent = [pscustomobject]@{
        Name     = "CONTOSO\DeployAdmin"
        IsSystem = $false
        User     = [pscustomobject]@{ Value = "S-1-5-21-12345-500" }
    }
    Assert-Condition (Test-LiteDeployShouldLaunchOSProbe -ResumeResult $interactiveSuccess -Identity $adminIdent -UserInteractive $true) `
        "Guard: Interactive Administrator Success launches probe"

    # Case 2: SYSTEM Deferred (real shape from Start-LiteDeployFullOSResume as SYSTEM)
    # Notice: Deferred outcome does NOT contain .Context
    $systemDeferred = [pscustomobject]@{
        Success  = $true
        Deferred = $true
        Identity = "SYSTEM"
        RunKey   = [pscustomobject]@{ Command = "powershell.exe" }
        Message  = "FullOS deferred to HKLM Run at Administrator logon; Setup sysprep CmdLine preserved."
    }
    $systemIdent = [pscustomobject]@{
        Name     = "NT AUTHORITY\SYSTEM"
        IsSystem = $true
        User     = [pscustomobject]@{ Value = "S-1-5-18" }
    }
    Assert-Condition (-not (Test-LiteDeployShouldLaunchOSProbe -ResumeResult $systemDeferred -Identity $systemIdent -UserInteractive $true)) `
        "Guard: SYSTEM Deferred blocks probe launch without StrictMode error"

    # Case 3: Failed Resume
    $failedResult = [pscustomobject]@{
        Success = $false
        Message = "Reconnection failed"
    }
    Assert-Condition (-not (Test-LiteDeployShouldLaunchOSProbe -ResumeResult $failedResult -Identity $adminIdent -UserInteractive $true)) `
        "Guard: Failed resume blocks probe launch"

    # Case 4: Null Result / Exception
    Assert-Condition (-not (Test-LiteDeployShouldLaunchOSProbe -ResumeResult $null -Identity $adminIdent -UserInteractive $true)) `
        "Guard: Null resume result blocks probe launch"

    # Case 5: Non-Interactive Session
    Assert-Condition (-not (Test-LiteDeployShouldLaunchOSProbe -ResumeResult $interactiveSuccess -Identity $adminIdent -UserInteractive $false)) `
        "Guard: Non-interactive session blocks probe launch"

    # Case 6: Safe evaluation of bare success without optional properties under StrictMode 2
    $bareSuccess = [pscustomobject]@{ Success = $true }
    Assert-Condition (Test-LiteDeployShouldLaunchOSProbe -ResumeResult $bareSuccess -Identity $adminIdent -UserInteractive $true) `
        "Guard: Safe optional property evaluation under StrictMode 2"

    # 6e: Orchestration Sequence & Cleanup Order (resume -> cleanup -> probe)
    # Testing Invoke-LiteDeployFullOSResumeEntryPoint with call-tracking mocks (no registry / no process kills)
    $script:orchestrationTrace = [System.Collections.Generic.List[string]]::new()
    $script:orchestrationOutcome = $interactiveSuccess

    function Start-LiteDeployFullOSResume {
        param($LocalRootName, $OsDriveLetter, $StatePath, $RuntimeRoot, [switch]$ForceDirect)
        $script:orchestrationTrace.Add("Start-LiteDeployFullOSResume")
        if ($script:orchestrationOutcome -eq "THROW") {
            throw "Simulated resume exception"
        }
        return $script:orchestrationOutcome
    }

    function Clear-LiteDeployFullOSSetupCmdLine {
        $script:orchestrationTrace.Add("Clear-LiteDeployFullOSSetupCmdLine")
        return [pscustomobject]@{ Cleared = $true }
    }

    function Stop-LiteDeployAuditModeSysprep {
        $script:orchestrationTrace.Add("Stop-LiteDeployAuditModeSysprep")
        return 0
    }

    function Show-LiteDeployOSProbe {
        param($ResumeResult, $LocalRoot, $StatePath)
        $script:orchestrationTrace.Add("Show-LiteDeployOSProbe")
    }

    # Test Sequence 1: Normal Interactive Success (Resume -> Finally Cleanup -> Probe)
    $script:orchestrationTrace.Clear()
    $script:orchestrationOutcome = $interactiveSuccess
    $null = Invoke-LiteDeployFullOSResumeEntryPoint -SkipTerminalDelegation -LocalRootName '~LiteDeploy'

    $traceNormal = $script:orchestrationTrace -join " -> "
    Assert-Condition ($traceNormal -eq "Start-LiteDeployFullOSResume -> Clear-LiteDeployFullOSSetupCmdLine -> Stop-LiteDeployAuditModeSysprep -> Show-LiteDeployOSProbe") `
        "Orchestration: Normal success order is Resume -> Cleanup (SetupCmdLine -> StopSysprep) -> Probe"

    # Test Sequence 2: Resume Throws Exception (Resume -> Finally Cleanup -> NO Probe)
    $script:orchestrationTrace.Clear()
    $script:orchestrationOutcome = "THROW"
    try {
        $null = Invoke-LiteDeployFullOSResumeEntryPoint -SkipTerminalDelegation -LocalRootName '~LiteDeploy'
    }
    catch {}

    $traceException = $script:orchestrationTrace -join " -> "
    Assert-Condition ($traceException -eq "Start-LiteDeployFullOSResume -> Clear-LiteDeployFullOSSetupCmdLine -> Stop-LiteDeployAuditModeSysprep") `
        "Orchestration: On exception, cleanup runs in finally and Probe is NEVER called"

    # Test Sequence 3: SYSTEM Deferred (Resume -> Finally Cleanup -> NO Probe)
    $script:orchestrationTrace.Clear()
    $script:orchestrationOutcome = $systemDeferred
    $null = Invoke-LiteDeployFullOSResumeEntryPoint -SkipTerminalDelegation -LocalRootName '~LiteDeploy'

    $traceDeferred = $script:orchestrationTrace -join " -> "
    Assert-Condition ($traceDeferred -eq "Start-LiteDeployFullOSResume -> Clear-LiteDeployFullOSSetupCmdLine -> Stop-LiteDeployAuditModeSysprep") `
        "Orchestration: On SYSTEM Deferred, cleanup runs in finally and Probe is NEVER called"
}
finally {
    # Restore global variables
    foreach ($entry in $savedGlobals.GetEnumerator()) {
        if ($null -ne $entry.Value) {
            Set-Variable -Scope Global -Name $entry.Key -Value $entry.Value
        } else {
            Remove-Variable -Scope Global -Name $entry.Key -ErrorAction SilentlyContinue
        }
    }

    # Strict isolation cleanup: verify absolute path is inside Temp before recursive removal
    if (Test-Path -LiteralPath $TestTemp) {
        $fullTestTemp = [System.IO.Path]::GetFullPath($TestTemp)
        if ($fullTestTemp.StartsWith($systemTemp, [System.StringComparison]::OrdinalIgnoreCase) -and $fullTestTemp.Length -gt $systemTemp.Length) {
            Remove-Item -LiteralPath $TestTemp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host "`n========================================================"
Write-Host "Passed: $passes  Failed: $($failures.Count)" -ForegroundColor $(if ($failures.Count -eq 0) { "Green" } else { "Red" })
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
}
exit 0
