<#
.SYNOPSIS
    LiteDeploy Admin Validation - whole-environment checks (architecture v2).
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
        ComponentId          = "Admin.Validation"
        Name                 = "LiteDeploy Admin Validation"
        Version              = "2.0.0"
        Category             = "Admin"
        TargetEnvironment    = "Host"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("Admin.Config", "Admin.Content", "Admin.Images", "Admin.Drivers", "Admin.Packages", "Admin.Workflows")
        Description          = "Pre-publish validation of config, content, images, drivers, packages, and workflows."
    }
}

if ($Metadata) { Get-LiteDeployComponentMetadata; return }

function Write-LiteDeployValidationLine {
    param([ValidateSet("PASS","WARN","FAIL")][string]$Status, [string]$Message)
    $color = switch ($Status) {
        "PASS" { "Green" }
        "WARN" { "Yellow" }
        "FAIL" { "Red" }
    }
    Write-Host ("[{0}] {1}" -f $Status.PadRight(4), $Message) -ForegroundColor $color
}

function Test-LiteDeployConfiguration {
    param([string]$ShareRoot)
    $cfg = Join-Path $ShareRoot "Config\BootConfig.json"
    $ok = Test-Path -LiteralPath $cfg -PathType Leaf
    Write-LiteDeployValidationLine -Status $(if ($ok) { "PASS" } else { "FAIL" }) -Message "Config"
    return $ok
}

function Test-LiteDeployContent {
    param([string]$ShareRoot)
    $required = @("Content\OperatingSystems", "Content\Drivers", "Content\Packages", "WorkFlows")
    $ok = $true
    foreach ($r in $required) {
        $p = Join-Path $ShareRoot $r
        if (-not (Test-Path -LiteralPath $p)) { $ok = $false }
    }
    Write-LiteDeployValidationLine -Status $(if ($ok) { "PASS" } else { "FAIL" }) -Message "Content"
    return $ok
}

function Test-LiteDeployImages {
    param([string]$ShareRoot)
    $catalog = Join-Path $ShareRoot "Content\OperatingSystems\catalog.json"
    $ok = Test-Path -LiteralPath $catalog -PathType Leaf
    Write-LiteDeployValidationLine -Status $(if ($ok) { "PASS" } else { "WARN" }) -Message "Images"
    return $ok
}

function Test-LiteDeployDrivers {
    param([string]$ShareRoot)
    $root = Join-Path $ShareRoot "Content\Drivers"
    $ok = Test-Path -LiteralPath $root
    Write-LiteDeployValidationLine -Status $(if ($ok) { "PASS" } else { "FAIL" }) -Message "Driver catalog root"
    return $ok
}

function Test-LiteDeployPackages {
    param([string]$ShareRoot)
    $root = Join-Path $ShareRoot "Content\Packages"
    if (-not (Test-Path -LiteralPath $root)) {
        Write-LiteDeployValidationLine -Status "WARN" -Message "Packages root missing"
        return $false
    }
    Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $json = Join-Path $_.FullName "package.json"
        if (-not (Test-Path $json)) {
            Write-LiteDeployValidationLine -Status "WARN" -Message "Package $($_.Name) missing package.json"
        }
        else {
            $def = Get-Content $json -Raw | ConvertFrom-Json
            if (-not $def.PSObject.Properties['detection'] -and -not $def.PSObject.Properties['Detection']) {
                Write-LiteDeployValidationLine -Status "WARN" -Message "Package $($_.Name) has no detection rule"
            }
        }
    }
    Write-LiteDeployValidationLine -Status "PASS" -Message "Packages"
    return $true
}

function Test-LiteDeployWorkflows {
    param([string]$ShareRoot)
    $dir = Join-Path $ShareRoot "WorkFlows"
    if (-not (Test-Path -LiteralPath $dir)) {
        Write-LiteDeployValidationLine -Status "FAIL" -Message "Workflows"
        return $false
    }
    $count = @(Get-ChildItem -Path $dir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
    Write-LiteDeployValidationLine -Status $(if ($count -gt 0) { "PASS" } else { "WARN" }) -Message "Workflows ($count)"
    return ($count -gt 0)
}

function Test-LiteDeployEnvironment {
    param([string]$ShareRoot)
    $results = [ordered]@{
        Config    = Test-LiteDeployConfiguration -ShareRoot $ShareRoot
        Content   = Test-LiteDeployContent -ShareRoot $ShareRoot
        Images    = Test-LiteDeployImages -ShareRoot $ShareRoot
        Drivers   = Test-LiteDeployDrivers -ShareRoot $ShareRoot
        Packages  = Test-LiteDeployPackages -ShareRoot $ShareRoot
        Workflows = Test-LiteDeployWorkflows -ShareRoot $ShareRoot
    }
    $failed = @($results.GetEnumerator() | Where-Object { -not $_.Value }).Count
    return [PSCustomObject]@{
        Passed  = ($failed -eq 0)
        Results = [PSCustomObject]$results
        ShareRoot = $ShareRoot
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($ShareRoot)) {
        Write-Host "LiteDeploy.Admin.Validation - provide -ShareRoot" -ForegroundColor Cyan
        Get-LiteDeployComponentMetadata | Format-List
        return
    }
    Test-LiteDeployEnvironment -ShareRoot $ShareRoot | Format-List
}
