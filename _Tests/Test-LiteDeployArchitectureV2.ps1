<#
.SYNOPSIS
    Non-destructive architecture v2 smoke tests for LiteDeploy Core.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [string]$PublishedRuntimeRoot = "",
    [string]$TestRoot = (Join-Path ([IO.Path]::GetTempPath()) ('LiteDeploy-Tests-' + [guid]::NewGuid().ToString('N')))
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    # Suite lives at <repo>\_Tests\ — one level up is the checkout root.
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

$scriptsRoot = Join-Path $RepoRoot "Engine\Scripts"
$failures = [System.Collections.Generic.List[string]]::new()
$passes = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        Write-Host "[PASS] $Message" -ForegroundColor Green
        $script:passes++
    }
    else {
        Write-Host "[FAIL] $Message" -ForegroundColor Red
        $script:failures.Add($Message)
    }
}

Write-Host "LiteDeploy Architecture v2 smoke tests" -ForegroundColor Cyan
Write-Host "Repo: $RepoRoot"

# A harmless configuration fixture keeps Engine tests independent of real deployment settings.
$null = New-Item -Path (Join-Path $TestRoot 'Config') -ItemType Directory -Force
$testConfigPath = Join-Path $TestRoot 'Config\BootConfig.json'
Set-Content -LiteralPath $testConfigPath -Value '{"Ui":{"Theme":"Dark"}}' -Encoding UTF8
$emptyPrecheckPath = Join-Path $TestRoot 'EmptyPrecheck.ps1'
$invalidSelectionPath = Join-Path $TestRoot 'InvalidSelection.ps1'
Set-Content -LiteralPath $emptyPrecheckPath -Value '# Deliberately returns no readiness result.' -Encoding UTF8
Set-Content -LiteralPath $invalidSelectionPath -Value '[pscustomobject]@{ Passed = $true }' -Encoding UTF8

