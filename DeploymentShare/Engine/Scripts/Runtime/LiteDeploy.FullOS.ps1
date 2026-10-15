<#
.SYNOPSIS
    LiteDeploy FullOS Engine — First-boot and reboot resume orchestrator (architecture v2).

.DESCRIPTION
    Dedicated FullOS execution engine. First launch is HKLM\...\Run\LiteDeployFullOS at
    interactive logon (Audit Admin or Domain Join AutoLogon). That Run value is staged in
    unattend specialize (Image) when the workflow has actions — not via auditUser.
    FullOS may re-arm the same Run key for mid-deploy reboot survival. Stock Setup\CmdLine
    (sysprep) is left alone; FullOS kills the sysprep.exe process. Only a LiteDeploy-owned
    Setup CmdLine (legacy) is cleared to stop reboot loops.

    Responsibilities:
      1. Loads FullOS dependencies (Logs, State, Hardware, Packages, HostShell).
      2. Loads and updates DeploymentState.json (increments resume count, sets Phase 5).
      3. Unseals WinPECT secrets in-memory (interactive admin context).
      4. Reconnects the DeploymentShare persistently as Z: with in-memory PSCredential.
      5. Configures remote log mirroring back to the deployment share under the deployment UID.
      6. Re-arms HKLM Run for reboot survival; kills sysprep.exe; clears Run on finish.
      7. Starts Interactive Probe in a second independent PowerShell window.
      8. Orchestrates package installations (LiteDeploy.Packages.ps1).

.PARAMETER LocalRootName
    Name of the staged deployment root on the OS volume (default: '~LiteDeploy').

.PARAMETER OsDriveLetter
    System drive letter (default: $env:SystemDrive).

.PARAMETER StatePath
    Optional explicit path to DeploymentState.json.

.PARAMETER Metadata
    Returns standardized component metadata.

.NOTES
    LiteDeploy Core Component Standard v2.0
    PowerShell Version: 5.1+
    Strict Mode: Version 2.0
#>

[CmdletBinding()]
param(
    [string]$LocalRootName = '~LiteDeploy',

    [string]$OsDriveLetter = $env:SystemDrive,

    [string]$StatePath = '',

    [switch]$ResumeFullOS,

    [switch]$ForceDirect,

    [switch]$Metadata
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ==============================================================================
# 1. COMPONENT METADATA
# ==============================================================================

function Get-LiteDeployComponentMetadata {
    return [PSCustomObject]@{
        ComponentId          = "FullOS"
        Name                 = "LiteDeploy FullOS Engine"
        Version              = "2.2.0"
        Category             = "Runtime"
        TargetEnvironment    = "FullOS"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("Environment", "Logs", "State", "Hardware", "Packages")
        Description          = "Interactive FullOS orchestrator (HKLM Run at logon; specialize-staged): WinPECT unseal, Z: reconnect, log mirror, Interactive Probe, package install."
    }
}

if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

# Load Environment if not already present
if (-not (Get-Command Get-LiteDeployRuntimePaths -ErrorAction SilentlyContinue)) {
    $environmentScript = Join-Path $PSScriptRoot 'LiteDeploy.Environment.ps1'
    if (Test-Path -LiteralPath $environmentScript -PathType Leaf) {
        . $environmentScript
    }
}

# ==============================================================================
# 2. COMPONENT LOADER
# ==============================================================================

function Import-LiteDeployFullOSComponent {
    <#
    .SYNOPSIS
        Dot-sources one Runtime component from the active Runtime root (or $PSScriptRoot).
        Exports declared functions into Global scope so callers retain them regardless
        of scope depth.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$RuntimeRoot = $PSScriptRoot
    )
    if ($Name -eq 'Environment' -or $Name -eq 'BootConfig' -or $Name -eq 'Engine' -or $Name -eq 'FullOS') { return }
    $relative = $null
    if ($global:LiteDeployPathSettings -and $global:LiteDeployPathSettings.ProductionFiles.Contains($Name)) {
        $relative = [string]$global:LiteDeployPathSettings.ProductionFiles[$Name]
    }
    else {
        $relative = "LiteDeploy.$Name.ps1"
    }
    $path = Join-Path $RuntimeRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required FullOS component missing: $Name ($path)"
    }
    $funcsBefore = @(Get-ChildItem function:)
    . $path
    $funcsAfter = @(Get-ChildItem function:)
    $newFuncs = $funcsAfter | Where-Object { $name = $_.Name; -not ($funcsBefore | Where-Object { $_.Name -eq $name }) }
    foreach ($fn in $newFuncs) {
        Set-Item -Path ('Function:Global:' + $fn.Name) -Value $fn.ScriptBlock -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# 3. LEGACY CLEANUP + INTERACTIVE PROBE
# ==============================================================================

function Clear-LiteDeployFullOSLegacyScheduledTasks {
    <#
    .SYNOPSIS
        Removes obsolete LiteDeploy FullOS scheduled tasks from older builds (HKLM Run is resume now).
    #>
    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($taskName in @('LiteDeploy_SystemEngine', 'LiteDeploy_ResumeEngine', 'LiteDeploy_InteractiveProbe')) {
        try {
            $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($null -ne $existing) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
                $removed.Add($taskName)
            }
        }
        catch {}
    }
    return [pscustomobject]@{
        Success = $true
        Removed = @($removed.ToArray())
        Count   = $removed.Count
    }
}

function Test-LiteDeployFullOSInteractiveProbeRunning {
    <#
    .SYNOPSIS
        True when the Interactive Probe named mutex already exists (probe window alive).
    #>
    try {
        $mutex = [System.Threading.Mutex]::OpenExisting('Global\LiteDeploy_InteractiveProbe_Mutex')
        $mutex.Dispose()
        return $true
    }
    catch [System.Threading.WaitHandleCannotBeOpenedException] {
        return $false
    }
    catch {
        return $false
    }
}

