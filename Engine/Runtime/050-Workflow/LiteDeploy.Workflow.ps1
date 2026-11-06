<#
.SYNOPSIS
    LiteDeploy Workflow - workflow catalog, validation, and plan resolution (business logic only; no UI).

.DESCRIPTION
    Loads deployment workflow definitions from <ShareRoot>\WorkFlows\*.json and the operating-system
    catalog from <ShareRoot>\Content\OperatingSystems\LocalCatalog.json, validates them, and resolves a workflow
    plus an OS/edition selection into an ordered plan of steps.

    Workflow JSON (schemaVersion 1):
        workflowId, name, description, enabled, revision, osCatalogPath, unattendPath,
        operatingSystems[ { osId, editionIds[] } ], requiredCredentialIds[],
        actions[ { actionId, name, packageId | script | command, phase, executionContext,
                   requiredCredentialIds[], continueOnError } ]

    Public API:
      Get-LiteDeployWorkflows      List workflows (optionally filtered by OS / edition).
      Get-LiteDeployWorkflow       Get one workflow by id, name, or file name.
      Test-LiteDeployWorkflow      Validate a workflow (bool, or -Detailed result).
      Resolve-LiteDeployWorkflow   Resolve workflow + OS selection into an ordered plan.
      Invoke-LiteDeployWorkflow    PLAN STUB: resolves the plan and walks every step without executing it.
      Invoke-LiteDeployStep        STUB: reports what a single step would do.

    Catalog / selection helpers (extracted from LiteDeploy.WorkflowSelection.ps1):
      Get-LiteDeployOperatingSystemsCatalog
      Get-LiteDeployWorkflowSelectionJsonPath
      Save-LiteDeployWorkflowSelectionJson
      New-LiteDeployWorkflowSelectionResult

    Only credential IDs (names) appear in workflows and plans; no secret values are read, stored, or logged.

    Usage:
        . "Z:\Engine\Scripts\Runtime\LiteDeploy.Workflow.ps1"   # load the API
        .\LiteDeploy.Workflow.ps1                               # list workflows from Z:
        .\LiteDeploy.Workflow.ps1 -ShareRoot \\Server\DeploymentShare$
        .\LiteDeploy.Workflow.ps1 -Metadata                     # component metadata only

    ComponentId: Workflow

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
        ComponentId          = "Workflow"
        Name                 = "LiteDeploy Workflow"
        Version              = "2.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "Universal"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("Logs")
        Description          = "Workflow and OS catalog loading, validation, and plan resolution (business logic; UI lives in UI.WorkflowSelection)."
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

$global:LiteDeployWorkflowDefaultShareRoot = "Z:"
$global:LiteDeployWorkflowStepTypes        = @("Package", "Script", "Command", "Disk", "Image", "Drivers", "Reboot")
$global:LiteDeployWorkflowPhases           = @("WinPE", "FullOS")
$global:LiteDeployWorkflowContexts         = @("System", "User")
$global:LiteDeployWorkflowIdPattern        = '^[A-Za-z0-9][A-Za-z0-9._-]*$'

# ==============================================================================
# 3. INTERNAL HELPERS
# ==============================================================================

function Write-LiteDeployWorkflowLog {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO",

        [switch]$NoConsole
    )

    if (Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue) {
        try {
            Write-LiteDeployLog -Message $Message -Level $Level -Component "Workflow" -NoConsole:$NoConsole
        }
        catch {
            # Logging must never break workflow handling.
        }
        return
    }

    if ($NoConsole) { return }
    switch ($Level) {
        "WARNING" { Write-Warning $Message }
        "ERROR"   { Write-Warning $Message }
        default   { Write-Verbose $Message }
    }
}

