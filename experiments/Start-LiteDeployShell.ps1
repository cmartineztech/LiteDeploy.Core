<#
.SYNOPSIS
    Launches a LiteDeploy HostShell window with a named behavior preset.

.DESCRIPTION
    Applies a HostShell preset (theme, frame style, position, size, title,
    prompt) to THIS console window, then optionally runs an engine script.

    This is the entry point WinPE should launch (winpeshl.ini / startnet.cmd).
    Preset names are validated against the supported HostShell presets.

.EXAMPLE
    powershell.exe -NoExit -ExecutionPolicy Bypass -File Start-LiteDeployShell.ps1 -Preset Main

    Interactive shell window with the Main preset (keep -NoExit for
    interactive use; omit it when -Script runs the whole flow).

.EXAMPLE
    .\Start-LiteDeployShell.ps1 -Preset Main -Script X:\LiteDeploy\LiteDeploy-PreCheck.ps1

    Applies the preset, then runs the LiteDeploy system pre-check engine script.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Main", "Full", "Logs", "Picker")]
    [string]$Preset = "Main",

    # Optional engine script to run after the preset is applied.
    [Parameter(Mandatory = $false)]
    [string]$Script,

    # Optional parameters to pass to the engine script.
    [Parameter(Mandatory = $false)]
    [string]$ScriptArgs,

    # Auto-detect and run LiteDeploy-PreCheck.ps1 if no script is specified.
    [Parameter(Mandatory = $false)]
    [switch]$AutoPreCheck
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

# Determine script to execute
$TargetScript = $Script

if ([string]::IsNullOrWhiteSpace($TargetScript) -and $AutoPreCheck) {
    $PreCheckPath = Join-Path $PSScriptRoot "LiteDeploy-PreCheck.ps1"
    if (Test-Path -LiteralPath $PreCheckPath -PathType Leaf) {
        $TargetScript = $PreCheckPath
    }
}

if ($TargetScript) {
    if (-not (Test-Path -LiteralPath $TargetScript -PathType Leaf)) {
        throw "Engine script not found: $TargetScript"
    }

    if (-not [string]::IsNullOrWhiteSpace($ScriptArgs)) {
        Invoke-Expression "& `"$TargetScript`" $ScriptArgs"
    }
    else {
        & $TargetScript
    }
}
