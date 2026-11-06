<#
.SYNOPSIS
    LiteDeploy Packages - package catalog, validation, staging, and execution (architecture v2).

.DESCRIPTION
    Reads package definitions from <ShareRoot>\Content\Packages\<packageId>\package.json, validates them,
    stages their payload, and executes their Script / Command with captured exit codes.

    package.json (schemaVersion 1):
        packageId, name, packageType (Application | Script), enabled,
        source   payload folder relative to the share root (default: <package folder>\payload)
        Optional execution fields:
        script           file inside the payload (.ps1 .cmd .bat .exe .msi) — no .vbs
        command          command line run via cmd.exe from the payload folder
        arguments        string or string[] appended to the script / command
        workingDirectory folder inside the payload (default: the payload)
        successExitCodes int[]  (default 0, 1641, 3010)
        timeoutSeconds   int    (default 3600)
        version, description

    A package with neither script nor command is payload-only: Invoke reports NoOp (success).
    When both are present the script runs first, then the command; a failure stops the sequence.

    Public API:
      Get-LiteDeployPackages     List packages.
      Get-LiteDeployPackage      Get one package by packageId (or folder name).
      Test-LiteDeployPackage     Validate a package (bool, or -Detailed result).
      Install-LiteDeployPackage  Stage the payload to -Destination and/or execute it (-StageOnly to only stage).
      Invoke-LiteDeployPackage   Execute the package Script / Command and capture exit codes.

    SECURITY: Secrets are never written to logs. Invoke-LiteDeployPackage passes -Parameters to the child
    process as environment variables (LITEDEPLOY_PARAM_<NAME>; a PSCredential becomes _USERNAME / _PASSWORD),
    not on the command line. Log lines contain package ids, file names, exit codes, and durations only.
    Captured output and error text are redacted (password / secret / token pairs) before being returned.

    Usage:
        . "Z:\Engine\Scripts\Runtime\LiteDeploy.Packages.ps1"   # load the API
        .\LiteDeploy.Packages.ps1                               # list packages from Z:
        .\LiteDeploy.Packages.ps1 -ShareRoot \\Server\DeploymentShare$
        .\LiteDeploy.Packages.ps1 -Metadata                     # component metadata only

    ComponentId: Packages

.PARAMETER ShareRoot
    Deployment share / media root. Defaults to the BootObject-derived root, else Z:.

.PARAMETER Metadata
    Outputs the standardized component metadata PSCustomObject and exits immediately.

.NOTES
    LiteDeploy Component Standard v2.0
    Target Environment: WinPE / FullOS
    PowerShell Version: 5.1+
    Strict Mode: Version 2.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ShareRoot = "",

    [Parameter(Mandatory = $false)]
    [switch]$Metadata
)

# Enforce strict execution discipline across the runtime
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ==============================================================================
# 1. COMPONENT METADATA & VERSION CONTROL
# ==============================================================================

function Get-LiteDeployComponentMetadata {
    <#
    .SYNOPSIS
        Returns standardized component metadata for inventory discovery and version management.
    #>
    return [PSCustomObject]@{
        ComponentId          = "Packages"
        Name                 = "LiteDeploy Packages"
        Version              = "2.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "Universal"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("Logs")
        Description          = "Package catalog from Content\Packages, validation, payload staging, and Script/Command execution with exit-code capture."
    }
}

# Fast-exit for automated inventory scanners or version queries
if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

# ==============================================================================
# 2. CONSTANTS
# ==============================================================================

$global:LiteDeployPackageDefaultShareRoot = "Z:"
$global:LiteDeployPackageTypes            = @("Application", "Script")
$global:LiteDeployPackageIdPattern        = '^[A-Za-z0-9][A-Za-z0-9._-]*$'
$global:LiteDeployPackageDefaultSuccess   = @(0, 1641, 3010)
$global:LiteDeployPackageRebootCodes      = @(1641, 3010)
$global:LiteDeployPackageDefaultTimeout   = 3600
$global:LiteDeployPackageScriptExtensions = @(".ps1", ".cmd", ".bat", ".exe", ".msi")
$global:LiteDeployPackageMaxOutputChars   = 2000

# ==============================================================================
# 3. INTERNAL HELPERS
# ==============================================================================

function Protect-LiteDeployPackageText {
    <#
    .SYNOPSIS
        Redacts password/secret/token style key-value pairs from free text before logging or returning it.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return "" }

    $clean = [regex]::Replace(
        $Text,
        '(?i)((?:pass(?:word|wd)?|pwd|secret|token|api[-_ ]?key|credential)\s*[=:]\s*)("[^"]*"|''[^'']*''|[^\s;,]+)',
        '$1***')
    $clean = [regex]::Replace(
        $clean,
        '(?i)(-(?:password|passwd|pwd|secret|token|apikey)\s+)("[^"]*"|''[^'']*''|\S+)',
        '$1***')
    return $clean
}

function Write-LiteDeployPackageLog {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO",

        [switch]$NoConsole
    )

    $text = Protect-LiteDeployPackageText -Text $Message

    if (Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue) {
        try {
            Write-LiteDeployLog -Message $text -Level $Level -Component "Packages" -NoConsole:$NoConsole
        }
        catch {
            # Logging must never break package handling.
        }
        return
    }

    if ($NoConsole) { return }
    switch ($Level) {
        "WARNING" { Write-Warning $text }
        "ERROR"   { Write-Warning $text }
        default   { Write-Verbose $text }
    }
}

function Get-LiteDeployPackageProperty {
    <#
    .SYNOPSIS
        StrictMode-safe, case-insensitive property/key read. Returns $Default when missing or $null.
        Array values are enumerated to the pipeline: wrap array reads in @(...).
    #>
    param(
        $InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in @($InputObject.Keys)) {
            if ([string]$key -ieq $Name) {
                $dictValue = $InputObject[$key]
                if ($null -eq $dictValue) { return $Default }
                return $dictValue
            }
        }
        return $Default
    }

    foreach ($prop in $InputObject.PSObject.Properties) {
        if ($prop.Name -ieq $Name) {
            $propValue = $prop.Value
            if ($null -eq $propValue) { return $Default }
            return $propValue
        }
    }
    return $Default
}

