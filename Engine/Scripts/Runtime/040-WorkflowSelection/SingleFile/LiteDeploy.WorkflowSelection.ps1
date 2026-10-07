<#
.SYNOPSIS
    LiteDeploy Workflow Selection wizard (PreCheck chrome) — SingleFile reference.

.NOTES
    Inlined-XAML variant (logic + UI in one .ps1). Production uses split
    LiteDeploy.WorkflowSelection.ps1 + LiteDeploy.WorkflowSelection.UI.xaml.
    Engine passes:
      -BootConfigPath        path to BootConfig.json (mandatory)
      -BootConfig            optional in-memory object (first paint only; F5 reloads from path)
      -DeploymentSharePath   share/media root ($root) - aliases: Root, DeploymentRoot
      -DeploymentUid         optional session ID from Engine (footer display)
    On confirm: writes X:\WorkflowSelection.json AND returns a selection object (Passed=$true).
    On cancel/fail: returns Passed=$false (no JSON written).
    Keep this file in sync with production logic and .UI.xaml (and SingleFile DriverPicker pair).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$BootConfigPath = "",

    # Optional cache from Engine. Path remains mandatory for STA/F5/audit.
    [psobject]$BootConfig = $null,

    [Parameter(Mandatory = $false)]
    [Alias("Root", "DeploymentRoot")]
    [string]$DeploymentSharePath = "",

    # Optional: Engine session UID (e.g. 260930-A3F1) shown in the footer.
    [Alias("DeploymentId", "DeployUid")]
    [string]$DeploymentUid = "",

    [ValidateSet("Light", "Dark")]
    [string]$Theme = "Light",

    # Do NOT name this $Metadata - BootConfig has a Metadata object (case-insensitive clash).
    [Alias("Metadata")]
    [switch]$GetComponentMetadata
)

# ==============================================================================
# COMPONENT METADATA
# ==============================================================================

function Get-LiteDeployComponentMetadata {
    return [PSCustomObject]@{
        ComponentId          = "WorkflowSelection"
        Name                 = "LiteDeploy Workflow Selection"
        Version              = "1.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "WinPE"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("LogWriter", "Hardware", "DriverStaging", "DriverPicker")
        Description          = "BootConfigPath + DeploymentSharePath SingleFile wizard (inlined XAML); driver detect via DriverStaging; writes X:\WorkflowSelection.json and returns selection object."
    }
}

$script:ComponentMetadata = Get-LiteDeployComponentMetadata

if ($GetComponentMetadata) {
    $script:ComponentMetadata
    return
}

if ([string]::IsNullOrWhiteSpace($BootConfigPath)) {
    throw "LiteDeploy.WorkflowSelection.ps1 requires -BootConfigPath."
}
if ([string]::IsNullOrWhiteSpace($DeploymentSharePath)) {
    throw "LiteDeploy.WorkflowSelection.ps1 requires -DeploymentSharePath (Root / DeploymentRoot)."
}

# ------------------------------------------------------------------------------
# STA MODE & WPF ASSEMBLIES
# ------------------------------------------------------------------------------
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path $powershellExe)) { $powershellExe = "powershell.exe" }
    $relaunch = @(
        "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass",
        "-File", $PSCommandPath,
        "-BootConfigPath", $BootConfigPath,
        "-DeploymentSharePath", $DeploymentSharePath
    )
    if (-not [string]::IsNullOrWhiteSpace($DeploymentUid)) {
        $relaunch += @("-DeploymentUid", $DeploymentUid)
    }
    if ($GetComponentMetadata) { $relaunch += "-GetComponentMetadata" }
    if ($PSBoundParameters.ContainsKey("Theme")) { $relaunch += @("-Theme", $Theme) }
    & $powershellExe @relaunch
    return
}

