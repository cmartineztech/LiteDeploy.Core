<#
.SYNOPSIS
    LiteDeploy Hardware inventory helpers (WinPE-first).

.DESCRIPTION
    Importable module of simple Get-Hardware* getters for identity, firmware,
    TPM, memory, CPU, NICs, disks, and a composed Get-HardwareInventory.
    Conserves gather logic used by HardwarePreCheck (WMI/CIM fallbacks).

.NOTES
    Compatible with Set-StrictMode 2.0, PowerShell 5.1+, and WinPE 5.1/10/11.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Metadata
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ==============================================================================
# COMPONENT METADATA
# ==============================================================================

function Get-LiteDeployComponentMetadata {
    return [PSCustomObject]@{
        ComponentId          = "Hardware"
        Name                 = "LiteDeploy Hardware"
        Version              = "1.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "WinPE"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @()
        Description          = "WinPE-first Get-Hardware* helpers and inventory composition for LiteDeploy."
    }
}

if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

# ==============================================================================
# PRIVATE CACHE
# ==============================================================================

$script:HardwareCache = @{}

function Clear-HardwareCache {
    $script:HardwareCache = @{}
}

function Get-HardwareCached {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Factory
    )
    if ($script:HardwareCache.ContainsKey($Key)) {
        return $script:HardwareCache[$Key]
    }
    $value = & $Factory
    $script:HardwareCache[$Key] = $value
    return $value
}

function Get-HardwareCimOrWmi {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClassName,
        [string]$Namespace = "root\cimv2"
    )
    try {
        if ($Namespace -eq "root\cimv2") {
            return @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop)
        }
        return @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop)
    }
    catch {
        try {
            if ($Namespace -eq "root\cimv2") {
                return @(Get-WmiObject -Class $ClassName -ErrorAction Stop)
            }
            return @(Get-WmiObject -Namespace $Namespace -Class $ClassName -ErrorAction Stop)
        }
        catch {
            return @()
        }
    }
}

# ==============================================================================
# IDENTITY
# ==============================================================================

function Test-HardwareIdentityJunk {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    return [bool]($Value -match '^(System SKU|SKU|None|N/A|Default string|To Be Filled|Invalid)')
}

function Get-HardwareVendorRaw {
    $cs = Get-HardwareCached -Key "ComputerSystem" -Factory { Get-HardwareCimOrWmi -ClassName "Win32_ComputerSystem" | Select-Object -First 1 }
    if ($cs -and $cs.Manufacturer) { return $cs.Manufacturer.Trim() }
    return $null
}

function Get-HardwareVendor {
    $raw = Get-HardwareVendorRaw
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    if ($raw -like "*Dell*") { return "Dell" }
    if ($raw -like "*HP*" -or $raw -like "*Hewlett*") { return "HP" }
    if ($raw -like "*Lenovo*") { return "Lenovo" }
    return $raw
}

function Get-HardwareBaseBoardProduct {
    <#
    .SYNOPSIS
        Returns Win32_BaseBoard.Product (HP platform ID / common SKU fallback).
    #>
    $board = Get-HardwareCached -Key "BaseBoard" -Factory { Get-HardwareCimOrWmi -ClassName "Win32_BaseBoard" | Select-Object -First 1 }
    if ($board -and $board.PSObject.Properties["Product"] -and $board.Product) {
        $product = [string]$board.Product.Trim()
        if (-not (Test-HardwareIdentityJunk -Value $product)) { return $product }
    }
    return $null
}

function Get-HardwareModel {
    <#
    .SYNOPSIS
        Returns the computer model. Lenovo uses the marketing name from
        Win32_ComputerSystemProduct.Version when available (matches DynamicDriverDownload).
    #>
    $cs = Get-HardwareCached -Key "ComputerSystem" -Factory { Get-HardwareCimOrWmi -ClassName "Win32_ComputerSystem" | Select-Object -First 1 }
    $csModel = if ($cs -and $cs.Model) { [string]$cs.Model.Trim() } else { $null }

    $vendor = Get-HardwareVendor
    if ($vendor -eq "Lenovo") {
        $product = Get-HardwareCached -Key "ComputerSystemProduct" -Factory { Get-HardwareCimOrWmi -ClassName "Win32_ComputerSystemProduct" | Select-Object -First 1 }
        if ($product -and $product.PSObject.Properties["Version"] -and $product.Version) {
            $productName = [string]$product.Version.Trim()
            if (-not [string]::IsNullOrWhiteSpace($productName)) { return $productName }
        }
    }

    return $csModel
}

