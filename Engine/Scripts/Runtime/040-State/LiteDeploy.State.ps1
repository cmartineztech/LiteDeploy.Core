<#
.SYNOPSIS
    LiteDeploy State - deployment state object, persistence, resume, and validation (architecture v2).

.DESCRIPTION
    Owns the deployment state document (DeploymentState.json) used by the Engine and the Progress UI.

    Extracted and adapted from LiteDeploy.DeploymentEngine.ps1 / LiteDeploy.Engine.ps1:
      - New-LiteDeployDeploymentObject   Creates the deployment state object (same structure as Engine).
      - Save-LiteDeployDeploymentState   Writes DeploymentState.json locally and mirrors it to the share log dir.

    Public API:
      Get-LiteDeployState [-Path] [-FromFile]       Read the live state (global) or a state file.
      Update-LiteDeployState                        Patch status/phase/step/percent/errors/properties, then save.
      Set-LiteDeployState                           Alias of Update-LiteDeployState.
      Save-LiteDeployState                          Alias of Save-LiteDeployDeploymentState.
      Resume-LiteDeployState                        Locate, validate, and re-activate a saved state.
      Test-LiteDeployState                          Validate a state object or state file.
      Get-DeploymentStateFromFile                   Compatibility reader for the Progress UI (returns a hashtable).

    SECURITY: Credentials are NEVER persisted or logged. When serializing, BootObject.Credential (and any
    property named like Credential / Password / Secret / Token, plus SecureString / PSCredential values) is
    omitted from the written JSON. The in-memory object is never modified by serialization. Log messages
    are passed through a redaction filter.

    Usage:
        . "Z:\Engine\Scripts\Runtime\LiteDeploy.State.ps1"     # load the API
        .\LiteDeploy.State.ps1                                 # show the local state file if present
        .\LiteDeploy.State.ps1 -StatePath Z:\WorkLogs\Deployments\260806-A3F1\DeploymentState.json
        .\LiteDeploy.State.ps1 -Metadata                       # component metadata only

    ComponentId: State

.PARAMETER StatePath
    Standalone only: state file to display. Defaults to $env:SystemDrive\~LiteDeploy\DeploymentState.json.

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
    [string]$StatePath = "",

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
        ComponentId          = "State"
        Name                 = "LiteDeploy State"
        Version              = "2.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "Universal"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("Logs", "Environment")
        Description          = "Deployment state object, RAM memory-map + credential-safe DeploymentState.json persistence, resume, and validation."
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

$global:LiteDeployStateFileName = "DeploymentState.json"

# Named memory map: Engine publishes JSON here; Progress (separate process) reads it from RAM.
# WinPE X:\ file persist remains a durable fallback / reboot handoff.
$global:LiteDeployStateMemoryMapName = "Local\LiteDeploy.DeploymentState"
$global:LiteDeployStateMemoryMapCapacity = 1048576  # 1 MB
$global:LiteDeployStateMemoryMap = $null
$global:LiteDeployStateMemoryAccessor = $null

$global:LiteDeployStateKnownStatuses = @(
    "Initializing", "HardwarePreCheck", "WorkflowSelection", "ReadyForDeployment",
    "DiskPreparation", "ReadyForStaging", "ApplyingOSImage", "OSImageApplied",
    "Staging", "Completed", "FullOS", "Cancelled", "Failed"
)

# WinPE "Completed" means imaging/handoff finished; FullOS continues under Status FullOS.
$global:LiteDeployStateTerminalStatuses = @("Cancelled", "Failed")

# Pipeline phases (Engine): 1 PreCheck, 2 Workflow, 3 Disk, 4 OS image, 5 post-install / FullOS.
$global:LiteDeployStatePhaseNames = @{
    1 = "HardwarePreCheck"
    2 = "WorkflowSelection"
    3 = "DiskPreparation"
    4 = "OSInstallation"
    5 = "FullOS"
}

# Status written when a Failed/Cancelled deployment is resumed at a given phase.
$global:LiteDeployStatePhaseStatus = @{
    1 = "HardwarePreCheck"
    2 = "WorkflowSelection"
    3 = "DiskPreparation"
    4 = "ApplyingOSImage"
    5 = "FullOS"
}

# Property names that must never be serialized (exact, case-insensitive).
$global:LiteDeployStateSensitiveNamePattern = '^(credentials?|ps?credential|networkcredential|[a-z_]*password|[a-z_]*secret|[a-z_]*token|apikey|privatekey)$'

$global:LiteDeployStateMaxDepth = 8

# ==============================================================================
# 3. INTERNAL HELPERS
# ==============================================================================

function Protect-LiteDeployStateText {
    <#
    .SYNOPSIS
        Redacts password/secret/token style key-value pairs from free text before logging or storing.
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

function Write-LiteDeployStateLog {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO",

        [switch]$NoConsole
    )

    $text = Protect-LiteDeployStateText -Text $Message

    if (Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue) {
        try {
            Write-LiteDeployLog -Message $text -Level $Level -Component "State" -NoConsole:$NoConsole
        }
        catch {
            # Logging must never break state handling.
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

function Get-LiteDeployStateProperty {
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

function Test-LiteDeployStateHasProperty {
    param(
        $InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) { return $false }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in @($InputObject.Keys)) {
            if ([string]$key -ieq $Name) { return $true }
        }
        return $false
    }

    foreach ($prop in $InputObject.PSObject.Properties) {
        if ($prop.Name -ieq $Name) { return $true }
    }
    return $false
}

function Set-LiteDeployStateMember {
    <#
    .SYNOPSIS
        Sets (or adds) a single property/key on a PSCustomObject or dictionary.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Target,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        $Value
    )

    if ($Target -is [System.Collections.IDictionary]) {
        $Target[$Name] = $Value
        return
    }

    foreach ($prop in $Target.PSObject.Properties) {
        if ($prop.Name -ieq $Name) {
            $prop.Value = $Value
            return
        }
    }

    Add-Member -InputObject $Target -MemberType NoteProperty -Name $Name -Value $Value -Force
}

function Set-LiteDeployStateValue {
    <#
    .SYNOPSIS
        Sets a value using a dotted path (e.g. 'Disk.Formatted'), creating intermediate objects as needed.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Object,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        $Value
    )

    $parts = @($Path.Split('.') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts.Count -eq 0) {
        throw "State property path '$Path' is empty."
    }

    $leaf = [string]$parts[$parts.Count - 1]
    if ($leaf -match $global:LiteDeployStateSensitiveNamePattern) {
        throw "Refusing to store sensitive property '$leaf' in deployment state."
    }

    $cursor = $Object
    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        $segment = [string]$parts[$i]
        $next = Get-LiteDeployStateProperty -InputObject $cursor -Name $segment
        if ($null -eq $next) {
            $next = [PSCustomObject]@{}
            Set-LiteDeployStateMember -Target $cursor -Name $segment -Value $next
        }
        $cursor = $next
    }

    Set-LiteDeployStateMember -Target $cursor -Name $leaf -Value $Value
}

