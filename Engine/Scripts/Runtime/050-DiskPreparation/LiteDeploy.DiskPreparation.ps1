<#
.SYNOPSIS
    Standardized Disk Partitioning & Formatting Engine for LiteDeploy in WinPE.

.DESCRIPTION
    Initializes and partitions a physical disk according to certified UEFI (GPT)
    or LEGACY (MBR) layouts for bare-metal Windows deployment. Configures EFI System
    Partitions, Microsoft Reserved (MSR), System Reserved, Windows OS staging volumes,
    and tail WinRE recovery partitions with required flags and attributes.

.PARAMETER DiskNumber
    The target physical disk index to wipe and partition (default: 0).

.PARAMETER BootMode
    Target firmware boot architecture: 'UEFI' (GPT) or 'LEGACY' (MBR). Default is 'UEFI'.

.PARAMETER OSTempDriveLetter
    Optional temporary staging drive letter (e.g., 'W' or 'W:') to mount the Windows OS
    volume during WinPE execution. If omitted, the volume is created unmounted.

.PARAMETER Metadata
    Switch to output standardized LiteDeploy component metadata PSCustomObject.

.PARAMETER BootObject
    Optional bootstrap PSCustomObject provided by BootInitializer.

.EXAMPLE
    .\LiteDeploy.DiskPreparation.ps1 -DiskNumber 0 -BootMode UEFI -OSTempDriveLetter W

.EXAMPLE
    .\LiteDeploy.DiskPreparation.ps1 -Metadata

.NOTES
    LiteDeploy Component Standard v1.0
    PowerShell Version: 5.1+
    Strict Mode: Version 2.0
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [int]$DiskNumber = 0,

    [Parameter(Mandatory = $false)]
    [ValidateSet("UEFI", "LEGACY")]
    [string]$BootMode = "UEFI",

    [Parameter(Mandatory = $false)]
    [string]$OSTempDriveLetter = $null,

    [Parameter(Mandatory = $false)]
    [switch]$Metadata,

    [Parameter(Mandatory = $false)]
    [psobject]$BootObject = $null
)

# Enforce strict execution discipline across WinPE runtime
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ==============================================================================
# 1. COMPONENT METADATA & INVENTORY DISCOVERY
# ==============================================================================

function Get-LiteDeployComponentMetadata {
    <#
    .SYNOPSIS
        Returns standardized component metadata for inventory discovery and version management.
    #>
    return [PSCustomObject]@{
        ComponentId          = "DiskPreparation"
        Name                 = "LiteDeploy Disk Preparation"
        Version              = "1.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "WinPE"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("LogWriter")
        Description          = "Initializes and formats target disk partitions for UEFI (GPT) and Legacy (MBR) deployment."
    }
}

# Fast-exit for automated inventory scanners or version queries
if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

# ==============================================================================
# 2. LOGGING & DIAGNOSTIC INTEGRATION
# ==============================================================================

function Write-ComponentLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "SUCCESS", "INIT", "CHECK", "WARNING", "RETRY", "ERROR")]
        [string]$Level = "INFO",

        [ConsoleColor]$ForegroundColor = [ConsoleColor]::White
    )

    $meta = Get-LiteDeployComponentMetadata

    if (Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue) {
        Write-LiteDeployLog -Message $Message -Level $Level -Component $meta.ComponentId -ForegroundColor $ForegroundColor
    }
    else {
        Write-Host " [$($Level.PadRight(7))] $Message" -ForegroundColor $ForegroundColor
    }
}

# ==============================================================================
# 3. CORE DISK FORMAT PAYLOAD
# ==============================================================================

