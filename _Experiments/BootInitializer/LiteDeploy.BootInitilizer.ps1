<#
.SYNOPSIS
    LiteDeploy WinPE Initialization & BootConfig Discovery Engine.

.DESCRIPTION
    Discovers BootConfig.json using a 3-priority hierarchy, performs network pre-validations,
    prompts for user credentials via native Get-Credential, maps deployment share Z:\ persistently,
    and resolves the target engine pre-check script path.

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
Write-Host  "LiteDeploy Loading..." -ForegroundColor DarkGray
Start-Sleep -Seconds 4
$Host.UI.RawUI.WindowTitle = "LiteDeploy v1.0"
Clear-Host

# ==============================================================================
# 1. HELPERS & GUI DIALOGS
# ==============================================================================

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
    if ([string]::IsNullOrWhiteSpace($RootPath)) { return "" }
    $resolved = Resolve-Path -Path @(
        "$RootPath\Engine\Scripts\LiteDeploy.PreCheck.ps1",
        "$RootPath\*\Engine\Scripts\LiteDeploy.PreCheck.ps1"
    ) -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($resolved) { return $resolved.Path }
    return (Join-Path $RootPath "Engine\Scripts\LiteDeploy.PreCheck.ps1")
}

# ==============================================================================
# 2. NETWORK VALIDATIONS
# ==============================================================================

function Test-LiteDeployNetworkHardware {
    try {
        $nicName = ""
        if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
            $nics = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne "Disabled" }
            if ($nics) {
                $first = $nics | Select-Object -First 1
                $nicName = if ($first.InterfaceDescription) { $first.InterfaceDescription.Trim() } else { $first.Name }
            }
        }
        if ([string]::IsNullOrWhiteSpace($nicName)) {
            try {
                $nics = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | 
                Where-Object { $_.NetworkInterfaceType -ne 'Loopback' -and $_.OperationalStatus -eq 'Up' }
                if ($nics) { $nicName = ($nics | Select-Object -First 1).Description.Trim() }
            }
            catch {}
        }
        return [PSCustomObject]@{ AdapterFound = (-not [string]::IsNullOrWhiteSpace($nicName)); AdapterName = $nicName }
    }
    catch {
        return [PSCustomObject]@{ AdapterFound = $false; AdapterName = "" }
    }
}

function Test-LiteDeployIPAddress {
    param([int]$TimeoutSeconds = 10)
    try {
        $ipAddress = ""; $ipv4Address = ""; $ipv6Address = ""
        $timer = [System.Diagnostics.Stopwatch]::StartNew()

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
            Start-Sleep -Milliseconds 150
        }
        return [PSCustomObject]@{ IPAddress = $ipAddress; IPv4Address = $ipv4Address; IPv6Address = $ipv6Address; HasValidIP = [bool]$ipAddress }
    }
    catch {
        return [PSCustomObject]@{ IPAddress = ""; IPv4Address = ""; IPv6Address = ""; HasValidIP = $false }
    }
}

