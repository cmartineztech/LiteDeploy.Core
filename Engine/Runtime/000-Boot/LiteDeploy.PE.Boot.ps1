<#
.SYNOPSIS
    LiteDeploy WinPE Initialization & BootConfig Discovery Engine.

.DESCRIPTION
    Discovers BootConfig.json from WinPE RAM (X:\~LiteDeploy\Config) or external USB/media,
    performs network pre-validations, prompts for credentials via Get-Credential, maps the
    deployment share to Z:\ persistently, and launches LiteDeploy.PE.Engine.ps1.

.PARAMETER ExplicitConfigPath
    Optional explicit path to BootConfig.json file to bypass automatic discovery.

.PARAMETER MountShare
    Switch to force mounting of the network deployment share specified in BootConfig.json.

.PARAMETER ShowGuiError
    Switch to display graphical Windows Forms message boxes on errors.

.PARAMETER Metadata
    Outputs the standardized component metadata PSCustomObject and exits immediately.

.EXAMPLE
    .\LiteDeploy.PE.Boot.ps1 -MountShare -ShowGuiError

.NOTES
    LiteDeploy Core Component Standard v2.0
    Target Environment: WinPE
    PowerShell Version: 5.1+
    Strict Mode: Version 2.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ExplicitConfigPath = "",

    [Parameter(Mandatory = $false)]
    [switch]$MountShare,

    [Parameter(Mandatory = $false)]
    [switch]$ShowGuiError,

    [Parameter(Mandatory = $false)]
    [switch]$Metadata
)

# Enforce strict execution discipline across WinPE runtime
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
        ComponentId          = "PE.Boot"
        Name                 = "LiteDeploy PE Boot"
        Version              = "2.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "WinPE"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @()
        Description          = "WinPE parent shell: discovers BootConfig.json, validates network, mounts Z:\, and launches LiteDeploy.PE.Engine.ps1."
    }
}

# Fast-exit for automated inventory scanners or version queries
if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

# ==============================================================================
# 2. HELPERS & GUI DIALOGS
# ==============================================================================

function Format-LiteDeployBootLogLine {
    <#
    .SYNOPSIS
        Autonomous console formatter for PE.Boot. Formats [LEVEL] tag with fixed padding.
    #>
    param(
        [AllowEmptyString()][string]$Message = "",
        [string]$Level = "INFO",
        [switch]$NoPrefix
    )

    if ($NoPrefix -or [string]::IsNullOrWhiteSpace($Message) -or $Message -match '^\s{2,}[^\[]') {
        return $Message
    }

    $clean = $Message -replace '(?i)^\s*\[(INFO|SUCCESS|INIT|CHECK|NOTICE|WARNING|RETRY|ERROR|DEBUG|BOOT|NETWORK|ENGINE)\]\s*', ''
    $tag = "[{0}]" -f $Level.ToUpper()
    return ($tag.PadRight(11) + $clean)
}

