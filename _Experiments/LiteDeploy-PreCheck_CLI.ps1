<#
.SYNOPSIS
    LiteDeploy WinPE System Pre-Check Engine.

.DESCRIPTION
    Streamlined, highly readable deployment pre-check engine for Windows PE.
    Evaluates minimal imaging prerequisites without halting on individual check failures:
      1. Configuration Discovery (BootConfig.json on WinPE RAM X:\, External USB, or local paths)
      2. Active Network Hardware Recognition (Get-NetAdapter & .NET fallback)
      3. IPv4 Address Assignment (DHCP/Static polling)
      4. Deployment Mode Identification (Network or Media (Local))
      5. Deployment Server Reachability (SMB TCP 445 connectivity)
      6. Hard Drive Availability (WinPE-StorageWMI / Win32_DiskDrive, non-USB target drives)
      7. System Memory Allocation (Physical RAM capacity check)
      8. System Environment & Platform Security (BIOS Mode UEFI/Legacy, Secure Boot, TPM 2.0)

.NOTES
    Compatible with Set-StrictMode 2.0 and WinPE 5.1/10/11.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$DeploymentShare = "",

    [Parameter(Mandatory = $false)]
    [int]$MaxNetworkWaitSeconds = 30,

    [Parameter(Mandatory = $false)]
    [int]$NetworkPollMilliseconds = 500,

    [Parameter(Mandatory = $false)]
    [int]$SmbConnectTimeoutMilliseconds = 2000,

    [Parameter(Mandatory = $false)]
    [int]$MinDiskSizeGB = 32,

    [Parameter(Mandatory = $false)]
    [int]$MinMemoryGB = 4,

    [Parameter(Mandatory = $false)]
    [bool]$HaltOnFailure = $true
)

# ==============================================================================
# 1. CONSTANTS & SCRIPT STATE
# ==============================================================================
$cTL = [char]0x250C; $cTR = [char]0x2510; $cBL = [char]0x2514
$cBR = [char]0x2518; $cHZ = [char]0x2500; $cVT = [char]0x2502

$script:Summary = New-Object System.Collections.Generic.List[object]
$script:ProgressAnchor = $null
$global:PreCheckPassed = $true

# ==============================================================================
# 2. UI & FORMATTING HELPERS
# ==============================================================================

function Write-Header {
    param([string]$Title, [string]$SubTitle)
    $Width = 64
    $Prefix = [string]$cTL + [string]$cHZ + " $Title "
    $Line1 = $Prefix + (New-Object System.String($cHZ, [Math]::Max(1, ($Width - $Prefix.Length - 1)))) + [string]$cTR
    $Line2 = [string]$cVT + " " + $SubTitle.PadRight([Math]::Max(1, ($Width - 3))) + [string]$cVT
    $Line3 = [string]$cBL + (New-Object System.String($cHZ, ($Width - 2))) + [string]$cBR

    Write-Host " $Line1" -ForegroundColor Cyan
    Write-Host " $Line2" -ForegroundColor White
    Write-Host " $Line3" -ForegroundColor Cyan
}

function Write-Status {
    param([string]$Message, [string]$Status = "INFO", [string]$ValueColor = "White")
    $tagColor = switch ($Status) {
        "OK" { "Green" }
        "FAIL" { "Red" }
        "WARN" { "Yellow" }
        default { "Cyan" }
    }
    
    Write-Host (" [" + $Status + "]").PadRight(10) -ForegroundColor $tagColor -NoNewline

    if ($Message -like "*:*") {
        $parts = $Message.Split(':', 2)
        Write-Host " $($parts[0]):" -ForegroundColor Gray -NoNewline
        $valColor = if ($Status -eq "WARN") { "Yellow" } elseif ($Status -eq "FAIL") { "Red" } else { $ValueColor }
        Write-Host "$($parts[1])" -ForegroundColor $valColor
    }
    else {
        Write-Host " $Message" -ForegroundColor White
    }
}

function Write-Banner {
    param([string]$Message)
    $Line = New-Object System.String($cHZ, [Math]::Max(1, (61 - $Message.Length)))
    Write-Host "`n $([string]$cHZ)$([string]$cHZ) $Message $Line" -ForegroundColor Gray
}