function Get-LiteDeployStateTimestamp {
    # Same format the Engine stamps into StartTime / EndTime / CompletedTime fields.
    return (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
}

function New-LiteDeployStateUid {
    # Fallback UID (e.g. 260806-A3F1) when the caller does not supply one.
    $bytes = New-Object byte[] 2
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $hex = [System.BitConverter]::ToString($bytes) -replace '-'
    return ("{0}-{1}" -f (Get-Date).ToString('yyMMdd'), $hex)
}

function Get-LiteDeployStateSystemDrive {
    $sysDrive = if ($env:SystemDrive) { [string]$env:SystemDrive } else { "X:" }
    return $sysDrive.TrimEnd('\')
}

function Get-LiteDeployStateFilePath {
    <#
    .SYNOPSIS
        Default local state file: <SystemDrive>\~LiteDeploy\DeploymentState.json
        In WinPE this is on the RAM disk (X:).
    #>
    return ("{0}\~LiteDeploy\{1}" -f (Get-LiteDeployStateSystemDrive), $global:LiteDeployStateFileName)
}

function Get-LiteDeployStateMemoryMapName {
    return [string]$global:LiteDeployStateMemoryMapName
}

function Close-LiteDeployStateMemory {
    <#
    .SYNOPSIS
        Releases the publisher-side memory map handles (Engine process).
    #>
    try {
        if ($null -ne $global:LiteDeployStateMemoryAccessor) {
            $global:LiteDeployStateMemoryAccessor.Dispose()
        }
    } catch {}
    try {
        if ($null -ne $global:LiteDeployStateMemoryMap) {
            $global:LiteDeployStateMemoryMap.Dispose()
        }
    } catch {}
    $global:LiteDeployStateMemoryAccessor = $null
    $global:LiteDeployStateMemoryMap = $null
}

function Write-LiteDeployStateToMemory {
    <#
    .SYNOPSIS
        Publishes credential-free state JSON into a named memory-mapped region (RAM IPC for Progress).
    .DESCRIPTION
        Layout: Int32 length (UTF-8 byte count) at offset 0, then payload bytes.
        CreateOrOpen keeps the map alive for the Engine process lifetime so Progress can OpenExisting.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Json
    )

    if ([string]::IsNullOrWhiteSpace($Json)) { return $false }

    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
        $needed = 4 + $bytes.Length
        if ($needed -gt $global:LiteDeployStateMemoryMapCapacity) {
            Write-LiteDeployStateLog -Message "State JSON exceeds RAM map capacity ($needed > $($global:LiteDeployStateMemoryMapCapacity))." -Level "WARNING"
            return $false
        }

        if ($null -eq $global:LiteDeployStateMemoryMap) {
            $global:LiteDeployStateMemoryMap = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateOrOpen(
                $global:LiteDeployStateMemoryMapName,
                [long]$global:LiteDeployStateMemoryMapCapacity
            )
            $global:LiteDeployStateMemoryAccessor = $global:LiteDeployStateMemoryMap.CreateViewAccessor(0, [long]$global:LiteDeployStateMemoryMapCapacity)
        }

        $accessor = $global:LiteDeployStateMemoryAccessor
        $accessor.Write(0, [int]$bytes.Length)
        $accessor.WriteArray(4, $bytes, 0, $bytes.Length)
        return $true
    }
    catch {
        Write-LiteDeployStateLog -Message "Could not publish state to RAM map: $($_.Exception.Message)" -Level "WARNING" -NoConsole
        return $false
    }
}

function Read-LiteDeployStateFromMemory {
    <#
    .SYNOPSIS
        Reads the latest state JSON from the named RAM map (Progress / secondary readers).
    .OUTPUTS
        UTF-8 JSON string, or empty string when the map is missing/empty.
    #>
    param(
        [string]$MapName = ""
    )

    if ([string]::IsNullOrWhiteSpace($MapName)) {
        $MapName = $global:LiteDeployStateMemoryMapName
    }

    $mmf = $null
    $accessor = $null
    try {
        $mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting($MapName)
        $accessor = $mmf.CreateViewAccessor(0, [long]$global:LiteDeployStateMemoryMapCapacity)
        $length = $accessor.ReadInt32(0)
        if ($length -le 0 -or $length -gt ($global:LiteDeployStateMemoryMapCapacity - 4)) {
            return ""
        }
        $buffer = New-Object byte[] $length
        $read = $accessor.ReadArray(4, $buffer, 0, $length)
        if ($read -le 0) { return "" }
        return [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    }
    catch {
        return ""
    }
    finally {
        if ($null -ne $accessor) { try { $accessor.Dispose() } catch {} }
        if ($null -ne $mmf) { try { $mmf.Dispose() } catch {} }
    }
}

function Get-LiteDeployStateRemoteDirectory {
    <#
    .SYNOPSIS
        Returns the share-side log directory recorded in a state object ('' when none).
    #>
    param($State)

    $logLocations = Get-LiteDeployStateProperty -InputObject $State -Name "LogLocations"
    $remote = Get-LiteDeployStateProperty -InputObject $logLocations -Name "RemoteLogDir"
    if (-not [string]::IsNullOrWhiteSpace([string]$remote)) { return [string]$remote }

    $execution = Get-LiteDeployStateProperty -InputObject $State -Name "Execution"
    $remote = Get-LiteDeployStateProperty -InputObject $execution -Name "RemoteLogDir"
    if (-not [string]::IsNullOrWhiteSpace([string]$remote)) { return [string]$remote }

    return ""
}

function Get-LiteDeployStateOsPaths {
    <#
    .SYNOPSIS
        Resolves offline Windows OS volume paths for state/log mirroring (e.g. W:\~LiteDeploy).
    #>
    param($State)

    $result = [PSCustomObject]@{
        Root      = ""
        LogDir    = ""
        StatePath = ""
    }

    $gRoot = Get-Variable -Name LiteDeployOsRoot -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    $gLogs = Get-Variable -Name LiteDeployOsLogDir -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    $gState = Get-Variable -Name LiteDeployOsStatePath -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($gRoot) { $result.Root = [string]$gRoot }
    if ($gLogs) { $result.LogDir = [string]$gLogs }
    if ($gState) { $result.StatePath = [string]$gState }

    $logLocations = Get-LiteDeployStateProperty -InputObject $State -Name "LogLocations"
    if ($logLocations) {
        $root = Get-LiteDeployStateProperty -InputObject $logLocations -Name "OfflineOsRoot"
        $logs = Get-LiteDeployStateProperty -InputObject $logLocations -Name "OfflineOsLogDir"
        $statePath = Get-LiteDeployStateProperty -InputObject $logLocations -Name "OfflineOsDeploymentState"
        if (-not $result.Root -and $root) { $result.Root = [string]$root }
        if (-not $result.LogDir -and $logs) { $result.LogDir = [string]$logs }
        if (-not $result.StatePath -and $statePath) { $result.StatePath = [string]$statePath }
    }

    if (-not $result.StatePath -and $result.Root) {
        $result.StatePath = Join-Path $result.Root $global:LiteDeployStateFileName
    }
    if (-not $result.LogDir -and $result.Root) {
        $result.LogDir = Join-Path $result.Root "WorkLogs"
    }

    return $result
}

function Get-LiteDeployLiveState {
    # In-memory deployment published by the Engine ($global:LiteDeployDeployment), or $null.
    $live = Get-Variable -Name LiteDeployDeployment -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $live) { return $live }
    return $null
}

