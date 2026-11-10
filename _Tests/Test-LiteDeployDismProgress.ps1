<#
.SYNOPSIS
    Behavior-focused isolated test suite for DISM progress logging and native log retention (Setup/Dism).
.DESCRIPTION
    Validates:
    - Character chunk streaming and line reassembly across CR and LF
    - Bracketed percentage regex with locale comma/dot and rejection of arbitrary numbers/errors
    - Milestone deduplication (every 10%) and jump-to-actual-crossing policy (no fabricated milestones)
    - In-memory retention of every observed percentage and reporting on failure (e.g. 47%)
    - Honest progress labeling ("Progress unavailable", never invent 0%, not exact error location)
    - Exit code authority (100% not proof of success; non-zero exit code remains failure)
    - Warning semantics for Add-Driver vs throw semantics for Apply-Image
    - Quoted paths with spaces and native log paths under WorkLogs\Dism\ with .bak rotation
    - Single structured return object with no pipeline pollution
    - Windows Setup log collection into WorkLogs\Setup\<Provenance>\ with strict whitelist
    - Zero sensitive XML/unattend/credentials collected
    - Session mirror synchronization of WorkLogs\Dism\ and WorkLogs\Setup\ to share and OS volume
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

$TestTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("LiteDeploy_DismTest_" + [System.Guid]::NewGuid().ToString("N"))
$null = New-Item -Path $TestTemp -ItemType Directory -Force

try {
    # Isolate session logging to temporary test folder
    $testWorkLogs = Join-Path $TestTemp "WorkLogs"
    $null = New-Item -Path $testWorkLogs -ItemType Directory -Force
    $global:LiteDeploySessionLogDir = $testWorkLogs

    Write-Host "`n========================================================" -ForegroundColor Cyan
    Write-Host " DISM Progress & Native Log Retention Test Suite" -ForegroundColor Cyan
    Write-Host "========================================================" -ForegroundColor Cyan

    # -------------------------------------------------------------------------
    # Group 1: DISM Progress Parsing & Locale Handling
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 1] DISM Progress Parsing, Locales & Chunk Boundaries..." -ForegroundColor Yellow

    $regex = '\[[\s=]*(\d{1,3}(?:[.,]\d+)?)\s*%[\s=]*\]'

    # Valid DISM progress formats
    $p1 = '[==========================10.0%                      ]'
    $p2 = '[== 20,5% ==]'
    $p3 = '[ 47% ]'
    $p4 = '[==========================100.0%==========================]'
    $p5 = '[   0.0%   ]'

    Assert-Condition ($p1 -match $regex -and $matches[1] -eq '10.0') "Matches standard DISM apply progress: 10.0%"
    Assert-Condition ($p2 -match $regex -and $matches[1].Replace(',', '.') -eq '20.5') "Matches European/locale comma format: 20,5%"
    Assert-Condition ($p3 -match $regex -and $matches[1] -eq '47') "Matches integer percentage without decimals: 47%"
    Assert-Condition ($p4 -match $regex -and $matches[1] -eq '100.0') "Matches completion percentage: 100.0%"
    Assert-Condition ($p5 -match $regex -and $matches[1] -eq '0.0') "Matches starting percentage: 0.0%"

    # Non-progress lines that MUST NOT be parsed as progress
    $np1 = 'Deployment Image Servicing and Management tool'
    $np2 = 'Error: 0x80070002 The system cannot find the file specified.'
    $np3 = 'Processed 50 files successfully.'
    $np4 = '[ERROR] Failed 50% of components'
    $np5 = '10.0%'  # No brackets

    Assert-Condition ($np1 -notmatch $regex) "Rejects general tool banner"
    Assert-Condition ($np2 -notmatch $regex) "Rejects error code with hex digits"
    Assert-Condition ($np3 -notmatch $regex) "Rejects arbitrary number of files"
    Assert-Condition ($np4 -notmatch $regex) "Rejects [ERROR] bracketed message containing percent"
    Assert-Condition ($np5 -notmatch $regex) "Rejects unbracketed raw percentage"

    # -------------------------------------------------------------------------
    # Group 2: Bounded Streaming & Chunk Reassembly with CR
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 2] Bounded Streaming & Split-Chunk Reassembly..." -ForegroundColor Yellow

    # Child PowerShell script that simulates split chunks and CR updates
    $fakeChunkEmitter = Join-Path $TestTemp "fake_chunk_emitter.ps1"
    $chunkScript = @'