function Add-SummaryItem {
    param([string]$Message, [string]$Status = "INFO")
    if ($null -eq $script:Summary) { $script:Summary = New-Object System.Collections.Generic.List[object] }
    $script:Summary.Add([PSCustomObject]@{ Status = $Status; Message = $Message })
}

function Update-Progress {
    param([int]$Percent, [string]$Message)
    $rawUI = $Host.UI.RawUI
    if ($null -eq $script:ProgressAnchor) {
        Write-Host ""
        try { $script:ProgressAnchor = $rawUI.CursorPosition } catch { $script:ProgressAnchor = New-Object System.Management.Automation.Host.Coordinates 0, 0 }
    }
    
    $savedCursor = $null
    try { $savedCursor = $rawUI.CursorPosition } catch {}
    if ($null -ne $script:ProgressAnchor -and $null -ne $savedCursor) { try { $rawUI.CursorPosition = $script:ProgressAnchor } catch {} }

    $width = [Math]::Max(10, ($rawUI.BufferSize.Width - 1))
    $msg = "  $Message".PadRight($width)
    if ($msg.Length -gt $width) { $msg = $msg.Substring(0, $width) }
    Write-Host $msg -ForegroundColor Gray

    $barColor = if ($Percent -ge 100) { "Green" } else { "Cyan" }
    if (Get-Command Write-HostShellProgress -ErrorAction SilentlyContinue) {
        try { Write-HostShellProgress -Percent $Percent -Width 60 -CompletedColor $barColor } catch {
            $done = New-Object System.String("#", [Math]::Floor($Percent / 100 * 40))
            Write-Host "  [$done$(New-Object System.String('-', (40 - $done.Length)))] $Percent%" -ForegroundColor $barColor
        }
    }
    else {
        $done = New-Object System.String("#", [Math]::Floor($Percent / 100 * 40))
        Write-Host "  [$done$(New-Object System.String('-', (40 - $done.Length)))] $Percent%" -ForegroundColor $barColor
    }

    if ($null -ne $savedCursor) { try { $rawUI.CursorPosition = $savedCursor } catch {} }
}

# ==============================================================================
# 3. ASSESSMENT CHECKS
# ==============================================================================

function Test-NetworkHardware {
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

        if (-not [string]::IsNullOrWhiteSpace($nicName)) {
            Add-SummaryItem -Status "OK" -Message "Network Adapter: Connected ($nicName)"; return $true
        }
        elseif ($nics) {
            Add-SummaryItem -Status "OK" -Message "Network Adapter: Connected"; return $true
        }
        else {
            Add-SummaryItem -Status "FAIL" -Message "Network Adapter: Not connected"; return $false
        }
    }
    catch {
        Add-SummaryItem -Status "FAIL" -Message "Network Adapter: Unable to detect."; return $false
    }
}

function Test-NetworkIPAddress {
    param([int]$TimeoutSeconds, [int]$PollIntervalMs)
    try {
        $ipAddress = ""
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            try {
                $nics = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object { $_.NetworkInterfaceType -ne 'Loopback' -and $_.OperationalStatus -eq 'Up' }
                foreach ($nic in $nics) {
                    foreach ($addr in $nic.GetIPProperties().UnicastAddresses) {
                        if ($addr.Address.AddressFamily -eq 'InterNetwork') {
                            $ipStr = $addr.Address.IPAddressToString
                            if ($ipStr -notlike "169.254.*" -and $ipStr -ne "127.0.0.1") { $ipAddress = $ipStr; break }
                        }
                    }
                    if ($ipAddress -ne "") { break }
                }
            }
            catch {}
            if ($ipAddress -ne "") { break }
            Start-Sleep -Milliseconds $PollIntervalMs
        }

        if ($ipAddress -ne "") { Add-SummaryItem -Status "OK" -Message "IPv4 Address: $ipAddress"; return $true }
        else { Add-SummaryItem -Status "FAIL" -Message "IPv4 Address: Not detected (Timeout $TimeoutSeconds s)."; return $false }
    }
    catch {
        Add-SummaryItem -Status "FAIL" -Message "IPv4 Address: Unable to detect."; return $false
    }
}

