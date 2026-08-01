<#
.SYNOPSIS
    Controls the current PowerShell console window.

.DESCRIPTION
    Supports window state, positioning, fixed or percentage-based sizing,
    always-on-top mode, window title, and PowerShell prompt customization.

.NOTES
    Designed for Windows Console Host and Windows PE.
    Windows Terminal uses a pseudoconsole, so window controls may not affect
    the visible Terminal window correctly.

.PROMPT BEHAVIOR
    Parameter omitted : Leave the current prompt unchanged.
    -Prompt "."       : Restore the standard location-based PowerShell prompt.
    -Prompt ""        : Clear the visible prompt.
    -Prompt "Text> "  : Set a custom prompt.

.EXAMPLE
    .\HostShell-Manager.ps1 -Action Minimize

.EXAMPLE
    .\HostShell-Manager.ps1 -Position TopLeft -WidthPercent 25 -HeightPercent 100

.EXAMPLE
    .\HostShell-Manager.ps1 -Position Bottom -WidthPercent 60 -HeightPercent 30

.EXAMPLE
    .\HostShell-Manager.ps1 -Title "LiteDeploy Logs" -Prompt "" -AlwaysOnTop On
#>

[CmdletBinding()]
param(
    [ValidateSet(
        "None",
        "Minimize",
        "Restore",
        "Maximize",
        "Hide"
    )]
    [string]$Action = "None",

    [ValidateSet(
        "None",
        "Top",
        "TopLeft",
        "TopRight",
        "Center",
        "Bottom",
        "BottomLeft",
        "BottomRight"
    )]
    [string]$Position = "None",

    [ValidateSet(
        "None",
        "On",
        "Off"
    )]
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

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if ($env:WT_SESSION) {
    Write-Warning "Windows Terminal detected. Use Windows Console Host or Windows PE for reliable window control."
}

# Add-Type definitions cannot be replaced in the same PowerShell session.
# Change the class name if these native declarations are modified later.
if (-not ("Win32.HostShellManagerV7" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

namespace Win32
{
    public static class HostShellManagerV7
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool ShowWindow(
            IntPtr hWnd,
            int nCmdShow
        );

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetWindowPos(
            IntPtr hWnd,
            IntPtr hWndInsertAfter,
            int X,
            int Y,
            int cx,
            int cy,
            uint uFlags
        );

        [DllImport("user32.dll")]
        public static extern int GetSystemMetrics(
            int nIndex
        );
    }
}
"@
}

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

        Set-Item -Path Function:\global:prompt -Value {
            " "
        }
    }
    else {
        $global:HostShellCustomPrompt = $Prompt

        Set-Item -Path Function:\global:prompt -Value {
            $global:HostShellCustomPrompt
        }
    }
}

$WindowHandle = [Win32.HostShellManagerV7]::GetConsoleWindow()

if ($WindowHandle -eq [IntPtr]::Zero) {
    throw "No console window is attached to this PowerShell process."
}

if ($Position -ne "None") {
    # Restore before moving or resizing.
    [Win32.HostShellManagerV7]::ShowWindow($WindowHandle, 9) | Out-Null
    Start-Sleep -Milliseconds 100

    # Current primary desktop resolution.
    $ScreenWidth  = [Win32.HostShellManagerV7]::GetSystemMetrics(0)
    $ScreenHeight = [Win32.HostShellManagerV7]::GetSystemMetrics(1)

    $TargetWidth = if ($WidthPercent -gt 0) {
        [int]($ScreenWidth * ($WidthPercent / 100))
    }
    else {
        $Width
    }

    $TargetHeight = if ($HeightPercent -gt 0) {
        [int]($ScreenHeight * ($HeightPercent / 100))
    }
    else {
        $Height
    }

    # Keep dimensions inside the primary desktop.
    $TargetWidth  = [Math]::Min([Math]::Max(1, $TargetWidth), $ScreenWidth)
    $TargetHeight = [Math]::Min([Math]::Max(1, $TargetHeight), $ScreenHeight)

    switch ($Position) {
        "Top" {
            $X = [int](($ScreenWidth - $TargetWidth) / 2)
            $Y = 0
        }
        "TopLeft" {
            $X = 0
            $Y = 0
        }
        "TopRight" {
            $X = $ScreenWidth - $TargetWidth
            $Y = 0
        }
        "Center" {
            $X = [int](($ScreenWidth - $TargetWidth) / 2)
            $Y = [int](($ScreenHeight - $TargetHeight) / 2)
        }
        "Bottom" {
            $X = [int](($ScreenWidth - $TargetWidth) / 2)
            $Y = $ScreenHeight - $TargetHeight
        }
        "BottomLeft" {
            $X = 0
            $Y = $ScreenHeight - $TargetHeight
        }
        "BottomRight" {
            $X = $ScreenWidth - $TargetWidth
            $Y = $ScreenHeight - $TargetHeight
        }
    }

    $X = [Math]::Max(0, $X)
    $Y = [Math]::Max(0, $Y)

    $UsingPercentSize = ($WidthPercent -gt 0) -or ($HeightPercent -gt 0)

    if ($UsingPercentSize) {
        # Console Host may shift the window when moving and resizing in one call.
        # First anchor it at the requested position without changing its size.
        # SWP_NOSIZE | SWP_NOZORDER | SWP_SHOWWINDOW
        $MoveOnlyFlags = 0x0001 -bor 0x0004 -bor 0x0040

        $Moved = [Win32.HostShellManagerV7]::SetWindowPos(
            $WindowHandle,
            [IntPtr]::Zero,
            $X,
            $Y,
            0,
            0,
            $MoveOnlyFlags
        )

        if (-not $Moved) {
            Write-Warning "The console window could not be anchored at the requested position."
        }

        Start-Sleep -Milliseconds 120
    }

    # Apply final position and size.
    # SWP_NOZORDER | SWP_SHOWWINDOW
    $PositionFlags = 0x0004 -bor 0x0040

    $Positioned = [Win32.HostShellManagerV7]::SetWindowPos(
        $WindowHandle,
        [IntPtr]::Zero,
        $X,
        $Y,
        $TargetWidth,
        $TargetHeight,
        $PositionFlags
    )

    if (-not $Positioned) {
        Write-Warning "The console window could not be positioned or resized."
    }
}

if ($AlwaysOnTop -ne "None") {
    # HWND_TOPMOST = -1
    # HWND_NOTOPMOST = -2
    $InsertAfter = if ($AlwaysOnTop -eq "On") {
        [IntPtr](-1)
    }
    else {
        [IntPtr](-2)
    }

    # SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE
    $TopMostFlags = 0x0002 -bor 0x0001 -bor 0x0010

    $TopMostChanged = [Win32.HostShellManagerV7]::SetWindowPos(
        $WindowHandle,
        $InsertAfter,
        0,
        0,
        0,
        0,
        $TopMostFlags
    )

    if (-not $TopMostChanged) {
        Write-Warning "Always-on-top mode could not be changed."
    }
}

$ShowCommand = switch ($Action) {
    "Hide"     { 0 } # SW_HIDE
    "Maximize" { 3 } # SW_MAXIMIZE
    "Minimize" { 6 } # SW_MINIMIZE
    "Restore"  { 9 } # SW_RESTORE
    default    { $null }
}

if ($null -ne $ShowCommand) {
    [Win32.HostShellManagerV7]::ShowWindow(
        $WindowHandle,
        $ShowCommand
    ) | Out-Null
}
