<#
.SYNOPSIS
    LiteDeploy HostShell - single-file console toolkit for Windows PE.

.DESCRIPTION
    Dot-source to load the toolkit into the current session:

        . X:\~LiteDeploy\Scripts\LiteDeploy-HostShell.ps1

        Set-HostShellWindow            Window state, position, size, always-on-top, title, prompt.
        Set-HostShellWindowStyle       Normal / Borderless / Fixed / Minimal frame styles.
        Set-HostShellTheme             Named or custom console color themes.
        Write-HostShellProgress        Colored in-place progress bar.
        Select-LiteDeployTaskSequence  Console task-sequence picker.

    Windows PE / PowerShell 5.1. No modules, kernel32/user32 P/Invoke only.

.NOTES
    Window control is only reliable in the classic Console Host (conhost),
    which is what Windows PE uses - not Windows Terminal.
    Dot-sourcing enables StrictMode 2.0 and $ErrorActionPreference = "Stop"
    in the calling session (intentional: engine scripts should fail fast).

.EXAMPLE
    Set-HostShellWindow -Position TopLeft -WidthPercent 25 -HeightPercent 100
#>

#region 1 - Bootstrap: strict session defaults + environment sanity check.

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if ($env:WT_SESSION) {
    Write-Warning "Windows Terminal detected. Use the classic Console Host or Windows PE for reliable window control."
}

#endregion

#region 2 - Native interop (Win32)
# Single consolidated P/Invoke class for the whole toolkit.
# Add-Type cannot redefine a type inside the same session: if these native
# declarations ever change, bump the class name (V1 -> V2) to force recompile.

