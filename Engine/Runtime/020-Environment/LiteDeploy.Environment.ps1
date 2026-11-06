<#
.SYNOPSIS
    LiteDeploy Environment - explicit path settings, runtime detection, share connectivity, and process execution.

.DESCRIPTION
    Architecture v2 component. Provides:
      - Environment detection   Test-LiteDeployWinPE, Get-LiteDeployEnvironment, Get-LiteDeployRoot
      - Path / UNC helpers      Format-LiteDeployUNCPath, Test-LiteDeployPath
      - UI theme                Get-LiteDeployUiTheme (BootConfig.Ui.Theme → Light|Dark for all Runtime UI)
      - Share connectivity      Connect-LiteDeployShare, Disconnect-LiteDeployShare (New-PSDrive / New-SmbMapping; credentials never on a process command line)
      - Process execution       Invoke-LiteDeployProcess

    Dot-source to load the functions:
        . "Z:\Engine\Scripts\Runtime\LiteDeploy.Environment.ps1"

    Run directly (no dot-source) to print Get-LiteDeployEnvironment. -Metadata returns the component record.

    ComponentId: Environment    Dependencies: Logs

.NOTES
    PowerShell 5.1, WinPE 5.1/10/11, Set-StrictMode -Version 2.0 compatible.
    Console controls live in UI.HostShell. Load Environment once with -Mode Development for source use.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Metadata,

    # Choose once when loading Environment. Production is safe for published/WinPE copies.
    [ValidateSet('Development', 'Production')][string]$Mode = 'Production',

    # Optional explicit Runtime folder for a test publish or custom location.
    [string]$RuntimeRoot = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ==============================================================================
# COMPONENT METADATA
# ==============================================================================

function Get-LiteDeployComponentMetadata {
    return [PSCustomObject]@{
        ComponentId          = "Environment"
        Name                 = "LiteDeploy Environment"
        Version              = "2.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "Universal"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("Logs")
        Description          = "Explicit runtime paths, environment detection, share connectivity, and process execution."
    }
}

if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

if ($RuntimeRoot -and $RuntimeRoot -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+)') {
    throw 'RuntimeRoot must be an absolute drive or UNC path.'
}

# PATH SETTINGS: change layout here, never in Engine or a consumer component.
# Development uses the source root beside this Environment folder.
# Production uses <deployment source>\Engine\Scripts\Runtime unless RuntimeRoot is supplied.
$global:LiteDeployPathSettings = [pscustomobject]@{
    Mode = $Mode
    ComponentRoot = if ($RuntimeRoot) { $RuntimeRoot } elseif ($Mode -eq 'Development') { Split-Path -Parent $PSScriptRoot } else { $PSScriptRoot }
    RuntimeRootOverride = $RuntimeRoot
    ProductionRuntimePath = 'Engine\Scripts\Runtime'
    ProductionFiles = [ordered]@{
        Environment = 'LiteDeploy.Environment.ps1'
        Boot = 'LiteDeploy.Boot.ps1'
        Engine = 'LiteDeploy.Engine.ps1'
        FullOS = 'LiteDeploy.FullOS.ps1'
        Logs = 'LiteDeploy.Logs.ps1'
        Hardware = 'LiteDeploy.Hardware.ps1'
        State = 'LiteDeploy.State.ps1'
        Workflow = 'LiteDeploy.Workflow.ps1'
        Drivers = 'LiteDeploy.Drivers.ps1'
        Disk = 'LiteDeploy.Disk.ps1'
        Image = 'LiteDeploy.Image.ps1'
        Packages = 'LiteDeploy.Packages.ps1'
        HostShell = 'UI\LiteDeploy.UI.HostShell.ps1'
        HardwarePrecheck = 'UI\LiteDeploy.UI.HardwarePrecheck.ps1'
        HardwarePrecheckView = 'UI\LiteDeploy.UI.HardwarePrecheck.xaml'
        WorkflowSelection = 'UI\LiteDeploy.UI.WorkflowSelection.ps1'
        WorkflowSelectionView = 'UI\LiteDeploy.UI.WorkflowSelection.xaml'
        DriverPicker = 'UI\LiteDeploy.UI.WorkflowSelectionDriverPicker.ps1'
        DriverPickerView = 'UI\LiteDeploy.UI.WorkflowSelectionDriverPicker.xaml'
        Progress = 'UI\LiteDeploy.UI.Progress.ps1'
        AdminDrivers = '..\Admin\LiteDeploy.Admin.Drivers.ps1'
    }
    DevelopmentFolders = @{
        Environment = '020-Environment'; Boot = '000-Boot'; Engine = '100-Engine'; FullOS = '100-Engine'
        Logs = '010-Logs'; Hardware = '030-Hardware'; State = '040-State'
        Workflow = '050-Workflow'; Drivers = '070-Drivers'; Disk = '060-Disk'
        Image = '080-Image'; Packages = '090-Packages'; HostShell = '110-UI\HostShell'
        HardwarePrecheck = '110-UI\HardwarePrecheck'; HardwarePrecheckView = '110-UI\HardwarePrecheck'
        WorkflowSelection = '110-UI\WorkflowSelection'; WorkflowSelectionView = '110-UI\WorkflowSelection'
        DriverPicker = '110-UI\WorkflowSelection'; DriverPickerView = '110-UI\WorkflowSelection'
        Progress = '110-UI\Progress'; AdminDrivers = '..\Admin\030-Drivers'
    }
}
# File-only log helper: uses Logs when loaded, otherwise stays silent (verbose only).
function Write-LiteDeployEnvironmentLog {
    param([string]$Message, [string]$Level = "INFO")
    if (Get-Command -Name Write-LiteDeployLog -ErrorAction SilentlyContinue) {
        Write-LiteDeployLog -Message $Message -Level $Level -Component "Environment" -NoConsole
    }
    else {
        Write-Verbose "[$Level] $Message"
    }
}

