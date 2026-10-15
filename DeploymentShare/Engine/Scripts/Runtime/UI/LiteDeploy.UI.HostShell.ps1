<#
.SYNOPSIS
    Console window layout, colors, and progress display for LiteDeploy.
.DESCRIPTION
    Dot-source once from Engine. Import does not change the console or start a window.
    Functions use Windows console APIs when called and work in Windows PowerShell 5.1.
#>
[CmdletBinding()]
param([switch]$Metadata)
if ($Metadata) {
    [pscustomobject]@{ ComponentId = 'UI.HostShell'; Name = 'LiteDeploy Console Host'; Version = '2.0.0'; Category = 'Runtime'; TargetEnvironment = 'Universal'; MinPowerShellVersion = '5.1'; Dependencies = @() }
    return
}
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
#region 3 - Console shell toolkit (self-contained copy of HostShell)

function Initialize-LiteDeployHostShellInterop {
    # Same type name/definition as HostShell v2, so both components can coexist.
    if ("Win32.LiteDeployHostShellV2" -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Win32
{
    public static class LiteDeployHostShellV2
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
            int X, int Y, int cx, int cy, uint uFlags);

        [DllImport("user32.dll")]
        public static extern int GetSystemMetrics(int nIndex);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr", SetLastError = true)]
        public static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", EntryPoint = "GetWindowLong", SetLastError = true)]
        public static extern IntPtr GetWindowLongPtr32(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr", SetLastError = true)]
        public static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

        [DllImport("user32.dll", EntryPoint = "SetWindowLong", SetLastError = true)]
        public static extern IntPtr SetWindowLongPtr32(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

        public static IntPtr GetWindowStyle(IntPtr hWnd, int nIndex)
        {
            return (IntPtr.Size == 8) ? GetWindowLongPtr64(hWnd, nIndex) : GetWindowLongPtr32(hWnd, nIndex);
        }

        public static IntPtr SetWindowStyle(IntPtr hWnd, int nIndex, IntPtr newStyle)
        {
            return (IntPtr.Size == 8)
                ? SetWindowLongPtr64(hWnd, nIndex, newStyle)
                : SetWindowLongPtr32(hWnd, nIndex, newStyle);
        }
    }
}
'@
}

function Resolve-LiteDeployHostShellLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Top", "TopLeft", "TopRight", "Center", "Bottom", "BottomLeft", "BottomRight")]
        [string]$Position,
        [Parameter(Mandatory)][ValidateRange(1, 16384)][int]$ScreenWidth,
        [Parameter(Mandatory)][ValidateRange(1, 16384)][int]$ScreenHeight,
        [ValidateRange(0, 100)][int]$WidthPercent = 0,
        [ValidateRange(0, 100)][int]$HeightPercent = 0,
        [ValidateRange(300, 4000)][int]$Width = 1000,
        [ValidateRange(200, 3000)][int]$Height = 700
    )

    $tw = if ($WidthPercent -gt 0) { [int]($ScreenWidth * ($WidthPercent / 100)) } else { $Width }
    $th = if ($HeightPercent -gt 0) { [int]($ScreenHeight * ($HeightPercent / 100)) } else { $Height }
    $tw = [Math]::Min([Math]::Max(1, $tw), $ScreenWidth)
    $th = [Math]::Min([Math]::Max(1, $th), $ScreenHeight)

    $cx = [int](($ScreenWidth - $tw) / 2)
    $cy = [int](($ScreenHeight - $th) / 2)
    switch ($Position) {
        "Top"         { $x = $cx;                $y = 0 }
        "TopLeft"     { $x = 0;                  $y = 0 }
        "TopRight"    { $x = $ScreenWidth - $tw; $y = 0 }
        "Center"      { $x = $cx;                $y = $cy }
        "Bottom"      { $x = $cx;                $y = $ScreenHeight - $th }
        "BottomLeft"  { $x = 0;                  $y = $ScreenHeight - $th }
        "BottomRight" { $x = $ScreenWidth - $tw; $y = $ScreenHeight - $th }
    }

    [PSCustomObject]@{
        X = [Math]::Max(0, $x); Y = [Math]::Max(0, $y); Width = $tw; Height = $th
        UsingPercentSize = ($WidthPercent -gt 0) -or ($HeightPercent -gt 0)
    }
}

function Get-LiteDeployHostShellWindowStyleValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet("Normal", "Borderless", "Fixed", "Minimal")][string]$WindowStyle,
        [Parameter(Mandatory)][long]$CurrentStyle,
        [Parameter(Mandatory)][long]$OriginalStyle
    )

    $WS_CAPTION = 0x00C00000L; $WS_SYSMENU = 0x00080000L; $WS_THICKFRAME = 0x00040000L
    $WS_MINIMIZEBOX = 0x00020000L; $WS_MAXIMIZEBOX = 0x00010000L

    $new = switch ($WindowStyle) {
        "Normal"     { $OriginalStyle }
        "Borderless" { $CurrentStyle -band (-bnot $WS_CAPTION) -band (-bnot $WS_THICKFRAME) }
        "Fixed"      { ($CurrentStyle -bor $WS_CAPTION -bor $WS_SYSMENU) -band (-bnot $WS_THICKFRAME) -band (-bnot $WS_MAXIMIZEBOX) }
        "Minimal"    { ($CurrentStyle -bor $WS_CAPTION -bor $WS_SYSMENU) -band (-bnot $WS_MINIMIZEBOX) -band (-bnot $WS_MAXIMIZEBOX) }
    }
    [long]$new
}

function Get-LiteDeployHostShellTheme {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet("LiteDeploy", "Midnight", "Slate", "Ocean", "HighContrast", "Default")][string]$Name)

    $themes = @{
        LiteDeploy   = @{ Foreground = [ConsoleColor]::White;  Background = [ConsoleColor]::DarkBlue }
        Midnight     = @{ Foreground = [ConsoleColor]::Gray;   Background = [ConsoleColor]::Black }
        Slate        = @{ Foreground = [ConsoleColor]::White;  Background = [ConsoleColor]::DarkGray }
        Ocean        = @{ Foreground = [ConsoleColor]::Cyan;   Background = [ConsoleColor]::DarkBlue }
        HighContrast = @{ Foreground = [ConsoleColor]::Yellow; Background = [ConsoleColor]::Black }
        Default      = @{ Foreground = [ConsoleColor]::Gray;   Background = [ConsoleColor]::Black }
    }
    $themes[$Name]
}

function Get-LiteDeployHostShellPreset {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet("Main", "Full", "Logs", "Picker")][string]$Name)

    $presets = @{
        Main   = @{ Theme = "LiteDeploy"; ClearScreen = $true; Style = "Fixed"; Position = "Top"; WidthPercent = 100; HeightPercent = 30
                    AlwaysOnTop = "On"; Title = "LiteDeploy"; Prompt = "LiteDeploy> " }
        Full   = @{ Theme = "LiteDeploy"; ClearScreen = $true; Action = "Maximize"; Title = "LiteDeploy"; Prompt = "LiteDeploy> " }
        Logs   = @{ Theme = "Midnight"; ClearScreen = $true; Style = "Minimal"; Position = "Bottom"; WidthPercent = 100; HeightPercent = 25
                    AlwaysOnTop = "On"; Title = "LiteDeploy Logs"; Prompt = "" }
        Picker = @{ Theme = "Ocean"; ClearScreen = $true; Style = "Fixed"; Position = "Center"; WidthPercent = 70; HeightPercent = 70
                    Title = "LiteDeploy" }
    }
    $presets[$Name]
}