function Get-HardwareComputerSku {
    <#
    .SYNOPSIS
        Returns the catalog-oriented system SKU (aligned with DynamicDriverDownload).

    .NOTES
        - Lenovo: machine type from LENOVO_MT_XXXX or first 4 chars of CS model
        - HP: Win32_BaseBoard.Product (platform ID)
        - Others: SystemSKUNumber, then BIOS registry, then baseboard product
    #>
    $vendor = Get-HardwareVendor
    $cs = Get-HardwareCached -Key "ComputerSystem" -Factory { Get-HardwareCimOrWmi -ClassName "Win32_ComputerSystem" | Select-Object -First 1 }
    $csModel = if ($cs -and $cs.Model) { [string]$cs.Model.Trim() } else { $null }

    $systemSku = $null
    if ($cs -and $cs.PSObject.Properties["SystemSKUNumber"] -and $cs.SystemSKUNumber) {
        $candidate = [string]$cs.SystemSKUNumber.Trim()
        if (-not (Test-HardwareIdentityJunk -Value $candidate)) { $systemSku = $candidate }
    }

    $regSku = $null
    try {
        $reg = Get-ItemProperty "HKLM:\HARDWARE\DESCRIPTION\System\BIOS" -ErrorAction SilentlyContinue
        if ($reg -and $reg.PSObject.Properties["SystemSKU"] -and $reg.SystemSKU) {
            $candidate = [string]$reg.SystemSKU.Trim()
            if (-not (Test-HardwareIdentityJunk -Value $candidate)) { $regSku = $candidate }
        }
    }
    catch {}

    if ($vendor -eq "Lenovo") {
        $raw = if ($systemSku) { $systemSku } else { $regSku }
        if ($raw -and $raw -match 'LENOVO_MT_(\w{4})') {
            return $Matches[1].ToUpperInvariant()
        }
        if ($csModel -and $csModel -match '^(\w{4})') {
            return $Matches[1].ToUpperInvariant()
        }
        if ($raw) { return $raw.ToUpperInvariant() }
        $board = Get-HardwareBaseBoardProduct
        if ($board) { return $board.ToUpperInvariant() }
        return $null
    }

    if ($vendor -eq "HP") {
        $board = Get-HardwareBaseBoardProduct
        if ($board) { return $board.ToUpperInvariant() }
        if ($systemSku) { return $systemSku.ToUpperInvariant() }
        if ($regSku) { return $regSku.ToUpperInvariant() }
        return $null
    }

    if ($systemSku) { return $systemSku.ToUpperInvariant() }
    if ($regSku) { return $regSku.ToUpperInvariant() }
    $board = Get-HardwareBaseBoardProduct
    if ($board) { return $board.ToUpperInvariant() }
    return $null
}

function Get-HardwareSerialNumber {
    $bios = Get-HardwareCached -Key "BIOS" -Factory { Get-HardwareCimOrWmi -ClassName "Win32_BIOS" | Select-Object -First 1 }
    if ($bios -and $bios.SerialNumber) { return $bios.SerialNumber.Trim() }
    $product = Get-HardwareCached -Key "ComputerSystemProduct" -Factory { Get-HardwareCimOrWmi -ClassName "Win32_ComputerSystemProduct" | Select-Object -First 1 }
    if ($product -and $product.IdentifyingNumber) { return $product.IdentifyingNumber.Trim() }
    return $null
}

function Get-HardwareUUID {
    $product = Get-HardwareCached -Key "ComputerSystemProduct" -Factory { Get-HardwareCimOrWmi -ClassName "Win32_ComputerSystemProduct" | Select-Object -First 1 }
    if ($product -and $product.UUID) { return $product.UUID.Trim() }
    return $null
}

function Get-HardwareAssetTag {
    $enclosure = Get-HardwareCached -Key "SystemEnclosure" -Factory { Get-HardwareCimOrWmi -ClassName "Win32_SystemEnclosure" | Select-Object -First 1 }
    if ($enclosure -and $enclosure.SMBIOSAssetTag) {
        $tag = [string]$enclosure.SMBIOSAssetTag.Trim()
        if ($tag -and $tag -notmatch '^(Asset Tag|None|N/A|To Be Filled)') { return $tag }
    }
    return $null
}

function Get-HardwareComputerName {
    if ($env:COMPUTERNAME) { return $env:COMPUTERNAME }
    try { return [Environment]::MachineName } catch { return $null }
}

function Get-HardwareArchitecture {
    if ($env:PROCESSOR_ARCHITECTURE) { return $env:PROCESSOR_ARCHITECTURE.ToUpperInvariant() }
    if ([Environment]::Is64BitOperatingSystem) { return "AMD64" }
    return "X86"
}

function Get-HardwareChassis {
    $enclosure = Get-HardwareCached -Key "SystemEnclosure" -Factory { Get-HardwareCimOrWmi -ClassName "Win32_SystemEnclosure" | Select-Object -First 1 }
    if (-not $enclosure) { return "Other" }
    $types = @($enclosure.ChassisTypes)
    $laptopTypes = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $desktopTypes = @(3, 4, 5, 6, 7, 15, 16)
    if ($types | Where-Object { $laptopTypes -contains $_ }) { return "Laptop" }
    if ($types | Where-Object { $desktopTypes -contains $_ }) { return "Desktop" }
    return "Other"
}

function Get-HardwareIsLaptop { return ((Get-HardwareChassis) -eq "Laptop") }
function Get-HardwareIsDesktop { return ((Get-HardwareChassis) -eq "Desktop") }

function Get-HardwareIsVM {
    $cs = Get-HardwareCached -Key "ComputerSystem" -Factory { Get-HardwareCimOrWmi -ClassName "Win32_ComputerSystem" | Select-Object -First 1 }
    if (-not $cs) { return $false }
    $blob = ("$($cs.Model) $($cs.Manufacturer)").ToLowerInvariant()
    return [bool]($blob -match "virtual|vmware|virtualbox|hyper-v|kvm|xen|parallels|qemu")
}

