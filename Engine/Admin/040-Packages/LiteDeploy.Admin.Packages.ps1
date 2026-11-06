<#
.SYNOPSIS
    LiteDeploy Admin Packages - package definition management (architecture v2).
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
        ComponentId          = "Admin.Packages"
        Name                 = "LiteDeploy Admin Packages"
        Version              = "2.0.0"
        Category             = "Admin"
        TargetEnvironment    = "Host"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("Logs", "Packages")
        Description          = "Create/edit/validate package.json definitions under Content\\Packages."
    }
}

if ($Metadata) { Get-LiteDeployComponentMetadata; return }

function Get-LiteDeployAdminPackages {
    param([Parameter(Mandatory = $true)][string]$ShareRoot)
    $root = Join-Path $ShareRoot "Content\Packages"
    $list = @()
    if (-not (Test-Path -LiteralPath $root)) { return $list }
    Get-ChildItem -Path $root -Directory | ForEach-Object {
        $json = Join-Path $_.FullName "package.json"
        if (Test-Path -LiteralPath $json) {
            $def = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
            $list += [PSCustomObject]@{
                PackageId = if ($def.packageId) { $def.packageId } else { $_.Name }
                Name      = if ($def.name) { $def.name } else { $_.Name }
                Path      = $_.FullName
                Definition = $def
            }
        }
    }
    return $list
}

function Test-LiteDeployAdminPackages {
    param([Parameter(Mandatory = $true)][string]$ShareRoot)
    $pkgs = @(Get-LiteDeployAdminPackages -ShareRoot $ShareRoot)
    $warnings = @()
    foreach ($p in $pkgs) {
        if (-not $p.Definition.PSObject.Properties['command'] -and -not (Test-Path (Join-Path $p.Path "payload\Install.ps1"))) {
            $warnings += "Package $($p.PackageId) has no command or Install.ps1"
        }
    }
    return [PSCustomObject]@{ Passed = $true; Count = $pkgs.Count; Warnings = $warnings; Packages = $pkgs }
}

function New-LiteDeployAdminPackage {
    param(
        [Parameter(Mandatory = $true)][string]$ShareRoot,
        [Parameter(Mandatory = $true)][string]$PackageId,
        [string]$Name = "",
        [string]$PackageType = "Script"
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = $PackageId }
    $dir = Join-Path $ShareRoot "Content\Packages\$PackageId"
    $null = New-Item -ItemType Directory -Path (Join-Path $dir "payload") -Force
    $def = [ordered]@{
        schemaVersion = 1
        packageId     = $PackageId
        name          = $Name
        packageType   = $PackageType
        enabled       = $true
        source        = "Content/Packages/$PackageId/payload"
    }
    $jsonPath = Join-Path $dir "package.json"
    ($def | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    return Get-Item -LiteralPath $jsonPath
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($ShareRoot)) {
        Get-LiteDeployComponentMetadata | Format-List
        return
    }
    Test-LiteDeployAdminPackages -ShareRoot $ShareRoot | Format-List
}