function ConvertTo-LiteDeploySerializableObject {
    <#
    .SYNOPSIS
        Builds a credential-free, JSON-safe copy of an object graph (the original is never modified).

    .DESCRIPTION
        Omits SecureString / PSCredential / NetworkCredential values and any property whose name matches
        the sensitive-name pattern (Credential, Password, Secret, Token, ...). Non-trivial .NET objects are
        reduced to strings; depth is capped to guard against cycles.
    #>
    param(
        $InputObject,
        [int]$Depth = 0
    )

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Security.SecureString] -or
        $InputObject -is [System.Management.Automation.PSCredential] -or
        $InputObject -is [System.Net.NetworkCredential]) {
        return $null
    }

    if ($InputObject -is [string] -or $InputObject -is [bool]) { return $InputObject }
    if ($InputObject -is [char]) { return [string]$InputObject }
    if ($InputObject -is [datetime]) { return $InputObject.ToString("o") }
    if ($InputObject -is [System.Enum]) { return $InputObject.ToString() }

    $inputType = $InputObject.GetType()
    if ($inputType.IsPrimitive -or $InputObject -is [decimal]) { return $InputObject }
    if ($InputObject -is [System.ValueType]) { return $InputObject.ToString() }

    if ($Depth -ge $global:LiteDeployStateMaxDepth) { return "[truncated]" }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $dictOut = [ordered]@{}
        foreach ($key in @($InputObject.Keys)) {
            $keyName = [string]$key
            if ($keyName -match $global:LiteDeployStateSensitiveNamePattern) { continue }
            # Optional registration, domain, and workgroup values have no meaning when null, empty, or whitespace.
            if ($keyName -in @('RegisteredOrganization', 'RegisteredOwner', 'JoinWorkGroup', 'JoinWorkgroup', 'JoinDomain', 'MachineObjectOU') -and
                [string]::IsNullOrWhiteSpace([string]$InputObject[$key])) { continue }
            $dictOut[$keyName] = ConvertTo-LiteDeploySerializableObject -InputObject $InputObject[$key] -Depth ($Depth + 1)
        }
        return $dictOut
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($item in $InputObject) {
            $items.Add((ConvertTo-LiteDeploySerializableObject -InputObject $item -Depth ($Depth + 1)))
        }
        return ,($items.ToArray())
    }

    $isPropertyBag = ($InputObject -is [System.Management.Automation.PSCustomObject])
    if (-not $isPropertyBag) {
        $typeNames = @($InputObject.PSObject.TypeNames)
        if ($typeNames.Count -gt 0 -and ([string]$typeNames[0]) -like 'Deserialized*') {
            $isPropertyBag = $true
        }
    }

    if ($isPropertyBag) {
        $objOut = [ordered]@{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            if ($prop.Name -match $global:LiteDeployStateSensitiveNamePattern) { continue }
            $propValue = $null
            try { $propValue = $prop.Value } catch { $propValue = $null }
            if ($prop.Name -in @('RegisteredOrganization', 'RegisteredOwner', 'JoinWorkGroup', 'JoinWorkgroup', 'JoinDomain', 'MachineObjectOU') -and
                [string]::IsNullOrWhiteSpace([string]$propValue)) { continue }
            $objOut[$prop.Name] = ConvertTo-LiteDeploySerializableObject -InputObject $propValue -Depth ($Depth + 1)
        }
        return $objOut
    }

    return [string]$InputObject
}

function Write-LiteDeployStateFile {
    <#
    .SYNOPSIS
        Writes UTF-8 (no BOM) text; uses temp-file + move so readers never see a half-written file.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -Path $directory -ItemType Directory -Force
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $tempPath = "$Path.tmp"
    try {
        [System.IO.File]::WriteAllText($tempPath, $Content, $utf8)
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    catch {
        # Target may be held open by the Progress UI reader; fall back to an in-place write.
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        [System.IO.File]::WriteAllText($Path, $Content, $utf8)
    }
}

function Read-LiteDeployStateFile {
    <#
    .SYNOPSIS
        Reads and parses a state JSON file with shared read access (the Engine may be writing).
        Returns $null for a missing or empty file; throws on invalid JSON.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $stream = $null
    $reader = $null
    $raw = ""
    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $raw = $reader.ReadToEnd()
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }

    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json -ErrorAction Stop)
}

function Get-LiteDeployStateNextPhase {
    <#
    .SYNOPSIS
        Determines the first incomplete pipeline phase (1-4), or 5 when every phase has completed.
    #>
    param($State)

    $preCheck = Get-LiteDeployStateProperty -InputObject $State -Name "HardwarePreCheck"
    if (-not [bool](Get-LiteDeployStateProperty -InputObject $preCheck -Name "Passed" -Default $false)) { return 1 }

    $workflow = Get-LiteDeployStateProperty -InputObject $State -Name "Workflow"
    if (-not [bool](Get-LiteDeployStateProperty -InputObject $workflow -Name "Confirmed" -Default $false)) { return 2 }

    $disk = Get-LiteDeployStateProperty -InputObject $State -Name "Disk"
    if (-not [bool](Get-LiteDeployStateProperty -InputObject $disk -Name "Formatted" -Default $false)) { return 3 }

    $osInstall = Get-LiteDeployStateProperty -InputObject $State -Name "OSInstall"
    if (-not [bool](Get-LiteDeployStateProperty -InputObject $osInstall -Name "Applied" -Default $false)) { return 4 }

    return 5
}

# ==============================================================================
# 4. STATE OBJECT & PERSISTENCE (extracted from Engine)
# ==============================================================================

