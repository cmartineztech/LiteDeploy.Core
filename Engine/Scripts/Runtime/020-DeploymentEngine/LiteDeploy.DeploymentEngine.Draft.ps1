<#
.SYNOPSIS
    DRAFT — LiteDeploy Deployment Engine stub.

.NOTES
    Scope: verify required files, load BootConfig, run HardwarePreCheck, log inventory,
    then launch WorkflowSelection (BootConfigPath + optional BootConfig + DeploymentSharePath).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [psobject]$BootObject
)

# Enforce strict execution discipline across WinPE runtime
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# Relative path parts for required files — composed with the deployment root
$RequiredFiles = [PSCustomObject]@{
    BootConfig         = "Config\BootConfig.json"
    LogWriter          = "Engine\Scripts\Runtime\LiteDeploy.LogWriter.ps1"
    Hardware           = "Engine\Scripts\Runtime\LiteDeploy.Hardware.ps1"
    HostShell          = "Engine\Scripts\Runtime\LiteDeploy.HostShell.ps1"
    HardwarePreCheck   = "Engine\Scripts\Runtime\LiteDeploy.HardwarePreCheck.ps1"
    WorkflowSelection  = "Engine\Scripts\Runtime\LiteDeploy.WorkflowSelection.ps1"
    DiskPreparation    = "Engine\Scripts\Runtime\LiteDeploy.DiskPreparation.ps1"
    DriverStaging      = "Engine\Scripts\Runtime\LiteDeploy.DriverStaging.ps1"
    
}

# ==============================================================================
# 1. COMPONENT METADATA & VERSION CONTROL
# ==============================================================================

function Get-LiteDeployComponentMetadata {
    <#
    .SYNOPSIS
        Returns standardized component metadata for inventory discovery and version management.
    #>
    return [PSCustomObject]@{
        ComponentId          = "DeploymentEngine"
        Name                 = "LiteDeploy Deployment Engine"
        Version              = "1.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "WinPE"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("LogWriter", "Hardware", "HardwarePreCheck", "WorkflowSelection", "DiskPreparation", "OSInstallation", "Progress")
        Description          = "Runtime pipeline orchestrator: sequences HardwarePreCheck, WorkflowSelection, and deployment execution."
    }
}

# Capture the component metadata
$script:ComponentMetadata = Get-LiteDeployComponentMetadata

function Get-LiteDeployRequiredFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    return [PSCustomObject]@{
        BootConfig        = Join-Path $RootPath $RequiredFiles.BootConfig
        LogWriter         = Join-Path $RootPath $RequiredFiles.LogWriter
        Hardware          = Join-Path $RootPath $RequiredFiles.Hardware
        HostShell         = Join-Path $RootPath $RequiredFiles.HostShell
        HardwarePreCheck  = Join-Path $RootPath $RequiredFiles.HardwarePreCheck
        WorkflowSelection = Join-Path $RootPath $RequiredFiles.WorkflowSelection
    }
}

function Test-LiteDeployRequiredFiles {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Paths
    )

    $missing = [System.Collections.Generic.List[string]]::new()

    foreach ($property in $Paths.PSObject.Properties) {
        $path = [string]$property.Value
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $missing.Add("$($property.Name): $path")
        }
    }

    return [PSCustomObject]@{
        Ok      = ($missing.Count -eq 0)
        Missing = $missing
    }
}

function Write-LiteDeployEngineLog {
    param(
        [string]$Message,
        [ValidateSet("INFO", "SUCCESS", "INIT", "CHECK", "WARNING", "RETRY", "ERROR")]
        [string]$Level = "INFO",
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::White,
        [switch]$NoConsole
    )

    if (Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue) {
        Write-LiteDeployLog -Message $Message -Level $Level -ForegroundColor $ForegroundColor -Component "DeploymentEngine" -NoConsole:$NoConsole
    }
    elseif (-not $NoConsole) {
        # LogWriter not loaded yet (e.g. LogWriter itself missing) — console only
        Write-Host $Message -ForegroundColor $ForegroundColor
    }
}