if (-not ("Win32.LiteDeployHostShellV1" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

namespace Win32
{
    public static class LiteDeployHostShellV1
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

        // 32/64-bit safe wrappers: pick the correct Ptr variant at runtime.
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

#region 3 - Pure logic and console helpers
# No Win32 P/Invoke in this region: math, data tables, and plain [Console]
# helpers that can be verified without touching the real window
# (see Test-LiteDeployHostShell.ps1, Section 1).

function Resolve-HostShellLayout {
    <#
    .SYNOPSIS
        Target window rectangle for a named screen position. Pure math helper
        for Set-HostShellWindow: percent->pixels, X/Y origin, screen clamping.
        UsingPercentSize in the result tells the caller to anchor the window
        before resizing (Console Host shifts the window otherwise).
    .EXAMPLE
        Resolve-HostShellLayout -Position Center -ScreenWidth 1920 -ScreenHeight 1080
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

        # Zero means use the fixed -Width value.
        [ValidateRange(0, 100)]
        [int]$WidthPercent = 0,

        # Zero means use the fixed -Height value.
        [ValidateRange(0, 100)]
        [int]$HeightPercent = 0,

        [ValidateRange(300, 4000)]
        [int]$Width = 1000,

        [ValidateRange(200, 3000)]
        [int]$Height = 700
    )

    $TargetWidth  = if ($WidthPercent  -gt 0) { [int]($ScreenWidth  * ($WidthPercent  / 100)) } else { $Width }
    $TargetHeight = if ($HeightPercent -gt 0) { [int]($ScreenHeight * ($HeightPercent / 100)) } else { $Height }

    # Keep dimensions inside the screen.
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
        New GWL_STYLE bitmask for a named window style. Pure bit-math helper
        for Set-HostShellWindowStyle: Normal restores OriginalStyle;
        Borderless drops caption+resize; Fixed keeps the title bar but drops
        resize+maximize; Minimal keeps the title bar but drops min/max buttons.
    .EXAMPLE
        Get-HostShellWindowStyleValue -WindowStyle Borderless -CurrentStyle $cur -OriginalStyle $orig
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

    # Standard window style flags (winuser.h).
    $WS_CAPTION     = 0x00C00000L  # Title bar (caption + border).
    $WS_SYSMENU     = 0x00080000L  # System menu on the title bar.
    $WS_THICKFRAME  = 0x00040000L  # Resizing border.
    $WS_MINIMIZEBOX = 0x00020000L  # Minimize button.
    $WS_MAXIMIZEBOX = 0x00010000L  # Maximize button.

    $NewStyle = switch ($WindowStyle) {
        "Normal"     { $OriginalStyle }
        "Borderless" { $CurrentStyle -band (-bnot $WS_CAPTION) -band (-bnot $WS_THICKFRAME) }
        "Fixed"      { ($CurrentStyle -bor $WS_CAPTION -bor $WS_SYSMENU) -band (-bnot $WS_THICKFRAME)  -band (-bnot $WS_MAXIMIZEBOX) }
        "Minimal"    { ($CurrentStyle -bor $WS_CAPTION -bor $WS_SYSMENU) -band (-bnot $WS_MINIMIZEBOX) -band (-bnot $WS_MAXIMIZEBOX) }
    }

    [long]$NewStyle
}

function Get-HostShellTheme {
    <#
    .SYNOPSIS
        Foreground/background colors for a named theme.
        To add a theme, add one line to the table - Set-HostShellTheme
        picks it up automatically.
    .EXAMPLE
        Get-HostShellTheme -Name LiteDeploy
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

function Get-TruncatedText {
    <#
    .SYNOPSIS
        Truncates text to a column width, ending with "..." when cut.
        Text that already fits is returned unchanged.
    .EXAMPLE
        Get-TruncatedText -Value "A very long task sequence name" -Width 12  # "A very lo..."
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [ValidateRange(4, 500)]
        [int]$Width
    )

    $Text = [string]$Value

    if ($Text.Length -le $Width) {
        return $Text
    }

    $Text.Substring(0, $Width - 3) + "..."
}

function Get-MaxTextLength {
    <#
    .SYNOPSIS
        Longest text length of one property across all rows, with a floor.
        Used by Select-LiteDeployTaskSequence to size table columns.
    .EXAMPLE
        Get-MaxTextLength -Rows $TaskSequences -Property Name -Minimum 20
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [string]$Property,

        [Parameter(Mandatory)]
        [int]$Minimum
    )

    [Math]::Max(
        $Minimum,
        [int](($Rows | ForEach-Object { ([string]$_.$Property).Length } | Measure-Object -Maximum).Maximum)
    )
}

function Clear-ConsoleRegion {
    <#
    .SYNOPSIS
        Blanks a block of console lines and parks the cursor at its top.
        Lets the selector redraw in place without Clear-Host flicker.
    .EXAMPLE
        Clear-ConsoleRegion -StartTop 5 -LineCount 12
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$StartTop,

        [Parameter(Mandatory)]
        [int]$LineCount
    )

    $BlankLine = " " * [Math]::Max(1, [Console]::BufferWidth - 1)

    for ($Line = 0; $Line -lt $LineCount; $Line++) {
        $TargetTop = $StartTop + $Line

        if ($TargetTop -ge [Console]::BufferHeight) {
            break
        }

        [Console]::SetCursorPosition(0, $TargetTop)
        Write-Host $BlankLine -NoNewline
    }

    [Console]::SetCursorPosition(0, $StartTop)
}

#endregion

#region 4 - Public functions: the toolkit API consumed by LiteDeploy.