function Invoke-DiskPreparation {
    [CmdletBinding()]
    param(
        [int]$TargetDiskNumber,
        [string]$TargetBootMode,
        [string]$TargetDriveLetter
    )

    Write-ComponentLog "Targeting Disk $TargetDiskNumber under $TargetBootMode mode..." -Level "INIT" -ForegroundColor Cyan

    # 1. Drive letter sanitization & validation
    $cleanLetter = $null
    $osPartDriveParams = @{}
    $mountMsg = "Unmounted"

    if (-not [string]::IsNullOrWhiteSpace($TargetDriveLetter)) {
        $trimmed = $TargetDriveLetter.Trim().TrimEnd(':\/')
        if ($trimmed -match '^[a-zA-Z]$') {
            $cleanLetter = [char]$trimmed.ToUpper()
            $existingVol = Get-Volume -DriveLetter $cleanLetter -ErrorAction SilentlyContinue
            if ($null -ne $existingVol) {
                Write-ComponentLog "Drive letter ${cleanLetter}: is currently occupied by volume '$($existingVol.FileSystemLabel)'." -Level "WARNING" -ForegroundColor Yellow
            }
            $osPartDriveParams['DriveLetter'] = $cleanLetter
            $mountMsg = "Mounting as ${cleanLetter}:"
        }
        else {
            throw "Invalid drive letter specification '$TargetDriveLetter'. Expected a single letter (e.g. 'W' or 'W:')."
        }
    }
    else {
        $osPartDriveParams['AssignDriveLetter'] = $false
    }

    # 2. Query and inspect target disk
    Update-HostStorageCache
    $disk = Get-Disk -Number $TargetDiskNumber -ErrorAction Stop

    # Bring online and clear read-only flag if required
    if ($disk.IsOffline) {
        Write-ComponentLog "Disk $TargetDiskNumber is OFFLINE. Bringing online..." -Level "INFO" -ForegroundColor Yellow
        Set-Disk -Number $TargetDiskNumber -IsOffline $false -ErrorAction Stop
    }

    if ($disk.IsReadOnly) {
        Write-ComponentLog "Disk $TargetDiskNumber is READ-ONLY. Clearing read-only flag..." -Level "INFO" -ForegroundColor Yellow
        Set-Disk -Number $TargetDiskNumber -IsReadOnly $false -ErrorAction Stop
    }

    # Validate minimal hardware capacity (at least 16GB)
    $minDiskSizeBytes = 16GB
    if ($disk.Size -lt $minDiskSizeBytes) {
        throw "Target disk size ($([math]::Round($disk.Size / 1GB, 2)) GB) is below minimum deployment requirements (16 GB)."
    }

    # 3. Clear partition table
    if ($disk.PartitionStyle -ne 'RAW') {
        Write-ComponentLog "Disk is initialized ($($disk.PartitionStyle)). Wiping partition table..." -Level "INFO"
        Clear-Disk -Number $TargetDiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
    }
    else {
        Write-ComponentLog "Disk is RAW / uninitialized. Skipping Clear-Disk." -Level "INFO"
    }

    Update-HostStorageCache
    $disk = Get-Disk -Number $TargetDiskNumber -ErrorAction Stop
    $recoveryReservation = 1024MB

    # 4. Partition creation based on BootMode
    if ($TargetBootMode -eq "UEFI") {
        # ----------------------------------------------------------------------
        # UEFI / GPT LAYOUT
        # ----------------------------------------------------------------------
        Initialize-Disk -Number $TargetDiskNumber -PartitionStyle GPT -Confirm:$false -ErrorAction Stop
        Update-HostStorageCache

        # Partition 1: EFI System Partition (500MB)
        Write-ComponentLog "[UEFI] Creating ESP (500MB)..." -Level "INFO"
        $espPart = New-Partition -DiskNumber $TargetDiskNumber -Size 500MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -AssignDriveLetter:$false -ErrorAction Stop
        Format-Volume -Partition $espPart -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false -ErrorAction Stop | Out-Null

        # Partition 2: Microsoft Reserved Partition (16MB)
        Write-ComponentLog "[UEFI] Creating MSR (16MB)..." -Level "INFO"
        $null = New-Partition -DiskNumber $TargetDiskNumber -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' -ErrorAction Stop

        # Partition 3: Windows OS
        $allocated = (Get-Partition -DiskNumber $TargetDiskNumber | Measure-Object -Property Size -Sum).Sum
        $osSizeBytes = [int64]($disk.Size - $allocated - $recoveryReservation - 32MB)

        if ($osSizeBytes -le 0) {
            throw "Insufficient disk space to allocate Windows OS partition. Total disk size: $([math]::Round($disk.Size / 1GB, 2)) GB."
        }

        Write-ComponentLog "[UEFI] Creating OS Partition ($mountMsg)..." -Level "INFO"
        $osPart = New-Partition -DiskNumber $TargetDiskNumber -Size $osSizeBytes @osPartDriveParams -ErrorAction Stop
        Format-Volume -Partition $osPart -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false -ErrorAction Stop | Out-Null

        # Partition 4: WinRE Recovery (Tail of disk)
        Write-ComponentLog "[UEFI] Creating Recovery Partition (Remaining Space)..." -Level "INFO"
        $recPart = New-Partition -DiskNumber $TargetDiskNumber -UseMaximumSize -GptType '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' -AssignDriveLetter:$false -ErrorAction Stop
        Format-Volume -Partition $recPart -FileSystem NTFS -NewFileSystemLabel "Recovery" -Confirm:$false -ErrorAction Stop | Out-Null

        # Stamp raw GPT attributes (0x8000000000000001) via diskpart pipeline
        Write-ComponentLog "[UEFI] Stamping GPT Recovery Attributes (0x8000000000000001)..." -Level "INFO"
        $diskpartScript = "select disk $TargetDiskNumber`r`nselect partition $($recPart.PartitionNumber)`r`ngpt attributes=0x8000000000000001`r`nexit`r`n"
        $diskpartOutput = $diskpartScript | diskpart.exe
        $rawOutput = ($diskpartOutput | Out-String).Trim()

        if ($LASTEXITCODE -ne 0 -or $rawOutput -match "(?i)DiskPart has encountered an error|Virtual Disk Service error") {
            throw "DiskPart failed to set recovery attributes. Details: $rawOutput"
        }

        $systemPartNumber = $espPart.PartitionNumber
    }
    else {
        # ----------------------------------------------------------------------
        # LEGACY / MBR LAYOUT
        # ----------------------------------------------------------------------
        Initialize-Disk -Number $TargetDiskNumber -PartitionStyle MBR -Confirm:$false -ErrorAction Stop
        Update-HostStorageCache

        # Partition 1: Active System Reserved (500MB)
        Write-ComponentLog "[LEGACY] Creating Active System Reserved Partition (500MB)..." -Level "INFO"
        $sysPart = New-Partition -DiskNumber $TargetDiskNumber -Size 500MB -MbrType 0x07 -IsActive -AssignDriveLetter:$false -ErrorAction Stop
        Format-Volume -Partition $sysPart -FileSystem NTFS -NewFileSystemLabel "System Reserved" -Confirm:$false -ErrorAction Stop | Out-Null

        # Partition 2: Windows OS
        $allocated = (Get-Partition -DiskNumber $TargetDiskNumber | Measure-Object -Property Size -Sum).Sum
        $osSizeBytes = [int64]($disk.Size - $allocated - $recoveryReservation - 32MB)

        if ($osSizeBytes -le 0) {
            throw "Insufficient disk space to allocate Windows OS partition. Total disk size: $([math]::Round($disk.Size / 1GB, 2)) GB."
        }

        Write-ComponentLog "[LEGACY] Creating OS Partition ($mountMsg)..." -Level "INFO"
        $osPart = New-Partition -DiskNumber $TargetDiskNumber -Size $osSizeBytes -MbrType 0x07 @osPartDriveParams -ErrorAction Stop
        Format-Volume -Partition $osPart -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false -ErrorAction Stop | Out-Null

        # Partition 3: WinRE Recovery
        Write-ComponentLog "[LEGACY] Creating Recovery Partition..." -Level "INFO"
        $recPart = New-Partition -DiskNumber $TargetDiskNumber -UseMaximumSize -MbrType 0x07 -AssignDriveLetter:$false -ErrorAction Stop
        Format-Volume -Partition $recPart -FileSystem NTFS -NewFileSystemLabel "Recovery" -Confirm:$false -ErrorAction Stop | Out-Null

        # Set MBR partition type to 0x27 (hidden recovery)
        Write-ComponentLog "[LEGACY] Updating Recovery Partition MBR Type to 0x27..." -Level "INFO"
        Set-Partition -DiskNumber $TargetDiskNumber -PartitionNumber $recPart.PartitionNumber -MbrType 0x27 -ErrorAction Stop

        $systemPartNumber = $sysPart.PartitionNumber
    }

    Update-HostStorageCache
    Write-ComponentLog "Disk $TargetDiskNumber successfully formatted for $TargetBootMode deployment." -Level "SUCCESS" -ForegroundColor Green

    return [PSCustomObject]@{
        Success                 = $true
        BootMode                = $TargetBootMode
        DiskNumber              = $TargetDiskNumber
        OSPartitionNumber       = $osPart.PartitionNumber
        OSDriveLetter           = if ($cleanLetter) { "$($cleanLetter):" } else { $null }
        SystemPartitionNumber   = $systemPartNumber
        RecoveryPartitionNumber = $recPart.PartitionNumber
        TotalSizeGB             = [math]::Round($disk.Size / 1GB, 2)
    }
}

# ==============================================================================
# 4. EXECUTION HANDOFF
# ==============================================================================

try {
    $result = Invoke-DiskPreparation -TargetDiskNumber $DiskNumber -TargetBootMode $BootMode -TargetDriveLetter $OSTempDriveLetter
    return $result
}
catch {
    Write-ComponentLog "Disk format failure: $($_.Exception.Message)" -Level "ERROR" -ForegroundColor Red
    throw $_
}