function Test-DeploymentShare {
    param([string]$SharePath, [int]$TimeoutMs, [string]$Mode = "Network")
    try {
        if ($Mode -eq "Media" -or [string]::IsNullOrWhiteSpace($SharePath)) { return $true }
        $server = $SharePath.TrimStart('\').Split('\')[0]
        $smbOK = $false
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $connect = $tcp.BeginConnect($server, 445, $null, $null)
            if ($connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { $tcp.EndConnect($connect); $smbOK = $true }
            else { $tcp.Close() }
        }
        catch { $smbOK = $false } finally { $tcp.Dispose() }

        $serverLabel = if (-not [string]::IsNullOrWhiteSpace($server)) { " ($server)" } else { "" }
        if (-not $smbOK) {
            Add-SummaryItem -Status "FAIL" -Message "Deployment Server: Unreachable$serverLabel on SMB Port 445."; return $false
        }
        Add-SummaryItem -Status "OK" -Message "Deployment Server: Reachable$serverLabel."
        return $true
    }
    catch {
        Add-SummaryItem -Status "FAIL" -Message "Deployment Server: Unable to test reachability."; return $false
    }
}

function Test-InternalStorage {
    param([int]$MinCapacityGB)
    try {
        $diskItems = @()
        if (Get-Command Get-Disk -ErrorAction SilentlyContinue) {
            try {
                $disks = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -ne "USB" -and $_.OperationalStatus -eq "Online" } | Sort-Object Number
                foreach ($d in $disks) {
                    $sz = if ($d.Size -and [double]$d.Size -gt 0) { [math]::Round([double]$d.Size / 1GB, 0) } elseif ($d.AllocatedSize) { [math]::Round([double]$d.AllocatedSize / 1GB, 0) } else { 0 }
                    $model = if ($d.Model) { $d.Model.Trim() } elseif ($d.FriendlyName) { $d.FriendlyName.Trim() } else { "Internal Drive" }
                    $diskItems += [PSCustomObject]@{ Number = $d.Number; Model = $model; SizeGB = $sz }
                }
            }
            catch {}
        }
        if ($diskItems.Count -eq 0) {
            try {
                $wmiDisks = Get-WmiObject Win32_DiskDrive -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceType -ne "USB" -and $_.MediaType -notlike "*Removable*" } | Sort-Object Index
                foreach ($d in $wmiDisks) {
                    $sz = if ($d.Size) { [math]::Round([double]$d.Size / 1GB, 0) } else { 0 }
                    $model = if ($d.Model) { $d.Model.Trim() } else { "Internal Drive" }
                    $idx = if ($null -ne $d.Index) { $d.Index } else { 0 }
                    $diskItems += [PSCustomObject]@{ Number = $idx; Model = $model; SizeGB = $sz }
                }
            }
            catch {}
        }

        if ($diskItems.Count -eq 0) {
            Add-SummaryItem -Status "FAIL" -Message "Hard Drive Available: Not Detected"; return $false
        }

        $validCount = 0
        foreach ($item in $diskItems) {
            $szText = if ($item.SizeGB -gt 0) { " ($($item.SizeGB) GB)" } else { "" }
            $status = "OK"
            if ($item.SizeGB -gt 0 -and $item.SizeGB -lt $MinCapacityGB) {
                $status = "FAIL"; $szText += " [Below min $MinCapacityGB GB]"
            }
            else { $validCount++ }
            Add-SummaryItem -Status $status -Message "Hard Drive Available: Disk $($item.Number) - $($item.Model)$szText"
        }
        return ($validCount -gt 0)
    }
    catch {
        Add-SummaryItem -Status "FAIL" -Message "Hard Drive Available: Not Detected"; return $false
    }
}