function Set-HostShellWindow {
    <#
    .SYNOPSIS
        Controls the current console window: state, position, fixed or
        percentage-based size, always-on-top, title, and prompt.
    .DESCRIPTION
        Prompt behavior:
          -Prompt omitted  : leave the current prompt unchanged.
          -Prompt "."      : restore the standard location-based prompt.
          -Prompt ""       : clear the visible prompt.
          -Prompt "Text> " : set a custom prompt.
    .EXAMPLE
        Set-HostShellWindow -Action Minimize
    .EXAMPLE
        Set-HostShellWindow -Position Bottom -WidthPercent 60 -HeightPercent 30
    .EXAMPLE
        Set-HostShellWindow -Title "LiteDeploy Logs" -Prompt "" -AlwaysOnTop On
    #>
    [CmdletBinding()]
    param(
        [ValidateSet("None", "Minimize", "Restore", "Maximize", "Hide")]
        [string]$Action = "None",

        [ValidateSet("None", "Top", "TopLeft", "TopRight", "Center", "Bottom", "BottomLeft", "BottomRight")]
        [string]$Position = "None",

        [ValidateSet("None", "On", "Off")]
        [string]$AlwaysOnTop = "None",

        # Zero means use the fixed -Width value.
        [ValidateRange(0, 100)]
        [int]$WidthPercent = 0,

        # Zero means use the fixed -Height value.
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
        [string]$Prompt
    )

    # Change the title only when -Title was explicitly supplied.
    if ($PSBoundParameters.ContainsKey("Title")) {
        $Host.UI.RawUI.WindowTitle = $Title
    }

    # Change the prompt only when -Prompt was explicitly supplied.
    if ($PSBoundParameters.ContainsKey("Prompt")) {
        if ($Prompt -eq ".") {
            Remove-Variable -Name HostShellCustomPrompt -Scope Global -ErrorAction SilentlyContinue

            Set-Item -Path Function:\global:prompt -Value {
                "PS $($ExecutionContext.SessionState.Path.CurrentLocation)$('>' * ($NestedPromptLevel + 1)) "
            }
        }
        elseif ([string]::IsNullOrEmpty($Prompt)) {
            Remove-Variable -Name HostShellCustomPrompt -Scope Global -ErrorAction SilentlyContinue

            # A single space keeps the prompt visually empty but functional.
            Set-Item -Path Function:\global:prompt -Value { " " }
        }
        else {
            # The prompt scriptblock reads this global on every render, so
            # changing the variable later changes the visible prompt.
            $global:HostShellCustomPrompt = $Prompt

            Set-Item -Path Function:\global:prompt -Value { $global:HostShellCustomPrompt }
        }
    }

    $WindowHandle = [Win32.LiteDeployHostShellV1]::GetConsoleWindow()

    if ($WindowHandle -eq [IntPtr]::Zero) {
        throw "No console window is attached to this PowerShell process."
    }

    if ($Position -ne "None") {
        # Restore before moving or resizing (SW_RESTORE = 9).
        [Win32.LiteDeployHostShellV1]::ShowWindow($WindowHandle, 9) | Out-Null
        Start-Sleep -Milliseconds 100

        # Primary desktop resolution (SM_CXSCREEN = 0, SM_CYSCREEN = 1).
        $ScreenWidth  = [Win32.LiteDeployHostShellV1]::GetSystemMetrics(0)
        $ScreenHeight = [Win32.LiteDeployHostShellV1]::GetSystemMetrics(1)

        $Layout = Resolve-HostShellLayout `
            -Position $Position `
            -ScreenWidth $ScreenWidth `
            -ScreenHeight $ScreenHeight `
            -WidthPercent $WidthPercent `
            -HeightPercent $HeightPercent `
            -Width $Width `
            -Height $Height

        if ($Layout.UsingPercentSize) {
            # Console Host may shift the window when moving and resizing in
            # one call, so anchor at the target position first (no resize).
            # SWP_NOSIZE | SWP_NOZORDER | SWP_SHOWWINDOW
            $MoveOnlyFlags = 0x0001 -bor 0x0004 -bor 0x0040

            $Moved = [Win32.LiteDeployHostShellV1]::SetWindowPos(
                $WindowHandle, [IntPtr]::Zero, $Layout.X, $Layout.Y, 0, 0, $MoveOnlyFlags)

            if (-not $Moved) {
                Write-Warning "The console window could not be anchored at the requested position."
            }

            Start-Sleep -Milliseconds 120
        }

        # Apply final position and size (SWP_NOZORDER | SWP_SHOWWINDOW).
        $PositionFlags = 0x0004 -bor 0x0040

        $Positioned = [Win32.LiteDeployHostShellV1]::SetWindowPos(
            $WindowHandle, [IntPtr]::Zero, $Layout.X, $Layout.Y, $Layout.Width, $Layout.Height, $PositionFlags)

        if (-not $Positioned) {
            Write-Warning "The console window could not be positioned or resized."
        }
    }

    if ($AlwaysOnTop -ne "None") {
        # HWND_TOPMOST = -1, HWND_NOTOPMOST = -2.
        $InsertAfter = if ($AlwaysOnTop -eq "On") { [IntPtr](-1) } else { [IntPtr](-2) }

        # SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE
        $TopMostFlags = 0x0002 -bor 0x0001 -bor 0x0010

        $TopMostChanged = [Win32.LiteDeployHostShellV1]::SetWindowPos(
            $WindowHandle, $InsertAfter, 0, 0, 0, 0, $TopMostFlags)

        if (-not $TopMostChanged) {
            Write-Warning "Always-on-top mode could not be changed."
        }
    }

    $ShowCommand = switch ($Action) {
        "Hide"     { 0 }    # SW_HIDE
        "Maximize" { 3 }    # SW_MAXIMIZE
        "Minimize" { 6 }    # SW_MINIMIZE
        "Restore"  { 9 }    # SW_RESTORE
        default    { $null }
    }

    if ($null -ne $ShowCommand) {
        [Win32.LiteDeployHostShellV1]::ShowWindow($WindowHandle, $ShowCommand) | Out-Null
    }
}

function Set-HostShellWindowStyle {
    <#
    .SYNOPSIS
        Changes the frame style of the current console window: Normal
        (restores the session's original style), Borderless, Fixed, Minimal.
        The original style is captured once per session in
        $global:HostShellOriginalWindowStyle so Normal can restore it.
    .EXAMPLE
        Set-HostShellWindowStyle -WindowStyle Borderless
    #>
    [CmdletBinding()]
    param(
        [ValidateSet("Normal", "Borderless", "Fixed", "Minimal")]
        [string]$WindowStyle = "Normal"
    )

    $WindowHandle = [Win32.LiteDeployHostShellV1]::GetConsoleWindow()

    if ($WindowHandle -eq [IntPtr]::Zero) {
        throw "No console window is attached to this PowerShell process."
    }

    $GWL_STYLE = -16  # Index of the window's style bitmask.

    $CurrentStyle = [Win32.LiteDeployHostShellV1]::GetWindowStyle($WindowHandle, $GWL_STYLE).ToInt64()

    # Store the original style once for the current PowerShell session.
    if (-not (Get-Variable -Name HostShellOriginalWindowStyle -Scope Global -ErrorAction SilentlyContinue)) {
        $global:HostShellOriginalWindowStyle = $CurrentStyle
    }

    $NewStyle = Get-HostShellWindowStyleValue `
        -WindowStyle $WindowStyle `
        -CurrentStyle $CurrentStyle `
        -OriginalStyle $global:HostShellOriginalWindowStyle

    [Win32.LiteDeployHostShellV1]::SetWindowStyle($WindowHandle, $GWL_STYLE, [IntPtr]$NewStyle) | Out-Null

    # SetWindowLong can return zero even on success, so success is judged by
    # this frame refresh instead:
    # SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_SHOWWINDOW
    $FrameFlags = 0x0001 -bor 0x0002 -bor 0x0004 -bor 0x0010 -bor 0x0020 -bor 0x0040

    $FrameUpdated = [Win32.LiteDeployHostShellV1]::SetWindowPos($WindowHandle, [IntPtr]::Zero, 0, 0, 0, 0, $FrameFlags)

    if (-not $FrameUpdated) {
        throw "The console window frame could not be refreshed."
    }

    Write-Verbose "Console window style applied: $WindowStyle"
}

function Set-HostShellTheme {
    <#
    .SYNOPSIS
        Applies a color theme to the current console, from a named theme
        (-Theme) or explicit colors (-ForegroundColor/-BackgroundColor;
        an omitted custom color keeps the current one). -ClearScreen
        repaints the whole console; -ShowPreview prints a sample block.
    .EXAMPLE
        Set-HostShellTheme -Theme LiteDeploy -ClearScreen -ShowPreview
    .EXAMPLE
        Set-HostShellTheme -ForegroundColor Cyan -BackgroundColor Black -ClearScreen
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

    $Host.UI.RawUI.ForegroundColor = $Colors.Foreground
    $Host.UI.RawUI.BackgroundColor = $Colors.Background

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
        Writes a colored in-place progress bar. Repeated calls redraw on
        the same line; write a final newline (Write-Host) after the last
        call to move past the bar. WinPE-friendly: console colors only.
    .EXAMPLE
        1..100 | ForEach-Object { Write-HostShellProgress -Percent $_ }
        Write-Host
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

    # `r returns the cursor to the start of the line for in-place redraw.
    Write-Host "`r|" -NoNewline -ForegroundColor $TextColor

    if ($FilledWidth -gt 0) {
        Write-Host (" " * $FilledWidth) -NoNewline -ForegroundColor Black -BackgroundColor $CompletedColor
    }

    if ($EmptyWidth -gt 0) {
        Write-Host (" " * $EmptyWidth) -NoNewline -ForegroundColor Black -BackgroundColor $RemainingColor
    }

    Write-Host ("| {0,3}%" -f $Percent) -NoNewline -ForegroundColor $TextColor
}

function Select-LiteDeployTaskSequence {
    <#
    .SYNOPSIS
        Console task-sequence picker: aligned table, Up/Down arrows,
        Home/End, Enter to select, Escape to cancel. Returns the selected
        task-sequence object, or $null on Escape.
        WinPE-friendly: no WPF, WinForms, Out-GridView, HTA, or modules.
        Expected properties: Id, Name, Architecture, Version, Description,
        ImagePath, ImageIndex.
    .EXAMPLE
        $Selected = Select-LiteDeployTaskSequence -TaskSequences $TaskSequences
        if ($null -eq $Selected) { return }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [object[]]$TaskSequences,

        [string]$Title = "LiteDeploy Task Sequences"
    )

    if ($TaskSequences.Count -eq 0) {
        throw "No task sequences were provided."
    }

    $OriginalCursorVisible = [Console]::CursorVisible
    $SelectedIndex = 0
    $StartTop = [Console]::CursorTop
    $RenderedLineCount = 0

    try {
        [Console]::CursorVisible = $false

        # Column widths grow to fit the longest value in each column.
        $IdWidth           = Get-MaxTextLength -Rows $TaskSequences -Property Id           -Minimum 4
        $NameWidth         = Get-MaxTextLength -Rows $TaskSequences -Property Name         -Minimum 20
        $ArchitectureWidth = Get-MaxTextLength -Rows $TaskSequences -Property Architecture -Minimum 12
        $VersionWidth      = Get-MaxTextLength -Rows $TaskSequences -Property Version      -Minimum 8

        $AvailableWidth = [Math]::Max(80, [Console]::WindowWidth - 1)

        # 2 chars of padding per column, plus 2 for the selection marker.
        $FixedWidth = 2 + $IdWidth + 2 + $NameWidth + 2 + $ArchitectureWidth + 2 + $VersionWidth + 2

        # Description takes whatever width is left.
        $DescriptionWidth = [Math]::Max(20, $AvailableWidth - $FixedWidth)

        do {
            if ($RenderedLineCount -gt 0) {
                Clear-ConsoleRegion -StartTop $StartTop -LineCount $RenderedLineCount
            }

            [Console]::SetCursorPosition(0, $StartTop)

            Write-Host $Title -ForegroundColor Cyan
            Write-Host "Use Up/Down arrows, Enter to select, or Esc to cancel." -ForegroundColor DarkGray
            Write-Host

            $Header = (
                "  {0,-$IdWidth}  {1,-$NameWidth}  {2,-$ArchitectureWidth}  {3,-$VersionWidth}  {4,-$DescriptionWidth}" -f
                "ID", "Name", "Architecture", "Version", "Description"
            )

            Write-Host $Header -ForegroundColor White
            Write-Host ("-" * [Math]::Min($Header.Length, $AvailableWidth)) -ForegroundColor DarkGray

            for ($Index = 0; $Index -lt $TaskSequences.Count; $Index++) {
                $TaskSequence = $TaskSequences[$Index]

                $Marker = if ($Index -eq $SelectedIndex) { ">" } else { " " }

                $Row = (
                    "{0} {1,-$IdWidth}  {2,-$NameWidth}  {3,-$ArchitectureWidth}  {4,-$VersionWidth}  {5,-$DescriptionWidth}" -f
                    $Marker,
                    (Get-TruncatedText -Value $TaskSequence.Id           -Width $IdWidth),
                    (Get-TruncatedText -Value $TaskSequence.Name         -Width $NameWidth),
                    (Get-TruncatedText -Value $TaskSequence.Architecture -Width $ArchitectureWidth),
                    (Get-TruncatedText -Value $TaskSequence.Version      -Width $VersionWidth),
                    (Get-TruncatedText -Value $TaskSequence.Description  -Width $DescriptionWidth)
                )

                $Row = $Row.PadRight([Math]::Min($AvailableWidth, $Row.Length))

                if ($Index -eq $SelectedIndex) {
                    Write-Host $Row -ForegroundColor Black -BackgroundColor Cyan
                }
                else {
                    Write-Host $Row -ForegroundColor Gray -BackgroundColor Black
                }
            }

            Write-Host
            Write-Host "Selected:" -NoNewline -ForegroundColor DarkGray
            Write-Host " $($TaskSequences[$SelectedIndex].Name)" -ForegroundColor Cyan

            Write-Host "Image:" -NoNewline -ForegroundColor DarkGray
            Write-Host " $($TaskSequences[$SelectedIndex].ImagePath)" -ForegroundColor Gray

            Write-Host "Index:" -NoNewline -ForegroundColor DarkGray
            Write-Host " $($TaskSequences[$SelectedIndex].ImageIndex)" -ForegroundColor Gray

            $RenderedLineCount = 8 + $TaskSequences.Count

            $Key = [Console]::ReadKey($true)

            switch ($Key.Key) {
                "UpArrow" {
                    # Wrap around at the top.
                    if ($SelectedIndex -gt 0) { $SelectedIndex-- } else { $SelectedIndex = $TaskSequences.Count - 1 }
                }
                "DownArrow" {
                    # Wrap around at the bottom.
                    if ($SelectedIndex -lt ($TaskSequences.Count - 1)) { $SelectedIndex++ } else { $SelectedIndex = 0 }
                }
                "Home"   { $SelectedIndex = 0 }
                "End"    { $SelectedIndex = $TaskSequences.Count - 1 }
                "Enter"  { return $TaskSequences[$SelectedIndex] }
                "Escape" { return $null }
            }
        }
        while ($true)
    }
    finally {
        [Console]::CursorVisible = $OriginalCursorVisible

        # Park the cursor below the picker so follow-up output does not overwrite it.
        if ($RenderedLineCount -gt 0) {
            [Console]::SetCursorPosition(0, [Math]::Min([Console]::BufferHeight - 1, $StartTop + $RenderedLineCount))
        }
    }
}

#endregion
