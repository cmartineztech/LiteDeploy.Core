<#
.SYNOPSIS
    Discovers and enumerates all LiteDeploy components across the repository.

.DESCRIPTION
    Scans the Scripts_Engine_Components directory, executes or inspects components for standard
    metadata, and outputs a consolidated inventory table.

.EXAMPLE
    .\Get-LiteDeployComponentInventory.ps1
    Outputs an inventory of all installed components with versions and targets.

.NOTES
    LiteDeploy Component Inventory Scanner
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$RootPath = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $RootPath = if ($scriptDir) { Join-Path $scriptDir "..\Scripts_Engine_Components" } else { ".\Scripts_Engine_Components" }
}

$resolvedRoot = (Resolve-Path -LiteralPath $RootPath).Path
$scripts = Get-ChildItem -Path $resolvedRoot -Filter "*.ps1" -Recurse -File

$inventory = [System.Collections.Generic.List[psobject]]::new()

foreach ($script in $scripts) {
    # Skip test harnesses and companion files
    if ($script.Name -like "Test-*" -or $script.Name -like "*.Template.*") { continue }

    $componentInfo = [ordered]@{
        ComponentFile = $script.Name
        Folder        = (Split-Path -Parent $script.FullName | Split-Path -Leaf)
        Category      = if ($script.FullName -match "\\Admin\\") { "Admin" } elseif ($script.FullName -match "\\Runtime\\") { "Runtime" } else { "Other" }
        Version       = "Unknown"
        ComponentId   = "Unknown"
        Environment   = "Universal"
        FullPath      = $script.FullName
    }

    # Attempt to query component metadata via standard -Metadata switch
    try {
        $meta = & $script.FullName -Metadata -ErrorAction SilentlyContinue
        if ($meta -and $meta.PSObject.Properties['Version']) {
            $componentInfo.Version     = $meta.Version
            $componentInfo.ComponentId = $meta.ComponentId
            if ($meta.PSObject.Properties['Category']) { $componentInfo.Category = $meta.Category }
            if ($meta.PSObject.Properties['TargetEnvironment']) { $componentInfo.Environment = $meta.TargetEnvironment }
        }
    }
    catch {}

    # Fallback to comment regex extraction if script does not yet export dynamic metadata
    if ($componentInfo.Version -eq "Unknown") {
        $content = Get-Content -LiteralPath $script.FullName -Raw
        if ($content -match '(?i)Version[:\s]+v?([0-9]+\.[0-9]+(?:\.[0-9]+)?)') {
            $componentInfo.Version = $matches[1]
        }
        if ($content -match '(?i)Component\s*=\s*"([^"]+)"') {
            $componentInfo.ComponentId = $matches[1]
        }
    }

    $inventory.Add([PSCustomObject]$componentInfo)
}

return $inventory