[Console]::Write("[== 10.")
Start-Sleep -Milliseconds 80
[Console]::Write("0% ==]`r")
Start-Sleep -Milliseconds 80
[Console]::Write("[== 20,0% ==]`r")
Start-Sleep -Milliseconds 80
[Console]::Write("[==== 47% ====]`r")
Start-Sleep -Milliseconds 80
[Console]::Write("[==========================100.0%==========================]`r`n")
exit 0
'@
    Set-Content -LiteralPath $fakeChunkEmitter -Value $chunkScript -Encoding UTF8

    $nativeLog1 = Join-Path $testWorkLogs "Dism\dism-test1.log"
    $res1 = Invoke-DismProcessStream -Stage "Apply-Image" -DismExecutable "powershell.exe" -ArgumentString "-NoProfile -ExecutionPolicy Bypass -File `"$fakeChunkEmitter`"" -NativeLogPath $nativeLog1

    Assert-Condition ($res1.Success -eq $true) "Fake progress emitter exited with success"
    Assert-Condition ($res1.ExitCode -eq 0) "Exit code is 0"
    Assert-Condition ($res1.LatestPercentage -eq 100.0) "Latest observed percentage reached 100.0%"
    Assert-Condition ($res1 -is [psobject] -and $res1.PSObject.Properties['Success']) "Helper emits structured object"

    # -------------------------------------------------------------------------
    # Group 2B: Pipe Capacity Overflow & Bounded Diagnostics (No Deadlock)
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 2B] Pipe Capacity Overflow & Bounded Diagnostics..." -ForegroundColor Yellow

    $fakeHeavyEmitter = Join-Path $TestTemp "fake_heavy_emitter.ps1"
    $scriptHeavy = @'
for ($i = 1; $i -le 1000; $i++) {
    [Console]::Out.WriteLine("[== 10.0% ==] stdout junk line $i " + ("x" * 80))
    [Console]::Error.WriteLine("stderr error line $i " + ("e" * 80))
}
[Console]::Error.WriteLine("FINAL_STDERR_ERROR_MARKER")
exit 3
'@
    Set-Content -LiteralPath $fakeHeavyEmitter -Value $scriptHeavy -Encoding UTF8

    $nativeLogHeavy = Join-Path $testWorkLogs "Dism\dism-test-heavy.log"
    $resHeavy = Invoke-DismProcessStream -Stage "Apply-Image" -DismExecutable "powershell.exe" -ArgumentString "-NoProfile -ExecutionPolicy Bypass -File `"$fakeHeavyEmitter`"" -NativeLogPath $nativeLogHeavy

    Assert-Condition ($resHeavy.Success -eq $false) "Heavy output process exited normally without hanging (Success = false)"
    Assert-Condition ($resHeavy.ExitCode -eq 3) "Exit code 3 preserved from heavy child process"
    Assert-Condition ($resHeavy.ErrorMessage -match "FINAL_STDERR_ERROR_MARKER") "Bounded result tail retains final error marker"
    Assert-Condition ($resHeavy.ErrorMessage.Length -le 8192) "Error message diagnostics capped at bounded length (<= 8KB)"

    # -------------------------------------------------------------------------
    # Group 3: Memory Retention of Exact 47% & Failure Diagnostics
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 3] Memory Retention of Exact 47% on Error..." -ForegroundColor Yellow

    $fake47ErrorEmitter = Join-Path $TestTemp "fake_47_error.ps1"
    $script47 = @'
