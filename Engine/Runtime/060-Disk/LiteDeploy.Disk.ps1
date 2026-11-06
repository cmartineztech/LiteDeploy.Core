<#
.SYNOPSIS
    LiteDeploy Disk - partitioning & formatting engine for WinPE (architecture v2).

.DESCRIPTION
    Initializes and partitions a physical disk according to certified UEFI (GPT)
    or LEGACY (MBR) layouts for bare-metal Windows deployment. Configures EFI System
    Partitions, Microsoft Reserved (MSR), System Reserved, Windows OS staging volumes,
    and tail WinRE recovery partitions with required flags and attributes.

    Invoke-DiskPreparation remains the primary engine entry point (compatibility).
    v2 wrappers (Clear/Initialize/New-PartitionLayout/Format/Test) are exposed for
    Engine and tooling; every destructive wrapper requires -ConfirmDestroy.

    STANDALONE SAFETY: running this file directly is READ-ONLY (lists disks and
    validates the layout of -DiskNumber). The wipe + partition + format only runs
    when -ConfirmDestroy (alias -ForceWipe) is passed explicitly.

.PARAMETER DiskNumber
    The target physical disk index (default: 0).

.PARAMETER BootMode
    Target firmware boot architecture: 'UEFI' (GPT) or 'LEGACY' (MBR). Default is 'UEFI'.

.PARAMETER OSTempDriveLetter
    Optional temporary staging drive letter (e.g., 'W' or 'W:') to mount the Windows OS
    volume during WinPE execution. If omitted, the volume is created unmounted.

.PARAMETER ConfirmDestroy
    Required for standalone destructive wipe/format (alias: ForceWipe). Without this
    switch, standalone execution is read-only (lists disks / tests layout).

.PARAMETER Metadata
    Switch to output standardized LiteDeploy component metadata PSCustomObject.

.EXAMPLE
    .\LiteDeploy.Disk.ps1
    Read-only disk inventory + layout test of disk 0.

.EXAMPLE
    .\LiteDeploy.Disk.ps1 -DiskNumber 0 -BootMode UEFI -OSTempDriveLetter W -ConfirmDestroy
    Destructive partition layout (explicit opt-in).

.NOTES
    LiteDeploy Component Standard v2.0
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
    [Alias("ForceWipe")]
    [switch]$ConfirmDestroy,

    [Parameter(Mandatory = $false)]
    [switch]$Metadata
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
        ComponentId          = "Disk"
        Name                 = "LiteDeploy Disk"
        Version              = "2.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "WinPE"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("Logs", "Hardware")
        Description          = "Target disk wipe, UEFI (GPT) and Legacy (MBR) partition layout, formatting, and WinRE attributes. Standalone execution is read-only unless -ConfirmDestroy."
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
# 3. CORE DISK FORMAT PAYLOAD (primary engine entry - behavior unchanged)
# ==============================================================================