function New-LiteDeployDeploymentObject {
    <#
    .SYNOPSIS
        Creates the deployment state object (structure identical to the Engine's).

    .NOTES
        BootObject holds the live in-memory boot context (including Credential). It is never written to
        disk with credentials: Save-LiteDeployDeploymentState strips them during serialization.
    #>
    param(
        [string]$Uid = "",
        [psobject]$BootCtx = $null,
        [string]$RemoteLogDir = "",
        # Engine uses local pre-check state before assigning a deployment ID.
        [switch]$DeferUid
    )

    if (-not $DeferUid -and [string]::IsNullOrWhiteSpace($Uid)) { $Uid = New-LiteDeployStateUid }

    $sysDrive = Get-LiteDeployStateSystemDrive
    $localLogDir = Join-Path $sysDrive "~LiteDeploy\WorkLogs"

    return [PSCustomObject]@{
        DeploymentUid = $Uid
        Status        = "Initializing"    # Initializing, HardwarePreCheck, WorkflowSelection, ReadyForDeployment, Staging, Completed, Cancelled, Failed
        CurrentPhase  = 0
        StartTime     = (Get-LiteDeployStateTimestamp)
        EndTime       = $null
        BootObject    = $BootCtx
        LogLocations  = [PSCustomObject]@{
            LocalLogDir               = $localLogDir
            RemoteLogDir              = $RemoteLogDir
            LocalExecutionLog         = (Join-Path $localLogDir "LiteDeploy.Execution.log")
            RemoteExecutionLog        = if ($RemoteLogDir) { Join-Path $RemoteLogDir "LiteDeploy.Execution.log" } else { "" }
            LocalDeploymentState      = (Join-Path $sysDrive "~LiteDeploy\DeploymentState.json")
            RemoteDeploymentState     = if ($RemoteLogDir) { Join-Path $RemoteLogDir "DeploymentState.json" } else { "" }
            OfflineOsRoot             = ""
            OfflineOsLogDir           = ""
            OfflineOsDeploymentState  = ""
        }
        HardwarePreCheck      = [PSCustomObject]@{
            Passed        = $false
            CompletedTime = $null
        }
        Workflow      = [PSCustomObject]@{
            Confirmed     = $false
            SelectionData = $null
            CompletedTime = $null
        }
        Disk          = [PSCustomObject]@{
            Formatted               = $false
            DiskNumber              = $null
            BootMode                = $null
            OSPartitionNumber       = $null
            OSDriveLetter           = $null
            SystemPartitionNumber   = $null
            RecoveryPartitionNumber = $null
            TotalSizeGB             = $null
            CompletedTime           = $null
        }
        OSInstall     = [PSCustomObject]@{
            StartedTime     = $null
            CompletedTime   = $null
            Engine          = "Setup.exe"
            SetupPath       = $null
            ImagePath       = $null
            ImageIndex      = $null
            UnattendPath    = $null
            Applied         = $false
            ExitCode        = $null
            DurationSeconds = 0
        }
        Execution     = [PSCustomObject]@{
            CurrentStep     = "Initialized"
            PercentComplete = 0
            LocalLogDir     = $localLogDir
            RemoteLogDir    = $RemoteLogDir
            Errors          = @()
        }
        Ui            = [PSCustomObject]@{
            Theme = "Light"   # BootConfig.Ui.Theme (Light|Dark) — shared across Runtime UI hosts
        }
    }
}

function Save-LiteDeployDeploymentState {
    <#
    .SYNOPSIS
        Serializes the deployment state to DeploymentState.json (local) and mirrors it to the share log dir.

    .DESCRIPTION
        Credential-safe: BootObject.Credential and other sensitive members are omitted from the JSON.
        Never throws and (like the Engine original) emits nothing unless -PassThru is supplied, so existing
        call sites do not pollute the pipeline.

    .PARAMETER DeploymentState
        State object from New-LiteDeployDeploymentObject.

    .PARAMETER Path
        Override for the local state file. Defaults to <SystemDrive>\~LiteDeploy\DeploymentState.json.

    .PARAMETER NoRemote
        Skip the mirror copy under LogLocations.RemoteLogDir.

    .PARAMETER PassThru
        Return a result object (Saved, LocalPath, RemoteSaved, RemotePath, Error).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$DeploymentState,

        [Parameter(Mandatory = $false)]
        [string]$Path = "",

        [Parameter(Mandatory = $false)]
        [switch]$NoRemote,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    $result = [PSCustomObject]@{
        Saved       = $false
        LocalPath   = ""
        RemoteSaved = $false
        RemotePath  = ""
        OsSaved     = $false
        OsPath      = ""
        Error       = ""
    }

    $json = $null
    try {
        $safeState = ConvertTo-LiteDeploySerializableObject -InputObject $DeploymentState
        $json = $safeState | ConvertTo-Json -Depth 10
    }
    catch {
        $result.Error = "Serialization failed: $($_.Exception.Message)"
        Write-LiteDeployStateLog -Message "Could not serialize deployment state: $($_.Exception.Message)" -Level "WARNING"
    }

    if ($null -ne $json) {
        # Primary live feed for Progress: named memory map (RAM IPC).
        $null = Write-LiteDeployStateToMemory -Json $json

        # 1) Local RAM / system drive
        $localPath = if ([string]::IsNullOrWhiteSpace($Path)) { Get-LiteDeployStateFilePath } else { $Path }
        $result.LocalPath = $localPath
        try {
            Write-LiteDeployStateFile -Path $localPath -Content $json
            $result.Saved = $true
        }
        catch {
            $result.Error = "Local write failed: $($_.Exception.Message)"
            Write-LiteDeployStateLog -Message "Could not write deployment state to '$localPath': $($_.Exception.Message)" -Level "WARNING"
        }

        # 2) Deployment share / media
        if (-not $NoRemote) {
            try {
                $remoteDir = Get-LiteDeployStateRemoteDirectory -State $DeploymentState
                if ($remoteDir -and (Test-Path -LiteralPath $remoteDir -ErrorAction SilentlyContinue)) {
                    $remotePath = Join-Path $remoteDir $global:LiteDeployStateFileName
                    $result.RemotePath = $remotePath
                    Write-LiteDeployStateFile -Path $remotePath -Content $json
                    $result.RemoteSaved = $true
                }
            }
            catch {
                Write-LiteDeployStateLog -Message "Could not mirror deployment state to the share: $($_.Exception.Message)" -Level "WARNING" -NoConsole
            }
        }

        # 3) Windows OS volume (W:\~LiteDeploy\DeploymentState.json) when Disk has mounted it
        try {
            $osPaths = Get-LiteDeployStateOsPaths -State $DeploymentState
            if ($osPaths.StatePath) {
                $osParent = Split-Path -Parent $osPaths.StatePath
                if ($osParent -and -not (Test-Path -LiteralPath $osParent -ErrorAction SilentlyContinue)) {
                    $null = New-Item -Path $osParent -ItemType Directory -Force -ErrorAction SilentlyContinue
                }
                if ($osParent -and (Test-Path -LiteralPath $osParent -ErrorAction SilentlyContinue)) {
                    Write-LiteDeployStateFile -Path $osPaths.StatePath -Content $json
                    $result.OsPath = $osPaths.StatePath
                    $result.OsSaved = $true
                }
            }
        }
        catch {
            Write-LiteDeployStateLog -Message "Could not mirror deployment state to the OS volume: $($_.Exception.Message)" -Level "WARNING" -NoConsole
        }
    }

    if ($PassThru) { return $result }
}

# ==============================================================================
# 5. PUBLIC API
# ==============================================================================

function Get-LiteDeployState {
    <#
    .SYNOPSIS
        Returns the deployment state.

    .DESCRIPTION
        -Path       reads that state file.
        (no -Path)  returns the live in-memory state ($global:LiteDeployDeployment) when present,
                    otherwise reads the default local state file.
        -FromFile   forces reading the file even when a live state exists.

        Returns $null when no state is available or the file is unreadable.

    .EXAMPLE
        $state = Get-LiteDeployState
        $state = Get-LiteDeployState -Path Z:\WorkLogs\Deployments\260806-A3F1\DeploymentState.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Path = "",

        [Parameter(Mandatory = $false)]
        [switch]$FromFile
    )

    $targetPath = $Path
    if ([string]::IsNullOrWhiteSpace($targetPath)) {
        if (-not $FromFile) {
            $live = Get-LiteDeployLiveState
            if ($null -ne $live) { return $live }
        }
        $targetPath = Get-LiteDeployStateFilePath
    }

    try {
        $state = Read-LiteDeployStateFile -Path $targetPath
        if ($null -eq $state) {
            Write-Verbose "No deployment state found at '$targetPath'."
            return $null
        }
        return $state
    }
    catch {
        Write-LiteDeployStateLog -Message "Could not read deployment state '$targetPath': $($_.Exception.Message)" -Level "WARNING"
        return $null
    }
}