function Test-LiteDeployDeploymentShare {
    param([string]$SharePath, [int]$TimeoutMs = 2000)
    try {
        if ([string]::IsNullOrWhiteSpace($SharePath)) { return [PSCustomObject]@{ Reachable = $false; Server = "" } }
        $server = $SharePath.TrimStart('\').Split('\')[0]
        $smbOK = $false
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $connect = $tcp.BeginConnect($server, 445, $null, $null)
            if ($connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { $tcp.EndConnect($connect); $smbOK = $true }
            else { $tcp.Close() }
        }
        catch {} finally { $tcp.Dispose() }
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
                    Remove-SmbMapping -LocalPath $cleanDrive -Force -UpdateProfile -ErrorAction SilentlyContinue
                }
            }
            catch {}
            Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
        }
    }

    # Fast-Path: Check if drive Z:\ is already connected
    if (Test-Path -Path "$($cleanDrive)\" -ErrorAction SilentlyContinue) {
        Write-Host " [INFO] Deployment share is already connected to $($cleanDrive)\" -ForegroundColor Green
        $existingCred = if (Test-Path Variable:global:LiteDeployCredential) { $global:LiteDeployCredential } else { $null }
        return [PSCustomObject]@{ Mounted = $true; DriveLetter = $cleanDrive; NetworkPath = $NetworkPath; Credential = $existingCred }
    }

    try {
        if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
            Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}

    $mounted = $false
    $userCred = $null

    while (-not $mounted) {
        try {
            $userCred = Get-Credential -Message "Enter credentials to access deployment share: $($NetworkPath)" -ErrorAction Stop
        }
        catch {
            Write-Warning "Deployment share authentication cancelled by user."
            Write-Host "`n [NOTICE] Deployment initialization paused.`n To restart this process, type 'wpeinit' or run 'startnet' below.`n" -ForegroundColor Yellow
            break
        }
        if ($null -eq $userCred) { break }

        # Native PowerShell persistent global drive mapping
        try {
            $null = New-PSDrive -Name $driveName -PSProvider FileSystem -Root $NetworkPath -Credential $userCred -Persist -Scope Global -ErrorAction Stop
            $mounted = $true
        }
        catch {
            try {
                if (Get-Command New-SmbMapping -ErrorAction SilentlyContinue) {
                    $null = New-SmbMapping -LocalPath $cleanDrive -RemotePath $NetworkPath -Credential $userCred -ErrorAction Stop
                    $mounted = $true
                }
            }
            catch {}
        }

        if ($mounted -or (Test-Path -Path "$($cleanDrive)\")) {
            $mounted = $true
            $global:LiteDeployCredential = $userCred
            $global:LiteDeployShareMounted = $true
            Write-Host " [SUCCESS] Deployment share connected successfully to $($cleanDrive)\" -ForegroundColor Green
            break
        }

        Write-Warning "Authentication failed for user '$($userCred.UserName)' on share '$($NetworkPath)'."
        $shouldRetry = $true
        if ($isWinPE -or $ShowGuiError) {
            $msg = "Invalid Credentials: Username or password is invalid for $($NetworkPath).`n`nWould you like to try again?"
            $shouldRetry = Show-LiteDeployGuiError -Message $msg -Title "LiteDeploy - Authentication Failure" -IsRetryDialog $true
        }
        else {
            Write-Host " [ERROR] Invalid Credentials for $($NetworkPath)." -ForegroundColor Red
        }
        if (-not $shouldRetry) { break }
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
                        if ($cfg.Deployment.NetworkPath) { $networkPath = $cfg.Deployment.NetworkPath }
                        if ($cfg.Deployment.LocalRootName) { $localRootName = $cfg.Deployment.LocalRootName }
                    }
                }
            }
        }
        catch {}
    }

    if (-not $configFound) {
        Write-Warning "BootConfig.json file was not found."
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
            $engineScriptPath = Resolve-LiteDeployEnginePath -RootPath $mediaDriveLetter
        }
    }
    elseif ($deploymentType -eq "Network") {
        if ([string]::IsNullOrWhiteSpace($networkPath)) {
            $serverReachable = $false
            Write-Warning "Misconfigured Network Deployment: NetworkPath is missing in BootConfig.json."
            if ($isWinPE -or $ShowGuiError) {
                Show-LiteDeployGuiError -Message "NetworkPath is missing in BootConfig.json.`n`Please update BootConfig.json with a valid network share path." -Title "LiteDeploy - Misconfigured NetworkPath"
            }
        }
        else {
            # Network Deployment Mode: Check NIC Hardware & IP Assignment
            $netHw = Test-LiteDeployNetworkHardware
            $netAdapterFound = $netHw.AdapterFound; $netAdapterName = $netHw.AdapterName

            if (-not $netAdapterFound) {
                Write-Warning "Network Card Not Detected: No active network adapter found."
                if ($isWinPE -or $ShowGuiError) {
                    Show-LiteDeployGuiError -Message "Network Card Not Detected: No active network adapter found.`n`Please ensure boot image includes network drivers." -Title "LiteDeploy - Driver Missing"
                }
            }
            else {
                $ipCheck = Test-LiteDeployIPAddress -TimeoutSeconds 10
                $ipAddress = $ipCheck.IPAddress
                $ipv4Address = $ipCheck.IPv4Address
                $ipv6Address = $ipCheck.IPv6Address
            }

            # Only test deployment server reachability if local network hardware and IP assignment are present
            $hasNetworkAccess = $netAdapterFound -and [bool]$ipAddress

            if (-not $hasNetworkAccess) {
                $serverReachable = $false
                Write-Warning "Deployment Server check skipped: Local network access unavailable (NIC missing or IP unassigned)."
            }
            else {
                $shareCheck = Test-LiteDeployDeploymentShare -SharePath $networkPath -TimeoutMs 2000
                $serverReachable = $shareCheck.Reachable; $serverName = $shareCheck.Server

                if (-not $serverReachable) {
                    Write-Warning "Deployment Server Unreachable: Unable to connect to '$($serverName)' on SMB Port 445."
                    if ($isWinPE -or $ShowGuiError) {
                        Show-LiteDeployGuiError -Message "Deployment Server '$($serverName)' could not be reached on SMB Port 445." -Title "LiteDeploy - Server Unreachable"
                    }
                }
                elseif ($MountShare -or $isWinPE) {
                    $mountRes = Connect-LiteDeployDeploymentShare -NetworkPath $networkPath -DriveLetter "Z:" -ShowGuiError:$ShowGuiError
                    $shareMounted = $mountRes.Mounted
                    $mountedDrive = $mountRes.DriveLetter
                    $userCred = $mountRes.Credential
                    if ($shareMounted) {
                        $engineScriptPath = Resolve-LiteDeployEnginePath -RootPath "Z:"
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
            Write-Host "`n [INFO] Connection successful. Launching engine script: $($enginePath)...`n" -ForegroundColor Cyan
            
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
                }
                catch {}
            }

            & $enginePath -BootObject $bootObj

            if (Get-Command Set-HostShellWindow -ErrorAction SilentlyContinue) {
                try { Set-HostShellWindow -Action Restore } catch {}
            }
        }
    }
    else {
        Write-Host "`n [NOTICE] Deployment initialization paused.`n To restart this process, type 'wpeinit' or run 'startnet' below.`n" -ForegroundColor Yellow
    }
    $bootObj
}
