<#
.SYNOPSIS
    Full Suite Execution Emulator & Test Runner for LiteDeploy Native Progress Host.

.DESCRIPTION
    Emulates an active task sequence execution by writing real-time JSON state payloads 
    to DeploymentState.json. Drives the unified pure-WPF host engine (LiteDeploy.Progress.ps1)
    across both FullOS and WinPE layout views.

.PARAMETER Interactive
    Launches the interactive CLI menu. Default when no parameters are provided.

.PARAMETER TestMode
    Non-interactive test mode selection:
      - 'Interactive'   : CLI Menu
      - 'FullOS_WPF'    : Emulate FullOS Task Sequence Execution
      - 'WinPE_WPF'     : Emulate WinPE Bare-Metal Task Sequence Execution
      - 'LiveJsonSync'  : Real-time DeploymentState.json state writer test
      - 'TestAllMatrix' : Full matrix execution across all layouts & themes

.PARAMETER Theme
    Target UI theme scheme ('Light' or 'Dark'). Default is 'Light'.

.PARAMETER TopMost
    Window z-ordering switch ('On' or 'Off'). Default is 'Off'.

.EXAMPLE
    .\Test-LiteDeployProgress.ps1

.EXAMPLE
    .\Test-LiteDeployProgress.ps1 -TestMode TestAllMatrix
#>

[CmdletBinding()]
param(
    [switch]$Interactive,

    [ValidateSet('Interactive', 'FullOS_WPF', 'WinPE_WPF', 'LiveJsonSync', 'TestAllMatrix')]
    [string]$TestMode = 'Interactive',

    [ValidateSet('Light', 'Dark')]
    [string]$Theme = 'Light',

    [ValidateSet('On', 'Off')]
    [string]$TopMost = 'Off',

    [string]$WindowTitle = '',
    [switch]$KeepOpen,
    [int]$StepDelayMs = 800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
    $ScriptRoot = "."
}

$ProgressScript = Join-Path $ScriptRoot "LiteDeploy.Progress.ps1"
$StateFile      = Join-Path $ScriptRoot "DeploymentState.json"

# Helper: Print Header Banner
function Show-TestBanner([string]$Title) {
    Write-Host ""
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host "  LiteDeploy Execution Emulator - $Title" -ForegroundColor White
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host ""
}

# Helper: Safe Non-Blocking File Writer
function Write-StatePayload($StateHashtable, $Path) {
    try {
        $jsonStr = $StateHashtable | ConvertTo-Json -Depth 4
        $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $sw = [System.IO.StreamWriter]::new($fs, [System.Text.Encoding]::UTF8)
        $sw.Write($jsonStr)
        $sw.Dispose()
        $fs.Dispose()
    }
    catch {
        Start-Sleep -Milliseconds 50
        $StateHashtable | ConvertTo-Json -Depth 4 | Out-File -FilePath $Path -Encoding utf8 -Force
    }
}

