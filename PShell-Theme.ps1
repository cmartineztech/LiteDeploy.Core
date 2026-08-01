<#
.SYNOPSIS
    Applies a modern color theme to the current PowerShell console.

.DESCRIPTION
    Changes classic Console Host foreground and background colors and can
    clear the screen so the entire console is repainted.

    Designed for Windows PowerShell, classic Console Host, and Windows PE.

.EXAMPLE
    .\PShell-Theme.ps1 -Theme LiteDeploy -ClearScreen -ShowPreview

.EXAMPLE
    .\PShell-Theme.ps1 -ForegroundColor Cyan -BackgroundColor Black -ClearScreen
#>

[CmdletBinding(DefaultParameterSetName = "Theme")]
param(
    [Parameter(ParameterSetName = "Theme")]
    [ValidateSet(
        "LiteDeploy",
        "Midnight",
        "Slate",
        "Ocean",
        "HighContrast",
        "Default"
    )]
    [string]$Theme = "LiteDeploy",

    [Parameter(ParameterSetName = "Custom")]
    [ValidateSet(
        "Black","DarkBlue","DarkGreen","DarkCyan","DarkRed","DarkMagenta",
        "DarkYellow","Gray","DarkGray","Blue","Green","Cyan","Red",
        "Magenta","Yellow","White"
    )]
    [string]$ForegroundColor,

    [Parameter(ParameterSetName = "Custom")]
    [ValidateSet(
        "Black","DarkBlue","DarkGreen","DarkCyan","DarkRed","DarkMagenta",
        "DarkYellow","Gray","DarkGray","Blue","Green","Cyan","Red",
        "Magenta","Yellow","White"
    )]
    [string]$BackgroundColor,

    [switch]$ClearScreen,
    [switch]$ShowPreview
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Set-PShellColors {
    param(
        [Parameter(Mandatory)]
        [ConsoleColor]$Foreground,

        [Parameter(Mandatory)]
        [ConsoleColor]$Background,

        [switch]$Clear
    )

    $Host.UI.RawUI.ForegroundColor = $Foreground
    $Host.UI.RawUI.BackgroundColor = $Background

    if ($Clear) {
        Clear-Host
    }
}

if ($PSCmdlet.ParameterSetName -eq "Custom") {
    if (-not $PSBoundParameters.ContainsKey("ForegroundColor")) {
        $ForegroundColor = $Host.UI.RawUI.ForegroundColor.ToString()
    }

    if (-not $PSBoundParameters.ContainsKey("BackgroundColor")) {
        $BackgroundColor = $Host.UI.RawUI.BackgroundColor.ToString()
    }

    Set-PShellColors `
        -Foreground ([ConsoleColor]$ForegroundColor) `
        -Background ([ConsoleColor]$BackgroundColor) `
        -Clear:$ClearScreen
}
else {
    switch ($Theme) {
        "LiteDeploy" {
            Set-PShellColors -Foreground White -Background DarkBlue -Clear:$ClearScreen
        }

        "Midnight" {
            Set-PShellColors -Foreground Gray -Background Black -Clear:$ClearScreen
        }

        "Slate" {
            Set-PShellColors -Foreground White -Background DarkGray -Clear:$ClearScreen
        }

        "Ocean" {
            Set-PShellColors -Foreground Cyan -Background DarkBlue -Clear:$ClearScreen
        }

        "HighContrast" {
            Set-PShellColors -Foreground Yellow -Background Black -Clear:$ClearScreen
        }

        "Default" {
            Set-PShellColors -Foreground Gray -Background Black -Clear:$ClearScreen
        }
    }
}

if ($ShowPreview) {
    Write-Host ""
    Write-Host " PShell Theme Preview " -ForegroundColor Black -BackgroundColor Cyan
    Write-Host ""
    Write-Host "LiteDeploy shell theme applied successfully."
    Write-Host "Foreground: $($Host.UI.RawUI.ForegroundColor)"
    Write-Host "Background: $($Host.UI.RawUI.BackgroundColor)"
    Write-Host ""
    Write-Host "[INFO]  Deployment environment initialized." -ForegroundColor Cyan
    Write-Host "[OK]    Network connectivity confirmed." -ForegroundColor Green
    Write-Host "[WARN]  Driver package not yet selected." -ForegroundColor Yellow
    Write-Host "[ERROR] Example error message." -ForegroundColor Red
    Write-Host ""
}