function Get-HardwareIsWinPE {
    return [bool](Test-Path -Path "HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT" -ErrorAction SilentlyContinue)
}

function Get-HardwareSystemDrive {
    if ($env:SystemDrive) { return $env:SystemDrive }
    return "X:"
}

function Get-HardwareDriverFolderHint {
    $vendor = Get-HardwareVendor
    $model = Get-HardwareModel
    if ([string]::IsNullOrWhiteSpace($vendor) -or [string]::IsNullOrWhiteSpace($model)) { return $null }
    return "$vendor\$model"
}

# ==============================================================================
# FIRMWARE / SECURITY
# ==============================================================================

function Get-HardwareFirmwareType {
    if ($env:firmware_type) { return $env:firmware_type }
    return "Unknown"
}

function Get-HardwareIsUEFI {
    return ((Get-HardwareFirmwareType) -eq "UEFI")
}

function Get-HardwareBiosVersion {
    $bios = Get-HardwareCached -Key "BIOS" -Factory { Get-HardwareCimOrWmi -ClassName "Win32_BIOS" | Select-Object -First 1 }
    if (-not $bios) { return $null }
    if ($bios.SMBIOSBIOSVersion) { return $bios.SMBIOSBIOSVersion.Trim() }
    if ($bios.Version) { return [string]$bios.Version }
    return $null
}

function Get-HardwareBiosReleaseDate {
    $bios = Get-HardwareCached -Key "BIOS" -Factory { Get-HardwareCimOrWmi -ClassName "Win32_BIOS" | Select-Object -First 1 }
    if (-not $bios -or -not $bios.ReleaseDate) { return $null }
    try {
        if ($bios.ReleaseDate -is [datetime]) { return $bios.ReleaseDate.ToString("yyyy-MM-dd") }
        return [string]$bios.ReleaseDate
    }
    catch { return [string]$bios.ReleaseDate }
}

function Get-HardwareSecureBootCertDetails {
    try {
        if (-not (Get-Command Get-SecureBootUEFI -ErrorAction SilentlyContinue)) { return "" }
        $dbBytes = (Get-SecureBootUEFI db -ErrorAction SilentlyContinue).Bytes
        if (-not $dbBytes -or $dbBytes.Count -eq 0) { return "" }
        $dbText = [System.Text.Encoding]::ASCII.GetString($dbBytes)
        $has2011 = $dbText -like "*Microsoft Windows Production PCA 2011*"
        $has2023 = $dbText -like "*Windows UEFI CA 2023*"
        if ($has2011 -and $has2023) { return " (2011/2023 CA Ready)" }
        if ($has2023) { return " (2023 CA Ready)" }
        if ($has2011) { return " (2011 CA Only - BIOS Update Recommended)" }
        return ""
    }
    catch { return "" }
}

function Get-HardwareSecureBootStatus {
    if (-not (Get-HardwareIsUEFI)) { return "N/A" }
    $secureBoot = "Unknown"
    if (Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue) {
        try { $secureBoot = if (Confirm-SecureBootUEFI -ErrorAction Stop) { "Enabled" } else { "Disabled" } } catch {}
    }
    if ($secureBoot -eq "Unknown") {
        $state = Get-ItemProperty "HKLM:\System\CurrentControlSet\Control\SecureBoot\State" -ErrorAction SilentlyContinue
        if ($state) {
            $secureBoot = if ($state.UEFISecureBootEnabled -eq 1) { "Enabled" } else { "Disabled" }
        }
    }
    return $secureBoot
}

function Get-HardwareSecureBootIsEnabled {
    return ((Get-HardwareSecureBootStatus) -eq "Enabled")
}

function Get-HardwareSecureBootDisplay {
    $status = Get-HardwareSecureBootStatus
    if ($status -eq "Enabled") {
        return ("Enabled" + (Get-HardwareSecureBootCertDetails))
    }
    if ($status -eq "N/A") { return $null }
    return $status
}

function Get-HardwareTpmInfo {
    return Get-HardwareCached -Key "TPM" -Factory {
        $firmware = Get-HardwareFirmwareType
        if ($firmware -eq "Legacy" -or $firmware -eq "BIOS") {
            return [PSCustomObject]@{ Present = $false; Version = $null; State = "Not Detected" }
        }

        try {
            $tpm = Get-WmiObject -Namespace "root\cimv2\Security\MicrosoftTpm" -Class Win32_Tpm -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($tpm) {
                $spec = if ($tpm.SpecVersion) { $tpm.SpecVersion.Split(',')[0].Trim() } else { "2.0" }
                $version = if ($spec -like "2.0*") { "TPM 2.0" } elseif ($spec -like "1.2*") { "TPM 1.2" } else { "TPM $spec" }
                $enabled = $false
                try { $enabled = [bool]($tpm.IsEnabled().IsEnabled) } catch { try { $enabled = [bool]$tpm.IsEnabled_InitialValue } catch {} }
                $state = if ($enabled) { "Enabled" } else { "Disabled" }
                return [PSCustomObject]@{ Present = $true; Version = $version; State = $state }
            }
        }
        catch {}

        try {
            $tpmPnp = Get-WmiObject Win32_PnPEntity -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "*Trusted Platform Module*" -or $_.DeviceID -like "*TPM*" } |
                Select-Object -First 1
            if ($tpmPnp) {
                $name = $tpmPnp.Name.Trim()
                $version = if ($name -like "*2.0*") { "TPM 2.0" } elseif ($name -like "*1.2*") { "TPM 1.2" } else { "TPM Present" }
                return [PSCustomObject]@{ Present = $true; Version = $version; State = "Enabled" }
            }
        }
        catch {}

        return [PSCustomObject]@{ Present = $false; Version = $null; State = "Not Detected" }
    }
}

