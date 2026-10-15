<#
.SYNOPSIS
    LiteDeploy Admin Utilities - Admin-only helpers (architecture v2).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Metadata
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Get-LiteDeployComponentMetadata {
    return [PSCustomObject]@{
        ComponentId          = "Admin.Utilities"
        Name                 = "LiteDeploy Admin Utilities"
        Version              = "2.0.0"
        Category             = "Admin"
        TargetEnvironment    = "Host"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @()
        Description          = "Admin-only reusable helpers (hash, JSON test, safe names, backups)."
    }
}

if ($Metadata) { Get-LiteDeployComponentMetadata; return }

function Get-LiteDeployFileHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet("SHA256", "SHA1", "MD5")][string]$Algorithm = "SHA256"
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File was not found: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash
}

function Test-LiteDeployJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $null = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Backup-LiteDeployConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$BackupDirectory = ""
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config file was not found: $Path"
    }
    if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
        $BackupDirectory = Join-Path (Split-Path -Parent $Path) "Backup"
    }
    if (-not (Test-Path -LiteralPath $BackupDirectory)) {
        $null = New-Item -ItemType Directory -Path $BackupDirectory -Force
    }
    $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $dest = Join-Path $BackupDirectory ("{0}.{1}.bak" -f (Split-Path -Leaf $Path), $stamp)
    Copy-Item -LiteralPath $Path -Destination $dest -Force
    return $dest
}

function ConvertTo-LiteDeploySafeFileName {
    param([Parameter(Mandatory = $true)][string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $pattern = "[{0}]" -f [regex]::Escape($invalid)
    $safe = [regex]::Replace($Name, $pattern, "_")
    $safe = $safe.Trim().Trim('.')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = "item" }
    return $safe
}

function Copy-LiteDeployAdminContent {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Force
    )
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Source was not found: $Source"
    }
    $destParent = Split-Path -Parent $Destination
    if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
        $null = New-Item -ItemType Directory -Path $destParent -Force
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force:$Force
    return (Resolve-Path -LiteralPath $Destination).Path
}

if ($MyInvocation.InvocationName -ne '.') {
    Get-LiteDeployComponentMetadata | Format-List
    Write-Host "Admin utilities loaded when dot-sourced." -ForegroundColor DarkGray
}