try { [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly } catch {}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$script:WindowsFormsAlertsAvailable = $true

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# Flat Runtime layout: LogWriter + Hardware + DriverStaging beside this script after SyncComponents.
# SingleFile also resolves numbered sibling folders two levels up (040\SingleFile → Runtime\000-*).
$logWriterModule = Join-Path $PSScriptRoot "LiteDeploy.LogWriter.ps1"
if (-not (Test-Path -LiteralPath $logWriterModule -PathType Leaf)) {
    $logWriterModule = Join-Path $PSScriptRoot "..\000-LogWriter\LiteDeploy.LogWriter.ps1"
}
if (-not (Test-Path -LiteralPath $logWriterModule -PathType Leaf)) {
    $logWriterModule = Join-Path $PSScriptRoot "..\..\000-LogWriter\LiteDeploy.LogWriter.ps1"
}
if (-not (Test-Path -LiteralPath $logWriterModule -PathType Leaf)) {
    throw "LiteDeploy.LogWriter.ps1 was not found beside WorkflowSelection (flat Runtime) or under 000-LogWriter."
}
Import-Module -Name $logWriterModule -Force

# Always import Hardware for this process: skip-if-loaded can leave Get-Hardware*
# bound after PreCheck while $script:HardwareCache is unset (StrictMode throw).
$hardwareModule = Join-Path $PSScriptRoot "LiteDeploy.Hardware.ps1"
if (-not (Test-Path -LiteralPath $hardwareModule -PathType Leaf)) {
    $hardwareModule = Join-Path $PSScriptRoot "..\000-Hardware\LiteDeploy.Hardware.ps1"
}
if (-not (Test-Path -LiteralPath $hardwareModule -PathType Leaf)) {
    $hardwareModule = Join-Path $PSScriptRoot "..\..\000-Hardware\LiteDeploy.Hardware.ps1"
}
if (-not (Test-Path -LiteralPath $hardwareModule -PathType Leaf)) {
    throw "LiteDeploy.Hardware.ps1 was not found beside WorkflowSelection (flat Runtime) or under 000-Hardware."
}
Import-Module -Name $hardwareModule -Force

$driverStagingModule = Join-Path $PSScriptRoot "LiteDeploy.DriverStaging.ps1"
if (-not (Test-Path -LiteralPath $driverStagingModule -PathType Leaf)) {
    $driverStagingModule = Join-Path $PSScriptRoot "..\060-DriverStaging\LiteDeploy.DriverStaging.ps1"
}
if (-not (Test-Path -LiteralPath $driverStagingModule -PathType Leaf)) {
    $driverStagingModule = Join-Path $PSScriptRoot "..\..\060-DriverStaging\LiteDeploy.DriverStaging.ps1"
}
if (-not (Test-Path -LiteralPath $driverStagingModule -PathType Leaf)) {
    throw "LiteDeploy.DriverStaging.ps1 was not found beside WorkflowSelection (flat Runtime) or under 060-DriverStaging."
}
Import-Module -Name $driverStagingModule -Force
# Keep WorkflowSelection metadata on $script:ComponentMetadata (import may overwrite Get-LiteDeployComponentMetadata).

$script:BootConfigPath = $BootConfigPath
$script:DeploymentSharePath = $DeploymentSharePath.TrimEnd('\')
$script:DeploymentRoot = $script:DeploymentSharePath
$script:DeploymentUid = if ([string]::IsNullOrWhiteSpace($DeploymentUid)) { "" } else { $DeploymentUid.Trim() }
$script:PassedBootConfig = $BootConfig
$script:UsePassedBootConfigOnce = ($null -ne $BootConfig)

function Get-LiteDeployProperty {
    param(
        $InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-EffectiveBootConfig {
    param([switch]$ForceReload)

    if (-not $ForceReload -and $script:UsePassedBootConfigOnce -and $null -ne $script:PassedBootConfig) {
        $script:UsePassedBootConfigOnce = $false
        return $script:PassedBootConfig
    }

    if (-not (Test-Path -LiteralPath $script:BootConfigPath -PathType Leaf)) {
        throw "BootConfig.json was not found at '$($script:BootConfigPath)'."
    }

    return (Get-Content -LiteralPath $script:BootConfigPath -Raw -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop)
}

function Test-JSONFormat([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

    try {
        $null = (Get-Content -LiteralPath $Path -Raw) | ConvertFrom-Json -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Show-DeploymentWarning {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$Title = "Missing Deployment Information"
    )

    if ($script:WindowsFormsAlertsAvailable) {
        [System.Windows.Forms.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    [System.Windows.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning
    ) | Out-Null
}

function Show-DeploymentInformation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$Title = "Driver Pack Details"
    )

    if ($script:WindowsFormsAlertsAvailable) {
        [System.Windows.Forms.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

    [System.Windows.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    ) | Out-Null
}

function Format-DriverPackInfoValue {
    param([object]$Value)
    if ($null -eq $Value) { return "-" }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return "-" }
    return $text.Trim()
}

function Get-TruncatedPathLabel {
    param(
        [string]$Path,
        [int]$MaxLength = 64
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $text = $Path.Trim()
    if ($text.Length -le $MaxLength) { return $text }

    # Keep start + end (usually includes file/folder name) with "..." in the middle.
    $ellipsis = "..."
    $keepEnd = [Math]::Min(28, [Math]::Floor(($MaxLength - $ellipsis.Length) / 2))
    $keepStart = $MaxLength - $keepEnd - $ellipsis.Length
    if ($keepStart -lt 12) {
        $keepStart = 12
        $keepEnd = $MaxLength - $keepStart - $ellipsis.Length
    }
    if ($keepEnd -lt 8) { $keepEnd = 8 }

    return ($text.Substring(0, $keepStart) + $ellipsis + $text.Substring($text.Length - $keepEnd))
}

function Get-DetectedPackComboLabel {
    param($Detection)

    if (-not $Detection -or -not $Detection.IsDetected) { return "Detected pack" }

    $location = if ($Detection.PSObject.Properties["RelativePath"] -and $Detection.RelativePath) {
        [string]$Detection.RelativePath
    } elseif ($Detection.FullPath) {
        [string]$Detection.FullPath
    } else {
        ""
    }

    if ([string]::IsNullOrWhiteSpace($location)) { return "Detected pack" }

    # Custom packs are short (Content\Drivers\Custom\FolderName) - show full relative path.
    # OEM packs often have long vendor/model/.exe paths - truncate with "...".
    $isOem = ($Detection.PSObject.Properties["IsOem"] -and $Detection.IsOem)
    if (-not $isOem) {
        return ("Detected pack: {0}" -f $location.Trim())
    }

    return ("Detected pack: {0}" -f (Get-TruncatedPathLabel -Path $location -MaxLength 64))
}

function Test-OemDetectedPackSelected {
    param(
        $Detection,
        [string]$SelectedChoice
    )

    if (-not $Detection -or -not $Detection.IsDetected) { return $false }
    if (-not ($Detection.PSObject.Properties["IsOem"] -and $Detection.IsOem)) { return $false }
    if ([string]::IsNullOrWhiteSpace($SelectedChoice)) { return $false }
    return $SelectedChoice.StartsWith("Detected pack:")
}

function Update-DriverPackInfoButtonVisibility {
    if ($null -eq $btnDriverPackInfo) { return }

    $selected = if ($null -ne $cmbDriverPackPath -and $null -ne $cmbDriverPackPath.SelectedItem) {
        $cmbDriverPackPath.SelectedItem.ToString()
    } else { "" }

    if (Test-OemDetectedPackSelected -Detection $script:DetectionResult -SelectedChoice $selected) {
        $btnDriverPackInfo.Visibility = [System.Windows.Visibility]::Visible
    }
    else {
        $btnDriverPackInfo.Visibility = [System.Windows.Visibility]::Collapsed
    }
}

function Show-OemDriverPackInfoDialog {
    param($Detection)

    if (-not $Detection -or -not $Detection.IsDetected -or -not $Detection.IsOem) { return }

    $matchBy = Format-DriverPackInfoValue $Detection.MatchBy
    if ($Detection.PSObject.Properties["HardwareSku"] -and $Detection.HardwareSku -and ($matchBy -like "OEM:SKU*")) {
        $matchBy = "{0} ({1})" -f $matchBy, ([string]$Detection.HardwareSku).Trim()
    }

    $sourceKind = Format-DriverPackInfoValue $Detection.SourceKind
    if ($sourceKind -ieq "Archive") {
        $sourceKind = "Archive (vendor .exe)"
    }
    elseif ($sourceKind -ieq "Content") {
        $sourceKind = "Extracted content"
    }

    $sha = Format-DriverPackInfoValue $Detection.SHA256
    $path = Format-DriverPackInfoValue $(if ($Detection.FullPath) { $Detection.FullPath } else { $Detection.RelativePath })

    $lines = @(
        "Model:              $(Format-DriverPackInfoValue $Detection.PackModel)"
        "Matched by:         $matchBy"
        "Source:             $sourceKind"
        "File name:          $(Format-DriverPackInfoValue $Detection.FileName)"
        "SHA256:             $sha"
        "Release date:       $(Format-DriverPackInfoValue $Detection.ReleaseDate)"
        "Downloaded on:      $(Format-DriverPackInfoValue $Detection.DownloadedOn)"
        ""
        "Path:"
        $path
    )

    Show-DeploymentInformation -Message ($lines -join "`r`n") -Title "OEM Driver Pack Details"
}

function Get-LiteDeployWorkflowSelectionJsonPath {
    $sysDrive = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\') } else { "X:" }
    return (Join-Path $sysDrive "WorkflowSelection.json")
}

function Save-LiteDeployWorkflowSelectionJson {
    param(
        [Parameter(Mandatory = $true)]
        $Selection
    )

    $path = Get-LiteDeployWorkflowSelectionJsonPath
    $json = ($Selection | ConvertTo-Json -Depth 6)
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8 -Force
    return $path
}

function New-LiteDeployWorkflowSelectionResult {
    param(
        [bool]$Passed,
        [string]$Status,
        [string]$SelectionJsonPath = $null,
        [string]$ComputerName = $null,
        [string]$ComputerDescription = $null,
        [string]$WorkflowName = $null,
        [string]$WorkflowTag = $null,
        [object]$TargetDiskIndex = $null,
        [string]$TargetDiskModel = $null,
        [string]$DriverFolderPath = $null,
        [bool]$AutoDetectDrivers = $false
    )

    return [PSCustomObject]@{
        Passed              = [bool]$Passed
        Status              = $Status
        SelectionJsonPath   = $SelectionJsonPath
        BootConfigPath      = $script:BootConfigPath
        DeploymentSharePath = $script:DeploymentSharePath
        DeploymentUid       = $script:DeploymentUid
        ComputerName        = $ComputerName
        ComputerDescription = $ComputerDescription
        WorkflowName        = $WorkflowName
        WorkflowTag         = $WorkflowTag
        TargetDiskIndex     = $TargetDiskIndex
        TargetDiskModel     = $TargetDiskModel
        DriverFolderPath    = $DriverFolderPath
        AutoDetectDrivers   = [bool]$AutoDetectDrivers
    }
}

# Load the WPF-only folder picker used by the driver selection control.
$driverPathPickerScript = Join-Path $PSScriptRoot "LiteDeploy.WorkflowSelectionDriverPicker.ps1"
if (Test-Path -LiteralPath $driverPathPickerScript) {
    . $driverPathPickerScript
}

# Engine may pass optional -BootConfig for first paint; F5 always reloads from path.
$bootConfig = Get-EffectiveBootConfig
$script:bootConfig = $bootConfig

# Theme from BootConfig.Ui.Theme (same precedence as PreCheck): -Theme > Ui.Theme > Light.
# Palette is baked into XAML below.
if (-not $PSBoundParameters.ContainsKey("Theme")) {
    $uiTheme = Get-LiteDeployProperty (Get-LiteDeployProperty $bootConfig "Ui") "Theme"
    if ($uiTheme) {
        switch -Regex ([string]$uiTheme.Trim()) {
            '^(?i)light$' { $Theme = "Light" }
            '^(?i)dark$'  { $Theme = "Dark" }
        }
    }
}

$isDark = ($Theme -eq "Dark")
$bgColor = if ($isDark) { "#121212" } else { "#FFFFFF" }
$fgColor = if ($isDark) { "#F3F4F6" } else { "#111827" }
$secFgColor = if ($isDark) { "#9CA3AF" } else { "#4B5563" }
$mutedFgColor = if ($isDark) { "#9CA3AF" } else { "#687684" }
$labelFg = if ($isDark) { "#E5E7EB" } else { "#374151" }
$surfaceBg = if ($isDark) { "#1E1E1E" } else { "#F7F9FB" }
$footerBg = if ($isDark) { "#181818" } else { "#F7F9FB" }
$headerBg = if ($isDark) { "#2A2A2A" } else { "#F3F4F6" }
$headerFg = if ($isDark) { "#E5E7EB" } else { "#374151" }
$borderColor = if ($isDark) { "#333333" } else { "#D9E0E7" }
$diskBorderColor = if ($isDark) { "#333333" } else { "#CCCCCC" }
$buttonBg = if ($isDark) { "#2A2A2A" } else { "#FFFFFF" }
$buttonFg = if ($isDark) { "#F3F4F6" } else { "#1F2937" }
$buttonHoverBg = if ($isDark) { "#383838" } else { "#F3F4F6" }
$buttonPressedBg = if ($isDark) { "#404040" } else { "#E5E7EB" }
$headerColor = if ($isDark) { "#3B82F6" } else { "#005A9E" }
$primaryHoverBg = if ($isDark) { "#2563EB" } else { "#0078D4" }
$primaryPressedBg = if ($isDark) { "#1D4ED8" } else { "#004E8C" }
$disabledBg = if ($isDark) { "#262626" } else { "#F3F4F6" }
$disabledBorder = if ($isDark) { "#333333" } else { "#E5E7EB" }
$disabledFg = if ($isDark) { "#6B7280" } else { "#9CA3AF" }
$errorFg = if ($isDark) { "#F87171" } else { "#D13438" }
# Inputs sit inset on the card: darker fill + stronger border so they do not blend into surfaceBg.
$textBoxBg = if ($isDark) { "#141414" } else { "#FFFFFF" }
$textBoxFg = if ($isDark) { "#FFFFFF" } else { "#1A1A1A" }
$textBoxBorder = if ($isDark) { "#4B5563" } else { "#D9E0E7" }

# Adaptive window size (same approach as HardwarePreCheck; taller canvas for wizard body).
$screenWidth = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
$screenHeight = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height
$designWidth = 960
$designHeight = 760
$targetHeight = [Math]::Min(900, [Math]::Max(560, [int]($screenHeight * 0.78)))
$targetWidth = [int]($targetHeight * ($designWidth / $designHeight))
if ($targetWidth -gt [int]($screenWidth * 0.92)) {
    $targetWidth = [int]($screenWidth * 0.92)
    $targetHeight = [int]($targetWidth * ($designHeight / $designWidth))
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LiteDeploy Workflow Selection"
        WindowState="Normal"
        WindowStyle="SingleBorderWindow"
        ResizeMode="NoResize"
        Width="$targetWidth" Height="$targetHeight"
        WindowStartupLocation="CenterScreen"
        Background="$bgColor">
    
    <Window.Resources>
        <Style x:Key="ActionLinkStyle" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Foreground" Value="$headerColor"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Margin" Value="0,0,16,0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="PrimaryButtonStyle" TargetType="Button">
            <Setter Property="Background" Value="$headerColor"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="$headerColor"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="24,7"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="border" Property="Background" Value="$primaryHoverBg"/><Setter TargetName="border" Property="BorderBrush" Value="$primaryHoverBg"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="border" Property="Background" Value="$primaryPressedBg"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="border" Property="Background" Value="$disabledBg"/><Setter TargetName="border" Property="BorderBrush" Value="$disabledBorder"/><Setter Property="Foreground" Value="$disabledFg"/><Setter Property="Cursor" Value="No"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SecondaryButtonStyle" TargetType="Button">
            <Setter Property="Background" Value="$buttonBg"/>
            <Setter Property="Foreground" Value="$buttonFg"/>
            <Setter Property="BorderBrush" Value="$borderColor"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="11.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="16,6"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="border" Property="Background" Value="$buttonHoverBg"/><Setter TargetName="border" Property="BorderBrush" Value="$headerColor"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="border" Property="Background" Value="$buttonPressedBg"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Modern Clean Styled TextBox -->
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="$textBoxBg"/>
            <Setter Property="Foreground" Value="$textBoxFg"/>
            <Setter Property="BorderBrush" Value="$textBoxBorder"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CaretBrush" Value="$textBoxFg"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Padding" Value="8,4"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>

        <Style TargetType="CheckBox">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Foreground" Value="$labelFg"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
        </Style>

        <!-- Shared text style for disk grid cells (selected = white on blue) -->
        <Style x:Key="DiskCellTextStyle" TargetType="TextBlock">
            <Setter Property="Foreground" Value="$fgColor"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Style.Triggers>
                <DataTrigger Binding="{Binding RelativeSource={RelativeSource AncestorType=DataGridCell}, Path=IsSelected}" Value="True">
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                </DataTrigger>
            </Style.Triggers>
        </Style>

        <!-- Dark-capable ComboBox (closed chrome + dropdown) -->
        <Style TargetType="ComboBoxItem">
            <Setter Property="Background" Value="$textBoxBg"/>
            <Setter Property="Foreground" Value="$textBoxFg"/>
            <Setter Property="Padding" Value="8,4"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="$primaryHoverBg"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="$primaryHoverBg"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="$textBoxBg"/>
            <Setter Property="Foreground" Value="$textBoxFg"/>
            <Setter Property="BorderBrush" Value="$textBoxBorder"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,4"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Auto"/>
            <Setter Property="ScrollViewer.VerticalScrollBarVisibility" Value="Auto"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="ToggleButton" Focusable="False" ClickMode="Press"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                          Background="{TemplateBinding Background}"
                                          BorderBrush="{TemplateBinding BorderBrush}"
                                          BorderThickness="{TemplateBinding BorderThickness}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="2">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="22"/>
                                                </Grid.ColumnDefinitions>
                                                <Path Grid.Column="1" HorizontalAlignment="Center" VerticalAlignment="Center"
                                                      Data="M0,0 L4,4 L8,0 Z" Fill="$textBoxFg"/>
                                            </Grid>
                                        </Border>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter Margin="8,4,26,4" VerticalAlignment="Center" HorizontalAlignment="Left"
                                              IsHitTestVisible="False"
                                              Content="{TemplateBinding SelectionBoxItem}"
                                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                              ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"/>
                            <Popup Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                                <Border MinWidth="{TemplateBinding ActualWidth}" MaxHeight="{TemplateBinding MaxDropDownHeight}"
                                        Background="$textBoxBg" BorderBrush="$textBoxBorder" BorderThickness="1">
                                    <ScrollViewer Margin="0" SnapsToDevicePixels="True">
                                        <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Workflow / Parent Header Template -->
        <DataTemplate x:Key="WorkflowHeaderTemplate">
            <StackPanel Orientation="Horizontal" Margin="0,2">
                <Path Width="18" Height="18" Stretch="Uniform" Fill="$headerColor" Margin="0,0,8,0"
                      Data="M19,13H13V19H19V13M11,13H5V19H11V13M19,5H13V11H19V5M11,5H5V11H11V5M3,3H21V21H3V3Z"/>
                <TextBlock Text="{Binding HeaderText}" FontWeight="Bold" FontSize="13" Foreground="$headerColor" VerticalAlignment="Center"/>
            </StackPanel>
        </DataTemplate>

        <!-- OS Item Template -->
        <DataTemplate x:Key="OSItemTemplate">
            <Grid Margin="0,2">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto" SharedSizeGroup="OSNameGroup"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <Path x:Name="ItemIcon" Grid.Column="0" Width="16" Height="16" Stretch="Uniform" Fill="$headerColor" Margin="0,0,10,0" VerticalAlignment="Center"
                      Data="M6,2H18A2,2 0 0,1 20,4V20A2,2 0 0,1 18,22H6A2,2 0 0,1 4,20V4A2,2 0 0,1 6,2M6,4V8H18V4H6M6,20H18V10H6V20M16,15A1,1 0 0,0 15,14A1,1 0 0,0 14,15A1,1 0 0,0 16,15Z"/>

                <TextBlock x:Name="ItemName" Grid.Column="1" Text="{Binding Name}" FontSize="13" Foreground="$buttonFg" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,30,0"/>

                <TextBlock x:Name="ItemDate" Grid.Column="3" Text="{Binding DateText}" FontSize="12" Foreground="$mutedFgColor" VerticalAlignment="Center" Margin="0,0,16,0"/>
            </Grid>

            <DataTemplate.Triggers>
                <DataTrigger Binding="{Binding RelativeSource={RelativeSource AncestorType=TreeViewItem}, Path=IsSelected}" Value="True">
                    <Setter TargetName="ItemName" Property="Foreground" Value="#FFFFFF"/>
                    <Setter TargetName="ItemDate" Property="Foreground" Value="#E0E0E0"/>
                    <Setter TargetName="ItemIcon" Property="Fill" Value="#FFFFFF"/>
                </DataTrigger>
            </DataTemplate.Triggers>
        </DataTemplate>

        <!-- Custom TreeViewItem Style -->
        <Style TargetType="TreeViewItem">
            <Setter Property="Padding" Value="4,2"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Style.Resources>
                <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="$primaryHoverBg" />
                <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#FFFFFF" />
                <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightBrushKey}" Color="$primaryHoverBg" />
                <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightTextBrushKey}" Color="#FFFFFF" />
            </Style.Resources>
        </Style>

        <Style x:Key="HeaderNodeStyle" TargetType="TreeViewItem" BasedOn="{StaticResource {x:Type TreeViewItem}}">
            <Setter Property="IsExpanded" Value="False"/>
            <Setter Property="HeaderTemplate" Value="{StaticResource WorkflowHeaderTemplate}"/>
        </Style>

        <Style x:Key="ChildNodeStyle" TargetType="TreeViewItem" BasedOn="{StaticResource {x:Type TreeViewItem}}">
            <Setter Property="HeaderTemplate" Value="{StaticResource OSItemTemplate}"/>
        </Style>
    </Window.Resources>

    <Viewbox Stretch="Fill">
        <Border Width="$designWidth" Height="$designHeight" Padding="0">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="78"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="60"/>
                </Grid.RowDefinitions>

                <!-- PreCheck-style header -->
                <Border Grid.Row="0" Background="#005A9E" Padding="25,10">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="50"/>
                            <ColumnDefinition Width="*" MinWidth="140"/>
                            <ColumnDefinition Width="*" MinWidth="160"/>
                        </Grid.ColumnDefinitions>
                        <Border Grid.Column="0" Background="#28FFFFFF" CornerRadius="4" Width="40" Height="40">
                            <TextBlock Text="LD" Foreground="White" FontWeight="Bold" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="12,0,12,0">
                            <!-- Filled at runtime from BootConfig.Metadata (Name / Environment / Version) -->
                            <TextBlock Name="TxtBrand" Text="" Foreground="White" FontSize="18" FontWeight="Bold" TextTrimming="CharacterEllipsis"/>
                            <TextBlock Name="TxtSubtitle" Text="" Foreground="#D9EFFF" FontSize="12" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                        <StackPanel Grid.Column="2" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="8,0,0,0">
                            <TextBlock Name="TxtDeviceIdentity" Text="Device information: detecting..." Foreground="White" FontSize="14" FontWeight="SemiBold"
                                       TextAlignment="Right" TextTrimming="CharacterEllipsis"/>
                            <TextBlock Name="TxtDeviceSerial" Text="" Foreground="#D9EFFF" FontSize="12"
                                       TextAlignment="Right" TextTrimming="CharacterEllipsis" Visibility="Collapsed"/>
                        </StackPanel>
                    </Grid>
                </Border>

                <!-- Main body (clip + scroll so Drivers never paint over the footer) -->
                <Grid Grid.Row="1" Margin="28,10,28,6" ClipToBounds="True">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                                  CanContentScroll="False" Focusable="False">
                    <StackPanel Name="MainSetupPanel" VerticalAlignment="Top" HorizontalAlignment="Stretch">

                        <!-- SECTION 1: Computer Identification + firmware snapshot -->
                        <TextBlock Name="HeaderComputerID" Text="Computer Identification" FontSize="13" FontWeight="SemiBold" Foreground="$headerColor" Margin="0,2,0,4" FontFamily="Segoe UI"/>

                        <Border Name="CardComputerID" Background="$surfaceBg" BorderBrush="$borderColor" BorderThickness="1" CornerRadius="5" Padding="12,10" Margin="0,0,0,8" HorizontalAlignment="Stretch">
                            <Grid Name="GridComputerIdLayout" HorizontalAlignment="Stretch">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Name="ColComputerInputs" Width="*" MinWidth="220"/>
                                    <ColumnDefinition Name="ColComputerSpacer" Width="12"/>
                                    <ColumnDefinition Name="ColFirmware" Width="Auto" MinWidth="240"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Grid.Column="0" Name="ContainerComputerID" HorizontalAlignment="Stretch" VerticalAlignment="Top">
                                    <Grid Name="RowComputerName" Margin="0,0,0,8" Visibility="Collapsed" HorizontalAlignment="Stretch">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="170"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="Auto"/>
                                            <RowDefinition Height="Auto"/>
                                        </Grid.RowDefinitions>
                                        <TextBlock Grid.Row="0" Grid.Column="0" Text="Computer name" VerticalAlignment="Center" Height="28"
                                                   FontSize="12.5" FontWeight="Bold" Foreground="$labelFg" FontFamily="Segoe UI"
                                                   TextAlignment="Right" Margin="0,0,10,0"/>
                                        <TextBox Grid.Row="0" Grid.Column="1" Name="TxtComputerName" Height="28" HorizontalAlignment="Stretch"/>
                                        <TextBlock Grid.Row="1" Grid.Column="1" Name="TxtComputerNameError" Foreground="$errorFg" FontSize="11" Margin="2,2,0,0" Height="14" Visibility="Hidden" TextWrapping="NoWrap" FontFamily="Segoe UI"/>
                                    </Grid>

                                    <Grid Name="RowComputerDescription" Margin="0,0,0,0" Visibility="Collapsed" HorizontalAlignment="Stretch">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="170"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="Auto"/>
                                            <RowDefinition Height="Auto"/>
                                        </Grid.RowDefinitions>
                                        <TextBlock Grid.Row="0" Grid.Column="0" Text="Computer description" VerticalAlignment="Center" Height="28"
                                                   FontSize="12.5" FontWeight="Bold" Foreground="$labelFg" FontFamily="Segoe UI"
                                                   TextAlignment="Right" Margin="0,0,10,0"/>
                                        <TextBox Grid.Row="0" Grid.Column="1" Name="TxtComputerDescription" Height="28" HorizontalAlignment="Stretch"/>
                                        <TextBlock Grid.Row="1" Grid.Column="1" Name="TxtComputerDescriptionError" Foreground="$errorFg" FontSize="11" Margin="2,2,0,0" Height="14" Visibility="Hidden" TextWrapping="NoWrap" FontFamily="Segoe UI"/>
                                    </Grid>
                                </StackPanel>

                                <!-- Firmware snapshot: right when identity fields shown; full width when both prompts are off -->
                                <Border Grid.Column="2" Name="BorderFirmwareSnapshot" Background="$textBoxBg" BorderBrush="$borderColor" BorderThickness="1" CornerRadius="4" Padding="12,8" VerticalAlignment="Top" MinWidth="240" HorizontalAlignment="Stretch">
                                    <Grid Name="GridFirmwareSnapshot">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="Auto"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="Auto"/>
                                            <RowDefinition Height="Auto"/>
                                            <RowDefinition Height="Auto"/>
                                            <RowDefinition Height="Auto"/>
                                            <RowDefinition Height="Auto"/>
                                        </Grid.RowDefinitions>
                                        <TextBlock Grid.Row="0" Grid.Column="0" Text="BIOS mode" FontSize="11" FontWeight="SemiBold" Foreground="$mutedFgColor" Margin="0,0,10,3" FontFamily="Segoe UI"/>
                                        <TextBlock Grid.Row="0" Grid.Column="1" Name="TxtFirmwareMode" Text="-" FontSize="11" FontWeight="SemiBold" Foreground="$fgColor" TextAlignment="Right" FontFamily="Segoe UI"/>
                                        <TextBlock Grid.Row="1" Grid.Column="0" Text="Secure Boot" FontSize="11" FontWeight="SemiBold" Foreground="$mutedFgColor" Margin="0,0,10,3" FontFamily="Segoe UI"/>
                                        <TextBlock Grid.Row="1" Grid.Column="1" Name="TxtFirmwareSecureBoot" Text="-" FontSize="11" Foreground="$fgColor" TextAlignment="Right" FontFamily="Segoe UI"/>
                                        <TextBlock Grid.Row="2" Grid.Column="0" Text="TPM" FontSize="11" FontWeight="SemiBold" Foreground="$mutedFgColor" Margin="0,0,10,3" FontFamily="Segoe UI"/>
                                        <TextBlock Grid.Row="2" Grid.Column="1" Name="TxtFirmwareTpm" Text="-" FontSize="11" Foreground="$fgColor" TextAlignment="Right" FontFamily="Segoe UI"/>
                                        <TextBlock Grid.Row="3" Grid.Column="0" Text="BIOS version" FontSize="11" FontWeight="SemiBold" Foreground="$mutedFgColor" Margin="0,0,10,3" FontFamily="Segoe UI"/>
                                        <TextBlock Grid.Row="3" Grid.Column="1" Name="TxtFirmwareBiosVersion" Text="-" FontSize="11" Foreground="$fgColor" TextAlignment="Right" TextTrimming="CharacterEllipsis" FontFamily="Segoe UI"/>
                                        <TextBlock Grid.Row="4" Grid.Column="0" Text="BIOS date" FontSize="11" FontWeight="SemiBold" Foreground="$mutedFgColor" Margin="0,0,10,0" FontFamily="Segoe UI"/>
                                        <TextBlock Grid.Row="4" Grid.Column="1" Name="TxtFirmwareBiosDate" Text="-" FontSize="11" Foreground="$fgColor" TextAlignment="Right" FontFamily="Segoe UI"/>
                                    </Grid>
                                </Border>
                            </Grid>
                        </Border>

                        <!-- SECTION 2: Deployment Workflow Selection -->
                        <TextBlock Text="Select deployment workflow" FontSize="13" FontWeight="SemiBold" Foreground="$headerColor" Margin="0,2,0,4" FontFamily="Segoe UI"/>

                        <Border Background="$surfaceBg" BorderBrush="$borderColor" BorderThickness="1" CornerRadius="5" Height="145" Margin="0,0,0,8" HorizontalAlignment="Stretch">
                            <TreeView Name="treeViewWorkflows" Grid.IsSharedSizeScope="True" Background="Transparent" BorderThickness="0" Padding="4" HorizontalContentAlignment="Stretch" ScrollViewer.VerticalScrollBarVisibility="Auto"/>
                        </Border>

                        <!-- Workflow Validation Error Message -->
                        <TextBlock Name="TxtWorkflowError" Foreground="$errorFg" FontSize="11" Margin="2,-5,0,6" Height="14" Visibility="Hidden" TextWrapping="NoWrap" FontFamily="Segoe UI"/>

                        <!-- SECTION 3: Hard Drive Selection -->
                        <Grid Name="HeaderDiskSelection" Margin="0,2,0,4" HorizontalAlignment="Stretch">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Grid.Column="0" Text="Select target hard drive" FontSize="13" FontWeight="SemiBold" Foreground="$headerColor" VerticalAlignment="Center" FontFamily="Segoe UI"/>
                            <Button Grid.Column="1" Name="BtnRefresh" Content="Refresh Disks" Style="{StaticResource ActionLinkStyle}"/>
                        </Grid>

                        <Border Name="BorderDiskSelection" Background="$surfaceBg" BorderBrush="$diskBorderColor" BorderThickness="1" CornerRadius="4" Height="96" Margin="0,0,0,8" HorizontalAlignment="Stretch">
                            <DataGrid Name="GridDisks" AutoGenerateColumns="False"
                                      HeadersVisibility="Column" GridLinesVisibility="None"
                                      Background="$surfaceBg" Foreground="$fgColor" BorderThickness="0"
                                      RowBackground="$surfaceBg" AlternatingRowBackground="$surfaceBg"
                                      RowHeight="28" SelectionMode="Single" SelectionUnit="FullRow" IsReadOnly="True"
                                      CanUserAddRows="False" CanUserDeleteRows="False"
                                      CanUserResizeColumns="True" HorizontalAlignment="Stretch">
                                <!-- Selection colors come from RowStyle/CellStyle (not SystemColors keys -
                                     those keys already live under TreeViewItem Style.Resources and
                                     re-adding them here throws ResourceDictionary Load errors on WinPE). -->
                                <DataGrid.ColumnHeaderStyle>
                                    <Style TargetType="DataGridColumnHeader">
                                        <Setter Property="Background" Value="$headerBg"/>
                                        <Setter Property="Foreground" Value="$headerFg"/>
                                        <Setter Property="FontWeight" Value="SemiBold"/>
                                        <Setter Property="FontSize" Value="11"/>
                                        <Setter Property="Padding" Value="10,6"/>
                                        <Setter Property="BorderThickness" Value="0,0,0,1"/>
                                        <Setter Property="BorderBrush" Value="$borderColor"/>
                                        <Setter Property="OverridesDefaultStyle" Value="True"/>
                                        <Setter Property="Template">
                                            <Setter.Value>
                                                <ControlTemplate TargetType="DataGridColumnHeader">
                                                    <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}">
                                                        <ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="True"/>
                                                    </Border>
                                                </ControlTemplate>
                                            </Setter.Value>
                                        </Setter>
                                    </Style>
                                </DataGrid.ColumnHeaderStyle>
                                <DataGrid.RowStyle>
                                    <Style TargetType="DataGridRow">
                                        <Setter Property="Background" Value="$surfaceBg"/>
                                        <Setter Property="Foreground" Value="$fgColor"/>
                                        <Setter Property="BorderThickness" Value="0"/>
                                        <Setter Property="Cursor" Value="Hand"/>
                                        <Style.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter Property="Background" Value="$buttonHoverBg"/>
                                            </Trigger>
                                            <Trigger Property="IsSelected" Value="True">
                                                <Setter Property="Background" Value="$primaryHoverBg"/>
                                                <Setter Property="Foreground" Value="#FFFFFF"/>
                                            </Trigger>
                                        </Style.Triggers>
                                    </Style>
                                </DataGrid.RowStyle>
                                <DataGrid.CellStyle>
                                    <Style TargetType="DataGridCell">
                                        <Setter Property="Background" Value="Transparent"/>
                                        <Setter Property="Foreground" Value="$fgColor"/>
                                        <Setter Property="BorderThickness" Value="0"/>
                                        <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
                                        <Setter Property="Padding" Value="6,0"/>
                                        <Style.Triggers>
                                            <Trigger Property="IsSelected" Value="True">
                                                <Setter Property="Background" Value="$primaryHoverBg"/>
                                                <Setter Property="Foreground" Value="#FFFFFF"/>
                                                <Setter Property="BorderBrush" Value="$primaryHoverBg"/>
                                            </Trigger>
                                        </Style.Triggers>
                                    </Style>
                                </DataGrid.CellStyle>
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Disk Index" Binding="{Binding Index}" Width="100" ElementStyle="{StaticResource DiskCellTextStyle}"/>
                                    <DataGridTextColumn Header="Model / Drive Name" Binding="{Binding Model}" Width="*" ElementStyle="{StaticResource DiskCellTextStyle}"/>
                                    <DataGridTextColumn Header="Capacity" Binding="{Binding Capacity}" Width="110" ElementStyle="{StaticResource DiskCellTextStyle}"/>
                                    <DataGridTextColumn Header="Estimated Usage" Binding="{Binding UsedSpace}" Width="120" ElementStyle="{StaticResource DiskCellTextStyle}"/>
                                    <DataGridTextColumn Header="Available Space" Binding="{Binding FreeSpace}" Width="120" ElementStyle="{StaticResource DiskCellTextStyle}"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </Border>

                        <!-- Disk Validation Error Message -->
                        <TextBlock Name="TxtDiskError" Foreground="$errorFg" FontSize="11" Margin="2,-5,0,6" Height="14" Visibility="Hidden" TextWrapping="NoWrap" FontFamily="Segoe UI"/>

                        <!-- SECTION 4: Drivers -->
                        <TextBlock Text="Drivers" FontSize="13" FontWeight="SemiBold" Foreground="$headerColor" Margin="0,2,0,4" FontFamily="Segoe UI"/>

                        <Border Background="$surfaceBg" BorderBrush="$borderColor" BorderThickness="1" CornerRadius="5" Padding="12,12" HorizontalAlignment="Stretch">
                            <StackPanel Name="ContainerDrivers" HorizontalAlignment="Stretch">

                                <!-- Auto Online Download Checkbox (above driver source) -->
                                <CheckBox Name="ChkOnlineDrivers" Content="Download the latest driver pack (USB media)"
                                          FontSize="12.5" Foreground="$labelFg" FontFamily="Segoe UI"
                                          VerticalContentAlignment="Center" Margin="0,0,0,10"/>

                                <!-- Manual Driver Pack Selection -->
                                <Grid Name="RowManualDriverSelection" Margin="0" Visibility="Collapsed" HorizontalAlignment="Stretch">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="170"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Text="Driver source" VerticalAlignment="Center" FontSize="12.5" Foreground="$labelFg" FontFamily="Segoe UI"/>
                                    <ComboBox Grid.Column="1" Name="CmbDriverPackPath" Height="28" VerticalContentAlignment="Center" FontSize="12" Margin="0,0,8,0" HorizontalAlignment="Stretch"/>
                                    <Button Grid.Column="2" Name="BtnDriverPackInfo" Content="Info" Style="{StaticResource ActionLinkStyle}" Height="28" Margin="0,0,10,0" Visibility="Collapsed" ToolTip="OEM driver pack details"/>
                                    <Button Grid.Column="3" Name="BtnBrowseDriverFolder" Content="Browse..." Style="{StaticResource ActionLinkStyle}" Height="28"/>
                                </Grid>
                            </StackPanel>
                        </Border>

                    </StackPanel>
                    </ScrollViewer>
                </Grid>

                <!-- PreCheck-style footer -->
                <Border Grid.Row="2" Background="$footerBg" Padding="20,12" BorderBrush="$borderColor" BorderThickness="0,1,0,0">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0" VerticalAlignment="Center" Margin="0,0,12,0">
                            <TextBlock Name="TxtConfigSource" Text="Configuration: Loading..." FontSize="11" Foreground="$mutedFgColor" TextTrimming="CharacterEllipsis"/>
                            <TextBlock Name="TxtDeploymentUid" Text="Deployment ID: -" FontSize="11" Foreground="$mutedFgColor" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                        </StackPanel>
                        <StackPanel Grid.Column="1" Orientation="Horizontal">
                            <Button Name="BtnBack" Content="Cancel" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,10,0"/>
                            <Button Name="BtnNext" Content="Start Deployment" Style="{StaticResource PrimaryButtonStyle}"/>
                        </StackPanel>
                    </Grid>
                </Border>
            </Grid>
        </Border>
    </Viewbox>
</Window>
"@

# Load XAML safely
$reader = New-Object System.Xml.XmlNodeReader $xaml

try {
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
} catch {
    Write-Error "Failed to parse XAML: $_"
    return (New-LiteDeployWorkflowSelectionResult -Passed $false -Status "XamlError")
}

if ($null -eq $window) {
    Write-Error "Window object returned null."
    return (New-LiteDeployWorkflowSelectionResult -Passed $false -Status "XamlError")
}

$window.Title = "$($script:ComponentMetadata.Name) v$($script:ComponentMetadata.Version)"

# -------------------------------------------------------------------
# BUSINESS LOGIC
# -------------------------------------------------------------------

# Map UI Elements
$btnNext                  = $window.FindName("BtnNext")
$btnBack                  = $window.FindName("BtnBack")
$btnRefresh               = $window.FindName("BtnRefresh")
$txtBrand                 = $window.FindName("TxtBrand")
$txtSubtitle              = $window.FindName("TxtSubtitle")
$txtDeviceIdentity        = $window.FindName("TxtDeviceIdentity")
$txtDeviceSerial          = $window.FindName("TxtDeviceSerial")
$txtConfigSource          = $window.FindName("TxtConfigSource")
$txtDeploymentUid         = $window.FindName("TxtDeploymentUid")
$txtFirmwareMode          = $window.FindName("TxtFirmwareMode")
$txtFirmwareSecureBoot    = $window.FindName("TxtFirmwareSecureBoot")
$txtFirmwareTpm           = $window.FindName("TxtFirmwareTpm")
$txtFirmwareBiosVersion   = $window.FindName("TxtFirmwareBiosVersion")
$txtFirmwareBiosDate      = $window.FindName("TxtFirmwareBiosDate")
$gridDisks                = $window.FindName("GridDisks")
$headerDiskSelection      = $window.FindName("HeaderDiskSelection")
$borderDiskSelection      = $window.FindName("BorderDiskSelection")
$headerComputerID         = $window.FindName("HeaderComputerID")
$cardComputerID           = $window.FindName("CardComputerID")
$containerComputerID      = $window.FindName("ContainerComputerID")
$gridComputerIdLayout     = $window.FindName("GridComputerIdLayout")
$borderFirmwareSnapshot   = $window.FindName("BorderFirmwareSnapshot")
$colComputerInputs = $null
$colComputerSpacer = $null
$colFirmware = $null
if ($null -ne $gridComputerIdLayout -and $gridComputerIdLayout.ColumnDefinitions.Count -ge 3) {
    $colComputerInputs = $gridComputerIdLayout.ColumnDefinitions[0]
    $colComputerSpacer = $gridComputerIdLayout.ColumnDefinitions[1]
    $colFirmware       = $gridComputerIdLayout.ColumnDefinitions[2]
}
$rowComputerName          = $window.FindName("RowComputerName")
$txtComputerName          = $window.FindName("TxtComputerName")
$txtComputerNameError     = $window.FindName("TxtComputerNameError")
$rowComputerDescription   = $window.FindName("RowComputerDescription")
$txtComputerDescription   = $window.FindName("TxtComputerDescription")
$txtComputerDescriptionError = $window.FindName("TxtComputerDescriptionError")
$treeView                 = $window.FindName("treeViewWorkflows")
$txtWorkflowError         = $window.FindName("TxtWorkflowError")
$txtDiskError             = $window.FindName("TxtDiskError")
$rowManualDriverSelection = $window.FindName("RowManualDriverSelection")
$cmbDriverPackPath        = $window.FindName("CmbDriverPackPath")
$btnDriverPackInfo        = $window.FindName("BtnDriverPackInfo")
$btnBrowseDriverFolder    = $window.FindName("BtnBrowseDriverFolder")
$chkOnlineDrivers         = $window.FindName("ChkOnlineDrivers")

if ($null -ne $txtConfigSource) {
    $txtConfigSource.Text = "Configuration: $BootConfigPath"
}
if ($null -ne $txtDeploymentUid) {
    $uidText = if ($script:DeploymentUid) { $script:DeploymentUid } else { "-" }
    $txtDeploymentUid.Text = "Deployment ID: $uidText"
}

$componentName = [string]$script:ComponentMetadata.Name
$componentVersion = [string]$script:ComponentMetadata.Version

function Update-LiteDeployBrandHeader {
    param($Config)

    $name = "LiteDeploy"
    $version = ""
    $environment = ""

    $configMeta = Get-LiteDeployProperty $Config "Metadata"
    $metaName = Get-LiteDeployProperty $configMeta "Name"
    $metaVersion = Get-LiteDeployProperty $configMeta "Version"
    $metaEnvironment = Get-LiteDeployProperty $configMeta "Environment"
    if (-not [string]::IsNullOrWhiteSpace([string]$metaName)) { $name = [string]$metaName }
    if (-not [string]::IsNullOrWhiteSpace([string]$metaVersion)) { $version = [string]$metaVersion }
    if (-not [string]::IsNullOrWhiteSpace([string]$metaEnvironment)) { $environment = [string]$metaEnvironment }

    if ($null -ne $txtBrand) { $txtBrand.Text = $name }
    if ($null -ne $txtSubtitle) {
        $txtSubtitle.Text = if ($environment) {
            "$environment Environment | v$version"
        } else {
            "$componentName   | v$componentVersion"
        }
    }
}

# Same PreCheck pattern: Metadata.Name / Environment / Version, else component fallback.
Update-LiteDeployBrandHeader -Config $bootConfig

function Clear-InlineValidationError {
    param([System.Windows.Controls.TextBlock]$ErrorTextBlock)

    if ($null -ne $ErrorTextBlock) {
        $ErrorTextBlock.Text = ""
        $ErrorTextBlock.Visibility = [System.Windows.Visibility]::Hidden
    }
}

function Set-InlineValidationError {
    param(
        [System.Windows.Controls.TextBlock]$ErrorTextBlock,
        [string]$Message
    )

    if ($null -eq $ErrorTextBlock) { return }
    if ([string]::IsNullOrWhiteSpace($Message)) {
        Clear-InlineValidationError -ErrorTextBlock $ErrorTextBlock
        return
    }
    $ErrorTextBlock.Text = $Message
    $ErrorTextBlock.Visibility = [System.Windows.Visibility]::Visible
}

function Get-LiteDeployComputerNameValidationError {
    param(
        [string]$Name,
        [int]$MaxLength = 15
    )

    $value = if ($null -eq $Name) { "" } else { $Name.Trim() }

    if ([string]::IsNullOrWhiteSpace($value)) {
        return "Computer name cannot be empty."
    }
    if ($value.Length -gt $MaxLength) {
        return "Computer name must not exceed $MaxLength characters."
    }
    # MDT / NetBIOS: letters, digits, hyphen only; no leading/trailing hyphen.
    if ($value -notmatch '^[A-Za-z0-9-]+$') {
        return "Use only letters, numbers, and hyphens (A-Z, 0-9, -)."
    }
    if ($value.StartsWith('-') -or $value.EndsWith('-')) {
        return "Computer name cannot start or end with a hyphen."
    }
    return $null
}

function Get-LiteDeployComputerDescriptionValidationError {
    param([string]$Description)

    $value = if ($null -eq $Description) { "" } else { $Description.Trim() }
    if ([string]::IsNullOrWhiteSpace($value)) {
        return "Computer description cannot be empty."
    }
    return $null
}

if ($null -ne $gridDisks) {
    $gridDisks.Add_SelectionChanged({
        if ($null -ne $gridDisks.SelectedItem) {
            Clear-InlineValidationError -ErrorTextBlock $txtDiskError
        }
    })
}

# ==============================================================================
# OPERATING SYSTEMS CATALOG (ImportOSMedia Content\OperatingSystems\catalog.json)
# ==============================================================================

function Get-LiteDeployOperatingSystemsCatalog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShareRoot
    )

    $catalogPath = Join-Path $ShareRoot.TrimEnd('\') "Content\OperatingSystems\catalog.json"
    if (-not (Test-JSONFormat -Path $catalogPath)) {
        return $null
    }

    $catalogData = Get-Content -LiteralPath $catalogPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $catalogData -or -not $catalogData.PSObject.Properties["operatingSystems"]) {
        return $null
    }

    return [PSCustomObject]@{
        CatalogPath      = $catalogPath
        OperatingSystems = @($catalogData.operatingSystems)
    }
}

function Get-LiteDeployOsCatalogDateText {
    param([psobject]$Os)

    $parts = [System.Collections.Generic.List[string]]::new()

    $imported = $null
    if ($Os -and $Os.PSObject.Properties["importedDate"] -and $Os.importedDate) {
        $imported = [string]$Os.importedDate
    }
    if ($imported) {
        $parts.Add("Imported $imported")
    }

    if ($Os -and $Os.buildVersion) {
        $parts.Add("Build $($Os.buildVersion)")
    }
    elseif ($Os -and $Os.version) {
        $parts.Add("Version $($Os.version)")
    }

    if ($parts.Count -eq 0) { return "Updated" }
    return ($parts -join " | ")
}

function Populate-WorkflowTreeView {
    param(
        [System.Windows.Controls.TreeView]$TreeView,
        [psobject]$CatalogResult,
        [System.Windows.Window]$Window
    )

    $TreeView.Items.Clear()
    $validOsFound = $false

    if ($CatalogResult -and $CatalogResult.OperatingSystems -and @($CatalogResult.OperatingSystems).Length -gt 0) {
        $enabledOsList = @(
            @($CatalogResult.OperatingSystems) | Where-Object {
                -not ($_.PSObject.Properties['enabled'] -and $_.enabled -eq $false)
            }
        )
        $expandSingleWorkflow = ($enabledOsList.Count -eq 1)

        foreach ($os in $enabledOsList) {
            $langTag = if ($os.defaultLanguage) { " [$($os.defaultLanguage)]" } else { "" }
            $parentTitle = if ($os.fullName) { "$($os.fullName)$langTag" } elseif ($os.osName) { "$($os.osName)$langTag" } else { "Operating System" }

            $parentItem = [System.Windows.Controls.TreeViewItem]::new()
            $parentItem.Style = $Window.FindResource("HeaderNodeStyle")
            $parentItem.Header = [PSCustomObject]@{
                HeaderText = $parentTitle
            }

            # One workflow -> expand; multiple -> only when catalog/OS expandOnLoad is true.
            $expandOnLoad = $false
            if ($os.PSObject.Properties['expandOnLoad']) {
                $expandOnLoad = [bool]$os.expandOnLoad
            } elseif ($os.PSObject.Properties['ExpandOnLoad']) {
                $expandOnLoad = [bool]$os.ExpandOnLoad
            }
            $parentItem.IsExpanded = $expandSingleWorkflow -or $expandOnLoad

            $editions = if ($os.PSObject.Properties['editions'] -and $os.editions) {
                @($os.editions | Where-Object { -not ($_.PSObject.Properties['enabled'] -and $_.enabled -eq $false) })
            } else {
                @()
            }

            $dateText = Get-LiteDeployOsCatalogDateText -Os $os

            if (@($editions).Length -gt 0) {
                foreach ($ed in @($editions)) {
                    $childItem = [System.Windows.Controls.TreeViewItem]::new()
                    $childItem.Style = $Window.FindResource("ChildNodeStyle")
                    
                    $edName = if ($ed.PSObject.Properties['editionName'] -and $ed.editionName) { 
                        $ed.editionName 
                    } elseif ($ed.PSObject.Properties['name'] -and $ed.name) { 
                        $ed.name 
                    } else { 
                        $os.fullName 
                    }

                    $edIndex = if ($ed.PSObject.Properties['imageIndex'] -and $null -ne $ed.imageIndex) { 
                        [int]$ed.imageIndex 
                    } elseif ($ed.PSObject.Properties['index'] -and $null -ne $ed.index) { 
                        [int]$ed.index 
                    } else { 
                        1 
                    }

                    $childItem.Header = [PSCustomObject]@{
                        Name     = $edName
                        DateText = $dateText
                    }

                    $childItem.Tag = [PSCustomObject]@{
                        OsId         = $os.osId
                        EditionId    = if ($ed.PSObject.Properties['editionId']) { $ed.editionId } else { $os.osId }
                        Name         = $edName
                        SkuCode      = if ($ed.PSObject.Properties['skuCode']) { $ed.skuCode } else { "" }
                        Index        = $edIndex
                        ImagePath    = $os.imagePath
                        SetupPath    = $os.setupPath
                        MediaRoot    = $os.mediaRoot
                        Arch         = $os.arch
                        Language     = $os.defaultLanguage
                        ImportedDate = if ($os.PSObject.Properties['importedDate']) { $os.importedDate } else { $null }
                    }

                    $null = $parentItem.Items.Add($childItem)
                    $validOsFound = $true
                }
            } else {
                # Single standalone OS entry without multi-edition breakdown
                $childItem = [System.Windows.Controls.TreeViewItem]::new()
                $childItem.Style = $Window.FindResource("ChildNodeStyle")
                $childItem.Header = [PSCustomObject]@{
                    Name     = if ($os.fullName) { $os.fullName } else { $os.osName }
                    DateText = $dateText
                }
                $childItem.Tag = [PSCustomObject]@{
                    OsId         = $os.osId
                    EditionId    = $os.osId
                    Name         = if ($os.fullName) { $os.fullName } else { $os.osName }
                    SkuCode      = ""
                    Index        = 1
                    ImagePath    = $os.imagePath
                    SetupPath    = $os.setupPath
                    MediaRoot    = $os.mediaRoot
                    Arch         = $os.arch
                    Language     = $os.defaultLanguage
                    ImportedDate = if ($os.PSObject.Properties['importedDate']) { $os.importedDate } else { $null }
                }
                $null = $parentItem.Items.Add($childItem)
                $validOsFound = $true
            }

            if ($parentItem.Items.Count -gt 0) {
                $null = $TreeView.Items.Add($parentItem)
            }
        }
    }

    if (-not $validOsFound) {
        # Display clean "No Workflows Available" placeholder
        $emptyNode = [System.Windows.Controls.TreeViewItem]::new()
        $emptyNode.Style = $Window.FindResource("HeaderNodeStyle")
        $emptyNode.Header = [PSCustomObject]@{
            HeaderText = "No Workflows Available"
        }
        $emptyNode.IsExpanded = $true

        $emptyChild = [System.Windows.Controls.TreeViewItem]::new()
        $emptyChild.Style = $Window.FindResource("ChildNodeStyle")
        $emptyChild.Header = [PSCustomObject]@{
            Name     = "No Operating Systems found in 'Content\OperatingSystems\catalog.json'"
            DateText = "Catalog Empty"
        }
        $emptyChild.Tag = $null

        $null = $emptyNode.Items.Add($emptyChild)
        $null = $TreeView.Items.Add($emptyNode)

        if ($null -ne $txtWorkflowError) {
            $txtWorkflowError.Text = "No operating system workflows are available in the deployment share."
            $txtWorkflowError.Visibility = [System.Windows.Visibility]::Visible
        }
    }
    # Do not auto-select a workflow - technician must choose one before Start Deployment.
}

# Discover catalog and dynamically populate TreeView
$script:DiscoveredCatalog = Get-LiteDeployOperatingSystemsCatalog -ShareRoot $script:DeploymentSharePath
if ($null -ne $treeView) {
    Populate-WorkflowTreeView -TreeView $treeView -CatalogResult $script:DiscoveredCatalog -Window $window

    # Auto-expand parent categories and prevent selecting empty parents
    $treeView.add_SelectedItemChanged({
        param($sender, $e)
        if ($treeView.SelectedItem -and $treeView.SelectedItem.HasItems) {
            $firstChild = $treeView.SelectedItem.Items[0]
            $firstChild.IsSelected = $true
        }
        if ($treeView.SelectedItem -and $treeView.SelectedItem.Tag) {
            Clear-InlineValidationError -ErrorTextBlock $txtWorkflowError
        }
    })
}

# Read Configuration Options from BootConfig -> Deployment
$deploymentType = "Media"
$deploymentConfig = Get-LiteDeployProperty $bootConfig "Deployment"
$configuredDeploymentType = Get-LiteDeployProperty $deploymentConfig "Type"
if (-not [string]::IsNullOrWhiteSpace([string]$configuredDeploymentType)) {
    $deploymentType = [string]$configuredDeploymentType
}

# Read Configuration Options from BootConfig -> ComputerSetup
$promptComputerName = $true
$maxNameLength      = 15
$namePrefix         = ""
$promptDescription  = $true
$driveSelection     = $true

$computerSetupConfig = Get-LiteDeployProperty $bootConfig "ComputerSetup"
if ($null -ne $computerSetupConfig) {
    $configuredPromptComputerName = Get-LiteDeployProperty $computerSetupConfig "PromptForComputerName"
    $configuredMaxNameLength = Get-LiteDeployProperty $computerSetupConfig "MaxComputerNameLength"
    $configuredNamePrefix = Get-LiteDeployProperty $computerSetupConfig "ComputerNamePrefix"
    $configuredPromptDescription = Get-LiteDeployProperty $computerSetupConfig "PromptForComputerDescription"
    $configuredDriveSelection = Get-LiteDeployProperty $computerSetupConfig "DriveSelection"

    if ($null -ne $configuredPromptComputerName) {
        $promptComputerName = [bool]$configuredPromptComputerName
    }
    # Windows NetBIOS / hostname limit is 15. BootConfig may only tighten that (1..15), never raise it.
    if ($null -ne $configuredMaxNameLength) {
        $parsedMax = 0
        if ([int]::TryParse([string]$configuredMaxNameLength, [ref]$parsedMax) -and $parsedMax -gt 0) {
            $maxNameLength = [Math]::Min(15, $parsedMax)
        }
    }
    if (-not [string]::IsNullOrEmpty([string]$configuredNamePrefix)) {
        $namePrefix = [string]$configuredNamePrefix
    }
    if ($null -ne $configuredPromptDescription) {
        $promptDescription = [bool]$configuredPromptDescription
    }
    if ($null -ne $configuredDriveSelection) {
        $driveSelection = [bool]$configuredDriveSelection
    }
}
$script:DriveSelection = $driveSelection
$script:PromptComputerName = $promptComputerName
$script:PromptDescription = $promptDescription
$script:MaxComputerNameLength = $maxNameLength
$script:ComputerNamePrefix = $namePrefix

# Read Configuration Options from BootConfig -> Drivers
$autoDetectDrivers    = $true
$allowManualSelection  = $true
$autoOnlineDownload    = $true

$driversConfig = Get-LiteDeployProperty $bootConfig "Drivers"
if ($null -ne $driversConfig) {
    $configuredAutoDetect = Get-LiteDeployProperty $driversConfig "AutoDetectDrivers"
    $configuredManualSelection = Get-LiteDeployProperty $driversConfig "AllowManualSelection"
    $configuredOnlineDownload = Get-LiteDeployProperty $driversConfig "AutoOnlineDownloadOnMedia"

    if ($null -ne $configuredAutoDetect) {
        $autoDetectDrivers = [bool]$configuredAutoDetect
    }
    if ($null -ne $configuredManualSelection) {
        $allowManualSelection = [bool]$configuredManualSelection
    }
    if ($null -ne $configuredOnlineDownload) {
        $autoOnlineDownload = [bool]$configuredOnlineDownload
    }
}

function Set-LiteDeployComputerIdentityUi {
    param(
        [bool]$PromptName,
        [bool]$PromptDescription,
        [int]$MaxNameLength = 15,
        [string]$NamePrefix = "",
        [switch]$ApplyPrefixIfEmpty
    )

    $script:PromptComputerName = $PromptName
    $script:PromptDescription = $PromptDescription
    $script:MaxComputerNameLength = $MaxNameLength
    $script:ComputerNamePrefix = $NamePrefix

    if ($null -ne $headerComputerID) { $headerComputerID.Visibility = [System.Windows.Visibility]::Visible }
    if ($null -ne $cardComputerID)   { $cardComputerID.Visibility   = [System.Windows.Visibility]::Visible }

    if ($PromptName) {
        if ($null -ne $rowComputerName) { $rowComputerName.Visibility = [System.Windows.Visibility]::Visible }
        if ($null -ne $txtComputerName) {
            $txtComputerName.MaxLength = $MaxNameLength
            if ($ApplyPrefixIfEmpty -and [string]::IsNullOrWhiteSpace($txtComputerName.Text) -and -not [string]::IsNullOrEmpty($NamePrefix)) {
                $txtComputerName.Text = $NamePrefix
            }
        }
    }
    else {
        if ($null -ne $rowComputerName) { $rowComputerName.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($null -ne $txtComputerNameError) { Clear-InlineValidationError -ErrorTextBlock $txtComputerNameError }
    }

    if ($PromptDescription) {
        if ($null -ne $rowComputerDescription) { $rowComputerDescription.Visibility = [System.Windows.Visibility]::Visible }
    }
    else {
        if ($null -ne $rowComputerDescription) { $rowComputerDescription.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($null -ne $txtComputerDescriptionError) { Clear-InlineValidationError -ErrorTextBlock $txtComputerDescriptionError }
    }

    # When name + description are both off, expand firmware to full card width.
    $showIdentityInputs = ($PromptName -or $PromptDescription)
    if ($showIdentityInputs) {
        if ($null -ne $containerComputerID) {
            $containerComputerID.Visibility = [System.Windows.Visibility]::Visible
        }
        if ($null -ne $colComputerInputs) {
            $colComputerInputs.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
            $colComputerInputs.MinWidth = 220
        }
        if ($null -ne $colComputerSpacer) {
            $colComputerSpacer.Width = [System.Windows.GridLength]::new(12)
        }
        if ($null -ne $colFirmware) {
            $colFirmware.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Auto)
            $colFirmware.MinWidth = 240
        }
        if ($null -ne $borderFirmwareSnapshot) {
            $borderFirmwareSnapshot.MinWidth = 240
            $borderFirmwareSnapshot.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
        }
    }
    else {
        if ($null -ne $containerComputerID) {
            $containerComputerID.Visibility = [System.Windows.Visibility]::Collapsed
        }
        if ($null -ne $colComputerInputs) {
            $colComputerInputs.Width = [System.Windows.GridLength]::new(0)
            $colComputerInputs.MinWidth = 0
        }
        if ($null -ne $colComputerSpacer) {
            $colComputerSpacer.Width = [System.Windows.GridLength]::new(0)
        }
        if ($null -ne $colFirmware) {
            $colFirmware.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
            $colFirmware.MinWidth = 0
        }
        if ($null -ne $borderFirmwareSnapshot) {
            $borderFirmwareSnapshot.MinWidth = 0
            $borderFirmwareSnapshot.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
        }
    }
}

Set-LiteDeployComputerIdentityUi `
    -PromptName:$script:PromptComputerName `
    -PromptDescription:$script:PromptDescription `
    -MaxNameLength $script:MaxComputerNameLength `
    -NamePrefix $script:ComputerNamePrefix `
    -ApplyPrefixIfEmpty

# DriveSelection=true: show disk picker. false: hide section and auto-pick first internal disk.
function Set-LiteDeployDriveSelectionUi {
    param([bool]$ShowPicker)

    $vis = if ($ShowPicker) {
        [System.Windows.Visibility]::Visible
    } else {
        [System.Windows.Visibility]::Collapsed
    }
    if ($null -ne $headerDiskSelection) { $headerDiskSelection.Visibility = $vis }
    if ($null -ne $borderDiskSelection) { $borderDiskSelection.Visibility = $vis }
    if ($null -ne $txtDiskError) {
        if ($ShowPicker) {
            $txtDiskError.Visibility = [System.Windows.Visibility]::Hidden
        } else {
            $txtDiskError.Visibility = [System.Windows.Visibility]::Collapsed
            $txtDiskError.Text = ""
        }
    }
}

function Set-LiteDeployAutoSelectedDisk {
    param([object[]]$Disks)

    $script:SelectedDiskIndex = $null
    $script:SelectedDiskModel = ""
    if ($null -eq $Disks -or @($Disks).Length -eq 0) { return $false }

    $first = @($Disks)[0]
    if ($null -ne $gridDisks) {
        $gridDisks.SelectedItem = $first
    }
    $script:SelectedDiskIndex = if ($first.PSObject.Properties['DiskNumber'] -and ($null -ne $first.DiskNumber)) {
        [int]$first.DiskNumber
    } elseif ("$($first.Index)" -match '(\d+)') {
        [int]$matches[1]
    } else {
        0
    }
    $script:SelectedDiskModel = if ($first.PSObject.Properties['Model']) { [string]$first.Model } else { "" }
    return $true
}

Set-LiteDeployDriveSelectionUi -ShowPicker:$script:DriveSelection

# Live validation while typing (always wired; policy flags gate the work).
if ($null -ne $txtComputerName) {
    $txtComputerName.Add_TextChanged({
        if (-not $script:PromptComputerName) {
            Clear-InlineValidationError -ErrorTextBlock $txtComputerNameError
            return
        }
        $err = Get-LiteDeployComputerNameValidationError -Name $txtComputerName.Text -MaxLength $script:MaxComputerNameLength
        Set-InlineValidationError -ErrorTextBlock $txtComputerNameError -Message $err
    })
}
if ($null -ne $txtComputerDescription) {
    $txtComputerDescription.Add_TextChanged({
        if (-not $script:PromptDescription) {
            Clear-InlineValidationError -ErrorTextBlock $txtComputerDescriptionError
            return
        }
        $err = Get-LiteDeployComputerDescriptionValidationError -Description $txtComputerDescription.Text
        Set-InlineValidationError -ErrorTextBlock $txtComputerDescriptionError -Message $err
    })
}

# Apply Manual Selection Settings
if ($null -ne $rowManualDriverSelection) {
    $rowManualDriverSelection.Visibility = [System.Windows.Visibility]::Visible
}

if ($allowManualSelection) {
    if ($null -ne $cmbDriverPackPath)     { $cmbDriverPackPath.IsEnabled = $true }
    if ($null -ne $btnBrowseDriverFolder) { $btnBrowseDriverFolder.Visibility = [System.Windows.Visibility]::Visible }
} else {
    if ($null -ne $cmbDriverPackPath)     { $cmbDriverPackPath.IsEnabled = $false }
    if ($null -ne $btnBrowseDriverFolder) { $btnBrowseDriverFolder.Visibility = [System.Windows.Visibility]::Collapsed }
    if ($null -ne $btnDriverPackInfo)     { $btnDriverPackInfo.Visibility = [System.Windows.Visibility]::Collapsed }
}

# Online download only when Media + AutoOnlineDownloadOnMedia + internet is reachable.
$script:OfferOnlineDriverDownload = Test-OfferOnlineDriverDownload -DeploymentType $deploymentType -AutoOnlineDownload $autoOnlineDownload
if ($null -ne $chkOnlineDrivers) {
    if ($script:OfferOnlineDriverDownload) {
        $chkOnlineDrivers.Visibility = [System.Windows.Visibility]::Visible
    } else {
        $chkOnlineDrivers.Visibility = [System.Windows.Visibility]::Collapsed
        $chkOnlineDrivers.IsChecked = $false
    }
}

# Device identity at top (Hardware) + driver pack detection via imported DriverStaging (LocalCatalog).

function Update-LiteDeployDeviceIdentityHeader {
    param([psobject]$Detection)

    # Header shows raw OEM manufacturer; driver-pack paths still use normalized Vendor.
    $vendor = $null
    try { $vendor = Get-HardwareVendorRaw } catch {}
    $model = if ($Detection -and $Detection.Model) { [string]$Detection.Model } else { Get-HardwareModel }
    $serial = if ($Detection -and $Detection.SerialNumber) { [string]$Detection.SerialNumber } else { Get-HardwareSerialNumber }
    $sku = $null
    try { $sku = Get-HardwareComputerSku } catch {}

    if ($null -ne $txtDeviceIdentity) {
        $identityParts = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$vendor)) { $identityParts += $vendor.Trim() }
        if (-not [string]::IsNullOrWhiteSpace([string]$model)) { $identityParts += "Model: $($model.Trim())" }
        $identity = $identityParts -join " / "
        $txtDeviceIdentity.Text = if ($identity) { $identity } else { "Device information: unavailable" }
        $txtDeviceIdentity.ToolTip = $txtDeviceIdentity.Text
    }
    if ($null -ne $txtDeviceSerial) {
        $detailParts = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$serial)) { $detailParts += "Serial: $serial" }
        if (-not [string]::IsNullOrWhiteSpace([string]$sku)) { $detailParts += "SKU: $sku" }
        if ($detailParts.Count -gt 0) {
            $detail = $detailParts -join " / "
            $txtDeviceSerial.Text = $detail
            $txtDeviceSerial.ToolTip = $detail
            $txtDeviceSerial.Visibility = [System.Windows.Visibility]::Visible
        } else {
            $txtDeviceSerial.Text = ""
            $txtDeviceSerial.ToolTip = $null
            $txtDeviceSerial.Visibility = [System.Windows.Visibility]::Collapsed
        }
    }
}

function Set-LiteDeployFirmwareValue {
    param(
        [System.Windows.Controls.TextBlock]$Control,
        [string]$Value,
        [switch]$MuteIfNa
    )
    if ($null -eq $Control) { return }
    $text = if ([string]::IsNullOrWhiteSpace($Value)) { "-" } else { $Value.Trim() }
    $Control.Text = $text
    $isNa = ($text -eq "N/A" -or $text -eq "-")
    $color = if ($MuteIfNa -and $isNa) { $mutedFgColor } else { $fgColor }
    $Control.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($color)
}

function Update-LiteDeployFirmwareSnapshot {
    # Right-side firmware card: same labels on UEFI and Legacy; Legacy uses N/A for Secure Boot / TPM.
    $rawMode = Get-HardwareFirmwareType
    $modeDisplay = if ([string]::IsNullOrWhiteSpace([string]$rawMode)) {
        "Unknown"
    }
    elseif ($rawMode -match '(?i)^(Legacy|BIOS)$') {
        "Legacy"
    }
    else {
        [string]$rawMode
    }

    $secureBoot = Get-HardwareSecureBootStatus
    if ([string]::IsNullOrWhiteSpace([string]$secureBoot)) { $secureBoot = "N/A" }

    $tpmDisplay = "N/A"
    if (Get-HardwareIsUEFI) {
        if (Get-HardwareTpmPresent) {
            $ver = Get-HardwareTpmVersion
            $state = Get-HardwareTpmState
            if ($ver -and $state) { $tpmDisplay = "$ver ($state)" }
            elseif ($ver) { $tpmDisplay = [string]$ver }
            else { $tpmDisplay = "Present" }
        }
        else {
            $tpmDisplay = "Not Detected"
        }
    }

    $biosVersion = Get-HardwareBiosVersion
    $biosDate = Get-HardwareBiosReleaseDate

    Set-LiteDeployFirmwareValue -Control $txtFirmwareMode -Value $modeDisplay
    Set-LiteDeployFirmwareValue -Control $txtFirmwareSecureBoot -Value $secureBoot -MuteIfNa
    Set-LiteDeployFirmwareValue -Control $txtFirmwareTpm -Value $tpmDisplay -MuteIfNa
    Set-LiteDeployFirmwareValue -Control $txtFirmwareBiosVersion -Value $(if ($biosVersion) { [string]$biosVersion } else { "-" }) -MuteIfNa
    Set-LiteDeployFirmwareValue -Control $txtFirmwareBiosDate -Value $(if ($biosDate) { [string]$biosDate } else { "-" }) -MuteIfNa
}

# Always show vendor / model / serial in the header.
if ($autoDetectDrivers) {
    $script:DetectionResult = Get-SystemDriverDetection -ShareRoot $script:DeploymentSharePath
} else {
    $script:DetectionResult = [PSCustomObject]@{
        Manufacturer = (Get-HardwareVendor)
        Model        = (Get-HardwareModel)
        SerialNumber = (Get-HardwareSerialNumber)
        RelativePath = "Standard OS In-Box Drivers (Windows Default)"
        FullPath     = $null
        IsDetected   = $false
    }
}
Update-LiteDeployDeviceIdentityHeader -Detection $script:DetectionResult
Update-LiteDeployFirmwareSnapshot

# Populate Driver Selection ComboBox cleanly
if ($null -ne $cmbDriverPackPath) {
    $cmbDriverPackPath.Items.Clear()

    # Auto-Detect Option (Only included if a matching driver pack was found on disk/share)
    if ($script:DetectionResult.IsDetected) {
        $null = $cmbDriverPackPath.Items.Add((Get-DetectedPackComboLabel -Detection $script:DetectionResult))
    }

    # Standard OS In-Box Drivers Option
    $null = $cmbDriverPackPath.Items.Add("Standard OS In-Box Drivers (Windows Default)")

    # Online download (Media + policy + internet)
    if ($script:OfferOnlineDriverDownload) {
        $null = $cmbDriverPackPath.Items.Add("Download latest driver pack")
    }

    # Precedence on launch:
    # 1. Local pack detected -> Detected pack
    # 2. No local pack & online download offered -> Download latest driver pack
    # 3. Otherwise -> Standard OS In-Box Drivers
    if ($script:DetectionResult.IsDetected) {
        $cmbDriverPackPath.SelectedIndex = 0
        if ($null -ne $chkOnlineDrivers) { $chkOnlineDrivers.IsChecked = $false }
    } elseif ($script:OfferOnlineDriverDownload) {
        for ($i = 0; $i -lt $cmbDriverPackPath.Items.Count; $i++) {
            if ($cmbDriverPackPath.Items[$i].ToString() -like "*Download latest driver pack*") {
                $cmbDriverPackPath.SelectedIndex = $i
                break
            }
        }
        if ($null -ne $chkOnlineDrivers) { $chkOnlineDrivers.IsChecked = $true }
    } else {
        $cmbDriverPackPath.SelectedIndex = 0
        if ($null -ne $chkOnlineDrivers) { $chkOnlineDrivers.IsChecked = $false }
    }

    Update-DriverPackInfoButtonVisibility
}

if ($null -ne $btnDriverPackInfo) {
    $btnDriverPackInfo.Add_Click({
        Show-OemDriverPackInfoDialog -Detection $script:DetectionResult
    })
}

# Browse Folder Button Event Handler
if ($null -ne $btnBrowseDriverFolder) {
    $btnBrowseDriverFolder.Add_Click({
        if (-not (Get-Command Show-DriverPathDialog -ErrorAction SilentlyContinue)) {
            [System.Windows.MessageBox]::Show(
                "The WinPE driver folder picker could not be loaded from:`n$driverPathPickerScript",
                "Driver Folder Picker",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            ) | Out-Null
            return
        }

        # Always reload picker so UI edits are picked up without restarting WinPE.
        . $driverPathPickerScript

        $initialDriverPath = if ($script:DetectionResult.FullPath) {
            $detectedPath = [string]$script:DetectionResult.FullPath
            if (Test-Path -LiteralPath $detectedPath -PathType Leaf) {
                Split-Path -Parent $detectedPath
            } else {
                $detectedPath
            }
        } else {
            Join-Path $script:DeploymentSharePath "Content\Drivers"
        }

        $customPath = Show-DriverPathDialog -WindowTitle "Select Driver Folder" -InitialPath $initialDriverPath -Owner $window -Theme $Theme -DeploymentSharePath $script:DeploymentSharePath
        if ($customPath) {
            $customEntry = "Custom folder: $customPath"
            $existingIndex = $cmbDriverPackPath.Items.IndexOf($customEntry)
            if ($existingIndex -lt 0) {
                $existingIndex = $cmbDriverPackPath.Items.Add($customEntry)
            }
            $cmbDriverPackPath.SelectedIndex = $existingIndex
        }
    })
}