function Invoke-DiskPreparation {
    [CmdletBinding()]
    param(
        [int]$TargetDiskNumber,
        [string]$TargetBootMode,
        [string]$TargetDriveLetter
    )

    Write-ComponentLog "Targeting Disk $TargetDiskNumber under $TargetBootMode mode..." -Level "INIT" -ForegroundColor Cyan

    # 1. Query and inspect target disk
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

    # 2. Clear partition table (releases any drive letters previously mounted on this target disk)
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

    # 3. Drive letter resolution & fallback sequence
    $cleanLetter = $null
    $osPartDriveParams = @{}
    $mountMsg = "Unmounted"

    if (-not [string]::IsNullOrWhiteSpace($TargetDriveLetter)) {
        $trimmed = $TargetDriveLetter.Trim().TrimEnd(':\/')
        if ($trimmed -match '^[a-zA-Z]$') {
            $primaryLetter = [char]$trimmed.ToUpper()
            $candidateLetters = @($primaryLetter, 'T', 'U', 'V', 'S', 'R', 'Q', 'P', 'O', 'N', 'M') | Select-Object -Unique

            $selectedLetter = $null
            foreach ($cand in $candidateLetters) {
                $candChar = [char]$cand
                $inUseVol = Get-Volume -DriveLetter $candChar -ErrorAction SilentlyContinue
                $inUsePart = Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq $candChar }
                $inUsePSDrive = Get-PSDrive -Name ([string]$candChar) -ErrorAction SilentlyContinue

                if ($null -eq $inUseVol -and $null -eq $inUsePart -and $null -eq $inUsePSDrive) {
                    $selectedLetter = $candChar
                    break
                }
            }

            if ($null -eq $selectedLetter) {
                throw "Failed to find an available drive letter for OS staging. All candidate drive letters ($($candidateLetters -join ', ')) are in use."
            }

            $cleanLetter = $selectedLetter
            if ($cleanLetter -ne $primaryLetter) {
                Write-ComponentLog "Preferred drive letter ${primaryLetter}: is occupied by another device. Automatically falling back to available letter ${cleanLetter}:" -Level "WARNING" -ForegroundColor Yellow
            }
            else {
                Write-ComponentLog "Selected staging drive letter ${cleanLetter}:" -Level "INFO"
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
# 4. v2 API WRAPPERS
#    Read-only: Get-LiteDeployDisk, Test-LiteDeployDiskLayout
#    Destructive (require -ConfirmDestroy): Clear/Initialize/New-PartitionLayout/Format
# ==============================================================================

function Get-LiteDeployDisk {
    <#
    .SYNOPSIS
        Returns one disk by number (read-only). Throws when not found.
    #>
    [CmdletBinding()]
    param(
        [Alias("DiskNumber")]
        [int]$Number = 0
    )

    $disk = Get-Disk -Number $Number -ErrorAction SilentlyContinue
    if (-not $disk) { throw "Disk was not found: $Number" }
    return $disk
}

function Test-LiteDeployDiskLayout {
    <#
    .SYNOPSIS
        Read-only validation that a disk matches the LiteDeploy UEFI (GPT) or LEGACY (MBR) layout.

    .NOTES
        UEFI : GPT with ESP + MSR + Windows (basic data) + Recovery.
        LEGACY: MBR with active system partition + Windows + Recovery (type 0x27).
    #>
    [CmdletBinding()]
    param(
        [Alias("DiskNumber")]
        [int]$Number = 0,

        [ValidateSet("UEFI", "LEGACY")]
        [string]$ExpectedBootMode = "UEFI"
    )

    $disk = Get-LiteDeployDisk -Number $Number
    $parts = @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue)
    $style = [string]$disk.PartitionStyle
    $issues = New-Object System.Collections.Generic.List[string]

    if ($ExpectedBootMode -eq "UEFI") {
        if ($style -ne "GPT") { $issues.Add("PartitionStyle is '$style' (expected GPT).") }
        else {
            $gptTypes = @($parts | ForEach-Object { ([string]$_.GptType).ToLowerInvariant() })
            if ($gptTypes -notcontains '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}') { $issues.Add("EFI System Partition not found.") }
            if ($gptTypes -notcontains '{e3c9e316-0b5c-4db8-817d-f92df00215ae}') { $issues.Add("Microsoft Reserved partition not found.") }
            if ($gptTypes -notcontains '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}') { $issues.Add("Windows (basic data) partition not found.") }
            if ($gptTypes -notcontains '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') { $issues.Add("Recovery partition not found.") }
        }
    }
    else {
        if ($style -ne "MBR") { $issues.Add("PartitionStyle is '$style' (expected MBR).") }
        else {
            if (@($parts | Where-Object { $_.IsActive }).Count -eq 0) { $issues.Add("No active system partition found.") }
            if ($parts.Count -lt 3) { $issues.Add("Expected at least 3 partitions (System, Windows, Recovery); found $($parts.Count).") }
        }
    }

    return [PSCustomObject]@{
        DiskNumber       = $Number
        PartitionStyle   = $style
        PartitionCount   = $parts.Count
        ExpectedBootMode = $ExpectedBootMode
        IsValid          = ($issues.Count -eq 0)
        Issues           = @($issues.ToArray())
        Partitions       = $parts
    }
}

function Clear-LiteDeployDisk {
    <#
    .SYNOPSIS
        DESTRUCTIVE. Brings the disk online/writable and clears its partition table.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Alias("DiskNumber")]
        [int]$Number = 0,
        [switch]$ConfirmDestroy
    )

    if (-not $ConfirmDestroy) {
        throw "Clear-LiteDeployDisk requires -ConfirmDestroy."
    }

    Update-HostStorageCache
    $disk = Get-Disk -Number $Number -ErrorAction Stop

    if (-not $PSCmdlet.ShouldProcess("Disk $Number", "Clear partition table and remove all data")) {
        return [PSCustomObject]@{ Success = $false; DiskNumber = $Number; Cleared = $false; Status = "WhatIf" }
    }

    if ($disk.IsOffline) {
        Set-Disk -Number $Number -IsOffline $false -ErrorAction Stop
    }
    if ($disk.IsReadOnly) {
        Set-Disk -Number $Number -IsReadOnly $false -ErrorAction Stop
    }

    $cleared = $false
    if ($disk.PartitionStyle -ne 'RAW') {
        Write-ComponentLog "Disk $Number is initialized ($($disk.PartitionStyle)). Wiping partition table..." -Level "INFO"
        Clear-Disk -Number $Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
        $cleared = $true
    }
    else {
        Write-ComponentLog "Disk $Number is RAW / uninitialized. Skipping Clear-Disk." -Level "INFO"
    }

    Update-HostStorageCache
    return [PSCustomObject]@{ Success = $true; DiskNumber = $Number; Cleared = $cleared; Status = "Cleared" }
}