#region Runtime paths from the declared Environment settings

function Get-LiteDeployRuntimePaths {
    <#
    .SYNOPSIS
        Builds the Engine's path list from the supplied source and layout. Does not search or import.
    .DESCRIPTION
        Network uses BootObject.DriveLetter. Media uses BootObject.MediaDriveLetter
        (or DriveLetter when MediaDriveLetter is not supplied) plus LocalRootName.
        ConfigPath, when supplied by Boot, is authoritative; a missing file is an error,
        not a reason to silently load configuration from another location.
        Environment's top-level settings select the mode and root; Engine supplies required names.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$BootObject,

        # Engine selects component names; Environment only maps them to exact locations.
        [string[]]$RequiredComponents = @()
    )

    if (-not $BootObject.PSObject.Properties['DeploymentType'] -or
        $BootObject.DeploymentType -notin @('Network', 'Media')) {
        throw 'BootObject.DeploymentType must be Network or Media.'
    }

    $sourceDrive = ''
    if ($BootObject.DeploymentType -eq 'Media' -and
        $BootObject.PSObject.Properties['MediaDriveLetter'] -and $BootObject.MediaDriveLetter) {
        $sourceDrive = [string]$BootObject.MediaDriveLetter
    }
    elseif ($BootObject.PSObject.Properties['DriveLetter']) {
        $sourceDrive = [string]$BootObject.DriveLetter
    }
    # A bare drive letter means its root, never the current directory on that drive.
    if ($sourceDrive -match '^[A-Za-z]:$') { $sourceDrive += '\' }
    if ($sourceDrive -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+)') {
        throw 'BootObject must supply an absolute source drive or share path. No default Z: drive is assumed.'
    }


    $deploymentRoot = $sourceDrive
    if ($BootObject.DeploymentType -eq 'Media') {
        if (-not $BootObject.PSObject.Properties['LocalRootName'] -or
            [string]::IsNullOrWhiteSpace([string]$BootObject.LocalRootName)) {
            throw 'Media deployment requires BootObject.LocalRootName.'
        }
        $mediaFolder = [string]$BootObject.LocalRootName
        if ($mediaFolder -match '[\\/:]' -or $mediaFolder -in @('.', '..')) {
            throw 'BootObject.LocalRootName must be a single folder name, such as ~LiteDeploy.'
        }
        $deploymentRoot = Join-Path $sourceDrive $mediaFolder
    }

    $bootConfigPath = Join-Path $deploymentRoot 'Config\BootConfig.json'
    if ($BootObject.PSObject.Properties['ConfigPath'] -and $BootObject.ConfigPath) {
        $bootConfigPath = [string]$BootObject.ConfigPath
    }
    if ($bootConfigPath -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+)') { throw 'BootObject.ConfigPath must be an absolute path.' }

    $settings = $global:LiteDeployPathSettings
    $resolvedRuntimeRoot = if ($settings.RuntimeRootOverride) {
        $settings.RuntimeRootOverride
    } elseif ($settings.Mode -eq 'Development') {
        $settings.ComponentRoot
    } else {
        Join-Path $deploymentRoot $settings.ProductionRuntimePath
    }
    if ($RequiredComponents.Count -eq 0) {
        $RequiredComponents = @('BootConfig') + @($settings.ProductionFiles.Keys | Where-Object { $_ -notin @('Boot', 'Engine', 'Workflow', 'Packages', 'AdminDrivers') })
    }
    $requiredFiles = [ordered]@{}
    foreach ($name in $RequiredComponents) {
        $requiredFiles[$name] = if ($name -eq 'BootConfig') { $bootConfigPath } else {
            Get-LiteDeployComponentPath -Name $name -RuntimeRoot $resolvedRuntimeRoot
        }
    }

    $workingRoot = Get-LiteDeployRoot
    $localLogDirectory = Join-Path $workingRoot 'WorkLogs'

    [pscustomobject]@{
        Mode = $settings.Mode
        DeploymentRoot = $deploymentRoot
        RuntimeRoot = $resolvedRuntimeRoot
        WorkingRoot = $workingRoot
        LocalLogDirectory = $localLogDirectory
        StatePath = Join-Path $workingRoot 'DeploymentState.json'
        DeploymentLogRoot = Join-Path $deploymentRoot 'WorkLogs\Deployments'
        ProgressStdErr = Join-Path $localLogDirectory 'ProgressHost.stderr.log'
        ProgressStdOut = Join-Path $localLogDirectory 'ProgressHost.stdout.log'
        PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        RequiredFiles = [pscustomobject]$requiredFiles
    }
}