# Sync Online Download Checkbox & ComboBox Selection
if ($null -ne $chkOnlineDrivers -and $null -ne $cmbDriverPackPath) {
    $chkOnlineDrivers.add_Checked({
        for ($i = 0; $i -lt $cmbDriverPackPath.Items.Count; $i++) {
            if ($cmbDriverPackPath.Items[$i].ToString() -like "*Download latest driver pack*") {
                $cmbDriverPackPath.SelectedIndex = $i
                break
            }
        }
    })

    $chkOnlineDrivers.add_Unchecked({
        if ($cmbDriverPackPath.SelectedItem -and $cmbDriverPackPath.SelectedItem.ToString() -like "*Download latest driver pack*") {
            $cmbDriverPackPath.SelectedIndex = 0
        }
    })

    $cmbDriverPackPath.add_SelectionChanged({
        if ($cmbDriverPackPath.SelectedItem) {
            if ($cmbDriverPackPath.SelectedItem.ToString() -like "*Download latest driver pack*") {
                $chkOnlineDrivers.IsChecked = $true
            } else {
                $chkOnlineDrivers.IsChecked = $false
            }
        }
        Update-DriverPackInfoButtonVisibility
    })
} elseif ($null -ne $cmbDriverPackPath) {
    $cmbDriverPackPath.add_SelectionChanged({
        Update-DriverPackInfoButtonVisibility
    })
}