function Test-SystemMemory {
    param([int]$MinRAMGB)
    try {
        $ramBytes = 0
        $wmiRam = Get-WmiObject Win32_PhysicalMemory -ErrorAction SilentlyContinue
        if ($wmiRam) { foreach ($chip in $wmiRam) { $ramBytes += [double]$chip.Capacity } }
        if ($ramBytes -gt 0) {
            $ramGB = [math]::Round($ramBytes / 1GB, 1)
            $status = if ($ramGB -ge $MinRAMGB) { "OK" } else { "WARN" }
            Add-SummaryItem -Status $status -Message "System RAM: $ramGB GB"
            return ($ramGB -ge $MinRAMGB)
        }
        return $true
    }
    catch { return $true }
}

function Test-SystemEnvironment {
    try {
        $fw = $env:firmware_type; if ([string]::IsNullOrWhiteSpace($fw)) { $fw = "Unknown" }
        if ($fw -eq "UEFI") {
            Add-SummaryItem -Status "OK" -Message "BIOS Mode: UEFI"
            $sbState = "Unknown"
            if (Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue) {
                try { if (Confirm-SecureBootUEFI -ErrorAction Stop) { $sbState = "Enabled" } else { $sbState = "Disabled" } } catch {}
            }
            if ($sbState -eq "Unknown") {
                try {
                    $sbReg = Get-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\SecureBoot\State" -Name "UEFISecureBootEnabled" -ErrorAction SilentlyContinue
                    if ($null -ne $sbReg -and $sbReg.UEFISecureBootEnabled -eq 1) { $sbState = "Enabled" }
                    elseif ($null -ne $sbReg -and $sbReg.UEFISecureBootEnabled -eq 0) { $sbState = "Disabled" }
                }
                catch {}
            }

            if ($sbState -eq "Enabled") { Add-SummaryItem -Status "OK" -Message "Secure Boot: Enabled" }
            elseif ($sbState -eq "Disabled") { Add-SummaryItem -Status "WARN" -Message "Secure Boot: Disabled" }
            else { Add-SummaryItem -Status "WARN" -Message "Secure Boot: Unknown / Unsupported" }
        }
        else {
            Add-SummaryItem -Status "WARN" -Message "BIOS Mode: $fw (Legacy BIOS)"
        }

        if (Get-Command Get-Tpm -ErrorAction SilentlyContinue) {
            try {
                $tpm = Get-Tpm -ErrorAction SilentlyContinue
                if ($tpm -and $tpm.TpmPresent) { Add-SummaryItem -Status "OK" -Message "TPM Security Module: Present and Enabled" }
                else { Add-SummaryItem -Status "WARN" -Message "TPM Security Module: Not Present or Disabled" }
            }
            catch {}
        }
        return $true
    }
    catch {
        Add-SummaryItem -Status "WARN" -Message "System Environment: Unable to detect full specifications."; return $true
    }
}

# ==============================================================================
# 4. MAIN CONTROLLER
# ==============================================================================

# Step 1: Load HostShell UI toolkit immediately for instant window framing
$HostShellPath = "$PSScriptRoot\LiteDeploy-HostShell.ps1"
if (Test-Path $HostShellPath) {
    try {
        . $HostShellPath
        Set-HostShellWindow -Position Center -WidthPercent 40 -HeightPercent 40 -Title "LiteDeploy | System Pre-Check" -Prompt "" -HideScrollBars
        Set-HostShellWindowStyle -WindowStyle Minimal
        Set-HostShellWindow -Action Restore
    }
    catch {}
}

# Step 2: Render initial UI header & progress bar IMMEDIATELY (<50ms feedback)
Clear-Host
$global:PreCheckPassed = $true
$script:Summary = New-Object System.Collections.Generic.List[object]

Write-Header -Title "LiteDeploy v1.0" -SubTitle "System Pre-Check"
Update-Progress -Percent 5 -Message "Initializing environment & discovering configuration..."

# Step 3: WinPE Detection & Configuration Discovery (Priority 1: RAM X:\, Priority 2: External USB, Priority 3: Local Script/PWD)
$isWinPE = Test-Path -Path "HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT" -ErrorAction SilentlyContinue
$PossibleConfigPaths = @()
if ($isWinPE) {
    $PossibleConfigPaths += "X:\~LiteDeploy\Config\BootConfig.json"
    $PossibleConfigPaths += "X:\BootConfig.json"
}