function Update-LiteDeployState {
    <#
    .SYNOPSIS
        Patches the deployment state and (by default) saves it. Alias: Set-LiteDeployState.

    .DESCRIPTION
        Target is -State, else the live global state, else the default local state file.
        Terminal statuses (Completed / Failed / Cancelled) stamp EndTime when it is empty.
        Error text is redacted before it is stored. Sensitive property names are refused.

    .PARAMETER Property
        Hashtable of dotted-path updates, e.g. @{ 'Disk.Formatted' = $true; 'Disk.DiskNumber' = 0 }.

    .EXAMPLE
        Update-LiteDeployState -Status "DiskPreparation" -CurrentPhase 3 -CurrentStep "FormattingTargetDisk" -PercentComplete 25
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [psobject]$State = $null,

        [Parameter(Mandatory = $false)]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [int]$CurrentPhase,

        [Parameter(Mandatory = $false)]
        [string]$CurrentStep,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 100)]
        [int]$PercentComplete,

        [Parameter(Mandatory = $false)]
        [string[]]$AddError,

        [Parameter(Mandatory = $false)]
        [hashtable]$Property,

        [Parameter(Mandatory = $false)]
        [switch]$NoSave,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    $target = $State
    if ($null -eq $target) { $target = Get-LiteDeployLiveState }
    if ($null -eq $target) { $target = Get-LiteDeployState -FromFile }
    if ($null -eq $target) {
        throw "Update-LiteDeployState: no deployment state is available (supply -State or load one with Get-LiteDeployState/Resume-LiteDeployState)."
    }

    if ($PSBoundParameters.ContainsKey('Status')) {
        Set-LiteDeployStateValue -Object $target -Path "Status" -Value $Status
        if ($global:LiteDeployStateTerminalStatuses -contains $Status) {
            $existingEnd = Get-LiteDeployStateProperty -InputObject $target -Name "EndTime"
            if ([string]::IsNullOrWhiteSpace([string]$existingEnd)) {
                Set-LiteDeployStateValue -Object $target -Path "EndTime" -Value (Get-LiteDeployStateTimestamp)
            }
        }
    }
    if ($PSBoundParameters.ContainsKey('CurrentPhase')) {
        Set-LiteDeployStateValue -Object $target -Path "CurrentPhase" -Value $CurrentPhase
    }
    if ($PSBoundParameters.ContainsKey('CurrentStep')) {
        Set-LiteDeployStateValue -Object $target -Path "Execution.CurrentStep" -Value $CurrentStep
    }
    if ($PSBoundParameters.ContainsKey('PercentComplete')) {
        Set-LiteDeployStateValue -Object $target -Path "Execution.PercentComplete" -Value $PercentComplete
    }

    if ($PSBoundParameters.ContainsKey('AddError') -and $null -ne $AddError) {
        $execution = Get-LiteDeployStateProperty -InputObject $target -Name "Execution"
        $errorList = New-Object System.Collections.Generic.List[string]
        foreach ($existing in @(Get-LiteDeployStateProperty -InputObject $execution -Name "Errors" -Default @())) {
            if ($null -ne $existing) { $errorList.Add([string]$existing) }
        }
        foreach ($newError in $AddError) {
            if (-not [string]::IsNullOrWhiteSpace($newError)) {
                $errorList.Add((Protect-LiteDeployStateText -Text $newError))
            }
        }
        Set-LiteDeployStateValue -Object $target -Path "Execution.Errors" -Value ($errorList.ToArray())
    }

    if ($PSBoundParameters.ContainsKey('Property') -and $null -ne $Property) {
        foreach ($key in @($Property.Keys)) {
            Set-LiteDeployStateValue -Object $target -Path ([string]$key) -Value $Property[$key]
        }
    }

    if (-not $NoSave) {
        Save-LiteDeployDeploymentState -DeploymentState $target
    }

    if ($PassThru) { return $target }
}