function Test-LiteDeployRequiredFiles {
    <#
    .SYNOPSIS
        Checks the supplied file list and returns every missing name and path. No imports or writes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Paths)

    $missingFiles = @(
        foreach ($file in $Paths.PSObject.Properties) {
            if ([string]::IsNullOrWhiteSpace([string]$file.Value) -or
                -not (Test-Path -LiteralPath $file.Value -PathType Leaf)) {
                '{0}: {1}' -f $file.Name, $file.Value
            }
        }
    )
    [pscustomobject]@{ Ok = ($missingFiles.Count -eq 0); Missing = $missingFiles }
}

function Resolve-LiteDeployContentPath {
    # Catalog-relative paths belong to the declared deployment root. No file search is performed.
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Path = '',
        [Parameter(Mandatory = $true)][string]$DeploymentRoot
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $contentPath = $Path.Trim()
    if ($contentPath -match '^[A-Za-z]:[\\/]' -or $contentPath -match '^\\\\') { return $contentPath }
    if ($contentPath -match '^[A-Za-z]:') { throw "Use an absolute content path, not a drive-relative path: $contentPath" }
    return Join-Path $DeploymentRoot $contentPath.TrimStart('\', '/')
}

function Get-LiteDeployComponentPath {
    <#
    .SYNOPSIS
        Returns one component path using Environment's mode and table. No directory search.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name, [string]$RuntimeRoot = '')

    $settings = $global:LiteDeployPathSettings
    if (-not $settings.ProductionFiles.Contains($Name)) { throw "Unknown component '$Name'. Define its path in Environment." }
    if (-not $RuntimeRoot) { $RuntimeRoot = $settings.ComponentRoot }
    $relativePath = $settings.ProductionFiles[$Name]
    if ($settings.Mode -eq 'Development') {
        $relativePath = Join-Path $settings.DevelopmentFolders[$Name] (Split-Path -Leaf $relativePath)
    }
    return Join-Path $RuntimeRoot $relativePath
}

function Resolve-LiteDeployEnginePath {
    # Boot has already discovered the source. Prefer LiteDeploy.Engine.ps1; fall back to the
    # BootInitializer compat alias LiteDeploy.DeploymentEngine.ps1 (same published content).
    param([string]$RootPath, [string]$LocalRootName = '~LiteDeploy', [ValidateSet('Network', 'Media')][string]$DeploymentType = 'Media')
    $sourceRoot = if ($RootPath -match '^[A-Za-z]:$') { $RootPath + '\' } else { $RootPath }
    $deploymentRoot = if ($DeploymentType -eq 'Media') { Join-Path $sourceRoot $LocalRootName } else { $sourceRoot }
    $settings = $global:LiteDeployPathSettings
    $runtimeRoot = if ($settings.RuntimeRootOverride) { $settings.RuntimeRootOverride } elseif ($settings.Mode -eq 'Development') { $settings.ComponentRoot } else { Join-Path $deploymentRoot $settings.ProductionRuntimePath }
    $enginePath = Get-LiteDeployComponentPath -Name Engine -RuntimeRoot $runtimeRoot
    if (Test-Path -LiteralPath $enginePath -PathType Leaf) {
        return $enginePath
    }
    $compatPath = Join-Path (Split-Path -Parent $enginePath) 'LiteDeploy.DeploymentEngine.ps1'
    if (Test-Path -LiteralPath $compatPath -PathType Leaf) {
        return $compatPath
    }
    return $enginePath
}

function Get-LiteDeployUiTheme {
    <#
    .SYNOPSIS
        Resolves the shared Runtime UI theme (Light|Dark) from BootConfig.Ui.Theme.

    .DESCRIPTION
        Single source of truth for PreCheck, WorkflowSelection, DriverPicker, and Progress.
        Precedence: -ExplicitTheme > BootConfig/BootObject.Config.Ui.Theme > file at -BootConfigPath > Light.
    #>
    [CmdletBinding()]
    param(
        [psobject]$BootConfig = $null,
        [string]$BootConfigPath = "",
        [string]$ExplicitTheme = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitTheme)) {
        switch -Regex ($ExplicitTheme.Trim()) {
            '^(?i)light$' { return "Light" }
            '^(?i)dark$'  { return "Dark" }
        }
    }

    $config = $BootConfig
    if ($null -eq $config -and -not [string]::IsNullOrWhiteSpace($BootConfigPath) -and
        (Test-Path -LiteralPath $BootConfigPath -PathType Leaf)) {
        try {
            $config = Get-Content -LiteralPath $BootConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $config = $null
        }
    }

    # BootObject may be passed; prefer nested .Config when Ui is not on the root.
    if ($config -and $config.PSObject.Properties["Config"] -and $config.Config -and
        -not ($config.PSObject.Properties["Ui"] -and $config.Ui)) {
        $config = $config.Config
    }

    $raw = $null
    if ($config -and $config.PSObject.Properties["Ui"] -and $config.Ui -and
        $config.Ui.PSObject.Properties["Theme"] -and $config.Ui.Theme) {
        $raw = [string]$config.Ui.Theme
    }

    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        switch -Regex ($raw.Trim()) {
            '^(?i)light$' { return "Light" }
            '^(?i)dark$'  { return "Dark" }
        }
    }

    return "Light"
}