try {
    $usbLetters = @()
    if (Get-Command Get-Volume -ErrorAction SilentlyContinue) {
        Get-Volume -ErrorAction SilentlyContinue | Where-Object { ($_.DriveType -eq 'Removable' -or $_.DriveType -eq 'CD-ROM' -or $_.DriveType -eq 'CDROM') -and $_.DriveLetter } | ForEach-Object {
            $r = "$($_.DriveLetter):"; if ($usbLetters -notcontains $r) { $usbLetters += $r }
        }
    }
    if (Get-Command Get-Disk -ErrorAction SilentlyContinue) {
        Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -eq "USB" } | Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object {
            $r = "$($_.DriveLetter):"; if ($usbLetters -notcontains $r) { $usbLetters += $r }
        }
    }
    foreach ($r in $usbLetters) {
        $PossibleConfigPaths += "$r\~LiteDeploy\Config\BootConfig.json"
        $PossibleConfigPaths += "$r\BootConfig.json"
        $PossibleConfigPaths += "$r\Config\BootConfig.json"
    }
}
catch {}

$PossibleConfigPaths += (Join-Path $PSScriptRoot "Config\BootConfig.json")
$PossibleConfigPaths += (Join-Path $PSScriptRoot "BootConfig.json")
$PossibleConfigPaths += (Join-Path $PWD "Config\BootConfig.json")
$PossibleConfigPaths += (Join-Path $PWD "BootConfig.json")

$FoundConfigPath = $null
foreach ($path in $PossibleConfigPaths) {
    if (Test-Path -LiteralPath $path -PathType Leaf) { $FoundConfigPath = $path; break }
}

$appName = "LiteDeploy"; $appVersion = "1.0"; $envName = ""; $deploymentType = $null; $configFound = $false; $cfg = $null

if ($FoundConfigPath) {
    try {
        $jsonContent = Get-Content -LiteralPath $FoundConfigPath -Raw -ErrorAction SilentlyContinue
        if ($jsonContent) {
            $parsedCfg = $jsonContent | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($parsedCfg) {
                $cfg = $parsedCfg
                $configFound = $true
                if ($cfg.Metadata) {
                    if ($cfg.Metadata.Name) { $appName = $cfg.Metadata.Name }
                    if ($cfg.Metadata.Environment) { $envName = $cfg.Metadata.Environment }
                    if ($cfg.Metadata.Version) { $appVersion = $cfg.Metadata.Version }
                }
                if ($cfg.Deployment) {
                    if ($cfg.Deployment.Type) { $deploymentType = $cfg.Deployment.Type }
                    if ($cfg.Deployment.NetworkPath -and (-not $PSBoundParameters.ContainsKey('DeploymentShare'))) {
                        $DeploymentShare = $cfg.Deployment.NetworkPath
                    }
                }
            }
        }
    }
    catch {}
}

# Dynamic Window Title Update if Environment Metadata is Specified
if (-not [string]::IsNullOrWhiteSpace($envName)) {
    if (Get-Command Set-HostShellWindow -ErrorAction SilentlyContinue) {
        try { Set-HostShellWindow -Title "$appName - Running $envName" } catch {}
    }
}

# Check for SkipHardwarePreCheck / SkipPreCheck flag
$skipPreCheck = $false
if ($null -ne $cfg -and $null -ne $cfg.Startup) {
    if ($cfg.Startup.SkipHardwarePreCheck -eq $true -or $cfg.Startup.SkipHardwarePreCheck -eq "true" -or
        $cfg.Startup.SkipPreCheck -eq $true -or $cfg.Startup.SkipPreCheck -eq "true") {
        $skipPreCheck = $true
    }
}
if ($skipPreCheck) {
    # Erase progress bar lines from console so no percentage (5%) is displayed on bypass
    if ($null -ne $script:ProgressAnchor) {
        try {
            $rawUI = $Host.UI.RawUI
            $rawUI.CursorPosition = $script:ProgressAnchor
            $blank = New-Object System.String(' ', [Math]::Max(10, ($rawUI.BufferSize.Width - 1)))
            Write-Host $blank
            Write-Host $blank
            $rawUI.CursorPosition = $script:ProgressAnchor
        }
        catch {}
    }

    Write-Banner -Message "PRE-CHECK BYPASSED"
    Write-Host ""
    Write-Status -Status "INFO" -Message "Pre-Check: Bypassed via configuration (SkipHardwarePreCheck = true)"
    Write-Host ""
    Write-Host "     [ SKIPPED ] SYSTEM PRE-CHECK BYPASSED BY POLICY  " -BackgroundColor Yellow -ForegroundColor Black
    Write-Host ""
    Start-Sleep -Seconds 1
    return
}

