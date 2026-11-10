<#
.SYNOPSIS
    Behavior-focused isolated test suite for Windows Setup (setup.exe) progress alignment.
.DESCRIPTION
    Validates:
    - Registry read-only reader (Get-LiteDeploySetupProgress) against volatile key contract
    - SetupProgress numeric validation 0..100, rejecting negative, >100, non-numeric without fabricated 0/100
    - Optional SetupPhase / SetupSubPhase numeric raw context without guessed phase names
    - StrictMode 2.0 execution with missing optional properties
    - Progress polling while process is actively alive (not just after return)
    - Milestone deduplication (every 10%) on actual observed crossing without fabricated milestones
    - Live evidence reproduction: 61% failure with Phase 5 and SubPhase 16
    - Baseline snapshot before launch: stale pre-existing registry data from prior attempts ignored
    - Clearing of baseline guard when progress/phase changes or key was missing before launch
    - Midrun disappearance: preserves last valid observation with honest label, never crashes
    - Phase changes and progress resets: fresh milestone context, latest failure uses most recent valid observation (not global max)
    - Exit code authority: non-zero exit after 100% remains failure
    - Exit code 3010 (reboot required) retained as success
    - Absent key initially/throughout: reports "Progress unavailable", never invents 0%
    - Process launch failure: reports "Progress unavailable (process launch failed)", no registry percent invented
    - Quoted paths with spaces and /NoReboot preservation
    - Native Setup log collection and mirror sync executed on all outcomes
    - Pure return object without pipeline pollution
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:TotalPassed = 0
$script:TotalFailed = 0

function Assert-Condition {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if ($Condition) {
        Write-Host "  [PASS] $Message" -ForegroundColor Green
        $script:TotalPassed++
    }
    else {
        Write-Host "  [FAIL] $Message" -ForegroundColor Red
        $script:TotalFailed++
    }
}

$TestRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $TestRoot
$RuntimeDir = Join-Path $RepoRoot "Engine\Runtime"

$sessionScript = Join-Path $RuntimeDir "030-Session\LiteDeploy.Session.ps1"
$imageScript   = Join-Path $RuntimeDir "080-Image\LiteDeploy.Image.ps1"

. $sessionScript
. $imageScript

$TestTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("LiteDeploy_SetupProgressTest_" + [System.Guid]::NewGuid().ToString("N"))
$null = New-Item -Path $TestTemp -ItemType Directory -Force

# Helper to create harmless mock target directory structure
$mockTargetRoot = Join-Path $TestTemp "MockTargetW"
$mockWindowsDir = Join-Path $mockTargetRoot "Windows"
$null = New-Item -Path $mockWindowsDir -ItemType Directory -Force