function Start-LiteDeployFullOSInteractiveProbe {
    <#
    .SYNOPSIS
        Starts FullOS Interactive Probe in a second independent PowerShell window.
    .NOTES
        Does not use scheduled tasks. Skips Start-Process when a probe is already running
        (avoids a flash of a second window if FullOS is entered twice in one session).
    #>
    param(
        [string]$LocalRootName = '~LiteDeploy',
        [string]$OsDriveLetter = $env:SystemDrive,
        [string]$ProbeScriptPath = '',
        [string]$RuntimeRoot = ''
    )

    $drive = ($OsDriveLetter -replace '[\\/]+$', '').Trim()
    if ([string]::IsNullOrWhiteSpace($drive)) { $drive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' } }
    if ($drive.Length -eq 1) { $drive += ':' }
    $localRoot = Join-Path "$drive\" $LocalRootName

    if ([string]::IsNullOrWhiteSpace($ProbeScriptPath)) {
        if (-not [string]::IsNullOrWhiteSpace($RuntimeRoot)) {
            $ProbeScriptPath = Join-Path $RuntimeRoot 'LiteDeploy.FullOS.InteractiveProbe.ps1'
        }
        else {
            $ProbeScriptPath = Join-Path $localRoot 'Engine\Scripts\Runtime\LiteDeploy.FullOS.InteractiveProbe.ps1'
        }
    }
    if (-not (Test-Path -LiteralPath $ProbeScriptPath -PathType Leaf)) {
        throw "Interactive probe script missing: $ProbeScriptPath"
    }

    if (Test-LiteDeployFullOSInteractiveProbeRunning) {
        return [pscustomobject]@{
            Success     = $true
            Skipped     = $true
            Mode        = 'AlreadyRunning'
            ProbeScript = $ProbeScriptPath
            Message     = 'Interactive probe already running; skipped second Start-Process.'
            Temporary   = $true
        }
    }

    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argument = '-NoExit -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Normal -File "{0}"' -f $ProbeScriptPath
    $proc = Start-Process -FilePath $powerShell -ArgumentList $argument -WorkingDirectory (Split-Path -Parent $ProbeScriptPath) -PassThru -ErrorAction Stop

    return [pscustomobject]@{
        Success     = $true
        Skipped     = $false
        Mode        = 'IndependentWindow'
        ProcessId   = $proc.Id
        ProbeScript = $ProbeScriptPath
        Temporary   = $true
    }
}

function Stop-LiteDeployAuditModeSysprep {
    <#
    .SYNOPSIS
        Terminates Audit Mode System Preparation Tool UI (sysprep.exe) across all sessions.
    #>
    [CmdletBinding()]
    param()

    $killed = 0
    foreach ($proc in @(Get-Process -Name 'sysprep' -ErrorAction SilentlyContinue)) {
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            $killed++
        }
        catch {
            try {
                & taskkill.exe /F /PID $proc.Id /T 2>$null
                $killed++
            }
            catch {}
        }
    }

    try {
        $null = & taskkill.exe /F /IM sysprep.exe /T 2>$null
    }
    catch {}

    return $killed
}

# ==============================================================================
# 3b. REBOOT SURVIVAL — HKLM Run (interactive logon), NOT Setup CmdLine
# ==============================================================================
# Setup\CmdLine + SetupType=2 causes Windows Setup-continue reboot loops when
# re-armed across failures. Use HKLM\...\Run so FullOS starts as the Autologon
# Administrator on each interactive logon instead.