function Get-HardwareTpmPresent { return [bool]((Get-HardwareTpmInfo).Present) }
function Get-HardwareTpmVersion { return (Get-HardwareTpmInfo).Version }
function Get-HardwareTpmState { return (Get-HardwareTpmInfo).State }

function Get-HardwareTpmIsReady {
    $info = Get-HardwareTpmInfo
    return [bool]($info.Present -and $info.Version -like "TPM 2.0*" -and $info.State -eq "Enabled")
}

# ==============================================================================
# MEMORY / CPU
# ==============================================================================

function Get-HardwareMemoryBytes {
    return [long](Get-HardwareCached -Key "MemoryBytes" -Factory {
        $bytes = [long]0
        try {
            Get-WmiObject Win32_PhysicalMemory -ErrorAction SilentlyContinue | ForEach-Object { $bytes += [long]$_.Capacity }
        }
        catch {}
        if ($bytes -le 0) {
            try {
                $os = Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue
                if ($os -and $os.TotalVisibleMemorySize) { $bytes = [long]($os.TotalVisibleMemorySize * 1KB) }
            }
            catch {}
        }
        return $bytes
    })
}

function Get-HardwareMemoryMB {
    $bytes = Get-HardwareMemoryBytes
    if ($bytes -le 0) { return 0 }
    return [int][math]::Round($bytes / 1MB)
}

function Get-HardwareMemoryGB {
    $bytes = Get-HardwareMemoryBytes
    if ($bytes -le 0) { return 0 }
    return [math]::Round($bytes / 1GB, 1)
}

function Get-HardwareProcessor {
    return Get-HardwareCached -Key "Processor" -Factory {
        Get-HardwareCimOrWmi -ClassName "Win32_Processor" | Select-Object -First 1
    }
}

function Get-HardwareProcessorName {
    $cpu = Get-HardwareProcessor
    if ($cpu -and $cpu.Name) { return $cpu.Name.Trim() }
    return $null
}

function Get-HardwareProcessorCores {
    $cpu = Get-HardwareProcessor
    if ($cpu -and $cpu.NumberOfCores) { return [int]$cpu.NumberOfCores }
    return 0
}

function Get-HardwareProcessorLogicalCount {
    $cpu = Get-HardwareProcessor
    if ($cpu -and $cpu.NumberOfLogicalProcessors) { return [int]$cpu.NumberOfLogicalProcessors }
    return 0
}

# ==============================================================================
# NETWORK / DISKS
# ==============================================================================

function Get-HardwareNICs {
    if ($script:HardwareCache.ContainsKey("NICs")) {
        return @($script:HardwareCache["NICs"])
    }

    $list = New-Object System.Collections.Generic.List[object]

    if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
        Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne "Disabled" } | ForEach-Object {
            $mac = if ($_.MacAddress) { ($_.MacAddress -replace '-', ':') } else { $null }
            $speed = $null
            if ($_.LinkSpeed) {
                try { $speed = [int](($_.LinkSpeed -replace '[^\d\.]', '')) } catch {}
            }
            $list.Add([PSCustomObject]@{
                    Name        = $_.Name
                    Description = if ($_.InterfaceDescription) { $_.InterfaceDescription.Trim() } else { $_.Name }
                    MacAddress  = $mac
                    Status      = [string]$_.Status
                    SpeedMbps   = $speed
                })
        }
    }

    if ($list.Count -eq 0) {
        try {
            [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object { $_.NetworkInterfaceType -ne "Loopback" } |
                ForEach-Object {
                    $bytes = $_.GetPhysicalAddress().GetAddressBytes()
                    $mac = if ($bytes -and $bytes.Length -gt 0) { ($bytes | ForEach-Object { $_.ToString("X2") }) -join ":" } else { $null }
                    $list.Add([PSCustomObject]@{
                            Name        = $_.Name
                            Description = $_.Description.Trim()
                            MacAddress  = $mac
                            Status      = [string]$_.OperationalStatus
                            SpeedMbps   = $null
                        })
                }
        }
        catch {}
    }

    $script:HardwareCache["NICs"] = @($list.ToArray())
    return @($script:HardwareCache["NICs"])
}

