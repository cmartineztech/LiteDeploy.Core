<#
.SYNOPSIS
    Manual verification harness for LiteDeploy-HostShell.ps1.

.DESCRIPTION
    This is NOT an automated test suite - it is a human-runnable check
    script with two sections:

    Section 1 (always runs, unattended):
        Assertion checks for the toolkit's pure-logic functions
        (layout math, window-style bit math, theme table, truncation).
        Prints PASS/FAIL per check and sets the exit code.

    Section 2 (runs with -Interactive, visual):
        Cycles window positions, window styles, themes, the progress
        bar, and the task-sequence selector with sample data.
        Run it in the classic Console Host (conhost) or Windows PE -
        window control is not reliable under Windows Terminal.

.EXAMPLE
    .\Test-LiteDeployHostShell.ps1

    Runs only the unattended Section 1 assertions.

.EXAMPLE
    .\Test-LiteDeployHostShell.ps1 -Interactive

    Runs Section 1, then the visual Section 2 walkthrough.
#>

[CmdletBinding()]
param(
    [switch]$Interactive,

    [ValidateRange(1, 10)]
    [int]$DelaySeconds = 2
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$ToolkitPath = Join-Path $PSScriptRoot "LiteDeploy-HostShell.ps1"

if (-not (Test-Path -LiteralPath $ToolkitPath -PathType Leaf)) {
    throw "Toolkit not found: $ToolkitPath"
}

. $ToolkitPath

# ============================================================================
#  Section 1 - Pure-logic assertions (unattended)
# ============================================================================

$script:PassCount = 0
$script:FailCount = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Expected,

        [AllowNull()]
        [object]$Actual
    )

    if ($Expected -eq $Actual) {
        $script:PassCount++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    }
    else {
        $script:FailCount++
        Write-Host "  [FAIL] $Name  expected=[$Expected] actual=[$Actual]" -ForegroundColor Red
    }
}

Write-Host "============================================================"
Write-Host "Section 1: pure-logic assertions"
Write-Host "============================================================"

# --- Resolve-HostShellLayout ------------------------------------------------

Write-Host ""
Write-Host "Resolve-HostShellLayout"

$Layout = Resolve-HostShellLayout -Position Center -ScreenWidth 1920 -ScreenHeight 1080
Assert-Equal -Name "Center fixed: X"      -Expected 460    -Actual $Layout.X
Assert-Equal -Name "Center fixed: Y"      -Expected 190    -Actual $Layout.Y
Assert-Equal -Name "Center fixed: Width"  -Expected 1000   -Actual $Layout.Width
Assert-Equal -Name "Center fixed: Height" -Expected 700    -Actual $Layout.Height
Assert-Equal -Name "Center fixed: not percent-based" -Expected $false -Actual $Layout.UsingPercentSize

$Layout = Resolve-HostShellLayout -Position TopLeft -ScreenWidth 1920 -ScreenHeight 1080
Assert-Equal -Name "TopLeft fixed: X" -Expected 0 -Actual $Layout.X
Assert-Equal -Name "TopLeft fixed: Y" -Expected 0 -Actual $Layout.Y

$Layout = Resolve-HostShellLayout -Position BottomRight -ScreenWidth 1920 -ScreenHeight 1080
Assert-Equal -Name "BottomRight fixed: X" -Expected 920 -Actual $Layout.X
Assert-Equal -Name "BottomRight fixed: Y" -Expected 380 -Actual $Layout.Y

$Layout = Resolve-HostShellLayout -Position TopLeft -ScreenWidth 1920 -ScreenHeight 1080 -WidthPercent 25 -HeightPercent 100
Assert-Equal -Name "TopLeft 25%x100%: Width"  -Expected 480   -Actual $Layout.Width
Assert-Equal -Name "TopLeft 25%x100%: Height" -Expected 1080  -Actual $Layout.Height
Assert-Equal -Name "TopLeft 25%x100%: percent-based" -Expected $true -Actual $Layout.UsingPercentSize

$Layout = Resolve-HostShellLayout -Position Center -ScreenWidth 1920 -ScreenHeight 1080 -WidthPercent 60 -HeightPercent 70
Assert-Equal -Name "Center 60%x70%: Width"  -Expected 1152 -Actual $Layout.Width
Assert-Equal -Name "Center 60%x70%: Height" -Expected 756  -Actual $Layout.Height
Assert-Equal -Name "Center 60%x70%: X"      -Expected 384  -Actual $Layout.X
Assert-Equal -Name "Center 60%x70%: Y"      -Expected 162  -Actual $Layout.Y