function Get-LiteDeployFullOSRunCommand {
    <#
    .SYNOPSIS
        Builds the HKLM Run command that launches FullOS at interactive logon.
    #>
    param(
        [string]$LocalRootName = '~LiteDeploy',
        [string]$OsDriveLetter = $env:SystemDrive
    )

    $drive = ($OsDriveLetter -replace '[\\/]+$', '').Trim()
    if ([string]::IsNullOrWhiteSpace($drive)) { $drive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' } }
    if ($drive.Length -eq 1) { $drive += ':' }
    $fullOsPath = Join-Path "$drive\" ($LocalRootName.TrimStart('\') + '\Engine\Scripts\Runtime\LiteDeploy.FullOS.ps1')
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return ('"{0}" -NoProfile -STA -ExecutionPolicy Bypass -File "{1}" -LocalRootName "{2}" -OsDriveLetter "{3}"' -f `
            $powerShell, $fullOsPath, $LocalRootName, $drive)
}

function Set-LiteDeployFullOSRunKey {
    <#
    .SYNOPSIS
        Arms HKLM Run so FullOS relaunches at Administrator Autologon after reboot.
    #>
    param(
        [string]$LocalRootName = '~LiteDeploy',
        [string]$OsDriveLetter = $env:SystemDrive,
        [string]$ValueName = 'LiteDeployFullOS',
        [string]$RunKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )

    $cmd = Get-LiteDeployFullOSRunCommand -LocalRootName $LocalRootName -OsDriveLetter $OsDriveLetter
    if (-not (Test-Path -LiteralPath $RunKey)) {
        $null = New-Item -Path $RunKey -Force -ErrorAction Stop
    }
    Set-ItemProperty -LiteralPath $RunKey -Name $ValueName -Value $cmd -Type String -Force -ErrorAction Stop

    return [pscustomobject]@{
        Success      = $true
        RunKey       = $RunKey
        ValueName    = $ValueName
        Command      = $cmd
        LocalRootName = $LocalRootName
        OsDriveLetter = $OsDriveLetter
    }
}

function Restore-LiteDeployFullOSUacBypass {
    <#
    .SYNOPSIS
        Restores EnableLUA=1 when Domain Join specialize marked UacBypassed (temporary UAC off for FullOS).
    .NOTES
        A reboot after restore is required for UAC to apply again. Safe no-op when marker is absent.
    #>
    $markerKey = 'HKLM:\SOFTWARE\LiteDeploy\FullOS'
    $policyKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $restored = $false
    $markerCleared = $false

    try {
        $marker = $null
        if (Test-Path -LiteralPath $markerKey) {
            $marker = Get-ItemProperty -LiteralPath $markerKey -Name 'UacBypassed' -ErrorAction SilentlyContinue
        }
        if ($marker -and [int]$marker.UacBypassed -eq 1) {
            if (-not (Test-Path -LiteralPath $policyKey)) {
                $null = New-Item -Path $policyKey -Force -ErrorAction Stop
            }
            Set-ItemProperty -LiteralPath $policyKey -Name 'EnableLUA' -Value 1 -Type DWord -Force -ErrorAction Stop
            $restored = $true
            Remove-ItemProperty -LiteralPath $markerKey -Name 'UacBypassed' -Force -ErrorAction SilentlyContinue
            $markerCleared = $true
        }
    }
    catch {
        return [pscustomobject]@{
            Success        = $false
            Restored       = $restored
            MarkerCleared  = $markerCleared
            Message        = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        Success       = $true
        Restored      = $restored
        MarkerCleared = $markerCleared
        Message       = $(if ($restored) { 'EnableLUA restored to 1 (reboot required for UAC).' } else { 'No UacBypassed marker; nothing to restore.' })
    }
}

function Clear-LiteDeployFullOSRunKey {
    <#
    .SYNOPSIS
        Removes the HKLM Run value so FullOS stops auto-launching at logon.
        Also restores temporary Domain Join UAC bypass (EnableLUA) when marked.
    #>
    param(
        [string]$ValueName = 'LiteDeployFullOS',
        [string]$RunKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )

    $uac = Restore-LiteDeployFullOSUacBypass

    if (-not (Test-Path -LiteralPath $RunKey)) {
        return [pscustomobject]@{ Success = $true; Cleared = $false; Message = 'Run key not present.'; UacRestore = $uac }
    }
    $existing = Get-ItemProperty -LiteralPath $RunKey -Name $ValueName -ErrorAction SilentlyContinue
    if ($null -eq $existing -or -not ($existing.PSObject.Properties.Name -contains $ValueName)) {
        return [pscustomobject]@{ Success = $true; Cleared = $false; Message = 'Run value not present.'; UacRestore = $uac }
    }
    Remove-ItemProperty -LiteralPath $RunKey -Name $ValueName -Force -ErrorAction Stop
    return [pscustomobject]@{ Success = $true; Cleared = $true; ValueName = $ValueName; RunKey = $RunKey; UacRestore = $uac }
}

function Test-LiteDeployOwnedSetupCmdLine {
    <#
    .SYNOPSIS
        True when Setup\CmdLine points at LiteDeploy FullOS (legacy hijack), not stock sysprep.
    #>
    param([string]$RegistryRoot = 'HKLM:\SYSTEM\Setup')

    if (-not (Test-Path -LiteralPath $RegistryRoot)) { return $false }
    try {
        $cmd = [string](Get-ItemProperty -LiteralPath $RegistryRoot -Name 'CmdLine' -ErrorAction Stop).CmdLine
    }
    catch {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }
    # Stock Audit continue is typically sysprep.exe — leave that alone.
    if ($cmd -match '(?i)sysprep(\.exe)?') { return $false }
    return ($cmd -match '(?i)LiteDeploy\.FullOS\.ps1|~LiteDeploy')
}

function Clear-LiteDeployFullOSSetupCmdLine {
    <#
    .SYNOPSIS
        Clears Setup continue only when CmdLine was hijacked to LiteDeploy FullOS.
        Leaves stock sysprep Setup\CmdLine intact; FullOS kills sysprep.exe instead.
    #>
    param(
        [string]$RegistryRoot = 'HKLM:\SYSTEM\Setup',
        [switch]$Force
    )

    if (-not (Test-Path -LiteralPath $RegistryRoot)) {
        return [pscustomobject]@{ Success = $true; Cleared = $false; Message = 'Setup key not present.' }
    }

    $owned = Test-LiteDeployOwnedSetupCmdLine -RegistryRoot $RegistryRoot
    if (-not $Force -and -not $owned) {
        return [pscustomobject]@{
            Success      = $true
            Cleared      = $false
            RegistryRoot = $RegistryRoot
            Message      = 'Setup CmdLine left unchanged (stock sysprep or empty).'
        }
    }

    Set-ItemProperty -LiteralPath $RegistryRoot -Name 'SetupType' -Value 0 -Type DWord -Force -ErrorAction Stop
    try {
        Set-ItemProperty -LiteralPath $RegistryRoot -Name 'CmdLine' -Value '' -Type String -Force -ErrorAction Stop
    }
    catch {
        Remove-ItemProperty -LiteralPath $RegistryRoot -Name 'CmdLine' -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        Success      = $true
        Cleared      = $true
        RegistryRoot = $RegistryRoot
        SetupType    = 0
        Message      = 'Cleared LiteDeploy-owned Setup CmdLine.'
    }
}

# Legacy aliases kept so older call sites / docs referring to "SetupCmdLine arm" still resolve to Run.
function Set-LiteDeployFullOSSetupCmdLine {
    param(
        [string]$LocalRootName = '~LiteDeploy',
        [string]$OsDriveLetter = $env:SystemDrive,
        [string]$FullOSPath = '',
        [string]$RegistryRoot = 'HKLM:\SYSTEM\Setup'
    )
    # Do not arm Setup continue — that caused reboot loops. Arm HKLM Run; only clear LiteDeploy hijacks.
    $null = Clear-LiteDeployFullOSSetupCmdLine -RegistryRoot $RegistryRoot
    return Set-LiteDeployFullOSRunKey -LocalRootName $LocalRootName -OsDriveLetter $OsDriveLetter
}

# ==============================================================================
# 4. SHARE CONNECTION HELPER
# ==============================================================================

function Get-LiteDeployFullOSSecret {
    <#
    .SYNOPSIS
        Retrieves a secret in memory: tries WinPECT CredentialTransfer.bin in-memory decryption first,
        then falls back to CLIXML if present. Never writes plaintext or DPAPI to disk.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][string]$SecretId
    )

    $packagePath = Join-Path $LocalRoot 'Content\Credentials\CredentialTransfer.bin'
    if (Test-Path -LiteralPath $packagePath -PathType Leaf) {
        $winpectEngine = Join-Path $LocalRoot 'Engine\Tools\WinPECT\WinPECredentialTransfer.ps1'
        if (-not (Test-Path -LiteralPath $winpectEngine -PathType Leaf)) {
            $winpectEngine = Join-Path $LocalRoot 'Tools\WinPECT\WinPECredentialTransfer.ps1'
        }
        if (Test-Path -LiteralPath $winpectEngine -PathType Leaf) {
            if (-not (Get-Command Read-WPCTCredentialTransfer -ErrorAction SilentlyContinue)) {
                . $winpectEngine
            }
            if (Get-Command Read-WPCTCredentialTransfer -ErrorAction SilentlyContinue) {
                $subKeys = @('LiteDeploy\CredentialTransfer', 'WinPECredentialTransfer\Bootstrap')
                $lastReadError = $null
                foreach ($subKey in $subKeys) {
                    try {
                        $read = Read-WPCTCredentialTransfer `
                            -SecretFilePath $packagePath `
                            -RegistrySubKey $subKey `
                            -ErrorAction Stop
                        if ($read -and $read.Success -and $read.Payload) {
                            $found = @($read.Payload.Secrets) | Where-Object { $_.Id -eq $SecretId }
                            if ($found) {
                                $user = [string]$found.Username
                                $sec = ConvertTo-SecureString ([string]$found.Password) -AsPlainText -Force
                                return [pscustomobject]@{
                                    Success    = $true
                                    Id         = $SecretId
                                    UserName   = $user
                                    Credential = (New-Object System.Management.Automation.PSCredential($user, $sec))
                                    Source     = 'WinPECT.InMemory'
                                }
                            }
                        }
                    }
                    catch {
                        $lastReadError = $_.Exception.Message
                    }
                }
            }
        }
    }

    # Fallback to CLIXML if present
    $clixmlPath = Join-Path $LocalRoot ("Content\Credentials\{0}.xml" -f $SecretId)
    if (Test-Path -LiteralPath $clixmlPath -PathType Leaf) {
        try {
            $credObj = Import-Clixml -LiteralPath $clixmlPath -ErrorAction Stop
            if ($credObj -is [System.Management.Automation.PSCredential]) {
                return [pscustomobject]@{
                    Success    = $true
                    Id         = $SecretId
                    UserName   = $credObj.UserName
                    Credential = $credObj
                    Source     = 'CLIXML'
                }
            }
        }
        catch {}
    }

    $detailMsg = if ($lastReadError) { " (WinPECT error: $lastReadError)" } else { '' }
    return [pscustomobject]@{
        Success = $false
        Id      = $SecretId
        Message = "Secret '$SecretId' not found in WinPECT package or CLIXML$detailMsg."
    }
}

