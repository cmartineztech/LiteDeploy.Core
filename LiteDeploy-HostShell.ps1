<#
.SYNOPSIS
    LiteDeploy HostShell - Streamlined console toolkit for Windows PE.

.DESCRIPTION
    Dot-source to load the toolkit into the current session:

        . X:\~LiteDeploy\Scripts\LiteDeploy-HostShell.ps1

    Exported API Functions:
        Set-HostShellWindow            Window state, position, size, always-on-top, title, prompt, optional scrollbar hiding.
        Set-HostShellWindowStyle       Normal / Borderless / Fixed / Minimal frame styles.
        Set-HostShellTheme             Named or custom console color themes.
        Set-HostShellPreset            One-call behavior bundles (theme + style + geometry).
        Write-HostShellProgress        Colored in-place progress bar.

    Target Environment:
        Windows PE / PowerShell 5.1. Zero module dependencies, kernel32/user32 P/Invoke interop only.

.NOTES
    Window control relies on the classic Console Host (conhost), which is standard in Windows PE.
#>

#region 1 - Bootstrap

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if ($env:WT_SESSION) {
    Write-Warning "Windows Terminal detected. Use the classic Console Host or Windows PE for reliable window control."
}

#endregion

#region 2 - Native Interop (Win32)

if (-not ("Win32.LiteDeployHostShellV2" -as [type])) {
    Add-Type @"
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

        // 32/64-bit safe wrappers: select appropriate Ptr variant at runtime.
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
"@
}

#endregion

#region 3 - Resolvers & Data Tables

function Resolve-HostShellLayout {
    <#
    .SYNOPSIS
        Calculates target window rectangle coordinates and dimensions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Top", "TopLeft", "TopRight", "Center", "Bottom", "BottomLeft", "BottomRight")]
        [string]$Position,

        [Parameter(Mandatory)]
        [ValidateRange(1, 16384)]
        [int]$ScreenWidth,

        [Parameter(Mandatory)]
        [ValidateRange(1, 16384)]
        [int]$ScreenHeight,

        [ValidateRange(0, 100)]
        [int]$WidthPercent = 0,

        [ValidateRange(0, 100)]
        [int]$HeightPercent = 0,

        [ValidateRange(300, 4000)]
        [int]$Width = 1000,

        [ValidateRange(200, 3000)]
        [int]$Height = 700
    )

    $TargetWidth  = if ($WidthPercent  -gt 0) { [int]($ScreenWidth  * ($WidthPercent  / 100)) } else { $Width }
    $TargetHeight = if ($HeightPercent -gt 0) { [int]($ScreenHeight * ($HeightPercent / 100)) } else { $Height }

    $TargetWidth  = [Math]::Min([Math]::Max(1, $TargetWidth),  $ScreenWidth)
    $TargetHeight = [Math]::Min([Math]::Max(1, $TargetHeight), $ScreenHeight)

    switch ($Position) {
        "Top"         { $X = [int](($ScreenWidth - $TargetWidth) / 2);  $Y = 0 }
        "TopLeft"     { $X = 0;                                         $Y = 0 }
        "TopRight"    { $X = $ScreenWidth - $TargetWidth;               $Y = 0 }
        "Center"      { $X = [int](($ScreenWidth - $TargetWidth) / 2);  $Y = [int](($ScreenHeight - $TargetHeight) / 2) }
        "Bottom"      { $X = [int](($ScreenWidth - $TargetWidth) / 2);  $Y = $ScreenHeight - $TargetHeight }
        "BottomLeft"  { $X = 0;                                         $Y = $ScreenHeight - $TargetHeight }
        "BottomRight" { $X = $ScreenWidth - $TargetWidth;               $Y = $ScreenHeight - $TargetHeight }
    }

    [PSCustomObject]@{
        X                = [Math]::Max(0, $X)
        Y                = [Math]::Max(0, $Y)
        Width            = $TargetWidth
        Height           = $TargetHeight
        UsingPercentSize = ($WidthPercent -gt 0) -or ($HeightPercent -gt 0)
    }
}