function Initialize-LiteDeployDisk {
    <#
    .SYNOPSIS
        DESTRUCTIVE. Clears the disk and initializes it as GPT (UEFI) or MBR (LEGACY). No partitions created.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Alias("DiskNumber")]
        [int]$Number = 0,

        [ValidateSet("UEFI", "LEGACY")]
        [string]$BootMode = "UEFI",

        [switch]$ConfirmDestroy
    )

    if (-not $ConfirmDestroy) {
        throw "Initialize-LiteDeployDisk requires -ConfirmDestroy."
    }

    $null = Clear-LiteDeployDisk -Number $Number -ConfirmDestroy -WhatIf:$WhatIfPreference
    if (-not $PSCmdlet.ShouldProcess("Disk $Number", "Initialize as $(if ($BootMode -eq 'UEFI') { 'GPT' } else { 'MBR' })")) {
        return [PSCustomObject]@{ Success = $false; DiskNumber = $Number; Status = "WhatIf" }
    }

    $style = if ($BootMode -eq "UEFI") { "GPT" } else { "MBR" }
    Initialize-Disk -Number $Number -PartitionStyle $style -Confirm:$false -ErrorAction Stop
    Update-HostStorageCache

    return [PSCustomObject]@{ Success = $true; DiskNumber = $Number; PartitionStyle = $style; BootMode = $BootMode; Status = "Initialized" }
}

function New-LiteDeployPartitionLayout {
    <#
    .SYNOPSIS
        DESTRUCTIVE. Full wipe + UEFI/GPT or LEGACY/MBR layout + format (delegates to Invoke-DiskPreparation).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Alias("DiskNumber")]
        [int]$Number = 0,

        [ValidateSet("UEFI", "LEGACY")]
        [string]$BootMode = "UEFI",

        [string]$OSTempDriveLetter = $null,

        [switch]$ConfirmDestroy
    )

    if (-not $ConfirmDestroy) {
        throw "New-LiteDeployPartitionLayout requires -ConfirmDestroy."
    }
    if (-not $PSCmdlet.ShouldProcess("Disk $Number", "Wipe and create $BootMode partition layout")) {
        return [PSCustomObject]@{ Success = $false; DiskNumber = $Number; Status = "WhatIf" }
    }

    return Invoke-DiskPreparation -TargetDiskNumber $Number -TargetBootMode $BootMode -TargetDriveLetter $OSTempDriveLetter
}

function Format-LiteDeployPartition {
    <#
    .SYNOPSIS
        DESTRUCTIVE. Formats a single existing partition (Format-Volume).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [Alias("DiskNumber")]
        [int]$Number,

        [Parameter(Mandatory = $true)]
        [int]$PartitionNumber,

        [ValidateSet("NTFS", "FAT32")]
        [string]$FileSystem = "NTFS",

        [string]$Label = "Windows",

        [switch]$ConfirmDestroy
    )

    if (-not $ConfirmDestroy) {
        throw "Format-LiteDeployPartition requires -ConfirmDestroy."
    }
    if (-not $PSCmdlet.ShouldProcess("Disk $Number partition $PartitionNumber", "Format as $FileSystem")) {
        return [PSCustomObject]@{ Success = $false; DiskNumber = $Number; PartitionNumber = $PartitionNumber; Status = "WhatIf" }
    }

    $partition = Get-Partition -DiskNumber $Number -PartitionNumber $PartitionNumber -ErrorAction Stop
    Format-Volume -Partition $partition -FileSystem $FileSystem -NewFileSystemLabel $Label -Confirm:$false -ErrorAction Stop | Out-Null
    Update-HostStorageCache

    return [PSCustomObject]@{ Success = $true; DiskNumber = $Number; PartitionNumber = $PartitionNumber; FileSystem = $FileSystem; Label = $Label; Status = "Formatted" }
}

# ==============================================================================
# 5. EXECUTION HANDOFF (standalone only; skipped on dot-source / Import-Module)
# ==============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $ConfirmDestroy) {
        # READ-ONLY default: nothing is modified.
        Write-Host "LiteDeploy.Disk - read-only mode (pass -ConfirmDestroy / -ForceWipe to wipe and format)." -ForegroundColor Cyan
        try {
            Get-Disk -ErrorAction Stop |
                Select-Object Number, FriendlyName, @{ Name = "SizeGB"; Expression = { [math]::Round($_.Size / 1GB, 1) } }, PartitionStyle, OperationalStatus, BusType |
                Format-Table -AutoSize | Out-Host
        }
        catch {
            Write-Warning "Disk inventory unavailable: $($_.Exception.Message)"
        }

        try {
            $layout = Test-LiteDeployDiskLayout -Number $DiskNumber -ExpectedBootMode $BootMode
            return ($layout | Select-Object DiskNumber, PartitionStyle, PartitionCount, ExpectedBootMode, IsValid, Issues)
        }
        catch {
            Write-Warning $_.Exception.Message
            return
        }
    }

    try {
        Write-ComponentLog "-ConfirmDestroy supplied: Disk $DiskNumber WILL be wiped and re-partitioned ($BootMode)." -Level "WARNING" -ForegroundColor Yellow
        $result = Invoke-DiskPreparation -TargetDiskNumber $DiskNumber -TargetBootMode $BootMode -TargetDriveLetter $OSTempDriveLetter
        return $result
    }
    catch {
        Write-ComponentLog "Disk format failure: $($_.Exception.Message)" -Level "ERROR" -ForegroundColor Red
        throw $_
    }
}