function Resume-LiteDeployState {
    <#
    .SYNOPSIS
        Locates, validates, and re-activates a saved deployment state so the pipeline can continue.

    .DESCRIPTION
        Search order when -Path is not given: the local state file, the live state's RemoteLogDir copy, and
        (with -DeploymentUid) <Drive>\WorkLogs\Deployments\<Uid> / <Drive>\<LocalRoot>\WorkLogs\Deployments\<Uid>
        on the boot share/media drive. The newest valid candidate wins.

        On success the state becomes $global:LiteDeployDeployment (unless -NoActivate), the live BootObject
        (with its in-memory credential) is re-attached, a Failed/Cancelled status is rewound to the next
        incomplete phase, and the result is saved. Completed deployments are not resumed without -Force.

    .OUTPUTS
        PSCustomObject: Resumed, Reason, State, Path, DeploymentUid, PreviousStatus, Status, CurrentPhase,
        NextPhase, NextPhaseName, CompletedPhases, ResumeCount.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path = "",

        [Parameter(Mandatory = $false)]
        [string]$DeploymentUid = "",

        [Parameter(Mandatory = $false)]
        [psobject]$BootObject = $null,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [switch]$NoActivate,

        [Parameter(Mandatory = $false)]
        [switch]$NoSave
    )

    $result = [PSCustomObject]@{
        Resumed         = $false
        Reason          = ""
        State           = $null
        Path            = ""
        DeploymentUid   = ""
        PreviousStatus  = ""
        Status          = ""
        CurrentPhase    = 0
        NextPhase       = 0
        NextPhaseName   = ""
        CompletedPhases = @()
        ResumeCount     = 0
    }

    # Live boot context (credential stays in memory only).
    $liveBoot = $BootObject
    if ($null -eq $liveBoot) {
        $liveBoot = Get-Variable -Name LiteDeployBootObject -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    }

    # ---- Build candidate list ------------------------------------------------
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $candidates.Add($Path)
    }
    else {
        $candidates.Add((Get-LiteDeployStateFilePath))

        $liveState = Get-LiteDeployLiveState
        if ($null -ne $liveState) {
            $liveRemote = Get-LiteDeployStateRemoteDirectory -State $liveState
            if ($liveRemote) { $candidates.Add((Join-Path $liveRemote $global:LiteDeployStateFileName)) }
        }

        if (-not [string]::IsNullOrWhiteSpace($DeploymentUid)) {
            $drive = [string](Get-LiteDeployStateProperty -InputObject $liveBoot -Name "DriveLetter" -Default "Z:")
            $drive = $drive.TrimEnd('\')
            $localRoot = [string](Get-LiteDeployStateProperty -InputObject $liveBoot -Name "LocalRootName" -Default "~LiteDeploy")
            $candidates.Add(("{0}\WorkLogs\Deployments\{1}\{2}" -f $drive, $DeploymentUid, $global:LiteDeployStateFileName))
            $candidates.Add(("{0}\{1}\WorkLogs\Deployments\{2}\{3}" -f $drive, $localRoot, $DeploymentUid, $global:LiteDeployStateFileName))
        }
    }

    $existing = @(
        $candidates | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf -ErrorAction SilentlyContinue } |
            ForEach-Object { Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue } |
            Sort-Object -Property LastWriteTime -Descending
    )

    if ($existing.Count -eq 0) {
        $result.Reason = "No saved deployment state file was found."
        return $result
    }

    # ---- Pick the newest valid candidate ------------------------------------
    $chosen = $null
    $chosenPath = ""
    $rejections = New-Object System.Collections.Generic.List[string]
    foreach ($file in $existing) {
        $loaded = $null
        try { $loaded = Read-LiteDeployStateFile -Path $file.FullName }
        catch {
            $rejections.Add("'$($file.FullName)' is not valid JSON")
            continue
        }
        if ($null -eq $loaded) {
            $rejections.Add("'$($file.FullName)' is empty")
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($DeploymentUid)) {
            $loadedUid = [string](Get-LiteDeployStateProperty -InputObject $loaded -Name "DeploymentUid" -Default "")
            if ($loadedUid -ine $DeploymentUid) {
                $rejections.Add("'$($file.FullName)' belongs to deployment '$loadedUid'")
                continue
            }
        }

        $check = Test-LiteDeployState -State $loaded -Persisted -Detailed
        if (-not $check.IsValid) {
            $rejections.Add("'$($file.FullName)' failed validation: " + ($check.Errors -join "; "))
            continue
        }

        $chosen = $loaded
        $chosenPath = $file.FullName
        break
    }

    if ($null -eq $chosen) {
        $result.Reason = "No valid deployment state found. " + ($rejections -join " | ")
        return $result
    }

    $uid = [string](Get-LiteDeployStateProperty -InputObject $chosen -Name "DeploymentUid" -Default "")
    $previousStatus = [string](Get-LiteDeployStateProperty -InputObject $chosen -Name "Status" -Default "")
    $result.Path = $chosenPath
    $result.DeploymentUid = $uid
    $result.PreviousStatus = $previousStatus
    $result.Status = $previousStatus
    $result.State = $chosen

    if ($previousStatus -eq "Completed" -and -not $Force) {
        $result.Reason = "Deployment '$uid' already completed; use -Force to resume anyway."
        return $result
    }

    # ---- Work out where to continue -----------------------------------------
    $nextPhase = Get-LiteDeployStateNextPhase -State $chosen
    $completed = New-Object System.Collections.Generic.List[string]
    for ($p = 1; $p -lt $nextPhase; $p++) { $completed.Add([string]$global:LiteDeployStatePhaseNames[$p]) }

    # ---- Re-attach live context and rewind terminal status -------------------
    if ($null -ne $liveBoot) {
        Set-LiteDeployStateMember -Target $chosen -Name "BootObject" -Value $liveBoot
    }

    if ($global:LiteDeployStateTerminalStatuses -contains $previousStatus) {
        Set-LiteDeployStateValue -Object $chosen -Path "EndTime" -Value $null
        if ($previousStatus -ne "Completed") {
            Set-LiteDeployStateValue -Object $chosen -Path "Status" -Value ([string]$global:LiteDeployStatePhaseStatus[$nextPhase])
        }
    }
    if ($nextPhase -le 4) {
        Set-LiteDeployStateValue -Object $chosen -Path "CurrentPhase" -Value $nextPhase
    }

    $execution = Get-LiteDeployStateProperty -InputObject $chosen -Name "Execution"
    $resumeCount = 0
    $parsedCount = 0
    if ([int]::TryParse([string](Get-LiteDeployStateProperty -InputObject $execution -Name "ResumeCount" -Default 0), [ref]$parsedCount)) {
        $resumeCount = $parsedCount
    }
    $resumeCount++
    Set-LiteDeployStateValue -Object $chosen -Path "Execution.ResumeCount" -Value $resumeCount
    Set-LiteDeployStateValue -Object $chosen -Path "Execution.LastResumedTime" -Value (Get-LiteDeployStateTimestamp)
    Set-LiteDeployStateValue -Object $chosen -Path "Execution.ResumedFromStatus" -Value $previousStatus

    # ---- Activate -------------------------------------------------------------
    if (-not $NoActivate) {
        $global:LiteDeployDeployment = $chosen
        $remoteDir = Get-LiteDeployStateRemoteDirectory -State $chosen
        if ($remoteDir -and (Test-Path -LiteralPath $remoteDir -ErrorAction SilentlyContinue)) {
            $global:LiteDeployRemoteLogDir = $remoteDir
        }
    }

    if (-not $NoSave) {
        Save-LiteDeployDeploymentState -DeploymentState $chosen
    }

    $result.Resumed = $true
    $result.Reason = "Resumed at phase $nextPhase ($($global:LiteDeployStatePhaseNames[$nextPhase]))."
    $result.State = $chosen
    $result.Status = [string](Get-LiteDeployStateProperty -InputObject $chosen -Name "Status" -Default "")
    $result.CurrentPhase = [int](Get-LiteDeployStateProperty -InputObject $chosen -Name "CurrentPhase" -Default 0)
    $result.NextPhase = $nextPhase
    $result.NextPhaseName = [string]$global:LiteDeployStatePhaseNames[$nextPhase]
    $result.CompletedPhases = $completed.ToArray()
    $result.ResumeCount = $resumeCount

    Write-LiteDeployStateLog -Message "Resumed deployment $uid at phase $nextPhase ($($result.NextPhaseName)); previous status '$previousStatus'." -Level "INFO"
    return $result
}

function Test-LiteDeployState {
    <#
    .SYNOPSIS
        Validates a deployment state object or state file.

    .DESCRIPTION
        Returns $true/$false, or a result object (IsValid, Errors, Warnings, Source) with -Detailed.
        -Persisted treats the input as something read from disk: a stored BootObject.Credential is then an
        error (in-memory state legitimately holds the credential and only produces a warning).

    .EXAMPLE
        Test-LiteDeployState -Path "X:\~LiteDeploy\DeploymentState.json" -Detailed
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [psobject]$State = $null,

        [Parameter(Mandatory = $false)]
        [string]$Path = "",

        [Parameter(Mandatory = $false)]
        [switch]$Persisted,

        [Parameter(Mandatory = $false)]
        [switch]$Detailed
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $source = "InputObject"
    $subject = $State
    $fromFile = [bool]$Persisted

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $source = $Path
        $fromFile = $true
        try {
            $subject = Read-LiteDeployStateFile -Path $Path
            if ($null -eq $subject) { $errors.Add("State file '$Path' was not found or is empty.") }
        }
        catch {
            $subject = $null
            $errors.Add("State file '$Path' is not valid JSON: $($_.Exception.Message)")
        }
    }
    elseif ($null -eq $subject) {
        $subject = Get-LiteDeployState
        $source = "CurrentState"
        if ($null -eq $subject) { $errors.Add("No deployment state is available.") }
    }

    if ($null -ne $subject) {
        $required = @("DeploymentUid", "Status", "CurrentPhase", "StartTime", "LogLocations",
                      "HardwarePreCheck", "Workflow", "Disk", "OSInstall", "Execution")
        foreach ($name in $required) {
            if (-not (Test-LiteDeployStateHasProperty -InputObject $subject -Name $name)) {
                $errors.Add("Missing property '$name'.")
            }
        }

        $sections = @{
            HardwarePreCheck = "Passed"
            Workflow         = "Confirmed"
            Disk             = "Formatted"
            OSInstall        = "Applied"
            Execution        = "CurrentStep"
        }
        foreach ($sectionName in $sections.Keys) {
            $section = Get-LiteDeployStateProperty -InputObject $subject -Name $sectionName
            if ($null -ne $section -and -not (Test-LiteDeployStateHasProperty -InputObject $section -Name $sections[$sectionName])) {
                $errors.Add("Missing property '$sectionName.$($sections[$sectionName])'.")
            }
        }

        $uidValue = [string](Get-LiteDeployStateProperty -InputObject $subject -Name "DeploymentUid" -Default "")
        if (Test-LiteDeployStateHasProperty -InputObject $subject -Name "DeploymentUid") {
            if ([string]::IsNullOrWhiteSpace($uidValue)) { $errors.Add("DeploymentUid is empty.") }
        }

        $statusValue = [string](Get-LiteDeployStateProperty -InputObject $subject -Name "Status" -Default "")
        if ($statusValue -and ($global:LiteDeployStateKnownStatuses -notcontains $statusValue)) {
            $warnings.Add("Unrecognized Status '$statusValue'.")
        }

        $phaseRaw = Get-LiteDeployStateProperty -InputObject $subject -Name "CurrentPhase"
        if ($null -ne $phaseRaw) {
            $phaseParsed = 0
            if (-not [int]::TryParse([string]$phaseRaw, [ref]$phaseParsed) -or $phaseParsed -lt 0 -or $phaseParsed -gt 9) {
                $errors.Add("CurrentPhase '$phaseRaw' is not an integer between 0 and 9.")
            }
        }

        $startRaw = [string](Get-LiteDeployStateProperty -InputObject $subject -Name "StartTime" -Default "")
        if ($startRaw) {
            $startParsed = [datetime]::MinValue
            if (-not [datetime]::TryParse($startRaw, [ref]$startParsed)) {
                $warnings.Add("StartTime '$startRaw' is not a parseable date.")
            }
        }

        $execution = Get-LiteDeployStateProperty -InputObject $subject -Name "Execution"
        $percentRaw = Get-LiteDeployStateProperty -InputObject $execution -Name "PercentComplete"
        if ($null -ne $percentRaw) {
            $percentParsed = 0.0
            if (-not [double]::TryParse([string]$percentRaw, [ref]$percentParsed) -or $percentParsed -lt 0 -or $percentParsed -gt 100) {
                $errors.Add("Execution.PercentComplete '$percentRaw' is not a number between 0 and 100.")
            }
        }

        # Credentials must never be persisted.
        $boot = Get-LiteDeployStateProperty -InputObject $subject -Name "BootObject"
        $credential = Get-LiteDeployStateProperty -InputObject $boot -Name "Credential"
        if ($null -ne $credential) {
            if ($fromFile) { $errors.Add("Persisted state contains BootObject.Credential (credentials must never be written to disk).") }
            else { $warnings.Add("BootObject.Credential is present in memory; it is omitted when the state is saved.") }
        }
    }

    $isValid = ($errors.Count -eq 0)
    if (-not $Detailed) { return $isValid }

    return [PSCustomObject]@{
        IsValid  = $isValid
        Errors   = $errors.ToArray()
        Warnings = $warnings.ToArray()
        Source   = $source
    }
}