#endregion

#region 1 - Environment detection

function Test-LiteDeployWinPE {
    <#
    .SYNOPSIS
        Returns $true when running inside Windows PE.
    #>
    [CmdletBinding()]
    param()

    try {
        if (Test-Path -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT" -ErrorAction SilentlyContinue) {
            return $true
        }
    }
    catch {}

    if ($env:SystemDrive -eq "X:" -and (Test-Path -LiteralPath "X:\Windows\System32\wpeinit.exe" -ErrorAction SilentlyContinue)) {
        return $true
    }
    return $false
}

function Get-LiteDeployRoot {
    <#
    .SYNOPSIS
        Resolves the ~LiteDeploy working root under the system drive (X:\~LiteDeploy in WinPE).
    #>
    [CmdletBinding()]
    param(
        [string]$SystemDrive = "",
        [switch]$Create
    )

    if ([string]::IsNullOrWhiteSpace($SystemDrive)) {
        $SystemDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "X:" }
    }
    $root = Join-Path ($SystemDrive.TrimEnd('\') + "\") "~LiteDeploy"

    if ($Create -and -not (Test-Path -LiteralPath $root)) {
        $null = New-Item -Path $root -ItemType Directory -Force -ErrorAction SilentlyContinue
    }
    return $root
}

function Get-LiteDeployEnvironment {
    <#
    .SYNOPSIS
        Returns an object describing the current runtime (WinPE/FullOS, architecture, drives, versions).
    #>
    [CmdletBinding()]
    param()

    $isWinPE = Test-LiteDeployWinPE
    $rawArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $arch = switch -Regex ([string]$rawArch) {
        '^(AMD64|x64)$' { "x64"; break }
        '^ARM64$'       { "arm64"; break }
        '^(x86|X86)$'   { "x86"; break }
        default         { if ($rawArch) { ([string]$rawArch).ToLower() } else { "unknown" } }
    }

    $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "X:" }

    $build = ""
    try {
        $build = [string](Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name CurrentBuildNumber -ErrorAction Stop).CurrentBuildNumber
    }
    catch {}

    $isAdmin = $false
    try {
        $principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
        $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {}

    [PSCustomObject]@{
        Type              = if ($isWinPE) { "WinPE" } else { "FullOS" }
        IsWinPE           = $isWinPE
        Architecture      = $arch
        Is64BitOS         = [Environment]::Is64BitOperatingSystem
        Is64BitProcess    = [Environment]::Is64BitProcess
        OSVersion         = [Environment]::OSVersion.Version.ToString()
        BuildNumber       = $build
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        SystemDrive       = $sysDrive
        WindowsDirectory  = $env:SystemRoot
        LiteDeployRoot    = (Get-LiteDeployRoot -SystemDrive $sysDrive)
        TempPath          = $env:TEMP
        ComputerName      = $env:COMPUTERNAME
        UserName          = $env:USERNAME
        IsAdministrator   = $isAdmin
        IsWindowsTerminal = [bool]$env:WT_SESSION
    }
}

#endregion

#region 2 - Paths and shares

function Format-LiteDeployUNCPath {
    <#
    .SYNOPSIS
        Normalizes a path to \\server\share form (forward slashes converted, no trailing slash).
    #>
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $clean = $Path.Trim() -replace '/', '\'
    if ($clean -notlike '\\*') {
        $clean = "\\$($clean.TrimStart('\'))"
    }
    return $clean.TrimEnd('\')
}

function Test-LiteDeployPath {
    <#
    .SYNOPSIS
        Safe Test-Path wrapper: returns $false instead of throwing (bad UNC, access denied, empty path).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Path,

        [ValidateSet("Any", "Leaf", "Container")]
        [string]$PathType = "Any"
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        if ($PathType -eq "Any") {
            return [bool](Test-Path -LiteralPath $Path -ErrorAction Stop)
        }
        return [bool](Test-Path -LiteralPath $Path -PathType $PathType -ErrorAction Stop)
    }
    catch {
        return $false
    }
}

function Invoke-LiteDeployProcess {
    <#
    .SYNOPSIS
        Starts a process, waits (optional timeout), and returns exit code and captured output.
    .DESCRIPTION
        Arguments are NOT logged unless -LogArguments is specified, so callers can safely pass secrets.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$FilePath,

        [Parameter(Position = 1)]
        [string]$ArgumentList = "",

        [string]$WorkingDirectory = "",

        [ValidateRange(0, 86400)]
        [int]$TimeoutSeconds = 0,

        [switch]$CaptureOutput,
        [switch]$LogArguments
    )

    $startedAt = Get-Date
    $result = [ordered]@{
        FilePath        = $FilePath
        Started         = $false
        ExitCode        = -1
        TimedOut        = $false
        StdOut          = ""
        StdErr          = ""
        DurationSeconds = 0
        Error           = ""
    }

    $logName = Split-Path -Leaf $FilePath
    $logLine = if ($LogArguments) { "Starting process: $logName $ArgumentList" } else { "Starting process: $logName (arguments not logged)" }
    Write-LiteDeployEnvironmentLog -Message $logLine

    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = $ArgumentList
        $psi.UseShellExecute = $false
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $psi.WorkingDirectory = $WorkingDirectory
        }
        if ($CaptureOutput) {
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
        }

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $null = $proc.Start()
        $result.Started = $true

        $outTask = $null
        $errTask = $null
        if ($CaptureOutput) {
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()
        }

        $waitMs = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds * 1000 } else { -1 }
        if ($proc.WaitForExit($waitMs)) {
            $result.ExitCode = $proc.ExitCode
        }
        else {
            $result.TimedOut = $true
            try { $proc.Kill() } catch {}
            $null = $proc.WaitForExit(5000)
            Write-LiteDeployEnvironmentLog -Message "Process '$logName' exceeded $TimeoutSeconds second(s) and was terminated." -Level "ERROR"
        }

        if ($CaptureOutput) {
            if ($outTask.Wait(5000)) { $result.StdOut = $outTask.Result }
            if ($errTask.Wait(5000)) { $result.StdErr = $errTask.Result }
        }
    }
    catch {
        $result.Error = $_.Exception.Message
        Write-LiteDeployEnvironmentLog -Message "Failed to run '$logName': $($result.Error)" -Level "ERROR"
    }
    finally {
        if ($proc) { $proc.Dispose() }
    }

    $result.DurationSeconds = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 2)
    if ($result.Started -and -not $result.TimedOut) {
        Write-LiteDeployEnvironmentLog -Message "Process '$logName' exited with code $($result.ExitCode)."
    }
    return [PSCustomObject]$result
}