$Layout = Resolve-HostShellLayout -Position Bottom -ScreenWidth 1920 -ScreenHeight 1080 -WidthPercent 60 -HeightPercent 30
Assert-Equal -Name "Bottom 60%x30%: X" -Expected 384 -Actual $Layout.X
Assert-Equal -Name "Bottom 60%x30%: Y" -Expected 756 -Actual $Layout.Y

# A fixed size larger than the screen must clamp to the screen.
$Layout = Resolve-HostShellLayout -Position TopRight -ScreenWidth 1920 -ScreenHeight 1080 -Width 4000 -Height 700
Assert-Equal -Name "Oversize clamps Width to screen" -Expected 1920 -Actual $Layout.Width
Assert-Equal -Name "Oversize TopRight: X"            -Expected 0    -Actual $Layout.X

# --- Get-HostShellWindowStyleValue ------------------------------------------

Write-Host ""
Write-Host "Get-HostShellWindowStyleValue"

# Style flags (winuser.h) for building test styles.
$WS_CAPTION     = 0x00C00000L
$WS_SYSMENU     = 0x00080000L
$WS_THICKFRAME  = 0x00040000L
$WS_MINIMIZEBOX = 0x00020000L
$WS_MAXIMIZEBOX = 0x00010000L

# Typical console style: every flag present.
$FullStyle = [long]($WS_CAPTION -bor $WS_SYSMENU -bor $WS_THICKFRAME -bor $WS_MINIMIZEBOX -bor $WS_MAXIMIZEBOX)

$Style = Get-HostShellWindowStyleValue -WindowStyle Borderless -CurrentStyle $FullStyle -OriginalStyle $FullStyle
Assert-Equal -Name "Borderless removes caption"    -Expected 0 -Actual ($Style -band $WS_CAPTION)
Assert-Equal -Name "Borderless removes thickframe" -Expected 0 -Actual ($Style -band $WS_THICKFRAME)
Assert-Equal -Name "Borderless keeps sysmenu"      -Expected $WS_SYSMENU -Actual ($Style -band $WS_SYSMENU)

$Style = Get-HostShellWindowStyleValue -WindowStyle Fixed -CurrentStyle $FullStyle -OriginalStyle $FullStyle
Assert-Equal -Name "Fixed keeps caption"        -Expected $WS_CAPTION -Actual ($Style -band $WS_CAPTION)
Assert-Equal -Name "Fixed keeps sysmenu"        -Expected $WS_SYSMENU -Actual ($Style -band $WS_SYSMENU)
Assert-Equal -Name "Fixed removes thickframe"   -Expected 0 -Actual ($Style -band $WS_THICKFRAME)
Assert-Equal -Name "Fixed removes maximize box" -Expected 0 -Actual ($Style -band $WS_MAXIMIZEBOX)
Assert-Equal -Name "Fixed keeps minimize box"   -Expected $WS_MINIMIZEBOX -Actual ($Style -band $WS_MINIMIZEBOX)

$Style = Get-HostShellWindowStyleValue -WindowStyle Minimal -CurrentStyle $FullStyle -OriginalStyle $FullStyle
Assert-Equal -Name "Minimal keeps caption"        -Expected $WS_CAPTION -Actual ($Style -band $WS_CAPTION)
Assert-Equal -Name "Minimal keeps thickframe"     -Expected $WS_THICKFRAME -Actual ($Style -band $WS_THICKFRAME)
Assert-Equal -Name "Minimal removes minimize box" -Expected 0 -Actual ($Style -band $WS_MINIMIZEBOX)
Assert-Equal -Name "Minimal removes maximize box" -Expected 0 -Actual ($Style -band $WS_MAXIMIZEBOX)

# Fixed must re-add the caption when starting from a borderless style.
$BorderlessStyle = [long]($WS_SYSMENU -bor $WS_MINIMIZEBOX -bor $WS_MAXIMIZEBOX)
$Style = Get-HostShellWindowStyleValue -WindowStyle Fixed -CurrentStyle $BorderlessStyle -OriginalStyle $FullStyle
Assert-Equal -Name "Fixed re-adds caption from borderless" -Expected $WS_CAPTION -Actual ($Style -band $WS_CAPTION)