function Write-LiteDeployEnginePauseNotice {
    Write-Host ""
    Write-LiteDeployEngineLog -Message " [NOTICE]  Deployment halted." -Level "WARNING" -ForegroundColor Yellow
    Write-LiteDeployEngineLog -Message "           To restart this process, run 'startnet' below." -Level "WARNING" -ForegroundColor Yellow
    Write-Host ""
}

function Get-LiteDeployUid {
    <#
    .SYNOPSIS
        Generates a short, collision-resistant deployment UID (e.g., 260806-A3F1).
    #>
    $bytes = [Byte[]]::new(2)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $hex = [System.BitConverter]::ToString($bytes) -replace '-'

    return "$((Get-Date).ToString('yyMMdd'))-$hex"
}

function Test-JSONFormat([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $null = (Get-Content -LiteralPath $Path -Raw) | ConvertFrom-Json -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Write-LiteDeployHardwareInventoryLog {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Inventory
    )

    function Format-InvValue([object]$Value) {
        if ($null -eq $Value) { return $null }
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return $text.Trim()
    }

    Write-LiteDeployEngineLog -Message " [INFO]    ---------- Computer Information ----------" -Level "INFO" -ForegroundColor Cyan

    $rows = [ordered]@{
        "Make"           = (Format-InvValue $Inventory.Vendor)
        "Model"          = (Format-InvValue $Inventory.Model)
        "SKU"            = (Format-InvValue $Inventory.Sku)
        "Serial Number"  = (Format-InvValue $Inventory.SerialNumber)
        "UUID"           = (Format-InvValue $Inventory.UUID)
        "Asset Tag"      = (Format-InvValue $Inventory.AssetTag)
        "Chassis"        = (Format-InvValue $Inventory.Chassis)
        "IsVM"           = (Format-InvValue $Inventory.IsVM)
        "Architecture"   = (Format-InvValue $Inventory.Architecture)
        "Memory"         = $(if ($null -ne $Inventory.MemoryGB -and [string]$Inventory.MemoryGB -ne "") { "$($Inventory.MemoryGB) GB" } else { $null })
        "Processor"      = (Format-InvValue $Inventory.ProcessorName)
        "Firmware"       = (Format-InvValue $Inventory.FirmwareType)
        "BIOS Version"   = (Format-InvValue $Inventory.BiosVersion)
        "BIOS Date"      = (Format-InvValue $Inventory.BiosReleaseDate)
        "Secure Boot"    = (Format-InvValue $Inventory.SecureBootDisplay)
        "TPM"            = $(
            $ver = Format-InvValue $Inventory.TpmVersion
            $state = Format-InvValue $Inventory.TpmState
            if ($ver -and $state) { "$ver ($state)" }
            elseif ($ver) { $ver }
            elseif ($state) { $state }
            else { $null }
        )
        "Network Adapter"= $(
            $nic = Format-InvValue $Inventory.PrimaryNicName
            if (-not $nic) { $nic = Format-InvValue $Inventory.NetworkAdapter }
            $nic
        )
        "MAC Address"    = (Format-InvValue $Inventory.PrimaryMacAddress)
        "IPv4"           = $(
            $cidr = Format-InvValue $Inventory.IPv4Cidr
            if ($cidr) {
                $cidr
            }
            else {
                $ip = Format-InvValue $Inventory.IPAddress
                $prefix = $null
                if ($Inventory.PSObject.Properties["IPv4PrefixLength"] -and $null -ne $Inventory.IPv4PrefixLength) {
                    $prefix = [int]$Inventory.IPv4PrefixLength
                }
                if ($ip -and $prefix -gt 0 -and $prefix -le 32) { "$ip/$prefix" } else { $ip }
            }
        )
        "IPv6"           = (Format-InvValue $Inventory.IPv6Address)
        "DNS"            = $(
            $dnsList = @()
            if ($Inventory.PSObject.Properties["DnsServers"] -and $Inventory.DnsServers) {
                $dnsList = @($Inventory.DnsServers | ForEach-Object { Format-InvValue $_ } | Where-Object { $_ })
            }
            if ($dnsList.Count -gt 0) { ($dnsList -join ", ") } else { $null }
        )
    }

    foreach ($label in $rows.Keys) {
        $value = $rows[$label]
        if (-not $value) { continue }
        Write-LiteDeployEngineLog -Message (" [INFO]    {0,-14}: {1}" -f $label, $value) -Level "INFO"
    }

    # One line per disk (Disk 0, Disk 1, ...) instead of a plural total.
    $diskList = @()
    if ($Inventory.PSObject.Properties["HardDrives"] -and $Inventory.HardDrives) {
        $diskList = @($Inventory.HardDrives)
    }
    elseif ($Inventory.PSObject.Properties["Disks"] -and $Inventory.Disks) {
        $diskList = @($Inventory.Disks)
    }

    if ($diskList.Count -gt 0) {
        foreach ($disk in $diskList) {
            $number = $null
            if ($disk.PSObject.Properties["Number"]) { $number = $disk.Number }
            $model = Format-InvValue $(if ($disk.PSObject.Properties["Model"]) { $disk.Model } else { $null })
            $sizeGb = $null
            if ($disk.PSObject.Properties["SizeGB"] -and $null -ne $disk.SizeGB -and "$($disk.SizeGB)" -ne "") {
                $sizeGb = $disk.SizeGB
            }
            elseif ($disk.PSObject.Properties["Size"] -and $null -ne $disk.Size -and "$($disk.Size)" -ne "") {
                $sizeGb = $disk.Size
            }

            $detailParts = [System.Collections.Generic.List[string]]::new()
            if ($model) { $detailParts.Add($model) }
            if ($null -ne $sizeGb -and "$sizeGb" -ne "") { $detailParts.Add("$sizeGb GB") }
            $detail = if ($detailParts.Count -gt 0) { ($detailParts -join " | ") } else { "Present" }

            $label = if ($null -ne $number -and "$number" -ne "") { "Disk $number" } else { "Disk" }
            Write-LiteDeployEngineLog -Message (" [INFO]    {0,-14}: {1}" -f $label, $detail) -Level "INFO"
        }
    }

    Write-LiteDeployEngineLog -Message " [INFO]    ----------------------------------------------" -Level "INFO" -ForegroundColor Cyan
}

# Main Execution
# Draft scope: resolve source → load Hardware → WinPE gate → PreCheck → WorkflowSelection.

$paths = $null
$root = $null

if ($BootObject.DeploymentType -eq "Network") {
    $root = $BootObject.DriveLetter.TrimEnd('\')
    $paths = Get-LiteDeployRequiredFiles -RootPath $root
}
elseif ($BootObject.DeploymentType -eq "Media") {
    $root = Join-Path $BootObject.DriveLetter.TrimEnd('\') $BootObject.LocalRootName
    $paths = Get-LiteDeployRequiredFiles -RootPath $root
}
else {
    Write-LiteDeployEngineLog -Message " [ERROR]   Unsupported DeploymentType '$($BootObject.DeploymentType)'. Expected 'Network' or 'Media'." -Level "ERROR" -ForegroundColor Red
    Write-LiteDeployEnginePauseNotice
    return
}

# Load LogWriter first when present so required-file failures are CMTrace-recorded.
# Keep engine metadata in $script:ComponentMetadata; import may overwrite Get-LiteDeployComponentMetadata.
if (Test-Path -LiteralPath $paths.LogWriter -PathType Leaf) {
    Import-Module -Name $paths.LogWriter -Force
}

$Host.UI.RawUI.WindowTitle = "LiteDeploy v$($script:ComponentMetadata.Version)"

Write-LiteDeployEngineLog -Message ""
Write-LiteDeployEngineLog -Message "==========================================================================" -Level "INFO" -ForegroundColor Cyan
Write-LiteDeployEngineLog -Message "            $($script:ComponentMetadata.Name) Component v$($script:ComponentMetadata.Version)            " -Level "INFO" -ForegroundColor White
Write-LiteDeployEngineLog -Message "==========================================================================" -Level "INFO" -ForegroundColor Cyan

$requiredCheck = Test-LiteDeployRequiredFiles -Paths $paths
if (-not $requiredCheck.Ok) {
    Write-LiteDeployEngineLog -Message " [ERROR]   Required component missing:" -Level "ERROR" -ForegroundColor Red
    foreach ($item in $requiredCheck.Missing) {
        $name, $path = $item -split ': ', 2
        Write-LiteDeployEngineLog -Message " [MISSING] $name -> $path" -Level "ERROR" -ForegroundColor Red
    }
    Write-LiteDeployEnginePauseNotice
    return
}

Import-Module -Name $paths.Hardware -Force
# WinPE gate uses live Hardware check only. BootObject.IsWinPE is ignored for the decision;
# if that property already exists, refresh it with the Hardware result for downstream readers.
$isWinPE = Get-HardwareIsWinPE
if ($BootObject.PSObject.Properties['IsWinPE']) {
    $BootObject.IsWinPE = $isWinPE
}
if (-not $isWinPE) {
    Write-LiteDeployEngineLog -Message " [ERROR]   DeploymentEngine requires WinPE (Get-HardwareIsWinPE returned false)." -Level "ERROR" -ForegroundColor Red
    Write-LiteDeployEnginePauseNotice
    return
}

if (-not (Test-JSONFormat -Path $paths.BootConfig)) {
    Write-LiteDeployEngineLog -Message " [ERROR]   BootConfig.json failed to load from '$($paths.BootConfig)'." -Level "ERROR" -ForegroundColor Red
    Write-LiteDeployEnginePauseNotice
    return
}

$BootConfig = Get-Content -LiteralPath $paths.BootConfig -Raw | ConvertFrom-Json -ErrorAction Stop

$envName = $null
$appVersion = $null
if ($BootConfig.PSObject.Properties["Metadata"] -and $BootConfig.Metadata) {
    if ($BootConfig.Metadata.PSObject.Properties["Environment"] -and $BootConfig.Metadata.Environment) {
        $envName = [string]$BootConfig.Metadata.Environment
    }
    if ($BootConfig.Metadata.PSObject.Properties["Version"] -and $BootConfig.Metadata.Version) {
        $appVersion = [string]$BootConfig.Metadata.Version
    }
}
$environmentLine = $null
if ($envName -and $appVersion) { $environmentLine = "$envName | v$appVersion" }
elseif ($envName) { $environmentLine = $envName }
elseif ($appVersion) { $environmentLine = "v$appVersion" }

Write-LiteDeployEngineLog -Message (" [INIT]    {0,-13}: {1}" -f "Deployment Mode", $BootConfig.Deployment.Type) -Level "INIT"
Write-LiteDeployEngineLog -Message (" [INIT]    {0,-13}: {1}" -f "Source", $root) -Level "INIT"
Write-LiteDeployEngineLog -Message (" [INIT]    {0,-13}: {1}" -f "BootConfig", $paths.BootConfig) -Level "INIT"
if ($environmentLine) {
    Write-LiteDeployEngineLog -Message (" [INIT]    {0,-13}: {1}" -f "Environment", $environmentLine) -Level "INIT"
}
Write-LiteDeployEngineLog -Message ""

Write-LiteDeployEngineLog -Message " [SUCCESS] Required components verified." -Level "SUCCESS"
Write-LiteDeployEngineLog -Message " [SUCCESS] LiteDeploy Engine loaded." -Level "SUCCESS"
Write-LiteDeployEngineLog -Message ""

# Minimize console
Import-Module -Name $paths.HostShell -Force
Write-LiteDeployEngineLog -Message " [INFO]    Launching HardwarePreCheck..." -Level "INFO" -ForegroundColor Cyan
Set-HostShellWindow -Action Minimize
$preCheckResult = & $paths.HardwarePreCheck -BootConfigPath $paths.BootConfig -BootConfig $BootConfig
if (-not $preCheckResult -or -not $preCheckResult.Passed) {
    Write-LiteDeployEngineLog -Message " [WARNING] HardwarePreCheck did not pass or was cancelled." -Level "WARNING"
    Write-LiteDeployEngineLog -Message " [INFO]    Deployment halted. No disk changes were made." -Level "INFO"
    Set-HostShellWindow -Action Restore
    Write-LiteDeployEnginePauseNotice
    return
}

$script:HardwareInventory = $preCheckResult.Inventory
Write-LiteDeployEngineLog -Message " [SUCCESS] Hardware PreCheck Completed." -Level "SUCCESS"
Write-LiteDeployEngineLog -Message ""
if ($script:HardwareInventory) {
    Write-LiteDeployHardwareInventoryLog -Inventory $script:HardwareInventory
}
Write-LiteDeployEngineLog -Message ""

Write-LiteDeployEngineLog -Message " [INFO]    Launching WorkflowSelection..." -Level "INFO" -ForegroundColor Cyan
$DeployUid = Get-LiteDeployUid
Write-LiteDeployEngineLog -Message " [INFO]    Deployment UID: $DeployUid" -Level "INFO" -ForegroundColor Yellow
$workflowResult = & $paths.WorkflowSelection -BootConfigPath $paths.BootConfig -BootConfig $BootConfig -DeploymentSharePath $root -DeploymentUid $DeployUid
if (-not $workflowResult -or -not $workflowResult.Passed) {
    $status = if ($workflowResult -and $workflowResult.PSObject.Properties["Status"]) { [string]$workflowResult.Status } else { "Failed" }
    Write-LiteDeployEngineLog -Message " [WARNING] WorkflowSelection did not pass ($status)." -Level "WARNING"
    Write-LiteDeployEngineLog -Message " [INFO]    Deployment halted. No disk changes were made." -Level "INFO"
    Set-HostShellWindow -Action Restore
    Write-LiteDeployEnginePauseNotice
    return
}

$script:WorkflowSelection = $workflowResult
$wfName = if ($workflowResult.WorkflowName) { [string]$workflowResult.WorkflowName } else { "-" }
$computerName = if ($workflowResult.ComputerName) { [string]$workflowResult.ComputerName } else { "-" }
$diskIndex = if ($null -ne $workflowResult.TargetDiskIndex -and "$($workflowResult.TargetDiskIndex)" -ne "") {
    [string]$workflowResult.TargetDiskIndex
} else { "-" }
$diskModel = if ($workflowResult.TargetDiskModel) { [string]$workflowResult.TargetDiskModel } else { "" }
$diskLabel = if ($diskModel) { "Disk $diskIndex ($diskModel)" } else { "Disk $diskIndex" }
$drivers = if ($workflowResult.DriverFolderPath) {
    [string]$workflowResult.DriverFolderPath
} else {
    "Standard OS In-Box Drivers (Windows Default)"
}

Write-LiteDeployEngineLog -Message " [SUCCESS] WorkflowSelection confirmed." -Level "SUCCESS"
Write-LiteDeployEngineLog -Message (" [INFO]    Workflow: {0}" -f $wfName) -Level "INFO"
Write-LiteDeployEngineLog -Message (" [INFO]    Computer: {0} | {1}" -f $computerName, $diskLabel) -Level "INFO"
Write-LiteDeployEngineLog -Message (" [INFO]    Drivers: {0}" -f $drivers) -Level "INFO"
Write-LiteDeployEngineLog -Message ""
Write-LiteDeployEngineLog -Message " [SUCCESS] Engine Draft phase complete (PreCheck + WorkflowSelection)." -Level "SUCCESS"
