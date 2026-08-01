<#
.SYNOPSIS
    Launches a LiteDeploy HostShell window with a named behavior preset.

.DESCRIPTION
    Applies a HostShell preset (theme, frame style, position, size, title,
    prompt) to THIS console window, then optionally runs an engine script.

    This is the entry point WinPE should launch (winpeshl.ini / startnet.cmd).
    Preset names are validated by the toolkit (Get-HostShellPreset), which
    is the single source of truth for the list.

.EXAMPLE
    powershell.exe -NoExit -ExecutionPolicy Bypass -File Start-LiteDeployShell.ps1 -Preset Main

    Interactive shell window with the Main preset (keep -NoExit for
    interactive use; omit it when -Script runs the whole flow).

.EXAMPLE
    .\Start-LiteDeployShell.ps1 -Preset Main -Script X:\LiteDeploy\Engine.ps1

    Applies the preset, then runs the engine script.
#>

[CmdletBinding()]
param(
    [string]$Preset = "Main",

    # Optional engine script to run after the preset is applied.
    [string]$Script
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$ToolkitPath = Join-Path $PSScriptRoot "LiteDeploy-HostShell.ps1"

if (-not (Test-Path -LiteralPath $ToolkitPath -PathType Leaf)) {
    throw "HostShell toolkit not found next to this launcher: $ToolkitPath"
}

. $ToolkitPath

# A window-setup failure must never leave WinPE without a usable shell.
try {
    Set-HostShellPreset -Name $Preset
}
catch {
    Write-Warning "HostShell preset '$Preset' could not be applied: $_"
}

if ($Script) {
    if (-not (Test-Path -LiteralPath $Script -PathType Leaf)) {
        throw "Engine script not found: $Script"
    }

    & $Script
}