function Get-LiteDeployWorkflowProperty {
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

function ConvertTo-LiteDeployWorkflowStringArray {
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

function ConvertTo-LiteDeployWorkflowBool {
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

function Join-LiteDeployWorkflowPath {
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

function Test-LiteDeployWorkflowPathInside {
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

function Test-LiteDeployJsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

    try {
        $null = (Get-Content -LiteralPath $Path -Raw) | ConvertFrom-Json -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Resolve-LiteDeployWorkflowShareRoot {
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
        $drive = [string](Get-LiteDeployWorkflowProperty -InputObject $boot -Name "DriveLetter" -Default "")
        $drive = $drive.Trim().TrimEnd('\')
        if ($drive) {
            $deployType = [string](Get-LiteDeployWorkflowProperty -InputObject $boot -Name "DeploymentType" -Default "")
            if ($deployType -ieq "Media") {
                $localRoot = [string](Get-LiteDeployWorkflowProperty -InputObject $boot -Name "LocalRootName" -Default "~LiteDeploy")
                return ("{0}\{1}" -f $drive, $localRoot)
            }
            return $drive
        }
    }

    return $global:LiteDeployWorkflowDefaultShareRoot
}

function ConvertTo-LiteDeployWorkflowObject {
    <#
    .SYNOPSIS
        Normalizes a parsed workflow JSON document into the LiteDeploy.Workflow object used by this API.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Document,
        [string]$SourcePath = "",
        [string]$ShareRoot = ""
    )

    $fileBase = if ($SourcePath) { [System.IO.Path]::GetFileNameWithoutExtension($SourcePath) } else { "" }

    $name = [string](Get-LiteDeployWorkflowProperty -InputObject $Document -Name "name" -Default "")
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $fileBase }

    $osList = New-Object System.Collections.Generic.List[object]
    foreach ($os in @(Get-LiteDeployWorkflowProperty -InputObject $Document -Name "operatingSystems" -Default @())) {
        $osList.Add([PSCustomObject]@{
            OsId       = [string](Get-LiteDeployWorkflowProperty -InputObject $os -Name "osId" -Default "")
            EditionIds = @(ConvertTo-LiteDeployWorkflowStringArray (Get-LiteDeployWorkflowProperty -InputObject $os -Name "editionIds" -Default @()))
        })
    }

    $actionList = New-Object System.Collections.Generic.List[object]
    $order = 0
    foreach ($action in @(Get-LiteDeployWorkflowProperty -InputObject $Document -Name "actions" -Default @())) {
        $order++
        $packageId = [string](Get-LiteDeployWorkflowProperty -InputObject $action -Name "packageId" -Default "")
        $scriptPath = [string](Get-LiteDeployWorkflowProperty -InputObject $action -Name "script" -Default "")
        $command = [string](Get-LiteDeployWorkflowProperty -InputObject $action -Name "command" -Default "")

        $type = [string](Get-LiteDeployWorkflowProperty -InputObject $action -Name "type" -Default "")
        if ([string]::IsNullOrWhiteSpace($type)) {
            if ($packageId) { $type = "Package" }
            elseif ($scriptPath) { $type = "Script" }
            elseif ($command) { $type = "Command" }
            else { $type = "Package" }
        }

        $actionList.Add([PSCustomObject]@{
            Order                 = $order
            ActionId              = [string](Get-LiteDeployWorkflowProperty -InputObject $action -Name "actionId" -Default "")
            Name                  = [string](Get-LiteDeployWorkflowProperty -InputObject $action -Name "name" -Default "")
            Type                  = $type
            PackageId             = $packageId
            Script                = $scriptPath
            Command               = $command
            Arguments             = @(ConvertTo-LiteDeployWorkflowStringArray (Get-LiteDeployWorkflowProperty -InputObject $action -Name "arguments" -Default @()))
            Phase                 = [string](Get-LiteDeployWorkflowProperty -InputObject $action -Name "phase" -Default "FullOS")
            ExecutionContext      = [string](Get-LiteDeployWorkflowProperty -InputObject $action -Name "executionContext" -Default "System")
            RequiredCredentialIds = @(ConvertTo-LiteDeployWorkflowStringArray (Get-LiteDeployWorkflowProperty -InputObject $action -Name "requiredCredentialIds" -Default @()))
            ContinueOnError       = (ConvertTo-LiteDeployWorkflowBool -Value (Get-LiteDeployWorkflowProperty -InputObject $action -Name "continueOnError") -Default $false)
            Enabled               = (ConvertTo-LiteDeployWorkflowBool -Value (Get-LiteDeployWorkflowProperty -InputObject $action -Name "enabled") -Default $true)
        })
    }

    $revision = 0
    [void][int]::TryParse([string](Get-LiteDeployWorkflowProperty -InputObject $Document -Name "revision" -Default 0), [ref]$revision)
    $schemaVersion = 0
    [void][int]::TryParse([string](Get-LiteDeployWorkflowProperty -InputObject $Document -Name "schemaVersion" -Default 0), [ref]$schemaVersion)
    $order = 0
    [void][int]::TryParse([string](Get-LiteDeployWorkflowProperty -InputObject $Document -Name "order" -Default 0), [ref]$order)
    $expanded = (ConvertTo-LiteDeployWorkflowBool -Value (Get-LiteDeployWorkflowProperty -InputObject $Document -Name "expanded" -Default $false) -Default $false)
    $comment = [string](Get-LiteDeployWorkflowProperty -InputObject $Document -Name "comment" -Default "")
    $computerSetup = Get-LiteDeployWorkflowProperty -InputObject $Document -Name "computerSetup" -Default $null

    return [PSCustomObject]@{
        PSTypeName            = "LiteDeploy.Workflow"
        WorkflowId            = [string](Get-LiteDeployWorkflowProperty -InputObject $Document -Name "workflowId" -Default "")
        Name                  = $name
        Description           = [string](Get-LiteDeployWorkflowProperty -InputObject $Document -Name "description" -Default "")
        Order                 = $order
        Expanded              = $expanded
        Comment               = $comment
        ComputerSetup         = $computerSetup
        Enabled               = (ConvertTo-LiteDeployWorkflowBool -Value (Get-LiteDeployWorkflowProperty -InputObject $Document -Name "enabled") -Default $true)
        Revision              = $revision
        SchemaVersion         = $schemaVersion
        OsCatalogPath         = [string](Get-LiteDeployWorkflowProperty -InputObject $Document -Name "osCatalogPath" -Default "")
        UnattendPath          = [string](Get-LiteDeployWorkflowProperty -InputObject $Document -Name "unattendPath" -Default "")
        OperatingSystems      = $osList.ToArray()
        RequiredCredentialIds = @(ConvertTo-LiteDeployWorkflowStringArray (Get-LiteDeployWorkflowProperty -InputObject $Document -Name "requiredCredentialIds" -Default @()))
        Actions               = $actionList.ToArray()
        SourcePath            = $SourcePath
        FileName              = $fileBase
        ShareRoot             = $ShareRoot
    }
}

function Initialize-LiteDeployWorkflowInput {
    # Accepts an already-normalized workflow, or a raw parsed JSON document, and returns a normalized workflow.
    param(
        [Parameter(Mandatory = $true)]
        $Workflow,
        [string]$ShareRoot = ""
    )

    if (@($Workflow.PSObject.TypeNames) -contains "LiteDeploy.Workflow") { return $Workflow }
    return (ConvertTo-LiteDeployWorkflowObject -Document $Workflow -ShareRoot $ShareRoot)
}

function Find-LiteDeployCatalogEdition {
    <#
    .SYNOPSIS
        Finds an OS (and optional edition) in an OS catalog result. Returns { OperatingSystem, Edition } or $null.
    #>
    param(
        $Catalog,
        [string]$OsId,
        [string]$EditionId = ""
    )

    if ($null -eq $Catalog -or [string]::IsNullOrWhiteSpace($OsId)) { return $null }

    foreach ($os in @($Catalog.OperatingSystems)) {
        $candidateId = [string](Get-LiteDeployWorkflowProperty -InputObject $os -Name "osId" -Default "")
        if ($candidateId -ine $OsId) { continue }

        $edition = $null
        if (-not [string]::IsNullOrWhiteSpace($EditionId)) {
            foreach ($ed in @(Get-LiteDeployWorkflowProperty -InputObject $os -Name "editions" -Default @())) {
                $edId = [string](Get-LiteDeployWorkflowProperty -InputObject $ed -Name "editionId" -Default "")
                if ($edId -ieq $EditionId) { $edition = $ed; break }
            }
            if ($null -eq $edition) { return $null }
        }

        return [PSCustomObject]@{
            OperatingSystem = $os
            Edition         = $edition
        }
    }

    return $null
}

# ==============================================================================
# 4. OS CATALOG (extracted from WorkflowSelection: ImportOSMedia Content\OperatingSystems\LocalCatalog.json)
# ==============================================================================

function Get-LiteDeployOperatingSystemsCatalog {
    <#
    .SYNOPSIS
        Reads the OS catalog. Returns { CatalogPath, OperatingSystems } or $null when missing/invalid.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShareRoot,

        [string]$RelativePath = "Content\OperatingSystems\LocalCatalog.json"
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) { $RelativePath = "Content\OperatingSystems\LocalCatalog.json" }

    $catalogPath = Join-LiteDeployWorkflowPath -Root $ShareRoot -ChildPath $RelativePath
    if (-not (Test-LiteDeployJsonFile -Path $catalogPath)) {
        return $null
    }

    $catalogData = Get-Content -LiteralPath $catalogPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $catalogData -or -not $catalogData.PSObject.Properties["operatingSystems"]) {
        return $null
    }

    return [PSCustomObject]@{
        CatalogPath      = $catalogPath
        OperatingSystems = @($catalogData.operatingSystems)
    }
}

function Test-JSONFormat {
    <#
    .SYNOPSIS
        True when the file exists and parses as JSON (same contract as the WorkflowSelection helper).
    #>
    param([string]$Path)

    return (Test-LiteDeployJsonFile -Path $Path)
}

function Get-LiteDeployNativeArchitecture {
    <#
    .SYNOPSIS
        Returns the normalized native CPU architecture (x64, arm64, x86).
    #>
    $rawArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch -Regex ([string]$rawArch) {
        'ARM64|AARCH64' { return 'arm64' }
        'x86|i386'      { return 'x86' }
        default         { return 'x64' }
    }
}

function Get-LiteDeployEditionListLabel {
    <#
    .SYNOPSIS
        Selectable row title. Appends " (version)" only when the edition name does not already contain it.
        "Windows 11 Pro" + 25H2 -> "Windows 11 Pro (25H2)".
        "Windows 11 25H2 Testing" + 25H2 -> "Windows 11 25H2 Testing".
    #>
    param(
        [psobject]$Edition,
        [psobject]$Os
    )

    $edName = "Operating System"
    if ($Edition -and $Edition.PSObject.Properties['editionName'] -and $Edition.editionName) {
        $edName = [string]$Edition.editionName
    }
    elseif ($Edition -and $Edition.PSObject.Properties['name'] -and $Edition.name) {
        $edName = [string]$Edition.name
    }
    elseif ($Os -and $Os.PSObject.Properties['fullName'] -and $Os.fullName) {
        $edName = [string]$Os.fullName
    }
    $edName = $edName.Trim()

    $ver = $null
    if ($Edition -and $Edition.PSObject.Properties['version'] -and $Edition.version) {
        $ver = [string]$Edition.version
    }
    elseif ($Os -and $Os.PSObject.Properties['version'] -and $Os.version) {
        $ver = [string]$Os.version
    }
    if ($ver) { $ver = $ver.Trim() }

    if ($ver -and $edName.IndexOf($ver, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        return "$edName ($ver)"
    }
    return $edName
}

function Get-LiteDeployOsCatalogDateText {
    <#
    .SYNOPSIS
        "Imported: <date> | Leng: <lang> | Build <n>" subtitle used by the WorkflowSelection tree.
    #>
    param(
        [psobject]$Os,
        [psobject]$Edition = $null,
        [string]$Separator = " | "
    )

    $imported = $null
    if ($Os -and $Os.PSObject.Properties["importedDate"] -and $Os.importedDate) {
        $imported = [string]$Os.importedDate
    }

    $lang = $null
    if ($Edition -and $Edition.PSObject.Properties["defaultLanguage"] -and $Edition.defaultLanguage) {
        $lang = [string]$Edition.defaultLanguage
    }
    elseif ($Os -and $Os.PSObject.Properties["defaultLanguage"] -and $Os.defaultLanguage) {
        $lang = [string]$Os.defaultLanguage
    }

    $build = $null
    if ($Edition -and $Edition.PSObject.Properties["buildVersion"] -and $Edition.buildVersion) {
        $build = [string]$Edition.buildVersion
    }
    elseif ($Os -and $Os.PSObject.Properties["buildVersion"] -and $Os.buildVersion) {
        $build = [string]$Os.buildVersion
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    if ($imported) { $parts.Add("Imported: $imported") }
    if ($lang) { $parts.Add("Leng: $lang") }
    if ($build) { $parts.Add("Build $build") }

    if ($parts.Count -eq 0) { return "Ready" }
    return ($parts -join $Separator)
}

function Get-LiteDeployWorkflowPresentationGroups {
    <#
    .SYNOPSIS
        Resolves workflows (or fallback OS catalog) into display groups for Populate-WorkflowTreeView.
    #>
    param(
        [psobject]$CatalogResult = $null,
        [string]$ShareRoot = "",
        [string]$MachineArch = ""
    )

    if ([string]::IsNullOrWhiteSpace($MachineArch)) {
        $MachineArch = Get-LiteDeployNativeArchitecture
    }

    $groups = [System.Collections.Generic.List[object]]::new()
    $workflows = @(Get-LiteDeployWorkflows -ShareRoot $ShareRoot)

    # Build OS lookup from catalog
    $osMap = @{}
    if ($CatalogResult -and $CatalogResult.PSObject.Properties["OperatingSystems"] -and $CatalogResult.OperatingSystems) {
        foreach ($os in @($CatalogResult.OperatingSystems)) {
            if (-not ($os.PSObject.Properties['enabled'] -and $os.enabled -eq $false)) {
                $osMap[[string]$os.osId] = $os
            }
        }
    }

    if (@($workflows).Count -gt 0) {
        # MODE 1: Workflows exist
        $expandSingle = (@($workflows).Count -eq 1)

        foreach ($wf in @($workflows)) {
            $entries = [System.Collections.Generic.List[object]]::new()

            if ($wf.OperatingSystems -and @($wf.OperatingSystems).Count -gt 0) {
                foreach ($wfOs in @($wf.OperatingSystems)) {
                    $osId = [string]$wfOs.OsId
                    if ($osMap.ContainsKey($osId)) {
                        $catOs = $osMap[$osId]
                        
                        # Check CPU Architecture compatibility
                        $catArch = if ($catOs.PSObject.Properties['arch']) { [string]$catOs.arch } else { "" }
                        if (-not [string]::IsNullOrWhiteSpace($catArch) -and -not [string]::IsNullOrWhiteSpace($MachineArch)) {
                            if ($catArch -ine $MachineArch) {
                                continue
                            }
                        }

                        $editions = if ($catOs.PSObject.Properties['editions'] -and $catOs.editions) {
                            @($catOs.editions | Where-Object { -not ($_.PSObject.Properties['enabled'] -and $_.enabled -eq $false) })
                        } else { @() }

                        $assignedEdIds = @($wfOs.EditionIds)

                        foreach ($ed in @($editions)) {
                            $edId = if ($ed.PSObject.Properties['editionId']) { [string]$ed.editionId } else { "" }
                            
                            if ($assignedEdIds.Count -gt 0 -and ($assignedEdIds -notcontains $edId)) {
                                continue
                            }

                            $displayName = Get-LiteDeployEditionListLabel -Edition $ed -Os $catOs
                            $dateText = Get-LiteDeployOsCatalogDateText -Os $catOs -Edition $ed

                            $edIndex = if ($ed.PSObject.Properties['imageIndex'] -and $null -ne $ed.imageIndex) { [int]$ed.imageIndex }
                            elseif ($ed.PSObject.Properties['index'] -and $null -ne $ed.index) { [int]$ed.index }
                            else { 1 }

                            $entries.Add([PSCustomObject]@{
                                Name     = $displayName
                                DateText = $dateText
                                Tag      = [PSCustomObject]@{
                                    WorkflowId    = $wf.WorkflowId
                                    WorkflowName  = $wf.Name
                                    UnattendPath  = $wf.UnattendPath
                                    ComputerSetup = $wf.ComputerSetup
                                    Actions       = @($wf.Actions)
                                    OsId          = $catOs.osId
                                    EditionId     = $edId
                                    Name          = $displayName
                                    SkuCode       = if ($ed.PSObject.Properties['skuCode']) { $ed.skuCode } else { "" }
                                    Index         = $edIndex
                                    ImagePath     = $catOs.imagePath
                                    SetupPath     = $catOs.setupPath
                                    MediaRoot     = $catOs.mediaRoot
                                    Arch          = $catArch
                                    Language      = if ($catOs.PSObject.Properties['defaultLanguage']) { $catOs.defaultLanguage } else { "" }
                                    ImportedDate  = if ($catOs.PSObject.Properties['importedDate']) { $catOs.importedDate } else { $null }
                                }
                            })
                        }
                    }
                }
            }

            # If workflow has no matching/assigned OS
            if ($entries.Count -eq 0) {
                $entries.Add([PSCustomObject]@{
                    Name     = "⚠️ No available operating systems assigned"
                    DateText = "Architecture: $MachineArch"
                    Tag      = $null
                })
            }

            $groups.Add([PSCustomObject]@{
                Title        = $wf.Name
                Description  = $wf.Description
                ExpandOnLoad = ($expandSingle -or $wf.Expanded)
                Entries      = @($entries.ToArray())
            })
        }

        return @($groups.ToArray())
    }

    # MODE 2: Fallback to Catalog directly (when no workflows exist)
    if ($CatalogResult -and $CatalogResult.PSObject.Properties["OperatingSystems"] -and $CatalogResult.OperatingSystems) {
        $enabledOsList = @(
            @($CatalogResult.OperatingSystems) | Where-Object {
                -not ($_.PSObject.Properties['enabled'] -and $_.enabled -eq $false) -and
                ([string]::IsNullOrWhiteSpace($_.arch) -or [string]::IsNullOrWhiteSpace($MachineArch) -or ($_.arch -ieq $MachineArch))
            }
        )
        $expandSingle = ($enabledOsList.Count -eq 1)

        foreach ($os in $enabledOsList) {
            $langTag = if ($os.defaultLanguage) { " [$($os.defaultLanguage)]" } else { "" }
            $parentTitle = if ($os.fullName) { "$($os.fullName)$langTag" } elseif ($os.osName) { "$($os.osName)$langTag" } else { "Operating System" }

            $expandOnLoad = $false
            if ($os.PSObject.Properties['expanded']) { $expandOnLoad = [bool]$os.expanded }
            elseif ($os.PSObject.Properties['Expanded']) { $expandOnLoad = [bool]$os.Expanded }
            elseif ($os.PSObject.Properties['expandOnLoad']) { $expandOnLoad = [bool]$os.expandOnLoad }
            elseif ($os.PSObject.Properties['ExpandOnLoad']) { $expandOnLoad = [bool]$os.ExpandOnLoad }

            $editions = if ($os.PSObject.Properties['editions'] -and $os.editions) {
                @($os.editions | Where-Object { -not ($_.PSObject.Properties['enabled'] -and $_.enabled -eq $false) })
            } else { @() }

            $entries = [System.Collections.Generic.List[object]]::new()
            foreach ($ed in @($editions)) {
                $displayName = Get-LiteDeployEditionListLabel -Edition $ed -Os $os
                $dateText = Get-LiteDeployOsCatalogDateText -Os $os -Edition $ed

                $edIndex = if ($ed.PSObject.Properties['imageIndex'] -and $null -ne $ed.imageIndex) { [int]$ed.imageIndex }
                elseif ($ed.PSObject.Properties['index'] -and $null -ne $ed.index) { [int]$ed.index }
                else { 1 }

                $entries.Add([PSCustomObject]@{
                    Name     = $displayName
                    DateText = $dateText
                    Tag      = [PSCustomObject]@{
                        OsId         = $os.osId
                        EditionId    = if ($ed.PSObject.Properties['editionId']) { $ed.editionId } else { $os.osId }
                        Name         = $displayName
                        SkuCode      = if ($ed.PSObject.Properties['skuCode']) { $ed.skuCode } else { "" }
                        Index        = $edIndex
                        ImagePath    = $os.imagePath
                        SetupPath    = $os.setupPath
                        MediaRoot    = $os.mediaRoot
                        Arch         = $os.arch
                        Language     = $os.defaultLanguage
                        ImportedDate = if ($os.PSObject.Properties['importedDate']) { $os.importedDate } else { $null }
                    }
                })
            }

            if ($entries.Count -gt 0) {
                $groups.Add([PSCustomObject]@{
                    Title        = $parentTitle
                    Description  = ""
                    ExpandOnLoad = ($expandSingle -or $expandOnLoad)
                    Entries      = @($entries.ToArray())
                })
            }
        }
    }

    return @($groups.ToArray())
}

function Get-LiteDeployOsWorkflowEntries {
    <#
    .SYNOPSIS
        Compatibility wrapper around Get-LiteDeployWorkflowPresentationGroups.
    #>
    param([psobject]$CatalogResult = $null)

    return (Get-LiteDeployWorkflowPresentationGroups -CatalogResult $CatalogResult)
}

# ==============================================================================
# 5. WORKFLOW SELECTION RESULT HELPERS (extracted from WorkflowSelection)
# ==============================================================================

function Get-LiteDeployWorkflowSelectionJsonPath {
    $sysDrive = if ($env:SystemDrive) { ([string]$env:SystemDrive).TrimEnd('\') } else { "X:" }
    return ("{0}\WorkflowSelection.json" -f $sysDrive)
}

function Save-LiteDeployWorkflowSelectionJson {
    param(
        [Parameter(Mandatory = $true)]
        $Selection,

        [string]$Path = ""
    )

    $targetPath = if ([string]::IsNullOrWhiteSpace($Path)) { Get-LiteDeployWorkflowSelectionJsonPath } else { $Path }
    $json = ($Selection | ConvertTo-Json -Depth 6)
    Set-Content -LiteralPath $targetPath -Value $json -Encoding UTF8 -Force
    return $targetPath
}

function New-LiteDeployWorkflowSelectionResult {
    <#
    .SYNOPSIS
        Builds the WorkflowSelection result contract (Passed, Status, selection fields).

    .NOTES
        BootConfigPath / DeploymentSharePath / DeploymentUid fall back to the caller script's
        caller script BootConfigPath / DeploymentSharePath / DeploymentUid when not supplied
        (the WorkflowSelection UI sets those). WorkflowTag is an object (OsId, EditionId, Index, ImagePath, ...).
    #>
    param(
        [bool]$Passed,
        [string]$Status,
        [string]$SelectionJsonPath = $null,
        [string]$ComputerName = $null,
        [string]$ComputerDescription = $null,
        [string]$WorkflowName = $null,
        [object]$WorkflowTag = $null,
        [object]$TargetDiskIndex = $null,
        [string]$TargetDiskModel = $null,
        [string]$DriverFolderPath = $null,
        [bool]$AutoDetectDrivers = $false,
        [string]$BootConfigPath = "",
        [string]$DeploymentSharePath = "",
        [string]$DeploymentUid = ""
    )

    if ([string]::IsNullOrWhiteSpace($BootConfigPath)) {
        $BootConfigPath = [string](Get-Variable -Name BootConfigPath -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    }
    if ([string]::IsNullOrWhiteSpace($DeploymentSharePath)) {
        $DeploymentSharePath = [string](Get-Variable -Name DeploymentSharePath -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    }
    if ([string]::IsNullOrWhiteSpace($DeploymentUid)) {
        $DeploymentUid = [string](Get-Variable -Name DeploymentUid -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    }

    return [PSCustomObject]@{
        Passed              = [bool]$Passed
        Status              = $Status
        SelectionJsonPath   = $SelectionJsonPath
        BootConfigPath      = $BootConfigPath
        DeploymentSharePath = $DeploymentSharePath
        DeploymentUid       = $DeploymentUid
        ComputerName        = $ComputerName
        ComputerDescription = $ComputerDescription
        WorkflowName        = $WorkflowName
        WorkflowTag         = $WorkflowTag
        TargetDiskIndex     = $TargetDiskIndex
        TargetDiskModel     = $TargetDiskModel
        DriverFolderPath    = $DriverFolderPath
        AutoDetectDrivers   = [bool]$AutoDetectDrivers
    }
}

# ==============================================================================
# 6. PUBLIC API - WORKFLOW CATALOG
# ==============================================================================

function Get-LiteDeployWorkflows {
    <#
    .SYNOPSIS
        Lists workflows from <ShareRoot>\WorkFlows\*.json (sorted by file name).

    .DESCRIPTION
        Disabled workflows are skipped unless -IncludeDisabled. -OsId / -EditionId keep only workflows that
        support that operating system / edition (a workflow with no operatingSystems list supports all).
        Unreadable JSON files are logged as warnings and skipped. Wrap results in @(...).

    .EXAMPLE
        @(Get-LiteDeployWorkflows -ShareRoot Z: -OsId win11-25h2-en-us-26200.8037-x64)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = "",

        [Parameter(Mandatory = $false)]
        [string]$OsId = "",

        [Parameter(Mandatory = $false)]
        [string]$EditionId = "",

        [Parameter(Mandatory = $false)]
        [switch]$IncludeDisabled,

        [Parameter(Mandatory = $false)]
        [switch]$CacheOnRAM
    )

    $root = Resolve-LiteDeployWorkflowShareRoot -ShareRoot $ShareRoot
    $workflowDir = Join-LiteDeployWorkflowPath -Root $root -ChildPath "WorkFlows"
    $found = New-Object System.Collections.Generic.List[object]

    # Fast RAM cache check for WinPE Network mode (Active only when -CacheOnRAM is explicitly enabled)
    $ramCacheDir = "X:\~LiteDeploy\Cache\WorkFlows"
    $effectiveWorkflowDir = $workflowDir
    $isWinPE = (Test-Path -LiteralPath "X:\Windows\System32" -PathType Container)
    if ($CacheOnRAM -and $isWinPE -and (Test-Path -LiteralPath $ramCacheDir -PathType Container)) {
        $cachedFiles = @(Get-ChildItem -LiteralPath $ramCacheDir -Filter "*.json" -File -ErrorAction SilentlyContinue)
        if ($cachedFiles.Count -gt 0) {
            $effectiveWorkflowDir = $ramCacheDir
        }
    }

    if (-not (Test-Path -LiteralPath $effectiveWorkflowDir -PathType Container)) {
        return
    }

    $files = @(Get-ChildItem -LiteralPath $effectiveWorkflowDir -Filter "*.json" -File -ErrorAction SilentlyContinue | Sort-Object -Property Name)
    foreach ($file in $files) {
        $parsed = $null
        try {
            $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
            $parsed = $content | ConvertFrom-Json -ErrorAction Stop
            if ($CacheOnRAM -and $isWinPE -and $effectiveWorkflowDir -ne $ramCacheDir) {
                if (-not (Test-Path -LiteralPath $ramCacheDir)) {
                    $null = New-Item -Path $ramCacheDir -ItemType Directory -Force -ErrorAction SilentlyContinue
                }
                Set-Content -LiteralPath (Join-Path $ramCacheDir $file.Name) -Value $content -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-LiteDeployWorkflowLog -Message "Skipping workflow file '$($file.Name)': $($_.Exception.Message)" -Level "WARNING" -NoConsole
            continue
        }

        # A file may hold one workflow, an array of workflows, or { "workflows": [ ... ] }.
        $documents = New-Object System.Collections.Generic.List[object]
        foreach ($doc in @($parsed)) {
            if ($null -eq $doc) { continue }
            $nested = Get-LiteDeployWorkflowProperty -InputObject $doc -Name "workflows"
            if ($null -ne $nested) {
                foreach ($inner in @($nested)) { if ($null -ne $inner) { $documents.Add($inner) } }
            }
            else {
                $documents.Add($doc)
            }
        }

        foreach ($document in $documents) {
            $workflow = ConvertTo-LiteDeployWorkflowObject -Document $document -SourcePath $file.FullName -ShareRoot $root

            if (-not $IncludeDisabled -and -not $workflow.Enabled) { continue }

            if (-not [string]::IsNullOrWhiteSpace($OsId) -and @($workflow.OperatingSystems).Count -gt 0) {
                $osEntry = $null
                foreach ($candidate in @($workflow.OperatingSystems)) {
                    if ($candidate.OsId -ieq $OsId) { $osEntry = $candidate; break }
                }
                if ($null -eq $osEntry) { continue }

                if (-not [string]::IsNullOrWhiteSpace($EditionId) -and @($osEntry.EditionIds).Count -gt 0) {
                    $editionMatch = $false
                    foreach ($edId in @($osEntry.EditionIds)) {
                        if ($edId -ieq $EditionId) { $editionMatch = $true; break }
                    }
                    if (-not $editionMatch) { continue }
                }
            }

            $found.Add($workflow)
        }
    }

    $sorted = @($found | Sort-Object -Property @{ Expression = { if ($_.Order -gt 0) { [int]$_.Order } else { [int]::MaxValue } } }, Name)
    return $sorted
}

function Get-LiteDeployWorkflow {
    <#
    .SYNOPSIS
        Gets one workflow by workflowId, name, or file name (case-insensitive). Returns $null when not found.
        Disabled workflows are included.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Identity,

        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = ""
    )

    $all = @(Get-LiteDeployWorkflows -ShareRoot $ShareRoot -IncludeDisabled)

    foreach ($wf in $all) { if ($wf.WorkflowId -and $wf.WorkflowId -ieq $Identity) { return $wf } }
    foreach ($wf in $all) { if ($wf.Name -ieq $Identity) { return $wf } }
    foreach ($wf in $all) { if ($wf.FileName -ieq $Identity) { return $wf } }
    return $null
}

function Test-LiteDeployWorkflow {
    <#
    .SYNOPSIS
        Validates a workflow (by -Identity, or a -Workflow object / raw parsed JSON).

    .DESCRIPTION
        Returns $true/$false, or { IsValid, Errors, Warnings, WorkflowId } with -Detailed.
        Errors: missing/invalid ids, unknown step types, duplicate action ids, unsafe paths, packages that
        do not exist under Content\Packages. Warnings: disabled workflow, unknown schema/phase/context,
        catalog or unattend files that cannot be found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Identity = "",

        [Parameter(Mandatory = $false)]
        [psobject]$Workflow = $null,

        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = "",

        [Parameter(Mandatory = $false)]
        [switch]$Detailed
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $wf = $null

    if ($null -ne $Workflow) {
        $wf = Initialize-LiteDeployWorkflowInput -Workflow $Workflow -ShareRoot $ShareRoot
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Identity)) {
        $wf = Get-LiteDeployWorkflow -Identity $Identity -ShareRoot $ShareRoot
        if ($null -eq $wf) { $errors.Add("Workflow '$Identity' was not found.") }
    }
    else {
        $errors.Add("Specify -Identity or -Workflow.")
    }

    $workflowId = ""
    if ($null -ne $wf) {
        $workflowId = $wf.WorkflowId

        $root = if (-not [string]::IsNullOrWhiteSpace($ShareRoot)) {
            Resolve-LiteDeployWorkflowShareRoot -ShareRoot $ShareRoot
        }
        elseif (-not [string]::IsNullOrWhiteSpace($wf.ShareRoot)) {
            $wf.ShareRoot
        }
        else {
            Resolve-LiteDeployWorkflowShareRoot
        }

        if ($wf.SchemaVersion -ne 1) {
            $warnings.Add("schemaVersion '$($wf.SchemaVersion)' is not the supported version (1).")
        }

        if ([string]::IsNullOrWhiteSpace($wf.WorkflowId)) { $errors.Add("workflowId is required.") }
        elseif ($wf.WorkflowId -notmatch $global:LiteDeployWorkflowIdPattern) { $errors.Add("workflowId '$($wf.WorkflowId)' may only contain letters, digits, '.', '_' and '-'.") }

        if ([string]::IsNullOrWhiteSpace($wf.Name)) { $errors.Add("name is required.") }
        if (-not $wf.Enabled) { $warnings.Add("Workflow is disabled.") }

        # --- OS catalog + unattend paths --------------------------------------
        $catalogRelative = if ($wf.OsCatalogPath) { $wf.OsCatalogPath } else { "Content\OperatingSystems\LocalCatalog.json" }
        $catalogFull = Join-LiteDeployWorkflowPath -Root $root -ChildPath $catalogRelative
        $catalog = $null
        if (-not (Test-LiteDeployWorkflowPathInside -ChildPath $catalogFull -ParentPath $root)) {
            $errors.Add("osCatalogPath '$($wf.OsCatalogPath)' escapes the share root.")
        }
        else {
            try { $catalog = Get-LiteDeployOperatingSystemsCatalog -ShareRoot $root -RelativePath $catalogRelative } catch { $catalog = $null }
            if ($null -eq $catalog -and @($wf.OperatingSystems).Count -gt 0) {
                $warnings.Add("OS catalog '$catalogRelative' was not found or is invalid; operating systems could not be verified.")
            }
        }

        if ($wf.UnattendPath) {
            $unattendFull = Join-LiteDeployWorkflowPath -Root $root -ChildPath $wf.UnattendPath
            if (-not (Test-LiteDeployWorkflowPathInside -ChildPath $unattendFull -ParentPath $root)) {
                $errors.Add("unattendPath '$($wf.UnattendPath)' escapes the share root.")
            }
            elseif (-not (Test-Path -LiteralPath $unattendFull -PathType Leaf)) {
                $warnings.Add("unattendPath '$($wf.UnattendPath)' was not found under the share root.")
            }
        }

        # --- Operating systems --------------------------------------------------
        foreach ($os in @($wf.OperatingSystems)) {
            if ([string]::IsNullOrWhiteSpace($os.OsId)) { $errors.Add("operatingSystems entry is missing osId."); continue }
            if ($null -eq $catalog) { continue }

            $osHit = Find-LiteDeployCatalogEdition -Catalog $catalog -OsId $os.OsId
            if ($null -eq $osHit) { $warnings.Add("osId '$($os.OsId)' is not in the OS catalog."); continue }
            foreach ($edId in @($os.EditionIds)) {
                if ($null -eq (Find-LiteDeployCatalogEdition -Catalog $catalog -OsId $os.OsId -EditionId $edId)) {
                    $warnings.Add("editionId '$edId' is not in the OS catalog for '$($os.OsId)'.")
                }
            }
        }

        # --- Actions -----------------------------------------------------------
        $packagesDir = Join-LiteDeployWorkflowPath -Root $root -ChildPath "Content\Packages"
        $packagesDirExists = Test-Path -LiteralPath $packagesDir -PathType Container
        $needsPackageCheck = $false
        $seenActionIds = @{}

        foreach ($action in @($wf.Actions)) {
            $label = if ($action.ActionId) { "Action '$($action.ActionId)'" } else { "Action #$($action.Order)" }

            if ([string]::IsNullOrWhiteSpace($action.ActionId)) { $errors.Add("$label is missing actionId.") }
            elseif ($action.ActionId -notmatch $global:LiteDeployWorkflowIdPattern) { $errors.Add("$label has an invalid actionId.") }
            elseif ($seenActionIds.ContainsKey($action.ActionId.ToLowerInvariant())) { $errors.Add("$label is duplicated.") }
            else { $seenActionIds[$action.ActionId.ToLowerInvariant()] = $true }

            if ($global:LiteDeployWorkflowStepTypes -notcontains $action.Type) {
                $errors.Add("$label has unknown type '$($action.Type)'.")
            }

            switch ($action.Type) {
                "Package" {
                    if ([string]::IsNullOrWhiteSpace($action.PackageId)) { $errors.Add("$label requires packageId.") }
                    elseif ($action.PackageId -notmatch $global:LiteDeployWorkflowIdPattern) { $errors.Add("$label has an invalid packageId '$($action.PackageId)'.") }
                    elseif ($packagesDirExists) {
                        $manifest = Join-LiteDeployWorkflowPath -Root $packagesDir -ChildPath ("{0}\package.json" -f $action.PackageId)
                        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { $errors.Add("$label references package '$($action.PackageId)' which was not found in Content\Packages.") }
                    }
                    else { $needsPackageCheck = $true }
                }
                "Script" {
                    if ([string]::IsNullOrWhiteSpace($action.Script)) { $errors.Add("$label requires script.") }
                }
                "Command" {
                    if ([string]::IsNullOrWhiteSpace($action.Command)) { $errors.Add("$label requires command.") }
                }
            }

            if ($global:LiteDeployWorkflowPhases -notcontains $action.Phase) {
                $warnings.Add("$label has unrecognized phase '$($action.Phase)' (expected WinPE or FullOS).")
            }
            if ($global:LiteDeployWorkflowContexts -notcontains $action.ExecutionContext) {
                $warnings.Add("$label has unrecognized executionContext '$($action.ExecutionContext)' (expected System or User).")
            }
        }

        if ($needsPackageCheck) {
            $warnings.Add("Content\Packages was not found under '$root'; package references were not verified.")
        }
    }

    $isValid = ($errors.Count -eq 0)
    if (-not $Detailed) { return $isValid }

    return [PSCustomObject]@{
        IsValid    = $isValid
        Errors     = $errors.ToArray()
        Warnings   = $warnings.ToArray()
        WorkflowId = $workflowId
    }
}

# ==============================================================================
# 7. PUBLIC API - PLAN RESOLUTION & (STUB) EXECUTION
# ==============================================================================

function New-LiteDeployWorkflowPlanStep {
    param(
        [string]$StepId,
        [string]$Name,
        [string]$Type,
        [string]$Phase,
        [string]$ExecutionContext = "System",
        [string]$PackageId = "",
        [string]$Script = "",
        [string]$Command = "",
        [string[]]$Arguments = @(),
        [string[]]$RequiredCredentialIds = @(),
        [bool]$ContinueOnError = $false,
        [bool]$Enabled = $true,
        [bool]$IsImplicit = $false,
        [hashtable]$Parameters = @{}
    )

    return [PSCustomObject]@{
        PSTypeName            = "LiteDeploy.WorkflowStep"
        Order                 = 0
        StepId                = $StepId
        Name                  = $Name
        Type                  = $Type
        Phase                 = $Phase
        ExecutionContext      = $ExecutionContext
        PackageId             = $PackageId
        Script                = $Script
        Command               = $Command
        Arguments             = @($Arguments)
        RequiredCredentialIds = @($RequiredCredentialIds)
        ContinueOnError       = $ContinueOnError
        Enabled               = $Enabled
        Implicit              = $IsImplicit
        Parameters            = $Parameters
    }
}

function Resolve-LiteDeployWorkflow {
    <#
    .SYNOPSIS
        Resolves a workflow and an OS/edition selection into an ordered plan.

    .DESCRIPTION
        The workflow comes from -Workflow, else -Identity (id / name / file name), else the single enabled
        workflow that supports the selected OS. The OS selection comes from -OsId/-EditionId or from a
        WorkflowSelection result passed as -Selection (WorkflowTag.OsId / EditionId).

        Plan steps = implicit WinPE steps (Disk, Image; omitted with -ActionsOnly or when no OS resolves)
        followed by the workflow actions in file order. Throws when the workflow is missing, disabled,
        invalid, does not support the selected OS, or the OS is not in the catalog.

    .OUTPUTS
        LiteDeploy.WorkflowPlan: WorkflowId, WorkflowName, Revision, ShareRoot, UnattendPath, OsId, EditionId,
        OperatingSystem, Edition, Steps, RequiredCredentialIds, Warnings, ResolvedTime, Workflow.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Identity = "",

        [Parameter(Mandatory = $false)]
        [psobject]$Workflow = $null,

        [Parameter(Mandatory = $false)]
        [psobject]$Selection = $null,

        [Parameter(Mandatory = $false)]
        [string]$OsId = "",

        [Parameter(Mandatory = $false)]
        [string]$EditionId = "",

        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = "",

        [Parameter(Mandatory = $false)]
        [switch]$ActionsOnly
    )

    $warnings = New-Object System.Collections.Generic.List[string]

    $root = $null
    if (-not [string]::IsNullOrWhiteSpace($ShareRoot)) {
        $root = Resolve-LiteDeployWorkflowShareRoot -ShareRoot $ShareRoot
    }
    elseif ($null -ne $Workflow -and -not [string]::IsNullOrWhiteSpace([string](Get-LiteDeployWorkflowProperty -InputObject $Workflow -Name "ShareRoot" -Default ""))) {
        $root = [string](Get-LiteDeployWorkflowProperty -InputObject $Workflow -Name "ShareRoot")
    }
    else {
        $root = Resolve-LiteDeployWorkflowShareRoot
    }

    # ---- Selection input -----------------------------------------------------
    if ($null -ne $Selection) {
        $tag = Get-LiteDeployWorkflowProperty -InputObject $Selection -Name "WorkflowTag"
        if ([string]::IsNullOrWhiteSpace($OsId)) { $OsId = [string](Get-LiteDeployWorkflowProperty -InputObject $tag -Name "OsId" -Default "") }
        if ([string]::IsNullOrWhiteSpace($EditionId)) { $EditionId = [string](Get-LiteDeployWorkflowProperty -InputObject $tag -Name "EditionId" -Default "") }
        if ([string]::IsNullOrWhiteSpace($Identity) -and $null -eq $Workflow) {
            $Identity = [string](Get-LiteDeployWorkflowProperty -InputObject $Selection -Name "WorkflowId" -Default "")
        }
    }

    # ---- Pick the workflow ---------------------------------------------------
    $wf = $null
    if ($null -ne $Workflow) {
        $wf = Initialize-LiteDeployWorkflowInput -Workflow $Workflow -ShareRoot $root
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Identity)) {
        $wf = Get-LiteDeployWorkflow -Identity $Identity -ShareRoot $root
        if ($null -eq $wf) { throw "Workflow '$Identity' was not found under '$root\WorkFlows'." }
    }
    else {
        $candidates = @(Get-LiteDeployWorkflows -ShareRoot $root -OsId $OsId -EditionId $EditionId)
        if ($candidates.Count -eq 0) { throw "No enabled workflow under '$root\WorkFlows' supports the selected operating system." }
        if ($candidates.Count -gt 1) {
            $ids = ($candidates | ForEach-Object { $_.WorkflowId }) -join ", "
            throw "Multiple workflows match ($ids); specify -Identity."
        }
        $wf = $candidates[0]
    }

    $check = Test-LiteDeployWorkflow -Workflow $wf -ShareRoot $root -Detailed
    if (-not $check.IsValid) {
        throw "Workflow '$($wf.WorkflowId)' failed validation: $($check.Errors -join '; ')"
    }
    if (-not $wf.Enabled) { throw "Workflow '$($wf.WorkflowId)' is disabled." }
    foreach ($w in @($check.Warnings)) {
        if ($w -ne "Workflow is disabled.") { $warnings.Add($w) }
    }

    # ---- OS compatibility ----------------------------------------------------
    $restricted = (@($wf.OperatingSystems).Count -gt 0)
    if (-not [string]::IsNullOrWhiteSpace($OsId) -and $restricted) {
        $osEntry = $null
        foreach ($candidate in @($wf.OperatingSystems)) {
            if ($candidate.OsId -ieq $OsId) { $osEntry = $candidate; break }
        }
        if ($null -eq $osEntry) { throw "Workflow '$($wf.WorkflowId)' does not support operating system '$OsId'." }

        if (-not [string]::IsNullOrWhiteSpace($EditionId) -and @($osEntry.EditionIds).Count -gt 0) {
            $editionMatch = $false
            foreach ($edId in @($osEntry.EditionIds)) {
                if ($edId -ieq $EditionId) { $editionMatch = $true; break }
            }
            if (-not $editionMatch) { throw "Workflow '$($wf.WorkflowId)' does not support edition '$EditionId' of '$OsId'." }
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($OsId) -and $restricted) {
        $warnings.Add("No operating system was selected; OS-specific steps were omitted.")
    }

    # ---- Catalog lookup ------------------------------------------------------
    $osObject = $null
    $editionObject = $null
    if (-not [string]::IsNullOrWhiteSpace($OsId)) {
        $catalog = Get-LiteDeployOperatingSystemsCatalog -ShareRoot $root -RelativePath $wf.OsCatalogPath
        if ($null -eq $catalog) { throw "The OS catalog could not be read from '$root'; cannot resolve operating system '$OsId'." }

        $hit = Find-LiteDeployCatalogEdition -Catalog $catalog -OsId $OsId -EditionId $EditionId
        if ($null -eq $hit) {
            $what = if ($EditionId) { "edition '$EditionId' of operating system '$OsId'" } else { "operating system '$OsId'" }
            throw "The OS catalog does not contain $what."
        }
        $osObject = $hit.OperatingSystem
        $editionObject = $hit.Edition

        if ([string]::IsNullOrWhiteSpace($EditionId) -and @(Get-LiteDeployWorkflowProperty -InputObject $osObject -Name "editions" -Default @()).Count -gt 0) {
            $warnings.Add("No edition was selected for '$OsId'; image index 1 will be used.")
        }
    }

    # ---- Build steps ----------------------------------------------------------
    $steps = New-Object System.Collections.Generic.List[object]

    if (-not $ActionsOnly -and $null -ne $osObject) {
        $imageIndex = 1
        if ($null -ne $editionObject) {
            $rawIndex = Get-LiteDeployWorkflowProperty -InputObject $editionObject -Name "imageIndex"
            if ($null -eq $rawIndex) { $rawIndex = Get-LiteDeployWorkflowProperty -InputObject $editionObject -Name "index" }
            $parsedIndex = 0
            if ($null -ne $rawIndex -and [int]::TryParse([string]$rawIndex, [ref]$parsedIndex) -and $parsedIndex -gt 0) { $imageIndex = $parsedIndex }
        }

        $unattendResolved = ""
        if ($wf.UnattendPath) { $unattendResolved = Join-LiteDeployWorkflowPath -Root $root -ChildPath $wf.UnattendPath }

        $steps.Add((New-LiteDeployWorkflowPlanStep -StepId "disk-prepare" -Name "Prepare target disk" -Type "Disk" -Phase "WinPE" -IsImplicit $true))
        $steps.Add((New-LiteDeployWorkflowPlanStep -StepId "image-apply" -Name "Apply operating system image" -Type "Image" -Phase "WinPE" -IsImplicit $true -Parameters @{
            OsId         = $OsId
            EditionId    = $EditionId
            ImageIndex   = $imageIndex
            ImagePath    = [string](Get-LiteDeployWorkflowProperty -InputObject $osObject -Name "imagePath" -Default "")
            SetupPath    = [string](Get-LiteDeployWorkflowProperty -InputObject $osObject -Name "setupPath" -Default "")
            UnattendPath = $unattendResolved
        }))
    }

    foreach ($action in @($wf.Actions)) {
        $actionName = if ($action.Name) { $action.Name } else { $action.ActionId }
        $steps.Add((New-LiteDeployWorkflowPlanStep `
            -StepId $action.ActionId -Name $actionName -Type $action.Type -Phase $action.Phase `
            -ExecutionContext $action.ExecutionContext -PackageId $action.PackageId -Script $action.Script `
            -Command $action.Command -Arguments @($action.Arguments) `
            -RequiredCredentialIds @($action.RequiredCredentialIds) `
            -ContinueOnError $action.ContinueOnError -Enabled $action.Enabled))
    }

    $orderNumber = 0
    foreach ($step in $steps) {
        $orderNumber++
        $step.Order = $orderNumber
    }

    # Credential IDs (names only) required by the workflow and its steps.
    $credentialIds = New-Object System.Collections.Generic.List[string]
    foreach ($cid in @($wf.RequiredCredentialIds)) { if ($credentialIds -notcontains $cid) { $credentialIds.Add($cid) } }
    foreach ($step in $steps) {
        foreach ($cid in @($step.RequiredCredentialIds)) { if ($credentialIds -notcontains $cid) { $credentialIds.Add($cid) } }
    }

    $unattendFullPath = ""
    if ($wf.UnattendPath) { $unattendFullPath = Join-LiteDeployWorkflowPath -Root $root -ChildPath $wf.UnattendPath }

    return [PSCustomObject]@{
        PSTypeName            = "LiteDeploy.WorkflowPlan"
        WorkflowId            = $wf.WorkflowId
        WorkflowName          = $wf.Name
        Revision              = $wf.Revision
        ShareRoot             = $root
        UnattendPath          = $unattendFullPath
        OsId                  = $OsId
        EditionId             = $EditionId
        OperatingSystem       = $osObject
        Edition               = $editionObject
        Steps                 = $steps.ToArray()
        RequiredCredentialIds = $credentialIds.ToArray()
        Warnings              = $warnings.ToArray()
        ResolvedTime          = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        Workflow              = $wf
    }
}

function Invoke-LiteDeployStep {
    <#
    .SYNOPSIS
        STUB: reports what a single plan step would do. Nothing is executed.

    .DESCRIPTION
        Returns { StepId, Name, Type, Phase, Status, Success, ExitCode, Message, Timestamp } where Status is
        Planned, Skipped (disabled step), or Failed (a Package step whose package is missing from the share).
        Execution is intentionally not implemented here; Package steps are executed by LiteDeploy.Packages
        (Invoke-LiteDeployPackage) once the Engine wires them in.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [psobject]$Step,

        [Parameter(Mandatory = $false)]
        [psobject]$Plan = $null,

        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = ""
    )

    $stepId = [string](Get-LiteDeployWorkflowProperty -InputObject $Step -Name "StepId" -Default "")
    $stepName = [string](Get-LiteDeployWorkflowProperty -InputObject $Step -Name "Name" -Default $stepId)
    $type = [string](Get-LiteDeployWorkflowProperty -InputObject $Step -Name "Type" -Default "")
    $phase = [string](Get-LiteDeployWorkflowProperty -InputObject $Step -Name "Phase" -Default "")
    $enabled = ConvertTo-LiteDeployWorkflowBool -Value (Get-LiteDeployWorkflowProperty -InputObject $Step -Name "Enabled") -Default $true

    $status = "Planned"
    $success = $true
    $message = "Stub: step was not executed."

    if (-not $enabled) {
        $status = "Skipped"
        $message = "Step is disabled."
    }
    elseif ($global:LiteDeployWorkflowStepTypes -notcontains $type) {
        $status = "Failed"
        $success = $false
        $message = "Unknown step type '$type'."
    }
    elseif ($type -eq "Package") {
        $packageId = [string](Get-LiteDeployWorkflowProperty -InputObject $Step -Name "PackageId" -Default "")
        $planRoot = if ($null -ne $Plan) { [string](Get-LiteDeployWorkflowProperty -InputObject $Plan -Name "ShareRoot" -Default "") } else { "" }
        $effectiveRoot = if (-not [string]::IsNullOrWhiteSpace($ShareRoot)) { $ShareRoot } else { $planRoot }
        $root = Resolve-LiteDeployWorkflowShareRoot -ShareRoot $effectiveRoot

        if ([string]::IsNullOrWhiteSpace($packageId) -or $packageId -notmatch $global:LiteDeployWorkflowIdPattern) {
            $status = "Failed"
            $success = $false
            $message = "Package step has no valid packageId."
        }
        elseif (Test-Path -LiteralPath (Join-LiteDeployWorkflowPath -Root $root -ChildPath "Content\Packages") -PathType Container) {
            $manifest = Join-LiteDeployWorkflowPath -Root $root -ChildPath ("Content\Packages\{0}\package.json" -f $packageId)
            if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
                $status = "Failed"
                $success = $false
                $message = "Package '$packageId' was not found in Content\Packages."
            }
            else {
                $message = "Stub: would run package '$packageId' (not executed)."
            }
        }
        else {
            $message = "Stub: would run package '$packageId' (package folder not reachable; not verified)."
        }
    }

    return [PSCustomObject]@{
        PSTypeName = "LiteDeploy.WorkflowStepResult"
        StepId     = $stepId
        Name       = $stepName
        Type       = $type
        Phase      = $phase
        Status     = $status
        Success    = $success
        ExitCode   = $null
        Message    = $message
        Timestamp  = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    }
}

function Invoke-LiteDeployWorkflow {
    <#
    .SYNOPSIS
        PLAN STUB: resolves the workflow plan and walks every step (via Invoke-LiteDeployStep) without executing.

    .DESCRIPTION
        Accepts the same selection parameters as Resolve-LiteDeployWorkflow. Never throws: resolution errors
        are returned in the result. A failed step stops the walk unless that step has ContinueOnError.

    .OUTPUTS
        { Success, Mode ('Plan'), WorkflowId, Plan, StepResults, Errors, Warnings }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Identity = "",

        [Parameter(Mandatory = $false)]
        [psobject]$Workflow = $null,

        [Parameter(Mandatory = $false)]
        [psobject]$Selection = $null,

        [Parameter(Mandatory = $false)]
        [string]$OsId = "",

        [Parameter(Mandatory = $false)]
        [string]$EditionId = "",

        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = "",

        [Parameter(Mandatory = $false)]
        [switch]$ActionsOnly
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $results = New-Object System.Collections.Generic.List[object]
    $plan = $null

    try {
        $plan = Resolve-LiteDeployWorkflow -Identity $Identity -Workflow $Workflow -Selection $Selection `
            -OsId $OsId -EditionId $EditionId -ShareRoot $ShareRoot -ActionsOnly:$ActionsOnly
    }
    catch {
        $errors.Add($_.Exception.Message)
        Write-LiteDeployWorkflowLog -Message "Workflow plan could not be resolved: $($_.Exception.Message)" -Level "ERROR" -NoConsole
    }

    if ($null -ne $plan) {
        Write-LiteDeployWorkflowLog -Message "Planning workflow '$($plan.WorkflowId)' ($(@($plan.Steps).Count) steps; stub, nothing is executed)." -Level "INFO" -NoConsole

        foreach ($step in @($plan.Steps)) {
            $stepResult = Invoke-LiteDeployStep -Step $step -Plan $plan
            $results.Add($stepResult)

            if (-not $stepResult.Success) {
                $errors.Add("Step '$($stepResult.StepId)': $($stepResult.Message)")
                if (-not $step.ContinueOnError) { break }
            }
        }
    }

    return [PSCustomObject]@{
        PSTypeName  = "LiteDeploy.WorkflowRunResult"
        Success     = ($null -ne $plan -and $errors.Count -eq 0)
        Mode        = "Plan"
        WorkflowId  = if ($null -ne $plan) { $plan.WorkflowId } else { "" }
        Plan        = $plan
        StepResults = $results.ToArray()
        Errors      = $errors.ToArray()
        Warnings    = if ($null -ne $plan) { @($plan.Warnings) } else { @() }
    }
}

# ==============================================================================
# 8. STANDALONE EXECUTION (read-only: list workflows)
# ==============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    $meta = Get-LiteDeployComponentMetadata
    $listRoot = Resolve-LiteDeployWorkflowShareRoot -ShareRoot $ShareRoot
    $listDir = Join-LiteDeployWorkflowPath -Root $listRoot -ChildPath "WorkFlows"

    Write-Host ""
    Write-Host ("{0} v{1} ({2})" -f $meta.Name, $meta.Version, $meta.ComponentId) -ForegroundColor Cyan
    Write-Host ("  Share root : {0}" -f $listRoot)
    Write-Host ("  Workflows  : {0}" -f $listDir)

    if (-not (Test-Path -LiteralPath $listDir -PathType Container)) {
        Write-Host "  The WorkFlows folder is not reachable. Use -ShareRoot <path> to point at the deployment share." -ForegroundColor Yellow
        Write-Host ""
        return
    }

    $listed = @(Get-LiteDeployWorkflows -ShareRoot $listRoot -IncludeDisabled)
    if ($listed.Count -eq 0) {
        Write-Host "  No workflow definitions found." -ForegroundColor Yellow
        Write-Host ""
        return
    }

    $rows = foreach ($item in $listed) {
        $validation = Test-LiteDeployWorkflow -Workflow $item -ShareRoot $listRoot -Detailed
        [PSCustomObject]@{
            WorkflowId = $item.WorkflowId
            Name       = $item.Name
            Enabled    = $item.Enabled
            Rev        = $item.Revision
            OSes       = @($item.OperatingSystems).Count
            Actions    = @($item.Actions).Count
            Credentials = (@($item.RequiredCredentialIds) -join ",")
            Valid      = $validation.IsValid
        }
    }

    Write-Host ""
    $rows | Format-Table -AutoSize | Out-Host
}