function ConvertTo-LiteDeployPackageStringArray {
    # Normalizes $null / scalar / array into a clean string[] (blank entries dropped). Wrap calls in @(...).
    param($Value)

    $list = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Value) {
        foreach ($item in @($Value)) {
            if ($null -ne $item) {
                $text = ([string]$item).Trim()
                if ($text) { $list.Add($text) }
            }
        }
    }
    return $list.ToArray()
}

function ConvertTo-LiteDeployPackageIntArray {
    # Parses a list of numbers; returns the default list when nothing parses. Wrap calls in @(...).
    param(
        $Value,
        [int[]]$Default
    )

    $list = New-Object System.Collections.Generic.List[int]
    if ($null -ne $Value) {
        foreach ($item in @($Value)) {
            $parsed = 0
            if ($null -ne $item -and [int]::TryParse(([string]$item).Trim(), [ref]$parsed)) { $list.Add($parsed) }
        }
    }
    if ($list.Count -eq 0) { return $Default }
    return $list.ToArray()
}

function ConvertTo-LiteDeployPackageBool {
    param(
        $Value,
        [bool]$Default = $true
    )

    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }

    $text = ([string]$Value).Trim()
    if ($text -match '^(?i)(true|yes|1|on)$')  { return $true }
    if ($text -match '^(?i)(false|no|0|off)$') { return $false }
    return $Default
}