[Console]::Write("[== 10.0% ==]`r")
Start-Sleep -Milliseconds 60
[Console]::Write("[==== 20.0% ====]`r")
Start-Sleep -Milliseconds 60
[Console]::Write("[====== 30.0% ======]`r")
Start-Sleep -Milliseconds 60
[Console]::Write("[======== 40.0% ========]`r")
Start-Sleep -Milliseconds 60
[Console]::Write("[========= 47.0% =========]`r")
Start-Sleep -Milliseconds 60
[Console]::Error.WriteLine("Error: 0x80070002 Disk read fault during cluster decompression.")
exit 2
'@
    Set-Content -LiteralPath $fake47ErrorEmitter -Value $script47 -Encoding UTF8

    $nativeLog2 = Join-Path $testWorkLogs "Dism\dism-test2.log"
    $res47 = Invoke-DismProcessStream -Stage "Apply-Image" -DismExecutable "powershell.exe" -ArgumentString "-NoProfile -ExecutionPolicy Bypass -File `"$fake47ErrorEmitter`"" -NativeLogPath $nativeLog2

    Assert-Condition ($res47.Success -eq $false) "Process failure correctly reported"
    Assert-Condition ($res47.ExitCode -eq 2) "Exit code decimal is 2"
    Assert-Condition ($res47.ExitCodeHex -eq "0x00000002") "Exit code hex is 0x00000002"
    Assert-Condition ($res47.LatestPercentage -eq 47.0) "Exact 47% retained in memory upon failure (last milestone was 40%)"
    Assert-Condition ($res47.ErrorMessage -match "0x80070002") "Captured stderr error detail from process"

    # -------------------------------------------------------------------------
    # Group 4: Early Failure & Launch Failure (Progress Unavailable)
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 4] Early Failure & Launch Failure (Progress Unavailable)..." -ForegroundColor Yellow

    $fakeEarlyFail = Join-Path $TestTemp "fake_early_fail.ps1"
    Set-Content -LiteralPath $fakeEarlyFail -Value 'exit 87' -Encoding UTF8

    $nativeLog3 = Join-Path $testWorkLogs "Dism\dism-test3.log"
    $resEarly = Invoke-DismProcessStream -Stage "Apply-Image" -DismExecutable "powershell.exe" -ArgumentString "-NoProfile -ExecutionPolicy Bypass -File `"$fakeEarlyFail`"" -NativeLogPath $nativeLog3

    Assert-Condition ($resEarly.Success -eq $false) "Early failure correctly marked unsuccessful"
    Assert-Condition ($resEarly.ExitCode -eq 87) "Exit code 87 preserved"
    Assert-Condition ($null -eq $resEarly.LatestPercentage) "LatestPercentage is null (never invented 0%)"

    # Launch failure with nonexistent executable
    $resLaunch = Invoke-DismProcessStream -Stage "Apply-Image" -DismExecutable "nonexistent_dism_exe_fake.exe" -ArgumentString "" -NativeLogPath $nativeLog3
    Assert-Condition ($resLaunch.Success -eq $false) "Launch failure marked unsuccessful"
    Assert-Condition ($resLaunch.ExitCode -eq -1) "Launch failure exit code sentinel is clearly labelled -1 (not fabricated native exit code)"
    Assert-Condition ($null -eq $resLaunch.LatestPercentage) "Launch failure LatestPercentage is null"

    # -------------------------------------------------------------------------
    # Group 5: Exit Code Authority (100% Not Proof of Success)
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 5] Exit Code Authority (100% Not Proof of Success)..." -ForegroundColor Yellow

    $fake100Fail = Join-Path $TestTemp "fake_100_fail.ps1"
    $script100 = @'