function Write-LiteDeployLog {
    param(
        [string]$Message = "",
        [string]$Level = "INFO",
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::White,
        [string]$Component = "PE.Boot",
        [switch]$NoConsole,
        [switch]$NoPrefix
    )

    if ($ForegroundColor -eq [ConsoleColor]::White) {
        $ForegroundColor = switch ($Level.ToUpper()) {
            "SUCCESS" { [ConsoleColor]::Green }
            "INIT"    { [ConsoleColor]::DarkGray }
            "CHECK"   { [ConsoleColor]::Cyan }
            "NOTICE"  { [ConsoleColor]::Yellow }
            "WARNING" { [ConsoleColor]::Yellow }
            "RETRY"   { [ConsoleColor]::DarkYellow }
            "ERROR"   { [ConsoleColor]::Red }
            default   { [ConsoleColor]::White }
        }
    }

    # Empty Message ("") still prints a blank console spacer; CMTrace skips whitespace-only below.
    if (-not $NoConsole) {
        Write-Host (Format-LiteDeployBootLogLine -Message $Message -Level $Level -NoPrefix:$NoPrefix) -ForegroundColor $ForegroundColor
    }
    try {
        $cleanMsg = $Message.Trim() -replace '[\r\n]+', ' '
        $cleanMsg = $cleanMsg.Replace(']LOG]!>', ']LOG] !>')
        if ([string]::IsNullOrWhiteSpace($cleanMsg)) {
            return
        }

        # Do not decorate CMTrace log with banner divider lines (====)
        if ($cleanMsg -match '^={5,}') {
            return
        }

        # Strip manual [TAG] prefix from persisted log entry only for known levels (retain domain tags like [UEFI]/[LEGACY])
        $cleanMsg = $cleanMsg -replace '(?i)^\s*\[(INFO|SUCCESS|INIT|CHECK|NOTICE|WARNING|RETRY|ERROR|DEBUG|BOOT|NETWORK|ENGINE)\]\s*', ''
        if ([string]::IsNullOrWhiteSpace($cleanMsg)) {
            return
        }

        $logDir = if (Get-Variable -Name LiteDeployBootLogDir -Scope Global -ErrorAction SilentlyContinue) {
            $global:LiteDeployBootLogDir
        } else {
            $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "X:" }
            Join-Path $sysDrive "~LiteDeploy\WorkLogs"
        }
        if (-not (Test-Path -LiteralPath $logDir)) {
            $null = New-Item -Path $logDir -ItemType Directory -Force -ErrorAction SilentlyContinue
        }
        $logFile = Join-Path $logDir "LiteDeploy.Execution.log"

        $now = Get-Date
        # CMTrace time uses local clock + UTC offset in minutes (e.g. -240 for EDT)
        $utcOffsetMinutes = [int][System.TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
        $offsetSign = if ($utcOffsetMinutes -ge 0) { "+" } else { "-" }
        $timeStr = $now.ToString("HH:mm:ss.fff") + $offsetSign + [math]::Abs($utcOffsetMinutes).ToString()
        $dateStr = $now.ToString("MM-dd-yyyy")
        $typeCode = switch ($Level.ToUpper()) {
            "ERROR"   { "3" }
            "WARNING" { "2" }
            "RETRY"   { "2" }
            "NOTICE"  { "1" }
            default   { "1" }
        }
        $scriptFile = if ($PSCommandPath) { Split-Path -Leaf $PSCommandPath } else { "LiteDeploy.PE.Boot.ps1" }
        # Official Microsoft CMTrace.exe XML Log Structure (UTF-8, PID thread, safe message)
        $logEntry = "<![LOG[$cleanMsg]LOG]!><time=""$timeStr"" date=""$dateStr"" component=""$Component"" context="""" type=""$typeCode"" thread=""$PID"" file=""$scriptFile"">"
        Add-Content -Path $logFile -Value $logEntry -Encoding utf8 -ErrorAction SilentlyContinue
    }
    catch {}
}

function Format-LiteDeployUncPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    if ($Path -match '^[A-Za-z]:') { return $Path.TrimEnd('\') }
    $clean = $Path -replace '/', '\'
    if ($clean -notlike '\\*') {
        $clean = "\\$($clean.TrimStart('\'))"
    }
    return $clean.TrimEnd('\')
}

function Enable-LiteDeployLongPaths {
    <#
    .SYNOPSIS
        Enables Win32/NTFS long path support (>260 characters) in the registry for WinPE and host environments.
    #>
    [CmdletBinding()]
    param()

    try {
        $fsKey = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
        if (Test-Path -LiteralPath $fsKey -ErrorAction SilentlyContinue) {
            $currentVal = (Get-ItemProperty -LiteralPath $fsKey -Name "LongPathsEnabled" -ErrorAction SilentlyContinue).LongPathsEnabled
            if ($currentVal -ne 1) {
                Set-ItemProperty -LiteralPath $fsKey -Name "LongPathsEnabled" -Value 1 -Type DWord -Force -ErrorAction Stop
                Write-LiteDeployLog "Enabled Windows long path support (LongPathsEnabled=1)." -Level "INIT" -Component "PE.Boot" -NoConsole
            }
        }
    }
    catch {
        Write-LiteDeployLog "Notice: Could not set LongPathsEnabled registry flag: $_" -Level "NOTICE" -Component "PE.Boot" -NoConsole
    }
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

function Write-LiteDeployPauseNotice {
    param(
        [string]$Reason = "Deployment initialization paused."
    )

    Write-Host ""
    Write-LiteDeployLog " [NOTICE]  $Reason" -Level "NOTICE" -ForegroundColor Yellow
    Write-LiteDeployLog "           To restart this process, run 'startnet' below." -Level "NOTICE" -ForegroundColor Yellow
    Write-Host ""
}

function Invoke-LiteDeployGuiRetry {
    <#
    .SYNOPSIS
        Shared failure → GUI Retry/Cancel → optional WinPE network re-init → retry log.
    .OUTPUTS
        $true  = caller should retry the check
        $false = user cancelled / non-interactive stop
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$WarningMessage,

        [Parameter(Mandatory = $true)]
        [string]$DialogMessage,

        [Parameter(Mandatory = $true)]
        [string]$DialogTitle,

        [Parameter(Mandatory = $true)]
        [string]$RetryLogMessage,

        [string]$WarningLevel = "WARNING",

        [ConsoleColor]$WarningColor = [ConsoleColor]::Yellow,

        [bool]$IsWinPE = $false,

        [switch]$ShowGuiError
    )

    Write-LiteDeployLog $WarningMessage -Level $WarningLevel -ForegroundColor $WarningColor

    $shouldRetry = $true
    if ($IsWinPE -or $ShowGuiError) {
        $shouldRetry = Show-LiteDeployGuiError -Message $DialogMessage -Title $DialogTitle -IsRetryDialog $true
    }
    else {
        $shouldRetry = $false
    }

    if (-not $shouldRetry) {
        return $false
    }

    if ($IsWinPE) {
        try { $null = & wpeutil.exe InitializeNetwork 2>$null } catch {}
    }
    try { [System.Console]::Out.Flush() } catch {}
    Write-LiteDeployLog $RetryLogMessage -Level "RETRY" -ForegroundColor DarkYellow
    return $true
}

function Resolve-LiteDeployEnginePath {
    param(
        [string]$RootPath,
        [string]$LocalRootName = "~LiteDeploy",
        [ValidateSet("Network", "Media")]
        [string]$DeploymentType = "Media"
    )
    # Layout differs by source:
    #   Network share (Z:):  Z:\Engine\Runtime\LiteDeploy.PE.Engine.ps1
    #   USB / Media:         <Drive>\~LiteDeploy\Engine\Runtime\LiteDeploy.PE.Engine.ps1
    if ([string]::IsNullOrWhiteSpace($RootPath)) { return "" }

    if ($DeploymentType -eq "Network") {
        return (Join-Path $RootPath "Engine\Runtime\LiteDeploy.PE.Engine.ps1")
    }

    if ([string]::IsNullOrWhiteSpace($LocalRootName)) { return "" }
    return (Join-Path $RootPath "$LocalRootName\Engine\Runtime\LiteDeploy.PE.Engine.ps1")
}

function Get-LiteDeployRuntimeConfig {
    param(
        [string]$RootPath,
        [string]$LocalRootName = "~LiteDeploy",
        [ValidateSet("Network", "Media")]
        [string]$DeploymentType = "Network"
    )
    # Layout differs by source:
    #   Network share (Z:):  Z:\Config\BootConfig.json
    #   USB / Media:         <Drive>\~LiteDeploy\Config\BootConfig.json
    if ([string]::IsNullOrWhiteSpace($RootPath)) { return $null }

    $path = if ($DeploymentType -eq "Network") {
        Join-Path $RootPath "Config\BootConfig.json"
    }
    else {
        if ([string]::IsNullOrWhiteSpace($LocalRootName)) { return $null }
        Join-Path $RootPath "$LocalRootName\Config\BootConfig.json"
    }

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    try {
        $rawContent = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $cleanContent = $rawContent -replace '^\xEF\xBB\xBF', ''
        $runtimeConfig = $cleanContent | ConvertFrom-Json -ErrorAction Stop

        return [PSCustomObject]@{
            Path   = $path
            Config = $runtimeConfig
        }
    }
    catch {
        throw "Runtime BootConfig.json is invalid at '$path': $($_.Exception.Message)"
    }
}

if (-not (Test-Path Variable:global:LiteDeployCredential)) {
    $global:LiteDeployCredential = $null
}

# ==============================================================================
# 3. NETWORK VALIDATIONS
# ==============================================================================


if (-not (Get-Command Get-LiteDeployHardwareInventory -ErrorAction SilentlyContinue)) {
    function Get-LiteDeployHardwareInventory { [CmdletBinding()] param() return (Test-LiteDeployNetworkHardware) }
}
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
        # One log entry for the wait; countdown ticks stay console-only
        Write-LiteDeployLog " [INFO]    Waiting for DHCP (up to $($TimeoutSeconds)s)..." -Level "INFO" -ForegroundColor DarkCyan
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $lastReport = -1

        while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $remaining = [math]::Max(0, [int]($TimeoutSeconds - $timer.Elapsed.TotalSeconds))
            if ($remaining -ne $lastReport -and ($remaining % 5 -eq 0 -or $remaining -le 5)) {
                $lastReport = $remaining
                Write-Host -NoNewline "`r [DHCP]    Waiting for IP address configuration ($($remaining)s remaining)...   "
            }

            if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
                $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
                Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" }
                if ($ips) {
                    $ipv4Address = ($ips | Select-Object -First 1).IPAddress
                    $ipAddress = $ipv4Address
                    break
                }
            }

            if ([string]::IsNullOrWhiteSpace($ipAddress)) {
                try {
                    $allNics = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | 
                    Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' }
                    foreach ($adapter in $allNics) {
                        $prop = $adapter.GetIPProperties()
                        foreach ($uni in $prop.UnicastAddresses) {
                            $addrStr = $uni.Address.ToString()
                            if ($uni.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $addrStr -notlike "127.*" -and $addrStr -notlike "169.254.*") {
                                $ipv4Address = $addrStr
                                $ipAddress = $addrStr
                                break
                            }
                        }
                        if ($ipAddress) { break }
                    }
                }
                catch {}
            }

            if ($ipAddress) { break }
            Start-Sleep -Milliseconds 1000
        }
        Write-Host "`r" + (" " * 80) + "`r" -NoNewline

        return [PSCustomObject]@{
            IPAddress   = $ipAddress
            IPv4Address = $ipv4Address
            IPv6Address = $ipv6Address
        }
    }
    catch {
        return [PSCustomObject]@{ IPAddress = ""; IPv4Address = ""; IPv6Address = "" }
    }
}

function Test-LiteDeployDeploymentShare {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SharePath,
        [int]$TimeoutMs = 5000
    )
    $cleanPath = Format-LiteDeployUncPath -Path $SharePath
    $server = ($cleanPath.TrimStart('\')).Split('\')[0]
    $reachable = $false

    if (-not [string]::IsNullOrWhiteSpace($server)) {
        $tcp = $null
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            $connectTask = $tcp.ConnectAsync($server, 445)
            $completed = $connectTask.Wait($TimeoutMs)
            if ($completed -and $tcp.Connected) {
                $reachable = $true
            }
        }
        catch {
            $reachable = $false
        }
        finally {
            if ($tcp) {
                try { $tcp.Close(); $tcp.Dispose() } catch {}
            }
        }
    }

    return [PSCustomObject]@{
        Server    = $server
        Reachable = $reachable
    }
}

function Protect-LiteDeployBootText {
    <#
    .SYNOPSIS
        Redacts credentials, password values, and token-shaped patterns before logging or console display.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [System.Management.Automation.PSCredential]$Credential = $null
    )
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    $clean = $Text

    # Redact actual secret if credential object is provided
    if ($Credential -and $Credential.Password) {
        try {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
            $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            if (-not [string]::IsNullOrEmpty($plain)) {
                $clean = $clean.Replace($plain, '***')
            }
        }
        catch {}
    }

    # Redact credential-shaped password/token fields
    $clean = [regex]::Replace(
        $clean,
        '(?i)((?:pass(?:word|wd)?|pwd|secret|token|api[-_ ]?key|credential)\s*[=:]\s*)("[^"]*"|''[^'']*''|[^\s;,]+)',
        '$1***')
    $clean = [regex]::Replace(
        $clean,
        '(?i)(-(?:password|passwd|pwd|secret|token|apikey)\s+)("[^"]*"|''[^'']*''|\S+)',
        '$1***')
    return $clean
}

function Get-LiteDeployErrorDiagnostic {
    <#
    .SYNOPSIS
        Extracts structured diagnostics (NativeErrorCode, HResult, ErrorId, Type, safe Message) and failure classification.
    #>
    param(
        $ErrorRecord,
        [System.Management.Automation.PSCredential]$Credential = $null
    )
    $ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } elseif ($ErrorRecord -is [System.Exception]) { $ErrorRecord } else { $null }
    $errType = if ($ex) { $ex.GetType().Name } else { "Unknown" }
    $rawMsg = if ($ex) { $ex.Message.Trim() } else { "Unknown error" }
    $cleanMsg = Protect-LiteDeployBootText -Text $rawMsg -Credential $Credential
    $errIdRaw = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { [string]$ErrorRecord.FullyQualifiedErrorId } else { "None" }
    $errId = Protect-LiteDeployBootText -Text $errIdRaw -Credential $Credential

    $hresultInt = if ($ex) { $ex.HResult } else { 0 }
    $hresultHex = if ($ex) { "0x{0:X8}" -f $hresultInt } else { "None" }

    $nativeCode = $null
    $curr = $ex
    while ($curr) {
        if ($curr -is [System.ComponentModel.Win32Exception]) {
            $nativeCode = [int]$curr.NativeErrorCode
            break
        }
        $curr = $curr.InnerException
    }

    $isLogon = $false
    $isAccessDenied = $false

    # Genuine logon failure codes (Win32 ERROR_LOGON_FAILURE 1326 / HResult 0x8007052E / etc.)
    if ($nativeCode -in @(1326, 1330, 1331, 1328, 1329, 1907, 1909)) {
        $isLogon = $true
    }
    elseif ($hresultInt -in @(-2147023570, -2147023566, -2147023565)) {
        $isLogon = $true
    }
    elseif ($errIdRaw -match '(?i)LogonFailure' -or $cleanMsg -match '(?i)\b(logon failure|bad user name or password|unknown user name or bad password)\b') {
        $isLogon = $true
    }

    if (-not $isLogon) {
        # Genuine access denied codes (ERROR_ACCESS_DENIED 5 / HResult 0x80070005 / UnauthorizedAccessException)
        if ($nativeCode -eq 5 -or $hresultInt -eq -2147024891 -or $ex -is [System.UnauthorizedAccessException] -or $errIdRaw -match '(?i)(AccessDenied|UnauthorizedAccess)' -or $cleanMsg -match '(?i)\baccess is denied\b') {
            $isAccessDenied = $true
        }
    }

    return [PSCustomObject]@{
        Type            = $errType
        Message         = $cleanMsg
        ErrorId         = $errId
        HResult         = $hresultHex
        HResultInt      = $hresultInt
        NativeErrorCode = $nativeCode
        IsLogonFailure  = $isLogon
        IsAccessDenied  = $isAccessDenied
    }
}

function Connect-LiteDeployDeploymentShare {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NetworkPath,
        [string]$DriveLetter = "Z:",
        [switch]$ShowGuiError
    )

    $cleanDrive = $DriveLetter.TrimEnd('\')
    $driveName = $cleanDrive.TrimEnd(':')
    $isWinPE = Test-Path -Path "HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT" -ErrorAction SilentlyContinue

    if ($isWinPE) {
        Enable-LiteDeployLongPaths
    }

    # Clean existing mapping to prevent stale credential locks
    try { [void](net.exe use "$cleanDrive" /delete /y 2>$null) } catch {}
    if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue | Out-Null
    }

    # Fast-Path: Check if drive Z:\ is already connected
    if (Test-Path -Path "$($cleanDrive)\" -ErrorAction SilentlyContinue) {
        Write-LiteDeployLog " [SUCCESS] Deployment share '$NetworkPath' is already connected to $($cleanDrive)\." -Level "SUCCESS" -ForegroundColor Green
        $existingCred = if (Test-Path Variable:global:LiteDeployCredential) { $global:LiteDeployCredential } else { $null }
        return [PSCustomObject]@{ Mounted = $true; DriveLetter = $cleanDrive; NetworkPath = $NetworkPath; Credential = $existingCred }
    }

    $mounted = $false
    $userCred = $null
    $attempt = 0
    $hadPreviousFailure = $false

    while (-not $mounted) {
        $attempt++
        try {
            # Keep CredUI short - full UNC is already shown on the console CHECK line above
            $userCred = Get-Credential -Message "Please enter your username and password to connect to the deployment share." -ErrorAction Stop
        }
        catch {
            Write-LiteDeployLog "Deployment share authentication cancelled by user." -Level "WARNING" -ForegroundColor Yellow
            Write-LiteDeployPauseNotice
            break
        }
        if ($null -eq $userCred) { break }

        $attemptedErrors = [System.Collections.Generic.List[psobject]]::new()

        try {
            $null = New-PSDrive -Name $driveName -PSProvider FileSystem -Root $NetworkPath -Credential $userCred -Persist -Scope Global -ErrorAction Stop
            $mounted = $true
        }
        catch {
            $diagPsDrive = Get-LiteDeployErrorDiagnostic -ErrorRecord $_ -Credential $userCred
            $attemptedErrors.Add([PSCustomObject]@{ Method = "New-PSDrive"; Diag = $diagPsDrive })

            if (Get-Command New-SmbMapping -ErrorAction SilentlyContinue) {
                try {
                    $null = New-SmbMapping -LocalPath $cleanDrive -RemotePath $NetworkPath -Credential $userCred -ErrorAction Stop
                    $mounted = $true
                }
                catch {
                    $diagSmb = Get-LiteDeployErrorDiagnostic -ErrorRecord $_ -Credential $userCred
                    $attemptedErrors.Add([PSCustomObject]@{ Method = "New-SmbMapping"; Diag = $diagSmb })
                }
            }
        }

        if ($mounted -or (Test-Path -Path "$($cleanDrive)\")) {
            $mounted = $true
            $global:LiteDeployCredential = $userCred
            $global:LiteDeployShareMounted = $true
            if ($hadPreviousFailure) {
                Write-LiteDeployLog "Deployment share connection recovered on attempt $attempt." -Level "INFO" -Component "PE.Boot"
            }
            Write-LiteDeployLog "Connected to deployment share '$NetworkPath' on $($cleanDrive)\." -Level "SUCCESS" -ForegroundColor Green
            break
        }

        $hadPreviousFailure = $true

        # Determine classification from attempted errors: prioritize genuine logon failure, then access denied, else last error
        $logonAtt = $null
        $accessAtt = $null
        foreach ($att in $attemptedErrors) {
            if ($att.Diag.IsLogonFailure -and -not $logonAtt) { $logonAtt = $att }
            if ($att.Diag.IsAccessDenied -and -not $accessAtt) { $accessAtt = $att }
        }
        $primaryDiag = if ($logonAtt) {
            $logonAtt.Diag
        } elseif ($accessAtt) {
            $accessAtt.Diag
        } elseif ($attemptedErrors.Count -gt 0) {
            $attemptedErrors[$attemptedErrors.Count - 1].Diag
        } else {
            $null
        }

        if ($primaryDiag -and $primaryDiag.IsLogonFailure) {
            Write-LiteDeployLog "Authentication failed for user '$($userCred.UserName)' on share '$NetworkPath'." -Level "ERROR" -ForegroundColor Red
        }
        elseif ($primaryDiag -and $primaryDiag.IsAccessDenied) {
            Write-LiteDeployLog "Access denied to share '$NetworkPath' for user '$($userCred.UserName)' ($($primaryDiag.Message))." -Level "ERROR" -ForegroundColor Red
        }
        else {
            $errMsg = if ($primaryDiag) { $primaryDiag.Message } else { "Unknown error" }
            Write-LiteDeployLog "Connection to share '$NetworkPath' failed ($errMsg)." -Level "ERROR" -ForegroundColor Red
        }

        # Detailed diagnostics to log for each actually attempted method (sanitized, zero password exposure)
        foreach ($att in $attemptedErrors) {
            $d = $att.Diag
            $nativeStr = if ($null -ne $d.NativeErrorCode) { ", NativeError=$($d.NativeErrorCode)" } else { "" }
            Write-LiteDeployLog "Share connection attempt $attempt failed (Method=$($att.Method), Type=$($d.Type), ErrorId=$($d.ErrorId), Code=$($d.HResult)$nativeStr): $($d.Message)" -Level "ERROR" -Component "PE.Boot" -NoConsole
        }

        if ($isWinPE) {
            try { $null = & wpeutil.exe InitializeNetwork 2>$null } catch {}
        }
        try { [System.Console]::Out.Flush() } catch {}
        Write-LiteDeployLog "Re-prompting for Credentials for $($NetworkPath)..." -Level "RETRY" -ForegroundColor DarkYellow
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
    if ($isWinPE) {
        Enable-LiteDeployLongPaths
    }

    # Discover BootConfig.json
    Write-Host ""
    Write-LiteDeployLog " [CHECK]   Searching for BootConfig.json..." -Level "INFO" -ForegroundColor Cyan
    $ramDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "X:" }
    $ramConfigPaths = @()
    if ($ConfigPath) { $ramConfigPaths += $ConfigPath }
    if ($isWinPE) {
        $ramConfigPaths += "$ramDrive\~LiteDeploy\Config\BootConfig.json"
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
            $null = Show-LiteDeployGuiError -Message "BootConfig.json was not found in WinPE RAM ($ramDrive\~LiteDeploy\Config) or external media.`n`nPlease rebuild the boot image or attach deployment media." -Title "LiteDeploy - Config Missing"
        }
    }

    # Resolution & Validations
    $netAdapterFound = $false; $netAdapterName = ""; $isLinkConnected = $false; $ipAddress = ""; $ipv4Address = ""; $ipv6Address = ""
    $serverReachable = $false; $serverName = ""; $shareMounted = $false; $mountedDrive = ""; $mediaDriveLetter = ""; $engineScriptPath = ""; $userCred = $null

    if ($deploymentType -eq "Media") {
        if ($FoundConfigPath) {
            $mediaDriveLetter = Split-Path -Qualifier $FoundConfigPath
            if ([string]::IsNullOrWhiteSpace($mediaDriveLetter)) { $mediaDriveLetter = $ramDrive }
            $mountedDrive = $mediaDriveLetter
            Write-LiteDeployLog " [INFO]    Deployment Mode: Media (Offline Drive: $($mediaDriveLetter))." -Level "INFO" -ForegroundColor DarkCyan
            $engineScriptPath = Resolve-LiteDeployEnginePath -RootPath $mediaDriveLetter -LocalRootName $localRootName -DeploymentType Media
        }
    }
    elseif ($deploymentType -eq "Network") {
        if ([string]::IsNullOrWhiteSpace($networkPath)) {
            $serverReachable = $false
            Write-LiteDeployLog " [WARNING] Misconfigured Network Deployment: NetworkPath is missing in BootConfig.json." -Level "WARNING" -ForegroundColor Yellow
            if ($isWinPE -or $ShowGuiError) {
                $null = Show-LiteDeployGuiError -Message "NetworkPath is missing in BootConfig.json.`n`nPlease update BootConfig.json with a valid network share path." -Title "LiteDeploy - Misconfigured NetworkPath"
            }
        }
        else {
            # Network Deployment Mode: Check NIC Hardware & IP Assignment (Interactive Retry Loops)
            if ($networkPath) {
                Write-LiteDeployLog " [INFO]    Deployment Mode: Network (Share: $($networkPath))." -Level "INFO" -ForegroundColor DarkCyan
            }

            # Step 1: Check Local Network Adapter
            Write-Host ""
            Write-LiteDeployLog " [CHECK]   Scanning for Network Hardware Adapters..." -Level "INFO" -ForegroundColor Cyan
            $netHw = Test-LiteDeployNetworkHardware
            $netAdapterFound = $netHw.AdapterFound
            $netAdapterName = $netHw.AdapterName
            $isLinkConnected = $netHw.IsLinkConnected

            while (-not $netAdapterFound) {
                $msg = "No Network Hardware Detected: WinPE could not detect any network adapter.`n`nPlease ensure network drivers are injected into the boot image, or connect an external adapter.`n`nWould you like to scan again?"
                $shouldRetry = Invoke-LiteDeployGuiRetry `
                    -WarningMessage " [WARNING] No Network Adapter Detected in WinPE!" `
                    -DialogMessage $msg `
                    -DialogTitle "LiteDeploy - Network Hardware Missing" `
                    -RetryLogMessage " [RETRY]   Re-scanning network hardware adapters..." `
                    -IsWinPE:$isWinPE `
                    -ShowGuiError:$ShowGuiError
                if (-not $shouldRetry) { break }

                $netHw = Test-LiteDeployNetworkHardware
                $netAdapterFound = $netHw.AdapterFound
                $netAdapterName = $netHw.AdapterName
                $isLinkConnected = $netHw.IsLinkConnected
            }

            if ($netAdapterFound) {
                Write-LiteDeployLog " [SUCCESS] Adapter Found: '$($netAdapterName)'." -Level "SUCCESS" -ForegroundColor Green

                # Step 2: Check Physical Link / Cable Connection
                Write-Host ""
                Write-LiteDeployLog " [CHECK]   Verifying Network Link Connection..." -Level "INFO" -ForegroundColor Cyan
                while (-not $isLinkConnected) {
                    $msg = "Network Cable Disconnected: Adapter '$($netAdapterName)' is detected, but no network link/cable is connected.`n`nPlease connect an Ethernet cable to the network port.`n`nWould you like to check again?"
                    $shouldRetry = Invoke-LiteDeployGuiRetry `
                        -WarningMessage " [WARNING] Network Cable Disconnected on '$($netAdapterName)'!" `
                        -DialogMessage $msg `
                        -DialogTitle "LiteDeploy - Network Cable Disconnected" `
                        -RetryLogMessage " [RETRY]   Re-checking network cable connection on '$($netAdapterName)'..." `
                        -IsWinPE:$isWinPE `
                        -ShowGuiError:$ShowGuiError
                    if (-not $shouldRetry) { break }

                    $netHw = Test-LiteDeployNetworkHardware
                    $isLinkConnected = $netHw.IsLinkConnected
                    if ($netHw.AdapterName) { $netAdapterName = $netHw.AdapterName }
                }

                if ($isLinkConnected) {
                    Write-LiteDeployLog " [SUCCESS] Network Link Active (Cable Connected)." -Level "SUCCESS" -ForegroundColor Green
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
                        $msg = "No IP Address Assigned: Network adapter '$($netAdapterName)' is connected, but could not obtain an IPv4/IPv6 address after 30 seconds.`n`nPlease check your DHCP server or network connection.`n`nWould you like to try obtaining an IP address again?"
                        $shouldRetry = Invoke-LiteDeployGuiRetry `
                            -WarningMessage " [WARNING] Could not obtain IP Address (30s DHCP Timeout) on '$($netAdapterName)'!" `
                            -DialogMessage $msg `
                            -DialogTitle "LiteDeploy - IP Address Assignment Failed" `
                            -RetryLogMessage " [RETRY]   Retrying IP address assignment for '$($netAdapterName)'..." `
                            -IsWinPE:$isWinPE `
                            -ShowGuiError:$ShowGuiError
                        if (-not $shouldRetry) { break }
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
                        $msg = "Deployment Server '$($serverName)' (from NetworkPath: $($networkPath)) could not be reached on SMB Port 445.`n`nPlease ensure the deployment server is online, SMB sharing is enabled, and firewall allows port 445.`n`nWould you like to try connecting again?"
                        $shouldRetry = Invoke-LiteDeployGuiRetry `
                            -WarningMessage " [ERROR]   Server '$($serverName)' is Unreachable on SMB Port 445!" `
                            -DialogMessage $msg `
                            -DialogTitle "LiteDeploy - Server Unreachable" `
                            -RetryLogMessage " [RETRY]   Retrying SMB connectivity test to server '$($serverHost)'..." `
                            -WarningLevel "ERROR" `
                            -WarningColor Red `
                            -IsWinPE:$isWinPE `
                            -ShowGuiError:$ShowGuiError
                        if (-not $shouldRetry) { break }
                    }
                    else {
                        Write-LiteDeployLog " [SUCCESS] Server '$($serverName)' is Reachable over SMB Port 445." -Level "SUCCESS" -ForegroundColor Green
                    }
                }

                if ($serverReachable -and ($MountShare -or $isWinPE)) {
                    Write-Host ""
                    Write-LiteDeployLog " [CHECK]   Connecting to deployment share '$networkPath'..." -Level "INFO" -ForegroundColor Cyan
                    $mountObj = Connect-LiteDeployDeploymentShare -NetworkPath $networkPath -DriveLetter "Z:" -ShowGuiError:$ShowGuiError
                    $shareMounted = [bool]$mountObj.Mounted
                    $mountedDrive = if ($mountObj.DriveLetter) { $mountObj.DriveLetter } else { "Z:" }
                    $userCred = $mountObj.Credential
                    if ($shareMounted) {
                        $engineScriptPath = Resolve-LiteDeployEnginePath -RootPath "Z:" -DeploymentType Network

                        # WinPE BootConfig may be minimal. Once the share is mounted,
                        # load the full deployment configuration into BootObject so
                        # later scripts use the same in-memory settings.
                        $runtimeConfig = Get-LiteDeployRuntimeConfig -RootPath "Z:" -DeploymentType Network
                        if ($runtimeConfig) {
                            $FoundConfigPath = $runtimeConfig.Path
                            $cfg = $runtimeConfig.Config
                            $configFound = $true

                            if ($cfg.PSObject.Properties['Metadata'] -and $cfg.Metadata) {
                                if ($cfg.Metadata.PSObject.Properties['Name'] -and $cfg.Metadata.Name) { $appName = $cfg.Metadata.Name }
                                if ($cfg.Metadata.Environment) { $envName = $cfg.Metadata.Environment }
                                if ($cfg.Metadata.PSObject.Properties['Version'] -and $cfg.Metadata.Version) { $appVersion = $cfg.Metadata.Version }
                            }
                            if ($cfg.PSObject.Properties['Deployment'] -and $cfg.Deployment -and
                                $cfg.Deployment.PSObject.Properties['LocalRootName'] -and $cfg.Deployment.LocalRootName) {
                                $localRootName = $cfg.Deployment.LocalRootName
                            }

                            Write-LiteDeployLog " [SUCCESS] Loaded deployment configuration from '$($FoundConfigPath)'." -Level "SUCCESS" -ForegroundColor Green
                        }
                        else {
                            Write-LiteDeployLog " [WARNING] Deployment configuration was not found on the share; continuing with current settings." -Level "WARNING" -ForegroundColor Yellow
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
    $isWinPE = Test-Path -Path "HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT" -ErrorAction SilentlyContinue

    if ($isWinPE) {
        # Activate High Performance power plan
        try { powercfg.exe /setactive '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' 2>$null } catch {}

        # Enable Windows long path support (>260 characters)
        Enable-LiteDeployLongPaths

        # Initialize WinPE components and network stack
        try { wpeinit.exe 2>$null } catch {}
        # Populate PE boot metadata under HKLM:\SYSTEM\CurrentControlSet\Control
        try { $null = & wpeutil.exe UpdateBootInfo 2>$null } catch {}
        try { $null = & wpeutil.exe InitializeNetwork 2>$null } catch {}
    }

    # Set the title of the console window while LiteDeploy is loading.
    $meta = Get-LiteDeployComponentMetadata
    $componentVersion = $meta.Version
    $componentName = $meta.Name
    $Host.UI.RawUI.WindowTitle = "LiteDeploy v$componentVersion"
    Clear-Host

    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-LiteDeployLog "$componentName Component v$componentVersion" -Level "INIT" -ForegroundColor Cyan
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-LiteDeployLog -Message ''
    if ($isWinPE) {
        Write-LiteDeployLog "WinPE Environment & High Performance Power Plan initialized." -Level "INIT" -ForegroundColor DarkGray
    }

    $bootObj = Get-LiteDeployBootConfig -ConfigPath $ExplicitConfigPath -MountShare -ShowGuiError

    $isMounted = [bool]$bootObj.ShareMounted
    $isMedia = ($bootObj.DeploymentType -eq "Media")

    if ($isMounted -or $isMedia) {
        $enginePath = $bootObj.EngineScriptPath
        if (-not $enginePath -or -not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
            $driveLetter = if ($bootObj.DriveLetter) { $bootObj.DriveLetter } else { "Z:" }
            $localRoot = if ($bootObj.LocalRootName) { $bootObj.LocalRootName } else { "~LiteDeploy" }
            $mode = if ($bootObj.DeploymentType -eq "Media") { "Media" } else { "Network" }
            $enginePath = Resolve-LiteDeployEnginePath -RootPath $driveLetter -LocalRootName $localRoot -DeploymentType $mode
        }

        if ($enginePath -and (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
            Write-LiteDeployLog "Launching LiteDeploy.PE.Engine.ps1..." -Level "INFO" -ForegroundColor Cyan
            try {
                $null = & $enginePath -BootObject $bootObj
            }
            catch {
                Write-LiteDeployLog "Execution failed for '$($enginePath)': $_" -Level "ERROR" -ForegroundColor Red
                Write-Warning "Engine script execution failed: $_"
                if ($isWinPE -or $ShowGuiError) {
                    # Discard dialog return ($false for OK) so it does not print to the host.
                    $null = Show-LiteDeployGuiError -Message "Engine Script Execution Failed: $($enginePath) encountered an unhandled error:`n`n$_" -Title "LiteDeploy - Execution Error"
                }
                Write-LiteDeployPauseNotice -Reason "Deployment engine failed with an unhandled error."
            }
        }
        else {
            $targetPath = if ($enginePath) { $enginePath } else { "Z:\Engine\Runtime\LiteDeploy.PE.Engine.ps1" }
            Write-LiteDeployLog "LiteDeploy.PE.Engine.ps1 was not found on the deployment source." -Level "ERROR" -ForegroundColor Red
            if ($isWinPE -or $ShowGuiError) {
                $null = Show-LiteDeployGuiError -Message "Unable to locate LiteDeploy.PE.Engine.ps1.`n`nPath: $($targetPath)`n`nConfirm the file exists on the share or USB media." -Title "LiteDeploy - Script Missing"
            }
            Write-LiteDeployPauseNotice
        }
    }
    else {
        Write-LiteDeployPauseNotice
    }
}