# Disk grid rows from Hardware (Capacity/Used/Free; 0 GB disks are listed, blocked on Continue).
# Auto-populate physical disk list on launch
$script:SelectedDiskIndex = $null
$script:SelectedDiskModel = ""
if ($null -ne $gridDisks) {
    [object[]]$detectedDisks = @(Get-HardwarePhysicalDisks)
    $gridDisks.ItemsSource = $detectedDisks
    if (-not $script:DriveSelection) {
        $null = Set-LiteDeployAutoSelectedDisk -Disks $detectedDisks
    }
}

# Unified Action Handler (Start Deployment / Validate All Sections)
$script:DeploymentRequested      = $false
$script:ComputerName             = ""
$script:ComputerDescription      = ""
$script:SelectedWorkflowTag      = $null
$script:SelectedOSName           = ""
# SelectedDiskIndex / SelectedDiskModel may already be set when DriveSelection=false
$script:AutoDetectDrivers        = $false
$script:SelectedDriverFolderPath = ""

if ($null -ne $btnNext) {
    $btnNext.Add_Click({
        $hasError = $false
        $validationMessages = @()
        $firstInvalidControl = $null

        # Hidden preserves the reserved validation rows so errors never shift the UI.
        if ($null -ne $txtComputerNameError) { Clear-InlineValidationError -ErrorTextBlock $txtComputerNameError }
        if ($null -ne $txtComputerDescriptionError) { Clear-InlineValidationError -ErrorTextBlock $txtComputerDescriptionError }
        if ($null -ne $txtWorkflowError)     { $txtWorkflowError.Visibility     = [System.Windows.Visibility]::Hidden; $txtWorkflowError.Text = "" }
        if ($null -ne $txtDiskError)         { $txtDiskError.Visibility         = [System.Windows.Visibility]::Hidden; $txtDiskError.Text = "" }

        # 1. Validate Computer Name (MDT / NetBIOS rules) when prompted
        if ($script:PromptComputerName -and $null -ne $txtComputerName) {
            $nameError = Get-LiteDeployComputerNameValidationError -Name $txtComputerName.Text -MaxLength $script:MaxComputerNameLength
            if ($nameError) {
                Set-InlineValidationError -ErrorTextBlock $txtComputerNameError -Message $nameError
                $validationMessages += "- $nameError"
                $firstInvalidControl = $txtComputerName
                $hasError = $true
            } else {
                $script:ComputerName = $txtComputerName.Text.Trim()
            }
        }

        # 1b. Computer description required when PromptForComputerDescription is true
        if ($script:PromptDescription -and $null -ne $txtComputerDescription) {
            $descError = Get-LiteDeployComputerDescriptionValidationError -Description $txtComputerDescription.Text
            if ($descError) {
                Set-InlineValidationError -ErrorTextBlock $txtComputerDescriptionError -Message $descError
                $validationMessages += "- $descError"
                if ($null -eq $firstInvalidControl) { $firstInvalidControl = $txtComputerDescription }
                $hasError = $true
            } else {
                $script:ComputerDescription = $txtComputerDescription.Text.Trim()
            }
        }

        # 2. Validate Deployment Workflow Selection
        $selectedItem = $treeView.SelectedItem
        if (-not $selectedItem -or -not $selectedItem.Tag) {
            $txtWorkflowError.Text = "Please select an OS workflow from the list above."
            $txtWorkflowError.Visibility = [System.Windows.Visibility]::Visible
            $validationMessages += "- Select an operating-system workflow."
            if ($null -eq $firstInvalidControl) { $firstInvalidControl = $treeView }
            $hasError = $true
        } else {
            $script:SelectedWorkflowTag = $selectedItem.Tag
            $script:SelectedOSName      = $selectedItem.Header.Name
        }

        # 3. Target hard drive: picker when DriveSelection=true; auto first disk when false
        if ($script:DriveSelection) {
            $selectedDisk = $null
            if ($null -ne $gridDisks) { $selectedDisk = $gridDisks.SelectedItem }
            if (-not $selectedDisk) {
                if ($null -ne $gridDisks -and $gridDisks.Items.Count -eq 0) {
                    $txtDiskError.Text = "No internal disks were detected. Load the storage driver and refresh."
                    $validationMessages += "- No internal disks were detected. Load the storage driver and refresh."
                } else {
                    $txtDiskError.Text = "Please select a target hard drive from the table above."
                    $validationMessages += "- Select a target hard drive."
                }
                if ($null -ne $txtDiskError) { $txtDiskError.Visibility = [System.Windows.Visibility]::Visible }
                if ($null -eq $firstInvalidControl) { $firstInvalidControl = $gridDisks }
                $hasError = $true
            } elseif (-not (Test-HardwareDiskSelectionHasCapacity -Disk $selectedDisk)) {
                $capacityMsg = "Selected disk has no usable capacity (0 GB). Choose another disk."
                if ($null -ne $txtDiskError) {
                    $txtDiskError.Text = $capacityMsg
                    $txtDiskError.Visibility = [System.Windows.Visibility]::Visible
                }
                $validationMessages += "- $capacityMsg"
                if ($null -eq $firstInvalidControl) { $firstInvalidControl = $gridDisks }
                $hasError = $true
            } else {
                $script:SelectedDiskIndex = if ($selectedDisk.PSObject.Properties['DiskNumber'] -and ($null -ne $selectedDisk.DiskNumber)) {
                    [int]$selectedDisk.DiskNumber
                } elseif ("$($selectedDisk.Index)" -match '(\d+)') {
                    [int]$matches[1]
                } else {
                    0
                }
                $script:SelectedDiskModel = $selectedDisk.Model
            }
        }
        else {
            $disks = @()
            if ($null -ne $gridDisks -and $null -ne $gridDisks.ItemsSource) {
                $disks = @($gridDisks.ItemsSource)
            }
            if (-not (Set-LiteDeployAutoSelectedDisk -Disks $disks)) {
                $validationMessages += "- No internal disks were detected. Load the storage driver and refresh."
                $hasError = $true
            } else {
                $autoDisk = if ($null -ne $gridDisks -and $null -ne $gridDisks.SelectedItem) {
                    $gridDisks.SelectedItem
                } elseif (@($disks).Length -gt 0) {
                    @($disks)[0]
                } else {
                    $null
                }
                if (-not (Test-HardwareDiskSelectionHasCapacity -Disk $autoDisk)) {
                    $validationMessages += "- Auto-selected disk has no usable capacity (0 GB). Load storage or enable Drive Selection to pick another disk."
                    $hasError = $true
                }
            }
        }

        # 4. Save Driver Selection Path
        $script:AutoDetectDrivers = $autoDetectDrivers
        if ($null -ne $cmbDriverPackPath -and $null -ne $cmbDriverPackPath.SelectedItem) {
            $selectedDriverChoice = $cmbDriverPackPath.SelectedItem.ToString()
            if ($selectedDriverChoice.StartsWith("Custom folder: ")) {
                $script:SelectedDriverFolderPath = $selectedDriverChoice.Substring(15)
            } elseif ($selectedDriverChoice.StartsWith("Detected pack: ") -and $script:DetectionResult.FullPath) {
                $script:SelectedDriverFolderPath = $script:DetectionResult.FullPath
            } else {
                $script:SelectedDriverFolderPath = $selectedDriverChoice
            }
        } else {
            $script:SelectedDriverFolderPath = $script:DetectionResult.RelativePath
        }

        if ($hasError) {
            Show-DeploymentWarning -Message ("Complete the following before starting deployment:`r`n`r`n" + ($validationMessages -join "`r`n"))
            if ($null -ne $firstInvalidControl) {
                $firstInvalidControl.Focus() | Out-Null
            }
            return
        }

        # Confirm & Complete Setup
        $confirmMsg = "Ready to proceed with deployment?`n`n" +
                      "Computer Name: $($script:ComputerName)`n" +
                      "Workflow: $($script:SelectedOSName)`n" +
                      "Target Disk: $($script:SelectedDiskIndex) ($($script:SelectedDiskModel))`n" +
                      "Drivers: $($script:SelectedDriverFolderPath)"

        $confirm = [System.Windows.MessageBox]::Show(
            $confirmMsg,
            "Confirm Deployment",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Information
        )

        if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
            $script:DeploymentRequested = $true
            $script:AllowClose = $true
            $window.Close()
        }
    })
}

