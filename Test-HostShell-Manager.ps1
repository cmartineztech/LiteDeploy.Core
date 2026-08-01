<#
.SYNOPSIS
    Interactive test suite for HostShell-Manager.ps1.

.DESCRIPTION
    Tests window actions, all positions, fixed sizing, percentage sizing,
    title, prompt customization, and always-on-top mode.

    Hide is intentionally excluded.
#>

[CmdletBinding()]
param(
    [string]$ManagerPath = (Join-Path $PSScriptRoot "HostShell-Manager.ps1"),

    [ValidateRange(1, 30)]
    [int]$DelaySeconds = 3
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ManagerPath -PathType Leaf)) {
    throw "HostShell manager not found: $ManagerPath"
}

function Invoke-HostShellTest {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [hashtable]$Arguments,

        [int]$Delay = $DelaySeconds
    )

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "TEST: $Name"
    Write-Host "============================================================"

    & $ManagerPath @Arguments

    Start-Sleep -Seconds $Delay
}

try {
    Write-Host "Starting HostShell-Manager test suite."
    Write-Host "Hide is excluded."
    Start-Sleep -Seconds 2

    Invoke-HostShellTest -Name "Set title and custom prompt" -Arguments @{
        Title  = "HostShell Manager Test"
        Prompt = "HostShell-Test> "
    }

    Invoke-HostShellTest -Name "Restore and center with fixed size" -Arguments @{
        Action   = "Restore"
        Position = "Center"
        Width    = 1000
        Height   = 700
    }

    Invoke-HostShellTest -Name "Top with fixed size" -Arguments @{
        Position = "Top"
        Width    = 900
        Height   = 500
    }

    Invoke-HostShellTest -Name "Top-left with fixed size" -Arguments @{
        Position = "TopLeft"
        Width    = 850
        Height   = 550
    }

    Invoke-HostShellTest -Name "Top-right with fixed size" -Arguments @{
        Position = "TopRight"
        Width    = 850
        Height   = 550
    }

    Invoke-HostShellTest -Name "Bottom with fixed size" -Arguments @{
        Position = "Bottom"
        Width    = 900
        Height   = 500
    }

    Invoke-HostShellTest -Name "Bottom-left with fixed size" -Arguments @{
        Position = "BottomLeft"
        Width    = 850
        Height   = 550
    }

    Invoke-HostShellTest -Name "Bottom-right with fixed size" -Arguments @{
        Position = "BottomRight"
        Width    = 850
        Height   = 550
    }

    Invoke-HostShellTest -Name "Top-left at 25 percent width and full height" -Arguments @{
        Position      = "TopLeft"
        WidthPercent  = 25
        HeightPercent = 100
    }

    Invoke-HostShellTest -Name "Top-right at 25 percent width and full height" -Arguments @{
        Position      = "TopRight"
        WidthPercent  = 25
        HeightPercent = 100
    }

    Invoke-HostShellTest -Name "Centered at 60 percent width and 70 percent height" -Arguments @{
        Position      = "Center"
        WidthPercent  = 60
        HeightPercent = 70
    }

    Invoke-HostShellTest -Name "Bottom at 60 percent width and 30 percent height" -Arguments @{
        Position      = "Bottom"
        WidthPercent  = 60
        HeightPercent = 30
    }

    Invoke-HostShellTest -Name "Always on top enabled" -Arguments @{
        AlwaysOnTop = "On"
        Title       = "Always On Top Test"
    }

    Invoke-HostShellTest -Name "Always on top disabled" -Arguments @{
        AlwaysOnTop = "Off"
    }

    Invoke-HostShellTest -Name "Maximize" -Arguments @{
        Action = "Maximize"
    }

    Invoke-HostShellTest -Name "Restore after maximize" -Arguments @{
        Action        = "Restore"
        Position      = "Center"
        WidthPercent  = 60
        HeightPercent = 70
    }

    Write-Host ""
    Write-Host "The window will minimize for $DelaySeconds seconds and restore automatically."
    Start-Sleep -Seconds 2

    & $ManagerPath -Action Minimize
    Start-Sleep -Seconds $DelaySeconds
    & $ManagerPath -Action Restore -Position Center -WidthPercent 60 -HeightPercent 70

    Invoke-HostShellTest -Name "Clear visible prompt" -Arguments @{
        Prompt = ""
        Title  = "Prompt Cleared"
    }

    Invoke-HostShellTest -Name "Restore standard PowerShell prompt" -Arguments @{
        Prompt = "."
        Title  = "Windows PowerShell"
    }

    & $ManagerPath `
        -Action Restore `
        -Position Center `
        -Width 1000 `
        -Height 700 `
        -AlwaysOnTop Off `
        -Prompt "." `
        -Title "Windows PowerShell"

    Write-Host ""
    Write-Host "All HostShell-Manager tests completed."
}
catch {
    Write-Error $_

    # Best-effort recovery.
    & $ManagerPath `
        -Action Restore `
        -Position Center `
        -Width 1000 `
        -Height 700 `
        -AlwaysOnTop Off `
        -Prompt "." `
        -Title "Windows PowerShell" `
        -ErrorAction SilentlyContinue

    exit 1
}
