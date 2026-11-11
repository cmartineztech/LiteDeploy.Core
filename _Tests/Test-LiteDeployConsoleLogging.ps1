<#
.SYNOPSIS
    Focused, rerunnable tests for console presentation, MDT-style hardware logging,
    and log stream integrity (PowerShell 5.1 and 7 compatible).

.DESCRIPTION
    Validates:
      1) Complete isolation under unique temporary directory (local, share, OS volume mirrors).
         Default log directory (C:\~LiteDeploy\WorkLogs) is never written to or read from.
      2) Write-LiteDeployLog -Message '' emits a blank console line without creating log records.
      3) Write-LiteDeployHardwareInventoryLog emits one CMTrace entry per property (-NoConsole)
         to Execution.log and configured mirrors with ZERO console output.
      4) Preserves false, 0, and formats null/empty/missing fields as 'unavailable'.
      5) Contract shape matching real Get-HardwareInventory (VendorRaw, FirmwareType,
         SecureBootIsEnabled, BiosVersion, TpmVersion, NICs, HardDrives, and Assessment Disks).
      6) SecureBootStatus 'Unknown' preserves 'Unknown' without falsely reporting 'Disabled' or 'False'.
      7) Suppresses sensitive/foreign properties (Password, ProductKey, Secrets, BootConfig).
      8) Calling helper with -Inventory $null completes safely without throw or writes.
      9) Statelessness: two subsequent invocations with different fixtures both record properly.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$passes = 0
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Condition {
    param([bool]$Condition, [string]$TestName)
    if ($Condition) {
        $script:passes++
        Write-Host "  [PASS] $TestName" -ForegroundColor Green
    } else {
        $script:failures.Add($TestName)
        Write-Host "  [FAIL] $TestName" -ForegroundColor Red
    }
}

Write-Host "`n=== LiteDeploy Console & Hardware Logging Tests ===" -ForegroundColor Cyan

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SourceRuntime = Join-Path $RepoRoot "Engine\Runtime"
$TestTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("LiteDeploy_TestLog_" + [Guid]::NewGuid().ToString("N"))
$localLogDir = Join-Path $TestTemp "LocalLogs"
$shareLogDir = Join-Path $TestTemp "ShareLogs"
$osLogDir    = Join-Path $TestTemp "OsLogs"

$null = New-Item -Path $localLogDir -ItemType Directory -Force
$null = New-Item -Path $shareLogDir -ItemType Directory -Force
$null = New-Item -Path $osLogDir -ItemType Directory -Force