function Get-HardwarePrimaryNicName {
    $nics = @(Get-HardwareNICs)
    if ($nics.Count -eq 0) { return $null }
    $up = $nics | Where-Object { $_.Status -eq "Up" -or $_.Status -eq "Connected" } | Select-Object -First 1
    $nic = if ($up) { $up } else { $nics[0] }
    if ($nic.Description) { return $nic.Description }
    return $nic.Name
}

function Get-HardwarePrimaryMacAddress {
    $nics = @(Get-HardwareNICs)
    if ($nics.Count -eq 0) { return $null }
    $up = $nics | Where-Object { ($_.Status -eq "Up" -or $_.Status -eq "Connected") -and $_.MacAddress } | Select-Object -First 1
    if ($up) { return $up.MacAddress }
    $any = $nics | Where-Object { $_.MacAddress } | Select-Object -First 1
    if ($any) { return $any.MacAddress }
    return $null
}

function Get-HardwareIPAddresses {
    param(
        [int]$TimeoutSeconds = 0,
        [int]$PollMilliseconds = 500
    )

    $ipv4 = ""
    $ipv4Prefix = $null
    $ipv6 = ""
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            $adapters = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object { $_.NetworkInterfaceType -ne "Loopback" -and $_.OperationalStatus -eq "Up" }
            foreach ($adapter in $adapters) {
                foreach ($address in $adapter.GetIPProperties().UnicastAddresses) {
                    $candidate = $address.Address.IPAddressToString
                    if ($address.Address.AddressFamily -eq "InterNetwork" -and $candidate -notlike "169.254.*" -and $candidate -ne "127.0.0.1") {
                        if (-not $ipv4) {
                            $ipv4 = $candidate
                            $ipv4Prefix = $null
                            try {
                                if ($address.PrefixLength -gt 0 -and $address.PrefixLength -le 32) {
                                    $ipv4Prefix = [int]$address.PrefixLength
                                }
                                elseif ($address.IPv4Mask) {
                                    $maskBytes = $address.IPv4Mask.GetAddressBytes()
                                    $bits = 0
                                    foreach ($b in $maskBytes) {
                                        $v = [int]$b
                                        while ($v -gt 0) {
                                            $bits += ($v -band 1)
                                            $v = $v -shr 1
                                        }
                                    }
                                    if ($bits -gt 0 -and $bits -le 32) { $ipv4Prefix = $bits }
                                }
                            }
                            catch {}
                        }
                    }
                    if ($address.Address.AddressFamily -eq "InterNetworkV6" -and $candidate -notlike "fe80:*" -and $candidate -ne "::1") {
                        if (-not $ipv6) { $ipv6 = $candidate }
                    }
                }
                if ($ipv4) { break }
            }
        }
        catch {}

        if ($ipv4 -or $TimeoutSeconds -le 0) { break }
        Start-Sleep -Milliseconds $PollMilliseconds
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)

    $cidr = $null
    if ($ipv4 -and $null -ne $ipv4Prefix) {
        $cidr = "$ipv4/$ipv4Prefix"
    }

    return [PSCustomObject]@{
        IPv4              = $(if ($ipv4) { $ipv4 } else { $null })
        IPv4PrefixLength  = $ipv4Prefix
        IPv4Cidr          = $cidr
        IPv6              = $(if ($ipv6) { $ipv6 } else { $null })
    }
}

function Get-HardwareIPAddress {
    param(
        [int]$TimeoutSeconds = 0,
        [int]$PollMilliseconds = 500
    )
    return (Get-HardwareIPAddresses -TimeoutSeconds $TimeoutSeconds -PollMilliseconds $PollMilliseconds).IPv4
}

function Get-HardwareIPv6Address {
    param(
        [int]$TimeoutSeconds = 0,
        [int]$PollMilliseconds = 500
    )
    return (Get-HardwareIPAddresses -TimeoutSeconds $TimeoutSeconds -PollMilliseconds $PollMilliseconds).IPv6
}

function Get-HardwareDnsServers {
    return Get-HardwareCached -Key "DnsServers" -Factory {
        $servers = New-Object System.Collections.Generic.List[string]
        try {
            $adapters = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object { $_.NetworkInterfaceType -ne "Loopback" -and $_.OperationalStatus -eq "Up" }
            foreach ($adapter in $adapters) {
                foreach ($dns in $adapter.GetIPProperties().DnsAddresses) {
                    $candidate = $dns.IPAddressToString
                    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
                    if ($candidate -eq "127.0.0.1" -or $candidate -eq "::1") { continue }
                    if ($candidate -like "fe80:*") { continue }
                    if (-not $servers.Contains($candidate)) {
                        $servers.Add($candidate)
                    }
                }
            }
        }
        catch {}
        return @($servers.ToArray())
    }
}