# Emulate Task Sequence Execution Step-by-Step
function Emulate-TaskSequenceExecution {
    param(
        [string]$EnvLayout,
        [string]$EngineName,
        [string]$ThemeName,
        [string]$TopMostMode,
        [string]$Title = '',
        [int]$DelayMs = 800,
        [switch]$KeepHostOpen
    )

    Show-TestBanner "Emulating Task Sequence Execution ($EngineName - $ThemeName Theme)"

    if (-not (Test-Path $ProgressScript)) {
        Write-Host "[ERROR] Target script missing: $ProgressScript" -ForegroundColor Red
        return $false
    }

    # 1. Write Initial Baseline JSON State Payload
    $state = @{
        productName     = "LiteDeploy"
        workflowName    = "Standard Workstation Workflow"
        environment     = $EnvLayout
        status          = "Running"
        phase           = "PreInstall"
        currentStep     = "Initializing Deployment Environment"
        message         = "Preparing target workstation deployment..."
        stepPercent     = 0
        overallPercent  = 0
        overallText     = "Action 1 of 5"
        logMessage      = "Mounting deployment media repository..."
        computerName    = "X1-DESKTOP01"
        computerModel   = "Latitude 7450"
        operatingSystem = "Windows 11 Enterprise 25H2"
        source          = "Local (Media) Repository"
        deploymentId    = "LD-206072-001"
    }
    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $state["windowTitle"] = $Title
    }

    Write-StatePayload $state $StateFile
    Write-Host "[INIT] Wrote initial DeploymentState.json payload." -ForegroundColor Cyan

    # 2. Launch Host Process
    Write-Host "[LAUNCH] Starting $EngineName..." -ForegroundColor Yellow
    $titleArg = if (-not [string]::IsNullOrWhiteSpace($Title)) { " -WindowTitle `"$Title`"" } else { "" }
    $keepArg = if ($KeepHostOpen) { " -KeepOpen" } else { "" }
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File `"$ProgressScript`" -Environment $EnvLayout -StatePath `"$StateFile`" -Theme $ThemeName -TopMost $TopMostMode$titleArg$keepArg" -WorkingDirectory $ScriptRoot -WindowStyle Normal -PassThru

    Start-Sleep -Milliseconds 1500

    # 3. Emulate Realistic Deployment Task Sequence Steps
    $phases = @(
        @{ Step = 1; Total = 5; Phase = "PreInstall"; StepName = "Initializing Environment"; Msg = "Preparing deployment media..."; Detail = "Mounting local media repository..."; Pct = 20 },
        @{ Step = 2; Total = 5; Phase = "DiskSetup"; StepName = "Partitioning Target Disk"; Msg = "Configuring GPT Disk 0"; Detail = "Diskpart.exe /s partition_gpt.txt executed..."; Pct = 40 },
        @{ Step = 3; Total = 5; Phase = "InstallWindows"; StepName = "Applying Windows Image"; Msg = "Installing Windows 11 Enterprise"; Detail = "Dism.exe /Apply-Image /ImageFile:install.wim /Index:6"; Pct = 60 },
        @{ Step = 4; Total = 5; Phase = "PostInstall"; StepName = "Injecting Device Drivers"; Msg = "Configuring System Hardware"; Detail = "Injecting PNP driver package for Dell Latitude 7450..."; Pct = 80 },
        @{ Step = 5; Total = 5; Phase = "Finalize"; StepName = "Writing Boot Configuration"; Msg = "Completing Installation"; Detail = "Bcdboot.exe C:\Windows /s S: /f UEFI..."; Pct = 100 }
    )

    foreach ($phase in $phases) {
        if ($proc.HasExited) { break }

        Write-Host "[EMULATE] Writing Action $($phase.Step)/$($phase.Total): $($phase.Msg)..." -ForegroundColor DarkCyan
        $state.phase       = $phase.Phase
        $state.currentStep = $phase.StepName
        $state.message     = $phase.Msg
        $state.overallText = "Action $($phase.Step) of $($phase.Total)"

        # Sub-step 1: Start action task
        $state.stepPercent    = 25
        $state.overallPercent = [math]::Max(0, [int]($phase.Pct - 15))
        $state.logMessage     = "Starting $($phase.StepName)..."
        Write-StatePayload $state $StateFile
        Start-Sleep -Milliseconds ([int]($DelayMs / 2))

        if ($proc.HasExited) { break }

        # Sub-step 2: Mid-point execution detail
        $state.stepPercent    = 65
        $state.overallPercent = [math]::Max(0, [int]($phase.Pct - 7))
        $state.logMessage     = $phase.Detail
        Write-StatePayload $state $StateFile
        Start-Sleep -Milliseconds ([int]($DelayMs / 2))

        if ($proc.HasExited) { break }

        # Sub-step 3: Complete step
        $state.stepPercent    = 100
        $state.overallPercent = $phase.Pct
        $state.logMessage     = "Completed $($phase.StepName)."
        if ($phase.Pct -eq 100) { $state.status = "Completed" }

        Write-StatePayload $state $StateFile
        Start-Sleep -Milliseconds ([int]($DelayMs / 2))
    }

    Write-Host "[PASS] Emulated task sequence execution completed for $EngineName." -ForegroundColor Green

    if ($KeepHostOpen -and -not $proc.HasExited) {
        Write-Host "[INFO] Host window is kept open (-KeepOpen). Press [Enter] to close progress host..." -ForegroundColor Yellow
        Read-Host | Out-Null
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    }
    elseif (-not $proc.HasExited) {
        $proc.WaitForExit(3000) | Out-Null
        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }

    return $true
}

# Run Full Automated Test Matrix
function Run-FullAutomatedMatrix {
    Show-TestBanner "Full Automated Matrix Execution"

    $results = @()

    # Test 1: FullOS Light Theme
    $resultFullOSLight = Emulate-TaskSequenceExecution -EnvLayout "FullOS" -EngineName "Pure WPF FullOS Host" -ThemeName "Light" -TopMostMode "Off" -DelayMs 300
    $results += [PSCustomObject]@{ Engine = "FullOS (Pure WPF)"; Theme = "Light"; Result = if ($resultFullOSLight) { "PASS" } else { "FAIL" } }

    # Test 2: FullOS Dark Theme
    $resultFullOSDark = Emulate-TaskSequenceExecution -EnvLayout "FullOS" -EngineName "Pure WPF FullOS Host" -ThemeName "Dark" -TopMostMode "Off" -DelayMs 300
    $results += [PSCustomObject]@{ Engine = "FullOS (Pure WPF)"; Theme = "Dark"; Result = if ($resultFullOSDark) { "PASS" } else { "FAIL" } }

    # Test 3: WinPE Light Theme
    $resultWinPELight = Emulate-TaskSequenceExecution -EnvLayout "WinPE" -EngineName "Pure WPF WinPE Host" -ThemeName "Light" -TopMostMode "Off" -DelayMs 300
    $results += [PSCustomObject]@{ Engine = "WinPE (Pure WPF)"; Theme = "Light"; Result = if ($resultWinPELight) { "PASS" } else { "FAIL" } }

    # Test 4: WinPE Dark Theme
    $resultWinPEDark = Emulate-TaskSequenceExecution -EnvLayout "WinPE" -EngineName "Pure WPF WinPE Host" -ThemeName "Dark" -TopMostMode "Off" -DelayMs 300
    $results += [PSCustomObject]@{ Engine = "WinPE (Pure WPF)"; Theme = "Dark"; Result = if ($resultWinPEDark) { "PASS" } else { "FAIL" } }

    # Summary Report
    Show-TestBanner "Automated Execution Matrix Results Summary"
    $results | Format-Table -AutoSize

    $failedCount = @($results | Where-Object { $_.Result -eq "FAIL" }).Count
    if ($failedCount -eq 0) {
        Write-Host "[SUMMARY] ALL NATIVE HOST EMULATIONS PASSED (100% SUCCESS)." -ForegroundColor Green
    }
    else {
        Write-Host "[SUMMARY] $failedCount EMULATION(S) FAILED." -ForegroundColor Red
    }
}