# Normal restores the original style, ignoring the current one.
$Style = Get-HostShellWindowStyleValue -WindowStyle Normal -CurrentStyle 0x12345 -OriginalStyle $FullStyle
Assert-Equal -Name "Normal restores original style" -Expected $FullStyle -Actual $Style

# --- Get-HostShellTheme ------------------------------------------------------

Write-Host ""
Write-Host "Get-HostShellTheme"

$Theme = Get-HostShellTheme -Name LiteDeploy
Assert-Equal -Name "LiteDeploy foreground" -Expected ([ConsoleColor]::White)    -Actual $Theme.Foreground
Assert-Equal -Name "LiteDeploy background" -Expected ([ConsoleColor]::DarkBlue) -Actual $Theme.Background

$Theme = Get-HostShellTheme -Name HighContrast
Assert-Equal -Name "HighContrast foreground" -Expected ([ConsoleColor]::Yellow) -Actual $Theme.Foreground
Assert-Equal -Name "HighContrast background" -Expected ([ConsoleColor]::Black)  -Actual $Theme.Background

foreach ($Name in "LiteDeploy", "Midnight", "Slate", "Ocean", "HighContrast", "Default") {
    $Theme = Get-HostShellTheme -Name $Name
    Assert-Equal -Name "Theme table resolves: $Name" -Expected $true -Actual ($null -ne $Theme)
}

# --- Get-TruncatedText -------------------------------------------------------

Write-Host ""
Write-Host "Get-TruncatedText"

Assert-Equal -Name "Short text unchanged"      -Expected "hello"       -Actual (Get-TruncatedText -Value "hello" -Width 10)
Assert-Equal -Name "Exact-fit text unchanged"  -Expected "1234567890"  -Actual (Get-TruncatedText -Value "1234567890" -Width 10)
Assert-Equal -Name "Long text gets ellipsis"   -Expected "hello w..."  -Actual (Get-TruncatedText -Value "hello world foo" -Width 10)
Assert-Equal -Name "Null becomes empty string" -Expected ""            -Actual (Get-TruncatedText -Value $null -Width 10)

# --- Summary -----------------------------------------------------------------

Write-Host ""
Write-Host "============================================================"

if ($script:FailCount -gt 0) {
    Write-Host "Section 1 FAILED: $($script:PassCount) passed, $($script:FailCount) failed." -ForegroundColor Red
    Write-Host "============================================================"
    exit 1
}

Write-Host "Section 1 PASSED: $($script:PassCount) of $($script:PassCount) checks." -ForegroundColor Green
Write-Host "============================================================"

if (-not $Interactive) {
    Write-Host ""
    Write-Host "Re-run with -Interactive for the visual walkthrough (conhost or WinPE only)."
    exit 0
}

# ============================================================================
#  Section 2 - Interactive visual walkthrough
# ============================================================================

if ($env:WT_SESSION) {
    Write-Warning "Windows Terminal detected. Window control is only reliable in the classic Console Host or Windows PE."
}

function Write-Step {
    param([Parameter(Mandatory)][string]$Text)

    Write-Host ""
    Write-Host "------------------------------------------------------------"
    Write-Host $Text -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------"
}

$HadError = $false