function Get-HostShellWindowStyleValue {
    <#
    .SYNOPSIS
        Calculates GWL_STYLE bitmask for target window frame styles.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Normal", "Borderless", "Fixed", "Minimal")]
        [string]$WindowStyle,

        [Parameter(Mandatory)]
        [long]$CurrentStyle,

        [Parameter(Mandatory)]
        [long]$OriginalStyle
    )

    $WS_CAPTION     = 0x00C00000L  # Title bar (caption + border)
    $WS_SYSMENU     = 0x00080000L  # System menu
    $WS_THICKFRAME  = 0x00040000L  # Resizing border
    $WS_MINIMIZEBOX = 0x00020000L  # Minimize button
    $WS_MAXIMIZEBOX = 0x00010000L  # Maximize button

    $NewStyle = switch ($WindowStyle) {
        "Normal"     { $OriginalStyle }
        "Borderless" { $CurrentStyle -band (-bnot $WS_CAPTION) -band (-bnot $WS_THICKFRAME) }
        "Fixed"      { ($CurrentStyle -bor $WS_CAPTION -bor $WS_SYSMENU) -band (-bnot $WS_THICKFRAME)  -band (-bnot $WS_MAXIMIZEBOX) }
        "Minimal"    { ($CurrentStyle -bor $WS_CAPTION -bor $WS_SYSMENU) -band (-bnot $WS_MINIMIZEBOX) -band (-bnot $WS_MAXIMIZEBOX) }
    }

    [long]$NewStyle
}

function Resolve-HostShellBufferSize {
    <#
    .SYNOPSIS
        Calculates console screen buffer dimensions matching viewport to hide scrollbars.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 4096)]
        [int]$WindowWidth,

        [Parameter(Mandatory)]
        [ValidateRange(1, 4096)]
        [int]$WindowHeight
    )

    [PSCustomObject]@{
        Width  = $WindowWidth
        Height = $WindowHeight
    }
}

function Get-HostShellTheme {
    <#
    .SYNOPSIS
        Retrieves color mapping for a named theme.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("LiteDeploy", "Midnight", "Slate", "Ocean", "HighContrast", "Default")]
        [string]$Name
    )

    $Themes = @{
        LiteDeploy   = @{ Foreground = [ConsoleColor]::White;  Background = [ConsoleColor]::DarkBlue }
        Midnight     = @{ Foreground = [ConsoleColor]::Gray;   Background = [ConsoleColor]::Black }
        Slate        = @{ Foreground = [ConsoleColor]::White;  Background = [ConsoleColor]::DarkGray }
        Ocean        = @{ Foreground = [ConsoleColor]::Cyan;   Background = [ConsoleColor]::DarkBlue }
        HighContrast = @{ Foreground = [ConsoleColor]::Yellow; Background = [ConsoleColor]::Black }
        Default      = @{ Foreground = [ConsoleColor]::Gray;   Background = [ConsoleColor]::Black }
    }

    $Themes[$Name]
}

function Get-HostShellPreset {
    <#
    .SYNOPSIS
        Retrieves behavior configuration bundle for a named preset.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Main", "Full", "Logs", "Picker")]
        [string]$Name
    )

    $Presets = @{
        Main = @{
            Theme         = "LiteDeploy"
            ClearScreen   = $true
            Style         = "Fixed"
            Position      = "Top"
            WidthPercent  = 100
            HeightPercent = 30
            AlwaysOnTop   = "On"
            Title         = "LiteDeploy"
            Prompt        = "LiteDeploy> "
        }
        Full = @{
            Theme       = "LiteDeploy"
            ClearScreen = $true
            Action      = "Maximize"
            Title       = "LiteDeploy"
            Prompt      = "LiteDeploy> "
        }
        Logs = @{
            Theme         = "Midnight"
            ClearScreen   = $true
            Style         = "Minimal"
            Position      = "Bottom"
            WidthPercent  = 100
            HeightPercent = 25
            AlwaysOnTop   = "On"
            Title         = "LiteDeploy Logs"
            Prompt        = ""
        }
        Picker = @{
            Theme         = "Ocean"
            ClearScreen   = $true
            Style         = "Fixed"
            Position      = "Center"
            WidthPercent  = 70
            HeightPercent = 70
            Title         = "LiteDeploy"
        }
    }

    $Presets[$Name]
}

#endregion

#region 4 - Public API Cmdlets