if ($null -ne $btnBack) {
    $btnBack.Add_Click({
        $window.Close()
    })
}

function Invoke-LiteDeployDiskRefresh {
    # Refresh Disks button: rediscover disks only; leave workflow/driver/name selections alone.
    if ($null -eq $gridDisks) { return }

    [object[]]$detectedDisks = @(Get-HardwarePhysicalDisks)
    $gridDisks.ItemsSource = $detectedDisks
    if (-not $script:DriveSelection) {
        $null = Set-LiteDeployAutoSelectedDisk -Disks $detectedDisks
    }
    if ($null -ne $txtDiskError -and $script:DriveSelection) {
        $txtDiskError.Text = ""
        $txtDiskError.Visibility = [System.Windows.Visibility]::Hidden
        if (@($detectedDisks).Length -eq 0) {
            Show-DeploymentWarning -Message "No internal disks were detected. Load the storage driver and refresh."
        }
    }
    elseif (-not $script:DriveSelection -and @($detectedDisks).Length -eq 0) {
        Show-DeploymentWarning -Message "No internal disks were detected. Load the storage driver and refresh."
    }
}

function Invoke-LiteDeployWorkflowRefresh {
    # F5: reload BootConfig from path and refresh brand, catalog, disks, and drivers.
    try {
        $script:bootConfig = Get-EffectiveBootConfig -ForceReload
    }
    catch {
        Show-DeploymentWarning -Title "Refresh Failed" -Message (
            "Could not reload BootConfig.json from:`r`n$($script:BootConfigPath)`r`n`r`n$($_.Exception.Message)"
        )
        return
    }

    $bootConfig = $script:bootConfig
    Update-LiteDeployBrandHeader -Config $bootConfig
    if ($null -ne $txtConfigSource) {
        $txtConfigSource.Text = "Configuration: $($script:BootConfigPath)"
    }

    # Re-apply ComputerSetup UI flags from reloaded BootConfig.
    $promptComputerName = $true
    $promptDescription = $true
    $driveSelection = $true
    $maxNameLength = 15
    $namePrefix = ""
    $computerSetupConfig = Get-LiteDeployProperty $bootConfig "ComputerSetup"
    if ($null -ne $computerSetupConfig) {
        $configuredPromptComputerName = Get-LiteDeployProperty $computerSetupConfig "PromptForComputerName"
        $configuredPromptDescription = Get-LiteDeployProperty $computerSetupConfig "PromptForComputerDescription"
        $configuredDriveSelection = Get-LiteDeployProperty $computerSetupConfig "DriveSelection"
        $configuredMaxNameLength = Get-LiteDeployProperty $computerSetupConfig "MaxComputerNameLength"
        $configuredNamePrefix = Get-LiteDeployProperty $computerSetupConfig "ComputerNamePrefix"

        if ($null -ne $configuredPromptComputerName) { $promptComputerName = [bool]$configuredPromptComputerName }
        if ($null -ne $configuredPromptDescription) { $promptDescription = [bool]$configuredPromptDescription }
        if ($null -ne $configuredDriveSelection) { $driveSelection = [bool]$configuredDriveSelection }
        if ($null -ne $configuredMaxNameLength) {
            $parsedMax = 0
            if ([int]::TryParse([string]$configuredMaxNameLength, [ref]$parsedMax) -and $parsedMax -gt 0) {
                $maxNameLength = [Math]::Min(15, $parsedMax)
            }
        }
        if (-not [string]::IsNullOrEmpty([string]$configuredNamePrefix)) {
            $namePrefix = [string]$configuredNamePrefix
        }
    }

    Set-LiteDeployComputerIdentityUi `
        -PromptName:$promptComputerName `
        -PromptDescription:$promptDescription `
        -MaxNameLength $maxNameLength `
        -NamePrefix $namePrefix `
        -ApplyPrefixIfEmpty

    $script:DriveSelection = $driveSelection
    Set-LiteDeployDriveSelectionUi -ShowPicker:$script:DriveSelection

    # Refresh OS / workflow catalog from the share.
    $script:DiscoveredCatalog = Get-LiteDeployOperatingSystemsCatalog -ShareRoot $script:DeploymentSharePath
    if ($null -ne $treeView) {
        Populate-WorkflowTreeView -TreeView $treeView -CatalogResult $script:DiscoveredCatalog -Window $window
    }

    Invoke-LiteDeployDiskRefresh

    # Re-read Drivers section from disk BootConfig and rebuild driver pack list.
    $deploymentType = "Media"
    $deploymentConfig = Get-LiteDeployProperty $bootConfig "Deployment"
    $configuredDeploymentType = Get-LiteDeployProperty $deploymentConfig "Type"
    if (-not [string]::IsNullOrWhiteSpace([string]$configuredDeploymentType)) {
        $deploymentType = [string]$configuredDeploymentType
    }

    $autoDetectDrivers = $true
    $allowManualSelection = $true
    $autoOnlineDownload = $true
    $driversConfig = Get-LiteDeployProperty $bootConfig "Drivers"
    if ($null -ne $driversConfig) {
        $configuredAutoDetect = Get-LiteDeployProperty $driversConfig "AutoDetectDrivers"
        $configuredManualSelection = Get-LiteDeployProperty $driversConfig "AllowManualSelection"
        $configuredOnlineDownload = Get-LiteDeployProperty $driversConfig "AutoOnlineDownloadOnMedia"
        if ($null -ne $configuredAutoDetect) { $autoDetectDrivers = [bool]$configuredAutoDetect }
        if ($null -ne $configuredManualSelection) { $allowManualSelection = [bool]$configuredManualSelection }
        if ($null -ne $configuredOnlineDownload) { $autoOnlineDownload = [bool]$configuredOnlineDownload }
    }

    if ($allowManualSelection) {
        if ($null -ne $cmbDriverPackPath) { $cmbDriverPackPath.IsEnabled = $true }
        if ($null -ne $btnBrowseDriverFolder) { $btnBrowseDriverFolder.Visibility = [System.Windows.Visibility]::Visible }
    }
    else {
        if ($null -ne $cmbDriverPackPath) { $cmbDriverPackPath.IsEnabled = $false }
        if ($null -ne $btnBrowseDriverFolder) { $btnBrowseDriverFolder.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($null -ne $btnDriverPackInfo) { $btnDriverPackInfo.Visibility = [System.Windows.Visibility]::Collapsed }
    }

    $script:OfferOnlineDriverDownload = Test-OfferOnlineDriverDownload -DeploymentType $deploymentType -AutoOnlineDownload $autoOnlineDownload
    if ($null -ne $chkOnlineDrivers) {
        if ($script:OfferOnlineDriverDownload) {
            $chkOnlineDrivers.Visibility = [System.Windows.Visibility]::Visible
        }
        else {
            $chkOnlineDrivers.Visibility = [System.Windows.Visibility]::Collapsed
            $chkOnlineDrivers.IsChecked = $false
        }
    }

    if ($autoDetectDrivers) {
        $script:DetectionResult = Get-SystemDriverDetection -ShareRoot $script:DeploymentSharePath
    }
    else {
        $script:DetectionResult = [PSCustomObject]@{
            Manufacturer = (Get-HardwareVendor)
            Model        = (Get-HardwareModel)
            SerialNumber = (Get-HardwareSerialNumber)
            RelativePath = "Standard OS In-Box Drivers (Windows Default)"
            FullPath     = $null
            IsDetected   = $false
        }
    }
    Update-LiteDeployDeviceIdentityHeader -Detection $script:DetectionResult
    Update-LiteDeployFirmwareSnapshot

    if ($null -ne $cmbDriverPackPath) {
        $cmbDriverPackPath.Items.Clear()
        if ($script:DetectionResult.IsDetected) {
            $null = $cmbDriverPackPath.Items.Add((Get-DetectedPackComboLabel -Detection $script:DetectionResult))
        }
        $null = $cmbDriverPackPath.Items.Add("Standard OS In-Box Drivers (Windows Default)")
        if ($script:OfferOnlineDriverDownload) {
            $null = $cmbDriverPackPath.Items.Add("Download latest driver pack")
        }
        if ($script:DetectionResult.IsDetected) {
            $cmbDriverPackPath.SelectedIndex = 0
            if ($null -ne $chkOnlineDrivers) { $chkOnlineDrivers.IsChecked = $false }
        }
        elseif ($script:OfferOnlineDriverDownload) {
            for ($i = 0; $i -lt $cmbDriverPackPath.Items.Count; $i++) {
                if ($cmbDriverPackPath.Items[$i].ToString() -like "*Download latest driver pack*") {
                    $cmbDriverPackPath.SelectedIndex = $i
                    break
                }
            }
            if ($null -ne $chkOnlineDrivers) { $chkOnlineDrivers.IsChecked = $true }
        }
        else {
            $cmbDriverPackPath.SelectedIndex = 0
            if ($null -ne $chkOnlineDrivers) { $chkOnlineDrivers.IsChecked = $false }
        }
        Update-DriverPackInfoButtonVisibility
    }
}

if ($null -ne $btnRefresh) {
    $btnRefresh.Add_Click({
        Invoke-LiteDeployDiskRefresh
    })
}

$window.Add_PreviewKeyDown({
    param($sender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::F5) {
        $e.Handled = $true
        Invoke-LiteDeployWorkflowRefresh
    }
})

$window.Add_KeyDown({
    if ($_.Key -eq [System.Windows.Input.Key]::Escape) { $window.Close() }
})

# Confirm cancel when closing via X, Escape, or Cancel (same pattern as Hardware PreCheck).
$script:AllowClose = $false
$window.Add_Closing({
    param($sender, $e)
    if (-not $script:AllowClose) {
        $msg = "Close Workflow Selection and cancel this deployment?"
        $result = [System.Windows.Forms.MessageBox]::Show(
            $msg,
            "Cancel Deployment",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($result -eq [System.Windows.Forms.DialogResult]::No) {
            $e.Cancel = $true
        }
    }
})

# Display Window
$window.ShowDialog() | Out-Null

if (-not $script:DeploymentRequested) {
    return (New-LiteDeployWorkflowSelectionResult -Passed $false -Status "Cancelled")
}

$result = New-LiteDeployWorkflowSelectionResult `
    -Passed $true `
    -Status "Confirmed" `
    -SelectionJsonPath (Get-LiteDeployWorkflowSelectionJsonPath) `
    -ComputerName $script:ComputerName `
    -ComputerDescription $script:ComputerDescription `
    -WorkflowName $script:SelectedOSName `
    -WorkflowTag $script:SelectedWorkflowTag `
    -TargetDiskIndex $script:SelectedDiskIndex `
    -TargetDiskModel $script:SelectedDiskModel `
    -DriverFolderPath $script:SelectedDriverFolderPath `
    -AutoDetectDrivers $script:AutoDetectDrivers

try {
    $null = Save-LiteDeployWorkflowSelectionJson -Selection $result
}
catch {
    Show-DeploymentWarning -Title "Workflow Selection Save Failed" -Message (
        "Could not write WorkflowSelection.json:`r`n`r`n$($_.Exception.Message)"
    )
    return (New-LiteDeployWorkflowSelectionResult -Passed $false -Status "SaveFailed")
}

return $result