try {
    Write-Step "Window: title + custom prompt"
    Set-HostShellWindow -Title "LiteDeploy HostShell - Interactive Test" -Prompt "HostShell-Test> "
    Start-Sleep -Seconds $DelaySeconds

    Write-Step "Window: center, fixed size 1000x700"
    Set-HostShellWindow -Action Restore -Position Center -Width 1000 -Height 700
    Start-Sleep -Seconds $DelaySeconds

    Write-Step "Window: dock left, 25% width x 100% height"
    Set-HostShellWindow -Position TopLeft -WidthPercent 25 -HeightPercent 100
    Start-Sleep -Seconds $DelaySeconds

    Write-Step "Window: bottom strip, 60% width x 30% height"
    Set-HostShellWindow -Position Bottom -WidthPercent 60 -HeightPercent 30
    Start-Sleep -Seconds $DelaySeconds

    Write-Step "Window: always-on-top ON"
    Set-HostShellWindow -AlwaysOnTop On
    Start-Sleep -Seconds $DelaySeconds

    Write-Step "Window: always-on-top OFF"
    Set-HostShellWindow -AlwaysOnTop Off
    Start-Sleep -Seconds $DelaySeconds

    Write-Step "Window: maximize, then restore to 60% x 70% centered"
    Set-HostShellWindow -Action Maximize
    Start-Sleep -Seconds $DelaySeconds
    Set-HostShellWindow -Action Restore -Position Center -WidthPercent 60 -HeightPercent 70
    Start-Sleep -Seconds $DelaySeconds

    Write-Step "Window style: Fixed (no resize, no maximize)"
    Set-HostShellWindowStyle -WindowStyle Fixed
    Start-Sleep -Seconds $DelaySeconds

    Write-Step "Window style: Minimal (no minimize/maximize buttons)"
    Set-HostShellWindowStyle -WindowStyle Minimal
    Start-Sleep -Seconds $DelaySeconds

    Write-Step "Window style: Borderless"
    Set-HostShellWindowStyle -WindowStyle Borderless
    Start-Sleep -Seconds $DelaySeconds

    Write-Step "Window style: Normal (restored)"
    Set-HostShellWindowStyle -WindowStyle Normal
    Start-Sleep -Seconds $DelaySeconds

    Write-Step "Themes: cycling all themes with preview"
    foreach ($Name in "LiteDeploy", "Midnight", "Slate", "Ocean", "HighContrast", "Default") {
        Set-HostShellTheme -Theme $Name -ClearScreen -ShowPreview
        Write-Host "Theme: $Name"
        Start-Sleep -Seconds $DelaySeconds
    }

    Write-Step "Progress bar: 0% to 100%"
    for ($Percent = 0; $Percent -le 100; $Percent += 5) {
        Write-HostShellProgress -Percent $Percent
        Start-Sleep -Milliseconds 120
    }
    Write-Host
    Start-Sleep -Seconds $DelaySeconds

    Write-Step "Task-sequence selector (sample data)"
    $TaskSequences = @(
        [PSCustomObject]@{
            Id           = "TS001"
            Name         = "Windows 11 Enterprise"
            Description  = "Standard Windows 11 Enterprise deployment"
            Architecture = "x64"
            Version      = "24H2"
            ImagePath    = "X:\Images\Windows11-Enterprise.wim"
            ImageIndex   = 6
            UnattendPath = "X:\LiteDeploy\Unattend\Enterprise.xml"
        }
        [PSCustomObject]@{
            Id           = "TS002"
            Name         = "Windows 11 Developer"
            Description  = "Developer workstation with additional tools"
            Architecture = "x64"
            Version      = "24H2"
            ImagePath    = "X:\Images\Windows11-Developer.wim"
            ImageIndex   = 6
            UnattendPath = "X:\LiteDeploy\Unattend\Developer.xml"
        }
        [PSCustomObject]@{
            Id           = "TS003"
            Name         = "Windows 11 Clean"
            Description  = "Minimal clean Windows 11 deployment"
            Architecture = "x64"
            Version      = "24H2"
            ImagePath    = "X:\Images\Windows11-Clean.wim"
            ImageIndex   = 6
            UnattendPath = "X:\LiteDeploy\Unattend\Clean.xml"
        }
    )

    $Selected = Select-LiteDeployTaskSequence -TaskSequences $TaskSequences

    Write-Host ""
    if ($null -eq $Selected) {
        Write-Host "Selection cancelled (Escape)." -ForegroundColor Yellow
    }
    else {
        Write-Host "Selected: $($Selected.Id) - $($Selected.Name)" -ForegroundColor Green
    }
}
catch {
    Write-Error $_
    $HadError = $true
}
finally {
    # Best-effort: leave the console in a sane state.
    Write-Step "Restore: normal style, default theme, centered 60% x 70%, standard prompt"
    Set-HostShellWindowStyle -WindowStyle Normal -ErrorAction SilentlyContinue
    Set-HostShellTheme -Theme Default -ClearScreen -ErrorAction SilentlyContinue
    Set-HostShellWindow `
        -Action Restore `
        -Position Center `
        -WidthPercent 60 `
        -HeightPercent 70 `
        -AlwaysOnTop Off `
        -Prompt "." `
        -Title "Windows PowerShell" `
        -ErrorAction SilentlyContinue
}

if ($HadError) {
    exit 1
}

Write-Host ""
Write-Host "Interactive walkthrough complete." -ForegroundColor Green
exit 0
