<#
.SYNOPSIS
    Displays a simple colored progress bar in PowerShell.

.DESCRIPTION
    Writes a WinPE-friendly progress bar using standard console colors,
    vertical bar boundaries, and no external dependencies.

.EXAMPLE
    .\PShell-ProgressBar.ps1 -Percent 50

.EXAMPLE
    .\PShell-ProgressBar.ps1 -Demo
#>

[CmdletBinding()]
param(
    [ValidateRange(0, 100)]
    [int]$Percent = 0,

    [ValidateRange(10, 100)]
    [int]$Width = 40,

    [ConsoleColor]$CompletedColor = [ConsoleColor]::Green,

    [ConsoleColor]$RemainingColor = [ConsoleColor]::DarkGray,

    [ConsoleColor]$TextColor = [ConsoleColor]::Gray,

    [switch]$Demo
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Write-PShellProgressBar {
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

    $FilledWidth = [int][Math]::Round(
        $Width * ($Percent / 100)
    )

    $EmptyWidth = $Width - $FilledWidth

    $Filled = " " * $FilledWidth
    $Empty  = " " * $EmptyWidth

    Write-Host "`r|" -NoNewline -ForegroundColor $TextColor

    if ($FilledWidth -gt 0) {
        Write-Host $Filled `
            -NoNewline `
            -ForegroundColor Black `
            -BackgroundColor $CompletedColor
    }

    if ($EmptyWidth -gt 0) {
        Write-Host $Empty `
            -NoNewline `
            -ForegroundColor Black `
            -BackgroundColor $RemainingColor
    }

    Write-Host ("| {0,3}%" -f $Percent) `
        -NoNewline `
        -ForegroundColor $TextColor
}

if ($Demo) {
    for ($CurrentPercent = 0; $CurrentPercent -le 100; $CurrentPercent += 5) {
        Write-PShellProgressBar `
            -Percent $CurrentPercent `
            -Width $Width `
            -CompletedColor $CompletedColor `
            -RemainingColor $RemainingColor `
            -TextColor $TextColor

        Start-Sleep -Milliseconds 150
    }

    Write-Host
}
else {
    Write-PShellProgressBar `
        -Percent $Percent `
        -Width $Width `
        -CompletedColor $CompletedColor `
        -RemainingColor $RemainingColor `
        -TextColor $TextColor

    Write-Host
}