function Get-DeploymentStateFromFile {
    <#
    .SYNOPSIS
        Compatibility reader for the Progress UI: returns a UI-state hashtable built from a state file.

    .DESCRIPTION
        Accepts either the Progress schema (camelCase keys such as status / overallPercent) or the full
        DeploymentState.json schema written by Save-LiteDeployDeploymentState (mapped onto the same UI keys).
        Starts from a clone of -DefaultState, never throws, and never surfaces credentials.

    .PARAMETER Path
        State file. Defaults to <SystemDrive>\~LiteDeploy\DeploymentState.json. Relative paths resolve
        against the current location.

    .PARAMETER DefaultState
        Baseline hashtable; its values remain when the file lacks a field.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Path = "",

        [Parameter(Mandatory = $false, Position = 1)]
        [hashtable]$DefaultState = $null
    )

    $state = if ($null -ne $DefaultState) { $DefaultState.Clone() } else { @{} }

    $targetPath = $Path
    if ([string]::IsNullOrWhiteSpace($targetPath)) { $targetPath = Get-LiteDeployStateFilePath }
    if (-not [System.IO.Path]::IsPathRooted($targetPath)) {
        $targetPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($targetPath)
    }

    try {
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) { return $state }

        $stream = $null
        $reader = $null
        $raw = ""
        try {
            $stream = New-Object System.IO.FileStream($targetPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            $raw = $reader.ReadToEnd()
        }
        finally {
            if ($null -ne $reader) { $reader.Dispose() }
            elseif ($null -ne $stream) { $stream.Dispose() }
        }
        if ([string]::IsNullOrWhiteSpace($raw)) { return $state }

        if ($raw -match '"Computer Model"') {
            $raw = $raw -replace '"Computer Model"\s*:', '"computerModel":'
        }
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $data) { return $state }

        if (Test-LiteDeployStateHasProperty -InputObject $data -Name "DeploymentUid") {
            # ---- Full DeploymentState.json schema -> UI keys ----
            $state['DeploymentId'] = [string](Get-LiteDeployStateProperty -InputObject $data -Name "DeploymentUid" -Default "")

            $status = Get-LiteDeployStateProperty -InputObject $data -Name "Status"
            if ($null -ne $status) { $state['Status'] = [string]$status }

            $phaseParsed = 0
            if ([int]::TryParse([string](Get-LiteDeployStateProperty -InputObject $data -Name "CurrentPhase" -Default 0), [ref]$phaseParsed) -and
                $global:LiteDeployStatePhaseNames.ContainsKey($phaseParsed)) {
                $state['Phase'] = [string]$global:LiteDeployStatePhaseNames[$phaseParsed]
            }

            $execution = Get-LiteDeployStateProperty -InputObject $data -Name "Execution"
            $step = Get-LiteDeployStateProperty -InputObject $execution -Name "CurrentStep"
            if ($null -ne $step) { $state['CurrentStep'] = [string]$step }

            $percentParsed = 0
            if ([int]::TryParse([string](Get-LiteDeployStateProperty -InputObject $execution -Name "PercentComplete"), [ref]$percentParsed)) {
                $state['OverallPercent'] = $percentParsed
            }

            $errorList = @(Get-LiteDeployStateProperty -InputObject $execution -Name "Errors" -Default @())
            if ($errorList.Count -gt 0) {
                $state['Message'] = Protect-LiteDeployStateText -Text ([string]$errorList[$errorList.Count - 1])
            }

            $workflow = Get-LiteDeployStateProperty -InputObject $data -Name "Workflow"
            $selection = Get-LiteDeployStateProperty -InputObject $workflow -Name "SelectionData"
            $workflowName = Get-LiteDeployStateProperty -InputObject $selection -Name "WorkflowName"
            if ($null -ne $workflowName) {
                $state['WorkflowName'] = [string]$workflowName
                $state['OperatingSystem'] = [string]$workflowName
            }
            $computerName = Get-LiteDeployStateProperty -InputObject $selection -Name "ComputerName"
            if ($null -ne $computerName) { $state['ComputerName'] = [string]$computerName }

            $boot = Get-LiteDeployStateProperty -InputObject $data -Name "BootObject"
            if ($null -ne $boot) {
                $isWinPE = Get-LiteDeployStateProperty -InputObject $boot -Name "IsWinPE"
                if ($null -ne $isWinPE) { $state['Environment'] = if ([bool]$isWinPE) { "WinPE" } else { "FullOS" } }
                $deployType = [string](Get-LiteDeployStateProperty -InputObject $boot -Name "DeploymentType" -Default "")
                if ($deployType -ieq "Network") { $state['Source'] = "Network Share" }
                elseif ($deployType -ieq "Media") { $state['Source'] = "Local (Media) Repository" }
            }
        }
        else {
            # ---- Progress schema (camelCase) -> UI keys ----
            $stringMap = [ordered]@{
                WindowTitle     = "windowTitle"
                ProductName     = "productName"
                WorkflowName    = "workflowName"
                Environment     = "environment"
                Status          = "status"
                Phase           = "phase"
                CurrentStep     = "currentStep"
                Message         = "message"
                LogMessage      = "logMessage"
                DeploymentId    = "deploymentId"
                ComputerName    = "computerName"
                ComputerModel   = "computerModel"
                OperatingSystem = "operatingSystem"
                Source          = "source"
            }
            foreach ($uiKey in $stringMap.Keys) {
                $value = Get-LiteDeployStateProperty -InputObject $data -Name $stringMap[$uiKey]
                if (($null -eq $value) -and $uiKey -eq "Source") {
                    $value = Get-LiteDeployStateProperty -InputObject $data -Name "repository"
                }
                if ($null -ne $value -and -not [string]::IsNullOrEmpty([string]$value)) { $state[$uiKey] = [string]$value }
            }

            $intMap = [ordered]@{ StepPercent = "stepPercent"; OverallPercent = "overallPercent" }
            foreach ($uiKey in $intMap.Keys) {
                $intParsed = 0
                $intRaw = Get-LiteDeployStateProperty -InputObject $data -Name $intMap[$uiKey]
                if ($null -ne $intRaw -and [int]::TryParse([string]$intRaw, [ref]$intParsed)) { $state[$uiKey] = $intParsed }
            }

            $overallText = [string](Get-LiteDeployStateProperty -InputObject $data -Name "overallText" -Default "")
            if ($overallText -match '(?:Action|Step)\s+(\d+)\s+of\s+(\d+)') {
                $state['StepNumber'] = [int]$Matches[1]
                $state['TotalSteps'] = [int]$Matches[2]
            }
        }
    }
    catch {
        # Compatibility reader: unreadable input yields the defaults.
    }

    return $state
}