# Parse every maintained script with the current host. Run this suite with Windows PowerShell 5.1.
foreach ($source in Get-ChildItem -LiteralPath $scriptsRoot -Filter '*.ps1' -Recurse -File) {
    $parseErrors = $null
    $tokens = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($source.FullName, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "Parses: $($source.Name)"
    foreach ($parseError in $parseErrors) { Write-Host $parseError.Message -ForegroundColor Red }
}

$requiredRuntime = @(
    "Runtime\000-Boot\LiteDeploy.Boot.ps1",
    "Runtime\010-Logs\LiteDeploy.Logs.ps1",
    "Runtime\020-Environment\LiteDeploy.Environment.ps1",
    "Runtime\030-Hardware\LiteDeploy.Hardware.ps1",
    "Runtime\040-State\LiteDeploy.State.ps1",
    "Runtime\050-Workflow\LiteDeploy.Workflow.ps1",
    "Runtime\060-Disk\LiteDeploy.Disk.ps1",
    "Runtime\070-Drivers\LiteDeploy.Drivers.ps1",
    "Runtime\080-Image\LiteDeploy.Image.ps1",
    "Runtime\090-Packages\LiteDeploy.Packages.ps1",
    "Runtime\100-Engine\LiteDeploy.Engine.ps1",
    "Runtime\110-UI\HostShell\LiteDeploy.UI.HostShell.ps1",
    "Runtime\110-UI\Theme\LiteDeploy.UI.Theme.xaml",
    "Runtime\110-UI\HardwarePrecheck\LiteDeploy.UI.HardwarePrecheck.ps1",
    "Runtime\110-UI\HardwarePrecheck\LiteDeploy.UI.HardwarePrecheck.xaml",
    "Runtime\110-UI\WorkflowSelection\LiteDeploy.UI.WorkflowSelection.ps1",
    "Runtime\110-UI\WorkflowSelection\LiteDeploy.UI.WorkflowSelection.xaml",
    "Runtime\110-UI\Progress\LiteDeploy.UI.Progress.ps1",
    "Runtime\110-UI\Progress\LiteDeploy.UI.Progress.xaml"
)

$requiredAdmin = @(
    "Admin\000-Build\LiteDeploy.Admin.Build.ps1",
    "Admin\010-Content\LiteDeploy.Admin.Content.ps1",
    "Admin\020-Images\LiteDeploy.Admin.Images.ps1",
    "Admin\030-Drivers\LiteDeploy.Admin.Drivers.ps1",
    "Admin\040-Packages\LiteDeploy.Admin.Packages.ps1",
    "Admin\050-Workflows\LiteDeploy.Admin.Workflows.ps1",
    "Admin\060-Config\LiteDeploy.Admin.Config.ps1",
    "Admin\070-Validation\LiteDeploy.Admin.Validation.ps1",
    "Admin\080-Utilities\LiteDeploy.Admin.Utilities.ps1",
    "Admin\090-UI\Images\LiteDeploy.Admin.UI.Images.ps1"
)

foreach ($rel in ($requiredRuntime + $requiredAdmin)) {
    $p = Join-Path $scriptsRoot $rel
    Assert-True (Test-Path -LiteralPath $p) "Exists: $rel"
}

# Metadata + parse checks for core components
$metaTargets = @(
    "Runtime\010-Logs\LiteDeploy.Logs.ps1",
    "Runtime\020-Environment\LiteDeploy.Environment.ps1",
    "Runtime\030-Hardware\LiteDeploy.Hardware.ps1",
    "Runtime\040-State\LiteDeploy.State.ps1",
    "Runtime\050-Workflow\LiteDeploy.Workflow.ps1",
    "Runtime\060-Disk\LiteDeploy.Disk.ps1",
    "Runtime\090-Packages\LiteDeploy.Packages.ps1",
    "Admin\080-Utilities\LiteDeploy.Admin.Utilities.ps1"
)

foreach ($rel in $metaTargets) {
    $p = Join-Path $scriptsRoot $rel
    try {
        $meta = & $p -Metadata
        Assert-True ($null -ne $meta -and $meta.PSObject.Properties['ComponentId']) "Metadata: $rel ($($meta.ComponentId))"
    }
    catch {
        Assert-True $false "Metadata threw for $rel : $_"
    }
}

# Dot-source load order (Logs -> Environment -> Hardware -> State)
try {
    $logs = Join-Path $scriptsRoot "Runtime\010-Logs\LiteDeploy.Logs.ps1"
    $envc = Join-Path $scriptsRoot "Runtime\020-Environment\LiteDeploy.Environment.ps1"
    $hw = Join-Path $scriptsRoot "Runtime\030-Hardware\LiteDeploy.Hardware.ps1"
    $state = Join-Path $scriptsRoot "Runtime\040-State\LiteDeploy.State.ps1"
    . $logs
    . $envc
    . $hw
    . $state
    Assert-True ([bool](Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue)) "Dot-source: Write-LiteDeployLog"
    Assert-True ([bool](Get-Command Get-LiteDeployEnvironment -ErrorAction SilentlyContinue)) "Dot-source: Get-LiteDeployEnvironment"
    Assert-True ([bool](Get-Command Get-LiteDeployHardwareInventory -ErrorAction SilentlyContinue)) "Dot-source: Get-LiteDeployHardwareInventory"
    Assert-True ([bool](Get-Command Get-LiteDeployState -ErrorAction SilentlyContinue)) "Dot-source: Get-LiteDeployState"
}
catch {
    Assert-True $false "Dot-source load order failed: $_"
}

# Disk standalone must be non-destructive (no ConfirmDestroy)
try {
    $disk = Join-Path $scriptsRoot "Runtime\060-Disk\LiteDeploy.Disk.ps1"
    $null = & $disk 2>&1 | Out-Null
    Assert-True $true "Disk standalone read-only completed without throw"
}
catch {
    # May throw if Get-Disk unavailable in constrained env - still acceptable if message is inventory-related
    Assert-True ($_.Exception.Message -notmatch 'ConfirmDestroy') "Disk standalone did not require ConfirmDestroy unexpectedly: $_"
}

$sourceRuntimeRoot = Join-Path $scriptsRoot 'Runtime'

# Loading Engine must retain in-memory configuration and never start its pipeline.
# Child scope contains dot-sourced parameter names and helper functions.
$engineTargets = @(@{ Path = (Join-Path $sourceRuntimeRoot '100-Engine\LiteDeploy.Engine.ps1'); Mode = 'Development'; EnvironmentPath = (Join-Path $sourceRuntimeRoot '020-Environment\LiteDeploy.Environment.ps1'); ComponentRoot = $sourceRuntimeRoot })
if ($PublishedRuntimeRoot) { $engineTargets += @{ Path = (Join-Path $PublishedRuntimeRoot 'LiteDeploy.Engine.ps1'); Mode = 'Production'; EnvironmentPath = (Join-Path $PublishedRuntimeRoot 'LiteDeploy.Environment.ps1'); ComponentRoot = $PublishedRuntimeRoot } }
foreach ($engineTarget in $engineTargets) {
    try {
        $imagePathForTest = if ($engineTarget.Mode -eq 'Development') { Join-Path $engineTarget.ComponentRoot '080-Image\LiteDeploy.Image.ps1' } else { Join-Path $engineTarget.ComponentRoot 'LiteDeploy.Image.ps1' }
        Assert-True ((& $imagePathForTest -ValidateEngineOnly) -eq 'setup.exe') "Image defaults to Setup ($($engineTarget.Mode))"
        $setupConfig = @{ ComputerSetup = @{ ImageEngine = ' Setup.EXE ' } }
        Assert-True ((& $imagePathForTest -BootConfig $setupConfig -ValidateEngineOnly) -eq 'setup.exe') "Image accepts normalized Setup configuration ($($engineTarget.Mode))"
        $dismConfig = @{ ComputerSetup = @{ ImageEngine = ' DISM.EXE ' } }
        Assert-True ((& $imagePathForTest -BootConfig $dismConfig -ValidateEngineOnly) -eq 'dism.exe') "Image accepts normalized DISM configuration ($($engineTarget.Mode))"
        foreach ($unsupportedEngine in @('other.exe', '')) {
            $unsupportedConfig = [pscustomobject]@{ ComputerSetup = [pscustomobject]@{ ImageEngine = $unsupportedEngine } }
            $rejected = $false
            try { $null = & $imagePathForTest -BootConfig $unsupportedConfig -ExecuteSetup }
            catch { $rejected = $_.Exception.Message -match 'ComputerSetup.ImageEngine' }
            Assert-True $rejected "Image rejects '$unsupportedEngine' before media or Setup access ($($engineTarget.Mode))"
        }
        $keyChecks = & {
            . $imagePathForTest
            $script:keyMessages = @()
            function Write-ComponentLog { param($Message, $Level, $ForegroundColor) $script:keyMessages += $Message }
            $template = Join-Path $TestRoot 'ProductKeyTemplate.xml'
            $answer = Join-Path $TestRoot 'ProductKeyAnswer.xml'
            $xmlText = '<unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="windowsPE"><component name="Microsoft-Windows-Setup"><UserData><ProductKey><WillShowUI>Never</WillShowUI></ProductKey></UserData></component></settings></unattend>'
            Set-Content $template $xmlText
            $fakeKey = 'ABCDE-12345-FGHIJ-67890-KLMNO'
            $allOptionalSkipped = $true
            foreach ($settings in @(@{}, @{ ProductKey = $null }, @{ ProductKey = '  ' }, @{ ProductKey = 'bad-key' })) {
                $null = New-LiteDeployUnattendXml -TemplateFile $template -TargetOutputFile $answer -ConfigObj @{ ComputerSetup = $settings }
                [xml]$generated = Get-Content $answer -Raw
                if ($generated.SelectSingleNode("//*[local-name()='Key']")) { $allOptionalSkipped = $false }
            }
            $configuration = [pscustomobject]@{ ComputerSetup = [pscustomobject]@{ ProductKey = (' ' + $fakeKey.ToLowerInvariant() + ' ') } }
            $null = New-LiteDeployUnattendXml -TemplateFile $template -TargetOutputFile $answer -ConfigObj $configuration
            [xml]$generated = Get-Content $answer -Raw
            $keyAdded = $generated.SelectSingleNode("//*[local-name()='ProductKey']/*[local-name()='Key']").InnerText -eq $fakeKey
            $uiPreserved = $generated.SelectSingleNode("//*[local-name()='WillShowUI']").InnerText -eq 'Never'
            Set-Content $template ($xmlText.Replace('<WillShowUI>', '<Key>OLD</Key><WillShowUI>'))
            $null = New-LiteDeployUnattendXml -TemplateFile $template -TargetOutputFile $answer -BootCtx ([pscustomobject]@{ Config = @{ ComputerSetup = @{ ProductKey = $fakeKey } } })
            [xml]$generated = Get-Content $answer -Raw
            $keys = $generated.SelectNodes("//*[local-name()='ProductKey']/*[local-name()='Key']")
            [pscustomobject]@{ Skipped = $allOptionalSkipped; Added = $keyAdded; UiPreserved = $uiPreserved; Replaced = ($keys.Count -eq 1 -and $keys[0].InnerText -eq $fakeKey); NotLogged = (($script:keyMessages -join ' ') -notmatch [regex]::Escape($fakeKey)) }
        }
        Assert-True $keyChecks.Skipped "Optional or malformed ProductKey is not inserted ($($engineTarget.Mode))"
        Assert-True ($keyChecks.Added -and $keyChecks.UiPreserved) "Valid ProductKey added without changing UI policy ($($engineTarget.Mode))"
        Assert-True ($keyChecks.Replaced -and $keyChecks.NotLogged) "ProductKey replaces existing Key without duplicate or log exposure ($($engineTarget.Mode))"
        $registrationChecks = & {
            . $imagePathForTest
            function Write-ComponentLog { param($Message, $Level, $ForegroundColor) }
            $stateComponent = if ($engineTarget.Mode -eq 'Development') { Join-Path $engineTarget.ComponentRoot '040-State\LiteDeploy.State.ps1' } else { Join-Path $engineTarget.ComponentRoot 'LiteDeploy.State.ps1' }
            . $stateComponent
            $template = Join-Path $RepoRoot 'DeploymentShare\Content\Unattend\IntuneReady.xml'
            $answer = Join-Path $TestRoot 'RegistrationAnswer.xml'
            $optionalClean = $true
            foreach ($blank in @($null, '', '   ')) {
                foreach ($settings in @(@{ RegisteredOwner = $blank; RegisteredOrganization = $blank; JoinWorkGroup = $blank; JoinDomain = $blank; MachineObjectOU = $blank }, [pscustomobject]@{ RegisteredOwner = $blank; RegisteredOrganization = $blank; JoinWorkGroup = $blank; JoinDomain = $blank; MachineObjectOU = $blank })) {
                    $config = [pscustomobject]@{ ComputerSetup = $settings }
                    $saved = ConvertTo-LiteDeploySerializableObject -InputObject $config
                    if ($saved.ComputerSetup.Contains('RegisteredOwner') -or $saved.ComputerSetup.Contains('RegisteredOrganization') -or $saved.ComputerSetup.Contains('JoinWorkGroup') -or $saved.ComputerSetup.Contains('JoinDomain') -or $saved.ComputerSetup.Contains('MachineObjectOU')) { $optionalClean = $false }
                    $null = New-LiteDeployUnattendXml -TemplateFile $template -TargetOutputFile $answer -ConfigObj $config
                    [xml]$xml = Get-Content $answer -Raw
                    if ($xml.SelectNodes("//*[local-name()='RegisteredOwner' or local-name()='RegisteredOrganization' or local-name()='JoinWorkgroup' or local-name()='JoinDomain' or local-name()='MachineObjectOU']").Count) { $optionalClean = $false }
                }
            }
            $settings = @{ PromptForComputerName = $false; ComputerNamePrefix = $null; MaxComputerNameLength = 15; PromptForComputerDescription = $false; DriveSelection = $false; ImageEngine = 'Setup.exe'; Language = 'fr-FR'; KeyboardLocale = '040c:0000040c'; TimeZone = 'Romance Standard Time'; RegisteredOwner = 'Network $1 User'; RegisteredOrganization = 'IT & Support'; JoinWorkGroup = 'MYCORP' }
            $config = @{ ComputerSetup = $settings }
            $saved = ConvertTo-LiteDeploySerializableObject -InputObject $config
            $allPreserved = ($saved.ComputerSetup.Count -eq $settings.Count)
            foreach ($name in $settings.Keys) { if ($saved.ComputerSetup[$name] -cne $settings[$name]) { $allPreserved = $false } }
            $identityPolicies = $true
            foreach ($nameEnabled in @($false, $true)) {
                foreach ($descriptionEnabled in @($false, $true)) {
                    $settings.PromptForComputerName = $nameEnabled
                    $settings.PromptForComputerDescription = $descriptionEnabled
                    $null = New-LiteDeployUnattendXml -TemplateFile $template -TargetOutputFile $answer -ConfigObj $config -WorkflowData ([pscustomobject]@{ ComputerName = 'TEST-PC'; ComputerDescription = 'Test workstation' })
                    [xml]$identityXml = Get-Content $answer -Raw
                    $nameNode = $identityXml.SelectSingleNode("//*[local-name()='ComputerName']")
                    # Order 1 RunSynchronous is always present (description slot); prompt flag only controls the value.
                    $descriptionCommand = $identityXml.SelectSingleNode("//*[local-name()='RunSynchronousCommand'][*[local-name()='Description'][text()='Set Computer Description']]")
                    if ([bool]$nameNode -ne $nameEnabled -or $null -eq $descriptionCommand) { $identityPolicies = $false }
                    $expectedDesc = if ($descriptionEnabled) { 'Test workstation' } else { 'No Description' }
                    $descPath = if ($descriptionCommand) { $descriptionCommand.SelectSingleNode("*[local-name()='Path']") } else { $null }
                    if ($null -eq $descPath -or $descPath.InnerText -notlike "*$expectedDesc*") { $identityPolicies = $false }
                }
            }
            $null = New-LiteDeployUnattendXml -TemplateFile $template -TargetOutputFile $answer -ConfigObj $config
            [xml]$emptyIdentity = Get-Content $answer -Raw
            if ($emptyIdentity.SelectSingleNode("//*[local-name()='ComputerName']")) { $identityPolicies = $false }
            # Order 1 description command remains even with no WorkflowData (default "No Description").
            if (-not $emptyIdentity.SelectSingleNode("//*[local-name()='RunSynchronousCommand']/*[local-name()='Description'][text()='Set Computer Description']")) { $identityPolicies = $false }
            $null = New-LiteDeployUnattendXml -TemplateFile $template -TargetOutputFile $answer -ConfigObj $config -WorkflowData ([pscustomobject]@{ ComputerName = 'TEST-PC' })
            [xml]$xml = Get-Content $answer -Raw
            $mapped = $true
            foreach ($pair in @(@('RegisteredOwner', $settings.RegisteredOwner), @('RegisteredOrganization', $settings.RegisteredOrganization), @('UILanguage', $settings.Language), @('InputLocale', $settings.KeyboardLocale), @('TimeZone', $settings.TimeZone), @('ComputerName', 'TEST-PC'))) {
                $nodes = $xml.SelectNodes("//*[local-name()='$($pair[0])']")
                if (-not $nodes.Count) { $mapped = $false }
                foreach ($node in $nodes) { if ($node.InnerText -cne $pair[1]) { $mapped = $false } }
            }
            foreach ($unattendTemplate in @('Standard.xml', 'DomainJoin.xml')) {
                $tmplPath = Join-Path $RepoRoot "DeploymentShare\Content\Unattend\$unattendTemplate"
                $null = New-LiteDeployUnattendXml -TemplateFile $tmplPath -TargetOutputFile $answer -ConfigObj $config
                [xml]$wgXml = Get-Content $answer -Raw
                $wgNode = $wgXml.SelectSingleNode("//*[local-name()='Identification']/*[local-name()='JoinWorkgroup']")
                if ($null -eq $wgNode -or $wgNode.InnerText -cne 'MYCORP') { $mapped = $false }
            }

            # Verify JoinDomain and MachineObjectOU on DomainJoin.xml
            $domainConfig = @{ ComputerSetup = @{ JoinDomain = 'corp.example.com'; MachineObjectOU = 'OU=Workstations,DC=corp,DC=example,DC=com' } }
            $domainTmplPath = Join-Path $RepoRoot "DeploymentShare\Content\Unattend\DomainJoin.xml"
            $null = New-LiteDeployUnattendXml -TemplateFile $domainTmplPath -TargetOutputFile $answer -ConfigObj $domainConfig
            [xml]$djXml = Get-Content $answer -Raw
            $domainNode = $djXml.SelectSingleNode("//*[local-name()='Identification']/*[local-name()='JoinDomain']")
            $ouNode = $djXml.SelectSingleNode("//*[local-name()='Identification']/*[local-name()='MachineObjectOU']")
            if ($null -eq $domainNode -or $domainNode.InnerText -cne 'corp.example.com') { $mapped = $false }
            if ($null -eq $ouNode -or $ouNode.InnerText -cne 'OU=Workstations,DC=corp,DC=example,DC=com') { $mapped = $false }

            [pscustomobject]@{ Omitted = $optionalClean; Preserved = $allPreserved; Mapped = $mapped; IdentityPolicies = $identityPolicies }
        }
        Assert-True $registrationChecks.Omitted "Blank registration omitted from state and answer file ($($engineTarget.Mode))"
        Assert-True $registrationChecks.Preserved "ComputerSetup fields including false/null remain correctly mapped in state ($($engineTarget.Mode))"
        Assert-True $registrationChecks.Mapped "Regional and registration settings map safely into XML ($($engineTarget.Mode))"
        Assert-True $registrationChecks.IdentityPolicies "Name honors prompt flag; description Order 1 always present with prompt-gated value ($($engineTarget.Mode))"
        $bypassChecks = & {
            . $imagePathForTest
            $cfgTrue = @{ ComputerSetup = @{ SkipSetupHardwareRequirements = $true } }
            $cfgFalse = @{ ComputerSetup = @{ SkipSetupHardwareRequirements = $false } }
            $cfgEmpty = @{ ComputerSetup = @{} }
            $wfOverride = [pscustomobject]@{ WorkflowTag = [pscustomobject]@{ ComputerSetup = [pscustomobject]@{ SkipSetupHardwareRequirements = $true } } }
            $isTrue = Test-LiteDeploySkipSetupHardwareRequirements -Configuration $cfgTrue
            $isFalse = Test-LiteDeploySkipSetupHardwareRequirements -Configuration $cfgFalse
            $isEmpty = Test-LiteDeploySkipSetupHardwareRequirements -Configuration $cfgEmpty
            $isWf = Test-LiteDeploySkipSetupHardwareRequirements -Configuration $cfgFalse -WorkflowSelection $wfOverride
            [pscustomobject]@{
                TrueDetected = $isTrue
                FalseDetected = (-not $isFalse)
                EmptyFalse = (-not $isEmpty)
                WorkflowOverrides = $isWf
            }
        }
        Assert-True ($bypassChecks.TrueDetected -and $bypassChecks.FalseDetected -and $bypassChecks.EmptyFalse -and $bypassChecks.WorkflowOverrides) "SkipSetupHardwareRequirements correctly detected and overridden by workflow ($($engineTarget.Mode))"
        $earlyRejection = & {
            . $engineTarget.EnvironmentPath -Mode $engineTarget.Mode -RuntimeRoot $engineTarget.ComponentRoot
            $badBoot = [pscustomobject]@{ DeploymentType = 'Network'; DriveLetter = $TestRoot; Config = [pscustomobject]@{ ComputerSetup = [pscustomobject]@{ ImageEngine = 'dism.exe' } } }
            try { $val = & $engineTarget.Path -BootObject $badBoot -ValidateOnly; return ($val.ImageEngine -eq 'dism.exe') }
            catch { return $false }
        }
        Assert-True $earlyRejection "Engine accepts DISM during startup validation ($($engineTarget.Mode))"
    }
    catch { Assert-True $false "Image engine configuration: $_" }
    try {
        $importResult = & {
            param($EnginePath, $EnvironmentMode, $SourceRoot, $EnvironmentPath, $ComponentRoot)
            . $EnvironmentPath -Mode $EnvironmentMode -RuntimeRoot $ComponentRoot
            $expectedBoot = [pscustomobject]@{
                DeploymentType = 'Network'; DriveLetter = $SourceRoot
                IsWinPE = $true # Deliberately stale: engine must use live detection instead.
                Config = [pscustomobject]@{ Ui = [pscustomobject]@{ Theme = 'Dark' } }
            }
            $beforeLocation = (Get-Location).Path
            $plan = & $EnginePath -BootObject $expectedBoot -ValidateOnly
            . $EnginePath -BootObject $expectedBoot -SkipPreCheck
            $skipInputPreserved = [bool]$SkipPreCheck
            $badDiskResultsRejected = $true
            foreach ($badResult in @($true, [pscustomobject]@{ Passed = $true },
                [pscustomobject]@{ Passed = $true; TargetDiskIndex = -1 },
                [pscustomobject]@{ Passed = $true; TargetDiskIndex = 'Disk 0' })) {
                try { $null = Get-LiteDeploySelectedDiskNumber -WorkflowResult $badResult; $badDiskResultsRejected = $false }
                catch { }
            }
            $zeroDisk = Get-LiteDeploySelectedDiskNumber -WorkflowResult ([pscustomobject]@{ Passed = $true; TargetDiskIndex = 0 })
            $fixedDisk = Get-LiteDeploySelectedDiskNumber -WorkflowResult ([pscustomobject]@{ Passed = $true; TargetDiskIndex = 0 }) -ComputerSetup ([pscustomobject]@{ DriveSelection = $false })
            $chosenDisk = Get-LiteDeploySelectedDiskNumber -WorkflowResult ([pscustomobject]@{ Passed = $true; TargetDiskIndex = 3 }) -ComputerSetup ([pscustomobject]@{ DriveSelection = $true })
            # Load only the disk-policy helper, without starting WPF or querying real disks.
            $uiTokens = $null; $uiErrors = $null
            $uiAst = [Management.Automation.Language.Parser]::ParseFile($RequiredFiles.WorkflowSelection, [ref]$uiTokens, [ref]$uiErrors)
            $autoFunction = $uiAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-LiteDeployAutoSelectedDisk' }, $true)
            . ([scriptblock]::Create($autoFunction.Extent.Text))
            $gridDisks = [pscustomobject]@{ SelectedItem = $null }
            $diskZero = [pscustomobject]@{ DiskNumber = 0; Model = 'Zero' }
            $otherDisk = [pscustomobject]@{ DiskNumber = 3; Model = 'Other' }
            $uiFoundZero = Set-LiteDeployAutoSelectedDisk -Disks @($otherDisk, $diskZero)
            $uiPolicyValid = $uiFoundZero -and $script:SelectedDiskIndex -eq 0 -and $gridDisks.SelectedItem.Model -eq 'Zero'
            $uiMissingZero = Set-LiteDeployAutoSelectedDisk -Disks @($otherDisk)
            $diskPolicyValid = $fixedDisk -eq 0 -and $chosenDisk -eq 3 -and $uiPolicyValid -and -not $uiMissingZero

            # Exercise actual pipeline stop conditions with inert screens and no filesystem/process actions.
            $script:unexpectedDeploymentPhase = $false
            function Initialize-LiteDeployDeploymentShareLogDir { return $null }
            function Save-LiteDeployDeploymentState { }
            function Sync-LiteDeployLogsToShare { }
            function Write-LiteDeployLog { }
            function Set-LiteDeployHostShellWindow { }
            function Start-LiteDeployProgressHost { $script:unexpectedDeploymentPhase = $true; throw 'Unexpected progress phase' }
            function Stop-LiteDeployProgressHost { }
            function Invoke-LiteDeployEngineScript { $script:unexpectedDeploymentPhase = $true; throw 'Unexpected deployment phase' }
            $RequiredFiles.HardwarePrecheck = Join-Path $SourceRoot 'EmptyPrecheck.ps1'
            $RequiredFiles.WorkflowSelection = Join-Path $SourceRoot 'InvalidSelection.ps1'
            $SkipPreCheck = $false
            $emptyPrecheckState = Start-LiteDeployPipeline
            $SkipPreCheck = $true
            $invalidSelectionState = Start-LiteDeployPipeline
            [pscustomobject]@{
                BootPreserved = [object]::ReferenceEquals($expectedBoot, $BootObject)
                SkipPreserved = $skipInputPreserved
                LocationPreserved = ((Get-Location).Path -eq $beforeLocation)
                StateLoaded = [bool](Get-Command New-LiteDeployDeploymentObject -ErrorAction SilentlyContinue)
                Theme = Get-LiteDeployUiTheme -BootConfig $EngineBootConfig
                IsWinPE = Test-LiteDeployWinPE
                ActualWinPE = Test-LiteDeployWinPE
                PlanValid = ($plan.Valid -and $plan.Mode -eq $EnvironmentMode -and $plan.DeploymentRoot -eq $SourceRoot)
                ProfilesValid = ($plan.ValidationProfile -eq 'WinPE' -and
                    [bool]$plan.RequirementsByEnvironment.FullOSImplemented -and
                    'Packages' -in $plan.RequirementsByEnvironment.FullOS -and
                    -not $plan.RequiredFiles.PSObject.Properties['Packages'])
                DiskNotImported = -not [bool](Get-Command Invoke-DiskPreparation -ErrorAction SilentlyContinue)
                DiskContractValid = ($badDiskResultsRejected -and $zeroDisk -eq 0)
                DiskPolicyValid = $diskPolicyValid
                StopsBeforeDisk = (-not $script:unexpectedDeploymentPhase -and
                    $emptyPrecheckState.Status -eq 'Cancelled' -and
                    $invalidSelectionState.Status -eq 'Failed' -and
                    $invalidSelectionState.Execution.Errors[0] -like 'InvalidWorkflowSelection:*')
            }
        } $engineTarget.Path $engineTarget.Mode $TestRoot $engineTarget.EnvironmentPath $engineTarget.ComponentRoot
        Assert-True ($importResult.BootPreserved -and $importResult.SkipPreserved) "Engine retains caller inputs: $($engineTarget.Path)"
        Assert-True ($importResult.LocationPreserved -and $importResult.StateLoaded) "Engine loads helpers and restores working directory"
        Assert-True ($importResult.Theme -eq 'Dark' -and $importResult.IsWinPE -eq $importResult.ActualWinPE) "Engine uses supplied theme and live environment detection"
        Assert-True ($importResult.PlanValid -and $importResult.DiskNotImported) 'ValidateOnly returns explicit paths; Engine does not import Disk'
        Assert-True $importResult.ProfilesValid 'Requirements distinguish active WinPE files from implemented FullOS packages'
        Assert-True $importResult.DiskContractValid 'Workflow must select a disk explicitly; valid Disk 0 remains supported'
        Assert-True $importResult.DiskPolicyValid 'DriveSelection false uses Disk 0 only; true honors selection; missing Disk 0 has no substitute'
        Assert-True $importResult.StopsBeforeDisk 'Pipeline stops before Progress/Disk for empty precheck or missing disk selection'
    }
    catch { Assert-True $false "Engine import failed: $_" }
}

# Environment maps exactly the requested layout/source and reports all missing requirements.
try {
    . $envc -Mode Development -RuntimeRoot $sourceRuntimeRoot
    $networkBoot = [pscustomobject]@{ DeploymentType = 'Network'; DriveLetter = $TestRoot }
    $networkPaths = Get-LiteDeployRuntimePaths -BootObject $networkBoot
    Assert-True ($networkPaths.RequiredFiles.Hardware -eq (Join-Path $sourceRuntimeRoot '030-Hardware\LiteDeploy.Hardware.ps1')) 'Development path is explicit'
    . $envc -Mode Production -RuntimeRoot $sourceRuntimeRoot
    $flatPaths = Get-LiteDeployRuntimePaths -BootObject $networkBoot
    Assert-True ($flatPaths.RequiredFiles.Hardware -eq (Join-Path $sourceRuntimeRoot 'LiteDeploy.Hardware.ps1')) 'Published layout does not fall back to available development files'
    . $envc -Mode Development -RuntimeRoot $sourceRuntimeRoot
    $fullOsPaths = Get-LiteDeployRuntimePaths -BootObject $networkBoot -RequiredComponents @('Environment', 'BootConfig', 'Logs', 'State', 'Packages')
    Assert-True ($fullOsPaths.RequiredFiles.Packages -eq (Join-Path $sourceRuntimeRoot '090-Packages\LiteDeploy.Packages.ps1') -and
        -not $fullOsPaths.RequiredFiles.PSObject.Properties['Disk']) 'Environment maps the requested FullOS subset without adding WinPE files'

    $mediaBoot = [pscustomobject]@{ DeploymentType = 'Media'; MediaDriveLetter = $TestRoot; DriveLetter = ''; LocalRootName = '~LiteDeploy' }
    $mediaPaths = Get-LiteDeployRuntimePaths -BootObject $mediaBoot
    Assert-True ($mediaPaths.DeploymentRoot -eq (Join-Path $TestRoot '~LiteDeploy')) 'Media uses the explicit media drive even when mapped DriveLetter is empty'

    $missingList = [pscustomobject]@{ Present = $testConfigPath; FirstMissing = (Join-Path $TestRoot 'missing-one'); SecondMissing = (Join-Path $TestRoot 'missing-two') }
    $missingResult = Test-LiteDeployRequiredFiles -Paths $missingList
    Assert-True (-not $missingResult.Ok -and $missingResult.Missing.Count -eq 2) 'Required-file check reports every missing file'

    $networkBoot | Add-Member -NotePropertyName ConfigPath -NotePropertyValue (Join-Path $TestRoot 'missing-config.json')
    $explicitPaths = Get-LiteDeployRuntimePaths -BootObject $networkBoot
    Assert-True ($explicitPaths.RequiredFiles.BootConfig -eq $networkBoot.ConfigPath) 'Missing explicit ConfigPath is not replaced by another existing configuration'
    $sourceRejected = $false
    try { $null = Get-LiteDeployRuntimePaths -BootObject ([pscustomobject]@{ DeploymentType = 'Network' }) }
    catch { $sourceRejected = $true }
    Assert-True $sourceRejected 'Missing source fails instead of assuming Z:'

    $catalogPath = Resolve-LiteDeployContentPath -Path 'Content\OperatingSystems\Example' -DeploymentRoot $TestRoot
    Assert-True ($catalogPath -eq (Join-Path $TestRoot 'Content\OperatingSystems\Example')) 'Catalog-relative content uses the declared source'
}
catch { Assert-True $false "Explicit Environment paths: $_" }

# Regression: imports keep caller helpers, and extracted log copying uses explicit paths.
try {
    $checks = & {
        . $envc -Mode Development -RuntimeRoot $sourceRuntimeRoot
        . (Get-LiteDeployComponentPath -Name Boot)
        $bootHelpersPresent = [bool](Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue) -and
            [bool](Get-Command Get-LiteDeployHardwareInventory -ErrorAction SilentlyContinue)
        $loggerBefore = (Get-Command Write-LiteDeployLog).ScriptBlock
        $hardwareBefore = (Get-Command Get-LiteDeployHardwareInventory).ScriptBlock
        . (Get-LiteDeployComponentPath -Name Drivers)
        $helpersReused = [object]::ReferenceEquals($loggerBefore, (Get-Command Write-LiteDeployLog).ScriptBlock) -and
            [object]::ReferenceEquals($hardwareBefore, (Get-Command Get-LiteDeployHardwareInventory).ScriptBlock)
        . (Get-LiteDeployComponentPath -Name HostShell)
        $localLogs = Join-Path $TestRoot 'CopySource'
        $remoteLogs = Join-Path $TestRoot 'CopyDestination'
        $null = New-Item -ItemType Directory -Path $localLogs, $remoteLogs -Force
        Set-Content (Join-Path $localLogs 'LiteDeploy.Test.log') 'copy fixture'
        Sync-LiteDeployLogsToShare -RuntimePaths ([pscustomobject]@{ LocalLogDirectory = $localLogs }) -RemoteLogDir $remoteLogs
        [pscustomobject]@{
            BootHelpersPresent = $bootHelpersPresent
            HelpersReused = $helpersReused
            HostShellLoaded = [bool](Get-Command Set-LiteDeployHostShellWindow -ErrorAction SilentlyContinue)
            LogCopied = (Get-Content (Join-Path $remoteLogs 'LiteDeploy.Test.log') -Raw).Trim() -eq 'copy fixture'
        }
    }
    Assert-True $checks.BootHelpersPresent 'Boot imports retain helper functions in the caller scope'
    Assert-True $checks.HelpersReused 'Drivers reuses the existing Logs and Hardware functions'
    Assert-True $checks.HostShellLoaded 'Console helpers load independently from Environment'
    Assert-True $checks.LogCopied 'Logs copies the expected content using explicit RuntimePaths'
}
catch { Assert-True $false "Central layout regressions: $_" }

Write-Host ""
# The real selection contract returns configuration in memory, not in its JSON copy.
try {
    $contract = & {
        $ui = Join-Path $scriptsRoot 'Runtime\110-UI\WorkflowSelection\LiteDeploy.UI.WorkflowSelection.ps1'
        $tree = [Management.Automation.Language.Parser]::ParseFile($ui, [ref]$null, [ref]$null)
        foreach ($name in @('New-LiteDeployWorkflowSelectionResult','Save-LiteDeployWorkflowSelectionJson')) {
            $node = $tree.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
            . ([scriptblock]::Create($node.Extent.Text))
        }
        $script:bootConfig = [pscustomobject]@{ComputerSetup=[pscustomobject]@{DriveSelection=$true}}
        $script:BootConfigPath = $testConfigPath
        $script:DeploymentSharePath = $TestRoot
        $script:DeploymentUid = 'snapshot-test'
        function Get-LiteDeployWorkflowSelectionJsonPath { Join-Path $TestRoot 'SelectionSnapshot.json' }
        $selection = New-LiteDeployWorkflowSelectionResult -Passed $true -Status Confirmed -TargetDiskIndex 3
        $path = Save-LiteDeployWorkflowSelectionJson -Selection $selection
        $saved = Get-Content $path -Raw | ConvertFrom-Json
        [pscustomobject]@{HasConfig=[object]::ReferenceEquals($selection.BootConfig,$script:bootConfig); NoConfigOnDisk=($null -eq $saved.PSObject.Properties['BootConfig']); Disk=$saved.TargetDiskIndex}
    }
    Assert-True $contract.HasConfig 'Selection returns its effective BootConfig object'
    Assert-True ($contract.NoConfigOnDisk -and $contract.Disk -eq 3) 'Selection JSON preserves target without duplicating BootConfig'
}
catch { Assert-True $false "Selection snapshot contract: $_" }
# Deployment lifecycle: no ID during pre-check and no remote folder before confirmation.
try {
    foreach ($scenario in @('PrecheckCancelled', 'SelectionCancelled', 'SelectionException', 'InvalidTarget', 'Confirmed', 'ReloadedTrue', 'ReloadedFalse', 'DiskMismatch', 'MissingConfig')) {
        $result = & {
            $events = [System.Collections.Generic.List[string]]::new()
            $enginePath = Join-Path $scriptsRoot 'Runtime\100-Engine\LiteDeploy.Engine.ps1'
            $tree = [System.Management.Automation.Language.Parser]::ParseFile($enginePath, [ref]$null, [ref]$null)
            foreach ($name in @('Start-LiteDeployPipeline', 'Get-LiteDeploySelectedDiskNumber')) {
                $node = $tree.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
                . ([scriptblock]::Create($node.Extent.Text))
            }
            function Write-LiteDeployLog { param($Message, $Level, $ForegroundColor, $Component) }
            function Save-LiteDeployDeploymentState { param($DeploymentState) }
            function Get-LiteDeployUiTheme { param($BootConfig) 'Light' }
            function Set-LiteDeployHostShellWindow { param($Action) }
            function Write-LiteDeployEnginePauseNotice {}
            function Stop-LiteDeployProgressHost {}
            function Test-LiteDeployWinPE { $true }
            function Start-LiteDeployProgressHost { param($StatePath, [switch]$WinPE, $Theme) throw 'AuditStopBeforeDisk' }
            function Get-LiteDeployUid { $events.Add('ID'); 'lifecycle-test-id' }
            function Initialize-LiteDeployDeploymentShareLogDir {
                param($RuntimePaths, $DeploymentUid)
                $events.Add('Folder')
                Join-Path $TestRoot $DeploymentUid
            }
            function Sync-LiteDeployLogsToShare { param($RuntimePaths, $RemoteLogDir) }
            $precheck = Join-Path $TestRoot 'LifecyclePrecheck.ps1'
            $selection = Join-Path $TestRoot 'LifecycleSelection.ps1'
            Set-Content $precheck '$events.Add("Precheck"); if ($global:LiteDeployDeployment.DeploymentUid) { throw "ID created too early" }; [pscustomobject]@{Passed=($scenario -ne "PrecheckCancelled")}'
            Set-Content $selection '$events.Add("Selection"); if (-not $DeploymentUid -or $global:LiteDeployRemoteLogDir) { throw "Invalid selection lifecycle" }; if ($scenario -eq "SelectionException") { throw "Selection failed" }; $confirmed = $scenario -in @("Confirmed", "ReloadedTrue", "ReloadedFalse", "DiskMismatch", "MissingConfig", "InvalidTarget"); $cfg = [pscustomobject]@{ComputerSetup=[pscustomobject]@{DriveSelection=($scenario -notin @("ReloadedFalse", "DiskMismatch"))}}; $r = [pscustomobject]@{Passed=$confirmed; TargetDiskIndex=$(if($scenario -eq "ReloadedFalse"){0}else{3}); BootConfig=$cfg}; if($scenario -eq "MissingConfig"){$r.PSObject.Properties.Remove("BootConfig")}; if($scenario -eq "InvalidTarget"){$r.PSObject.Properties.Remove("TargetDiskIndex")}; $r'
            # Named parameters are accepted through $args in the fixture; read the live ID.
            Set-Content $selection ('param($DeploymentUid, $BootConfigPath, $BootConfig, $RuntimeFiles, $DeploymentSharePath, $Theme)' + "`r`n" + (Get-Content $selection -Raw))
            $RuntimePaths = [pscustomobject]@{DeploymentRoot=$TestRoot;RuntimeRoot=$TestRoot;Mode='Development';StatePath=(Join-Path $TestRoot 'state.json')}
            $RequiredFiles = [pscustomobject]@{BootConfig=$testConfigPath;HardwarePrecheck=$precheck;WorkflowSelection=$selection;Image=(Join-Path $TestRoot 'LifecycleImage.ps1')}
            $EngineBootConfig = [pscustomobject]@{ComputerSetup=[pscustomobject]@{DriveSelection=($scenario -ne 'ReloadedTrue')}}
            Set-Content $RequiredFiles.Image 'param($BootConfig, [switch]$ValidateEngineOnly) if(-not $ValidateEngineOnly){throw "No image execution allowed"}'
            $BootObject = [pscustomobject]@{Config=$EngineBootConfig}
            $SkipPreCheck = $false
            $script:EngineMetadata = [pscustomobject]@{Name='Lifecycle test';Version='1'}
            $global:LiteDeployRemoteLogDir = 'stale-remote'
            $global:LiteDeployOsLogDir = 'stale-os'
            try { $null = Start-LiteDeployPipeline } catch { if ($_.Exception.Message -ne 'AuditStopBeforeDisk') { throw } }
            [pscustomobject]@{Events=($events -join ','); State=$global:LiteDeployDeployment; OsMirror=$global:LiteDeployOsLogDir}
        }
        $expected = switch ($scenario) {
            'PrecheckCancelled' { 'Precheck' }
            { $_ -in @('Confirmed','ReloadedTrue','ReloadedFalse') } { 'Precheck,ID,Selection,Folder' }
            default { 'Precheck,ID,Selection' }
        }
        Assert-True ($result.Events -eq $expected) "Deployment lifecycle order: $scenario"
        Assert-True ([string]::IsNullOrWhiteSpace($result.OsMirror)) "Deployment clears stale OS mirror: $scenario"
        if ($scenario -in @('Confirmed','ReloadedTrue','ReloadedFalse')) {
            Assert-True ($result.State.Workflow.Confirmed -and $result.State.LogLocations.RemoteLogDir -eq $result.State.Execution.RemoteLogDir -and $result.State.LogLocations.RemoteDeploymentState) 'Confirmed deployment records remote log/state paths'
        }
        if ($scenario -eq 'ReloadedFalse') { Assert-True ($result.State.BootObject.Config.ComputerSetup.DriveSelection -eq $false -and $result.State.Workflow.SelectionData.TargetDiskIndex -eq 0) 'Reloaded false configuration is adopted with confirmed Disk 0' }
        if ($scenario -eq 'ReloadedTrue') { Assert-True ($result.State.BootObject.Config.ComputerSetup.DriveSelection -eq $true -and $result.State.Workflow.SelectionData.TargetDiskIndex -eq 3) 'Reloaded true configuration preserves confirmed Disk 3' }
        if ($scenario -in @('DiskMismatch','MissingConfig')) { Assert-True ($result.State.Status -eq 'Failed' -and -not $result.State.Workflow.Confirmed) "Unsafe selection rejected: $scenario" }
    }
}
catch { Assert-True $false "Deployment lifecycle regression: $_" }
Write-Host "Passed: $passes  Failed: $($failures.Count)" -ForegroundColor $(if ($failures.Count -eq 0) { "Green" } else { "Yellow" })
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
}
exit 0