function Get-HardwareHardDrives {
    if ($script:HardwareCache.ContainsKey("HardDrives")) {
        return @($script:HardwareCache["HardDrives"])
    }

    $items = @()
    try {
        if (Get-Command Get-Disk -ErrorAction SilentlyContinue) {
            Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -ne "USB" -and $_.OperationalStatus -eq "Online" } | Sort-Object Number | ForEach-Object {
                $size = if ($_.Size) { [math]::Round([double]$_.Size / 1GB) } else { 0 }
                $model = if ($_.Model) { $_.Model.Trim() } elseif ($_.FriendlyName) { $_.FriendlyName.Trim() } else { "Internal Drive" }
                $items += [PSCustomObject]@{
                    Number  = $_.Number
                    Model   = $model
                    SizeGB  = $size
                    BusType = [string]$_.BusType
                }
            }
        }
        if (-not $items) {
            Get-WmiObject Win32_DiskDrive -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceType -ne "USB" -and $_.MediaType -notlike "*Removable*" } | Sort-Object Index | ForEach-Object {
                $size = if ($_.Size) { [math]::Round([double]$_.Size / 1GB) } else { 0 }
                $items += [PSCustomObject]@{
                    Number  = $_.Index
                    Model   = $_.Model.Trim()
                    SizeGB  = $size
                    BusType = [string]$_.InterfaceType
                }
            }
        }
    }
    catch {}

    $script:HardwareCache["HardDrives"] = @($items)
    return @($script:HardwareCache["HardDrives"])
}

function Get-HardwareDiskCount {
    return @(Get-HardwareHardDrives).Count
}

function Get-HardwareTotalDiskGB {
    $total = 0
    foreach ($d in @(Get-HardwareHardDrives)) {
        if ($d.SizeGB) { $total += [int]$d.SizeGB }
    }
    return $total
}

# ==============================================================================
# DISK SELECTION GRID (WorkflowSelection — free/used/capacity rows)
# ==============================================================================

function Get-HardwareDiskStorageAvailableBytes {
    param(
        [int]$DiskNumber,
        [double]$TotalBytes
    )

    if (-not (Get-Command Get-Partition -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        $partitions = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop)
        $partitionedBytes = 0.0
        $readableFreeBytes = 0.0
        $canReadVolumes = $null -ne (Get-Command Get-Volume -ErrorAction SilentlyContinue)

        foreach ($partition in $partitions) {
            $partitionBytes = [math]::Max(0.0, [double]$partition.Size)
            $partitionedBytes += $partitionBytes

            if ($canReadVolumes) {
                try {
                    $volume = $partition | Get-Volume -ErrorAction Stop | Select-Object -First 1
                    if ($null -ne $volume -and $null -ne $volume.SizeRemaining) {
                        $volumeFreeBytes = [math]::Max(0.0, [double]$volume.SizeRemaining)
                        $readableFreeBytes += [math]::Min($partitionBytes, $volumeFreeBytes)
                    }
                } catch {
                    # Locked, RAW, hidden, or unmounted partitions count fully as used.
                }
            }
        }

        $unallocatedBytes = [math]::Max(0.0, $TotalBytes - $partitionedBytes)
        return [math]::Min($TotalBytes, $unallocatedBytes + $readableFreeBytes)
    } catch {
        return $null
    }
}

function Get-HardwareDiskWmiAvailableBytes {
    param(
        [int]$DiskIndex,
        [double]$TotalBytes,
        [int]$ExpectedPartitionCount = 0
    )

    try {
        $partitions = @(Get-WmiObject -Class Win32_DiskPartition -Filter "DiskIndex = $DiskIndex" -ErrorAction Stop)
        if ($ExpectedPartitionCount -gt 0 -and @($partitions).Length -eq 0) {
            return $null
        }

        $partitionedBytes = 0.0
        $readableFreeBytes = 0.0

        foreach ($partition in $partitions) {
            $partitionBytes = [math]::Max(0.0, [double]$partition.Size)
            $partitionedBytes += $partitionBytes

            try {
                $partitionId = ([string]$partition.DeviceID).Replace("'", "''")
                $query = "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$partitionId'} WHERE AssocClass=Win32_LogicalDiskToPartition"
                $logicalDisks = @(Get-WmiObject -Query $query -ErrorAction Stop)
                $partitionFreeBytes = 0.0

                foreach ($logicalDisk in $logicalDisks) {
                    if ($null -ne $logicalDisk.FreeSpace) {
                        $partitionFreeBytes += [math]::Max(0.0, [double]$logicalDisk.FreeSpace)
                    }
                }

                $readableFreeBytes += [math]::Min($partitionBytes, $partitionFreeBytes)
            } catch {
                # If WMI cannot map a filesystem, count the partition fully as used.
            }
        }

        $unallocatedBytes = [math]::Max(0.0, $TotalBytes - $partitionedBytes)
        return [math]::Min($TotalBytes, $unallocatedBytes + $readableFreeBytes)
    } catch {
        return $null
    }
}

function New-HardwareDiskSelectionRow {
    param(
        [int]$DiskNumber,
        [string]$Model,
        [double]$TotalBytes,
        $AvailableBytes
    )

    # Unknown space is handled conservatively: all capacity is considered used.
    $safeAvailableBytes = if ($null -eq $AvailableBytes) {
        0.0
    } else {
        [math]::Min($TotalBytes, [math]::Max(0.0, [double]$AvailableBytes))
    }

    # Derive usage from rounded display values so Capacity = Usage + Available.
    $totalGB = [math]::Round($TotalBytes / 1GB, 1)
    $availableGB = [math]::Round($safeAvailableBytes / 1GB, 1)
    $usedGB = [math]::Max(0.0, [math]::Round($totalGB - $availableGB, 1))

    return [PSCustomObject]@{
        Index      = "Disk $DiskNumber"
        Model      = $Model
        Capacity   = "$totalGB GB"
        UsedSpace  = "$usedGB GB"
        FreeSpace  = "$availableGB GB"
        DiskNumber = $DiskNumber
        TotalBytes = $TotalBytes
    }
}

