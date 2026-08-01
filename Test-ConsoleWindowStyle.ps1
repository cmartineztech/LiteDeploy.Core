<#
.SYNOPSIS
    Tests different classic Console Host window styles.

.DESCRIPTION
    Changes the style of the current PowerShell console window.

    Supported styles:

    Normal
        Restores the original console style.

    Borderless
        Removes the title bar and resize border.

    Fixed
        Keeps the title bar but disables resizing and removes
        the maximize button.

    Minimal
        Keeps the title bar but removes the minimize and
        maximize buttons.

.NOTES
    Designed for classic Windows Console Host and Windows PE.
    Windows Terminal is not supported reliably.

.EXAMPLE
    .\Test-ConsoleWindowStyle.ps1 -WindowStyle Borderless

.EXAMPLE
    .\Test-ConsoleWindowStyle.ps1 -WindowStyle Normal
#>

[CmdletBinding()]
param(
    [ValidateSet(
        "Normal",
        "Borderless",
        "Fixed",
        "Minimal"
    )]
    [string]$WindowStyle = "Normal"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if ($env:WT_SESSION) {
    Write-Warning "Windows Terminal detected. Run this in classic Console Host or Windows PE."
}

if (-not ("Win32.ConsoleStyleTestV1" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

namespace Win32
{
    public static class ConsoleStyleTestV1
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr", SetLastError = true)]
        public static extern IntPtr GetWindowLongPtr64(
            IntPtr hWnd,
            int nIndex
        );

        [DllImport("user32.dll", EntryPoint = "GetWindowLong", SetLastError = true)]
        public static extern IntPtr GetWindowLongPtr32(
            IntPtr hWnd,
            int nIndex
        );

        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr", SetLastError = true)]
        public static extern IntPtr SetWindowLongPtr64(
            IntPtr hWnd,
            int nIndex,
            IntPtr dwNewLong
        );

        [DllImport("user32.dll", EntryPoint = "SetWindowLong", SetLastError = true)]
        public static extern IntPtr SetWindowLongPtr32(
            IntPtr hWnd,
            int nIndex,
            IntPtr dwNewLong
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

        public static IntPtr GetWindowStyle(
            IntPtr hWnd,
            int nIndex
        )
        {
            if (IntPtr.Size == 8)
            {
                return GetWindowLongPtr64(hWnd, nIndex);
            }

            return GetWindowLongPtr32(hWnd, nIndex);
        }

        public static IntPtr SetWindowStyle(
            IntPtr hWnd,
            int nIndex,
            IntPtr newStyle
        )
        {
            if (IntPtr.Size == 8)
            {
                return SetWindowLongPtr64(hWnd, nIndex, newStyle);
            }

            return SetWindowLongPtr32(hWnd, nIndex, newStyle);
        }
    }
}
"@
}

$WindowHandle = [Win32.ConsoleStyleTestV1]::GetConsoleWindow()

if ($WindowHandle -eq [IntPtr]::Zero) {
    throw "No console window is attached to this PowerShell process."
}

# Window style index.
$GWL_STYLE = -16

# Standard window style flags.
$WS_CAPTION     = 0x00C00000L
$WS_THICKFRAME  = 0x00040000L
$WS_MINIMIZEBOX = 0x00020000L
$WS_MAXIMIZEBOX = 0x00010000L
$WS_SYSMENU     = 0x00080000L

# Read the current style.
$CurrentStylePointer = [Win32.ConsoleStyleTestV1]::GetWindowStyle(
    $WindowHandle,
    $GWL_STYLE
)

$CurrentStyle = $CurrentStylePointer.ToInt64()

# Store the original style once for the current PowerShell session.
if (-not (Get-Variable -Name ConsoleOriginalWindowStyle -Scope Global -ErrorAction SilentlyContinue)) {
    $global:ConsoleOriginalWindowStyle = $CurrentStyle
}

switch ($WindowStyle) {
    "Normal" {
        $NewStyle = $global:ConsoleOriginalWindowStyle
    }

    "Borderless" {
        $NewStyle = $CurrentStyle

        $NewStyle = $NewStyle -band (-bnot $WS_CAPTION)
        $NewStyle = $NewStyle -band (-bnot $WS_THICKFRAME)
    }

    "Fixed" {
        $NewStyle = $CurrentStyle

        # Keep the title bar and system menu.
        $NewStyle = $NewStyle -bor $WS_CAPTION
        $NewStyle = $NewStyle -bor $WS_SYSMENU

        # Remove resizing and maximize support.
        $NewStyle = $NewStyle -band (-bnot $WS_THICKFRAME)
        $NewStyle = $NewStyle -band (-bnot $WS_MAXIMIZEBOX)
    }

    "Minimal" {
        $NewStyle = $CurrentStyle

        # Keep the title bar and system menu.
        $NewStyle = $NewStyle -bor $WS_CAPTION
        $NewStyle = $NewStyle -bor $WS_SYSMENU

        # Remove minimize and maximize buttons.
        $NewStyle = $NewStyle -band (-bnot $WS_MINIMIZEBOX)
        $NewStyle = $NewStyle -band (-bnot $WS_MAXIMIZEBOX)
    }
}

$SetResult = [Win32.ConsoleStyleTestV1]::SetWindowStyle(
    $WindowHandle,
    $GWL_STYLE,
    [IntPtr]$NewStyle
)

# SetWindowLong can return zero even when successful.
# Force Windows to recalculate and redraw the frame.
$SWP_NOSIZE       = 0x0001
$SWP_NOMOVE       = 0x0002
$SWP_NOZORDER     = 0x0004
$SWP_NOACTIVATE   = 0x0010
$SWP_FRAMECHANGED = 0x0020
$SWP_SHOWWINDOW   = 0x0040

$FrameFlags = (
    $SWP_NOSIZE       -bor
    $SWP_NOMOVE       -bor
    $SWP_NOZORDER     -bor
    $SWP_NOACTIVATE   -bor
    $SWP_FRAMECHANGED -bor
    $SWP_SHOWWINDOW
)

$FrameUpdated = [Win32.ConsoleStyleTestV1]::SetWindowPos(
    $WindowHandle,
    [IntPtr]::Zero,
    0,
    0,
    0,
    0,
    $FrameFlags
)

if (-not $FrameUpdated) {
    throw "The console window frame could not be refreshed."
}

Write-Host "Console window style applied: $WindowStyle"