function Join-LiteDeployPackagePath {
    # Joins a root and a relative path ('/' or '\') without Join-Path drive-root quirks ('Z:' stays valid).
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$ChildPath
    )

    $child = $ChildPath.Replace('/', '\').TrimStart('\')
    if ([string]::IsNullOrEmpty($child)) { return $Root.TrimEnd('\') }
    return ("{0}\{1}" -f $Root.TrimEnd('\'), $child)
}

function Test-LiteDeployPackagePathInside {
    # True when $ChildPath resolves to a location at or below $ParentPath (blocks '..' escapes).
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChildPath,
        [Parameter(Mandatory = $true)]
        [string]$ParentPath
    )

    try {
        $child = [System.IO.Path]::GetFullPath($ChildPath).TrimEnd('\')
        $parent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd('\')
        if ($child -ieq $parent) { return $true }
        return $child.StartsWith($parent + '\', [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Resolve-LiteDeployPackageShareRoot {
    <#
    .SYNOPSIS
        Resolves the share/media root: explicit -ShareRoot, else derived from the global BootObject
        (Network -> DriveLetter, Media -> DriveLetter\LocalRootName), else Z:.
    #>
    param([string]$ShareRoot = "")

    if (-not [string]::IsNullOrWhiteSpace($ShareRoot)) {
        $explicit = $ShareRoot.Trim().TrimEnd('\')
        if ($explicit) { return $explicit }
    }

    $boot = Get-Variable -Name LiteDeployBootObject -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $boot) {
        $drive = [string](Get-LiteDeployPackageProperty -InputObject $boot -Name "DriveLetter" -Default "")
        $drive = $drive.Trim().TrimEnd('\')
        if ($drive) {
            $deployType = [string](Get-LiteDeployPackageProperty -InputObject $boot -Name "DeploymentType" -Default "")
            if ($deployType -ieq "Media") {
                $localRoot = [string](Get-LiteDeployPackageProperty -InputObject $boot -Name "LocalRootName" -Default "~LiteDeploy")
                return ("{0}\{1}" -f $drive, $localRoot)
            }
            return $drive
        }
    }

    return $global:LiteDeployPackageDefaultShareRoot
}

function ConvertTo-LiteDeployPackageObject {
    <#
    .SYNOPSIS
        Normalizes a parsed package.json into the LiteDeploy.Package object used by this API.
    #>
    param(
        $Manifest,
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,
        [Parameter(Mandatory = $true)]
        [string]$ShareRoot,
        [string]$LoadError = ""
    )

    $packageRoot = Split-Path -Parent $ManifestPath
    $folderName = Split-Path -Leaf $packageRoot

    $packageId = [string](Get-LiteDeployPackageProperty -InputObject $Manifest -Name "packageId" -Default "")
    if ([string]::IsNullOrWhiteSpace($packageId)) { $packageId = $folderName }

    $source = [string](Get-LiteDeployPackageProperty -InputObject $Manifest -Name "source" -Default "")
    $sourceIsAbsolute = ($source -match '^[A-Za-z]:' -or $source -match '^\\\\')
    $sourceEscapes = $false
    if ($source) {
        $payloadCandidate = if ($sourceIsAbsolute) { $source } else { Join-LiteDeployPackagePath -Root $ShareRoot -ChildPath $source }
    }
    else {
        $payloadCandidate = Join-LiteDeployPackagePath -Root $packageRoot -ChildPath "payload"
    }

    $payloadPath = $payloadCandidate
    try { $payloadPath = [System.IO.Path]::GetFullPath($payloadCandidate) } catch { $payloadPath = $payloadCandidate }
    if ($source -and -not $sourceIsAbsolute) {
        $sourceEscapes = -not (Test-LiteDeployPackagePathInside -ChildPath $payloadPath -ParentPath $ShareRoot)
    }

    $timeout = $global:LiteDeployPackageDefaultTimeout
    $parsedTimeout = 0
    $rawTimeout = Get-LiteDeployPackageProperty -InputObject $Manifest -Name "timeoutSeconds"
    if ($null -ne $rawTimeout -and [int]::TryParse([string]$rawTimeout, [ref]$parsedTimeout)) { $timeout = $parsedTimeout }

    $schemaVersion = 0
    [void][int]::TryParse([string](Get-LiteDeployPackageProperty -InputObject $Manifest -Name "schemaVersion" -Default 0), [ref]$schemaVersion)

    $scriptName = [string](Get-LiteDeployPackageProperty -InputObject $Manifest -Name "script" -Default "")
    $commandLine = [string](Get-LiteDeployPackageProperty -InputObject $Manifest -Name "command" -Default "")

    $enabled = ConvertTo-LiteDeployPackageBool -Value (Get-LiteDeployPackageProperty -InputObject $Manifest -Name "enabled") -Default $true
    if ($LoadError) { $enabled = $false }

    return [PSCustomObject]@{
        PSTypeName       = "LiteDeploy.Package"
        PackageId        = $packageId
        Name             = [string](Get-LiteDeployPackageProperty -InputObject $Manifest -Name "name" -Default "")
        PackageType      = [string](Get-LiteDeployPackageProperty -InputObject $Manifest -Name "packageType" -Default "")
        Enabled          = $enabled
        SchemaVersion    = $schemaVersion
        Version          = [string](Get-LiteDeployPackageProperty -InputObject $Manifest -Name "version" -Default "")
        Description      = [string](Get-LiteDeployPackageProperty -InputObject $Manifest -Name "description" -Default "")
        Source           = $source
        Script           = $scriptName
        Command          = $commandLine
        Arguments        = @(ConvertTo-LiteDeployPackageStringArray (Get-LiteDeployPackageProperty -InputObject $Manifest -Name "arguments" -Default @()))
        WorkingDirectory = [string](Get-LiteDeployPackageProperty -InputObject $Manifest -Name "workingDirectory" -Default "")
        SuccessExitCodes = @(ConvertTo-LiteDeployPackageIntArray -Value (Get-LiteDeployPackageProperty -InputObject $Manifest -Name "successExitCodes" -Default @()) -Default $global:LiteDeployPackageDefaultSuccess)
        TimeoutSeconds   = $timeout
        HasExecutable    = (-not [string]::IsNullOrWhiteSpace($scriptName) -or -not [string]::IsNullOrWhiteSpace($commandLine))
        PackageRoot      = $packageRoot
        FolderName       = $folderName
        ManifestPath     = $ManifestPath
        PayloadPath      = $payloadPath
        PayloadExists    = (Test-Path -LiteralPath $payloadPath -PathType Container)
        PayloadExternal  = $sourceIsAbsolute
        PayloadEscapes   = $sourceEscapes
        LoadError        = $LoadError
        ShareRoot        = $ShareRoot
    }
}

function ConvertTo-LiteDeployArgumentString {
    # Builds a Windows command-line argument string, quoting values that contain whitespace or quotes.
    param([string[]]$Values = @())

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Values)) {
        if ($null -eq $value) { continue }
        if ($value.Length -eq 0) { $parts.Add('""'); continue }
        if ($value -match '[\s"]') {
            $parts.Add('"' + $value.Replace('"', '\"') + '"')
        }
        else {
            $parts.Add($value)
        }
    }
    return ($parts -join ' ')
}

function New-LiteDeployPackageResult {
    param(
        [string]$PackageId = "",
        [string]$Name = "",
        [string]$Status = "Failed",
        [bool]$Success = $false,
        [string]$Message = ""
    )

    return [PSCustomObject]@{
        PSTypeName      = "LiteDeploy.PackageResult"
        PackageId       = $PackageId
        Name            = $Name
        Status          = $Status        # Succeeded, Failed, TimedOut, NoOp, Skipped, WhatIf
        Success         = $Success
        ExitCode        = $null
        RebootRequired  = $false
        PayloadPath     = ""
        DurationSeconds = 0.0
        Runs            = @()
        Message         = $Message
        Errors          = @()
    }
}

# ==============================================================================
# 4. PUBLIC API - CATALOG
# ==============================================================================

function Get-LiteDeployPackages {
    <#
    .SYNOPSIS
        Lists packages from <ShareRoot>\Content\Packages\*\package.json (sorted by folder name).

    .DESCRIPTION
        Disabled packages (and manifests that cannot be parsed, reported with LoadError) are skipped
        unless -IncludeDisabled. Wrap results in @(...).

    .EXAMPLE
        @(Get-LiteDeployPackages -ShareRoot Z: -IncludeDisabled) | Format-Table PackageId, Name, PackageType, Enabled
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = "",

        [Parameter(Mandatory = $false)]
        [string]$PackageType = "",

        [Parameter(Mandatory = $false)]
        [switch]$IncludeDisabled
    )

    $root = Resolve-LiteDeployPackageShareRoot -ShareRoot $ShareRoot
    $packagesDir = Join-LiteDeployPackagePath -Root $root -ChildPath "Content\Packages"
    $found = New-Object System.Collections.Generic.List[object]

    if (-not (Test-Path -LiteralPath $packagesDir -PathType Container)) {
        return
    }

    $folders = @(Get-ChildItem -LiteralPath $packagesDir -Directory -ErrorAction SilentlyContinue | Sort-Object -Property Name)
    foreach ($folder in $folders) {
        $manifestPath = Join-Path $folder.FullName "package.json"
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }

        $manifest = $null
        $loadError = ""
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $manifest) { $loadError = "package.json is empty." }
        }
        catch {
            $loadError = "package.json is not valid JSON: $($_.Exception.Message)"
        }

        if ($loadError) {
            Write-LiteDeployPackageLog -Message "Package '$($folder.Name)': $loadError" -Level "WARNING" -NoConsole
        }

        $package = ConvertTo-LiteDeployPackageObject -Manifest $manifest -ManifestPath $manifestPath -ShareRoot $root -LoadError $loadError

        if (-not $IncludeDisabled -and -not $package.Enabled) { continue }
        if (-not [string]::IsNullOrWhiteSpace($PackageType) -and $package.PackageType -ine $PackageType) { continue }

        $found.Add($package)
    }

    return $found.ToArray()
}

function Get-LiteDeployPackage {
    <#
    .SYNOPSIS
        Gets one package by packageId (or folder name), case-insensitive. Returns $null when not found.
        Disabled packages are included.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = ""
    )

    $all = @(Get-LiteDeployPackages -ShareRoot $ShareRoot -IncludeDisabled)

    foreach ($pkg in $all) { if ($pkg.PackageId -ieq $PackageId) { return $pkg } }
    foreach ($pkg in $all) { if ($pkg.FolderName -ieq $PackageId) { return $pkg } }
    return $null
}

function Test-LiteDeployPackage {
    <#
    .SYNOPSIS
        Validates a package (by -PackageId, or a -Package object from Get-LiteDeployPackage).

    .DESCRIPTION
        Returns $true/$false, or { IsValid, Errors, Warnings, PackageId } with -Detailed.
        Errors: unparseable manifest, invalid / mismatched packageId, missing name, unknown packageType,
        path escapes, missing payload or script when something must execute, unsupported script type.
        Warnings: disabled, unknown schemaVersion, metadata-only package, inline secret-looking arguments.
        -PayloadPath validates against a staged copy instead of the share payload.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$PackageId = "",

        [Parameter(Mandatory = $false)]
        [psobject]$Package = $null,

        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = "",

        [Parameter(Mandatory = $false)]
        [string]$PayloadPath = "",

        [Parameter(Mandatory = $false)]
        [switch]$Detailed
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $pkg = $Package

    if ($null -eq $pkg) {
        if ([string]::IsNullOrWhiteSpace($PackageId)) {
            $errors.Add("Specify -PackageId or -Package.")
        }
        else {
            $pkg = Get-LiteDeployPackage -PackageId $PackageId -ShareRoot $ShareRoot
            if ($null -eq $pkg) { $errors.Add("Package '$PackageId' was not found.") }
        }
    }
    elseif (@($pkg.PSObject.TypeNames) -notcontains "LiteDeploy.Package") {
        $errors.Add("-Package must be an object returned by Get-LiteDeployPackage.")
        $pkg = $null
    }

    $resolvedId = $PackageId
    if ($null -ne $pkg) {
        $resolvedId = $pkg.PackageId

        if ($pkg.LoadError) { $errors.Add($pkg.LoadError) }

        if ($pkg.SchemaVersion -ne 1) { $warnings.Add("schemaVersion '$($pkg.SchemaVersion)' is not the supported version (1).") }
        if ($pkg.PackageId -notmatch $global:LiteDeployPackageIdPattern) { $errors.Add("packageId '$($pkg.PackageId)' may only contain letters, digits, '.', '_' and '-'.") }
        if ($pkg.PackageId -ine $pkg.FolderName) { $errors.Add("packageId '$($pkg.PackageId)' does not match its folder name '$($pkg.FolderName)'.") }
        if ([string]::IsNullOrWhiteSpace($pkg.Name)) { $errors.Add("name is required.") }

        if ([string]::IsNullOrWhiteSpace($pkg.PackageType)) { $errors.Add("packageType is required.") }
        elseif ($global:LiteDeployPackageTypes -notcontains $pkg.PackageType) { $errors.Add("packageType '$($pkg.PackageType)' is not one of: $($global:LiteDeployPackageTypes -join ', ').") }

        if (-not $pkg.Enabled -and -not $pkg.LoadError) { $warnings.Add("Package is disabled.") }

        $effectivePayload = if ([string]::IsNullOrWhiteSpace($PayloadPath)) { $pkg.PayloadPath } else { $PayloadPath }
        $payloadExists = Test-Path -LiteralPath $effectivePayload -PathType Container

        if ($pkg.PayloadEscapes) { $errors.Add("source '$($pkg.Source)' escapes the share root.") }
        if ($pkg.PayloadExternal) { $warnings.Add("source '$($pkg.Source)' points outside the share (absolute path).") }

        if (-not $payloadExists) {
            if ($pkg.HasExecutable) { $errors.Add("Payload folder '$effectivePayload' was not found.") }
            else { $warnings.Add("Payload folder '$effectivePayload' was not found (metadata-only package).") }
        }

        if ($pkg.Script) {
            $scriptFull = Join-LiteDeployPackagePath -Root $effectivePayload -ChildPath $pkg.Script
            $extension = [System.IO.Path]::GetExtension($pkg.Script).ToLowerInvariant()
            if ($pkg.Script -match '^[A-Za-z]:' -or $pkg.Script -match '^[\\/]') {
                $errors.Add("script '$($pkg.Script)' must be relative to the payload folder.")
            }
            elseif (-not (Test-LiteDeployPackagePathInside -ChildPath $scriptFull -ParentPath $effectivePayload)) {
                $errors.Add("script '$($pkg.Script)' escapes the payload folder.")
            }
            elseif ($global:LiteDeployPackageScriptExtensions -notcontains $extension) {
                $errors.Add("script '$($pkg.Script)' has unsupported type '$extension' (supported: $($global:LiteDeployPackageScriptExtensions -join ' ')).")
            }
            elseif ($payloadExists -and -not (Test-Path -LiteralPath $scriptFull -PathType Leaf)) {
                $errors.Add("script '$($pkg.Script)' was not found in the payload.")
            }
        }

        if ($pkg.WorkingDirectory) {
            $workFull = Join-LiteDeployPackagePath -Root $effectivePayload -ChildPath $pkg.WorkingDirectory
            if (-not (Test-LiteDeployPackagePathInside -ChildPath $workFull -ParentPath $effectivePayload)) {
                $errors.Add("workingDirectory '$($pkg.WorkingDirectory)' escapes the payload folder.")
            }
        }

        if ($pkg.PackageType -ieq "Script" -and -not $pkg.HasExecutable) {
            $warnings.Add("Script package declares neither 'script' nor 'command'; invoking it does nothing.")
        }

        if ($pkg.TimeoutSeconds -le 0) { $warnings.Add("timeoutSeconds '$($pkg.TimeoutSeconds)' disables the timeout.") }

        $secretPattern = '(?i)(pass(word|wd)?|pwd|secret|token|api[-_ ]?key)\s*[=:]\s*\S|-(password|passwd|pwd|secret|token|apikey)\s+\S'
        $inline = ((@($pkg.Arguments) + @($pkg.Command)) -join ' ')
        if ($inline -match $secretPattern) {
            $warnings.Add("arguments/command appear to contain an inline secret; pass secrets with Invoke-LiteDeployPackage -Parameters instead.")
        }
    }

    $isValid = ($errors.Count -eq 0)
    if (-not $Detailed) { return $isValid }

    return [PSCustomObject]@{
        IsValid   = $isValid
        Errors    = $errors.ToArray()
        Warnings  = $warnings.ToArray()
        PackageId = $resolvedId
    }
}

# ==============================================================================
# 5. EXECUTION ENGINE
# ==============================================================================

function Get-LiteDeployPackageRunSpecs {
    <#
    .SYNOPSIS
        Builds the ordered process launches (script first, then command) for a package. Throws on unsafe paths.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Package,
        [Parameter(Mandatory = $true)]
        [string]$PayloadPath,
        [string[]]$ExtraArguments = @()
    )

    $specs = New-Object System.Collections.Generic.List[object]
    $comSpec = if ($env:ComSpec) { [string]$env:ComSpec } else { "cmd.exe" }
    $allArguments = @(@($Package.Arguments) + @($ExtraArguments))

    $workingDirectory = $PayloadPath
    if ($Package.WorkingDirectory) {
        $workingDirectory = [System.IO.Path]::GetFullPath((Join-LiteDeployPackagePath -Root $PayloadPath -ChildPath $Package.WorkingDirectory))
        if (-not (Test-LiteDeployPackagePathInside -ChildPath $workingDirectory -ParentPath $PayloadPath)) {
            throw "workingDirectory '$($Package.WorkingDirectory)' escapes the payload folder."
        }
    }

    if ($Package.Script) {
        $scriptFull = [System.IO.Path]::GetFullPath((Join-LiteDeployPackagePath -Root $PayloadPath -ChildPath $Package.Script))
        if (-not (Test-LiteDeployPackagePathInside -ChildPath $scriptFull -ParentPath $PayloadPath)) {
            throw "script '$($Package.Script)' escapes the payload folder."
        }
        if (-not (Test-Path -LiteralPath $scriptFull -PathType Leaf)) {
            throw "script '$($Package.Script)' was not found in '$PayloadPath'."
        }

        $argText = ConvertTo-LiteDeployArgumentString -Values $allArguments
        $extension = [System.IO.Path]::GetExtension($scriptFull).ToLowerInvariant()
        $filePath = ""
        $arguments = ""

        switch ($extension) {
            ".ps1" {
                $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
                if (-not (Test-Path -LiteralPath $psExe)) { $psExe = "powershell.exe" }
                $filePath = $psExe
                $arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f $scriptFull, $argText).TrimEnd()
            }
            { $_ -eq ".cmd" -or $_ -eq ".bat" } {
                $filePath = $comSpec
                # /s strips the outer quote pair, leaving: "<script>" <args>
                $arguments = ('/d /s /c ""{0}" {1}"' -f $scriptFull, $argText)
            }
            ".exe" {
                $filePath = $scriptFull
                $arguments = $argText
            }
            ".msi" {
                $filePath = "msiexec.exe"
                $arguments = ('/i "{0}" /qn /norestart {1}' -f $scriptFull, $argText).TrimEnd()
            }
            default {
                throw "script '$($Package.Script)' has unsupported type '$extension'."
            }
        }

        $specs.Add([PSCustomObject]@{
            Kind             = "Script"
            Target           = [System.IO.Path]::GetFileName($scriptFull)
            FilePath         = $filePath
            Arguments        = $arguments
            WorkingDirectory = $workingDirectory
        })
    }

    if ($Package.Command) {
        # Package arguments belong to the script when one exists; otherwise they extend the command line.
        $commandLine = [string]$Package.Command
        if (-not $Package.Script -and $allArguments.Count -gt 0) {
            $commandLine = ("{0} {1}" -f $commandLine, (ConvertTo-LiteDeployArgumentString -Values $allArguments))
        }

        $specs.Add([PSCustomObject]@{
            Kind             = "Command"
            Target           = "cmd.exe /c"
            FilePath         = $comSpec
            Arguments        = ('/d /s /c "{0}"' -f $commandLine)
            WorkingDirectory = $workingDirectory
        })
    }

    return $specs.ToArray()
}