function Test-HardwareDiskSelectionHasCapacity {
    <#
    .SYNOPSIS
        True when a Get-HardwarePhysicalDisks row has usable capacity (at least 1 GB).
    #>
    param(
        [Parameter(Mandatory = $false)]
        $Disk
    )

    if ($null -eq $Disk) { return $false }

    if ($Disk.PSObject.Properties["TotalBytes"] -and $null -ne $Disk.TotalBytes) {
        return ([double]$Disk.TotalBytes -ge 1GB)
    }

    if ($Disk.PSObject.Properties["Capacity"] -and $Disk.Capacity) {
        if ([string]$Disk.Capacity -match '(?i)^0(\.0)?\s*GB$') { return $false }
        if ([string]$Disk.Capacity -match '(?i)([\d\.]+)\s*GB') {
            return ([double]$Matches[1] -ge 1.0)
        }
    }

    if ($Disk.PSObject.Properties["SizeGB"] -and $null -ne $Disk.SizeGB) {
        return ([double]$Disk.SizeGB -ge 1.0)
    }

    return $false
}

function Get-HardwarePhysicalDisks {
    <#
    .SYNOPSIS
        Internal non-USB disks with Capacity/Used/Free columns for WorkflowSelection wipe-target grid.

    .NOTES
        Includes 0-capacity disks so the technician can see them; WorkflowSelection blocks
        Continue when the selected disk fails Test-HardwareDiskSelectionHasCapacity.
        Free space = unallocated + readable volume free (Storage then WMI). Unknown free → 0.
        Does not replace Get-HardwareHardDrives (PreCheck inventory).
    #>
    $diskList = @()

    try {
        if (Get-Command Get-Disk -ErrorAction SilentlyContinue) {
            $disks = @(Get-Disk -ErrorAction Stop | Where-Object {
                $_.BusType -ne "USB" -and
                ($_.OperationalStatus -eq "Online" -or $_.OperationalStatus -contains "Online")
            } | Sort-Object Number)

            foreach ($disk in $disks) {
                $totalBytes = if ($null -ne $disk.Size) { [double]$disk.Size } else { 0.0 }

                $model = if ($disk.Model) {
                    $disk.Model.Trim()
                } elseif ($disk.FriendlyName) {
                    $disk.FriendlyName.Trim()
                } else {
                    "Internal Drive"
                }

                $availableBytes = $null
                if ($totalBytes -gt 0) {
                    $availableBytes = Get-HardwareDiskStorageAvailableBytes -DiskNumber $disk.Number -TotalBytes $totalBytes
                    if ($null -eq $availableBytes) {
                        $availableBytes = Get-HardwareDiskWmiAvailableBytes -DiskIndex $disk.Number -TotalBytes $totalBytes -ExpectedPartitionCount $disk.NumberOfPartitions
                    }
                } else {
                    $availableBytes = 0.0
                }

                $diskList += New-HardwareDiskSelectionRow -DiskNumber $disk.Number -Model $model -TotalBytes $totalBytes -AvailableBytes $availableBytes
            }
        }
    } catch {
        $diskList = @()
    }

    if (@($diskList).Length -eq 0) {
        try {
            $wmiDisks = @(Get-WmiObject -Class Win32_DiskDrive -ErrorAction Stop | Where-Object {
                $_.InterfaceType -ne "USB" -and $_.MediaType -notlike "*Removable*"
            } | Sort-Object Index)

            foreach ($disk in $wmiDisks) {
                $totalBytes = if ($null -ne $disk.Size) { [double]$disk.Size } else { 0.0 }
                $model = if ($disk.Model) { $disk.Model.Trim() } else { "Internal Drive" }
                $availableBytes = if ($totalBytes -gt 0) {
                    Get-HardwareDiskWmiAvailableBytes -DiskIndex $disk.Index -TotalBytes $totalBytes -ExpectedPartitionCount $disk.Partitions
                } else {
                    0.0
                }
                $diskList += New-HardwareDiskSelectionRow -DiskNumber $disk.Index -Model $model -TotalBytes $totalBytes -AvailableBytes $availableBytes
            }
        } catch {
            $diskList = @()
        }
    }

    return @($diskList)
}

# ==============================================================================
# LOGGING HELPERS
# ==============================================================================

function Get-HardwareTimezoneId {
    try { return [System.TimeZoneInfo]::Local.Id } catch { return $null }
}