function Disconnect-LiteDeployShare {
    <#
    .SYNOPSIS
        Removes a mapped share using native PowerShell (Remove-PSDrive / Remove-SmbMapping).
    .DESCRIPTION
        Never calls net.exe. Safe to call when the mapping is already gone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Target
    )

    $ok = $false
    if ($Target -match '^[A-Za-z]:?$') {
        $drive = $Target.TrimEnd(':').ToUpper() + ":"
        $driveName = $drive.TrimEnd(':')

        if (Get-Command Remove-SmbMapping -ErrorAction SilentlyContinue) {
            try {
                Remove-SmbMapping -LocalPath $drive -Force -UpdateProfile -ErrorAction Stop
                $ok = $true
            }
            catch {
                try {
                    Remove-SmbMapping -LocalPath $drive -Force -ErrorAction Stop
                    $ok = $true
                }
                catch {}
            }
        }

        if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
            try {
                Remove-PSDrive -Name $driveName -Force -ErrorAction Stop
                $ok = $true
            }
            catch {}
        }

        if (-not (Test-Path -LiteralPath "$drive\" -ErrorAction SilentlyContinue)) {
            $ok = $true
        }

        Write-LiteDeployEnvironmentLog -Message $(if ($ok) { "Disconnected '$drive'." } else { "Disconnect of '$drive' did not remove an active mapping." }) -Level $(if ($ok) { "INFO" } else { "WARNING" })
        return $ok
    }

    $unc = Format-LiteDeployUNCPath -Path $Target
    if (Get-Command Remove-SmbMapping -ErrorAction SilentlyContinue) {
        try {
            Remove-SmbMapping -RemotePath $unc -Force -ErrorAction Stop
            $ok = $true
        }
        catch {}
    }

    Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object {
        $_.DisplayRoot -and ([string]$_.DisplayRoot).TrimEnd('\') -eq $unc.TrimEnd('\')
    } | ForEach-Object {
        try {
            Remove-PSDrive -Name $_.Name -Force -ErrorAction Stop
            $ok = $true
        }
        catch {}
    }

    Write-LiteDeployEnvironmentLog -Message $(if ($ok) { "Disconnected '$unc'." } else { "Disconnect of '$unc' did not remove an active mapping." }) -Level $(if ($ok) { "INFO" } else { "WARNING" })
    return $ok
}