function ConvertTo-LiteDeployPackageEnvironment {
    <#
    .SYNOPSIS
        Builds the child-process environment: LITEDEPLOY_* context plus LITEDEPLOY_PARAM_<NAME> parameters.
        PSCredential -> _USERNAME / _PASSWORD; SecureString -> plain value. Never logged.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Package,
        [Parameter(Mandatory = $true)]
        [string]$PayloadPath,
        [hashtable]$Parameters = @{}
    )

    $environment = @{
        LITEDEPLOY_PACKAGE_ID   = [string]$Package.PackageId
        LITEDEPLOY_PACKAGE_PATH = $PayloadPath
        LITEDEPLOY_SHARE_ROOT   = [string]$Package.ShareRoot
    }

    foreach ($key in @($Parameters.Keys)) {
        $safeName = ([string]$key -replace '[^A-Za-z0-9_]', '_').ToUpperInvariant()
        if ([string]::IsNullOrEmpty($safeName)) { continue }
        $envName = "LITEDEPLOY_PARAM_$safeName"
        $value = $Parameters[$key]

        if ($null -eq $value) { continue }

        if ($value -is [System.Management.Automation.PSCredential]) {
            $environment["${envName}_USERNAME"] = [string]$value.UserName
            $environment["${envName}_PASSWORD"] = [string]$value.GetNetworkCredential().Password
        }
        elseif ($value -is [System.Security.SecureString]) {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($value)
            try { $environment[$envName] = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
        else {
            $environment[$envName] = [string]$value
        }
    }

    return $environment
}

function Invoke-LiteDeployPackageProcess {
    <#
    .SYNOPSIS
        Runs one process, capturing exit code / output with a timeout. Never throws.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string]$Arguments = "",
        [string]$WorkingDirectory = "",
        [hashtable]$Environment = @{},
        [int]$TimeoutSeconds = 0
    )

    $outcome = [PSCustomObject]@{
        Started         = $false
        ExitCode        = -1
        TimedOut        = $false
        StdOut          = ""
        StdErr          = ""
        DurationSeconds = 0.0
        Error           = ""
    }

    $startTime = Get-Date
    $process = $null
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $FilePath
        $startInfo.Arguments = $Arguments
        if ($WorkingDirectory) { $startInfo.WorkingDirectory = $WorkingDirectory }
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($name in @($Environment.Keys)) {
            $startInfo.EnvironmentVariables[[string]$name] = [string]$Environment[$name]
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        [void]$process.Start()
        $outcome.Started = $true

        # Read both streams asynchronously so a full pipe can never deadlock the child.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $waitMs = -1
        if ($TimeoutSeconds -gt 0) { $waitMs = [int][Math]::Min([int]::MaxValue, ([long]$TimeoutSeconds * 1000)) }

        if ($process.WaitForExit($waitMs)) {
            $process.WaitForExit()
            $outcome.ExitCode = $process.ExitCode
        }
        else {
            $outcome.TimedOut = $true
            try { $process.Kill() } catch { }
            [void]$process.WaitForExit(5000)
            $outcome.ExitCode = -1
        }

        if ($stdoutTask.Wait(5000)) { $outcome.StdOut = [string]$stdoutTask.Result }
        if ($stderrTask.Wait(5000)) { $outcome.StdErr = [string]$stderrTask.Result }
    }
    catch {
        $outcome.Error = $_.Exception.Message
        $outcome.ExitCode = -1
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
    }

    $outcome.DurationSeconds = [Math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
    return $outcome
}