function Get-HardwareUtcOffsetMinutes {
    try {
        return [int][System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes
    }
    catch { return 0 }
}

# ==============================================================================
# INVENTORY COMPOSE
# ==============================================================================

function Get-HardwareInventory {
    [CmdletBinding()]
    param(
        [psobject]$Assessment = $null,
        [object[]]$Results = @(),
        [bool]$Passed = $true,
        [switch]$Force
    )

    if ($Force) { Clear-HardwareCache }

    $drives = @(Get-HardwareHardDrives)
    $nics = @(Get-HardwareNICs)
    $ips = Get-HardwareIPAddresses

    $inventory = [ordered]@{
        Vendor                 = Get-HardwareVendor
        VendorRaw              = Get-HardwareVendorRaw
        Model                  = Get-HardwareModel
        Sku                    = Get-HardwareComputerSku
        SerialNumber           = Get-HardwareSerialNumber
        UUID                   = Get-HardwareUUID
        AssetTag               = Get-HardwareAssetTag
        ComputerName           = Get-HardwareComputerName
        Architecture           = Get-HardwareArchitecture
        Chassis                = Get-HardwareChassis
        IsLaptop               = Get-HardwareIsLaptop
        IsDesktop              = Get-HardwareIsDesktop
        IsVM                   = Get-HardwareIsVM
        IsWinPE                = Get-HardwareIsWinPE
        SystemDrive            = Get-HardwareSystemDrive
        DriverFolderHint       = Get-HardwareDriverFolderHint
        FirmwareType           = Get-HardwareFirmwareType
        IsUEFI                 = Get-HardwareIsUEFI
        BiosVersion            = Get-HardwareBiosVersion
        BiosReleaseDate        = Get-HardwareBiosReleaseDate
        SecureBootStatus       = Get-HardwareSecureBootStatus
        SecureBootIsEnabled    = Get-HardwareSecureBootIsEnabled
        SecureBootDisplay      = Get-HardwareSecureBootDisplay
        TpmPresent             = Get-HardwareTpmPresent
        TpmVersion             = Get-HardwareTpmVersion
        TpmState               = Get-HardwareTpmState
        TpmIsReady             = Get-HardwareTpmIsReady
        MemoryBytes            = Get-HardwareMemoryBytes
        MemoryMB               = Get-HardwareMemoryMB
        MemoryGB               = Get-HardwareMemoryGB
        ProcessorName          = Get-HardwareProcessorName
        ProcessorCores         = Get-HardwareProcessorCores
        ProcessorLogicalCount  = Get-HardwareProcessorLogicalCount
        PrimaryNicName         = Get-HardwarePrimaryNicName
        PrimaryMacAddress      = Get-HardwarePrimaryMacAddress
        IPAddress              = $ips.IPv4
        IPv4PrefixLength       = $ips.IPv4PrefixLength
        IPv4Cidr               = $ips.IPv4Cidr
        IPv6Address            = $ips.IPv6
        DnsServers             = @(Get-HardwareDnsServers)
        NICs                   = $nics
        HardDrives             = $drives
        DiskCount              = $drives.Count
        TotalDiskGB            = (Get-HardwareTotalDiskGB)
        TimezoneId             = Get-HardwareTimezoneId
        UtcOffsetMinutes       = Get-HardwareUtcOffsetMinutes
        Passed                 = [bool]$Passed
        Results                = @()
    }

    if ($Assessment) {
        foreach ($name in @(
                "BootConfigPath", "DeploymentMode", "NetworkPath", "NetworkAdapter", "IpAddress",
                "DeploymentServer", "Disks", "MemoryGB", "FirmwareType", "SecureBoot",
                "TpmPresent", "TpmVersion", "TpmState", "RequireTpm", "SkippedByPolicy"
            )) {
            if ($Assessment.PSObject.Properties[$name]) {
                $inventory[$name] = $Assessment.$name
            }
        }
        # Prefer assessment IP/adapter when PreCheck filled them
        if ($Assessment.PSObject.Properties["IpAddress"] -and $Assessment.IpAddress) {
            $inventory.IPAddress = $Assessment.IpAddress
            # Drop CIDR if it no longer matches the assessment IPv4 (avoid misleading prefix).
            if ($inventory.IPv4Cidr -and -not ([string]$inventory.IPv4Cidr).StartsWith("$($Assessment.IpAddress)/")) {
                $inventory.IPv4Cidr = $null
                $inventory.IPv4PrefixLength = $null
            }
        }
        if ($Assessment.PSObject.Properties["NetworkAdapter"] -and $Assessment.NetworkAdapter) {
            $inventory.PrimaryNicName = $Assessment.NetworkAdapter
            $inventory.NetworkAdapter = $Assessment.NetworkAdapter
        }
        if ($Assessment.PSObject.Properties["SecureBoot"] -and $Assessment.SecureBoot) {
            $inventory.SecureBootDisplay = $Assessment.SecureBoot
        }
        if ($Assessment.PSObject.Properties["Disks"] -and $Assessment.Disks) {
            $inventory.Disks = @($Assessment.Disks)
        }
        if ($Assessment.PSObject.Properties["SkippedByPolicy"]) {
            $inventory.SkippedByPolicy = [bool]$Assessment.SkippedByPolicy
        }
    }

    if ($Results) {
        $inventory.Results = @($Results | ForEach-Object {
                [PSCustomObject]@{
                    Status  = $_.Status
                    Check   = $_.Check
                    Details = $_.Details
                }
            })
    }

    return [PSCustomObject]$inventory
}
