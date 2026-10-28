<#
.SYNOPSIS
    Security and reliability hardening unit, contract, and adversarial test suite for LiteDeploy Core.

.DESCRIPTION
    Validates hardening controls across LD-01 through LD-15, P0-LD-01, and ADD-01 through ADD-05:
      - LD-01 / LD-14: Production Unattend credential/AutoLogon prohibition & preflight validator
      - LD-02: XML DOM / literal token handling, ComputerName & ComputerDescription validation, no cmd.exe srvcomment interpolation
      - LD-03 / P0-LD-01 / LD-13 / ADD-03 / ADD-04: FullOS fail-safe finalizer, WinPECT secret buffer clearing, Audit-Mode Sysprep guard, SID DACL, non-persistent SMB mapping
      - LD-04 / ADD-01: Immutable target disk identity verification & live SMBIOS hardware queries
      - LD-05 / LD-10: ReleaseManifest.json SHA-256 verification, Admin.Build -WhatIf safety, and clean-target boundary guards
      - LD-06 / LD-07 / LD-11: Crash-safe atomic state persistence with .bak recovery, ADR-0001 local-only database guard, and 48-bit CSPRNG UID generation
      - LD-08 / LD-09: Opt-in plaintext password environment gating and timeout process-tree termination
      - LD-15 / ADD-02 / ADD-05: Mandatory driver SHA-256 & Authenticode enforcement, TLS 1.2+ transport hygiene, and safe BootConfig defaults
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [string]$TestRoot = (Join-Path ([System.IO.Path]::GetTempPath()) ('LiteDeploy-SecurityTests-' + [guid]::NewGuid().ToString('N')))
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

$scriptsRoot = Join-Path $RepoRoot 'Engine\Scripts'
$failures = [System.Collections.Generic.List[string]]::new()
$passes = 0

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if ($Condition) {
        Write-Host "[PASS] $Message" -ForegroundColor Green
        $script:passes++
    }
    else {
        Write-Host "[FAIL] $Message" -ForegroundColor Red
        $script:failures.Add($Message)
    }
}

function Get-FunctionFromScriptAst {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string[]]$FunctionNames
    )
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "Parse error in ${ScriptPath}: $($errors[0].Message)"
    }
    $blocks = foreach ($fnName in $FunctionNames) {
        $node = $ast.Find({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName
            }, $true)
        if ($null -eq $node) {
            throw "Function '$fnName' not found in $ScriptPath"
        }
        $node.Extent.Text
    }
    return ($blocks -join [Environment]::NewLine)
}

Write-Host "LiteDeploy Security & Reliability Hardening Test Suite" -ForegroundColor Cyan
Write-Host "Repo: $RepoRoot"

$null = New-Item -Path $TestRoot -ItemType Directory -Force