function Invoke-LiteDeployPackage {
    <#
    .SYNOPSIS
        Executes a package's Script and/or Command and captures exit codes.

    .DESCRIPTION
        Never throws; failures are reported in the result. A package with no Script/Command returns NoOp
        (success). A non-success exit code (see successExitCodes) stops the sequence. 1641 / 3010 set
        RebootRequired. Use -PayloadPath to run from a staged copy. Supports -WhatIf.

        -Parameters are exposed to the child as LITEDEPLOY_PARAM_<NAME> environment variables (PSCredential ->
        _USERNAME / _PASSWORD) and never appear in logs or on the command line.

    .OUTPUTS
        LiteDeploy.PackageResult: PackageId, Name, Status (Succeeded | Failed | TimedOut | NoOp | Skipped |
        WhatIf), Success, ExitCode, RebootRequired, PayloadPath, DurationSeconds, Runs, Message, Errors.

    .EXAMPLE
        Invoke-LiteDeployPackage -PackageId domain-join -ShareRoot Z: -Parameters @{ Credential = $cred }
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$PackageId = "",

        [Parameter(Mandatory = $false)]
        [psobject]$Package = $null,

        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = "",

        [Parameter(Mandatory = $false)]
        [string]$PayloadPath = "",

        [Parameter(Mandatory = $false)]
        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $false)]
        [hashtable]$Parameters = @{},

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 0,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeDisabled
    )

    $pkg = $Package
    if ($null -eq $pkg) {
        if ([string]::IsNullOrWhiteSpace($PackageId)) {
            return (New-LiteDeployPackageResult -Message "Specify -PackageId or -Package.")
        }
        $pkg = Get-LiteDeployPackage -PackageId $PackageId -ShareRoot $ShareRoot
        if ($null -eq $pkg) {
            return (New-LiteDeployPackageResult -PackageId $PackageId -Message "Package '$PackageId' was not found.")
        }
    }

    if (@($pkg.PSObject.TypeNames) -notcontains "LiteDeploy.Package") {
        return (New-LiteDeployPackageResult -Message "-Package must be an object returned by Get-LiteDeployPackage.")
    }

    $result = New-LiteDeployPackageResult -PackageId $pkg.PackageId -Name $pkg.Name

    $effectivePayload = if ([string]::IsNullOrWhiteSpace($PayloadPath)) { $pkg.PayloadPath } else { [System.IO.Path]::GetFullPath($PayloadPath) }
    $result.PayloadPath = $effectivePayload

    if (-not $pkg.Enabled -and -not $IncludeDisabled) {
        $result.Status = "Skipped"
        $result.Message = "Package is disabled."
        return $result
    }

    $validation = Test-LiteDeployPackage -Package $pkg -PayloadPath $effectivePayload -Detailed
    if (-not $validation.IsValid) {
        $result.Errors = $validation.Errors
        $result.Message = "Package validation failed: " + ($validation.Errors -join "; ")
        Write-LiteDeployPackageLog -Message "Package '$($pkg.PackageId)' failed validation: $($validation.Errors -join '; ')" -Level "ERROR" -NoConsole
        return $result
    }

    if (-not $pkg.HasExecutable) {
        $result.Status = "NoOp"
        $result.Success = $true
        $result.Message = "Package has no script or command; nothing to execute."
        Write-LiteDeployPackageLog -Message "Package '$($pkg.PackageId)': no script or command; nothing to execute." -Level "INFO" -NoConsole
        return $result
    }

    if (-not $PSCmdlet.ShouldProcess($pkg.PackageId, "Execute LiteDeploy package")) {
        $result.Status = "WhatIf"
        $result.Success = $true
        $result.Message = "Execution skipped (-WhatIf)."
        return $result
    }

    $specs = @()
    try {
        $specs = @(Get-LiteDeployPackageRunSpecs -Package $pkg -PayloadPath $effectivePayload -ExtraArguments $Arguments)
    }
    catch {
        $result.Errors = @($_.Exception.Message)
        $result.Message = $_.Exception.Message
        Write-LiteDeployPackageLog -Message "Package '$($pkg.PackageId)': $($_.Exception.Message)" -Level "ERROR" -NoConsole
        return $result
    }

    $environment = ConvertTo-LiteDeployPackageEnvironment -Package $pkg -PayloadPath $effectivePayload -Parameters $Parameters
    $timeout = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds } else { $pkg.TimeoutSeconds }

    $runs = New-Object System.Collections.Generic.List[object]
    $overallStart = Get-Date
    $failed = $false
    $timedOut = $false
    $runNumber = 0

    foreach ($spec in $specs) {
        $runNumber++
        Write-LiteDeployPackageLog -Message "Package '$($pkg.PackageId)': running $($spec.Kind) '$($spec.Target)' ($runNumber of $($specs.Count))." -Level "INFO" -NoConsole

        $outcome = Invoke-LiteDeployPackageProcess -FilePath $spec.FilePath -Arguments $spec.Arguments `
            -WorkingDirectory $spec.WorkingDirectory -Environment $environment -TimeoutSeconds $timeout

        $isSuccess = (-not $outcome.TimedOut -and $outcome.Started -and (@($pkg.SuccessExitCodes) -contains $outcome.ExitCode))

        $combined = ($outcome.StdOut + [Environment]::NewLine + $outcome.StdErr).Trim()
        if ($combined.Length -gt $global:LiteDeployPackageMaxOutputChars) {
            $combined = $combined.Substring($combined.Length - $global:LiteDeployPackageMaxOutputChars)
        }

        $runs.Add([PSCustomObject]@{
            Kind            = $spec.Kind
            Target          = $spec.Target
            ExitCode        = $outcome.ExitCode
            Success         = $isSuccess
            TimedOut        = $outcome.TimedOut
            DurationSeconds = $outcome.DurationSeconds
            OutputSummary   = (Protect-LiteDeployPackageText -Text $combined)
            Error           = (Protect-LiteDeployPackageText -Text $outcome.Error)
        })

        $result.ExitCode = $outcome.ExitCode

        if ($isSuccess) {
            if (@($global:LiteDeployPackageRebootCodes) -contains $outcome.ExitCode) { $result.RebootRequired = $true }
            Write-LiteDeployPackageLog -Message "Package '$($pkg.PackageId)': $($spec.Kind) exit code $($outcome.ExitCode) in $($outcome.DurationSeconds)s." -Level "INFO" -NoConsole
        }
        else {
            $failed = $true
            $timedOut = $outcome.TimedOut
            $reason = if ($outcome.TimedOut) { "timed out after $timeout s" }
                      elseif (-not $outcome.Started) { "could not be started" }
                      else { "exit code $($outcome.ExitCode)" }
            $result.Errors = @("$($spec.Kind) '$($spec.Target)' $reason.")
            Write-LiteDeployPackageLog -Message "Package '$($pkg.PackageId)': $($spec.Kind) $reason." -Level "ERROR" -NoConsole
            break
        }
    }

    $result.Runs = $runs.ToArray()
    $result.DurationSeconds = [Math]::Round(((Get-Date) - $overallStart).TotalSeconds, 2)

    if ($failed) {
        $result.Status = if ($timedOut) { "TimedOut" } else { "Failed" }
        $result.Success = $false
        $result.Message = [string]($result.Errors[0])
    }
    else {
        $result.Status = "Succeeded"
        $result.Success = $true
        $result.Message = if ($result.RebootRequired) { "Completed; a reboot is required." } else { "Completed successfully." }
        Write-LiteDeployPackageLog -Message "Package '$($pkg.PackageId)' completed (exit code $($result.ExitCode))." -Level "SUCCESS" -NoConsole
    }

    return $result
}

function Install-LiteDeployPackage {
    <#
    .SYNOPSIS
        Stages a package payload to -Destination and/or executes it.

    .DESCRIPTION
        With -Destination the manifest and payload are copied to <Destination>\<packageId>\ (any previous copy
        is replaced) and the package runs from the staged payload; -StageOnly stages without executing.
        Without -Destination the package runs directly from the share payload. Execution, exit-code capture,
        and secret handling are those of Invoke-LiteDeployPackage. Never throws. Supports -WhatIf.

    .OUTPUTS
        { PackageId, Success, Status, Staged, StagedPath, Invocation, Message, Errors }
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$PackageId = "",

        [Parameter(Mandatory = $false)]
        [psobject]$Package = $null,

        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = "",

        [Parameter(Mandatory = $false)]
        [string]$Destination = "",

        [Parameter(Mandatory = $false)]
        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $false)]
        [hashtable]$Parameters = @{},

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 0,

        [Parameter(Mandatory = $false)]
        [switch]$StageOnly,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeDisabled
    )

    $result = [PSCustomObject]@{
        PSTypeName = "LiteDeploy.PackageInstallResult"
        PackageId  = $PackageId
        Success    = $false
        Status     = "Failed"        # Succeeded, Staged, Failed, Skipped, WhatIf
        Staged     = $false
        StagedPath = ""
        Invocation = $null
        Message    = ""
        Errors     = @()
    }

    $pkg = $Package
    if ($null -eq $pkg) {
        if ([string]::IsNullOrWhiteSpace($PackageId)) {
            $result.Message = "Specify -PackageId or -Package."
            return $result
        }
        $pkg = Get-LiteDeployPackage -PackageId $PackageId -ShareRoot $ShareRoot
        if ($null -eq $pkg) {
            $result.Message = "Package '$PackageId' was not found."
            return $result
        }
    }
    if (@($pkg.PSObject.TypeNames) -notcontains "LiteDeploy.Package") {
        $result.Message = "-Package must be an object returned by Get-LiteDeployPackage."
        return $result
    }
    $result.PackageId = $pkg.PackageId

    if ($StageOnly -and [string]::IsNullOrWhiteSpace($Destination)) {
        $result.Message = "-StageOnly requires -Destination."
        return $result
    }

    if (-not $pkg.Enabled -and -not $IncludeDisabled) {
        $result.Status = "Skipped"
        $result.Message = "Package is disabled."
        return $result
    }

    $validation = Test-LiteDeployPackage -Package $pkg -Detailed
    if (-not $validation.IsValid) {
        $result.Errors = $validation.Errors
        $result.Message = "Package validation failed: " + ($validation.Errors -join "; ")
        Write-LiteDeployPackageLog -Message "Install of package '$($pkg.PackageId)' failed validation: $($validation.Errors -join '; ')" -Level "ERROR" -NoConsole
        return $result
    }

    if (-not $PSCmdlet.ShouldProcess($pkg.PackageId, "Install LiteDeploy package")) {
        $result.Status = "WhatIf"
        $result.Success = $true
        $result.Message = "Install skipped (-WhatIf)."
        return $result
    }

    $payloadForRun = ""
    if (-not [string]::IsNullOrWhiteSpace($Destination)) {
        try {
            $destinationRoot = [System.IO.Path]::GetFullPath($Destination)
            $stagedRoot = [System.IO.Path]::GetFullPath((Join-LiteDeployPackagePath -Root $destinationRoot -ChildPath $pkg.PackageId))

            # Defense in depth: packageId was validated, but never delete anything outside the destination.
            if ($stagedRoot -ieq $destinationRoot.TrimEnd('\') -or -not (Test-LiteDeployPackagePathInside -ChildPath $stagedRoot -ParentPath $destinationRoot)) {
                throw "Staging path '$stagedRoot' is not inside the destination '$destinationRoot'."
            }

            if (Test-Path -LiteralPath $stagedRoot) {
                Remove-Item -LiteralPath $stagedRoot -Recurse -Force -ErrorAction Stop
            }
            $null = New-Item -Path $stagedRoot -ItemType Directory -Force -ErrorAction Stop

            Copy-Item -LiteralPath $pkg.ManifestPath -Destination (Join-Path $stagedRoot "package.json") -Force -ErrorAction Stop
            $stagedPayload = Join-Path $stagedRoot "payload"
            if ($pkg.PayloadExists) {
                Copy-Item -LiteralPath $pkg.PayloadPath -Destination $stagedPayload -Recurse -Force -ErrorAction Stop
            }
            else {
                $null = New-Item -Path $stagedPayload -ItemType Directory -Force -ErrorAction Stop
            }

            $result.Staged = $true
            $result.StagedPath = $stagedRoot
            $payloadForRun = $stagedPayload
            Write-LiteDeployPackageLog -Message "Package '$($pkg.PackageId)' staged to '$stagedRoot'." -Level "INFO" -NoConsole
        }
        catch {
            $result.Errors = @($_.Exception.Message)
            $result.Message = "Staging failed: $($_.Exception.Message)"
            Write-LiteDeployPackageLog -Message "Package '$($pkg.PackageId)' staging failed: $($_.Exception.Message)" -Level "ERROR" -NoConsole
            return $result
        }
    }

    if ($StageOnly) {
        $result.Status = "Staged"
        $result.Success = $true
        $result.Message = "Package staged to '$($result.StagedPath)'."
        return $result
    }

    $invokeParameters = @{
        Package    = $pkg
        Arguments  = $Arguments
        Parameters = $Parameters
        IncludeDisabled = $IncludeDisabled
    }
    if ($payloadForRun) { $invokeParameters['PayloadPath'] = $payloadForRun }
    if ($TimeoutSeconds -gt 0) { $invokeParameters['TimeoutSeconds'] = $TimeoutSeconds }

    $invocation = Invoke-LiteDeployPackage @invokeParameters
    $result.Invocation = $invocation
    $result.Success = $invocation.Success
    $result.Message = $invocation.Message
    $result.Errors = @($invocation.Errors)
    $result.Status = if ($invocation.Success) { "Succeeded" } elseif ($invocation.Status -eq "Skipped") { "Skipped" } else { "Failed" }
    return $result
}

# ==============================================================================
# 6. STANDALONE EXECUTION (read-only: list packages)
# ==============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    $meta = Get-LiteDeployComponentMetadata
    $listRoot = Resolve-LiteDeployPackageShareRoot -ShareRoot $ShareRoot
    $listDir = Join-LiteDeployPackagePath -Root $listRoot -ChildPath "Content\Packages"

    Write-Host ""
    Write-Host ("{0} v{1} ({2})" -f $meta.Name, $meta.Version, $meta.ComponentId) -ForegroundColor Cyan
    Write-Host ("  Share root : {0}" -f $listRoot)
    Write-Host ("  Packages   : {0}" -f $listDir)

    if (-not (Test-Path -LiteralPath $listDir -PathType Container)) {
        Write-Host "  The Content\Packages folder is not reachable. Use -ShareRoot <path> to point at the deployment share." -ForegroundColor Yellow
        Write-Host ""
        return
    }

    $listed = @(Get-LiteDeployPackages -ShareRoot $listRoot -IncludeDisabled)
    if ($listed.Count -eq 0) {
        Write-Host "  No packages found." -ForegroundColor Yellow
        Write-Host ""
        return
    }

    $rows = foreach ($item in $listed) {
        $validation = Test-LiteDeployPackage -Package $item -Detailed
        [PSCustomObject]@{
            PackageId  = $item.PackageId
            Name       = $item.Name
            Type       = $item.PackageType
            Enabled    = $item.Enabled
            Executable = $item.HasExecutable
            Payload    = $item.PayloadExists
            Valid      = $validation.IsValid
        }
    }

    Write-Host ""
    $rows | Format-Table -AutoSize | Out-Host
}
