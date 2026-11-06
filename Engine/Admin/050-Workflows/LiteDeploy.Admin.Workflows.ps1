<#
.SYNOPSIS
    LiteDeploy Admin Workflows - workflow JSON authoring (architecture v2).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ShareRoot = "",

    [Parameter(Mandatory = $false)]
    [switch]$Metadata
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Get-LiteDeployComponentMetadata {
    return [PSCustomObject]@{
        ComponentId          = "Admin.Workflows"
        Name                 = "LiteDeploy Admin Workflows"
        Version              = "2.0.0"
        Category             = "Admin"
        TargetEnvironment    = "Host"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("Logs", "Workflow")
        Description          = "Create/edit/validate WorkFlows\\*.json definitions and action ordering."
    }
}

if ($Metadata) { Get-LiteDeployComponentMetadata; return }

function Get-LiteDeployAdminWorkflows {
    param([Parameter(Mandatory = $true)][string]$ShareRoot)
    $dir = Join-Path $ShareRoot "WorkFlows"
    $list = @()
    if (-not (Test-Path -LiteralPath $dir)) { return $list }
    Get-ChildItem -Path $dir -Filter "*.json" -File | ForEach-Object {
        try {
            $def = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
            $list += [PSCustomObject]@{
                Name = if ($def.name) { $def.name } elseif ($def.Name) { $def.Name } else { $_.BaseName }
                Path = $_.FullName
                Definition = $def
            }
        }
        catch {}
    }
    return $list
}

function Test-LiteDeployAdminWorkflows {
    param([Parameter(Mandatory = $true)][string]$ShareRoot)
    $wfs = @(Get-LiteDeployAdminWorkflows -ShareRoot $ShareRoot)
    $errors = @()
    foreach ($w in $wfs) {
        if (-not $w.Name) { $errors += "Workflow missing name: $($w.Path)" }
    }
    return [PSCustomObject]@{
        Passed = ($errors.Count -eq 0)
        Count  = $wfs.Count
        Errors = $errors
        Workflows = $wfs
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($ShareRoot)) {
        Get-LiteDeployComponentMetadata | Format-List
        return
    }
    Test-LiteDeployAdminWorkflows -ShareRoot $ShareRoot | Format-List
}