function Connect-LiteDeployShare {
    <#
    .SYNOPSIS
        Connects a network share with native PowerShell (New-PSDrive / New-SmbMapping).
    .DESCRIPTION
        Credentials are passed only as PSCredential / SecureString to PowerShell cmdlets.
        Passwords are never placed on an external process command line and are never logged.
    #>
    [CmdletBinding(DefaultParameterSetName = "Anonymous")]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$SharePath,

        [ValidatePattern('^[A-Za-z]:?$')]
        [string]$DriveLetter = "",

        [Parameter(ParameterSetName = "Credential", Mandatory = $true)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(ParameterSetName = "Plain", Mandatory = $true)]
        [string]$UserName,

        [Parameter(ParameterSetName = "Plain")]
        [System.Security.SecureString]$Password,

        [switch]$Force,

        [switch]$Persist
    )

    $unc = Format-LiteDeployUNCPath -Path $SharePath
    $drive = if ($DriveLetter) { $DriveLetter.TrimEnd(':').ToUpper() + ":" } else { "" }
    $driveName = if ($drive) { $drive.TrimEnd(':') } else { "" }

    $cred = $null
    if ($PSCmdlet.ParameterSetName -eq "Credential") {
        $cred = $Credential
    }
    elseif ($PSCmdlet.ParameterSetName -eq "Plain") {
        if (-not $Password) {
            throw "Connect-LiteDeployShare -UserName requires -Password as SecureString."
        }
        $cred = New-Object System.Management.Automation.PSCredential ($UserName, $Password)
    }

    $userLabel = if ($cred) { $cred.UserName } else { "" }
    $result = [ordered]@{
        Success     = $false
        SharePath   = $unc
        DriveLetter = $drive
        Method      = ""
        Message     = ""
        Credential  = $cred
    }

    if ($drive -and $Force) {
        $null = Disconnect-LiteDeployShare -Target $drive
    }

    if ($drive -and (Test-Path -LiteralPath "$drive\" -ErrorAction SilentlyContinue)) {
        $result.Success = $true
        $result.Method = "Existing"
        $result.Message = "Share already available at $drive"
        Write-LiteDeployEnvironmentLog -Message "Share '$unc' already connected at $drive." -Level "SUCCESS"
        return [PSCustomObject]$result
    }

    Write-LiteDeployEnvironmentLog -Message "Connecting share '$unc'$(if ($drive) { " as $drive" })$(if ($userLabel) { " (user: $userLabel)" })."

    # Preferred: New-PSDrive with PSCredential (no plaintext password on a process cmdline)
    if ($driveName) {
        try {
            $driveParams = @{
                Name        = $driveName
                PSProvider  = "FileSystem"
                Root        = $unc
                Scope       = "Global"
                ErrorAction = "Stop"
            }
            if ($cred) { $driveParams["Credential"] = $cred }
            if ($Persist) { $driveParams["Persist"] = $true }

            $null = New-PSDrive @driveParams
            if (Test-Path -LiteralPath "$drive\" -ErrorAction SilentlyContinue) {
                $result.Success = $true
                $result.Method = "New-PSDrive"
                $result.Message = "Connected via New-PSDrive"
            }
        }
        catch {
            $result.Message = $_.Exception.Message
        }
    }

    # Fallback: New-SmbMapping with SecureString password (still native PowerShell)
    if (-not $result.Success -and $drive -and (Get-Command New-SmbMapping -ErrorAction SilentlyContinue)) {
        try {
            $mapParams = @{
                LocalPath   = $drive
                RemotePath  = $unc
                ErrorAction = "Stop"
            }
            if ($cred) {
                $mapParams["UserName"] = $cred.UserName
                $mapParams["Password"] = $cred.Password
            }
            $null = New-SmbMapping @mapParams
            if (Test-Path -LiteralPath "$drive\" -ErrorAction SilentlyContinue) {
                $result.Success = $true
                $result.Method = "New-SmbMapping"
                $result.Message = "Connected via New-SmbMapping"
            }
        }
        catch {
            if ([string]::IsNullOrWhiteSpace([string]$result.Message)) {
                $result.Message = $_.Exception.Message
            }
            else {
                $result.Message = "$($result.Message); New-SmbMapping: $($_.Exception.Message)"
            }
        }
    }

    # UNC-only connect (no drive letter): New-PSDrive with a temporary name
    if (-not $result.Success -and -not $driveName) {
        try {
            $tempName = "LD" + ([guid]::NewGuid().ToString("N").Substring(0, 6))
            $driveParams = @{
                Name        = $tempName
                PSProvider  = "FileSystem"
                Root        = $unc
                Scope       = "Global"
                ErrorAction = "Stop"
            }
            if ($cred) { $driveParams["Credential"] = $cred }
            $null = New-PSDrive @driveParams
            $result.Success = $true
            $result.Method = "New-PSDrive"
            $result.DriveLetter = ""
            $result.Message = "Connected UNC via New-PSDrive ($tempName)"
        }
        catch {
            $result.Message = $_.Exception.Message
        }
    }

    if ($result.Success) {
        Write-LiteDeployEnvironmentLog -Message "Connected '$unc' via $($result.Method)." -Level "SUCCESS"
    }
    else {
        if ([string]::IsNullOrWhiteSpace([string]$result.Message)) {
            $result.Message = "Share connect failed."
        }
        Write-LiteDeployEnvironmentLog -Message "Failed to connect '$unc': $($result.Message)" -Level "ERROR"
    }

    return [PSCustomObject]$result
}

#endregion



# ==============================================================================
# STANDALONE EXECUTION
# ==============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    Get-LiteDeployEnvironment
}