function Set-LiteDeployHostShellWindow {
    <#
    .SYNOPSIS
        Controls console window position, geometry, prompt, title, and z-order.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet("None", "Minimize", "Restore", "Maximize", "Hide")][string]$Action = "None",
        [ValidateSet("None", "Top", "TopLeft", "TopRight", "Center", "Bottom", "BottomLeft", "BottomRight")][string]$Position = "None",
        [ValidateSet("None", "On", "Off")][string]$AlwaysOnTop = "None",
        [ValidateRange(0, 100)][int]$WidthPercent = 0,
        [ValidateRange(0, 100)][int]$HeightPercent = 0,
        [ValidateRange(300, 4000)][int]$Width = 1000,
        [ValidateRange(200, 3000)][int]$Height = 700,
        [AllowEmptyString()][string]$Title,
        [AllowEmptyString()][AllowNull()][string]$Prompt,
        [switch]$HideScrollBars
    )

    if ($PSBoundParameters.ContainsKey("Title")) {
        $Host.UI.RawUI.WindowTitle = $Title
    }

    if ($PSBoundParameters.ContainsKey("Prompt")) {
        if ($Prompt -eq ".") {
            Remove-Variable -Name HostShellCustomPrompt -Scope Global -ErrorAction SilentlyContinue
            Set-Item -Path Function:\global:prompt -Value {
                "PS $($ExecutionContext.SessionState.Path.CurrentLocation)$('>' * ($NestedPromptLevel + 1)) "
            }
        }
        elseif ([string]::IsNullOrEmpty($Prompt)) {
            Remove-Variable -Name HostShellCustomPrompt -Scope Global -ErrorAction SilentlyContinue
            Set-Item -Path Function:\global:prompt -Value { " " }
        }
        else {
            $global:HostShellCustomPrompt = $Prompt
            Set-Item -Path Function:\global:prompt -Value { $global:HostShellCustomPrompt }
        }
    }

    Initialize-LiteDeployHostShellInterop
    $hWnd = [Win32.LiteDeployHostShellV2]::GetConsoleWindow()
    if ($hWnd -eq [IntPtr]::Zero) {
        Write-Verbose "No console window handle attached to this process."
        return
    }

    if ($Position -ne "None") {
        [Win32.LiteDeployHostShellV2]::ShowWindow($hWnd, 9) | Out-Null
        Start-Sleep -Milliseconds 100

        $layout = Resolve-LiteDeployHostShellLayout -Position $Position `
            -ScreenWidth ([Win32.LiteDeployHostShellV2]::GetSystemMetrics(0)) `
            -ScreenHeight ([Win32.LiteDeployHostShellV2]::GetSystemMetrics(1)) `
            -WidthPercent $WidthPercent -HeightPercent $HeightPercent -Width $Width -Height $Height

        if ($layout.UsingPercentSize) {
            # Move first (SWP_NOSIZE|NOZORDER|SHOWWINDOW) so DPI scaling does not distort the resize.
            [Win32.LiteDeployHostShellV2]::SetWindowPos($hWnd, [IntPtr]::Zero, $layout.X, $layout.Y, 0, 0, (0x0001 -bor 0x0004 -bor 0x0040)) | Out-Null
            Start-Sleep -Milliseconds 120
        }
        [Win32.LiteDeployHostShellV2]::SetWindowPos($hWnd, [IntPtr]::Zero, $layout.X, $layout.Y, $layout.Width, $layout.Height, (0x0004 -bor 0x0040)) | Out-Null
    }

    if ($AlwaysOnTop -ne "None") {
        $insertAfter = if ($AlwaysOnTop -eq "On") { [IntPtr](-1) } else { [IntPtr](-2) }
        [Win32.LiteDeployHostShellV2]::SetWindowPos($hWnd, $insertAfter, 0, 0, 0, 0, (0x0002 -bor 0x0001 -bor 0x0010)) | Out-Null
    }

    $show = switch ($Action) {
        "Hide"     { 0 }
        "Maximize" { 3 }
        "Minimize" { 6 }
        "Restore"  { 9 }
        default    { $null }
    }
    if ($null -ne $show) {
        [Win32.LiteDeployHostShellV2]::ShowWindow($hWnd, $show) | Out-Null
    }

    if ($HideScrollBars) {
        $ws = $Host.UI.RawUI.WindowSize
        $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($ws.Width, $ws.Height)
    }
}

function Set-LiteDeployHostShellWindowStyle {
    <#
    .SYNOPSIS
        Changes the console window frame style (Normal, Borderless, Fixed, Minimal).
    #>
    [CmdletBinding()]
    param([ValidateSet("Normal", "Borderless", "Fixed", "Minimal")][string]$WindowStyle = "Normal")

    Initialize-LiteDeployHostShellInterop
    $hWnd = [Win32.LiteDeployHostShellV2]::GetConsoleWindow()
    if ($hWnd -eq [IntPtr]::Zero) {
        Write-Verbose "No console window handle attached to this process."
        return
    }

    $GWL_STYLE = -16
    $current = [Win32.LiteDeployHostShellV2]::GetWindowStyle($hWnd, $GWL_STYLE).ToInt64()
    if (-not (Get-Variable -Name HostShellOriginalWindowStyle -Scope Global -ErrorAction SilentlyContinue)) {
        $global:HostShellOriginalWindowStyle = $current
    }

    $new = Get-LiteDeployHostShellWindowStyleValue -WindowStyle $WindowStyle -CurrentStyle $current -OriginalStyle $global:HostShellOriginalWindowStyle
    [Win32.LiteDeployHostShellV2]::SetWindowStyle($hWnd, $GWL_STYLE, [IntPtr]$new) | Out-Null
    [Win32.LiteDeployHostShellV2]::SetWindowPos($hWnd, [IntPtr]::Zero, 0, 0, 0, 0, (0x0001 -bor 0x0002 -bor 0x0004 -bor 0x0010 -bor 0x0020 -bor 0x0040)) | Out-Null
    Write-Verbose "Console window style applied: $WindowStyle"
}

function Set-LiteDeployHostShellTheme {
    <#
    .SYNOPSIS
        Applies a named or custom color theme to the console.
    #>
    [CmdletBinding(DefaultParameterSetName = "Theme")]
    param(
        [Parameter(ParameterSetName = "Theme")]
        [ValidateSet("LiteDeploy", "Midnight", "Slate", "Ocean", "HighContrast", "Default")]
        [string]$Theme = "LiteDeploy",

        [Parameter(ParameterSetName = "Custom")][ConsoleColor]$ForegroundColor,
        [Parameter(ParameterSetName = "Custom")][ConsoleColor]$BackgroundColor,
        [switch]$ClearScreen,
        [switch]$ShowPreview
    )

    $rawUI = $Host.UI.RawUI
    if ($PSCmdlet.ParameterSetName -eq "Custom") {
        if (-not $PSBoundParameters.ContainsKey("ForegroundColor")) { $ForegroundColor = $rawUI.ForegroundColor }
        if (-not $PSBoundParameters.ContainsKey("BackgroundColor")) { $BackgroundColor = $rawUI.BackgroundColor }
        $colors = @{ Foreground = $ForegroundColor; Background = $BackgroundColor }
    }
    else {
        $colors = Get-LiteDeployHostShellTheme -Name $Theme
    }

    $rawUI.ForegroundColor = $colors.Foreground
    $rawUI.BackgroundColor = $colors.Background
    if ($rawUI.PSObject.Properties.Match("PopupForegroundColor").Count -gt 0) { $rawUI.PopupForegroundColor = $colors.Foreground }
    if ($rawUI.PSObject.Properties.Match("PopupBackgroundColor").Count -gt 0) { $rawUI.PopupBackgroundColor = $colors.Background }

    if ($ClearScreen) { try { Clear-Host } catch {} }

    if ($ShowPreview) {
        Write-Host ""
        Write-Host " HostShell Theme Preview " -ForegroundColor Black -BackgroundColor Cyan
        Write-Host ("Foreground: {0}  Background: {1}" -f $rawUI.ForegroundColor, $rawUI.BackgroundColor)
        Write-Host "[INFO]  Deployment environment initialized." -ForegroundColor Cyan
        Write-Host "[OK]    Network connectivity confirmed." -ForegroundColor Green
        Write-Host "[WARN]  Driver package not yet selected." -ForegroundColor Yellow
        Write-Host "[ERROR] Example error message." -ForegroundColor Red
        Write-Host ""
    }
}

function Set-LiteDeployHostShellPreset {
    <#
    .SYNOPSIS
        Applies a named behavior preset (Main, Full, Logs, Picker): theme + frame style + geometry.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet("Main", "Full", "Logs", "Picker")][string]$Name)

    $preset = Get-LiteDeployHostShellPreset -Name $Name

    if ($preset.ContainsKey("Theme")) {
        Set-LiteDeployHostShellTheme -Theme $preset.Theme -ClearScreen:($preset.ContainsKey("ClearScreen") -and $preset.ClearScreen)
    }
    if ($preset.ContainsKey("Style")) {
        Set-LiteDeployHostShellWindowStyle -WindowStyle $preset.Style
    }

    $windowArgs = @{}
    foreach ($key in "Action", "Position", "WidthPercent", "HeightPercent", "Width", "Height", "AlwaysOnTop", "Title", "Prompt", "HideScrollBars") {
        if ($preset.ContainsKey($key)) { $windowArgs[$key] = $preset[$key] }
    }
    if ($windowArgs.Count -gt 0) {
        Set-LiteDeployHostShellWindow @windowArgs
    }
}

function Write-LiteDeployHostShellProgress {
    <#
    .SYNOPSIS
        Writes a colored in-place progress bar (carriage-return redraw).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(0, 100)][int]$Percent,
        [ValidateRange(10, 100)][int]$Width = 40,
        [ConsoleColor]$CompletedColor = [ConsoleColor]::Green,
        [ConsoleColor]$RemainingColor = [ConsoleColor]::DarkGray,
        [ConsoleColor]$TextColor = [ConsoleColor]::Gray
    )

    $filled = [int][Math]::Round($Width * ($Percent / 100))
    $empty = $Width - $filled

    Write-Host "`r|" -NoNewline -ForegroundColor $TextColor
    if ($filled -gt 0) { Write-Host (" " * $filled) -NoNewline -ForegroundColor Black -BackgroundColor $CompletedColor }
    if ($empty -gt 0) { Write-Host (" " * $empty) -NoNewline -ForegroundColor Black -BackgroundColor $RemainingColor }
    Write-Host ("| {0,3}%" -f $Percent) -NoNewline -ForegroundColor $TextColor
}



#endregion
