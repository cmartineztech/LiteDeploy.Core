<#
.SYNOPSIS
    LiteDeploy WinPE Initialization & BootConfig Discovery Engine.

.DESCRIPTION
    Discovers BootConfig.json using a 3-priority hierarchy, performs network pre-validations,
    prompts for user credentials via native Get-Credential, maps deployment share Z:\ persistently,
    and launches LiteDeploy.DeploymentEngine.ps1 with the in-memory BootObject.

.NOTES
    Compatible with Set-StrictMode 2.0 and WinPE 5.1/10/11.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ExplicitConfigPath = "",

    [Parameter(Mandatory = $false)]
    [switch]$MountShare,

    [Parameter(Mandatory = $false)]
    [switch]$ShowGuiError
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ==============================================================================
# 1. HELPERS & GUI DIALOGS
# ==============================================================================

function Write-LiteDeployLog {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::White,
        [string]$Component = "BootInitilizer",
        [switch]$NoConsole
    )
    if ($Message -and -not $NoConsole) {
        Write-Host $Message -ForegroundColor $ForegroundColor
    }
    try {
        $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "X:" }
        $logDir = Join-Path $sysDrive "~LiteDeploy\WorkLogs"
        if (-not (Test-Path -LiteralPath $logDir)) {
            $null = New-Item -Path $logDir -ItemType Directory -Force -ErrorAction SilentlyContinue
        }
        $logFile = Join-Path $logDir "LiteDeploy.Execution.log"
        $cleanMsg = $Message.Trim()
        if (-not [string]::IsNullOrWhiteSpace($cleanMsg)) {
            $now = Get-Date
            $timeStr = $now.ToString("HH:mm:ss.fff") + "+000"
            $dateStr = $now.ToString("MM-dd-yyyy")
            $typeCode = switch ($Level.ToUpper()) {
                "ERROR" { "3" }
                "WARNING" { "2" }
                "RETRY" { "2" }
                default { "1" }
            }
            # Official Microsoft CMTrace.exe XML Log Structure
            $logEntry = "<![LOG[$cleanMsg]LOG]!><time=""$timeStr"" date=""$dateStr"" component=""$Component"" context="""" type=""$typeCode"" thread=""1"" file=""LiteDeploy.BootInitilizer.ps1"">"
            Add-Content -Path $logFile -Value $logEntry -ErrorAction SilentlyContinue

            # Modern Newline-Delimited JSON (NDJSON) Log Structure
            $jsonFile = Join-Path $logDir "LiteDeploy.Execution.json"
            $isoTimestamp = $now.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            $jsonRecord = [ordered]@{
                timestamp = $isoTimestamp
                level     = $Level.ToUpper()
                type      = [int]$typeCode
                component = $Component
                message   = $cleanMsg
                file      = "LiteDeploy.BootInitilizer.ps1"
            }
            $jsonEntry = $jsonRecord | ConvertTo-Json -Compress
            Add-Content -Path $jsonFile -Value $jsonEntry -ErrorAction SilentlyContinue
        }
    }
    catch {}
}

function Format-LiteDeployUncPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $clean = $Path -replace '/', '\'
    if ($clean -notlike '\\*') {
        $clean = "\\$($clean.TrimStart('\'))"
    }
    return $clean.TrimEnd('\')
}

function Show-LiteDeployGuiError {
    param(
        [string]$Message,
        [string]$Title = "LiteDeploy Error",
        [bool]$IsRetryDialog = $false
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $buttons = if ($IsRetryDialog) { [System.Windows.Forms.MessageBoxButtons]::RetryCancel } else { [System.Windows.Forms.MessageBoxButtons]::OK }
        $result = [System.Windows.Forms.MessageBox]::Show($Message, $Title, $buttons, [System.Windows.Forms.MessageBoxIcon]::Error)
        return ($result -eq [System.Windows.Forms.DialogResult]::Retry)
    }
    catch {
        Write-Warning "$($Title): $($Message)"
        return $true
    }
}

function Resolve-LiteDeployEnginePath {
    param([string]$RootPath)
    # Prefer the deployment engine orchestrator. PreCheck is invoked by the engine, not BootInitializer.
    $candidates = [System.Collections.Generic.List[string]]::new()

    # Production: BootInitializer and DeploymentEngine are siblings under Engine\Scripts.
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $candidates.Add((Join-Path $PSScriptRoot "LiteDeploy.DeploymentEngine.ps1"))
        # Development repository layout (numbered component folders).
        $candidates.Add((Join-Path $PSScriptRoot "..\08-DeploymentEngine\LiteDeploy.DeploymentEngine.ps1"))
    }

    if (-not [string]::IsNullOrWhiteSpace($RootPath)) {
        $candidates.Add((Join-Path $RootPath "Engine\Scripts\LiteDeploy.DeploymentEngine.ps1"))
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate -ErrorAction SilentlyContinue).Path
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($RootPath)) {
        return (Join-Path $RootPath "Engine\Scripts\LiteDeploy.DeploymentEngine.ps1")
    }
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return (Join-Path $PSScriptRoot "LiteDeploy.DeploymentEngine.ps1")
    }
    return ""
}

function Get-LiteDeployRuntimeConfig {
    param(
        [string]$RootPath,
        [string]$LocalRootName = "~LiteDeploy"
    )

    if ([string]::IsNullOrWhiteSpace($RootPath)) { return $null }

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($LocalRootName)) {
        $candidates.Add((Join-Path $RootPath "$LocalRootName\Config\BootConfig.json"))
    }
    $candidates.Add((Join-Path $RootPath "Config\BootConfig.json"))
    $candidates.Add((Join-Path $RootPath "*\Config\BootConfig.json"))

    foreach ($candidate in $candidates) {
        $resolved = Resolve-Path -Path $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $resolved -or -not (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) { continue }

        try {
            $runtimeConfig = Get-Content -LiteralPath $resolved.Path -Raw -ErrorAction Stop |
                ConvertFrom-Json -ErrorAction Stop
            return [PSCustomObject]@{
                Path   = $resolved.Path
                Config = $runtimeConfig
            }
        }
        catch {
            throw "Runtime BootConfig.json is invalid at '$($resolved.Path)': $($_.Exception.Message)"
        }
    }

    return $null
}

if (-not (Test-Path Variable:global:LiteDeployCredential)) {
    $global:LiteDeployCredential = $null
}

$isWinPE = Test-Path -Path "HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT" -ErrorAction SilentlyContinue

if ($isWinPE) {
    # Activate High Performance power plan
    try { powercfg.exe /setactive '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' 2>$null } catch {}

    # Initialize WinPE components and network stack
    try { wpeinit.exe 2>$null } catch {}
    try { wpeutil.exe InitializeNetwork 2>$null } catch {}
}

# Set the title of the console window while LiteDeploy is loading.
$Host.UI.RawUI.WindowTitle = "LiteDeploy Loading..."
Write-LiteDeployLog "LiteDeploy Loading..." -Level "INFO" -ForegroundColor DarkGray
$Host.UI.RawUI.WindowTitle = "LiteDeploy v1.0"
Clear-Host

Write-LiteDeployLog "==========================================================================" -Level "INFO" -ForegroundColor Cyan
Write-LiteDeployLog "                LiteDeploy WinPE Initialization Engine v1.0               " -Level "INFO" -ForegroundColor White
Write-LiteDeployLog "==========================================================================" -Level "INFO" -ForegroundColor Cyan
Write-LiteDeployLog "" -Level "INFO"
if ($isWinPE) {
    Write-LiteDeployLog " [INIT]    WinPE Environment & High Performance Power Plan initialized." -Level "INIT" -ForegroundColor DarkGray
}

# ==============================================================================
# 2. NETWORK VALIDATIONS
# ==============================================================================

function Test-LiteDeployNetworkHardware {
    try {
        $nicName = ""
        $isLinkUp = $false

        if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
            $nics = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne "Disabled" }
            if ($nics) {
                # Prioritize an adapter that is actively connected
                $connectedNic = $nics | Where-Object { $_.MediaConnectionState -eq "Connected" -or $_.Status -eq "Up" } | Select-Object -First 1
                $targetNic = if ($connectedNic) { $connectedNic } else { $nics | Select-Object -First 1 }
                
                $nicName = if ($targetNic.InterfaceDescription) { $targetNic.InterfaceDescription.Trim() } else { $targetNic.Name }
                if ($connectedNic) { $isLinkUp = $true }
            }
        }

        if ([string]::IsNullOrWhiteSpace($nicName)) {
            try {
                $allNics = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | 
                Where-Object { $_.NetworkInterfaceType -ne 'Loopback' }
                if ($allNics) {
                    $connectedNic = $allNics | Where-Object { $_.OperationalStatus -eq 'Up' } | Select-Object -First 1
                    $targetNic = if ($connectedNic) { $connectedNic } else { $allNics | Select-Object -First 1 }
                    
                    $nicName = $targetNic.Description.Trim()
                    if ($connectedNic) { $isLinkUp = $true }
                }
            }
            catch {}
        }
        else {
            if (-not $isLinkUp) {
                try {
                    $upNic = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | 
                    Where-Object { $_.NetworkInterfaceType -ne 'Loopback' -and $_.OperationalStatus -eq 'Up' }
                    if ($upNic) { $isLinkUp = $true }
                }
                catch {}
            }
        }

        return [PSCustomObject]@{
            AdapterFound    = (-not [string]::IsNullOrWhiteSpace($nicName))
            AdapterName     = $nicName
            IsLinkConnected = $isLinkUp
        }
    }
    catch {
        return [PSCustomObject]@{ AdapterFound = $false; AdapterName = ""; IsLinkConnected = $false }
    }
}

function Test-LiteDeployIPAddress {
    param([int]$TimeoutSeconds = 30)
    try {
        $ipAddress = ""; $ipv4Address = ""; $ipv6Address = ""
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $lastReport = -1

        while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            try {
                $nics = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object { $_.NetworkInterfaceType -ne 'Loopback' -and $_.OperationalStatus -eq 'Up' }

                foreach ($nic in $nics) {
                    foreach ($addr in $nic.GetIPProperties().UnicastAddresses) {
                        $family = $addr.Address.AddressFamily
                        $ipStr = $addr.Address.IPAddressToString
                        if ($family -eq 'InterNetwork' -and $ipStr -notlike "169.254.*" -and $ipStr -ne "127.0.0.1") {
                            if ([string]::IsNullOrWhiteSpace($ipv4Address)) { $ipv4Address = $ipStr }
                        }
                        elseif ($family -eq 'InterNetworkV6' -and $ipStr -ne "::1" -and $ipStr -notlike "fe80:*") {
                            if ([string]::IsNullOrWhiteSpace($ipv6Address)) { $ipv6Address = $ipStr }
                        }
                    }
                }
                $ipAddress = if ($ipv4Address) { $ipv4Address } else { $ipv6Address }
            }
            catch {}
            if ($ipAddress) { break }

            $elapsedSec = [math]::Floor($timer.Elapsed.TotalSeconds)
            if ($elapsedSec -gt $lastReport -and $elapsedSec % 3 -eq 0 -and $elapsedSec -gt 0) {
                Write-Host "           Waiting for DHCP IP assignment ($($elapsedSec)s / $($TimeoutSeconds)s)..." -ForegroundColor DarkGray
                $lastReport = $elapsedSec
            }

            Start-Sleep -Milliseconds 250
        }
        return [PSCustomObject]@{ IPAddress = $ipAddress; IPv4Address = $ipv4Address; IPv6Address = $ipv6Address; HasValidIP = [bool]$ipAddress }
    }
    catch {
        return [PSCustomObject]@{ IPAddress = ""; IPv4Address = ""; IPv6Address = ""; HasValidIP = $false }
    }
}

function Test-LiteDeployDeploymentShare {
    param([string]$SharePath, [int]$TimeoutMs = 5000)
    try {
        if ([string]::IsNullOrWhiteSpace($SharePath)) { return [PSCustomObject]@{ Reachable = $false; Server = "" } }
        $cleanPath = Format-LiteDeployUncPath -Path $SharePath
        $server = $cleanPath.TrimStart('\').Split('\')[0]
        if ([string]::IsNullOrWhiteSpace($server)) { return [PSCustomObject]@{ Reachable = $false; Server = "" } }

        $smbOK = $false
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $connect = $tcp.BeginConnect($server, 445, $null, $null)
            if ($connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
                $tcp.EndConnect($connect)
                $smbOK = $true
            }
            else { $tcp.Close() }
        }
        catch {} finally { $tcp.Dispose() }

        # Secondary fallback: If socket check timed out during WinPE DNS lookup, test UNC path directly
        if (-not $smbOK) {
            try {
                if (Test-Path -Path $cleanPath -ErrorAction SilentlyContinue) {
                    $smbOK = $true
                }
            }
            catch {}
        }

        return [PSCustomObject]@{ Reachable = $smbOK; Server = $server }
    }
    catch { return [PSCustomObject]@{ Reachable = $false; Server = "" } }
}

# ==============================================================================
# 3. SHARE MOUNTING
# ==============================================================================

function Connect-LiteDeployDeploymentShare {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NetworkPath,
        [string]$DriveLetter = "Z:",
        [switch]$ShowGuiError
    )

    $isWinPE = Test-Path -Path "HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT" -ErrorAction SilentlyContinue
    $driveName = $DriveLetter.TrimEnd(':', '\')
    $cleanDrive = "$($driveName):"

    # Purge stale net use mappings or orphaned sessions prior to drive verification
    if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
        # Test if the existing drive connection is actually responsive
        $driveResponsive = Test-Path -Path "$($cleanDrive)\" -ErrorAction SilentlyContinue
        if (-not $driveResponsive) {
            Write-Warning "Stale or unmapped drive detected on $($cleanDrive). Purging existing SMB session..."
            try {
                if (Get-Command Remove-SmbMapping -ErrorAction SilentlyContinue) {
                    Remove-SmbMapping -LocalPath $cleanDrive -Force -UpdateProfile -ErrorAction SilentlyContinue | Out-Null
                }
            }
            catch {}
            Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    # Fast-Path: Check if drive Z:\ is already connected
    if (Test-Path -Path "$($cleanDrive)\" -ErrorAction SilentlyContinue) {
        Write-LiteDeployLog "Deployment share is already connected to $($cleanDrive)\ ($NetworkPath)." -Level "SUCCESS" -ForegroundColor Green
        $existingCred = if (Test-Path Variable:global:LiteDeployCredential) { $global:LiteDeployCredential } else { $null }
        return [PSCustomObject]@{ Mounted = $true; DriveLetter = $cleanDrive; NetworkPath = $NetworkPath; Credential = $existingCred }
    }

    try {
        if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
            Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
    catch {}

    $mounted = $false
    $userCred = $null

    while (-not $mounted) {
        try {
            $userCred = Get-Credential -Message "Enter credentials to connect the deployment share.`n$($NetworkPath)" -ErrorAction Stop
        }
        catch {
            Write-LiteDeployLog "Deployment share authentication cancelled by user." -Level "WARNING" -ForegroundColor Yellow
            Write-Host ""
            Write-Host " [NOTICE]  Deployment initialization paused." -ForegroundColor Yellow
            Write-Host "           To restart this process, run 'startnet' below." -ForegroundColor Yellow
            Write-Host ""
            break
        }
        if ($null -eq $userCred) { break }

        # Native PowerShell persistent global drive mapping
        try {
            New-PSDrive -Name $driveName -PSProvider FileSystem -Root $NetworkPath -Credential $userCred -Persist -Scope Global -ErrorAction Stop | Out-Null
            $mounted = $true
        }
        catch {
            try {
                if (Get-Command New-SmbMapping -ErrorAction SilentlyContinue) {
                    New-SmbMapping -LocalPath $cleanDrive -RemotePath $NetworkPath -Credential $userCred -ErrorAction Stop | Out-Null
                    $mounted = $true
                }
            }
            catch {}
        }

        if ($mounted -or (Test-Path -Path "$($cleanDrive)\")) {
            $mounted = $true
            $global:LiteDeployCredential = $userCred
            $global:LiteDeployShareMounted = $true
            Write-LiteDeployLog " [SUCCESS] Deployment share connected successfully to $($cleanDrive)\ ($NetworkPath)." -Level "SUCCESS" -ForegroundColor Green
            break
        }

        Write-LiteDeployLog " [ERROR]   Authentication failed for user '$($userCred.UserName)' on share '$($NetworkPath)'." -Level "ERROR" -ForegroundColor Red
        $shouldRetry = $true
        if (-not $shouldRetry) { break }

        if ($isWinPE) {
            try { wpeutil.exe InitializeNetwork 2>$null } catch {}
        }
        try { [System.Console]::Out.Flush() } catch {}
        Write-LiteDeployLog " [RETRY]   Re-prompting for Credentials for $($NetworkPath)..." -Level "RETRY" -ForegroundColor DarkYellow
    }

    return [PSCustomObject]@{ Mounted = $mounted; DriveLetter = $cleanDrive; NetworkPath = $NetworkPath; Credential = $userCred }
}

# ==============================================================================
# 4. MAIN CONFIGURATION DISCOVERY ENGINE
# ==============================================================================

function Get-LiteDeployBootConfig {
    param(
        [string]$ConfigPath = "",
        [switch]$ShowGuiError,
        [switch]$MountShare
    )

    $isWinPE = Test-Path -Path "HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT" -ErrorAction SilentlyContinue

    # Discover BootConfig.json
    Write-Host ""
    Write-LiteDeployLog " [CHECK]   Searching for BootConfig.json..." -Level "INFO" -ForegroundColor Cyan
    $ramDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "X:" }
    $ramConfigPaths = @()
    if ($ConfigPath) { $ramConfigPaths += $ConfigPath }
    if ($isWinPE) {
        $ramConfigPaths += "$ramDrive\~LiteDeploy\Config\BootConfig.json"
        $ramConfigPaths += "$ramDrive\*\Config\BootConfig.json"
        $ramConfigPaths += "$ramDrive\Windows\System32\BootConfig.json"
    }

    $FoundConfigPath = $null
    foreach ($path in $ramConfigPaths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        try {
            $resolved = Resolve-Path -Path $path -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($resolved -and (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) {
                $FoundConfigPath = $resolved.Path
                break
            }
        }
        catch {}
    }

    # Only enumerate external USB/CD drives if config was NOT found in RAM or explicit path
    if (-not $FoundConfigPath) {
        try {
            if (Get-Command Get-Volume -ErrorAction SilentlyContinue) {
                $sysDrive = $ramDrive.TrimEnd(':')
                $externalVolumes = Get-Volume -ErrorAction SilentlyContinue | Where-Object {
                    $vol = $_
                    if (-not $vol.DriveLetter -or $vol.DriveLetter -eq $sysDrive) { return $false }
                    $isRemovable = $vol.DriveType -in @('Removable', 'CD-ROM', 'CDROM')
                    $isUsbBus = $false
                    if ($vol.PSObject.Properties['DiskNumber'] -and $vol.DiskNumber -ne $null) {
                        $disk = Get-Disk -Number $vol.DiskNumber -ErrorAction SilentlyContinue
                        if ($disk -and $disk.PSObject.Properties['BusType'] -and $disk.BusType -in @('USB', '1394', 'SD')) {
                            $isUsbBus = $true
                        }
                    }
                    return ($isRemovable -or $isUsbBus)
                }
                foreach ($vol in $externalVolumes) {
                    $r = "$($vol.DriveLetter):"
                    $extCandidate = Resolve-Path -Path "$r\~LiteDeploy\Config\BootConfig.json", "$r\*\Config\BootConfig.json" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($extCandidate -and (Test-Path -LiteralPath $extCandidate.Path -PathType Leaf)) {
                        $FoundConfigPath = $extCandidate.Path
                        break
                    }
                }
            }
        }
        catch {}
    }

    $appName = "LiteDeploy"; $appVersion = "1.0"; $envName = ""; $deploymentType = $null; $networkPath = $null; $localRootName = "~LiteDeploy"; $configFound = $false; $cfg = $null

    if ($FoundConfigPath) {
        Write-LiteDeployLog " [SUCCESS] BootConfig.json discovered at '$($FoundConfigPath)'." -Level "SUCCESS" -ForegroundColor Green
        try {
            $jsonContent = Get-Content -LiteralPath $FoundConfigPath -Raw -ErrorAction SilentlyContinue
            if ($jsonContent) {
                $cfg = $jsonContent | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($cfg) {
                    $configFound = $true
                    if ($cfg.Metadata) {
                        if ($cfg.Metadata.Name) { $appName = $cfg.Metadata.Name }
                        if ($cfg.Metadata.Environment) { $envName = $cfg.Metadata.Environment }
                        if ($cfg.Metadata.Version) { $appVersion = $cfg.Metadata.Version }
                    }
                    if ($cfg.Deployment) {
                        if ($cfg.Deployment.Type) { $deploymentType = $cfg.Deployment.Type }
                        if ($cfg.Deployment.NetworkPath) { $networkPath = Format-LiteDeployUncPath -Path $cfg.Deployment.NetworkPath }
                        if ($cfg.Deployment.LocalRootName) { $localRootName = $cfg.Deployment.LocalRootName }
                    }
                }
            }
        }
        catch {}
    }

    if (-not $configFound) {
        Write-LiteDeployLog " [WARNING] BootConfig.json file was not found." -Level "WARNING" -ForegroundColor Yellow
        if ($isWinPE -or $ShowGuiError) {
            Show-LiteDeployGuiError -Message "BootConfig.json was not found in WinPE RAM ($ramDrive\), external media, or script path.`n`Please rebuild the boot image." -Title "LiteDeploy - Config Missing"
        }
    }

    # Resolution & Validations
    $netAdapterFound = $true; $netAdapterName = ""; $ipAddress = ""; $ipv4Address = ""; $ipv6Address = ""
    $serverReachable = $true; $serverName = ""; $shareMounted = $false; $mountedDrive = ""; $mediaDriveLetter = ""; $engineScriptPath = ""; $userCred = $null

    if ($deploymentType -eq "Media") {
        if ($FoundConfigPath) {
            $mediaDriveLetter = Split-Path -Qualifier $FoundConfigPath
            if ([string]::IsNullOrWhiteSpace($mediaDriveLetter)) { $mediaDriveLetter = $ramDrive }
            $mountedDrive = $mediaDriveLetter
            Write-LiteDeployLog " [INFO]    Deployment Mode: Media (Offline Drive: $($mediaDriveLetter))." -Level "INFO" -ForegroundColor DarkCyan
            $engineScriptPath = Resolve-LiteDeployEnginePath -RootPath $mediaDriveLetter
        }
    }
    elseif ($deploymentType -eq "Network") {
        if ([string]::IsNullOrWhiteSpace($networkPath)) {
            $serverReachable = $false
            Write-LiteDeployLog " [WARNING] Misconfigured Network Deployment: NetworkPath is missing in BootConfig.json." -Level "WARNING" -ForegroundColor Yellow
            if ($isWinPE -or $ShowGuiError) {
                Show-LiteDeployGuiError -Message "NetworkPath is missing in BootConfig.json.`n`Please update BootConfig.json with a valid network share path." -Title "LiteDeploy - Misconfigured NetworkPath"
            }
        }
        else {
            # Network Deployment Mode: Check NIC Hardware & IP Assignment (Interactive Retry Loops)
            if ($networkPath) {
                Write-LiteDeployLog " [INFO]    Deployment Mode: Network (Share: $($networkPath))." -Level "INFO" -ForegroundColor DarkCyan
            }
            $netAdapterFound = $false
            $netAdapterName = ""
            $isLinkConnected = $false

            # Step 1: Check NIC Hardware & Driver
            Write-Host ""
            Write-LiteDeployLog " [CHECK]   Scanning Network Adapters..." -Level "INFO" -ForegroundColor Cyan
            while (-not $netAdapterFound) {
                $netHw = Test-LiteDeployNetworkHardware
                $netAdapterFound = $netHw.AdapterFound
                $netAdapterName = $netHw.AdapterName
                $isLinkConnected = $netHw.IsLinkConnected

                if (-not $netAdapterFound) {
                    Write-LiteDeployLog " [ERROR]   Network Card Not Detected! (Driver missing)" -Level "ERROR" -ForegroundColor Red
                    $shouldRetry = $true
                    if ($isWinPE -or $ShowGuiError) {
                        $msg = "Network Card Not Detected: No active network adapter found.`n`Please load the required network card driver.`n`nWould you like to try scanning again?"
                        $shouldRetry = Show-LiteDeployGuiError -Message $msg -Title "LiteDeploy - Network Driver Missing" -IsRetryDialog $true
                    }
                    else {
                        $shouldRetry = $false
                    }
                    if (-not $shouldRetry) { break }

                    if ($isWinPE) {
                        try { wpeutil.exe InitializeNetwork 2>$null } catch {}
                    }
                    try { [System.Console]::Out.Flush() } catch {}
                    Write-LiteDeployLog " [RETRY]   Re-scanning network hardware adapters..." -Level "RETRY" -ForegroundColor DarkYellow
                }
                else {
                    Write-LiteDeployLog " [SUCCESS] Adapter Found: '$($netAdapterName)'." -Level "SUCCESS" -ForegroundColor Green
                }
            }

            # Step 2: Check Physical Link / Cable Connection
            if ($netAdapterFound) {
                Write-Host ""
                Write-LiteDeployLog " [CHECK]   Verifying Network Link Connection..." -Level "INFO" -ForegroundColor Cyan
                while (-not $isLinkConnected) {
                    $netHw = Test-LiteDeployNetworkHardware
                    $isLinkConnected = $netHw.IsLinkConnected
                    if ($netHw.AdapterName) { $netAdapterName = $netHw.AdapterName }

                    if (-not $isLinkConnected) {
                        Write-LiteDeployLog " [WARNING] Network Cable Disconnected on '$($netAdapterName)'!" -Level "WARNING" -ForegroundColor Yellow
                        $shouldRetry = $true
                        if ($isWinPE -or $ShowGuiError) {
                            $msg = "Network Cable Disconnected: Adapter '$($netAdapterName)' is detected, but no network link/cable is connected.`n`Please connect an Ethernet cable to the network port.`n`nWould you like to check again?"
                            $shouldRetry = Show-LiteDeployGuiError -Message $msg -Title "LiteDeploy - Network Cable Disconnected" -IsRetryDialog $true
                        }
                        else {
                            $shouldRetry = $false
                        }
                        if (-not $shouldRetry) { break }

                        if ($isWinPE) {
                            try { wpeutil.exe InitializeNetwork 2>$null } catch {}
                        }
                        try { [System.Console]::Out.Flush() } catch {}
                        Write-LiteDeployLog " [RETRY]   Re-checking network cable connection on '$($netAdapterName)'..." -Level "RETRY" -ForegroundColor DarkYellow
                    }
                    else {
                        Write-LiteDeployLog " [SUCCESS] Network Link Active (Cable Connected)." -Level "SUCCESS" -ForegroundColor Green
                    }
                }
            }

            # Step 3: Poll IP Address Assignment (Only if NIC is present and cable is connected)
            if ($netAdapterFound -and $isLinkConnected) {
                Write-Host ""
                Write-LiteDeployLog " [CHECK]   Polling IPv4 / IPv6 Address Assignment..." -Level "INFO" -ForegroundColor Cyan
                while ([string]::IsNullOrWhiteSpace($ipAddress)) {
                    $ipCheck = Test-LiteDeployIPAddress -TimeoutSeconds 30
                    $ipAddress = $ipCheck.IPAddress
                    $ipv4Address = $ipCheck.IPv4Address
                    $ipv6Address = $ipCheck.IPv6Address

                    if ($ipAddress) {
                        Write-LiteDeployLog " [SUCCESS] IP Address Assigned: $($ipAddress)" -Level "SUCCESS" -ForegroundColor Green
                    }
                    else {
                        Write-LiteDeployLog " [WARNING] Could not obtain IP Address (30s DHCP Timeout) on '$($netAdapterName)'!" -Level "WARNING" -ForegroundColor Yellow
                        $shouldRetry = $true
                        if ($isWinPE -or $ShowGuiError) {
                            $msg = "No IP Address Assigned: Network adapter '$($netAdapterName)' is connected, but could not obtain an IPv4/IPv6 address after 30 seconds.`n`Please check your DHCP server or network connection.`n`nWould you like to try obtaining an IP address again?"
                            $shouldRetry = Show-LiteDeployGuiError -Message $msg -Title "LiteDeploy - IP Address Assignment Failed" -IsRetryDialog $true
                        }
                        else {
                            $shouldRetry = $false
                        }
                        if (-not $shouldRetry) { break }

                        if ($isWinPE) {
                            try { wpeutil.exe InitializeNetwork 2>$null } catch {}
                        }
                        try { [System.Console]::Out.Flush() } catch {}
                        Write-LiteDeployLog " [RETRY]   Retrying IP address assignment for '$($netAdapterName)'..." -Level "RETRY" -ForegroundColor DarkYellow
                    }
                }
            }

            # Only test deployment server reachability if local network hardware and valid IP assignment are present
            $hasNetworkAccess = $netAdapterFound -and [bool]$ipAddress

            if (-not $hasNetworkAccess) {
                $serverReachable = $false
                Write-LiteDeployLog " [WARNING] Deployment Server check skipped: Local network access unavailable (NIC missing or IP unassigned)." -Level "WARNING" -ForegroundColor Yellow
            }
            else {
                # Step 4: Check Deployment Server Reachability (SMB Port 445 Interactive Retry Loop)
                $serverReachable = $false
                $serverName = ""
                $serverHost = if ($networkPath) { (Format-LiteDeployUncPath -Path $networkPath).TrimStart('\').Split('\')[0] } else { "" }

                Write-Host ""
                Write-LiteDeployLog " [CHECK]   Testing SMB Connectivity to Server '$($serverHost)' (Port 445)..." -Level "INFO" -ForegroundColor Cyan
                while (-not $serverReachable) {
                    $shareCheck = Test-LiteDeployDeploymentShare -SharePath $networkPath -TimeoutMs 5000
                    $serverReachable = $shareCheck.Reachable
                    $serverName = $shareCheck.Server

                    if (-not $serverReachable) {
                        Write-LiteDeployLog " [ERROR]   Server '$($serverName)' is Unreachable on SMB Port 445!" -Level "ERROR" -ForegroundColor Red
                        $shouldRetry = $true
                        if ($isWinPE -or $ShowGuiError) {
                            $msg = "Deployment Server '$($serverName)' (from NetworkPath: $($networkPath)) could not be reached on SMB Port 445.`n`Please ensure the deployment server is online, SMB sharing is enabled, and firewall allows port 445.`n`nWould you like to try connecting again?"
                            $shouldRetry = Show-LiteDeployGuiError -Message $msg -Title "LiteDeploy - Server Unreachable" -IsRetryDialog $true
                        }
                        else {
                            $shouldRetry = $false
                        }
                        if (-not $shouldRetry) { break }

                        if ($isWinPE) {
                            try { wpeutil.exe InitializeNetwork 2>$null } catch {}
                        }
                        try { [System.Console]::Out.Flush() } catch {}
                        Write-LiteDeployLog " [RETRY]   Retrying SMB connectivity test to server '$($serverHost)'..." -Level "RETRY" -ForegroundColor DarkYellow
                    }
                    else {
                        Write-LiteDeployLog " [SUCCESS] Server '$($serverName)' is Reachable over SMB Port 445." -Level "SUCCESS" -ForegroundColor Green
                    }
                }

                if ($serverReachable -and ($MountShare -or $isWinPE)) {
                    Write-Host ""
                    Write-LiteDeployLog " [CHECK]   Connecting Deployment Share to Z:\..." -Level "INFO" -ForegroundColor Cyan
                    $mountRes = Connect-LiteDeployDeploymentShare -NetworkPath $networkPath -DriveLetter "Z:" -ShowGuiError:$ShowGuiError
                    $mountObj = if ($mountRes -is [array]) { $mountRes | Where-Object { $_ -is [PSCustomObject] -and $_.PSObject.Properties['Mounted'] } | Select-Object -Last 1 } else { $mountRes }
                    $shareMounted = [bool]($mountObj -and $mountObj.PSObject.Properties['Mounted'] -and $mountObj.Mounted)
                    $mountedDrive = if ($mountObj -and $mountObj.PSObject.Properties['DriveLetter']) { $mountObj.DriveLetter } else { "Z:" }
                    $userCred = if ($mountObj -and $mountObj.PSObject.Properties['Credential']) { $mountObj.Credential } else { $null }
                    if ($shareMounted) {
                        $engineScriptPath = Resolve-LiteDeployEnginePath -RootPath "Z:"

                        # The WinPE BootConfig is only a bootstrap contract. Once the
                        # deployment source is mounted, promote its full configuration
                        # into BootObject so every downstream script consumes the same
                        # in-memory object and credential-bearing process.
                        $runtimeConfig = Get-LiteDeployRuntimeConfig -RootPath "Z:" -LocalRootName $localRootName
                        if ($runtimeConfig) {
                            $FoundConfigPath = $runtimeConfig.Path
                            $cfg = $runtimeConfig.Config
                            $configFound = $true

                            if ($cfg.PSObject.Properties['Metadata'] -and $cfg.Metadata) {
                                if ($cfg.Metadata.PSObject.Properties['Name'] -and $cfg.Metadata.Name) { $appName = $cfg.Metadata.Name }
                                if ($cfg.Metadata.PSObject.Properties['Environment'] -and $cfg.Metadata.Environment) { $envName = $cfg.Metadata.Environment }
                                if ($cfg.Metadata.PSObject.Properties['Version'] -and $cfg.Metadata.Version) { $appVersion = $cfg.Metadata.Version }
                            }
                            if ($cfg.PSObject.Properties['Deployment'] -and $cfg.Deployment -and
                                $cfg.Deployment.PSObject.Properties['LocalRootName'] -and $cfg.Deployment.LocalRootName) {
                                $localRootName = $cfg.Deployment.LocalRootName
                            }

                            Write-LiteDeployLog " [SUCCESS] Runtime configuration promoted from '$($FoundConfigPath)'." -Level "SUCCESS" -ForegroundColor Green
                        }
                        else {
                            Write-LiteDeployLog " [WARNING] Full runtime BootConfig.json was not found on the mounted deployment source; downstream defaults will be used." -Level "WARNING" -ForegroundColor Yellow
                        }
                    }
                }
            }
        }
    }

    return [PSCustomObject]@{
        ConfigFound         = $configFound
        ConfigPath          = $FoundConfigPath
        Config              = $cfg
        IsWinPE             = $isWinPE
        DeploymentType      = $deploymentType
        MediaDriveLetter    = $mediaDriveLetter
        LocalRootName       = $localRootName
        EngineScriptPath    = $engineScriptPath
        NetworkAdapterFound = $netAdapterFound
        NetworkAdapterName  = $netAdapterName
        IPAddress           = $ipAddress
        IPv4Address         = $ipv4Address
        IPv6Address         = $ipv6Address
        HasValidIP          = [bool]$ipAddress
        ServerReachable     = $serverReachable
        ServerName          = $serverName
        ShareMounted        = $shareMounted
        DriveLetter         = $mountedDrive
        Credential          = $userCred
        AppName             = $appName
        AppVersion          = $appVersion
        Environment         = $envName
        NetworkPath         = $networkPath
    }
}

# ==============================================================================
# 5. STANDALONE LAUNCHER
# ==============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    $res = Get-LiteDeployBootConfig -ConfigPath $ExplicitConfigPath -MountShare -ShowGuiError
    $bootObj = if ($res -is [array]) { $res | Where-Object { $_ -is [PSCustomObject] } | Select-Object -Last 1 } else { $res }

    $isMounted = [bool]($bootObj -and $bootObj.PSObject.Properties['ShareMounted'] -and $bootObj.ShareMounted)
    $isMedia = [bool]($bootObj -and $bootObj.PSObject.Properties['DeploymentType'] -and $bootObj.DeploymentType -eq "Media")

    if ($isMounted -or $isMedia) {
        $enginePath = if ($bootObj -and $bootObj.PSObject.Properties['EngineScriptPath']) { $bootObj.EngineScriptPath } else { "" }
        if ($enginePath -and (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
            Write-LiteDeployLog "Connection successful. Launching engine script: $($enginePath)..." -Level "INFO" -ForegroundColor Cyan
            
            # Check for HostShell script via EngineScriptPath folder or root DriveLetter, consume if present, and minimize console shell
            $engineFolder = Split-Path -Parent $enginePath
            $driveLetter = if ($bootObj.PSObject.Properties['DriveLetter']) { $bootObj.DriveLetter } else { "" }
            $hostShellResolved = Resolve-Path -Path @(
                "$engineFolder\LiteDeploy.HostShell.ps1",
                "$driveLetter\Engine\Scripts\LiteDeploy.HostShell.ps1",
                "$driveLetter\*\Engine\Scripts\LiteDeploy.HostShell.ps1"
            ) -ErrorAction SilentlyContinue | Select-Object -First 1
            $hostShellPath = if ($hostShellResolved) { $hostShellResolved.Path } else { $null }

            if ($hostShellPath) {
                try {
                    . $hostShellPath
                    if (Get-Command Set-HostShellWindow -ErrorAction SilentlyContinue) {
                        Set-HostShellWindow -Action Minimize
                    }
                    Write-LiteDeployLog "HostShell script '$($hostShellPath)' loaded successfully." -Level "INFO" -NoConsole
                }
                catch {
                    Write-LiteDeployLog "Failed to load HostShell script '$($hostShellPath)': $_" -Level "WARNING" -NoConsole
                }
            }
            else {
                Write-LiteDeployLog "HostShell script 'LiteDeploy.HostShell.ps1' not found. Continuing without window minimization." -Level "INFO" -NoConsole
            }

            try {
                # Deployment engine orchestrates PreCheck → SelectWorkflow → state init (and later Setup).
                $null = & $enginePath -BootObject $bootObj
            }
            catch {
                Write-LiteDeployLog " [ERROR] Execution failed for '$($enginePath)': $_" -Level "ERROR" -ForegroundColor Red
                Write-Warning "Engine script execution failed: $_"
                if ($isWinPE -or $ShowGuiError) {
                    Show-LiteDeployGuiError -Message "Engine Script Execution Failed: $($enginePath) encountered an unhandled error:`n`n$_" -Title "LiteDeploy - Execution Error"
                }
            }

            if (Get-Command Set-HostShellWindow -ErrorAction SilentlyContinue) {
                try { Set-HostShellWindow -Action Restore } catch {}
            }
        }
        else {
            $targetPath = if ($enginePath) { $enginePath } else { "Z:\Engine\Scripts\LiteDeploy.DeploymentEngine.ps1" }
            Write-LiteDeployLog " [ERROR] Engine script not found: 'LiteDeploy.DeploymentEngine.ps1' is missing at '$($targetPath)'." -Level "ERROR" -ForegroundColor Red
            Write-Warning "Engine script missing: Unable to locate LiteDeploy.DeploymentEngine.ps1 at '$($targetPath)'."
            if ($isWinPE -or $ShowGuiError) {
                Show-LiteDeployGuiError -Message "Engine Script Missing: LiteDeploy.DeploymentEngine.ps1 was not found on deployment share/media.`n`Target Path: $($targetPath)`n`Please ensure the deployment engine script exists on the deployment share." -Title "LiteDeploy - Script Missing"
            }
            Write-Host ""
            Write-Host " [NOTICE]  Deployment initialization paused." -ForegroundColor Yellow
            Write-Host "           To restart this process, run 'startnet' below." -ForegroundColor Yellow
            Write-Host ""
        }
    }
    else {
        Write-Host ""
        Write-Host " [NOTICE]  Deployment initialization paused." -ForegroundColor Yellow
        Write-Host "           To restart this process, run 'startnet' below." -ForegroundColor Yellow
        Write-Host ""
    }
}