# Aliases (resolved in the same scope as the functions above)
Set-Alias -Name Save-LiteDeployState -Value Save-LiteDeployDeploymentState
Set-Alias -Name Set-LiteDeployState -Value Update-LiteDeployState

# ==============================================================================
# 6. STANDALONE EXECUTION (read-only: display the state file if present)
# ==============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    $meta = Get-LiteDeployComponentMetadata
    $displayPath = if ([string]::IsNullOrWhiteSpace($StatePath)) { Get-LiteDeployStateFilePath } else { $StatePath }

    Write-Host ""
    Write-Host ("{0} v{1} ({2})" -f $meta.Name, $meta.Version, $meta.ComponentId) -ForegroundColor Cyan
    Write-Host ("  State file : {0}" -f $displayPath)

    if (-not (Test-Path -LiteralPath $displayPath -PathType Leaf)) {
        Write-Host "  Exists     : False (no deployment state recorded yet)" -ForegroundColor Yellow
        Write-Host ""
        return
    }

    Write-Host "  Exists     : True"
    $shown = Get-LiteDeployState -Path $displayPath
    if ($null -eq $shown) {
        Write-Host "  The state file could not be read or is not valid JSON." -ForegroundColor Red
        Write-Host ""
        return
    }

    $check = Test-LiteDeployState -State $shown -Persisted -Detailed
    $execution = Get-LiteDeployStateProperty -InputObject $shown -Name "Execution"
    $workflow = Get-LiteDeployStateProperty -InputObject $shown -Name "Workflow"
    $selection = Get-LiteDeployStateProperty -InputObject $workflow -Name "SelectionData"
    $disk = Get-LiteDeployStateProperty -InputObject $shown -Name "Disk"
    $osInstall = Get-LiteDeployStateProperty -InputObject $shown -Name "OSInstall"
    $logLocations = Get-LiteDeployStateProperty -InputObject $shown -Name "LogLocations"
    $phaseNumber = 0
    [void][int]::TryParse([string](Get-LiteDeployStateProperty -InputObject $shown -Name "CurrentPhase" -Default 0), [ref]$phaseNumber)
    $phaseLabel = if ($global:LiteDeployStatePhaseNames.ContainsKey($phaseNumber)) { " ($($global:LiteDeployStatePhaseNames[$phaseNumber]))" } else { "" }

    Write-Host ""
    Write-Host ("  Deployment : {0}" -f (Get-LiteDeployStateProperty -InputObject $shown -Name "DeploymentUid" -Default "-"))
    Write-Host ("  Status     : {0}" -f (Get-LiteDeployStateProperty -InputObject $shown -Name "Status" -Default "-"))
    Write-Host ("  Phase      : {0}{1}" -f $phaseNumber, $phaseLabel)
    Write-Host ("  Step       : {0} ({1}%)" -f (Get-LiteDeployStateProperty -InputObject $execution -Name "CurrentStep" -Default "-"), (Get-LiteDeployStateProperty -InputObject $execution -Name "PercentComplete" -Default 0))
    Write-Host ("  Started    : {0}" -f (Get-LiteDeployStateProperty -InputObject $shown -Name "StartTime" -Default "-"))
    Write-Host ("  Ended      : {0}" -f (Get-LiteDeployStateProperty -InputObject $shown -Name "EndTime" -Default "-"))
    Write-Host ("  Workflow   : {0}" -f (Get-LiteDeployStateProperty -InputObject $selection -Name "WorkflowName" -Default "-"))
    Write-Host ("  Computer   : {0}" -f (Get-LiteDeployStateProperty -InputObject $selection -Name "ComputerName" -Default "-"))
    Write-Host ("  Disk       : formatted={0}, disk={1}, mode={2}" -f (Get-LiteDeployStateProperty -InputObject $disk -Name "Formatted" -Default $false), (Get-LiteDeployStateProperty -InputObject $disk -Name "DiskNumber" -Default "-"), (Get-LiteDeployStateProperty -InputObject $disk -Name "BootMode" -Default "-"))
    Write-Host ("  OS install : applied={0}, exit code={1}" -f (Get-LiteDeployStateProperty -InputObject $osInstall -Name "Applied" -Default $false), (Get-LiteDeployStateProperty -InputObject $osInstall -Name "ExitCode" -Default "-"))
    Write-Host ("  Remote logs: {0}" -f (Get-LiteDeployStateProperty -InputObject $logLocations -Name "RemoteLogDir" -Default "(none)"))
    Write-Host ("  Next phase : {0}" -f (Get-LiteDeployStateNextPhase -State $shown))
    Write-Host ("  Valid      : {0}" -f $check.IsValid) -ForegroundColor $(if ($check.IsValid) { "Green" } else { "Red" })

    foreach ($problem in @($check.Errors)) { Write-Host ("    ERROR   {0}" -f (Protect-LiteDeployStateText -Text $problem)) -ForegroundColor Red }
    foreach ($note in @($check.Warnings)) { Write-Host ("    WARNING {0}" -f (Protect-LiteDeployStateText -Text $note)) -ForegroundColor Yellow }

    $recordedErrors = @(Get-LiteDeployStateProperty -InputObject $execution -Name "Errors" -Default @())
    if ($recordedErrors.Count -gt 0) {
        Write-Host "  Errors recorded:" -ForegroundColor Yellow
        foreach ($recorded in $recordedErrors) {
            Write-Host ("    - {0}" -f (Protect-LiteDeployStateText -Text ([string]$recorded))) -ForegroundColor Yellow
        }
    }
    Write-Host ""
}