try {
    # =========================================================================
    # 0. AST Parse Verification across all Engine & Test scripts
    # =========================================================================
    $allScripts = @(
        Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'Engine') -Filter '*.ps1' -Recurse -File
        Get-ChildItem -LiteralPath (Join-Path $RepoRoot '_Tests') -Filter '*.ps1' -Recurse -File
    )
    foreach ($scriptFile in $allScripts) {
        $parseErrors = $null
        $tokens = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors)
        Assert-True ($parseErrors.Count -eq 0) "AST Parse: $($scriptFile.Name)"
    }

    # =========================================================================
    # 1. LD-01, LD-02, LD-14: Unattend Hardening, Preflight Policy, & Injection Prevention
    # =========================================================================
    $imageScriptPath = Join-Path $scriptsRoot 'Runtime\080-Image\LiteDeploy.Image.ps1'
    $uiSelectionPath = Join-Path $scriptsRoot 'Runtime\110-UI\WorkflowSelection\LiteDeploy.UI.WorkflowSelection.ps1'

    $unattendChecks = & {
        . $imageScriptPath
        function Write-ComponentLog { param($Message, $Level, $ForegroundColor) }

        $prodTemplates = @('Standard.xml', 'DomainJoin.xml', 'IntuneReady.xml')
        $prodClean = $true
        foreach ($tmplName in $prodTemplates) {
            $tmplPath = Join-Path $RepoRoot "DeploymentShare\Content\Unattend\$tmplName"
            $outPath = Join-Path $TestRoot "Prod-$tmplName"
            $cfg = @{
                ComputerSetup = @{
                    PromptForComputerName        = $true
                    PromptForComputerDescription = $true
                    Language                     = 'en-US'
                    KeyboardLocale               = '0409:00000409'
                    TimeZone                     = 'Eastern Standard Time'
                    RegisteredOwner              = 'SecOps $1 & <Team>'
                    RegisteredOrganization       = 'Agency "Alpha" & Sons'
                    JoinWorkGroup                = 'WORKGROUP'
                }
            }
            $wf = [pscustomobject]@{
                WorkflowName        = 'Secured -- Deployment --> Flow'
                ComputerName        = 'WKS-001'
                ComputerDescription = 'Standard Asset 001'
            }
            $null = New-LiteDeployUnattendXml -TemplateFile $tmplPath -TargetOutputFile $outPath -ConfigObj $cfg -WorkflowData $wf
            [xml]$doc = Get-Content -LiteralPath $outPath -Raw
            $validation = Test-LiteDeployUnattendDocument -XmlDocument $doc -Path $outPath -PassThru
            if (-not $validation.Passed) { $prodClean = $false }
            if ($doc.SelectSingleNode("//*[local-name()='UserAccounts']//*[local-name()='LocalAccount']")) { $prodClean = $false }
            if ($doc.SelectSingleNode("//*[local-name()='AutoLogon']")) { $prodClean = $false }
            if ($doc.OuterXml -match 'srvcomment') { $prodClean = $false }
            $ownerNode = $doc.SelectSingleNode("//*[local-name()='RegisteredOwner']")
            if ($null -eq $ownerNode -or $ownerNode.InnerText -cne 'SecOps $1 & <Team>') { $prodClean = $false }
        }

        $unsafeFixture = Join-Path $RepoRoot '_Tests\Fixtures\UNSAFE-DEV-ONLY\DomainJoin.UnsafeDev.xml'
        $unsafeOut = Join-Path $TestRoot 'UnsafeOut.xml'
        $unsafeBlockedByDefault = $false
        try {
            $null = New-LiteDeployUnattendXml -TemplateFile $unsafeFixture -TargetOutputFile $unsafeOut -ConfigObj @{ ComputerSetup = @{} }
        }
        catch {
            $unsafeBlockedByDefault = ($_.Exception.Message -match 'Policy violation')
        }

        $unsafeAllowedWithSwitch = $false
        try {
            $null = New-LiteDeployUnattendXml -TemplateFile $unsafeFixture -TargetOutputFile $unsafeOut -ConfigObj @{ ComputerSetup = @{} } -AllowUnsafeLabUnattend
            $unsafeAllowedWithSwitch = (Test-Path -LiteralPath $unsafeOut)
        }
        catch {
            $unsafeAllowedWithSwitch = $false
        }

        $injectionPayloadsRejected = $true
        foreach ($badDesc in @(
                'Foo" & calc.exe & rem "',
                'Asset | powershell -enc AAAA',
                'Bad &gt; Comment',
                "Line1`r`nLine2",
                ('A' * 128)
            )) {
            $descValid = Test-LiteDeployComputerDescription -ComputerDescription $badDesc
            if ($descValid) { $injectionPayloadsRejected = $false }
            $threw = $false
            try {
                $null = New-LiteDeployUnattendXml `
                    -TemplateFile (Join-Path $RepoRoot 'DeploymentShare\Content\Unattend\Standard.xml') `
                    -TargetOutputFile (Join-Path $TestRoot 'BadDesc.xml') `
                    -ConfigObj @{ ComputerSetup = @{ PromptForComputerDescription = $true } } `
                    -WorkflowData ([pscustomobject]@{ ComputerDescription = $badDesc })
            }
            catch {
                $threw = $true
            }
            if (-not $threw) { $injectionPayloadsRejected = $false }
        }

        [pscustomobject]@{
            ProdClean               = $prodClean
            UnsafeBlockedByDefault  = $unsafeBlockedByDefault
            UnsafeAllowedWithSwitch = $unsafeAllowedWithSwitch
            InjectionRejected       = $injectionPayloadsRejected
        }
    }

    Assert-True $unattendChecks.ProdClean 'LD-01/LD-02: Production Unattend templates contain no credentials/AutoLogon, preserve $1/&/< safely, and omit cmd.exe srvcomment'
    Assert-True $unattendChecks.UnsafeBlockedByDefault 'LD-01/LD-14: Unsafe lab Unattend fixture with LocalAccount/AutoLogon is blocked by default'
    Assert-True $unattendChecks.UnsafeAllowedWithSwitch 'LD-14: Unsafe lab Unattend fixture is permitted only when -AllowUnsafeLabUnattend is explicitly supplied'
    Assert-True $unattendChecks.InjectionRejected 'LD-02: Adversarial ComputerDescription payloads (shell metacharacters, control chars, >127 chars) are rejected'

    $uiValidationChecks = & {
        . ([scriptblock]::Create((Get-FunctionFromScriptAst -ScriptPath $uiSelectionPath -FunctionNames @(
                        'Get-LiteDeployComputerNameValidationError',
                        'Get-LiteDeployComputerDescriptionValidationError'
                    ))))

        $numericNameRejected = -not [string]::IsNullOrWhiteSpace((Get-LiteDeployComputerNameValidationError -Name '123456'))
        $hyphenNameRejected = -not [string]::IsNullOrWhiteSpace((Get-LiteDeployComputerNameValidationError -Name '-BADPC'))
        $validNameAccepted = [string]::IsNullOrWhiteSpace((Get-LiteDeployComputerNameValidationError -Name 'PC-01'))
        $shellDescRejected = -not [string]::IsNullOrWhiteSpace((Get-LiteDeployComputerDescriptionValidationError -Description 'PC & whoami'))
        $validDescAccepted = [string]::IsNullOrWhiteSpace((Get-LiteDeployComputerDescriptionValidationError -Description 'Floor 3 Reception PC'))

        [pscustomobject]@{
            NumericNameRejected = $numericNameRejected
            HyphenNameRejected  = $hyphenNameRejected
            ValidNameAccepted   = $validNameAccepted
            ShellDescRejected   = $shellDescRejected
            ValidDescAccepted   = $validDescAccepted
        }
    }
    Assert-True ($uiValidationChecks.NumericNameRejected -and $uiValidationChecks.HyphenNameRejected -and $uiValidationChecks.ValidNameAccepted) 'LD-02: UI ComputerName validator rejects all-numeric and leading-hyphen names'
    Assert-True ($uiValidationChecks.ShellDescRejected -and $uiValidationChecks.ValidDescAccepted) 'LD-02: UI ComputerDescription validator blocks shell metacharacters and accepts valid descriptions'

    # =========================================================================
    # 2. LD-03, P0-LD-01, LD-13, ADD-03, ADD-04: FullOS Security & Secret Hygiene
    # =========================================================================
    $fullOsPath = Join-Path $scriptsRoot 'Runtime\100-Engine\LiteDeploy.FullOS.ps1'
    $probePath = Join-Path $scriptsRoot 'Runtime\100-Engine\LiteDeploy.FullOS.InteractiveProbe.ps1'
    $logsPath = Join-Path $scriptsRoot 'Runtime\010-Logs\LiteDeploy.Logs.ps1'
    $statePath = Join-Path $scriptsRoot 'Runtime\040-State\LiteDeploy.State.ps1'

    $fullOsChecks = & {
        . $statePath
        . ([scriptblock]::Create((Get-FunctionFromScriptAst -ScriptPath $fullOsPath -FunctionNames @(
                        'Get-LiteDeployFullOSSecret',
                        'Complete-LiteDeployFullOSFinalization',
                        'Connect-LiteDeployFullOSDeploymentShare',
                        'Stop-LiteDeployAuditModeSysprep'
                    ))))

        function Write-LiteDeployLog { param($Message, $Level, $ForegroundColor, $Component) }

        # Test P0-LD-01: Get-LiteDeployFullOSSecret zeroes all plaintext Password fields in $read.Payload.Secrets
        $fakeSecret1 = [pscustomobject]@{ Id = 'DeploymentShare'; Username = 'corp\deploy'; Password = 'SuperSecretPassword1!' }
        $fakeSecret2 = [pscustomobject]@{ Id = 'DomainJoin'; Username = 'corp\joiner'; Password = 'SuperSecretPassword2!' }
        $script:mockPayload = [pscustomobject]@{ Secrets = @($fakeSecret1, $fakeSecret2) }

        $mockLocalRoot = Join-Path $TestRoot 'FullOSMockRoot'
        $mockCredDir = Join-Path $mockLocalRoot 'Content\Credentials'
        $mockWinPectDir = Join-Path $mockLocalRoot 'Engine\Tools\WinPECT'
        $null = New-Item -Path $mockCredDir, $mockWinPectDir -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $mockCredDir 'CredentialTransfer.bin') -Value 'mock-bin' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $mockWinPectDir 'WinPECredentialTransfer.ps1') -Value '# mock winpect' -Encoding UTF8

        function Read-WPCTCredentialTransfer {
            param($SecretFilePath, $RegistrySubKey, $ErrorAction)
            return [pscustomobject]@{
                Success = $true
                Payload = $script:mockPayload
            }
        }

        $secretRes = Get-LiteDeployFullOSSecret -LocalRoot $mockLocalRoot -SecretId 'DeploymentShare'
        $credRetrieved = ($null -ne $secretRes -and $secretRes.Success -and $secretRes.UserName -eq 'corp\deploy' -and $secretRes.Credential.GetNetworkCredential().Password -eq 'SuperSecretPassword1!')
        $passwordsZeroed = ($null -eq $fakeSecret1.Password -and $null -eq $fakeSecret2.Password)

        # Test LD-03 & P0-LD-01: Complete-LiteDeployFullOSFinalization purges credentials, restores UAC, clears Run key, updates state
        $script:wpctRemoved = $false
        $script:runKeyCleared = $false
        function Remove-WPCTCredentialTransfer {
            param($SecretFilePath, $RegistrySubKey, $ErrorAction)
            $script:wpctRemoved = $true
            if (Test-Path -LiteralPath $SecretFilePath) { Remove-Item -LiteralPath $SecretFilePath -Force }
            return [pscustomobject]@{ Success = $true }
        }
        function Clear-LiteDeployFullOSRunKey {
            $script:runKeyCleared = $true
            return [pscustomobject]@{
                Success    = $true
                Cleared    = $true
                UacRestore = [pscustomobject]@{ Success = $true; Restored = $true; MarkerCleared = $true }
            }
        }

        $finalStateFile = Join-Path $mockLocalRoot 'DeploymentState.json'
        $initialState = New-LiteDeployDeploymentObject -DeferUid
        $initialState.Status = 'ApplyingOSImage'
        Write-LiteDeployStateFile -Path $finalStateFile -StateObject $initialState

        $finalResult = Complete-LiteDeployFullOSFinalization -OsDriveLetter 'C:' -LocalRootName '~LiteDeploy' -StatePath $finalStateFile -ShareDriveLetter '' -DeploymentState $initialState -FinalStatus 'Completed'
        $savedState = Read-LiteDeployStateFile -Path $finalStateFile

        $fullOsSource = Get-Content -LiteralPath $fullOsPath -Raw
        $noLinkedConnections = ($fullOsSource -notmatch 'EnableLinkedConnections')
        $probeSource = Get-Content -LiteralPath $probePath -Raw
        $hasMutexDacl = ($probeSource -match 'MutexSecurity' -and $probeSource -match 'LocalSystemSid' -and $probeSource -match 'BuiltinAdministratorsSid')
        $logsSource = Get-Content -LiteralPath $logsPath -Raw
        $hasProtectedDirAcl = ($logsSource -match 'Set-LiteDeployProtectedDirectoryAcl' -and $logsSource -match 'LocalSystemSid' -and $logsSource -match 'BuiltinAdministratorsSid')

        [pscustomobject]@{
            CredRetrieved       = $credRetrieved
            PasswordsZeroed     = $passwordsZeroed
            FinalizerComplete   = ($finalResult.Success -and $finalResult.RunKeyCleared -and $finalResult.UacRestored -and $finalResult.RebootRequiredForUac -and $savedState.Status -eq 'Completed')
            NoLinkedConnections = $noLinkedConnections
            HasMutexDacl        = $hasMutexDacl
            HasProtectedDirAcl  = $hasProtectedDirAcl
        }
    }

    Assert-True ($fullOsChecks.CredRetrieved -and $fullOsChecks.PasswordsZeroed) 'P0-LD-01: Get-LiteDeployFullOSSecret zeroes plaintext Password fields on all payload secrets in finally block'
    Assert-True $fullOsChecks.FinalizerComplete 'LD-03/P0-LD-01: Complete-LiteDeployFullOSFinalization purges WinPECT transfer, clears Run key, restores EnableLUA=1, and updates state'
    Assert-True $fullOsChecks.NoLinkedConnections 'ADD-04: Connect-LiteDeployFullOSDeploymentShare does not enable permanent EnableLinkedConnections registry policy'
    Assert-True ($fullOsChecks.HasMutexDacl -and $fullOsChecks.HasProtectedDirAcl) 'ADD-03/LD-13: InteractiveProbe Mutex and ~LiteDeploy directory enforce SID-based SYSTEM/Administrators DACLs'

    # =========================================================================
    # 3. LD-04 & ADD-01: Target Disk Identity Verification & Live Hardware Queries
    # =========================================================================
    $hwPath = Join-Path $scriptsRoot 'Runtime\030-Hardware\LiteDeploy.Hardware.ps1'
    $diskPath = Join-Path $scriptsRoot 'Runtime\060-Disk\LiteDeploy.Disk.ps1'

    $hwDiskChecks = & {
        $hwSource = Get-Content -LiteralPath $hwPath -Raw
        $noHardcodedDell = ($hwSource -notmatch 'return\s+"Dell Inc\."' -and
            $hwSource -notmatch 'return\s+"Latitude 7450"' -and
            $hwSource -notmatch 'return\s+"0CC1"')

        . ([scriptblock]::Create((Get-FunctionFromScriptAst -ScriptPath $diskPath -FunctionNames @(
                        'Assert-LiteDeployTargetDiskIdentity'
                    ))))

        function Get-Partition { param($DiskNumber, $ErrorAction) return @() }

        $validDisk = [pscustomobject]@{
            Number       = 0
            FriendlyName = 'NVMe Samsung SSD'
            SerialNumber = 'S4E5NX0M123456'
            UniqueId     = 'eui.0025388701b12345'
            BusType      = 'NVMe'
            Size         = 512110190592
            IsBoot       = $false
            IsSystem     = $false
        }

        $matched = Assert-LiteDeployTargetDiskIdentity -Disk $validDisk -ExpectedUniqueId 'eui.0025388701b12345' -ExpectedSerialNumber 'S4E5NX0M123456' -ExpectedModel 'NVMe Samsung SSD' -ExpectedSizeBytes 512110190592 -ExpectedBusType 'NVMe'

        # Reject USB bus type
        $usbRejected = $false
        $usbDisk = [pscustomobject]@{ Number = 0; FriendlyName = 'USB Drive'; SerialNumber = '123'; UniqueId = 'u1'; BusType = 'USB'; Size = 64000000000; IsBoot = $false; IsSystem = $false }
        try { $null = Assert-LiteDeployTargetDiskIdentity -Disk $usbDisk } catch { $usbRejected = ($_.Exception.Message -match 'USB') }

        # Reject Boot/System disk
        $bootRejected = $false
        $bootDisk = [pscustomobject]@{ Number = 0; FriendlyName = 'NVMe'; SerialNumber = '123'; UniqueId = 'u1'; BusType = 'NVMe'; Size = 64000000000; IsBoot = $true; IsSystem = $false }
        try { $null = Assert-LiteDeployTargetDiskIdentity -Disk $bootDisk } catch { $bootRejected = ($_.Exception.Message -match 'IsBoot') }

        # Reject SerialNumber mismatch
        $serialMismatchRejected = $false
        try { $null = Assert-LiteDeployTargetDiskIdentity -Disk $validDisk -ExpectedSerialNumber 'WRONG-SERIAL' } catch { $serialMismatchRejected = ($_.Exception.Message -match 'SerialNumber mismatch') }

        # Reject UniqueId mismatch
        $uniqueIdMismatchRejected = $false
        try { $null = Assert-LiteDeployTargetDiskIdentity -Disk $validDisk -ExpectedUniqueId 'WRONG-UID' } catch { $uniqueIdMismatchRejected = ($_.Exception.Message -match 'UniqueId mismatch') }

        [pscustomobject]@{
            NoHardcodedDell          = $noHardcodedDell
            ValidDiskAccepted        = ($matched -eq $true)
            UsbRejected              = $usbRejected
            BootRejected             = $bootRejected
            SerialMismatchRejected   = $serialMismatchRejected
            UniqueIdMismatchRejected = $uniqueIdMismatchRejected
        }
    }

    Assert-True $hwDiskChecks.NoHardcodedDell 'ADD-01: Hardware inventory functions contain no hardcoded Dell/Latitude/0CC1 debug return statements'
    Assert-True ($hwDiskChecks.ValidDiskAccepted -and $hwDiskChecks.UsbRejected -and $hwDiskChecks.BootRejected -and $hwDiskChecks.SerialMismatchRejected -and $hwDiskChecks.UniqueIdMismatchRejected) 'LD-04: Assert-LiteDeployTargetDiskIdentity blocks USB, boot/system disks, and SerialNumber/UniqueId drift before Clear-Disk'

    # =========================================================================
    # 4. LD-05 & LD-10: Release Manifest Integrity & Admin.Build Safety
    # =========================================================================
    $buildPath = Join-Path $scriptsRoot 'Admin\000-Build\LiteDeploy.Admin.Build.ps1'
    $enginePath = Join-Path $scriptsRoot 'Runtime\100-Engine\LiteDeploy.Engine.ps1'

    $buildManifestChecks = & {
        . ([scriptblock]::Create((Get-FunctionFromScriptAst -ScriptPath $buildPath -FunctionNames @(
                        'Write-SyncLog',
                        'Assert-LiteDeploySafeCleanTarget',
                        'New-LiteDeployReleaseManifest'
                    ))))
        . ([scriptblock]::Create((Get-FunctionFromScriptAst -ScriptPath $enginePath -FunctionNames @(
                        'Test-LiteDeployReleaseManifest'
                    ))))
        function Write-LiteDeployLog { param($Message, $Level, $ForegroundColor, $Component) }

        $stageRoot = Join-Path $TestRoot 'StageRoot'
        $scriptsDir = Join-Path $stageRoot 'Engine\Scripts\Runtime'
        $null = New-Item -Path $scriptsDir -ItemType Directory -Force

        $sampleScript = Join-Path $scriptsDir 'LiteDeploy.Disk.ps1'
        Set-Content -LiteralPath $sampleScript -Value 'Write-Output "Original"' -Encoding UTF8

        $manifestPath = New-LiteDeployReleaseManifest -RuntimeDirectory $scriptsDir
        $validBeforeTamper = (Test-LiteDeployReleaseManifest -RuntimeRoot $scriptsDir -ScriptPath $sampleScript)

        # Tamper with script
        Set-Content -LiteralPath $sampleScript -Value 'Write-Output "Tampered"' -Encoding UTF8
        $rejectedAfterTamper = $false
        try {
            $null = Test-LiteDeployReleaseManifest -RuntimeRoot $scriptsDir -ScriptPath $sampleScript
        }
        catch {
            $rejectedAfterTamper = ($_.Exception.Message -match 'Integrity verification failed')
        }

        # SafeCleanTarget checks (blocks drive root / shallow paths; allows deep paths)
        $driveRootRejected = $false
        try {
            $null = Assert-LiteDeploySafeCleanTarget -TargetPath 'C:\'
        }
        catch {
            $driveRootRejected = $true
        }

        $insideAllowed = $false
        try {
            $insideAllowed = Assert-LiteDeploySafeCleanTarget -TargetPath $scriptsDir
        }
        catch {
            $insideAllowed = $false
        }

        [pscustomobject]@{
            ManifestCreated     = (Test-Path -LiteralPath $manifestPath)
            ValidBeforeTamper   = $validBeforeTamper
            RejectedAfterTamper = $rejectedAfterTamper
            OutsideRejected     = $driveRootRejected
            InsideAllowed       = $insideAllowed
        }
    }

    Assert-True ($buildManifestChecks.ManifestCreated -and $buildManifestChecks.ValidBeforeTamper -and $buildManifestChecks.RejectedAfterTamper) 'LD-05: ReleaseManifest.json verifies intact runtime scripts and fails closed when a script is tampered with'
    Assert-True ($buildManifestChecks.OutsideRejected -and $buildManifestChecks.InsideAllowed) 'LD-10: Assert-LiteDeploySafeCleanTarget blocks drive root / shallow paths and allows valid target folders'

    # =========================================================================
    # 5. LD-06, LD-07, LD-11: Atomic State, .bak Recovery, ADR-0001 DB Boundary, 48-Bit CSPRNG UID
    # =========================================================================
    $stateChecks = & {
        . $statePath
        . ([scriptblock]::Create((Get-FunctionFromScriptAst -ScriptPath $enginePath -FunctionNames @('Get-LiteDeployUid'))))
        . ([scriptblock]::Create((Get-FunctionFromScriptAst -ScriptPath $logsPath -FunctionNames @('Initialize-LiteDeployDeploymentShareLogDir', 'Sync-LiteDeployLogsToShare'))))
        function Write-LiteDeployLog { param($Message, $Level, $ForegroundColor, $Component) }

        $stateFile = Join-Path $TestRoot 'StateTest\DeploymentState.json'
        $stateObj1 = New-LiteDeployDeploymentObject -DeferUid
        $stateObj1.Status = 'Checkpoint1'
        Write-LiteDeployStateFile -Path $stateFile -StateObject $stateObj1

        $stateObj2 = New-LiteDeployDeploymentObject -DeferUid
        $stateObj2.Status = 'Checkpoint2'
        Write-LiteDeployStateFile -Path $stateFile -StateObject $stateObj2

        $bakExists = Test-Path -LiteralPath "$stateFile.bak"
        $readPrimary = Read-LiteDeployStateFile -Path $stateFile

        # Corrupt primary state file and verify automatic recovery from .bak
        Set-Content -LiteralPath $stateFile -Value '{corrupt-json' -Encoding UTF8
        $recoveredFromBak = Read-LiteDeployStateFile -Path $stateFile

        # LD-07: Local database path guard
        $uncRejected = $false
        try {
            $null = Test-LiteDeployLocalDatabasePath -DatabasePath '\\fileserver\DeploymentShare\WorkLogs\state.db' -ThrowOnViolation
        }
        catch {
            $uncRejected = ($_.Exception.Message -match 'ADR-0001')
        }
        $localAccepted = Test-LiteDeployLocalDatabasePath -DatabasePath (Join-Path $TestRoot 'LocalState.db')
        $repoAdrPath = Join-Path $RepoRoot 'docs\decisions\ADR-0001-state-persistence-and-pslocalbase-boundaries.md'
        $parentAdrPath = Join-Path (Resolve-Path (Join-Path $RepoRoot '..')).Path 'docs\decisions\ADR-0001-state-persistence-and-pslocalbase-boundaries.md'
        $adrExists = (Test-Path -LiteralPath $repoAdrPath) -or (Test-Path -LiteralPath $parentAdrPath)

        # LD-11: 48-bit CSPRNG UID format & uniqueness + collision rejection
        $uids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $formatValid = $true
        for ($i = 0; $i -lt 200; $i++) {
            $u1 = Get-LiteDeployUid
            $u2 = New-LiteDeployStateUid
            if ($u1 -notmatch '^\d{6}-[0-9A-F]{12}$' -or $u2 -notmatch '^\d{6}-[0-9A-F]{12}$') {
                $formatValid = $false
            }
            $null = $uids.Add($u1)
            $null = $uids.Add($u2)
        }

        $shareRoot = Join-Path $TestRoot 'ShareLogs'
        $localLogs = Join-Path $TestRoot 'LocalLogs'
        $null = New-Item -Path $localLogs -ItemType Directory -Force
        $rtPaths = [pscustomobject]@{ DeploymentRoot = $shareRoot; DeploymentLogRoot = (Join-Path $shareRoot 'WorkLogs\Deployments'); LocalLogDirectory = $localLogs }
        $firstLogDir = Initialize-LiteDeployDeploymentShareLogDir -RuntimePaths $rtPaths -DeploymentUid '261027-ABCDEF012345'
        $collisionRejected = $false
        try {
            $null = Initialize-LiteDeployDeploymentShareLogDir -RuntimePaths $rtPaths -DeploymentUid '261027-ABCDEF012345'
        }
        catch {
            $collisionRejected = ($_.Exception.Message -match 'collision')
        }

        [pscustomobject]@{
            BakExists         = $bakExists
            PrimaryValid      = ($readPrimary.Status -eq 'Checkpoint2')
            RecoveredValid    = ($recoveredFromBak.Status -eq 'Checkpoint1')
            UncRejected       = $uncRejected
            LocalAccepted     = $localAccepted
            AdrExists         = $adrExists
            UidFormatValid    = ($formatValid -and $uids.Count -eq 400)
            CollisionRejected = ($null -ne $firstLogDir -and $collisionRejected)
        }
    }

    Assert-True ($stateChecks.BakExists -and $stateChecks.PrimaryValid -and $stateChecks.RecoveredValid) 'LD-06: Write-LiteDeployStateFile performs atomic replacement with .bak creation and Read-LiteDeployStateFile recovers from .bak on corruption'
    Assert-True ($stateChecks.UncRejected -and $stateChecks.LocalAccepted -and $stateChecks.AdrExists) 'LD-07: Test-LiteDeployLocalDatabasePath blocks UNC/SMB SQLite paths per ADR-0001'
    Assert-True ($stateChecks.UidFormatValid -and $stateChecks.CollisionRejected) 'LD-11: Deployment UIDs use 48-bit CSPRNG (yyMMdd-XXXXXXXXXXXX) and remote log initialization rejects collisions'

    # =========================================================================
    # 6. LD-08 & LD-09: Package Secret Environment Gating & Process-Tree Kill
    # =========================================================================
    $pkgPath = Join-Path $scriptsRoot 'Runtime\090-Packages\LiteDeploy.Packages.ps1'
    $envPath = Join-Path $scriptsRoot 'Runtime\020-Environment\LiteDeploy.Environment.ps1'

    $pkgChecks = & {
        . ([scriptblock]::Create((Get-FunctionFromScriptAst -ScriptPath $pkgPath -FunctionNames @(
                        'ConvertTo-LiteDeployPackageEnvironment',
                        'Stop-LiteDeployProcessTree'
                    ))))
        function Write-LiteDeployLog { param($Message, $Level, $ForegroundColor, $Component) }

        $secPass = ConvertTo-SecureString 'P@ssw0rd123!' -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential ('corp\svc_pkg', $secPass)
        $secretMap = @{ DomainCred = $cred; ApiToken = $secPass }
        $mockPkg = [pscustomobject]@{ PackageId = 'test-pkg'; ShareRoot = $TestRoot }

        $envDefault = ConvertTo-LiteDeployPackageEnvironment -Package $mockPkg -PayloadPath $TestRoot -Parameters $secretMap
        $omittedByDefault = (-not $envDefault.ContainsKey('LITEDEPLOY_PARAM_DOMAINCRED_PASSWORD') -and
            -not $envDefault.ContainsKey('LITEDEPLOY_PARAM_APITOKEN') -and
            $envDefault['LITEDEPLOY_PARAM_DOMAINCRED_USERNAME'] -eq 'corp\svc_pkg')

        $envOptIn = ConvertTo-LiteDeployPackageEnvironment -Package $mockPkg -PayloadPath $TestRoot -Parameters $secretMap -AllowPlaintextPasswordEnv
        $includedWhenOptIn = ($envOptIn['LITEDEPLOY_PARAM_DOMAINCRED_PASSWORD'] -eq 'P@ssw0rd123!' -and
            $envOptIn['LITEDEPLOY_PARAM_APITOKEN'] -eq 'P@ssw0rd123!')

        $driversSource = Get-Content -LiteralPath (Join-Path $scriptsRoot 'Runtime\070-Drivers\LiteDeploy.Drivers.ps1') -Raw
        $pkgSource = Get-Content -LiteralPath $pkgPath -Raw
        $hasTreeKill = ($pkgSource -match 'Stop-LiteDeployProcessTree' -and $driversSource -match 'taskkill\.exe.*/T\s+/F')

        [pscustomobject]@{
            OmittedByDefault  = $omittedByDefault
            IncludedWhenOptIn = $includedWhenOptIn
            HasTreeKill       = $hasTreeKill
        }
    }

    Assert-True ($pkgChecks.OmittedByDefault -and $pkgChecks.IncludedWhenOptIn) 'LD-08: ConvertTo-LiteDeployPackageEnvironment omits plaintext _PASSWORD by default and requires explicit opt-in'
    Assert-True $pkgChecks.HasTreeKill 'LD-09: Both LiteDeploy.Packages.ps1 and LiteDeploy.Drivers.ps1 terminate descendant process trees on timeout'

    # =========================================================================
    # 7. LD-15, ADD-02, ADD-05: Driver Integrity, Transport Hygiene, & BootConfig Defaults
    # =========================================================================
    $driversPath = Join-Path $scriptsRoot 'Runtime\070-Drivers\LiteDeploy.Drivers.ps1'
    $adminDriversPath = Join-Path $scriptsRoot 'Admin\030-Drivers\LiteDeploy.Admin.Drivers.ps1'
    $bootConfigPath = Join-Path $RepoRoot 'DeploymentShare\Config\BootConfig.json'

    $driverAndConfigChecks = & {
        . ([scriptblock]::Create((Get-FunctionFromScriptAst -ScriptPath $driversPath -FunctionNames @(
                        'Stage-LiteDeployDrivers',
                        'Expand-LiteDeployDriverPackage'
                    ))))
        . ([scriptblock]::Create((Get-FunctionFromScriptAst -ScriptPath $adminDriversPath -FunctionNames @(
                        'Test-PackHash'
                    ))))
        function Write-LiteDeployLog { param($Message, $Level, $ForegroundColor, $Component) }
        function Write-Log { param($Message, $Level) }

        $dummyArchive = Join-Path $TestRoot 'DummyDriver.exe'
        Set-Content -LiteralPath $dummyArchive -Value 'dummy-archive-bytes' -Encoding UTF8
        $actualHash = (Get-FileHash -LiteralPath $dummyArchive -Algorithm SHA256).Hash

        # Missing SHA256 must fail closed in Stage-LiteDeployDrivers
        $missingRes = Stage-LiteDeployDrivers `
            -ShareRoot $TestRoot `
            -Detection ([pscustomobject]@{ IsDetected = $true; SourceKind = 'Archive'; FullPath = $dummyArchive; SHA256 = '' }) `
            -DestinationPath (Join-Path $TestRoot 'DriverStage1')
        $missingHashRejected = (-not $missingRes.Success -and $missingRes.Status -eq 'MissingHash')

        # Mismatched SHA256 must fail closed
        $badHashRes = Stage-LiteDeployDrivers `
            -ShareRoot $TestRoot `
            -Detection ([pscustomobject]@{ IsDetected = $true; SourceKind = 'Archive'; FullPath = $dummyArchive; SHA256 = ('0' * 64) }) `
            -DestinationPath (Join-Path $TestRoot 'DriverStage2')
        $badHashRejected = (-not $badHashRes.Success -and $badHashRes.Message -match 'failed SHA256 integrity check')

        # Admin Test-PackHash fails closed when SHA256 is missing
        $adminMissingHashRejected = -not (Test-PackHash -Path $dummyArchive -Pack ([pscustomobject]@{ FileName = 'DummyDriver.exe'; SHA256 = '' }))
        $adminValidHashAccepted = (Test-PackHash -Path $dummyArchive -Pack ([pscustomobject]@{ FileName = 'DummyDriver.exe'; SHA256 = $actualHash }))

        $adminDriverSource = Get-Content -LiteralPath $adminDriversPath -Raw
        $noInsecureCurl = ($adminDriverSource -notmatch 'Install-Curl' -and
            $adminDriverSource -notmatch 'http://curl\.se' -and
            $adminDriverSource -notmatch '--ssl-no-revoke')

        $runtimeDriverSource = Get-Content -LiteralPath $driversPath -Raw
        $hasAuthenticodeCheck = ($runtimeDriverSource -match 'Get-AuthenticodeSignature' -and $adminDriverSource -match 'Get-AuthenticodeSignature')

        $bootCfg = Get-Content -LiteralPath $bootConfigPath -Raw | ConvertFrom-Json
        $safeBootConfig = ($bootCfg.ComputerSetup.SkipSetupHardwareRequirements -eq $false -and $bootCfg.Ui.Theme -eq 'Light')

        [pscustomobject]@{
            MissingHashRejected      = $missingHashRejected
            BadHashRejected          = $badHashRejected
            AdminMissingHashRejected = $adminMissingHashRejected
            AdminValidHashAccepted   = $adminValidHashAccepted
            NoInsecureCurl           = $noInsecureCurl
            HasAuthenticodeCheck     = $hasAuthenticodeCheck
            SafeBootConfig           = $safeBootConfig
        }
    }

    Assert-True ($driverAndConfigChecks.MissingHashRejected -and $driverAndConfigChecks.BadHashRejected -and $driverAndConfigChecks.AdminMissingHashRejected -and $driverAndConfigChecks.AdminValidHashAccepted) 'LD-15/ADD-02: Runtime and Admin driver verification fail closed on missing or mismatched SHA-256 digests'
    Assert-True ($driverAndConfigChecks.NoInsecureCurl -and $driverAndConfigChecks.HasAuthenticodeCheck) 'LD-15/ADD-02: Driver scripts enforce Authenticode signature checks on .exe extractors and remove insecure curl/revocation bypasses'
    Assert-True $driverAndConfigChecks.SafeBootConfig 'ADD-05: BootConfig.json ships with SkipSetupHardwareRequirements=false and valid Ui.Theme=Light'
}
finally {
    if (Test-Path -LiteralPath $TestRoot) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Security Hardening Suite - Passed: $passes  Failed: $($failures.Count)" -ForegroundColor $(if ($failures.Count -eq 0) { 'Green' } else { 'Red' })
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
}
exit 0