function Connect-LiteDeployFullOSDeploymentShare {
    <#
    .SYNOPSIS
        Maps the DeploymentShare to Z: in the current user session using native PowerShell
        cmdlets and in-memory PSCredential (never exposing credentials to net.exe or process args).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][string]$NetworkPath,
        [string]$DriveLetter = 'Z:',
        [string]$CredentialId = 'DeploymentShare'
    )

    $cleanDrive = $DriveLetter.TrimEnd('\').TrimEnd(':') + ':'
    $driveName = $cleanDrive.TrimEnd(':')
    if ([string]::IsNullOrWhiteSpace($NetworkPath) -or $NetworkPath -notmatch '^\\\\') {
        throw "NetworkPath must be a UNC path (got '$NetworkPath')."
    }

    $secretResult = Get-LiteDeployFullOSSecret -LocalRoot $LocalRoot -SecretId $CredentialId
    if (-not $secretResult.Success) {
        throw "Cannot connect DeploymentShare: $($secretResult.Message)"
    }

    $credential = $secretResult.Credential
    $userName = $secretResult.UserName

    try {
        # Ensure EnableLinkedConnections so Explorer and elevated admin share drive Z:
        try {
            $policiesKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
            if (Test-Path -LiteralPath $policiesKey) {
                Set-ItemProperty -Path $policiesKey -Name 'EnableLinkedConnections' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            }
        }
        catch {}

        # Clean up any existing mapping on the drive letter
        if (Get-Command Remove-SmbMapping -ErrorAction SilentlyContinue) {
            try { Remove-SmbMapping -LocalPath $cleanDrive -Force -UpdateProfile -ErrorAction SilentlyContinue } catch {}
        }
        if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
            try { Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue } catch {}
        }

        $mapped = $false
        $lastError = ''

        # 1) Method A: Native New-SmbMapping with in-memory PSCredential
        if (Get-Command New-SmbMapping -ErrorAction SilentlyContinue) {
            try {
                $null = New-SmbMapping `
                    -LocalPath $cleanDrive `
                    -RemotePath $NetworkPath `
                    -Credential $credential `
                    -Persistent $true `
                    -ErrorAction Stop
                if (Test-Path -LiteralPath "$cleanDrive\" -PathType Container) {
                    $mapped = $true
                }
                else {
                    # Partial map (common under SYSTEM) — remove before New-PSDrive or "resource type" errors.
                    try { Remove-SmbMapping -LocalPath $cleanDrive -Force -UpdateProfile -ErrorAction SilentlyContinue } catch {}
                    $lastError = 'New-SmbMapping created mapping but path is not accessible.'
                }
            }
            catch {
                $lastError = "New-SmbMapping exception: $_"
                try { Remove-SmbMapping -LocalPath $cleanDrive -Force -UpdateProfile -ErrorAction SilentlyContinue } catch {}
            }
        }

        # 2) Method B: Native New-PSDrive with -Persist and in-memory PSCredential
        if (-not $mapped) {
            try {
                if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
                    try { Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue } catch {}
                }
                $null = New-PSDrive `
                    -Name $driveName `
                    -PSProvider FileSystem `
                    -Root $NetworkPath `
                    -Credential $credential `
                    -Persist `
                    -Scope Global `
                    -ErrorAction Stop
                if (Test-Path -LiteralPath "$cleanDrive\" -PathType Container) {
                    $mapped = $true
                }
            }
            catch {
                $lastError = "New-PSDrive exception: $_"
            }
        }

        if (-not (Test-Path -LiteralPath "$cleanDrive\" -PathType Container)) {
            throw "Mapped $cleanDrive but path is not accessible. Last error: $lastError"
        }

        return [pscustomobject]@{
            Success      = $true
            DriveLetter  = $cleanDrive
            NetworkPath  = $NetworkPath
            CredentialId = $CredentialId
            UserName     = $userName
            Source       = $secretResult.Source
        }
    }
    finally {
        $credential = $null
        $secretResult = $null
    }
}