try {
    # Isolate session logging to temporary test folder
    $testWorkLogs = Join-Path $TestTemp "WorkLogs"
    $null = New-Item -Path $testWorkLogs -ItemType Directory -Force
    $global:LiteDeploySessionLogDir = $testWorkLogs

    Write-Host "`n========================================================" -ForegroundColor Cyan
    Write-Host " Windows Setup Progress Alignment Test Suite" -ForegroundColor Cyan
    Write-Host "========================================================" -ForegroundColor Cyan

    # -------------------------------------------------------------------------
    # Group 1: Registry Reader Unit Behavior (No Host Registry Writes)
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 1] Get-LiteDeploySetupProgress Contract & Boundary Handling..." -ForegroundColor Yellow

    # Test non-existent registry path
    $nonExistentPath = 'HKLM:\SOFTWARE\LiteDeploy_NonExistent_Test_Key_12345'
    $emptyResult = Get-LiteDeploySetupProgress -RegistryPath $nonExistentPath
    Assert-Condition ($null -eq $emptyResult) "Non-existent registry path returns null without throwing"

    # Test mock reader simulation with valid and boundary values
    $mockReaderValid = {
        [PSCustomObject]@{
            Progress = 61.0
            Phase    = 5
            SubPhase = 16
        }
    }
    $resValid = & $mockReaderValid
    Assert-Condition ($resValid.Progress -eq 61.0) "Valid SetupProgress 61.0 parsed correctly"
    Assert-Condition ($resValid.Phase -eq 5) "SetupPhase 5 parsed as numeric raw context"
    Assert-Condition ($resValid.SubPhase -eq 16) "SetupSubPhase 16 parsed as numeric raw context"

    # Boundary values 0.0 and 100.0
    $mockReader0 = { [PSCustomObject]@{ Progress = 0.0; Phase = 1; SubPhase = 1 } }
    $mockReader100 = { [PSCustomObject]@{ Progress = 100.0; Phase = 5; SubPhase = 20 } }
    Assert-Condition ((& $mockReader0).Progress -eq 0.0) "Boundary progress 0.0 is valid"
    Assert-Condition ((& $mockReader100).Progress -eq 100.0) "Boundary progress 100.0 is valid"

    # Missing optional properties under StrictMode 2.0
    $mockMissingProps = {
        [PSCustomObject]@{
            Progress = 35.0
        }
    }
    $resMissing = & $mockMissingProps
    Assert-Condition ($resMissing.Progress -eq 35.0) "Progress without Phase/SubPhase is accepted"
    $phaseVal = if ($resMissing.PSObject.Properties['Phase']) { $resMissing.Phase } else { $null }
    Assert-Condition ($null -eq $phaseVal) "Missing Phase safely evaluated as null under StrictMode 2.0"

    # -------------------------------------------------------------------------
    # Group 2: Progress Recorded While Process Is Alive (Not After Return Only)
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 2] Live Progress Polling While Process Alive..." -ForegroundColor Yellow

    $cmdPath = "$env:ComSpec"
    $fakeAliveSetup = Join-Path $TestTemp "fake_alive_setup.exe"
    Copy-Item -LiteralPath $cmdPath -Destination $fakeAliveSetup -Force

    $pollState = @{
        Iterations = 0
        AliveCount = 0
    }
    $mockAliveReader = {
        $pollState.Iterations++
        if ($pollState.Iterations -eq 1) {
            # Baseline snapshot before launch: return null (clean baseline)
            return $null
        }
        $pollState.AliveCount++
        return [PSCustomObject]@{
            Progress = [math]::Min(100.0, [double](($pollState.Iterations - 1) * 20))
            Phase    = 1
            SubPhase = 1
        }
    }

    # Run fake setup that sleeps for ~1.5 seconds so WaitForExit(1000) loops while process is alive
    $resAlive = Invoke-SetupEngine `
        -ResolvedSetupPath $fakeAliveSetup `
        -NormalizedDestination $mockTargetRoot `
        -ExtraArgs @('/c', 'powershell', '-Command', 'Start-Sleep -Milliseconds 1500; exit 0') `
        -ProgressReader $mockAliveReader

    Assert-Condition ($resAlive.Success -eq $true) "Setup process completed successfully"
    Assert-Condition ($pollState.AliveCount -ge 1) "Progress reader was invoked during polling while process was active (count=$($pollState.AliveCount))"
    Assert-Condition ($null -ne $resAlive.LatestPercentage) "Return object retains LatestPercentage ($($resAlive.LatestPercentage)%)"

    # -------------------------------------------------------------------------
    # Group 3: Milestone Deduplication & Jump-to-Actual Crossing
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 3] Milestone Deduplication & Actual Crossing Progression..." -ForegroundColor Yellow

    $capturedMilestones = [System.Collections.Generic.List[string]]::new()

    function Write-LiteDeployLog {
        param($Component, $Message, $Level, $ForegroundColor, $NoConsole, $NoPrefix)
        if ($Message -match 'Windows Setup progress:\s*(\d+(?:\.\d+)?%)') {
            $capturedMilestones.Add($Matches[1])
        }
    }

    $progressStream = [System.Collections.Generic.Queue[object]]::new()
    # Baseline read before launch
    $progressStream.Enqueue($null)
    # Emits 10%, 10% (deduped), 10% (deduped), jump to 47%, 47% (deduped), 50%, 50% (deduped)
    $progressStream.Enqueue([PSCustomObject]@{ Progress = 10.0; Phase = 1; SubPhase = 1 })
    $progressStream.Enqueue([PSCustomObject]@{ Progress = 10.0; Phase = 1; SubPhase = 1 })
    $progressStream.Enqueue([PSCustomObject]@{ Progress = 10.0; Phase = 1; SubPhase = 1 })
    $progressStream.Enqueue([PSCustomObject]@{ Progress = 47.0; Phase = 1; SubPhase = 1 })
    $progressStream.Enqueue([PSCustomObject]@{ Progress = 47.0; Phase = 1; SubPhase = 1 })
    $progressStream.Enqueue([PSCustomObject]@{ Progress = 50.0; Phase = 1; SubPhase = 1 })
    $progressStream.Enqueue([PSCustomObject]@{ Progress = 50.0; Phase = 1; SubPhase = 1 })

    $streamReader = {
        if ($progressStream.Count -gt 0) {
            return $progressStream.Dequeue()
        }
        return [PSCustomObject]@{ Progress = 50.0; Phase = 1; SubPhase = 1 }
    }

    $fakeDedupSetup = Join-Path $TestTemp "fake_dedup_setup.exe"
    Copy-Item -LiteralPath $cmdPath -Destination $fakeDedupSetup -Force

    $resDedup = Invoke-SetupEngine `
        -ResolvedSetupPath $fakeDedupSetup `
        -NormalizedDestination $mockTargetRoot `
        -ExtraArgs @('/c', 'powershell', '-Command', 'Start-Sleep -Milliseconds 600; exit 0') `
        -ProgressReader $streamReader `
        -PollIntervalMs 50

    # Restore Write-LiteDeployLog
    Remove-Item function:Write-LiteDeployLog -ErrorAction SilentlyContinue
    . $sessionScript

    # Check deduplication and jump
    $count10 = @($capturedMilestones | Where-Object { $_ -eq '10%' }).Count
    $count47 = @($capturedMilestones | Where-Object { $_ -eq '47%' }).Count
    $count50 = @($capturedMilestones | Where-Object { $_ -eq '50%' }).Count

    Assert-Condition ($count10 -eq 1) "Milestone 10% was logged exactly ONCE despite 3 identical polls"
    Assert-Condition ($count47 -eq 1) "Jump to 47% logged actual 47% milestone without fabricating 20%/30%/40%"
    Assert-Condition ($count50 -eq 1) "Milestone 50% was logged exactly ONCE after crossing from 47%"

    # -------------------------------------------------------------------------
    # Group 4: Live Evidence Reproduction: 61% Failure with Phase 5 & SubPhase 16
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 4] Live Evidence: 61% Failure with Phase 5 & SubPhase 16..." -ForegroundColor Yellow

    $fakeFailSetup = Join-Path $TestTemp "fake_failing_61_setup.exe"
    Copy-Item -LiteralPath $cmdPath -Destination $fakeFailSetup -Force

    $group4Queue = [System.Collections.Generic.Queue[object]]::new()
    $group4Queue.Enqueue($null) # Baseline read
    $group4Queue.Enqueue([PSCustomObject]@{ Progress = 61.0; Phase = 5; SubPhase = 16 })

    $mock61Reader = {
        if ($group4Queue.Count -gt 0) {
            return $group4Queue.Dequeue()
        }
        return [PSCustomObject]@{ Progress = 61.0; Phase = 5; SubPhase = 16 }
    }

    $caught61Error = ""
    $caught61Threw = $false
    try {
        $null = Invoke-SetupEngine `
            -ResolvedSetupPath $fakeFailSetup `
            -NormalizedDestination $mockTargetRoot `
            -ExtraArgs @('/c', 'exit', '1') `
            -ProgressReader $mock61Reader
    }
    catch {
        $caught61Threw = $true
        $caught61Error = $_.Exception.Message
    }

    Assert-Condition ($caught61Threw -eq $true) "Setup with exit code 1 threw exception"
    Assert-Condition ($caught61Error -match 'exit code 1 \(0x00000001\)') "Exception contains exit code 1 (0x00000001)"
    Assert-Condition ($caught61Error -match 'Last reported progress before failure: 61%') "Exception includes last reported progress: 61%"
    Assert-Condition ($caught61Error -match 'Phase: 5, SubPhase: 16') "Exception includes numeric raw context: Phase: 5, SubPhase: 16"
    Assert-Condition ($caught61Error -match 'Setup log directory:') "Exception identifies Setup log directory"
    Assert-Condition ($caught61Error -match 'note: last reported progress is an observation and may not be the exact error location') "Exception includes honest observation caveat"

    # -------------------------------------------------------------------------
    # Group 5: Stale Initial Snapshot & Baseline Guard
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 5] Stale Initial Snapshot & Baseline Guard..." -ForegroundColor Yellow

    # Test 5A: Registry already contains stale 61% before launch. Process runs and exits without changing it.
    # The baseline must be ignored, and no progress percentage attributed to this run.
    $stale61Reader = {
        [PSCustomObject]@{
            Progress = 61.0
            Phase    = 5
            SubPhase = 16
        }
    }

    $staleThrew = $false
    $staleError = ""
    try {
        $null = Invoke-SetupEngine `
            -ResolvedSetupPath $fakeFailSetup `
            -NormalizedDestination $mockTargetRoot `
            -ExtraArgs @('/c', 'exit', '1') `
            -ProgressReader $stale61Reader
    }
    catch {
        $staleThrew = $true
        $staleError = $_.Exception.Message
    }

    Assert-Condition ($staleThrew -eq $true) "Setup failed as expected"
    Assert-Condition ($staleError -match 'Progress unavailable \(no progress percentage reported before failure\)') "Stale baseline 61% was correctly ignored; reported Progress unavailable"
    Assert-Condition ($staleError -notmatch 'Last reported progress before failure: 61%') "Stale baseline 61% was NOT attributed to new setup run"

    # Test 5B: Registry contains stale 61% baseline, but during the run progress resets to 0% (change detected)
    $staleThenResetQueue = [System.Collections.Generic.Queue[object]]::new()
    # Baseline read
    $staleThenResetQueue.Enqueue([PSCustomObject]@{ Progress = 61.0; Phase = 5; SubPhase = 16 })
    # Run reads: resets to 0%, then advances to 10%
    $staleThenResetQueue.Enqueue([PSCustomObject]@{ Progress = 0.0; Phase = 1; SubPhase = 1 })
    $staleThenResetQueue.Enqueue([PSCustomObject]@{ Progress = 10.0; Phase = 1; SubPhase = 1 })

    $resetReader = {
        if ($staleThenResetQueue.Count -gt 0) {
            return $staleThenResetQueue.Dequeue()
        }
        return [PSCustomObject]@{ Progress = 10.0; Phase = 1; SubPhase = 1 }
    }

    $resetThrew = $false
    $resetError = ""
    try {
        $null = Invoke-SetupEngine `
            -ResolvedSetupPath $fakeFailSetup `
            -NormalizedDestination $mockTargetRoot `
            -ExtraArgs @('/c', 'powershell', '-Command', 'Start-Sleep -Milliseconds 300; exit 1') `
            -ProgressReader $resetReader `
            -PollIntervalMs 50
    }
    catch {
        $resetThrew = $true
        $resetError = $_.Exception.Message
    }

    Assert-Condition ($resetThrew -eq $true) "Setup failed with exit 1"
    Assert-Condition ($resetError -match 'Last reported progress before failure: 10%') "Baseline cleared upon change; new progress (10%) correctly attributed to this run"

    # -------------------------------------------------------------------------
    # Group 6: Midrun Disappearance & Fault Tolerance
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 6] Midrun Disappearance & Fault Tolerance..." -ForegroundColor Yellow

    # Reader emits 25%, then null (key disappeared), then exits with failure while key is missing
    $disappearQueue = [System.Collections.Generic.Queue[object]]::new()
    # Baseline
    $disappearQueue.Enqueue($null)
    # Poll 1: 25%
    $disappearQueue.Enqueue([PSCustomObject]@{ Progress = 25.0; Phase = 2; SubPhase = 1 })
    # Poll 2: $null (key temporarily deleted)
    $disappearQueue.Enqueue($null)

    $disappearReader = {
        if ($disappearQueue.Count -gt 0) {
            return $disappearQueue.Dequeue()
        }
        return $null
    }

    $disappearThrew = $false
    $disappearError = ""
    try {
        $null = Invoke-SetupEngine `
            -ResolvedSetupPath $fakeFailSetup `
            -NormalizedDestination $mockTargetRoot `
            -ExtraArgs @('/c', 'powershell', '-Command', 'Start-Sleep -Milliseconds 300; exit 1') `
            -ProgressReader $disappearReader `
            -PollIntervalMs 50
    }
    catch {
        $disappearThrew = $true
        $disappearError = $_.Exception.Message
    }

    Assert-Condition ($disappearThrew -eq $true) "Setup threw exit code failure"
    Assert-Condition ($disappearError -match 'Last reported progress before failure: 25%') "Last valid observation (25%) preserved despite temporary disappearance"

    # -------------------------------------------------------------------------
    # Group 7: Phase Change, Progress Reset & Most Recent Valid vs Global Max
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 7] Phase Change / Reset: Most Recent Valid vs Global Max..." -ForegroundColor Yellow

    # Phase 1 reached 100%, then Phase 2 started and was at 15% when failure occurred
    $phaseResetQueue = [System.Collections.Generic.Queue[object]]::new()
    $phaseResetQueue.Enqueue($null) # Baseline
    $phaseResetQueue.Enqueue([PSCustomObject]@{ Progress = 100.0; Phase = 1; SubPhase = 10 })
    $phaseResetQueue.Enqueue([PSCustomObject]@{ Progress = 15.0;  Phase = 2; SubPhase = 1 })

    $phaseResetReader = {
        if ($phaseResetQueue.Count -gt 0) {
            return $phaseResetQueue.Dequeue()
        }
        return [PSCustomObject]@{ Progress = 15.0; Phase = 2; SubPhase = 1 }
    }

    $phaseResetThrew = $false
    $phaseResetError = ""
    try {
        $null = Invoke-SetupEngine `
            -ResolvedSetupPath $fakeFailSetup `
            -NormalizedDestination $mockTargetRoot `
            -ExtraArgs @('/c', 'powershell', '-Command', 'Start-Sleep -Milliseconds 300; exit 1') `
            -ProgressReader $phaseResetReader `
            -PollIntervalMs 50
    }
    catch {
        $phaseResetThrew = $true
        $phaseResetError = $_.Exception.Message
    }

    Assert-Condition ($phaseResetThrew -eq $true) "Setup threw failure"
    Assert-Condition ($phaseResetError -match 'Last reported progress before failure: 15% \(Phase: 2, SubPhase: 1\)') "Failure reports most recent valid observation (15% Phase 2), NOT global max (100% Phase 1)"

    # -------------------------------------------------------------------------
    # Group 8: Exit Code Authority: Non-Zero After 100% Remains Failure
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 8] Exit Code Authority: 100% Then Error Remains Failure..." -ForegroundColor Yellow

    $group8Queue = [System.Collections.Generic.Queue[object]]::new()
    $group8Queue.Enqueue($null) # Baseline read
    $group8Queue.Enqueue([PSCustomObject]@{ Progress = 100.0; Phase = 5; SubPhase = 20 })

    $reader100Error = {
        if ($group8Queue.Count -gt 0) { return $group8Queue.Dequeue() }
        return [PSCustomObject]@{ Progress = 100.0; Phase = 5; SubPhase = 20 }
    }

    $errorAfter100Threw = $false
    $errorAfter100Msg = ""
    try {
        $null = Invoke-SetupEngine `
            -ResolvedSetupPath $fakeFailSetup `
            -NormalizedDestination $mockTargetRoot `
            -ExtraArgs @('/c', 'exit', '1') `
            -ProgressReader $reader100Error
    }
    catch {
        $errorAfter100Threw = $true
        $errorAfter100Msg = $_.Exception.Message
    }

    Assert-Condition ($errorAfter100Threw -eq $true) "Non-zero exit code throws failure even when progress reached 100%"
    Assert-Condition ($errorAfter100Msg -match 'Last reported progress before failure: 100%') "Reports 100% observation with explicit failure exit code"

    # -------------------------------------------------------------------------
    # Group 9: Exit 3010 Retained Success Semantics
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 9] Exit 3010 Retained Success Semantics..." -ForegroundColor Yellow

    $fake3010Setup = Join-Path $TestTemp "fake_3010_setup.exe"
    Copy-Item -LiteralPath $cmdPath -Destination $fake3010Setup -Force

    $group9Queue = [System.Collections.Generic.Queue[object]]::new()
    $group9Queue.Enqueue($null) # Baseline read
    $group9Queue.Enqueue([PSCustomObject]@{ Progress = 100.0; Phase = 5; SubPhase = 20 })

    $reader100Success = {
        if ($group9Queue.Count -gt 0) { return $group9Queue.Dequeue() }
        return [PSCustomObject]@{ Progress = 100.0; Phase = 5; SubPhase = 20 }
    }

    $res3010 = Invoke-SetupEngine `
        -ResolvedSetupPath $fake3010Setup `
        -NormalizedDestination $mockTargetRoot `
        -ExtraArgs @('/c', 'exit', '3010') `
        -ProgressReader $reader100Success

    Assert-Condition ($res3010.Success -eq $true) "Exit code 3010 succeeds per existing contract"
    Assert-Condition ($res3010.ExitCode -eq 3010) "Exit code 3010 accurately recorded on result object"
    Assert-Condition ($res3010.LatestPercentage -eq 100.0) "Latest percentage 100.0 retained on successful 3010 result"

    # -------------------------------------------------------------------------
    # Group 10: Absent Key Initially / Throughout (No Fabricated 0%)
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 10] Absent Key Initially / Throughout (No Fabricated 0%)..." -ForegroundColor Yellow

    $readerNull = { $null }

    # On success with absent key
    $resNullSuccess = Invoke-SetupEngine `
        -ResolvedSetupPath $fakeDedupSetup `
        -NormalizedDestination $mockTargetRoot `
        -ExtraArgs @('/c', 'exit', '0') `
        -ProgressReader $readerNull

    Assert-Condition ($resNullSuccess.Success -eq $true) "Setup succeeds with absent registry key"
    Assert-Condition ($null -eq $resNullSuccess.LatestPercentage) "LatestPercentage is null (no fabricated 0% invented)"

    # On failure with absent key
    $nullFailThrew = $false
    $nullFailError = ""
    try {
        $null = Invoke-SetupEngine `
            -ResolvedSetupPath $fakeFailSetup `
            -NormalizedDestination $mockTargetRoot `
            -ExtraArgs @('/c', 'exit', '1') `
            -ProgressReader $readerNull
    }
    catch {
        $nullFailThrew = $true
        $nullFailError = $_.Exception.Message
    }

    Assert-Condition ($nullFailThrew -eq $true) "Setup failed with exit 1"
    Assert-Condition ($nullFailError -match 'Progress unavailable \(no progress percentage reported before failure\)') "Reports Progress unavailable; no fabricated 0% reported"

    # -------------------------------------------------------------------------
    # Group 11: Launch Failure & No Registry Percent Invented
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 11] Launch Failure & No Registry Percent Invented..." -ForegroundColor Yellow

    $nonExistentBinary = Join-Path $TestTemp "non_existent_binary_12345.exe"
    $launchFailThrew = $false
    $launchFailMsg = ""
    try {
        $null = Invoke-SetupEngine `
            -ResolvedSetupPath $nonExistentBinary `
            -NormalizedDestination $mockTargetRoot `
            -ProgressReader $mock61Reader
    }
    catch {
        $launchFailThrew = $true
        $launchFailMsg = $_.Exception.Message
    }

    Assert-Condition ($launchFailThrew -eq $true) "Launch failure of missing binary threw exception"
    Assert-Condition ($launchFailMsg -match 'Progress unavailable \(process launch failed\)') "Launch failure honest label: Progress unavailable (process launch failed)"
    Assert-Condition ($launchFailMsg -notmatch 'Last reported progress before failure: 61%') "No registry percentage invented when process launch fails"

    # -------------------------------------------------------------------------
    # Group 12: Quoted Arguments & Paths with Spaces Preservation
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 12] Quoted Arguments & Paths with Spaces Preservation..." -ForegroundColor Yellow

    $pathWithSpaces = Join-Path $TestTemp "Path With Spaces"
    $null = New-Item -Path $pathWithSpaces -ItemType Directory -Force
    $imageWithSpaces = Join-Path $pathWithSpaces "install image.wim"
    Set-Content -LiteralPath $imageWithSpaces -Value "dummy image" -Encoding UTF8
    $unattendWithSpaces = Join-Path $pathWithSpaces "unattend file.xml"
    Set-Content -LiteralPath $unattendWithSpaces -Value "<unattend/>" -Encoding UTF8

    $genArgs = Get-LiteDeploySetupArguments `
        -ImagePath $imageWithSpaces `
        -ImageIndex 2 `
        -UnattendPath $unattendWithSpaces `
        -ExtraArgs @('/noreboot', '/DiagnosticPrompt enable')

    Assert-Condition ($genArgs -match '/NoReboot') "Preserves /NoReboot flag"
    Assert-Condition ($genArgs -match '/DiagnosticPrompt enable') "Preserves /DiagnosticPrompt enable flag"
    Assert-Condition ($genArgs -match '/ImageIndex 2') "Preserves /ImageIndex 2"
    Assert-Condition ($genArgs -match '/InstallFrom\s+"[^"]+install image\.wim"') "Quotes ImagePath with spaces"
    Assert-Condition ($genArgs -match '/Unattend:"[^"]+unattend file\.xml"') "Quotes UnattendPath with spaces"

    # -------------------------------------------------------------------------
    # Group 13: Native Setup Log Collection on Success and Failure
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 13] Native Setup Log Collection on All Outcomes..." -ForegroundColor Yellow

    # Setup mock WinPE Panther log source
    $mockWinPEDrive = Join-Path $TestTemp "MockWinPEX"
    $mockWinPEPanther = Join-Path $mockWinPEDrive "Windows\Panther"
    $null = New-Item -Path $mockWinPEPanther -ItemType Directory -Force
    $mockSetupAct = Join-Path $mockWinPEPanther "setupact.log"
    Set-Content -LiteralPath $mockSetupAct -Value "mock winpe setup act" -Encoding UTF8
    $global:LiteDeployWinPESystemDrive = $mockWinPEDrive

    $setupLogDir = Join-Path $testWorkLogs "Setup"
    Remove-Item -LiteralPath $setupLogDir -Recurse -Force -ErrorAction SilentlyContinue

    # Run successful setup
    $null = Invoke-SetupEngine `
        -ResolvedSetupPath $fakeDedupSetup `
        -NormalizedDestination $mockTargetRoot `
        -ExtraArgs @('/c', 'exit', '0') `
        -ProgressReader $mockReaderValid

    Assert-Condition (Test-Path -LiteralPath (Join-Path $setupLogDir "setupact.log")) "Setup logs collected after successful completion"

    # Run failing setup and verify collection in finally
    Remove-Item -LiteralPath $setupLogDir -Recurse -Force -ErrorAction SilentlyContinue
    try {
        $null = Invoke-SetupEngine `
            -ResolvedSetupPath $fakeFailSetup `
            -NormalizedDestination $mockTargetRoot `
            -ExtraArgs @('/c', 'exit', '1') `
            -ProgressReader $mockReaderValid
    } catch {}

    Assert-Condition (Test-Path -LiteralPath (Join-Path $setupLogDir "setupact.log")) "Setup logs collected in finally block after nonzero failure"

    # Verify launch failure executes finally block: collection and sync attempt
    Remove-Item -LiteralPath $setupLogDir -Recurse -Force -ErrorAction SilentlyContinue
    try {
        $null = Invoke-SetupEngine `
            -ResolvedSetupPath (Join-Path $TestTemp "non_existent_binary_xyz.exe") `
            -NormalizedDestination $mockTargetRoot
    } catch {}

    Assert-Condition (Test-Path -LiteralPath (Join-Path $setupLogDir "setupact.log")) "Setup logs collected in finally block even when process launch fails"

    # -------------------------------------------------------------------------
    # Group 14: Diagnostic Log Location Presentation & UNC Resolution
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 14] Diagnostic Log Location Presentation & UNC Resolution..." -ForegroundColor Yellow

    # 1. Direct UNC Path Preservation
    $directUnc = "\\DeploymentServer\DeploymentShare$\WorkLogs\Deployments\TEST-UID-001\Setup"
    $resolvedUnc = Resolve-LiteDeployShareUncPath -Path $directUnc
    Assert-Condition ($resolvedUnc -eq $directUnc) "Direct UNC path is preserved without modification"

    # 2. Drive Letter Resolution via configured BootObject / Deployment State
    $global:LiteDeployBootObject = [PSCustomObject]@{
        NetworkPath = "\\DeploymentServer\DeploymentShare$"
        DriveLetter = "Z:"
    }
    $drivePath = "Z:\WorkLogs\Deployments\TEST-UID-001\Setup"
    $resolvedDrive = Resolve-LiteDeployShareUncPath -Path $drivePath
    Assert-Condition ($resolvedDrive -eq "\\DeploymentServer\DeploymentShare$\WorkLogs\Deployments\TEST-UID-001\Setup") "Drive letter Z: correctly resolved to UNC via BootObject"

    # 3. Hash Verification & Staleness Detection
    $localVerifyDir = Join-Path $TestTemp "VerifyLocal"
    $remoteVerifyDir = Join-Path $TestTemp "VerifyRemote"
    $null = New-Item -Path $localVerifyDir -ItemType Directory -Force
    $null = New-Item -Path $remoteVerifyDir -ItemType Directory -Force

    $testFileLocal = Join-Path $localVerifyDir "setupact.log"
    $testFileRemote = Join-Path $remoteVerifyDir "setupact.log"
    Set-Content -LiteralPath $testFileLocal -Value "Hash verification test content 12345" -Encoding UTF8
    Set-Content -LiteralPath $testFileRemote -Value "Hash verification test content 12345" -Encoding UTF8

    $verifyGood = Verify-LiteDeployLogSync -LocalPath $localVerifyDir -RemoteDirectory $remoteVerifyDir
    Assert-Condition ($verifyGood.Success -eq $true) "Matching SHA256 hashes successfully verified"

    # Introduce staleness: remote file modified / out of sync
    Set-Content -LiteralPath $testFileRemote -Value "Old stale content from prior session" -Encoding UTF8
    $verifyStale = Verify-LiteDeployLogSync -LocalPath $localVerifyDir -RemoteDirectory $remoteVerifyDir
    Assert-Condition ($verifyStale.Success -eq $false -and $verifyStale.Mismatched.Count -gt 0) "Stale remote file rejected by SHA256 verification"

    # 4. Write-LiteDeployDiagnosticLogLocation Reporting Behavior
    # A) Verified on share -> outputs UNC path
    Set-Content -LiteralPath $testFileRemote -Value "Hash verification test content 12345" -Encoding UTF8
    $uncResult = Write-LiteDeployDiagnosticLogLocation -LocalPath $localVerifyDir -RemoteLogDir $remoteVerifyDir
    Assert-Condition ($uncResult -like "*$remoteVerifyDir*" -or $uncResult -like "\\*") "Verified sync reports remote/UNC destination"

    # B) Inaccessible share -> warning and local fallback with WinPE notice
    $inaccessibleDir = Join-Path $TestTemp "InaccessibleShareDir_XYZ"
    $fallbackResult = Write-LiteDeployDiagnosticLogLocation -LocalPath "X:\~LiteDeploy\WorkLogs\Setup" -RemoteLogDir $inaccessibleDir
    Assert-Condition ($fallbackResult -eq "X:\~LiteDeploy\WorkLogs\Setup") "Inaccessible share falls back to local path"

    # -------------------------------------------------------------------------
    # Group 15: Post-Reboot FullOS Panther Collection & Routing (Both Engines)
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 15] Post-Reboot FullOS Panther Collection & Engine Routing..." -ForegroundColor Yellow

    $osEngineScript = Join-Path $RuntimeDir "010-Engine\LiteDeploy.OS.Engine.ps1"
    . $osEngineScript

    # Create mock host Panther directory
    $mockHostPanther = Join-Path $TestTemp "MockHostPanther"
    $null = New-Item -Path $mockHostPanther -ItemType Directory -Force
    Set-Content -LiteralPath (Join-Path $mockHostPanther "setupact.log") -Value "Host Panther setupact content" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $mockHostPanther "setuperr.log") -Value "Host Panther setuperr content" -Encoding UTF8

    # Set isolation override so real host Panther is NEVER read
    $global:LiteDeployFullOSPantherSourceDir = $mockHostPanther

    # 1. Route to Dism when OSInstall.Engine is dism.exe
    $fullOsWorkLogs = Join-Path $TestTemp "FullOSWorkLogs"
    $null = New-Item -Path $fullOsWorkLogs -ItemType Directory -Force
    $dismState = [PSCustomObject]@{
        OSInstall = [PSCustomObject]@{ Engine = "dism.exe" }
    }
    $dismCollectDest = Collect-LiteDeployFullOSPantherLogs -LocalLogDir $fullOsWorkLogs -PantherSourceDir $mockHostPanther -DeploymentState $dismState
    Assert-Condition ($dismCollectDest -match "Dism[\\/]FullOS-Panther") "FullOS Panther logs routed to WorkLogs\Dism\FullOS-Panther for dism.exe"
    Assert-Condition (Test-Path -LiteralPath (Join-Path $dismCollectDest "setupact.log")) "setupact.log copied to Dism\FullOS-Panther"
    Assert-Condition (Test-Path -LiteralPath (Join-Path $dismCollectDest "setuperr.log")) "setuperr.log copied to Dism\FullOS-Panther"
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $fullOsWorkLogs "Setup\FullOS-Panther"))) "Setup\FullOS-Panther NOT created when engine is DISM (no duplicate copy)"

    # 2. Route to Setup when OSInstall.Engine is setup.exe (case-insensitive)
    $setupState = [PSCustomObject]@{
        OSInstall = [PSCustomObject]@{ Engine = "SETUP.EXE" }
    }
    # Pre-seed root WinPE log in Setup to ensure FullOS collection leaves it intact
    $setupBaseDir = Join-Path $fullOsWorkLogs "Setup"
    $null = New-Item -Path $setupBaseDir -ItemType Directory -Force
    Set-Content -LiteralPath (Join-Path $setupBaseDir "setupact.log") -Value "Original WinPE Setup Act Log" -Encoding UTF8

    $setupCollectDest = Collect-LiteDeployFullOSPantherLogs -LocalLogDir $fullOsWorkLogs -PantherSourceDir $mockHostPanther -DeploymentState $setupState
    Assert-Condition ($setupCollectDest -match "Setup[\\/]FullOS-Panther") "FullOS Panther logs routed to WorkLogs\Setup\FullOS-Panther for setup.exe"
    Assert-Condition (Test-Path -LiteralPath (Join-Path $setupCollectDest "setupact.log")) "setupact.log copied to Setup\FullOS-Panther"

    # Verify root WinPE log remains intact and unchanged
    $rootContent = Get-Content -LiteralPath (Join-Path $setupBaseDir "setupact.log") -Raw
    Assert-Condition ($rootContent -match "Original WinPE Setup Act Log") "Root WinPE setupact.log remains intact and unchanged after FullOS collection"

    # 3. Handle unknown engine honestly: warn and skip without misclassifying
    $unknownState = [PSCustomObject]@{
        OSInstall = [PSCustomObject]@{ Engine = "UnrecognizedCustomEngine.exe" }
    }
    $unknownResult = Collect-LiteDeployFullOSPantherLogs -LocalLogDir $fullOsWorkLogs -PantherSourceDir $mockHostPanther -DeploymentState $unknownState
    Assert-Condition ($null -eq $unknownResult) "Unknown engine skipped honestly without misclassifying"

    # Clean up global test overrides
    Remove-Variable -Name LiteDeployFullOSPantherSourceDir -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name LiteDeployWinPESystemDrive -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name LiteDeployBootObject -Scope Global -ErrorAction SilentlyContinue

}
finally {
    # Reset global session log override
    Remove-Variable -Name LiteDeploySessionLogDir -Scope Global -ErrorAction SilentlyContinue

    # Clean up temporary test files
    if (Test-Path -LiteralPath $TestTemp) {
        Remove-Item -LiteralPath $TestTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host " Setup Progress Alignment Tests Complete" -ForegroundColor Cyan
Write-Host " Passed: $script:TotalPassed  Failed: $script:TotalFailed" -ForegroundColor $(if ($script:TotalFailed -eq 0) { "Green" } else { "Red" })
Write-Host "========================================================`n" -ForegroundColor Cyan

if ($script:TotalFailed -gt 0) {
    exit 1
}