function Set-HostShellWindow {
    <#
    .SYNOPSIS
        Controls console window position, geometry, prompt, title, and z-order.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet("None", "Minimize", "Restore", "Maximize", "Hide")]
        [string]$Action = "None",

        [ValidateSet("None", "Top", "TopLeft", "TopRight", "Center", "Bottom", "BottomLeft", "BottomRight")]
        [string]$Position = "None",

        [ValidateSet("None", "On", "Off")]
        [string]$AlwaysOnTop = "None",

        [ValidateRange(0, 100)]
        [int]$WidthPercent = 0,

        [ValidateRange(0, 100)]
        [int]$HeightPercent = 0,

        [ValidateRange(300, 4000)]
        [int]$Width = 1000,

        [ValidateRange(200, 3000)]
        [int]$Height = 700,

        [AllowEmptyString()]
        [string]$Title,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$Prompt,

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

    $WindowHandle = [Win32.LiteDeployHostShellV2]::GetConsoleWindow()

    if ($WindowHandle -eq [IntPtr]::Zero) {
        Write-Verbose "No console window handle attached to this process."
        return
    }

    if ($Position -ne "None") {
        [Win32.LiteDeployHostShellV2]::ShowWindow($WindowHandle, 9) | Out-Null
        Start-Sleep -Milliseconds 100

        $ScreenWidth  = [Win32.LiteDeployHostShellV2]::GetSystemMetrics(0)
        $ScreenHeight = [Win32.LiteDeployHostShellV2]::GetSystemMetrics(1)

        $Layout = Resolve-HostShellLayout `
            -Position $Position `
            -ScreenWidth $ScreenWidth `
            -ScreenHeight $ScreenHeight `
            -WidthPercent $WidthPercent `
            -HeightPercent $HeightPercent `
            -Width $Width `
            -Height $Height

        if ($Layout.UsingPercentSize) {
            $MoveOnlyFlags = 0x0001 -bor 0x0004 -bor 0x0040
            [Win32.LiteDeployHostShellV2]::SetWindowPos(
                $WindowHandle, [IntPtr]::Zero, $Layout.X, $Layout.Y, 0, 0, $MoveOnlyFlags) | Out-Null
            Start-Sleep -Milliseconds 120
        }

        $PositionFlags = 0x0004 -bor 0x0040
        [Win32.LiteDeployHostShellV2]::SetWindowPos(
            $WindowHandle, [IntPtr]::Zero, $Layout.X, $Layout.Y, $Layout.Width, $Layout.Height, $PositionFlags) | Out-Null
    }

    if ($AlwaysOnTop -ne "None") {
        $InsertAfter  = if ($AlwaysOnTop -eq "On") { [IntPtr](-1) } else { [IntPtr](-2) }
        $TopMostFlags = 0x0002 -bor 0x0001 -bor 0x0010
        [Win32.LiteDeployHostShellV2]::SetWindowPos(
            $WindowHandle, $InsertAfter, 0, 0, 0, 0, $TopMostFlags) | Out-Null
    }

    $ShowCommand = switch ($Action) {
        "Hide"     { 0 }
        "Maximize" { 3 }
        "Minimize" { 6 }
        "Restore"  { 9 }
        default    { $null }
    }

    if ($null -ne $ShowCommand) {
        [Win32.LiteDeployHostShellV2]::ShowWindow($WindowHandle, $ShowCommand) | Out-Null
    }

    if ($HideScrollBars) {
        $WindowSize = $Host.UI.RawUI.WindowSize
        $TargetBufferSize = Resolve-HostShellBufferSize -WindowWidth $WindowSize.Width -WindowHeight $WindowSize.Height
        $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($TargetBufferSize.Width, $TargetBufferSize.Height)
    }
}

function Set-HostShellWindowStyle {
    <#
    .SYNOPSIS
        Changes the console window frame style (Normal, Borderless, Fixed, Minimal).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet("Normal", "Borderless", "Fixed", "Minimal")]
        [string]$WindowStyle = "Normal"
    )

    $WindowHandle = [Win32.LiteDeployHostShellV2]::GetConsoleWindow()

    if ($WindowHandle -eq [IntPtr]::Zero) {
        Write-Verbose "No console window handle attached to this process."
        return
    }

    $GWL_STYLE    = -16
    $CurrentStyle = [Win32.LiteDeployHostShellV2]::GetWindowStyle($WindowHandle, $GWL_STYLE).ToInt64()

    if (-not (Get-Variable -Name HostShellOriginalWindowStyle -Scope Global -ErrorAction SilentlyContinue)) {
        $global:HostShellOriginalWindowStyle = $CurrentStyle
    }

    $NewStyle = Get-HostShellWindowStyleValue `
        -WindowStyle $WindowStyle `
        -CurrentStyle $CurrentStyle `
        -OriginalStyle $global:HostShellOriginalWindowStyle

    [Win32.LiteDeployHostShellV2]::SetWindowStyle($WindowHandle, $GWL_STYLE, [IntPtr]$NewStyle) | Out-Null

    $FrameFlags = 0x0001 -bor 0x0002 -bor 0x0004 -bor 0x0010 -bor 0x0020 -bor 0x0040
    [Win32.LiteDeployHostShellV2]::SetWindowPos($WindowHandle, [IntPtr]::Zero, 0, 0, 0, 0, $FrameFlags) | Out-Null

    Write-Verbose "Console window style applied: $WindowStyle"
}