# Sequential Non-Blocking Assessment Loop
Update-Progress -Percent 15 -Message "Scanning for active network hardware..."
if (-not (Test-NetworkHardware)) { $global:PreCheckPassed = $false }

Update-Progress -Percent 40 -Message "Awaiting IPv4 address assignment..."
if (-not (Test-NetworkIPAddress -TimeoutSeconds $MaxNetworkWaitSeconds -PollIntervalMs $NetworkPollMilliseconds)) { $global:PreCheckPassed = $false }

if ($configFound) {
    if ($deploymentType -eq "Media") {
        Add-SummaryItem -Status "OK" -Message "Deployment Mode: Media (Local)"
    }
    elseif ($deploymentType -eq "Network") {
        if ([string]::IsNullOrWhiteSpace($DeploymentShare)) {
            Add-SummaryItem -Status "FAIL" -Message "Deployment Mode: Network (Misconfigured - Missing NetworkPath)"
            $global:PreCheckPassed = $false
        }
        else {
            Add-SummaryItem -Status "OK" -Message "Deployment Mode: Network"
        }
    }
    else {
        Add-SummaryItem -Status "WARN" -Message "Deployment Mode: $deploymentType"
    }
}
else {
    Add-SummaryItem -Status "FAIL" -Message "Deployment Mode: Configuration File Not Found"
    $global:PreCheckPassed = $false
}

Update-Progress -Percent 65 -Message "Testing deployment share connectivity..."
if (-not (Test-DeploymentShare -SharePath $DeploymentShare -TimeoutMs $SmbConnectTimeoutMilliseconds -Mode $deploymentType)) { $global:PreCheckPassed = $false }

Update-Progress -Percent 85 -Message "Validating internal storage & system RAM..."
if (-not (Test-InternalStorage -MinCapacityGB $MinDiskSizeGB)) { $global:PreCheckPassed = $false }
Test-SystemMemory -MinRAMGB $MinMemoryGB | Out-Null

Update-Progress -Percent 95 -Message "Analyzing firmware & Secure Boot..."
if (-not (Test-SystemEnvironment)) { $global:PreCheckPassed = $false }

# Complete Progress & Render Summary
Update-Progress -Percent 100 -Message "Pre-Check complete."
Write-Host ""

Write-Banner -Message "ASSESSMENT SUMMARY"
Write-Host "`n System Pre-Check Checklist:" -ForegroundColor Cyan
$divider = New-Object System.String($cHZ, 64)
Write-Host " $divider" -ForegroundColor Gray

foreach ($item in $script:Summary) {
    Write-Status -Status $item.Status -Message $item.Message
}
Write-Host " $divider" -ForegroundColor Gray
Write-Host ""

# Final Status Banner & Troubleshooting Action
if ($global:PreCheckPassed) {
    Write-Host "     [ SUCCESS ] SYSTEM READY FOR IMAGE DEPLOYMENT  " -BackgroundColor Green -ForegroundColor Black
    Write-Host ""
    Start-Sleep -Seconds 5 
    Set-HostShellWindow -Action Hide
    $cred = Get-Credential 
    Set-HostShellWindow -Action Restore


    
}
else {
    Write-Host "     [ FAILURE ] CRITICAL PRE-CHECK ISSUES DETECTED  " -BackgroundColor Red -ForegroundColor Black
    Write-Host ""
    if ($HaltOnFailure) {
        Write-Host " Opening troubleshooting shell for manual diagnostics..." -ForegroundColor Yellow
        cmd.exe /k
    }
}