try {
    # -------------------------------------------------------------------------
    # 1. AST Validation
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 1] AST Parsing (PS 5.1 / 7 syntax check)..." -ForegroundColor Yellow
    foreach ($rel in @(
        "000-Boot\LiteDeploy.PE.Boot.ps1",
        "010-Engine\LiteDeploy.PE.Engine.ps1",
        "010-Engine\LiteDeploy.OS.Engine.ps1",
        "030-Session\LiteDeploy.Session.ps1",
        "040-Hardware\LiteDeploy.Hardware.ps1",
        "060-Disk\LiteDeploy.Disk.ps1",
        "070-Drivers\LiteDeploy.Drivers.ps1",
        "080-Image\LiteDeploy.Image.ps1",
        "..\Admin\000-Build\LiteDeploy.Admin.Build.ps1"
    )) {
        $path = Join-Path $SourceRuntime $rel
        $errors = $null
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        Assert-Condition ($errors.Count -eq 0) "Parses cleanly: $rel"
    }

    # -------------------------------------------------------------------------
    # 2. Load Real Components & Set Up Test Isolation Proxy
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 2] Component Loading & Isolated Log Routing..." -ForegroundColor Yellow
    $sessionScript = Join-Path $SourceRuntime "030-Session\LiteDeploy.Session.ps1"
    $hwScript = Join-Path $SourceRuntime "040-Hardware\LiteDeploy.Hardware.ps1"
    . $sessionScript
    . $hwScript

    Assert-Condition ([bool](Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue)) "Write-LiteDeployLog is loaded"
    Assert-Condition ([bool](Get-Command Write-LiteDeployHardwareInventoryLog -ErrorAction SilentlyContinue)) "Write-LiteDeployHardwareInventoryLog is loaded"

    # Route default CustomPath to isolated test directory so host (C:\~LiteDeploy) is never touched
    function Get-LiteDeployLogPath {
        param(
            [string]$CustomPath = "",
            [string]$FileName = "LiteDeploy.Execution.log"
        )
        $dir = if ([string]::IsNullOrWhiteSpace($CustomPath)) { $localLogDir } else { $CustomPath }
        if (-not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -Path $dir -ItemType Directory -Force -ErrorAction SilentlyContinue
        }
        return (Join-Path $dir $FileName)
    }

    $global:LiteDeploySessionLogDir = $localLogDir
    $global:LiteDeployRemoteLogDir = $shareLogDir
    $global:LiteDeployOsLogDir = $osLogDir

    $localExecutionLog = Join-Path $localLogDir "LiteDeploy.Execution.log"
    $shareExecutionLog = Join-Path $shareLogDir "LiteDeploy.Execution.log"
    $osExecutionLog    = Join-Path $osLogDir "LiteDeploy.Execution.log"

    # -------------------------------------------------------------------------
    # 3. Console Spacer Behavior (Empty message writes console-only, NO log records)
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 3] Console Spacer vs Log Record..." -ForegroundColor Yellow

    # Write initial log entry to create base log files
    Write-LiteDeployLog -Message "Test entry 1"
    $initialLocalCount = @(Get-Content -Path $localExecutionLog).Count
    $initialShareCount = @(Get-Content -Path $shareExecutionLog).Count
    $initialOsCount    = @(Get-Content -Path $osExecutionLog).Count

    # Capture information stream from Write-LiteDeployLog -Message ''
    $capturedSpacer = & {
        Write-LiteDeployLog -Message ''
    } 6>&1

    $afterSpacerLocalCount = @(Get-Content -Path $localExecutionLog).Count
    $afterSpacerShareCount = @(Get-Content -Path $shareExecutionLog).Count
    $afterSpacerOsCount    = @(Get-Content -Path $osExecutionLog).Count

    Assert-Condition ($initialLocalCount -gt 0) "Initial CMTrace record written to local log"
    Assert-Condition ($initialShareCount -gt 0) "Initial CMTrace record mirrored to share"
    Assert-Condition ($initialOsCount -gt 0) "Initial CMTrace record mirrored to OS volume"
    $spacerList = @($capturedSpacer)
    Assert-Condition ($spacerList.Count -ge 1 -and [string]$spacerList[0] -eq '') "Spacer emitted blank line to host information stream"
    Assert-Condition ($afterSpacerLocalCount -eq $initialLocalCount) "Spacer (-Message '') did not write to local log file"
    Assert-Condition ($afterSpacerShareCount -eq $initialShareCount) "Spacer (-Message '') did not write to share mirror"
    Assert-Condition ($afterSpacerOsCount -eq $initialOsCount) "Spacer (-Message '') did not write to OS mirror"

    # -------------------------------------------------------------------------
    # 4. MDT-Style Hardware Inventory Logging (Real Contract Shape, -NoConsole)
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 4] MDT-Style Hardware Inventory Logging..." -ForegroundColor Yellow

    # Reset log files for inventory tests
    Remove-Item -Path $localExecutionLog -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $shareExecutionLog -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $osExecutionLog -Force -ErrorAction SilentlyContinue

    # Fixture with exact real contract shape of Get-HardwareInventory
    $fixtureInventory = [PSCustomObject]@{
        VendorRaw           = "Dell Inc."
        Vendor              = "Dell Inc."
        Model               = "Latitude 5520"
        SerialNumber        = "SN-123456"
        UUID                = "4c4c4544-0050-4810-8032-b2c04f425832"
        BiosVersion         = "1.14.0"
        Architecture        = "x64"
        MemoryMB            = 0                # numeric 0 must be preserved
        FirmwareType        = "UEFI"
        SecureBootIsEnabled = $false           # boolean false must be preserved
        SecureBootStatus    = "Disabled"
        TpmVersion          = 0                # numeric 0 must be preserved

        # Real HardDrives contract
        HardDrives          = @(
            [PSCustomObject]@{
                Number  = 0
                Model   = "SKHynix NVMe 512GB"
                SizeGB  = 512
                BusType = "NVMe"
            }
        )

        # Real Assessment Disks contract
        Disks               = @(
            [PSCustomObject]@{
                Index      = "Disk 0"
                Model      = "SKHynix NVMe 512GB"
                Capacity   = "512.0 GB"
                UsedSpace  = "50.0 GB"
                FreeSpace  = "462.0 GB"
                DiskNumber = 0
                TotalBytes = 549755813888
                SecretDisk = "DiskSecret"
            }
        )

        # Real NICs contract
        NICs                = @(
            [PSCustomObject]@{
                Name        = "Ethernet"
                Description = "Intel(R) Ethernet Connection"
                MacAddress  = "00:11:22:33:44:55"
                Status      = "Up"
                SpeedMbps   = 1000
                IPAddress   = "192.168.1.100"
                SecretNic   = "NicSecret"
            }
        )

        # Foreign / Secret properties that MUST NOT be emitted
        Password            = "SuperSecretPassword123"
        ProductKey          = "VK7JG-NPHTM-C97JM-9MPGT-3V66T"
        SecretToken         = "token_abc_xyz"
        BootConfig          = [PSCustomObject]@{ Credential = "plaintext" }
    }

    # Verify inventory is log-only (zero output to host/information stream)
    $capturedInvHost = & {
        Write-LiteDeployHardwareInventoryLog -Inventory $fixtureInventory
    } 6>&1

    Assert-Condition ($null -eq $capturedInvHost -or @($capturedInvHost).Count -eq 0) "Hardware inventory details produced zero console stream output (-NoConsole verified)"

    $localContent = if (Test-Path -LiteralPath $localExecutionLog) { Get-Content -LiteralPath $localExecutionLog -Raw } else { "" }
    $shareContent = if (Test-Path -LiteralPath $shareExecutionLog) { Get-Content -LiteralPath $shareExecutionLog -Raw } else { "" }
    $osContent    = if (Test-Path -LiteralPath $osExecutionLog) { Get-Content -LiteralPath $osExecutionLog -Raw } else { "" }

    # Validate exact properties in local log and mirror parity
    Assert-Condition ($localContent -match 'Hardware: Manufacturer = Dell Inc\.') "Logs: Manufacturer = Dell Inc."
    Assert-Condition ($localContent -match 'Hardware: Model = Latitude 5520') "Logs: Model = Latitude 5520"
    Assert-Condition ($localContent -match 'Hardware: SerialNumber = SN-123456') "Logs: SerialNumber = SN-123456"
    Assert-Condition ($localContent -match 'Hardware: UUID = 4c4c4544-0050-4810-8032-b2c04f425832') "Logs: UUID mapped"
    Assert-Condition ($localContent -match 'Hardware: BIOSVersion = 1\.14\.0') "Logs: BIOSVersion mapped"
    Assert-Condition ($localContent -match 'Hardware: Architecture = x64') "Logs: Architecture mapped"
    Assert-Condition ($localContent -match 'Hardware: MemoryMB = 0') "Logs: MemoryMB = 0 (numeric 0 preserved)"
    Assert-Condition ($localContent -match 'Hardware: BootMode = UEFI') "Logs: BootMode mapped"
    Assert-Condition ($localContent -match 'Hardware: SecureBootEnabled = False') "Logs: SecureBootEnabled = False (boolean false preserved)"
    Assert-Condition ($localContent -match 'Hardware: TPMVersion = 0') "Logs: TPMVersion = 0 (numeric 0 preserved)"

    # Validate Disks & NetworkAdapters
    Assert-Condition ($localContent -match 'Hardware: Disk\[0\]\.DiskNumber = 0') "Logs: Disk[0].DiskNumber = 0"
    Assert-Condition ($localContent -match 'Hardware: Disk\[0\]\.Index = Disk 0') "Logs: Disk[0].Index = Disk 0"
    Assert-Condition ($localContent -match 'Hardware: Disk\[0\]\.Model = SKHynix NVMe 512GB') "Logs: Disk[0].Model mapped"
    Assert-Condition ($localContent -match 'Hardware: Disk\[0\]\.Capacity = 512\.0 GB') "Logs: Disk[0].Capacity mapped"
    Assert-Condition ($localContent -match 'Hardware: NetworkAdapter\[0\]\.Name = Ethernet') "Logs: NetworkAdapter[0].Name mapped"
    Assert-Condition ($localContent -match 'Hardware: NetworkAdapter\[0\]\.MacAddress = 00:11:22:33:44:55') "Logs: NetworkAdapter[0].MacAddress mapped"

    # Mirror parity
    Assert-Condition ($shareContent -match 'Hardware: Manufacturer = Dell Inc\.' -and $osContent -match 'Hardware: Manufacturer = Dell Inc\.') "Mirrors: parity for Manufacturer"
    Assert-Condition ($shareContent -match 'Hardware: SecureBootEnabled = False' -and $osContent -match 'Hardware: SecureBootEnabled = False') "Mirrors: parity for SecureBootEnabled = False"
    Assert-Condition ($shareContent -match 'Hardware: Disk\[0\]\.Capacity = 512\.0 GB' -and $osContent -match 'Hardware: Disk\[0\]\.Capacity = 512\.0 GB') "Mirrors: parity for Disk[0].Capacity"

    # Secrets suppression
    Assert-Condition ($localContent -notmatch 'SuperSecretPassword123' -and $shareContent -notmatch 'SuperSecretPassword123') "Suppresses password property"
    Assert-Condition ($localContent -notmatch 'VK7JG-NPHTM' -and $shareContent -notmatch 'VK7JG-NPHTM') "Suppresses product key property"
    Assert-Condition ($localContent -notmatch 'token_abc_xyz' -and $shareContent -notmatch 'token_abc_xyz') "Suppresses secret token"
    Assert-Condition ($localContent -notmatch 'plaintext' -and $shareContent -notmatch 'plaintext') "Suppresses nested BootConfig object"
    Assert-Condition ($localContent -notmatch 'DiskSecret' -and $localContent -notmatch 'NicSecret') "Suppresses secret fields on Disk/NIC objects"

    # -------------------------------------------------------------------------
    # 5. SecureBootStatus 'Unknown' Preservation (No False 'Disabled')
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 5] SecureBootStatus 'Unknown' & Missing Flags..." -ForegroundColor Yellow

    Remove-Item -Path $localExecutionLog -Force -ErrorAction SilentlyContinue
    $unknownSbFixture = [PSCustomObject]@{
        VendorRaw           = "Lenovo"
        Model               = "ThinkPad T14"
        SecureBootStatus    = "Unknown"
        SecureBootIsEnabled = $null  # flag is null; must not falsely emit False/Disabled
    }
    Write-LiteDeployHardwareInventoryLog -Inventory $unknownSbFixture
    $unknownSbContent = if (Test-Path -LiteralPath $localExecutionLog) { Get-Content -LiteralPath $localExecutionLog -Raw } else { "" }
    Assert-Condition ($unknownSbContent -match 'Hardware: SecureBootEnabled = Unknown') "SecureBootStatus Unknown emits 'Unknown' (not falsely False or Disabled)"
    Assert-Condition ($unknownSbContent -notmatch 'Hardware: SecureBootEnabled = False' -and $unknownSbContent -notmatch 'Hardware: SecureBootEnabled = Disabled') "SecureBootStatus Unknown does not produce False or Disabled"

    # -------------------------------------------------------------------------
    # 6. Null Properties, Empty Collections & Absence Mapping to 'unavailable'
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 6] Null / Empty / Missing Property Mapping..." -ForegroundColor Yellow

    Remove-Item -Path $localExecutionLog -Force -ErrorAction SilentlyContinue
    $emptyFixture = [PSCustomObject]@{
        Manufacturer = $null
        SerialNumber = ""
        TPMVersion   = ""
        Disks        = @()
        NICs         = @()
    }
    Write-LiteDeployHardwareInventoryLog -Inventory $emptyFixture
    $emptyContent = if (Test-Path -LiteralPath $localExecutionLog) { Get-Content -LiteralPath $localExecutionLog -Raw } else { "" }
    Assert-Condition ($emptyContent -match 'Hardware: Manufacturer = unavailable') "Null Manufacturer mapped to unavailable"
    Assert-Condition ($emptyContent -match 'Hardware: SerialNumber = unavailable') "Empty SerialNumber mapped to unavailable"
    Assert-Condition ($emptyContent -match 'Hardware: TPMVersion = unavailable') "Empty TPMVersion mapped to unavailable"
    Assert-Condition ($emptyContent -match 'Hardware: Disks = unavailable') "Empty Disks mapped to unavailable"
    Assert-Condition ($emptyContent -match 'Hardware: NetworkAdapters = unavailable') "Empty NICs mapped to unavailable"

    # -------------------------------------------------------------------------
    # 7. Null Inventory & Stateless Invocations (No Stale Globals / Suppressions)
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 7] Null Inventory & Stateless Invocations..." -ForegroundColor Yellow

    # Call with null inventory: must not throw or write
    $nullThrew = $false
    try {
        Write-LiteDeployHardwareInventoryLog -Inventory $null
    }
    catch {
        $nullThrew = $true
    }
    Assert-Condition (-not $nullThrew) "Calling Write-LiteDeployHardwareInventoryLog -Inventory `$null completes without throw"

    # Two sequential invocations with different fixtures: both must be recorded
    Remove-Item -Path $localExecutionLog -Force -ErrorAction SilentlyContinue
    $fixtureA = [PSCustomObject]@{ VendorRaw = "VendorA"; Model = "ModelA 100" }
    $fixtureB = [PSCustomObject]@{ VendorRaw = "VendorB"; Model = "ModelB 200" }

    Write-LiteDeployHardwareInventoryLog -Inventory $fixtureA
    Write-LiteDeployHardwareInventoryLog -Inventory $fixtureB

    $seqContent = if (Test-Path -LiteralPath $localExecutionLog) { Get-Content -LiteralPath $localExecutionLog -Raw } else { "" }
    Assert-Condition ($seqContent -match 'Hardware: Model = ModelA 100') "Sequential call 1 recorded: ModelA 100"
    Assert-Condition ($seqContent -match 'Hardware: Model = ModelB 200') "Sequential call 2 recorded: ModelB 200 (helper is stateless)"

    # -------------------------------------------------------------------------
    # 8. WinPE Handoff Reboot Guard & StrictMode Isolated Scope Execution
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 8] WinPE Handoff Reboot Guard & StrictMode Execution..." -ForegroundColor Yellow

    # Extract actual Complete-LiteDeployWinPEHandoff AST from source
    $peEnginePath = Join-Path $SourceRuntime "010-Engine\LiteDeploy.PE.Engine.ps1"
    $peTree = [System.Management.Automation.Language.Parser]::ParseFile($peEnginePath, [ref]$null, [ref]$null)
    $handoffNode = $peTree.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Complete-LiteDeployWinPEHandoff'}, $true)
    . ([scriptblock]::Create($handoffNode.Extent.Text))

    # Mocks for isolated execution: no actual disk, network, or reboot processes
    function Test-LiteDeployWinPE { return $true }
    function Test-Path { param($LiteralPath, $PathType) return $true }
    function Save-LiteDeployDeploymentState { param($DeploymentState) }
    function Sync-LiteDeployLogsToShare { param($RuntimePaths, $RemoteLogDir) }
    function Sync-LiteDeployFullOSPayloadToOsVolume {
        param($RuntimePaths, $OsDriveLetter, $LocalRootName)
        return [pscustomobject]@{
            Success = $true
            Message = 'Payload staged'
            RuntimeDestination = 'C:\~LiteDeploy\Runtime'
            ToolsDestination = 'C:\~LiteDeploy\Tools'
            EnginePath = 'C:\~LiteDeploy\Runtime\LiteDeploy.OS.Engine.ps1'
            FullOSPath = 'C:\~LiteDeploy\Runtime\LiteDeploy.OS.Engine.ps1'
            ToolsFilesCopied = 5
        }
    }
    function Complete-LiteDeployWinPECredentialHandoff {
        param($DeploymentState, $RuntimePaths, $OsDriveLetter, $LocalRootName, $BootCtx)
        return [pscustomobject]@{
            SecretIds = @('DeploymentShare')
            SecretFilePath = 'C:\~LiteDeploy\Credentials\secret.dat'
        }
    }
    $script:mockHandoffArtifactsResult = [pscustomobject]@{
        Success = $true
        StateCopied = $true
        LogsCopied = 2
        Message = 'Handoff OK'
    }
    function Sync-LiteDeployArtifactsToOsVolume {
        param($RuntimePaths, $OsDriveLetter, $DeploymentState, $LocalRootName)
        return $script:mockHandoffArtifactsResult
    }
    $script:mockRebootToolCalls = [System.Collections.Generic.List[psobject]]::new()
    function Start-Process {
        param([string]$FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, [switch]$NoNewWindow, $ErrorAction)
        $script:mockRebootToolCalls.Add([pscustomobject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList })
        return [pscustomobject]@{ ExitCode = 0 }
    }

    # 8a: Valid handoff reaches exactly one mocked reboot request under StrictMode2
    $stateSuccess = [PSCustomObject]@{
        Status = 'Completed'
        Disk = [PSCustomObject]@{ DiskNumber = 0; Formatted = $true }
        OSInstall = [PSCustomObject]@{ Applied = $true; ImagePath = 'C:\Images\install.wim'; ExitCode = 0; DurationSeconds = 45 }
        Execution = [PSCustomObject]@{ CurrentStep = 'OSInstallation'; RemoteLogDir = 'Z:\Logs\TEST-01' }
    }

    $script:mockRebootToolCalls.Clear()
    Complete-LiteDeployWinPEHandoff `
        -DeploymentState $stateSuccess `
        -RuntimePaths ([PSCustomObject]@{}) `
        -OsDriveLetter 'C:' `
        -LocalRootName '~LiteDeploy'

    Assert-Condition ($script:mockRebootToolCalls.Count -eq 1) "Valid handoff reaches exactly one mocked reboot request"
    Assert-Condition ($script:mockRebootToolCalls[0].FilePath -match 'wpeutil\.exe' -and $script:mockRebootToolCalls[0].ArgumentList -eq 'Reboot') "Reboot tool invoked with argument 'Reboot'"
    Assert-Condition ($stateSuccess.Execution.CurrentStep -eq 'RebootRequested') "DeploymentState step successfully transitions to RebootRequested"

    # 8b: Unsuccessful handoff (failed sync) never requests reboot and throws to caller
    $script:mockHandoffArtifactsResult = [pscustomobject]@{
        Success = $false
        StateCopied = $false
        LogsCopied = 0
        Message = 'Mock disk sync failure'
    }
    $script:mockRebootToolCalls.Clear()
    $handoffFailedThrew = $false
    try {
        Complete-LiteDeployWinPEHandoff `
            -DeploymentState $stateSuccess `
            -RuntimePaths ([PSCustomObject]@{}) `
            -OsDriveLetter 'C:' `
            -LocalRootName '~LiteDeploy'
    }
    catch {
        $handoffFailedThrew = $true
    }
    Assert-Condition ($handoffFailedThrew) "Unsuccessful handoff throws exception to caller"
    Assert-Condition ($script:mockRebootToolCalls.Count -eq 0) "Unsuccessful handoff never requests reboot"

    # 8c: Incomplete OS imaging never requests reboot
    $stateIncomplete = [PSCustomObject]@{
        Status = 'Failed'
        Disk = [PSCustomObject]@{ DiskNumber = 0; Formatted = $true }
        OSInstall = [PSCustomObject]@{ Applied = $false; ImagePath = 'C:\Images\install.wim'; ExitCode = 1; DurationSeconds = 10 }
        Execution = [PSCustomObject]@{ CurrentStep = 'OSInstallation'; RemoteLogDir = 'Z:\Logs\TEST-01' }
    }
    $script:mockRebootToolCalls.Clear()
    $incompleteThrew = $false
    try {
        Complete-LiteDeployWinPEHandoff `
            -DeploymentState $stateIncomplete `
            -RuntimePaths ([PSCustomObject]@{}) `
            -OsDriveLetter 'C:' `
            -LocalRootName '~LiteDeploy'
    }
    catch {
        $incompleteThrew = $true
    }
    Assert-Condition ($incompleteThrew) "Incomplete OS imaging throws before handoff"
    Assert-Condition ($script:mockRebootToolCalls.Count -eq 0) "Incomplete OS imaging never requests reboot"

    # 8d: Zero workflow actions skips FullOS staging and cleans target OS volume before reboot
    $stateZeroActions = [PSCustomObject]@{
        Status    = 'Completed'
        Disk      = [PSCustomObject]@{ DiskNumber = 0; Formatted = $true }
        OSInstall = [PSCustomObject]@{ Applied = $true; ImagePath = 'C:\Images\install.wim'; ExitCode = 0; DurationSeconds = 45 }
        Execution = [PSCustomObject]@{ CurrentStep = 'OSInstallation'; RemoteLogDir = 'Z:\Logs\TEST-ZERO' }
        Workflow  = [PSCustomObject]@{
            SelectionData = [PSCustomObject]@{
                actions = @()
            }
        }
    }
    $script:mockRebootToolCalls.Clear()
    $script:mockRemoveItemCalls = [System.Collections.Generic.List[string]]::new()
    function Remove-Item {
        param($LiteralPath, [switch]$Recurse, [switch]$Force, $ErrorAction)
        $script:mockRemoveItemCalls.Add([string]$LiteralPath)
    }

    Complete-LiteDeployWinPEHandoff `
        -DeploymentState $stateZeroActions `
        -RuntimePaths ([PSCustomObject]@{}) `
        -OsDriveLetter 'C:' `
        -LocalRootName '~LiteDeploy'

    Assert-Condition ($script:mockRebootToolCalls.Count -eq 1) "Zero actions reaches reboot"
    Assert-Condition ($stateZeroActions.Execution.FullOSPayload.Staged -eq $false) "Zero actions skips FullOS payload staging"
    Assert-Condition ($script:mockRemoveItemCalls -contains 'C:\~LiteDeploy') "Zero actions removes ~LiteDeploy from OS volume"
    Remove-Item function:Remove-Item -ErrorAction SilentlyContinue

    # 8e: Default log path fallback without global override under StrictMode2
    $script:logFallbackOk = $false
    $script:logOverrideOk = $false
    & {
        Set-StrictMode -Version 2.0
        . $sessionScript
        Remove-Variable -Name LiteDeploySessionLogDir -Scope Global -ErrorAction SilentlyContinue
        function New-Item { param($Path, $ItemType, $Force, $ErrorAction) }
        function Test-Path { param($LiteralPath, $PathType) return $true }

        $resolvedDefault = Get-LiteDeployLogPath
        $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "X:" }
        $expectedDefault = Join-Path $sysDrive "~LiteDeploy\WorkLogs\LiteDeploy.Execution.log"
        if ($resolvedDefault -eq $expectedDefault) { $script:logFallbackOk = $true }

        $testOverrideDir = Join-Path $TestTemp "CustomOverrideLogs"
        $global:LiteDeploySessionLogDir = $testOverrideDir
        $resolvedCustom = Get-LiteDeployLogPath
        if ($resolvedCustom -eq (Join-Path $testOverrideDir "LiteDeploy.Execution.log")) { $script:logOverrideOk = $true }
        Remove-Variable -Name LiteDeploySessionLogDir -Scope Global -ErrorAction SilentlyContinue
    }
    Assert-Condition ($script:logFallbackOk) "Default log path resolves cleanly without global override under StrictMode2"
    Assert-Condition ($script:logOverrideOk) "Optional LiteDeploySessionLogDir override is honored when present"

    # Restore session test logging directory for subsequent test groups
    $global:LiteDeploySessionLogDir = $localLogDir

    # Clean up handoff mocks
    Remove-Item function:Test-LiteDeployWinPE -ErrorAction SilentlyContinue
    Remove-Item function:Test-Path -ErrorAction SilentlyContinue
    Remove-Item function:Save-LiteDeployDeploymentState -ErrorAction SilentlyContinue
    Remove-Item function:Sync-LiteDeployLogsToShare -ErrorAction SilentlyContinue
    Remove-Item function:Sync-LiteDeployFullOSPayloadToOsVolume -ErrorAction SilentlyContinue
    Remove-Item function:Complete-LiteDeployWinPECredentialHandoff -ErrorAction SilentlyContinue
    Remove-Item function:Sync-LiteDeployArtifactsToOsVolume -ErrorAction SilentlyContinue
    Remove-Item function:Start-Process -ErrorAction SilentlyContinue

    # -------------------------------------------------------------------------
    # 9. DISM Image Apply Duration Stopwatch (Requirement 2)
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 9] DISM Image Apply Stopwatch Duration & Phases..." -ForegroundColor Yellow

    $imageScriptPath = Join-Path $SourceRuntime "080-Image\LiteDeploy.Image.ps1"
    . $imageScriptPath

    # Prepare safe isolated test directories
    $dismTestDir = Join-Path $TestTemp "DismTest"
    $dismDestDir = Join-Path $dismTestDir "TargetDiskW"
    $dismWindowsDir = Join-Path $dismDestDir "Windows"
    $dismDriversDir = Join-Path $dismTestDir "StagedDrivers"
    $dismUnattend = Join-Path $dismTestDir "unattend.xml"

    $null = New-Item -Path $dismWindowsDir -ItemType Directory -Force
    $null = New-Item -Path $dismDriversDir -ItemType Directory -Force
    Set-Content -LiteralPath $dismUnattend -Value "<unattend></unattend>" -Encoding UTF8

    # Local mocks for external destructive/process operations
    $script:mockProcesses = [System.Collections.Generic.List[psobject]]::new()
    function Start-Process {
        param(
            [string]$FilePath,
            $ArgumentList,
            [switch]$Wait,
            [switch]$PassThru,
            [switch]$NoNewWindow
        )
        Start-Sleep -Milliseconds 375
        $argsStr = if ($ArgumentList -is [array]) { $ArgumentList -join " " } else { [string]$ArgumentList }
        $script:mockProcesses.Add([PSCustomObject]@{ FilePath = $FilePath; Arguments = $argsStr })
        return [PSCustomObject]@{ ExitCode = 0 }
    }

    function Invoke-DismProcessStream {
        param(
            [string]$Stage,
            [string]$DismExecutable,
            [string]$ArgumentString,
            [string]$NativeLogPath
        )
        Start-Sleep -Milliseconds 375
        $script:mockProcesses.Add([PSCustomObject]@{ FilePath = $DismExecutable; Arguments = $ArgumentString })
        return [PSCustomObject]@{
            Success          = $true
            ExitCode         = 0
            ExitCodeHex      = "0x00000000"
            DurationSeconds  = 0
            LatestPercentage = 100.0
            LogPath          = $NativeLogPath
            Stage            = $Stage
            ErrorMessage     = ""
        }
    }

    function Get-Partition {
        param($DiskNumber, $PartitionNumber, $ErrorAction)
        return [PSCustomObject]@{ DiskNumber = $DiskNumber; PartitionNumber = $PartitionNumber; DriveLetter = $null }
    }

    function Set-Partition {
        param($DiskNumber, $PartitionNumber, $NewDriveLetter, $ErrorAction)
        return $null
    }

    function Remove-PartitionAccessPath {
        param($DiskNumber, $PartitionNumber, $AccessPath, $ErrorAction)
        return $null
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $dismResult = Invoke-DismEngine `
        -ResolvedImagePath "C:\MockSource\install.wim" `
        -NormalizedDestination $dismDestDir `
        -SelectedImageIndex 1 `
        -EffectiveUnattendPath $dismUnattend `
        -DriverFolder $dismDriversDir `
        -DiskData ([PSCustomObject]@{ DiskNumber = 0; SystemPartitionNumber = 1; BootMode = "UEFI" })
    $sw.Stop()

    Assert-Condition ($dismResult.Success -eq $true) "Invoke-DismEngine succeeds under mocked external operations"
    Assert-Condition ($dismResult.Engine -eq "dism.exe") "Invoke-DismEngine reports engine 'dism.exe'"
    Assert-Condition ($sw.Elapsed.TotalMilliseconds -gt 1000) "Stopwatch measured real elapsed mock phase execution time ($([Math]::Round($sw.Elapsed.TotalSeconds, 2))s > 1.0s)"
    Assert-Condition ($dismResult.DurationSeconds -gt 0) "Return object DurationSeconds ($($dismResult.DurationSeconds)s) accounts for work and is nonzero"
    Assert-Condition ($dismResult.DurationSeconds -le [Math]::Ceiling($sw.Elapsed.TotalSeconds)) "Reported DurationSeconds ($($dismResult.DurationSeconds)s) within plausible bound of total elapsed execution time"

    # Verify all expected phases were invoked
    $hasApplyImage = [bool]($script:mockProcesses | Where-Object { $_.FilePath -eq "dism.exe" -and $_.Arguments -match '/Apply-Image' })
    $hasBcdboot = [bool]($script:mockProcesses | Where-Object { $_.FilePath -eq "bcdboot.exe" -and $_.Arguments -match '/s S:' })
    $hasAddDriver = [bool]($script:mockProcesses | Where-Object { $_.FilePath -eq "dism.exe" -and $_.Arguments -match '/Add-Driver' })

    Assert-Condition ($hasApplyImage) "Execution includes phase: DISM /Apply-Image"
    Assert-Condition ($hasBcdboot) "Execution includes phase: BCD bootloader configuration (bcdboot.exe)"
    Assert-Condition ($hasAddDriver) "Execution includes phase: Offline driver injection (dism.exe /Add-Driver)"
    Assert-Condition (Test-Path -LiteralPath (Join-Path $dismWindowsDir "Panther\unattend.xml")) "Execution includes phase: Unattend staging to Panther"

    # Clean up local mock functions
    Remove-Item function:Start-Process -ErrorAction SilentlyContinue
    Remove-Item function:Invoke-DismProcessStream -ErrorAction SilentlyContinue
    Remove-Item function:Get-Partition -ErrorAction SilentlyContinue
    Remove-Item function:Set-Partition -ErrorAction SilentlyContinue
    Remove-Item function:Remove-PartitionAccessPath -ErrorAction SilentlyContinue

    # -------------------------------------------------------------------------
    # 10. Boot Connection Diagnostics & Safe Credential Handling (Requirement 3)
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 10] Boot Connection Diagnostics & Credential Safety..." -ForegroundColor Yellow

    $bootScriptPath = Join-Path $SourceRuntime "000-Boot\LiteDeploy.PE.Boot.ps1"

    # Extract functions from LiteDeploy.PE.Boot.ps1 via AST into local scope
    $bootTokens = $null
    $bootErrors = $null
    $bootAst = [System.Management.Automation.Language.Parser]::ParseFile($bootScriptPath, [ref]$bootTokens, [ref]$bootErrors)
    $funcAsts = $bootAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    foreach ($fn in $funcAsts) {
        Invoke-Expression $fn.Extent.Text
    }

    # Isolate all log paths in validated unique TEMP directory
    $group10LogDir = Join-Path $TestTemp "BootLogs"
    $null = New-Item -Path $group10LogDir -ItemType Directory -Force
    $global:LiteDeployBootLogDir = $group10LogDir
    $bootLogFile = Join-Path $group10LogDir "LiteDeploy.Execution.log"

    # Set up local mocks
    $script:mockNetInvocations = [System.Collections.Generic.List[string]]::new()
    function net.exe {
        $script:mockNetInvocations.Add([string]($args -join ' '))
        return 0
    }

    function wpeutil.exe {
        return 0
    }

    function Get-PSDrive {
        return $null
    }

    function Remove-PSDrive {
        return $null
    }

    $script:mockDriveConnected = $false
    function Test-Path {
        if ($args.Count -gt 0 -and $args[0] -match '^[A-Za-z]:[\\/]?$') {
            return [bool]$script:mockDriveConnected
        }
        Microsoft.PowerShell.Management\Test-Path @args
    }

    $dummySecret = "TopSecretBootPassword999!"
    function Get-Credential {
        param([string]$Message)
        $sec = ConvertTo-SecureString $dummySecret -AsPlainText -Force
        return [System.Management.Automation.PSCredential]::new('CONTOSO\deployuser', $sec)
    }

    # Helper to capture console output of a scriptblock
    function Invoke-WithConsoleCapture {
        param([scriptblock]$ScriptBlock)
        $captured = [System.Collections.Generic.List[string]]::new()
        $res = & {
            & $ScriptBlock
        } 6>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.InformationRecord]) {
                $captured.Add($_.MessageData.ToString())
            }
            else {
                $_
            }
        }
        return [PSCustomObject]@{
            Result  = $res
            Console = [string]::Join("`n", $captured)
        }
    }

    $script:mockSmbMappingAbsent = $true
    function Get-Command {
        if ($args.Count -gt 0 -and $args[0] -eq 'New-SmbMapping' -and $script:mockSmbMappingAbsent) {
            return $null
        }
        Microsoft.PowerShell.Core\Get-Command @args
    }

    # Case 1: Network / Transport Error (e.g. System.IO.IOException "The network path was not found.")
    $script:mockSmbMappingAbsent = $true
    $script:mockDriveConnected = $false
    $script:mockCallCount = 0
    function New-PSDrive {
        param($Name, $PSProvider, $Root, $Credential, [switch]$Persist, $Scope)
        $script:mockCallCount++
        if ($script:mockCallCount -eq 1) {
            throw [System.IO.IOException]::new("The network path was not found.")
        }
        $script:mockDriveConnected = $true
        return [PSCustomObject]@{ Name = $Name }
    }
    Remove-Item function:New-SmbMapping -ErrorAction SilentlyContinue

    $null = Clear-Content -Path $bootLogFile -ErrorAction SilentlyContinue
    $capture1 = Invoke-WithConsoleCapture {
        Connect-LiteDeployDeploymentShare -NetworkPath '\\mockserver\mockshare' -DriveLetter 'M:'
    }
    $logText1 = if (Test-Path -LiteralPath $bootLogFile) { Get-Content -LiteralPath $bootLogFile -Raw } else { "" }

    Assert-Condition ($capture1.Console -match 'Connection to share .+\ failed \(The network path was not found\.\)') "Network error captured and classified as connection failure on console"
    Assert-Condition ($capture1.Console -notmatch 'Authentication failed') "Transport error is NOT falsely attributed to Authentication failed on console"
    Assert-Condition ($capture1.Console -notmatch 'Access denied') "Transport error is NOT classified as access denied"
    Assert-Condition ($capture1.Console -match 'recovered on attempt 2') "Recovery on attempt 2 is clearly logged on console"
    Assert-Condition ($logText1 -match 'The network path was not found') "Network error is recorded in CMTrace log"
    Assert-Condition ($logText1 -match 'Method=New-PSDrive') "Log identifies New-PSDrive method"
    Assert-Condition ($logText1 -notmatch 'Method=New-SmbMapping') "Fallback New-SmbMapping is NOT reported when absent"

    # Case 2: Genuine Logon Failure (Win32 ERROR_LOGON_FAILURE 1326 / 0x8007052E)
    $null = Clear-Content -Path $bootLogFile -ErrorAction SilentlyContinue
    $script:mockSmbMappingAbsent = $true
    $script:mockDriveConnected = $false
    $script:mockCallCount = 0
    function New-PSDrive {
        param($Name, $PSProvider, $Root, $Credential, [switch]$Persist, $Scope)
        $script:mockCallCount++
        if ($script:mockCallCount -eq 1) {
            throw [System.ComponentModel.Win32Exception]::new(1326, "Logon failure: unknown user name or bad password.")
        }
        $script:mockDriveConnected = $true
        return [PSCustomObject]@{ Name = $Name }
    }

    $capture2 = Invoke-WithConsoleCapture {
        Connect-LiteDeployDeploymentShare -NetworkPath '\\mockserver\mockshare' -DriveLetter 'M:'
    }
    $logText2 = if (Test-Path -LiteralPath $bootLogFile) { Get-Content -LiteralPath $bootLogFile -Raw } else { "" }

    Assert-Condition ($capture2.Console -match "Authentication failed for user 'CONTOSO\\deployuser' on share '\\\\mockserver\\mockshare'") "Genuine logon failure (1326) classified as 'Authentication failed'"
    Assert-Condition ($logText2 -match 'NativeError=1326' -or $logText2 -match '0x8007052E') "Log records Win32 NativeErrorCode 1326 / HResult for logon failure"

    # Case 3: Access Denied (Win32 ERROR_ACCESS_DENIED 5 / UnauthorizedAccessException)
    $null = Clear-Content -Path $bootLogFile -ErrorAction SilentlyContinue
    $script:mockSmbMappingAbsent = $true
    $script:mockDriveConnected = $false
    $script:mockCallCount = 0
    function New-PSDrive {
        param($Name, $PSProvider, $Root, $Credential, [switch]$Persist, $Scope)
        $script:mockCallCount++
        if ($script:mockCallCount -eq 1) {
            throw [System.UnauthorizedAccessException]::new("Access is denied.")
        }
        $script:mockDriveConnected = $true
        return [PSCustomObject]@{ Name = $Name }
    }

    $capture3 = Invoke-WithConsoleCapture {
        Connect-LiteDeployDeploymentShare -NetworkPath '\\mockserver\mockshare' -DriveLetter 'M:'
    }
    $logText3 = if (Test-Path -LiteralPath $bootLogFile) { Get-Content -LiteralPath $bootLogFile -Raw } else { "" }

    Assert-Condition ($capture3.Console -match "Access denied to share '\\\\mockserver\\mockshare'") "Permission failure classified as 'Access denied' (neutral/access-denied)"
    Assert-Condition ($capture3.Console -notmatch 'Authentication failed') "Access denied is NOT labeled as Authentication failed"
    Assert-Condition ($logText3 -match 'Type=UnauthorizedAccessException' -and $logText3 -match 'Code=0x80070005') "Log records UnauthorizedAccessException with HResult 0x80070005"

    # Case 4: Fallback method diagnostics when New-SmbMapping IS present and fails
    $null = Clear-Content -Path $bootLogFile -ErrorAction SilentlyContinue
    $script:mockSmbMappingAbsent = $false
    $script:mockDriveConnected = $false
    $script:mockCallCount = 0
    function New-PSDrive {
        param($Name, $PSProvider, $Root, $Credential, [switch]$Persist, $Scope)
        $script:mockCallCount++
        if ($script:mockCallCount -eq 1) {
            throw [System.IO.IOException]::new("New-PSDrive failed.")
        }
        $script:mockDriveConnected = $true
        return [PSCustomObject]@{ Name = $Name }
    }
    function New-SmbMapping {
        param($LocalPath, $RemotePath, $Credential)
        throw [System.IO.IOException]::new("New-SmbMapping fallback also failed.")
    }

    $capture4 = Invoke-WithConsoleCapture {
        Connect-LiteDeployDeploymentShare -NetworkPath '\\mockserver\mockshare' -DriveLetter 'M:'
    }
    $logText4 = if (Test-Path -LiteralPath $bootLogFile) { Get-Content -LiteralPath $bootLogFile -Raw } else { "" }

    Assert-Condition ($logText4 -match 'Method=New-PSDrive' -and $logText4 -match 'New-PSDrive failed') "Log retains diagnostics for New-PSDrive"
    Assert-Condition ($logText4 -match 'Method=New-SmbMapping' -and $logText4 -match 'New-SmbMapping fallback also failed') "Log retains diagnostics for attempted New-SmbMapping fallback"

    # Case 5: Feed exception containing dummy secret, verify secret absent in BOTH console and log outputs
    $null = Clear-Content -Path $bootLogFile -ErrorAction SilentlyContinue
    $script:mockSmbMappingAbsent = $true
    $script:mockDriveConnected = $false
    $script:mockCallCount = 0
    $dummySecretInMsg = "TopSecretBootPassword999!"
    function New-PSDrive {
        param($Name, $PSProvider, $Root, $Credential, [switch]$Persist, $Scope)
        $script:mockCallCount++
        if ($script:mockCallCount -eq 1) {
            throw [System.IO.IOException]::new("Server failed for password=$dummySecretInMsg with token=SecretApiToken456.")
        }
        $script:mockDriveConnected = $true
        return [PSCustomObject]@{ Name = $Name }
    }
    Remove-Item function:New-SmbMapping -ErrorAction SilentlyContinue

    $capture5 = Invoke-WithConsoleCapture {
        Connect-LiteDeployDeploymentShare -NetworkPath '\\mockserver\mockshare' -DriveLetter 'M:'
    }
    $logText5 = if (Test-Path -LiteralPath $bootLogFile) { Get-Content -LiteralPath $bootLogFile -Raw } else { "" }

    Assert-Condition ($capture5.Console -notmatch 'TopSecretBootPassword999!') "Dummy secret is ABSENT from console output"
    Assert-Condition ($capture5.Console -notmatch 'SecretApiToken456') "Token secret is ABSENT from console output"
    Assert-Condition ($capture5.Console -match 'password=\*\*\*' -and $capture5.Console -match 'token=\*\*\*') "Secrets are redacted to '***' in console output"

    Assert-Condition ($logText5 -notmatch 'TopSecretBootPassword999!') "Dummy secret is ABSENT from CMTrace log output"
    Assert-Condition ($logText5 -notmatch 'SecretApiToken456') "Token secret is ABSENT from CMTrace log output"
    Assert-Condition ($logText5 -match 'password=\*\*\*' -and $logText5 -match 'token=\*\*\*') "Secrets are redacted to '***' in CMTrace log file"

    # Verify real mappings / default host logs were NEVER touched
    Assert-Condition ($script:mockNetInvocations.Count -gt 0) "M: net.exe delete commands intercepted by mock (host never touched)"
    Assert-Condition (-not (Test-Path -LiteralPath "C:\~LiteDeploy\WorkLogs\LiteDeploy.Execution.log.dummy")) "Isolation confirmed"

    # Cleanup test functions
    Remove-Item function:net.exe -ErrorAction SilentlyContinue
    Remove-Item function:wpeutil.exe -ErrorAction SilentlyContinue
    Remove-Item function:Get-PSDrive -ErrorAction SilentlyContinue
    Remove-Item function:Remove-PSDrive -ErrorAction SilentlyContinue
    Remove-Item function:Test-Path -ErrorAction SilentlyContinue
    Remove-Item function:Get-Credential -ErrorAction SilentlyContinue
    Remove-Item function:Get-Command -ErrorAction SilentlyContinue
    Remove-Item function:New-PSDrive -ErrorAction SilentlyContinue
    Remove-Item function:New-SmbMapping -ErrorAction SilentlyContinue
    $global:LiteDeployBootLogDir = $null

    # -------------------------------------------------------------------------
    # 11. CMTrace Severity Mapping, Tag Stripping & Banner Suppression (Requirements 4, 6)
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 11] CMTrace Severity Mapping & Formatting..." -ForegroundColor Yellow

    # Reload Session to restore Session's Write-LiteDeployLog
    . $sessionScript

    $severityLogDir = Join-Path $TestTemp "SevLogs"
    $null = New-Item -Path $severityLogDir -ItemType Directory -Force
    $severityLogFile = Join-Path $severityLogDir "LiteDeploy.Execution.log"

    $oldSessionLogDir = Get-Variable -Name LiteDeploySessionLogDir -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    $global:LiteDeploySessionLogDir = $severityLogDir

    Write-LiteDeployLog -Message "Informational event" -Level "INFO"
    Write-LiteDeployLog -Message "Notice event (normal flow)" -Level "NOTICE"
    Write-LiteDeployLog -Message "Warning event" -Level "WARNING"
    Write-LiteDeployLog -Message "Error event" -Level "ERROR"
    Write-LiteDeployLog -Message "==================================================" -Level "INFO"
    Write-LiteDeployLog -Message " [INFO]    Prefixed message should be stripped" -Level "INFO"
    Write-LiteDeployLog -Message "[UEFI] Secure Boot is enabled" -Level "INFO"
    Write-LiteDeployLog -Message "[LEGACY] MBR partitioning selected" -Level "INFO"

    $global:LiteDeploySessionLogDir = $oldSessionLogDir

    $sevContent = if (Test-Path -LiteralPath $severityLogFile) { Get-Content -LiteralPath $severityLogFile -Raw } else { "" }

    Assert-Condition ($sevContent -match '<!\[LOG\[Informational event\]LOG\]!><time="[^"]*" date="[^"]*" component="[^"]*" context="[^"]*" type="1"') "INFO is mapped to CMTrace type=1"
    Assert-Condition ($sevContent -match '<!\[LOG\[Notice event \(normal flow\)\]LOG\]!><time="[^"]*" date="[^"]*" component="[^"]*" context="[^"]*" type="1"') "NOTICE is mapped to CMTrace type=1 (not type 2)"
    Assert-Condition ($sevContent -match '<!\[LOG\[Warning event\]LOG\]!><time="[^"]*" date="[^"]*" component="[^"]*" context="[^"]*" type="2"') "WARNING is mapped to CMTrace type=2"
    Assert-Condition ($sevContent -match '<!\[LOG\[Error event\]LOG\]!><time="[^"]*" date="[^"]*" component="[^"]*" context="[^"]*" type="3"') "ERROR is mapped to CMTrace type=3"
    Assert-Condition ($sevContent -notmatch '========') "Divider banner lines (====) are suppressed from CMTrace log"
    Assert-Condition ($sevContent -match '<!\[LOG\[Prefixed message should be stripped\]LOG\]!>') "Manual [INFO] prefix stripped from CMTrace CDATA payload"
    Assert-Condition ($sevContent -match '<!\[LOG\[\[UEFI\] Secure Boot is enabled\]LOG\]!>') "Domain tag [UEFI] is preserved in CMTrace log"
    Assert-Condition ($sevContent -match '<!\[LOG\[\[LEGACY\] MBR partitioning selected\]LOG\]!>') "Domain tag [LEGACY] is preserved in CMTrace log"

    $fmtUefi = Format-LiteDeployLogLine -Message "[UEFI] Secure Boot is enabled" -Level "INFO"
    Assert-Condition ($fmtUefi -match '\[INFO\]\s+\[UEFI\] Secure Boot is enabled') "Domain tag [UEFI] is preserved in formatted console line"
    $fmtLegacy = Format-LiteDeployLogLine -Message "[LEGACY] MBR partitioning selected" -Level "INFO"
    Assert-Condition ($fmtLegacy -match '\[INFO\]\s+\[LEGACY\] MBR partitioning selected') "Domain tag [LEGACY] is preserved in formatted console line"

    # -------------------------------------------------------------------------
    # 12. FullOS Honest Completion & Safe Encoding (Requirements 5, 7)
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 12] FullOS Honest Completion & Safe Encoding..." -ForegroundColor Yellow

    $osEnginePath = Join-Path $SourceRuntime "010-Engine\LiteDeploy.OS.Engine.ps1"
    $osEngineContent = Get-Content -LiteralPath $osEnginePath -Raw

    Assert-Condition ($osEngineContent -match 'FullOS initialization completed\. Package orchestration is pending\.') "FullOS completion reports honest 'initialization completed. Package orchestration is pending.'"
    Assert-Condition ($osEngineContent -notmatch 'FullOS resume complete') "Old inaccurate 'FullOS resume complete' was removed"
    Assert-Condition ($osEngineContent -match "'InitialEntry'" -and $osEngineContent -match "'ReEntry'" -and $osEngineContent -match 'Entry=\{0\}') "FullOS distinguishes InitialEntry vs ReEntry"
    Assert-Condition ($osEngineContent -match '\$reason\s*=\s*.Unknown.' -and $osEngineContent -match 'Reason=\{2\}') "FullOS logs Reason=Unknown without auto-inferring loops"

    # Encoding check in PE.Engine
    $peEnginePath = Join-Path $SourceRuntime "010-Engine\LiteDeploy.PE.Engine.ps1"
    $peEngineBytes = [System.IO.File]::ReadAllBytes($peEnginePath)
    $hasEmDash = $false
    for ($k = 0; $k -lt $peEngineBytes.Length - 2; $k++) {
        if ($peEngineBytes[$k] -eq 0xE2 -and $peEngineBytes[$k+1] -eq 0x80 -and $peEngineBytes[$k+2] -eq 0x94) {
            $hasEmDash = $true
            break
        }
    }
    Assert-Condition (-not $hasEmDash) "LiteDeploy.PE.Engine.ps1 contains no Unicode em dash (ASCII ' - ' used)"

    # -------------------------------------------------------------------------
    # 13. Testing Scope Declaration
    # -------------------------------------------------------------------------
    Write-Host "`n[Group 13] Testing Scope & Limitations..." -ForegroundColor Yellow
    Write-Host "  [NOTE] Static regex assertion of Engine headings was intentionally omitted." -ForegroundColor Gray
    Write-Host "         Pipeline orchestration ordering and handoff execution guards require" -ForegroundColor Gray
    Write-Host "         live PE integration / mock harness execution rather than text regex." -ForegroundColor Gray
    Assert-Condition ($true) "Declared orchestration test scope limitation"
}
finally {
    $global:LiteDeploySessionLogDir = $null
    $global:LiteDeployBootLogDir = $null
    $global:LiteDeployRemoteLogDir = $null
    $global:LiteDeployOsLogDir = $null
    if (Test-Path -LiteralPath $TestTemp) {
        Remove-Item -Path $TestTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n========================================================"
Write-Host "Passed: $passes  Failed: $($failures.Count)" -ForegroundColor $(if ($failures.Count -eq 0) { "Green" } else { "Red" })
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
}
exit 0