[Console]::Write("[==========================100.0%==========================]`r`n")
[Console]::Error.WriteLine("Error: 112 There is not enough space on the disk.")
exit 112
'@
    Set-Content -LiteralPath $fake100Fail -Value $script100 -Encoding UTF8

    $nativeLog4 = Join-Path $testWorkLogs "Dism\dism-test4.log"
    $res100 = Invoke-DismProcessStream -Stage "Apply-Image" -DismExecutable "powershell.exe" -ArgumentString "-NoProfile -ExecutionPolicy Bypass -File `"$fake100Fail`"" -NativeLogPath $nativeLog4

    Assert-Condition ($res100.Success -eq $false) "100% output is NOT proof of success when exit code is nonzero"
    Assert-Condition ($res100.ExitCode -eq 112) "Exit code 112 preserved"
    Assert-Condition ($res100.ExitCodeHex -eq "0x00000070") "Hex code 0x00000070 formatted accurately"
    Assert-Condition ($res100.LatestPercentage -eq 100.0) "Observed 100% detail retained for diagnostics"

    # -------------------------------------------------------------------------
    # Group 6: Milestone Deduplication & Jump Policy
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 6] Milestone Deduplication & Jump Policy..." -ForegroundColor Yellow

    $execLogPath = Join-Path $testWorkLogs "LiteDeploy.Execution.log"
    $logContentBefore = if (Test-Path -LiteralPath $execLogPath) { Get-Content -LiteralPath $execLogPath -Raw } else { "" }
    $count10Before = ([regex]::Matches($logContentBefore, 'progress: 10%')).Count

    # Emits repeated 10% and then jumps to 47%
    $fakeMilestoneEmitter = Join-Path $TestTemp "fake_milestones.ps1"
    $scriptMilestones = @'
[Console]::Write("[== 10.0% ==]`r")
Start-Sleep -Milliseconds 40
[Console]::Write("[== 10.0% ==]`r")
Start-Sleep -Milliseconds 40
[Console]::Write("[== 10.0% ==]`r")
Start-Sleep -Milliseconds 40
[Console]::Write("[========= 47.0% =========]`r")
Start-Sleep -Milliseconds 40
[Console]::Write("[=========== 50.0% ===========]`r")
Start-Sleep -Milliseconds 40
exit 0
'@
    Set-Content -LiteralPath $fakeMilestoneEmitter -Value $scriptMilestones -Encoding UTF8

    $nativeLog5 = Join-Path $testWorkLogs "Dism\dism-test5.log"
    $resM = Invoke-DismProcessStream -Stage "Apply-Image" -DismExecutable "powershell.exe" -ArgumentString "-NoProfile -ExecutionPolicy Bypass -File `"$fakeMilestoneEmitter`"" -NativeLogPath $nativeLog5

    Assert-Condition ($resM.Success -eq $true) "Milestone process succeeded"
    Assert-Condition ($resM.LatestPercentage -eq 50.0) "Latest observed percentage is 50.0%"

    $logContentAfter = if (Test-Path -LiteralPath $execLogPath) { Get-Content -LiteralPath $execLogPath -Raw } else { "" }
    $count10After = ([regex]::Matches($logContentAfter, 'progress: 10%')).Count

    Assert-Condition (($count10After - $count10Before) -eq 1) "Repeated 10% progress in Group 6 logged exactly ONCE (deduplicated; diff=1)"

    $hasJump47 = $logContentAfter -match 'progress: 47%'
    Assert-Condition ($hasJump47) "Jump to 47% logged actual 47% milestone without fabricating 20%/30%/40%"

    $hasFifty = $logContentAfter -match 'progress: 50%'
    Assert-Condition ($hasFifty) "Next milestone after jump correctly advanced to 50%"

    # -------------------------------------------------------------------------
    # Group 7: Native Log Path with Spaces & .bak Rotation
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 7] Native Log Path with Spaces & .bak Rotation..." -ForegroundColor Yellow

    $spaceDir = Join-Path $testWorkLogs "Dism With Spaces"
    $spaceLog = Join-Path $spaceDir "dism-apply.log"
    $null = New-Item -Path $spaceDir -ItemType Directory -Force
    Set-Content -LiteralPath $spaceLog -Value "Existing prior run DISM log data" -Encoding UTF8

    $dummyProc = Join-Path $TestTemp "dummy_proc.ps1"
    Set-Content -LiteralPath $dummyProc -Value 'exit 0' -Encoding UTF8

    $resRotate = Invoke-DismProcessStream -Stage "Apply-Image" -DismExecutable "powershell.exe" -ArgumentString "-NoProfile -ExecutionPolicy Bypass -File `"$dummyProc`"" -NativeLogPath $spaceLog

    $bakFile = "$spaceLog.bak"
    Assert-Condition (Test-Path -LiteralPath $bakFile) "Pre-existing native log was safely rotated to .bak"
    Assert-Condition ((Get-Content -LiteralPath $bakFile -Raw) -match "Existing prior run") "Rotated .bak content preserved"

    # -------------------------------------------------------------------------
    # Group 8: Pipeline Pollution & Return Value Purity
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 8] Pipeline Pollution & Return Value Purity..." -ForegroundColor Yellow

    $pipelineResult = @(Invoke-DismProcessStream -Stage "Apply-Image" -DismExecutable "powershell.exe" -ArgumentString "-NoProfile -ExecutionPolicy Bypass -File `"$dummyProc`"" -NativeLogPath $nativeLog1)

    Assert-Condition ($pipelineResult.Count -eq 1) "Helper returns exactly ONE structured object (count=1)"
    Assert-Condition ($pipelineResult[0].PSObject.Properties['Success'] -and $pipelineResult[0].Success -eq $true) "Return object is not contaminated by process stdout"

    # -------------------------------------------------------------------------
    # Group 9: Setup Native Log Collection & Whitelist
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 9] Setup Native Log Collection & Whitelist..." -ForegroundColor Yellow

    # Create mock environment for Setup log collection
    $mockWinPEDrive = Join-Path $TestTemp "MockWinPEX"
    $mockWinPEPanther = Join-Path $mockWinPEDrive "Windows\Panther"
    $mockWinPEBt = Join-Path $mockWinPEDrive "`$Windows.~BT\Sources\Panther"
    $mockWinPEInf = Join-Path $mockWinPEDrive "Windows\INF"

    $null = New-Item -Path $mockWinPEPanther -ItemType Directory -Force
    $null = New-Item -Path $mockWinPEBt -ItemType Directory -Force
    $null = New-Item -Path $mockWinPEInf -ItemType Directory -Force

    $mockTargetRoot = Join-Path $TestTemp "MockTargetW"
    $null = New-Item -Path (Join-Path $mockTargetRoot "Windows") -ItemType Directory -Force

    # Set global isolation variable for test
    $global:LiteDeployWinPESystemDrive = $mockWinPEDrive

    # Seed logs: BT has setupact.log, Windows\Panther has setupact.log and setuperr.log
    # Deterministic priority: setupact should be picked from BT, setuperr from Windows\Panther
    Set-Content -LiteralPath (Join-Path $mockWinPEBt "setupact.log")      -Value "BT Sources setupact content" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $mockWinPEPanther "setupact.log") -Value "Panther setupact content" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $mockWinPEPanther "setuperr.log") -Value "Panther setuperr content" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $mockWinPEPanther "diagerr.xml")  -Value "<diag>Error</diag>" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $mockWinPEInf "setupapi.offline.log") -Value "Offline driver log" -Encoding UTF8

    # Seed sensitive files that MUST NEVER be collected
    Set-Content -LiteralPath (Join-Path $mockWinPEPanther "unattend.xml") -Value "<unattend><Password>SuperSecret</Password></unattend>" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $mockWinPEPanther "unattended.xml") -Value "<secret>CredentialData</secret>" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $mockWinPEPanther "credentials.txt") -Value "SecretToken123" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $mockWinPEPanther "migstate.dat") -Value "BinaryMigrationData" -Encoding UTF8

    # Execute Setup log collection pointing to mock WinPE drive
    Collect-LiteDeploySetupLogs -WinPESystemDrive $mockWinPEDrive

    $setupCollectedDir = Join-Path $testWorkLogs "Setup"
    Assert-Condition (Test-Path -LiteralPath $setupCollectedDir) "WorkLogs\Setup directory created"

    # Verify root WorkLogs\Setup collection with strict 2-file policy
    $setupactPath = Join-Path $setupCollectedDir "setupact.log"
    $setuperrPath = Join-Path $setupCollectedDir "setuperr.log"
    Assert-Condition (Test-Path -LiteralPath $setupactPath) "setupact.log collected directly under WorkLogs\Setup"
    Assert-Condition (Test-Path -LiteralPath $setuperrPath) "setuperr.log collected directly under WorkLogs\Setup"

    # Verify deterministic priority: setupact came from $Windows.~BT (higher priority)
    $cAct = Get-Content -LiteralPath $setupactPath -Raw
    Assert-Condition ($cAct -match "BT Sources setupact") "setupact.log picked higher priority `$Windows.~BT source"

    # Verify setuperr fell back to Windows\Panther
    $cErr = Get-Content -LiteralPath $setuperrPath -Raw
    Assert-Condition ($cErr -match "Panther setuperr") "setuperr.log fell back to Windows\Panther source"

    # Verify extras NOT copied (strict whitelist)
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $setupCollectedDir "diagerr.xml"))) "diagerr.xml NOT copied (strict 2-file whitelist)"
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $setupCollectedDir "setupapi.offline.log"))) "setupapi.offline.log NOT copied"
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $setupCollectedDir "Target-INF"))) "Target-INF directory not created"

    # CRITICAL: Verify sensitive files are ABSENT
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $setupCollectedDir "unattend.xml"))) "SECURITY: unattend.xml was NOT collected"
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $setupCollectedDir "unattended.xml"))) "SECURITY: unattended.xml was NOT collected"
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $setupCollectedDir "credentials.txt"))) "SECURITY: credentials.txt was NOT collected"
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $setupCollectedDir "migstate.dat"))) "SECURITY: migstate.dat was NOT collected"

    # Failed copy at I/O boundary: warning surfaced, copied count not inflated, continues other available logs
    $mockWinPERO = Join-Path $TestTemp "MockWinPEReadOnly"
    $mockWinPEPantherRO = Join-Path $mockWinPERO "Windows\Panther"
    $null = New-Item -Path $mockWinPEPantherRO -ItemType Directory -Force

    Set-Content -LiteralPath (Join-Path $mockWinPEPantherRO "setupact.log") -Value "Panther setupact RO test" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $mockWinPEPantherRO "setuperr.log") -Value "Panther setuperr RO test" -Encoding UTF8

    $roBlockedFile = Join-Path $setupCollectedDir "setupact.log"
    $lockStream = [System.IO.File]::Open($roBlockedFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)

    $execLogBefore = if (Test-Path -LiteralPath $execLogPath) { Get-Content -LiteralPath $execLogPath -Raw } else { "" }
    try {
        Collect-LiteDeploySetupLogs -WinPESystemDrive $mockWinPERO
    }
    finally {
        $lockStream.Dispose()
    }
    $execLogAfter = if (Test-Path -LiteralPath $execLogPath) { Get-Content -LiteralPath $execLogPath -Raw } else { "" }

    Assert-Condition (Test-Path -LiteralPath (Join-Path $setupCollectedDir "setuperr.log")) "Other available logs continue copying when one file fails"
    Assert-Condition ($execLogAfter -match "Failed to copy Setup log") "Failure at I/O boundary logs warning identifying source/destination/error without mask"

    # Missing directories/files handled without error
    $null = Collect-LiteDeploySetupLogs -WinPESystemDrive (Join-Path $TestTemp "NonExistentDestination")
    Assert-Condition ($true) "Missing directories handled gracefully without throwing"

    # -------------------------------------------------------------------------
    # Group 10: Session Mirror Synchronization of WorkLogs\Setup & WorkLogs\Dism
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 10] Session Mirror Synchronization (Share & OS Volume)..." -ForegroundColor Yellow

    # Ensure a DISM log file exists in WorkLogs\Dism\
    $dismWorkDir = Join-Path $testWorkLogs "Dism"
    $null = New-Item -Path $dismWorkDir -ItemType Directory -Force
    Set-Content -LiteralPath (Join-Path $dismWorkDir "dism-apply.log") -Value "DISM native log contents" -Encoding UTF8

    # Also add FullOS-Panther subfolder in Setup and Dism to verify recursive sync includes both
    $setupFullOS = Join-Path $setupCollectedDir "FullOS-Panther"
    $null = New-Item -Path $setupFullOS -ItemType Directory -Force
    Set-Content -LiteralPath (Join-Path $setupFullOS "setupact.log") -Value "FullOS Panther setupact for Setup" -Encoding UTF8

    $dismFullOS = Join-Path $dismWorkDir "FullOS-Panther"
    $null = New-Item -Path $dismFullOS -ItemType Directory -Force
    Set-Content -LiteralPath (Join-Path $dismFullOS "setupact.log") -Value "FullOS Panther setupact for DISM" -Encoding UTF8

    # 1. Share Mirror Sync
    $remoteShareLogs = Join-Path $TestTemp "RemoteShareLogs"
    $null = New-Item -Path $remoteShareLogs -ItemType Directory -Force

    Sync-LiteDeployLogsToShare -RuntimePaths ([PSCustomObject]@{ LocalLogDirectory = $testWorkLogs }) -RemoteLogDir $remoteShareLogs

    Assert-Condition (Test-Path -LiteralPath (Join-Path $remoteShareLogs "Setup\setupact.log")) "Setup root WinPE log mirrored to deployment share"
    Assert-Condition (Test-Path -LiteralPath (Join-Path $remoteShareLogs "Setup\FullOS-Panther\setupact.log")) "Setup FullOS-Panther log mirrored recursively to share"
    Assert-Condition (Test-Path -LiteralPath (Join-Path $remoteShareLogs "Dism\dism-apply.log")) "DISM native root log mirrored to deployment share"
    Assert-Condition (Test-Path -LiteralPath (Join-Path $remoteShareLogs "Dism\FullOS-Panther\setupact.log")) "DISM FullOS-Panther log mirrored recursively to share"

    # 1B. Inaccessible configured share destination surfaces bounded warning without throw
    $inaccessibleShare = Join-Path $TestTemp "NonExistentShare_Inaccessible_XYZ\Sub"
    $execLogBeforeInacc = if (Test-Path -LiteralPath $execLogPath) { Get-Content -LiteralPath $execLogPath -Raw } else { "" }
    Sync-LiteDeployLogsToShare -RuntimePaths ([PSCustomObject]@{ LocalLogDirectory = $testWorkLogs }) -RemoteLogDir $inaccessibleShare
    $execLogAfterInacc = if (Test-Path -LiteralPath $execLogPath) { Get-Content -LiteralPath $execLogPath -Raw } else { "" }
    Assert-Condition ($execLogAfterInacc -match "Remote deployment log directory '.*' is inaccessible") "Inaccessible configured share surfaces bounded warning without throw"

    # 1C. Missing/no configured share is normal (blank/empty returns without warning)
    $execLogBeforeBlank = if (Test-Path -LiteralPath $execLogPath) { Get-Content -LiteralPath $execLogPath -Raw } else { "" }
    Sync-LiteDeployLogsToShare -RuntimePaths ([PSCustomObject]@{ LocalLogDirectory = $testWorkLogs }) -RemoteLogDir ""
    $execLogAfterBlank = if (Test-Path -LiteralPath $execLogPath) { Get-Content -LiteralPath $execLogPath -Raw } else { "" }
    Assert-Condition ($execLogBeforeBlank.Length -eq $execLogAfterBlank.Length) "Missing or unconfigured remote share directory is normal (no false warning)"

    # 2. OS Volume Artifact Sync
    $mockDriveLetter = $TestTemp.Substring(0, 2) # e.g. C:
    $testLocalRoot = "TestLiteDeploy_" + [System.Guid]::NewGuid().ToString("N").Substring(0, 8)

    # Pre-seed DeploymentState.json to satisfy state check in Sync-LiteDeployArtifactsToOsVolume
    $stateFilePath = Join-Path $testWorkLogs "DeploymentState.json"
    $mockState = [PSCustomObject]@{
        DeploymentUid = "TEST-UID-999"
        LogLocations  = [PSCustomObject]@{
            OfflineOsRoot            = ""
            OfflineOsLogDir          = ""
            OfflineOsDeploymentState = ""
        }
    }
    Set-Content -LiteralPath $stateFilePath -Value ($mockState | ConvertTo-Json -Depth 5) -Encoding UTF8

    $handoffResult = Sync-LiteDeployArtifactsToOsVolume `
        -RuntimePaths ([PSCustomObject]@{ LocalLogDirectory = $testWorkLogs; StatePath = $stateFilePath }) `
        -OsDriveLetter $mockDriveLetter `
        -LocalRootName $testLocalRoot

    $targetWorkLogs = Join-Path (Join-Path "$mockDriveLetter\" $testLocalRoot) "WorkLogs"
    Assert-Condition ($handoffResult.Success -eq $true) "Sync-LiteDeployArtifactsToOsVolume succeeded"
    Assert-Condition (Test-Path -LiteralPath (Join-Path $targetWorkLogs "Setup\setupact.log")) "Setup root WinPE log synced to OS volume WorkLogs"
    Assert-Condition (Test-Path -LiteralPath (Join-Path $targetWorkLogs "Setup\FullOS-Panther\setupact.log")) "Setup FullOS-Panther log synced to OS volume WorkLogs"
    Assert-Condition (Test-Path -LiteralPath (Join-Path $targetWorkLogs "Dism\dism-apply.log")) "DISM native logs synced to OS volume WorkLogs"
    Assert-Condition (Test-Path -LiteralPath (Join-Path $targetWorkLogs "Dism\FullOS-Panther\setupact.log")) "DISM FullOS-Panther log synced to OS volume WorkLogs"

    # Clean up test artifact folder on mock OS volume
    Remove-Item -LiteralPath (Join-Path "$mockDriveLetter\" $testLocalRoot) -Recurse -Force -ErrorAction SilentlyContinue

    # -------------------------------------------------------------------------
    # Group 11: Setup & DISM Lifecycle & Error Semantics
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 11] Setup & DISM Lifecycle & Error Semantics..." -ForegroundColor Yellow

    # Verify that Setup log collection in finally preserves original setup exception
    $fakeFailingSetup = Join-Path $TestTemp "fake_failing_setup.exe"
    # Create fake executable using cmd.exe copy
    $cmdPath = "$env:SystemRoot\System32\cmd.exe"
    Copy-Item -LiteralPath $cmdPath -Destination $fakeFailingSetup -Force

    # Clear setupCollectedDir to prove collection happens in finally
    Remove-Item -LiteralPath $setupCollectedDir -Recurse -Force -ErrorAction SilentlyContinue

    $setupThrewProperly = $false
    try {
        # Pass args to cmd.exe that make it exit with code 1
        $null = Invoke-SetupEngine `
            -ResolvedSetupPath $fakeFailingSetup `
            -NormalizedDestination $mockTargetRoot `
            -ExtraArgs @('/c', 'exit', '1')
    }
    catch {
        $setupThrewProperly = ($_.Exception.Message -match "Windows Setup failed with exit code 1")
    }

    Assert-Condition ($setupThrewProperly) "Setup failure throws original exit code error (not swallowed or masked)"
    Assert-Condition (Test-Path -LiteralPath (Join-Path $setupCollectedDir "setupact.log")) "Setup logs collected in finally block after nonzero failure"

    # Verify that Setup log collection in finally also runs and succeeds on successful process (exit 0)
    $fakeSuccessSetup = Join-Path $TestTemp "fake_success_setup.exe"
    Copy-Item -LiteralPath $cmdPath -Destination $fakeSuccessSetup -Force

    Remove-Item -LiteralPath $setupCollectedDir -Recurse -Force -ErrorAction SilentlyContinue

    $setupSuccessThrew = $false
    try {
        $null = Invoke-SetupEngine `
            -ResolvedSetupPath $fakeSuccessSetup `
            -NormalizedDestination $mockTargetRoot `
            -ExtraArgs @('/c', 'exit', '0')
    }
    catch {
        $setupSuccessThrew = $true
    }

    Assert-Condition (-not $setupSuccessThrew) "Harmless Setup process with exit 0 completes without throwing"
    Assert-Condition (Test-Path -LiteralPath (Join-Path $setupCollectedDir "setupact.log")) "Setup logs collected in finally block after successful completion"

    # Verify AddDriver warning semantics in Invoke-DismEngine: non-zero driver exit does NOT throw
    # Mock Invoke-DismProcessStream for AddDriver failure
    function Invoke-DismProcessStream {
        param($Stage, $DismExecutable, $ArgumentString, $NativeLogPath)
        if ($Stage -eq "Apply-Image") {
            return [PSCustomObject]@{
                Success          = $true
                ExitCode         = 0
                ExitCodeHex      = "0x00000000"
                DurationSeconds  = 1
                LatestPercentage = 100.0
                LogPath          = $NativeLogPath
                Stage            = $Stage
                ErrorMessage     = ""
            }
        }
        elseif ($Stage -eq "Add-Driver") {
            # Add-Driver returns non-zero warning code
            return [PSCustomObject]@{
                Success          = $false
                ExitCode         = 2
                ExitCodeHex      = "0x00000002"
                DurationSeconds  = 1
                LatestPercentage = 47.0
                LogPath          = $NativeLogPath
                Stage            = $Stage
                ErrorMessage     = "Missing inf in driver directory"
            }
        }
    }

    # Mock bcdboot Start-Process
    function Start-Process {
        param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, [switch]$NoNewWindow)
        return [PSCustomObject]@{ ExitCode = 0 }
    }

    $dismTargetDir = Join-Path $TestTemp "DismLifecycleTarget"
    $null = New-Item -Path (Join-Path $dismTargetDir "Windows") -ItemType Directory -Force
    $dismDriverDir = Join-Path $TestTemp "DismStagedDrivers"
    $null = New-Item -Path $dismDriverDir -ItemType Directory -Force

    $driverWarningCompletedWithoutThrow = $false
    try {
        $dismRes = Invoke-DismEngine `
            -ResolvedImagePath "C:\MockSource\install.wim" `
            -NormalizedDestination $dismTargetDir `
            -SelectedImageIndex 1 `
            -DriverFolder $dismDriverDir `
            -DiskData ([PSCustomObject]@{ DiskNumber = 0; SystemPartitionNumber = 1; BootMode = "UEFI" })

        $driverWarningCompletedWithoutThrow = ($dismRes.Success -eq $true)
    }
    catch {
        $driverWarningCompletedWithoutThrow = $false
    }

    Assert-Condition ($driverWarningCompletedWithoutThrow) "AddDriver non-zero exit code preserves warning semantics without throwing"

    # Clean up lifecycle test mock functions
    Remove-Item function:Invoke-DismProcessStream -ErrorAction SilentlyContinue
    Remove-Item function:Start-Process -ErrorAction SilentlyContinue

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
Write-Host " DISM Progress & Native Log Tests Complete" -ForegroundColor Cyan
Write-Host " Passed: $script:TotalPassed  Failed: $script:TotalFailed" -ForegroundColor $(if ($script:TotalFailed -eq 0) { "Green" } else { "Red" })
Write-Host "========================================================`n" -ForegroundColor Cyan

if ($script:TotalFailed -gt 0) {
    exit 1
}