# ==============================================================================
# 5. STATE CONTEXT HELPER
# ==============================================================================

function Get-LiteDeployFullOSContextFromState {
    <#
    .SYNOPSIS
        Builds FullOS resume inputs from DeploymentState.json (source of truth after WinPE).
    #>
    param(
        [Parameter(Mandatory = $true)][psobject]$DeploymentState,
        [string]$DefaultLocalRootName = '~LiteDeploy',
        [string]$DefaultDriveLetter = 'Z:',
        [string]$DefaultCredentialId = 'DeploymentShare'
    )

    $boot = Get-LiteDeployStateProperty -InputObject $DeploymentState -Name 'BootObject' -Default $null
    $execution = Get-LiteDeployStateProperty -InputObject $DeploymentState -Name 'Execution' -Default $null
    $logLocations = Get-LiteDeployStateProperty -InputObject $DeploymentState -Name 'LogLocations' -Default $null
    $share = Get-LiteDeployStateProperty -InputObject $execution -Name 'FullOSShare' -Default $null
    $credHandoff = Get-LiteDeployStateProperty -InputObject $execution -Name 'CredentialHandoff' -Default $null
    $payload = Get-LiteDeployStateProperty -InputObject $execution -Name 'FullOSPayload' -Default $null

    $offlineRoot = [string](Get-LiteDeployStateProperty -InputObject $logLocations -Name 'OfflineOsRoot' -Default '')
    $localRootName = $DefaultLocalRootName
    if (-not [string]::IsNullOrWhiteSpace($offlineRoot)) {
        $leaf = Split-Path -Leaf $offlineRoot.TrimEnd('\')
        if (-not [string]::IsNullOrWhiteSpace($leaf)) { $localRootName = $leaf }
    }
    elseif ($boot) {
        $fromBoot = [string](Get-LiteDeployStateProperty -InputObject $boot -Name 'LocalRootName' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($fromBoot)) { $localRootName = $fromBoot }
    }

    $deploymentType = [string](Get-LiteDeployStateProperty -InputObject $share -Name 'DeploymentType' -Default '')
    if ([string]::IsNullOrWhiteSpace($deploymentType)) {
        $deploymentType = [string](Get-LiteDeployStateProperty -InputObject $boot -Name 'DeploymentType' -Default 'Media')
    }

    $networkPath = [string](Get-LiteDeployStateProperty -InputObject $share -Name 'NetworkPath' -Default '')
    if ([string]::IsNullOrWhiteSpace($networkPath)) {
        $networkPath = [string](Get-LiteDeployStateProperty -InputObject $boot -Name 'NetworkPath' -Default '')
    }

    if ($deploymentType -ne 'Network' -and -not [string]::IsNullOrWhiteSpace($networkPath)) {
        $deploymentType = 'Network'
    }

    $shareDrive = [string](Get-LiteDeployStateProperty -InputObject $share -Name 'DriveLetter' -Default $DefaultDriveLetter)
    if ([string]::IsNullOrWhiteSpace($shareDrive)) { $shareDrive = $DefaultDriveLetter }

    $credentialId = [string](Get-LiteDeployStateProperty -InputObject $share -Name 'CredentialId' -Default $DefaultCredentialId)
    if ([string]::IsNullOrWhiteSpace($credentialId)) { $credentialId = $DefaultCredentialId }

    $remoteLogDir = [string](Get-LiteDeployStateProperty -InputObject $execution -Name 'RemoteLogDir' -Default '')
    if ([string]::IsNullOrWhiteSpace($remoteLogDir)) {
        $remoteLogDir = [string](Get-LiteDeployStateProperty -InputObject $logLocations -Name 'RemoteLogDir' -Default '')
    }

    $uid = [string](Get-LiteDeployStateProperty -InputObject $DeploymentState -Name 'DeploymentUid' -Default '')
    $credStaged = [bool](Get-LiteDeployStateProperty -InputObject $credHandoff -Name 'Staged' -Default $false)
    $secretIds = @(Get-LiteDeployStateProperty -InputObject $credHandoff -Name 'SecretIds' -Default @())
    $reconnect = $true
    if ($null -ne $share -and $share.PSObject.Properties['ReconnectOnBoot']) {
        $reconnect = [bool]$share.ReconnectOnBoot
    }
    else {
        $reconnect = ($deploymentType -eq 'Network')
    }

    return [pscustomobject]@{
        DeploymentUid     = $uid
        Status            = [string](Get-LiteDeployStateProperty -InputObject $DeploymentState -Name 'Status' -Default '')
        CurrentStep       = [string](Get-LiteDeployStateProperty -InputObject $execution -Name 'CurrentStep' -Default '')
        DeploymentType    = $deploymentType
        NetworkPath       = $networkPath
        ShareDriveLetter  = $shareDrive
        CredentialId      = $credentialId
        ReconnectOnBoot   = $reconnect
        LocalRootName     = $localRootName
        OfflineOsRoot     = $offlineRoot
        RemoteLogDir      = $remoteLogDir
        CredentialStaged  = $credStaged
        SecretIds         = @($secretIds)
        CredentialHandoff = $credHandoff
        FullOSPayload     = $payload
        FullOSShare       = $share
        BootObject        = $boot
        Workflow          = (Get-LiteDeployStateProperty -InputObject $DeploymentState -Name 'Workflow' -Default $null)
        OSInstall         = (Get-LiteDeployStateProperty -InputObject $DeploymentState -Name 'OSInstall' -Default $null)
        Disk              = (Get-LiteDeployStateProperty -InputObject $DeploymentState -Name 'Disk' -Default $null)
    }
}

# ==============================================================================
# 6. FULLOS RESUME ORCHESTRATOR
# ==============================================================================

function Start-LiteDeployFullOSResume {
    <#
    .SYNOPSIS
        FullOS Engine pipeline driven by DeploymentState.json.
    #>
    param(
        [string]$LocalRootName = '~LiteDeploy',
        [string]$OsDriveLetter = $env:SystemDrive,
        [string]$StatePath = '',
        [string]$RuntimeRoot = $PSScriptRoot,
        [switch]$ForceDirect
    )

    $drive = ($OsDriveLetter -replace '[\\/]+$', '').Trim()
    if ($drive.Length -eq 1) { $drive += ':' }
    $localRoot = Join-Path "$drive\" $LocalRootName
    $null = New-Item -Path (Join-Path $localRoot 'WorkLogs') -ItemType Directory -Force -ErrorAction SilentlyContinue

    foreach ($name in @('Logs', 'State', 'Hardware', 'Packages', 'HostShell')) {
        Import-LiteDeployFullOSComponent -Name $name -RuntimeRoot $RuntimeRoot
    }

    if ([string]::IsNullOrWhiteSpace($StatePath)) {
        $StatePath = Join-Path $localRoot 'DeploymentState.json'
    }

    function Write-FullOSLog([string]$Message, [string]$Level = 'INFO') {
        if (Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue) {
            Write-LiteDeployLog -Message $Message -Level $Level -Component 'Engine.FullOS'
        }
        else {
            Write-Host ('[{0}] [{1}] {2}' -f (Get-Date -Format 'o'), $Level, $Message)
        }
    }

    Write-FullOSLog "FullOS resume starting. StatePath=$StatePath RuntimeRoot=$RuntimeRoot"

    # Leave stock Setup\CmdLine (sysprep) alone. Only clear a legacy LiteDeploy FullOS hijack.
    try {
        $clearedSetup = Clear-LiteDeployFullOSSetupCmdLine
        Write-FullOSLog ("Setup CmdLine check: {0}" -f $(if ($clearedSetup.Message) { $clearedSetup.Message } else { "Cleared=$($clearedSetup.Cleared)" })) -Level 'INFO'
    }
    catch {
        Write-FullOSLog "Setup CmdLine check failed: $_" -Level 'WARNING'
    }

    # Kill Audit Mode sysprep GUI so FullOS/probe own the desktop (do not rewrite Setup registry)
    $killedSysprep = Stop-LiteDeployAuditModeSysprep
    Write-FullOSLog ("Sysprep process kill sweep: {0} instance(s)." -f $killedSysprep) -Level 'INFO'

    # Remove obsolete LiteDeploy scheduled tasks from older builds (resume is HKLM Run only)
    try {
        $legacyTasks = Clear-LiteDeployFullOSLegacyScheduledTasks
        if ($legacyTasks.Count -gt 0) {
            Write-FullOSLog ("Removed legacy scheduled task(s): {0}" -f ($legacyTasks.Removed -join ', ')) -Level 'INFO'
        }
    }
    catch {
        Write-FullOSLog "Legacy scheduled-task cleanup failed: $_" -Level 'WARNING'
    }

    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $isSystem = $currentIdentity.IsSystem -or ($currentIdentity.User.Value -eq 'S-1-5-18')

    # Arm HKLM Run for interactive Administrator Autologon after reboots
    $runKey = $null
    try {
        $runKey = Set-LiteDeployFullOSRunKey -LocalRootName $LocalRootName -OsDriveLetter $drive
        Write-FullOSLog ("HKLM Run armed ({0}): {1}" -f $runKey.ValueName, $runKey.Command) -Level 'SUCCESS'
    }
    catch {
        Write-FullOSLog "Failed to arm HKLM Run resume key: $_" -Level 'WARNING'
    }

    if ($isSystem) {
        # Legacy LiteDeploy Setup CmdLine entry as SYSTEM — defer to Administrator via Run.
        Write-FullOSLog 'Invoked as NT AUTHORITY\SYSTEM. HKLM Run armed; exiting so Administrator Autologon owns FullOS. Stock sysprep Setup left intact.' -Level 'NOTICE'
        return [pscustomobject]@{
            Success   = $true
            Deferred  = $true
            Identity  = 'SYSTEM'
            RunKey    = $runKey
            Message   = 'FullOS deferred to HKLM Run at Administrator logon; Setup sysprep CmdLine preserved.'
        }
    }

    Write-FullOSLog "Executing FullOS engine in interactive user session ($($currentIdentity.Name))." -Level 'SUCCESS'

    # 1) Load state first — everything else is derived from it.
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        throw "DeploymentState.json not found at '$StatePath'. FullOS cannot resume without WinPE handoff state."
    }

    $deployment = Read-LiteDeployStateFile -Path $StatePath
    if ($null -eq $deployment) {
        throw "DeploymentState.json at '$StatePath' is empty or unreadable."
    }

    $ctx = Get-LiteDeployFullOSContextFromState -DeploymentState $deployment -DefaultLocalRootName $LocalRootName
    if (-not [string]::IsNullOrWhiteSpace($ctx.LocalRootName) -and $ctx.LocalRootName -ne $LocalRootName) {
        $LocalRootName = $ctx.LocalRootName
        $localRoot = Join-Path "$drive\" $LocalRootName
        Write-FullOSLog "LocalRootName from state OfflineOsRoot: $LocalRootName"
    }

    $previousStatus = [string]$ctx.Status
    $resumeCount = 0
    $execution = Get-LiteDeployStateProperty -InputObject $deployment -Name 'Execution' -Default $null
    [void][int]::TryParse([string](Get-LiteDeployStateProperty -InputObject $execution -Name 'ResumeCount' -Default 0), [ref]$resumeCount)
    $resumeCount++

    $deployment | Add-Member -NotePropertyName Status -NotePropertyValue 'FullOS' -Force
    $deployment | Add-Member -NotePropertyName CurrentPhase -NotePropertyValue 5 -Force
    $deployment | Add-Member -NotePropertyName EndTime -NotePropertyValue $null -Force
    if ($execution) {
        $execution | Add-Member -NotePropertyName ResumeCount -NotePropertyValue $resumeCount -Force
        $execution | Add-Member -NotePropertyName LastResumedTime -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        $execution | Add-Member -NotePropertyName ResumedFromStatus -NotePropertyValue $previousStatus -Force
        $execution | Add-Member -NotePropertyName CurrentStep -NotePropertyValue 'FullOSResumed' -Force
    }
    $global:LiteDeployDeployment = $deployment
    Save-LiteDeployDeploymentState -DeploymentState $deployment
    Write-FullOSLog ("State active UID={0} previousStatus={1} resume#{2} type={3}" -f `
            $ctx.DeploymentUid, $previousStatus, $resumeCount, $ctx.DeploymentType) -Level 'SUCCESS'

    # 2) WinPECT in-memory readiness (zero disk footprint)
    $credDir = Join-Path $localRoot 'Content\Credentials'
    $packagePath = Join-Path $credDir 'CredentialTransfer.bin'
    $hasWinpectPackage = (Test-Path -LiteralPath $packagePath -PathType Leaf)
    $clixml = @(Get-ChildItem -LiteralPath $credDir -Filter '*.xml' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    if ($hasWinpectPackage) {
        Write-FullOSLog "WinPECT package ready for in-memory decryption (zero disk footprint)." -Level 'SUCCESS'
    }
    elseif ($clixml.Count -gt 0) {
        Write-FullOSLog ("Credential files available: {0}" -f ($clixml -join ', ')) -Level 'INFO'
    }
    else {
        Write-FullOSLog 'No WinPECT package or credential files found; continuing with local resources.' -Level 'INFO'
    }

    # 3) Network (from state): reconnect share every boot, then mirror logs to state's UID folder.
    $shareMap = $null
    $runtimePaths = $null
    $remoteLogDir = $null
    $logsMirrored = $false
    $deploymentType = [string]$ctx.DeploymentType
    $networkPath = [string]$ctx.NetworkPath
    $shareDrive = [string]$ctx.ShareDriveLetter
    $credentialId = [string]$ctx.CredentialId

    if ($deploymentType -ne 'Network' -or -not $ctx.ReconnectOnBoot) {
        Write-FullOSLog ("DeploymentType={0} ReconnectOnBoot={1}; skipping DeploymentShare reconnect / share log mirror." -f $deploymentType, $ctx.ReconnectOnBoot) -Level 'INFO'
    }
    elseif ([string]::IsNullOrWhiteSpace($networkPath)) {
        Write-FullOSLog 'State NetworkPath is empty; cannot reconnect share or mirror logs.' -Level 'WARNING'
    }
    elseif (-not $hasWinpectPackage -and ($clixml -notcontains "$credentialId.xml")) {
        Write-FullOSLog ("Cannot reconnect {0}: missing WinPECT package or Content\Credentials\{1}.xml (state CredentialId)." -f $shareDrive, $credentialId) -Level 'WARNING'
    }
    else {
        Write-FullOSLog "Reconnecting DeploymentShare from state: $networkPath -> $shareDrive ..."
        try {
            $shareMap = Connect-LiteDeployFullOSDeploymentShare `
                -LocalRoot $localRoot `
                -NetworkPath $networkPath `
                -DriveLetter $shareDrive `
                -CredentialId $credentialId
            Write-FullOSLog ("DeploymentShare connected: {0} = {1} (user {2})" -f $shareMap.DriveLetter, $shareMap.NetworkPath, $shareMap.UserName) -Level 'SUCCESS'
            $global:LiteDeployShareDrive = $shareMap.DriveLetter
            $global:LiteDeployNetworkPath = $shareMap.NetworkPath
        }
        catch {
            Write-FullOSLog ("DeploymentShare connection FAILED: {0}" -f $_.Exception.Message) -Level 'ERROR'
            throw $_
        }

        $fullOsBoot = [pscustomobject]@{
            DeploymentType = 'Network'
            DriveLetter    = $shareMap.DriveLetter
            NetworkPath    = $shareMap.NetworkPath
            LocalRootName  = $LocalRootName
            ConfigPath     = (Join-Path $shareMap.DriveLetter 'Config\BootConfig.json')
            ConfigFound    = (Test-Path -LiteralPath (Join-Path $shareMap.DriveLetter 'Config\BootConfig.json') -PathType Leaf)
            ShareMounted   = $true
            AppName        = $(if ($ctx.BootObject) { Get-LiteDeployStateProperty -InputObject $ctx.BootObject -Name 'AppName' -Default 'LiteDeploy' } else { 'LiteDeploy' })
            Environment    = $(if ($ctx.BootObject) { Get-LiteDeployStateProperty -InputObject $ctx.BootObject -Name 'Environment' -Default '' } else { '' })
            Credential     = $null
        }
        $global:LiteDeployBootObject = $fullOsBoot
        if ($deployment.PSObject.Properties['BootObject']) {
            # Keep persisted BootObject fields; overlay live share mount (never store Credential).
            $deployment.BootObject | Add-Member -NotePropertyName DriveLetter -NotePropertyValue $shareMap.DriveLetter -Force
            $deployment.BootObject | Add-Member -NotePropertyName ShareMounted -NotePropertyValue $true -Force
            $deployment.BootObject | Add-Member -NotePropertyName NetworkPath -NotePropertyValue $shareMap.NetworkPath -Force
            $deployment.BootObject | Add-Member -NotePropertyName DeploymentType -NotePropertyValue 'Network' -Force
        }

        $runtimePaths = Get-LiteDeployRuntimePaths `
            -BootObject $fullOsBoot `
            -RequiredComponents @('Environment', 'BootConfig', 'Logs', 'State', 'Hardware', 'Packages', 'HostShell')
        $global:LiteDeployRuntimeRoot = $runtimePaths.RuntimeRoot
        Write-FullOSLog ("RuntimePaths ready. DeploymentRoot={0} RuntimeRoot={1} LocalLogs={2}" -f `
                $runtimePaths.DeploymentRoot, $runtimePaths.RuntimeRoot, $runtimePaths.LocalLogDirectory)

        # Remote log dir: prefer state UID under reconnected DeploymentLogRoot (drive-letter safe).
        if (-not [string]::IsNullOrWhiteSpace($ctx.DeploymentUid)) {
            $remoteLogDir = Join-Path $runtimePaths.DeploymentLogRoot $ctx.DeploymentUid
        }
        elseif (-not [string]::IsNullOrWhiteSpace($ctx.RemoteLogDir)) {
            $leaf = Split-Path -Leaf $ctx.RemoteLogDir.TrimEnd('\')
            $remoteLogDir = if ($leaf -and $leaf -ne 'Deployments') {
                Join-Path $runtimePaths.DeploymentLogRoot $leaf
            } else {
                $ctx.RemoteLogDir
            }
        }
        else {
            $remoteLogDir = $runtimePaths.DeploymentLogRoot
        }

        try {
            $null = New-Item -Path $remoteLogDir -ItemType Directory -Force -ErrorAction Stop
            $global:LiteDeployRemoteLogDir = $remoteLogDir
            if ($execution) {
                $execution | Add-Member -NotePropertyName RemoteLogDir -NotePropertyValue $remoteLogDir -Force
                $execution | Add-Member -NotePropertyName CurrentStep -NotePropertyValue 'FullOSShareConnected' -Force
            }
            $logLocations = Get-LiteDeployStateProperty -InputObject $deployment -Name 'LogLocations' -Default $null
            if ($logLocations) {
                $logLocations | Add-Member -NotePropertyName RemoteLogDir -NotePropertyValue $remoteLogDir -Force
                $logLocations | Add-Member -NotePropertyName RemoteExecutionLog -NotePropertyValue (Join-Path $remoteLogDir 'LiteDeploy.Execution.log') -Force
                $logLocations | Add-Member -NotePropertyName RemoteDeploymentState -NotePropertyValue (Join-Path $remoteLogDir 'DeploymentState.json') -Force
            }
            $global:LiteDeployDeployment = $deployment
            Save-LiteDeployDeploymentState -DeploymentState $deployment
            Sync-LiteDeployLogsToShare -RuntimePaths $runtimePaths -RemoteLogDir $remoteLogDir
            $logsMirrored = $true
            Write-FullOSLog "Share log mirror enabled from state: $($runtimePaths.LocalLogDirectory) -> $remoteLogDir" -Level 'SUCCESS'
        }
        catch {
            Write-FullOSLog "Share connected but log mirror failed: $_. Local logs remain at $($runtimePaths.LocalLogDirectory)." -Level 'WARNING'
            $global:LiteDeployRemoteLogDir = $null
        }
    }

    if (Get-Command Get-LiteDeployPackages -ErrorAction SilentlyContinue) {
        Write-FullOSLog 'Packages component loaded (orchestration pending; use state Workflow / future action list).'
    }

    # 4) Interactive probe in a second independent window
    $interactiveProbe = $null
    try {
        $interactiveProbe = Start-LiteDeployFullOSInteractiveProbe `
            -LocalRootName $LocalRootName `
            -OsDriveLetter $drive `
            -RuntimeRoot $RuntimeRoot
        if ($execution) {
            $execution | Add-Member -NotePropertyName FullOSInteractiveProbe -NotePropertyValue ([pscustomobject]@{
                    Mode              = $interactiveProbe.Mode
                    ProcessId         = $(if ($interactiveProbe.PSObject.Properties['ProcessId']) { $interactiveProbe.ProcessId } else { $null })
                    ProbeScript       = $interactiveProbe.ProbeScript
                    Skipped           = [bool]($interactiveProbe.PSObject.Properties['Skipped'] -and $interactiveProbe.Skipped)
                    Temporary         = $true
                    StartedTimeUtc    = [DateTime]::UtcNow.ToString('o')
                }) -Force
            $global:LiteDeployDeployment = $deployment
            Save-LiteDeployDeploymentState -DeploymentState $deployment
        }
        if ($interactiveProbe.PSObject.Properties['Skipped'] -and $interactiveProbe.Skipped) {
            Write-FullOSLog $interactiveProbe.Message -Level 'INFO'
        }
        else {
            Write-FullOSLog ("Interactive probe started in second window (PID {0}): {1}" -f $interactiveProbe.ProcessId, $interactiveProbe.ProbeScript) -Level 'SUCCESS'
        }
    }
    catch {
        Write-FullOSLog "Failed to start interactive probe window: $_" -Level 'WARNING'
    }

    if ($execution -and $runKey) {
        $execution | Add-Member -NotePropertyName FullOSRunKey -NotePropertyValue ([pscustomobject]@{
                ValueName         = $runKey.ValueName
                Command           = $runKey.Command
                RegisteredTimeUtc = [DateTime]::UtcNow.ToString('o')
            }) -Force
        $execution | Add-Member -NotePropertyName CurrentStep -NotePropertyValue 'FullOSRunKeyArmed' -Force
        $global:LiteDeployDeployment = $deployment
        Save-LiteDeployDeploymentState -DeploymentState $deployment
    }

    # Final sweep against Audit Mode sysprep GUI
    $null = Stop-LiteDeployAuditModeSysprep

    Write-FullOSLog 'FullOS resume complete (state-driven). HKLM Run remains armed for mid-deploy reboots; call Clear-LiteDeployFullOSRunKey on final success.' -Level 'SUCCESS'
    return [pscustomobject]@{
        Success          = $true
        Context          = $ctx
        LocalRoot        = $localRoot
        StatePath        = $StatePath
        CredentialFiles  = $clixml
        CredentialDir    = $credDir
        DeploymentType   = $deploymentType
        ShareMapped      = [bool]$shareMap
        ShareDrive       = $(if ($shareMap) { $shareMap.DriveLetter } else { $null })
        NetworkPath      = $networkPath
        RemoteLogDir     = $remoteLogDir
        LogsMirrored     = $logsMirrored
        RunKey           = $runKey
        InteractiveProbe = $interactiveProbe
        RuntimePaths     = $runtimePaths
        DeploymentUid    = $ctx.DeploymentUid
        ResumeCount      = $resumeCount
        WinpectReady     = $hasWinpectPackage
        DeploymentState  = $deployment
    }
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Start-LiteDeployFullOSResume -LocalRootName $LocalRootName -OsDriveLetter $OsDriveLetter -StatePath $StatePath -RuntimeRoot $PSScriptRoot -ForceDirect:$ForceDirect
    }
    finally {
        # Only strip a LiteDeploy-owned Setup CmdLine hijack — never wipe stock sysprep.
        try { $null = Clear-LiteDeployFullOSSetupCmdLine } catch {}
        # Keep sysprep GUI from reclaiming the desktop if it respawned during the run.
        try { $null = Stop-LiteDeployAuditModeSysprep } catch {}
    }
}