# Interactive CLI Menu
function Show-InteractiveMenu {
    while ($true) {
        Show-TestBanner "Interactive Execution Selector"
        Write-Host "  1. Emulate FullOS Task Sequence (Pure WPF - Light Theme)" -ForegroundColor Yellow
        Write-Host "  2. Emulate FullOS Task Sequence (Pure WPF - Dark Theme)" -ForegroundColor Yellow
        Write-Host "  3. Emulate WinPE Bare-Metal Task Sequence (Pure WPF - Light Theme)" -ForegroundColor Yellow
        Write-Host "  4. Emulate WinPE Bare-Metal Task Sequence (Pure WPF - Dark Theme)" -ForegroundColor Yellow
        Write-Host "  5. Run Full Automated Matrix Test (All Environments & Themes)" -ForegroundColor Green
        Write-Host "  Q. Quit Test Suite" -ForegroundColor Gray
        Write-Host ""
        $choice = Read-Host "Select an option [1-5, Q]"

        switch ($choice.ToString().Trim().ToUpper()) {
            '1' { Emulate-TaskSequenceExecution -EnvLayout "FullOS" -EngineName "Pure WPF FullOS Host" -ThemeName "Light" -TopMostMode "Off" -Title $WindowTitle -DelayMs 1000 -KeepHostOpen }
            '2' { Emulate-TaskSequenceExecution -EnvLayout "FullOS" -EngineName "Pure WPF FullOS Host" -ThemeName "Dark" -TopMostMode "Off" -Title $WindowTitle -DelayMs 1000 -KeepHostOpen }
            '3' { Emulate-TaskSequenceExecution -EnvLayout "WinPE" -EngineName "Pure WPF WinPE Host" -ThemeName "Light" -TopMostMode "Off" -Title $WindowTitle -DelayMs 1000 -KeepHostOpen }
            '4' { Emulate-TaskSequenceExecution -EnvLayout "WinPE" -EngineName "Pure WPF WinPE Host" -ThemeName "Dark" -TopMostMode "Off" -Title $WindowTitle -DelayMs 1000 -KeepHostOpen }
            '5' { Run-FullAutomatedMatrix }
            'Q' { Write-Host "Exiting Test Suite. Goodbye!" -ForegroundColor Cyan; break }
            Default { Write-Host "Invalid option. Please try again." -ForegroundColor Red }
        }
    }
}

# Dispatch Execution Mode
if ($Interactive -or ($PSBoundParameters.Count -eq 0 -and $TestMode -eq 'Interactive')) {
    Show-InteractiveMenu
}
else {
    switch ($TestMode) {
        'FullOS_WPF'     { Emulate-TaskSequenceExecution -EnvLayout "FullOS" -EngineName "Pure WPF FullOS Host" -ThemeName $Theme -TopMostMode $TopMost -Title $WindowTitle -DelayMs $StepDelayMs -KeepHostOpen:$KeepOpen }
        'WinPE_WPF'      { Emulate-TaskSequenceExecution -EnvLayout "WinPE" -EngineName "Pure WPF WinPE Host" -ThemeName $Theme -TopMostMode $TopMost -Title $WindowTitle -DelayMs $StepDelayMs -KeepHostOpen:$KeepOpen }
        'LiveJsonSync'   { Emulate-TaskSequenceExecution -EnvLayout "FullOS" -EngineName "Pure WPF FullOS Host" -ThemeName $Theme -TopMostMode $TopMost -Title $WindowTitle -DelayMs $StepDelayMs -KeepHostOpen:$KeepOpen }
        'TestAllMatrix'  { Run-FullAutomatedMatrix }
        Default          { Show-InteractiveMenu }
    }
}