function Set-HostShellPreset {
    <#
    .SYNOPSIS
        Applies a named behavior preset bundle to the current console window.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $Preset = Get-HostShellPreset -Name $Name

    if ($Preset.ContainsKey("Theme")) {
        Set-HostShellTheme -Theme $Preset.Theme `
            -ClearScreen:($Preset.ContainsKey("ClearScreen") -and $Preset.ClearScreen)
    }

    if ($Preset.ContainsKey("Style")) {
        Set-HostShellWindowStyle -WindowStyle $Preset.Style
    }

    $WindowParameters = @{}
    foreach ($Key in "Action", "Position", "WidthPercent", "HeightPercent", "Width", "Height", "AlwaysOnTop", "Title", "Prompt", "HideScrollBars") {
        if ($Preset.ContainsKey($Key)) {
            $WindowParameters[$Key] = $Preset[$Key]
        }
    }

    if ($WindowParameters.Count -gt 0) {
        Set-HostShellWindow @WindowParameters
    }
}

function Set-HostShellTheme {
    <#
    .SYNOPSIS
        Applies color theme to the console window.
    #>
    [CmdletBinding(DefaultParameterSetName = "Theme")]
    param(
        [Parameter(ParameterSetName = "Theme")]
        [ValidateSet("LiteDeploy", "Midnight", "Slate", "Ocean", "HighContrast", "Default")]
        [string]$Theme = "LiteDeploy",

        [Parameter(ParameterSetName = "Custom")]
        [ConsoleColor]$ForegroundColor,

        [Parameter(ParameterSetName = "Custom")]
        [ConsoleColor]$BackgroundColor,

        [switch]$ClearScreen,

        [switch]$ShowPreview
    )

    if ($PSCmdlet.ParameterSetName -eq "Custom") {
        if (-not $PSBoundParameters.ContainsKey("ForegroundColor")) {
            $ForegroundColor = $Host.UI.RawUI.ForegroundColor
        }
        if (-not $PSBoundParameters.ContainsKey("BackgroundColor")) {
            $BackgroundColor = $Host.UI.RawUI.BackgroundColor
        }
        $Colors = @{ Foreground = $ForegroundColor; Background = $BackgroundColor }
    }
    else {
        $Colors = Get-HostShellTheme -Name $Theme
    }

    $RawUI = $Host.UI.RawUI
    $RawUI.ForegroundColor = $Colors.Foreground
    $RawUI.BackgroundColor = $Colors.Background

    if ($RawUI.PSObject.Properties.Match("PopupForegroundColor").Count -gt 0) {
        $RawUI.PopupForegroundColor = $Colors.Foreground
    }
    if ($RawUI.PSObject.Properties.Match("PopupBackgroundColor").Count -gt 0) {
        $RawUI.PopupBackgroundColor = $Colors.Background
    }

    if ($ClearScreen) {
        Clear-Host
    }

    if ($ShowPreview) {
        Write-Host ""
        Write-Host " HostShell Theme Preview " -ForegroundColor Black -BackgroundColor Cyan
        Write-Host ""
        Write-Host "LiteDeploy shell theme applied successfully."
        Write-Host "Foreground: $($Host.UI.RawUI.ForegroundColor)"
        Write-Host "Background: $($Host.UI.RawUI.BackgroundColor)"
        Write-Host ""
        Write-Host "[INFO]  Deployment environment initialized." -ForegroundColor Cyan
        Write-Host "[OK]    Network connectivity confirmed."          -ForegroundColor Green
        Write-Host "[WARN]  Driver package not yet selected."          -ForegroundColor Yellow
        Write-Host "[ERROR] Example error message."                    -ForegroundColor Red
        Write-Host ""
    }
}

function Write-HostShellProgress {
    <#
    .SYNOPSIS
        Writes a colored in-place progress bar.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 100)]
        [int]$Percent,

        [ValidateRange(10, 100)]
        [int]$Width = 40,

        [ConsoleColor]$CompletedColor = [ConsoleColor]::Green,
        [ConsoleColor]$RemainingColor = [ConsoleColor]::DarkGray,
        [ConsoleColor]$TextColor = [ConsoleColor]::Gray
    )

    $FilledWidth = [int][Math]::Round($Width * ($Percent / 100))
    $EmptyWidth  = $Width - $FilledWidth

    Write-Host "`r|" -NoNewline -ForegroundColor $TextColor

    if ($FilledWidth -gt 0) {
        Write-Host (" " * $FilledWidth) -NoNewline -ForegroundColor Black -BackgroundColor $CompletedColor
    }

    if ($EmptyWidth -gt 0) {
        Write-Host (" " * $EmptyWidth) -NoNewline -ForegroundColor Black -BackgroundColor $RemainingColor
    }

    Write-Host ("| {0,3}%" -f $Percent) -NoNewline -ForegroundColor $TextColor
}

#endregion
