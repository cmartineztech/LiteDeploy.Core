<#
.SYNOPSIS
    Unified Pure-WPF Progress Host & Real-Time Deployment State Renderer for LiteDeploy.

.DESCRIPTION
    High-performance, pure-WPF progress UI renderer supporting both FullOS (Dashboard Layout)
    and WinPE (Enterprise Layout) deployment environments in Light and Dark themes.

.PARAMETER StatePath
    Path to DeploymentState.json. Defaults to .\DeploymentState.json.

.PARAMETER Environment
    Target deployment environment layout:
      - 'Auto'   : Auto-detect environment from DeploymentState.json (default: FullOS)
      - 'FullOS' : Render FullOS Dashboard View (Sidebar cards, dual progress bars, log box)
      - 'WinPE'  : Render WinPE Enterprise View (Centered layout, big percent text, metadata footer)

.PARAMETER Theme
    Color palette scheme ('Light' or 'Dark'). Default is 'Light'.

.PARAMETER TopMost
    Window z-ordering switch ('Off' or 'On'). Default is 'Off'.

.PARAMETER WindowTitle
    Custom window title override.

.PARAMETER ShowBackdrop
    Display a full-screen backdrop window behind the host.

.PARAMETER KeepOpen
    Keep the UI host open even after status reaches 'Completed'.

.PARAMETER WinPE
    Force the WinPE enterprise layout (same as -Environment WinPE). Use this from Engine
    so Progress aligns with the WinPE execution environment. Prefers the RAM memory-map
    state published by LiteDeploy.State (Local\LiteDeploy.DeploymentState), then falls back
    to DeploymentState.json on the SystemDrive RAM disk (X:\ in WinPE).

.EXAMPLE
    .\LiteDeploy.UI.Progress.ps1 -Environment FullOS -Theme Light

.EXAMPLE
    .\LiteDeploy.UI.Progress.ps1 -WinPE -Theme Dark -TopMost On
#>

[CmdletBinding()]
param(
    [string]$StatePath = ".\DeploymentState.json",

    [ValidateSet("Auto", "FullOS", "WinPE")]
    [string]$Environment = "Auto",

    [ValidateSet("Light", "Dark")]
    [string]$Theme = "Light",

    [ValidateSet("On", "Off")]
    [string]$TopMost = "Off",

    [string]$WindowTitle = "",

    [switch]$ShowBackdrop,
    [switch]$KeepOpen,

    # Do not alias WinPe — PowerShell parameter names are case-insensitive, so Alias("WinPe")
    # conflicts with -WinPE and the host exits before the window opens (Engine passes -WinPE).
    [switch]$WinPE,

    [switch]$Metadata
)

# ==============================================================================
# COMPONENT METADATA
# ==============================================================================

function Get-LiteDeployComponentMetadata {
    return [PSCustomObject]@{
        ComponentId          = "UI.Progress"
        Name                 = "LiteDeploy UI Progress"
        Version              = "2.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "Universal"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("State")
        Description          = "WPF progress dashboard: reads Engine state from RAM memory-map (preferred) or DeploymentState.json; -WinPE selects WinPE layout."
    }
}

if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# -WinPE aligns Progress layout with Engine's WinPE execution environment.
# Theme always follows BootConfig.Ui.Theme (passed by Engine as -Theme); do not force Dark.
if ($WinPE) {
    $Environment = "WinPE"
}

# Absolute StatePath Resolution (PowerShell 5.1 Compatible Syntax)
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $scriptDir = [System.IO.Path]::GetDirectoryName($PSCommandPath)
    } else {
        $scriptDir = [System.Environment]::CurrentDirectory
    }
}

# Default state file: SystemDrive RAM disk in WinPE (X:\~LiteDeploy\...), else explicit -StatePath.
$targetStateFile = "DeploymentState.json"
if (-not [string]::IsNullOrWhiteSpace($StatePath) -and $PSBoundParameters.ContainsKey("StatePath")) {
    $targetStateFile = $StatePath
}
elseif ($env:SystemDrive) {
    $ramState = Join-Path $env:SystemDrive "~LiteDeploy\DeploymentState.json"
    if ((Test-Path -LiteralPath $ramState -PathType Leaf) -or $WinPE -or $Environment -eq "WinPE") {
        $targetStateFile = $ramState
    }
}
if (-not [System.IO.Path]::IsPathRooted($targetStateFile)) {
    $targetStateFile = Join-Path $scriptDir $targetStateFile
}
$script:StatePath = [System.IO.Path]::GetFullPath($targetStateFile)
$script:StateMemoryMapName = "Local\LiteDeploy.DeploymentState"
$script:StateMemoryMapCapacity = 1048576

# Ensure Single-Threaded Apartment (STA) Mode for WPF Compatibility in PowerShell 5.1
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $boundArgs = @()
        foreach ($parameterName in $PSBoundParameters.Keys) {
            if ($parameterName -eq "StatePath") { continue }
            $parameterValue = $PSBoundParameters[$parameterName]
            if ($parameterValue -is [switch] -and $parameterValue.IsPresent) {
                $boundArgs += "-$parameterName"
            }
            elseif ($parameterValue -isnot [switch] -and -not [string]::IsNullOrWhiteSpace([string]$parameterValue)) {
                $boundArgs += "-$parameterName `"$parameterValue`""
            }
        }
        $boundArgs += "-StatePath `"$script:StatePath`""
        $argList = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`" " + ($boundArgs -join " ")
        # Hidden host console — WPF Progress window is the only UI the technician should see.
        Start-Process -FilePath "powershell.exe" -ArgumentList $argList -WorkingDirectory $scriptDir -WindowStyle Hidden
        return
    }
}

# Hide this process's console window (if any) so only the WPF Progress surface is visible.
try {
    if (-not ([System.Management.Automation.PSTypeName]'LiteDeployProgressConsole').Type) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class LiteDeployProgressConsole {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    public const int SW_HIDE = 0;
}
"@ -ErrorAction Stop
    }
    $consoleHwnd = [LiteDeployProgressConsole]::GetConsoleWindow()
    if ($consoleHwnd -ne [IntPtr]::Zero) {
        [void][LiteDeployProgressConsole]::ShowWindow($consoleHwnd, [LiteDeployProgressConsole]::SW_HIDE)
    }
}
catch {}

# ------------------------------------------------------------------------------
# 1. HIGH-DPI AWARENESS & WPF ASSEMBLY INITIALIZATION
# ------------------------------------------------------------------------------
if (-not ([System.Management.Automation.PSTypeName]'DpiHelper').Type) {
    try {
        $DpiHelperCode = @"
            using System;
            using System.Runtime.InteropServices;
            public class DpiHelper {
                [DllImport("user32.dll")]
                public static extern bool SetProcessDpiAwarenessContext(IntPtr h);
            }
"@
        Add-Type -TypeDefinition $DpiHelperCode -ErrorAction SilentlyContinue
    } catch {}
}

try {
    [DpiHelper]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
} catch {}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ------------------------------------------------------------------------------
# 2. COLOR PALETTE & WPF BRUSH CONVERTERS
# ------------------------------------------------------------------------------
function ConvertTo-WinColor([string]$Hex) {
    return [System.Drawing.ColorTranslator]::FromHtml($Hex)
}

function ConvertTo-WpfBrush([string]$Hex) {
    return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex)
}

$script:ColorMap = @{
    Dark = @{
        IsDark      = $true
        BgMain      = "#151515"
        BgSidebar   = "#181818"
        BgFooter    = "#1B1B1B"
        BgLogBox    = "#242424"
        Border      = "#292929"
        TextPrimary = "#FFFFFF"
        TextSec     = "#BFBFBF"
        TextMuted   = "#808080"
        LogText     = "#60A5FA"
        TrackBg     = "#2E2E2E"
    }
    Light = @{
        IsDark      = $false
        BgMain      = "#FFFFFF"
        BgSidebar   = "#FFFFFF"
        BgFooter    = "#F7F9FB"
        BgLogBox    = "#F3F6F9"
        Border      = "#D9E0E7"
        TextPrimary = "#111827"
        TextSec     = "#4B5563"
        TextMuted   = "#687684"
        LogText     = "#0078D4"
        TrackBg     = "#E6EBF0"
    }
}

function Get-NativeThemePalette([string]$ThemeName) {
    $themeRecord = $script:ColorMap["Light"]
    if ($script:ColorMap.ContainsKey($ThemeName)) {
        $themeRecord = $script:ColorMap[$ThemeName]
    }

    return @{
        IsDark          = $themeRecord.IsDark
        WpfBgMain       = ConvertTo-WpfBrush $themeRecord.BgMain
        WpfBgSidebar    = ConvertTo-WpfBrush $themeRecord.BgSidebar
        WpfBgFooter     = ConvertTo-WpfBrush $themeRecord.BgFooter
        WpfBgLogBox     = ConvertTo-WpfBrush $themeRecord.BgLogBox
        WpfBorder       = ConvertTo-WpfBrush $themeRecord.Border
        WpfTextPrimary  = ConvertTo-WpfBrush $themeRecord.TextPrimary
        WpfTextSec      = ConvertTo-WpfBrush $themeRecord.TextSec
        WpfTextMuted    = ConvertTo-WpfBrush $themeRecord.TextMuted
        WpfLogText      = ConvertTo-WpfBrush $themeRecord.LogText
        WpfTrackBg      = ConvertTo-WpfBrush $themeRecord.TrackBg
    }
}

$script:StatusHexMap = @{
    "Completed" = "#107C10"
    "Failed"    = "#D13438"
    "Cancelled" = "#D13438"
    "Warning"   = "#D97706"
    "Running"   = "#0078D4"
    "Pending"   = "#CBD5E1"
}

function Get-LiteDeployProgressUiStatus {
    <#
    .SYNOPSIS
        Maps Engine DeploymentState.Status values onto Progress color/tag statuses.
    #>
    param([string]$RawStatus)
    if ([string]::IsNullOrWhiteSpace($RawStatus)) { return "Running" }
    switch -Regex ($RawStatus.Trim()) {
        '^(?i)Failed$'                          { return "Failed" }
        '^(?i)Cancelled$'                       { return "Failed" }
        '^(?i)(Completed|OSImageApplied)$'      { return "Completed" }
        default                                 { return "Running" }
    }
}

function Test-LiteDeployProgressTerminalSuccess {
    param([string]$RawStatus)
    return [bool]($RawStatus -match '^(?i)(Completed|OSImageApplied)$')
}

function Test-LiteDeployProgressTerminalFailure {
    param([string]$RawStatus)
    return [bool]($RawStatus -match '^(?i)(Failed|Cancelled)$')
}

function Get-StatusColor([string]$StatusName) {
    $normalized = Get-LiteDeployProgressUiStatus -RawStatus $StatusName
    $hex = "#0078D4"
    if ($script:StatusHexMap.ContainsKey($normalized)) {
        $hex = $script:StatusHexMap[$normalized]
    }
    elseif ($script:StatusHexMap.ContainsKey($StatusName)) {
        $hex = $script:StatusHexMap[$StatusName]
    }
    return ConvertTo-WpfBrush $hex
}

$Palette = Get-NativeThemePalette -ThemeName $Theme

# ------------------------------------------------------------------------------
# 3. BACKDROP OVERLAY WINDOW
# ------------------------------------------------------------------------------
$script:BackdropForm = $null
if ($ShowBackdrop) {
    $script:BackdropForm = New-Object System.Windows.Forms.Form
    $script:BackdropForm.Text = "LiteDeploy Backdrop"
    $script:BackdropForm.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
    $script:BackdropForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $bgColor = ConvertTo-WinColor "#002D50"
    if ($Palette.IsDark) {
        $bgColor = ConvertTo-WinColor "#0A0A0A"
    }
    $script:BackdropForm.BackColor = $bgColor
    $script:BackdropForm.ShowInTaskbar = $false
    $script:BackdropForm.Show()
}

# Global Control References & Active Layout Target
$script:UIControls = @{}
$script:ActiveLayout = "FullOS"

# Helper: Recursive Control Tree Traversal
function Get-WpfControlByName {
    param(
        [System.Windows.DependencyObject]$Parent,
        [string]$Name
    )
    if ($null -eq $Parent) { return $null }

    if ($Parent -is [System.Windows.FrameworkElement] -and $Parent.Name -eq $Name) {
        return $Parent
    }

    if ($Parent -is [System.Windows.FrameworkElement]) {
        try {
            $found = $Parent.FindName($Name)
            if ($null -ne $found) { return $found }
        } catch {}
    }

    try {
        $children = [System.Windows.LogicalTreeHelper]::GetChildren($Parent)
        foreach ($child in $children) {
            if ($child -is [System.Windows.DependencyObject]) {
                $foundChild = Get-WpfControlByName -Parent $child -Name $Name
                if ($null -ne $foundChild) { return $foundChild }
            }
        }
    } catch {}

    return $null
}

# Generic WPF Window Factory
function Build-WpfWindowFromXaml([string]$XamlText, [string[]]$ControlNames) {
    $reader = New-Object System.Xml.XmlNodeReader([xml]$XamlText)
    $script:WpfWindow = [System.Windows.Markup.XamlReader]::Load($reader)
    $script:WpfWindow.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen

    foreach ($controlName in $ControlNames) {
        $found = Get-WpfControlByName -Parent $script:WpfWindow -Name $controlName
        if ($null -ne $found) {
            $script:UIControls[$controlName] = $found
        }
    }
}

# FullOS View XAML Template Builder
function Build-WpfFullOSWindow([hashtable]$Pal) {
    $xaml = @"
    <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
            Title="LiteDeploy Progress Host (FullOS)" Width="800" Height="450" ResizeMode="CanMinimize" UseLayoutRounding="True" SnapsToDevicePixels="True"
            RenderOptions.BitmapScalingMode="HighQuality" TextOptions.TextFormattingMode="Ideal" TextOptions.TextRenderingMode="ClearType" Background="$($Pal.WpfBgMain)" FontFamily="Segoe UI">
        <Grid>
            <Grid.RowDefinitions><RowDefinition Height="64"/><RowDefinition Height="*"/><RowDefinition Height="45"/></Grid.RowDefinitions>
            <Grid Grid.Row="0">
                <Grid.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#005A9E" Offset="0"/><GradientStop Color="#0078D4" Offset="1"/></LinearGradientBrush></Grid.Background>
                <StackPanel Orientation="Horizontal" Margin="22,0,22,0" VerticalAlignment="Center">
                    <Border Width="44" Height="44" CornerRadius="8" Background="#28FFFFFF" Margin="0,0,14,0"><TextBlock Text="LD" Foreground="White" FontWeight="Bold" FontSize="15" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                    <StackPanel VerticalAlignment="Center">
                        <TextBlock x:Name="lblBrandTitle" Text="LiteDeploy" Foreground="White" FontSize="21" FontWeight="SemiBold"/>
                        <TextBlock x:Name="lblBrandSub" Text="Standard Workstation Workflow" Foreground="#D9EFFF" FontSize="15" Margin="0,2,0,0"/>
                    </StackPanel>
                </StackPanel>
            </Grid>
            <Grid Grid.Row="1">
                <Grid.ColumnDefinitions><ColumnDefinition Width="220"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Border Grid.Column="0" Background="$($Pal.WpfBgSidebar)" BorderBrush="$($Pal.WpfBorder)" BorderThickness="0,0,1,0" Padding="20,0,20,0">
                    <StackPanel VerticalAlignment="Center">
                        <StackPanel Margin="0,0,0,22"><TextBlock Text="DEPLOYMENT ID" FontSize="11" FontWeight="Bold" Foreground="$($Pal.WpfTextMuted)"/><TextBlock x:Name="lblDeployId" Text="LD-206072-001" FontSize="15" FontWeight="SemiBold" Foreground="$($Pal.WpfTextPrimary)" Margin="0,3,0,0"/></StackPanel>
                        <StackPanel Margin="0,0,0,22"><TextBlock Text="COMPUTER NAME" FontSize="11" FontWeight="Bold" Foreground="$($Pal.WpfTextMuted)"/><TextBlock x:Name="lblComputerName" Text="DESKTOP-01" FontSize="15" FontWeight="SemiBold" Foreground="$($Pal.WpfTextPrimary)" Margin="0,3,0,0"/></StackPanel>
                        <StackPanel Margin="0,0,0,22"><TextBlock Text="COMPUTER MODEL" FontSize="11" FontWeight="Bold" Foreground="$($Pal.WpfTextMuted)"/><TextBlock x:Name="lblComputerModel" Text="Latitude 7450" FontSize="15" FontWeight="SemiBold" Foreground="$($Pal.WpfTextPrimary)" Margin="0,3,0,0"/></StackPanel>
                        <StackPanel><TextBlock Text="OPERATING SYSTEM" FontSize="11" FontWeight="Bold" Foreground="$($Pal.WpfTextMuted)"/><TextBlock x:Name="lblTargetOS" Text="Windows 11 Enterprise 25H2" FontSize="13" FontWeight="SemiBold" Foreground="$($Pal.WpfTextPrimary)" Margin="0,3,0,0" TextWrapping="Wrap"/></StackPanel>
                    </StackPanel>
                </Border>
                <Grid Grid.Column="1" Margin="34,0,34,0" VerticalAlignment="Center">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <TextBlock x:Name="lblCurrentStep" Grid.Row="0" Text="Installing Windows 11 Enterprise" FontSize="23" FontWeight="SemiBold" Foreground="$($Pal.WpfTextPrimary)" TextTrimming="CharacterEllipsis"/>
                    <TextBlock x:Name="lblStepSubtitle" Grid.Row="1" Text="InstallWindows" FontSize="14" Foreground="$($Pal.WpfTextSec)" Margin="0,4,0,18"/>
                    <ProgressBar x:Name="WpfStepProgressBar" Grid.Row="2" Height="18" Minimum="0" Maximum="100" Value="0" Foreground="#0078D4" Background="$($Pal.WpfTrackBg)" BorderThickness="0"/>
                    <TextBlock x:Name="lblOverallLabel" Grid.Row="3" Text="OVERALL PROGRESS (ACTION 4 OF 8)" FontSize="11" FontWeight="Bold" Foreground="$($Pal.WpfTextMuted)" Margin="0,20,0,8"/>
                    <ProgressBar x:Name="WpfOverallProgressBar" Grid.Row="4" Height="18" Minimum="0" Maximum="100" Value="0" Foreground="#0078D4" Background="$($Pal.WpfTrackBg)" BorderThickness="0"/>
                    <Border Grid.Row="5" Height="56" Background="$($Pal.WpfBgLogBox)" BorderBrush="$($Pal.WpfBorder)" BorderThickness="1" CornerRadius="6" Margin="0,18,0,0" Padding="14,0,14,0" VerticalAlignment="Center">
                        <TextBlock x:Name="lblLogMessage" Text="Applying image index..." FontSize="13" FontFamily="Consolas" Foreground="$($Pal.WpfLogText)" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                    </Border>
                </Grid>
            </Grid>
            <Border Grid.Row="2" Background="$($Pal.WpfBgFooter)" BorderBrush="$($Pal.WpfBorder)" BorderThickness="0,1,0,0" Padding="26,0,26,0">
                <Grid VerticalAlignment="Center">
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Left"><TextBlock Text="Source: " FontSize="14" Foreground="$($Pal.WpfTextMuted)"/><TextBlock x:Name="lblSource" Text="Local Repository" FontSize="14" FontWeight="SemiBold" Foreground="$($Pal.WpfTextPrimary)"/></StackPanel>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right"><TextBlock Text="Status: " FontSize="14" Foreground="$($Pal.WpfTextMuted)"/><TextBlock x:Name="lblStatusTag" Text="Running" FontSize="14" FontWeight="SemiBold" Foreground="$($Pal.WpfTextPrimary)"/></StackPanel>
                </Grid>
            </Border>
        </Grid>
    </Window>
"@
    Build-WpfWindowFromXaml $xaml @("lblBrandTitle", "lblBrandSub", "lblDeployId", "lblComputerName", "lblComputerModel", "lblTargetOS", "lblCurrentStep", "lblStepSubtitle", "lblLogMessage", "lblOverallLabel", "lblSource", "lblStatusTag", "WpfStepProgressBar", "WpfOverallProgressBar")
}

# WinPE View XAML Template Builder
function Build-WpfWinPEWindow([hashtable]$Pal) {
    $xaml = @"
    <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
            Title="LiteDeploy Progress Host (WinPE)" Width="800" Height="450" ResizeMode="CanMinimize" UseLayoutRounding="True" SnapsToDevicePixels="True"
            RenderOptions.BitmapScalingMode="HighQuality" TextOptions.TextFormattingMode="Ideal" TextOptions.TextRenderingMode="ClearType" Background="$($Pal.WpfBgMain)" FontFamily="Segoe UI">
        <Grid>
            <Grid.RowDefinitions><RowDefinition Height="76"/><RowDefinition Height="*"/><RowDefinition Height="66"/></Grid.RowDefinitions>
            <Grid Grid.Row="0">
                <Grid.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#005A9E" Offset="0"/><GradientStop Color="#0078D4" Offset="1"/></LinearGradientBrush></Grid.Background>
                <StackPanel Orientation="Horizontal" Margin="24,0,24,0" VerticalAlignment="Center">
                    <Border Width="46" Height="46" CornerRadius="8" Background="#28FFFFFF" Margin="0,0,14,0"><TextBlock Text="LD" Foreground="White" FontWeight="Bold" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                    <StackPanel VerticalAlignment="Center">
                        <TextBlock x:Name="lblBrandTitle" Text="LiteDeploy" Foreground="White" FontSize="22" FontWeight="SemiBold"/>
                        <TextBlock x:Name="lblBrandSub" Text="Standard Workstation Workflow" Foreground="#D9EFFF" FontSize="14" Margin="0,2,0,0"/>
                    </StackPanel>
                </StackPanel>
            </Grid>
            <Grid Grid.Row="1" Margin="80,0,80,0" VerticalAlignment="Center">
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <TextBlock x:Name="lblTargetOS" Grid.Row="0" Text="Windows OS" FontSize="24" FontWeight="Bold" Foreground="$($Pal.WpfTextPrimary)" HorizontalAlignment="Center"/>
                <TextBlock x:Name="lblCurrentStep" Grid.Row="1" Text="Initializing Progress Host..." FontSize="15" Foreground="$($Pal.WpfTextSec)" HorizontalAlignment="Center" Margin="0,6,0,24"/>
                <ProgressBar x:Name="WpfOverallProgressBar" Grid.Row="2" Height="18" Minimum="0" Maximum="100" Value="0" Foreground="#0078D4" Background="$($Pal.WpfTrackBg)" BorderThickness="0"/>
                <TextBlock x:Name="lblPercent" Grid.Row="3" Text="0% Complete" FontSize="24" FontWeight="Bold" Foreground="$($Pal.WpfTextPrimary)" HorizontalAlignment="Center" Margin="0,20,0,6"/>
                <TextBlock x:Name="lblStepText" Grid.Row="4" Text="Action 1 of 1 • Starting Bare-Metal Deployment" FontSize="13" Foreground="$($Pal.WpfTextSec)" HorizontalAlignment="Center"/>
            </Grid>
            <Border Grid.Row="2" Background="$($Pal.WpfBgFooter)" BorderBrush="$($Pal.WpfBorder)" BorderThickness="0,1,0,0" Padding="20,0,20,0">
                <Grid VerticalAlignment="Center">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" HorizontalAlignment="Center"><TextBlock Text="DEPLOYMENT ID" FontSize="11" FontWeight="Bold" Foreground="$($Pal.WpfTextMuted)" HorizontalAlignment="Center"/><TextBlock x:Name="lblDeployId" Text="LD-000000-000" FontSize="14" FontWeight="Bold" Foreground="$($Pal.WpfTextPrimary)" Margin="0,2,0,0" HorizontalAlignment="Center"/></StackPanel>
                    <StackPanel Grid.Column="1" HorizontalAlignment="Center"><TextBlock Text="COMPUTER NAME" FontSize="11" FontWeight="Bold" Foreground="$($Pal.WpfTextMuted)" HorizontalAlignment="Center"/><TextBlock x:Name="lblComputerName" Text="DESKTOP-01" FontSize="14" FontWeight="Bold" Foreground="$($Pal.WpfTextPrimary)" Margin="0,2,0,0" HorizontalAlignment="Center"/></StackPanel>
                    <StackPanel Grid.Column="2" HorizontalAlignment="Center"><TextBlock Text="SOURCE" FontSize="11" FontWeight="Bold" Foreground="$($Pal.WpfTextMuted)" HorizontalAlignment="Center"/><TextBlock x:Name="lblSource" Text="Local Repository" FontSize="14" FontWeight="Bold" Foreground="$($Pal.WpfTextPrimary)" Margin="0,2,0,0" HorizontalAlignment="Center"/></StackPanel>
                </Grid>
            </Border>
        </Grid>
    </Window>
"@
    Build-WpfWindowFromXaml $xaml @("lblBrandTitle", "lblBrandSub", "lblTargetOS", "lblCurrentStep", "WpfOverallProgressBar", "lblPercent", "lblStepText", "lblDeployId", "lblComputerName", "lblSource")
}

function NonBlocking-Sleep([int]$Milliseconds) {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.ElapsedMilliseconds -lt $Milliseconds) {
        if ($script:IsClosing -or -not $script:WpfWindow) { break }
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
        Start-Sleep -Milliseconds 15
    }
}

# Synchronize UI Controls with State
function Sync-LiteDeployUI([hashtable]$State) {
    if ($script:IsClosing -or -not $script:WpfWindow) { return }
    $controlDict = $script:UIControls

    if (-not [string]::IsNullOrWhiteSpace($State.WindowTitle) -and $script:WpfWindow) {
        $script:WpfWindow.Title = $State.WindowTitle
    }

    if ($script:ActiveLayout -eq "WinPE") {
        if ($controlDict.ContainsKey("lblBrandTitle"))   { $controlDict["lblBrandTitle"].Text   = $State.ProductName }
        if ($controlDict.ContainsKey("lblBrandSub"))     { $controlDict["lblBrandSub"].Text     = $State.WorkflowName }
        if ($controlDict.ContainsKey("lblTargetOS"))     { $controlDict["lblTargetOS"].Text     = $State.OperatingSystem }
        if ($controlDict.ContainsKey("lblCurrentStep"))  { $controlDict["lblCurrentStep"].Text  = $State.Message }
        if ($controlDict.ContainsKey("lblPercent"))      { $controlDict["lblPercent"].Text      = "$($State.OverallPercent)% Complete" }
        if ($controlDict.ContainsKey("lblStepText"))     { $controlDict["lblStepText"].Text     = "Action $($State.StepNumber) of $($State.TotalSteps) $([char]0x2022) $($State.CurrentStep) ($($State.StepPercent)%)" }
        if ($controlDict.ContainsKey("lblDeployId"))      { $controlDict["lblDeployId"].Text      = $State.DeploymentId }
        if ($controlDict.ContainsKey("lblComputerName"))  { $controlDict["lblComputerName"].Text  = $State.ComputerName }
        if ($controlDict.ContainsKey("lblSource"))        { $controlDict["lblSource"].Text        = $State.Source }
        if ($controlDict.ContainsKey("WpfOverallProgressBar")) {
            $controlDict["WpfOverallProgressBar"].Value = $State.OverallPercent
            $controlDict["WpfOverallProgressBar"].Foreground = Get-StatusColor $State.Status
        }
    } else {
        if ($controlDict.ContainsKey("lblBrandTitle"))   { $controlDict["lblBrandTitle"].Text   = $State.ProductName }
        if ($controlDict.ContainsKey("lblBrandSub"))     { $controlDict["lblBrandSub"].Text     = $State.WorkflowName }
        if ($controlDict.ContainsKey("lblCurrentStep"))  { $controlDict["lblCurrentStep"].Text  = $State.Message }
        
        $phaseText = $State.CurrentStep
        if (-not [string]::IsNullOrWhiteSpace($State.Phase)) {
            $phaseText = $State.Phase
        }
        if ($controlDict.ContainsKey("lblStepSubtitle")) {
            $controlDict["lblStepSubtitle"].Text = "$phaseText ($($State.StepPercent)%)"
        }

        if ($controlDict.ContainsKey("lblTargetOS"))     { $controlDict["lblTargetOS"].Text     = $State.OperatingSystem }
        if ($controlDict.ContainsKey("lblLogMessage"))   { $controlDict["lblLogMessage"].Text   = $State.LogMessage }
        if ($controlDict.ContainsKey("lblOverallLabel")) { $controlDict["lblOverallLabel"].Text = "OVERALL PROGRESS (ACTION $($State.StepNumber) OF $($State.TotalSteps) $([char]0x2022) $($State.OverallPercent)%)" }
        if ($controlDict.ContainsKey("lblDeployId"))      { $controlDict["lblDeployId"].Text      = $State.DeploymentId }
        if ($controlDict.ContainsKey("lblComputerName"))  { $controlDict["lblComputerName"].Text  = $State.ComputerName }
        if ($controlDict.ContainsKey("lblComputerModel")) { $controlDict["lblComputerModel"].Text = $State.ComputerModel }
        if ($controlDict.ContainsKey("lblSource"))        { $controlDict["lblSource"].Text        = $State.Source }
        if ($controlDict.ContainsKey("lblStatusTag"))     { $controlDict["lblStatusTag"].Text     = $State.Status }

        if ($controlDict.ContainsKey("WpfStepProgressBar")) {
            $controlDict["WpfStepProgressBar"].Value = $State.StepPercent
            $controlDict["WpfStepProgressBar"].Foreground = Get-StatusColor $State.Status
        }
        if ($controlDict.ContainsKey("WpfOverallProgressBar")) {
            $controlDict["WpfOverallProgressBar"].Value = $State.OverallPercent
            $controlDict["WpfOverallProgressBar"].Foreground = Get-StatusColor $State.Status
        }
    }

    if ($script:WpfWindow -and -not $script:IsClosing) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    }
}

function Get-LiteDeployProgressProperty {
    param([object]$InputObject, [string]$Name, $Default = $null)
    if ($null -eq $InputObject) { return $Default }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    return $prop.Value
}

function Test-LiteDeployProgressHasProperty {
    param([object]$InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $false }
    return [bool]$InputObject.PSObject.Properties[$Name]
}

function Read-LiteDeployProgressStateJsonFromMemory {
    <#
    .SYNOPSIS
        Reads Engine-published DeploymentState JSON from the named RAM memory map.
    #>
    $mmf = $null
    $accessor = $null
    try {
        if (Get-Command Read-LiteDeployStateFromMemory -ErrorAction SilentlyContinue) {
            $fromApi = Read-LiteDeployStateFromMemory
            if (-not [string]::IsNullOrWhiteSpace($fromApi)) { return $fromApi }
        }

        $mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting($script:StateMemoryMapName)
        $accessor = $mmf.CreateViewAccessor(0, [long]$script:StateMemoryMapCapacity)
        $length = $accessor.ReadInt32(0)
        if ($length -le 0 -or $length -gt ($script:StateMemoryMapCapacity - 4)) { return "" }
        $buffer = New-Object byte[] $length
        $read = $accessor.ReadArray(4, $buffer, 0, $length)
        if ($read -le 0) { return "" }
        return [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    }
    catch {
        return ""
    }
    finally {
        if ($null -ne $accessor) { try { $accessor.Dispose() } catch {} }
        if ($null -ne $mmf) { try { $mmf.Dispose() } catch {} }
    }
}

function Read-LiteDeployProgressStateJsonFromFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }
    try {
        $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
        $jsonRaw = $sr.ReadToEnd()
        $sr.Dispose()
        $fs.Dispose()
        return $jsonRaw
    }
    catch {
        return ""
    }
}

# StrictMode-safe JSON reader: RAM map first, then file. Supports Engine DeploymentState + legacy camelCase.
function Get-DeploymentStateFromFile([string]$Path, [hashtable]$DefaultState) {
    $state = $DefaultState.Clone()
    $targetPath = $script:StatePath
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $targetPath = $Path
    }
    if (-not [System.IO.Path]::IsPathRooted($targetPath)) {
        $targetPath = [System.IO.Path]::GetFullPath((Join-Path $scriptDir $targetPath))
    }

    try {
        $jsonRaw = Read-LiteDeployProgressStateJsonFromMemory
        if ([string]::IsNullOrWhiteSpace($jsonRaw)) {
            $jsonRaw = Read-LiteDeployProgressStateJsonFromFile -Path $targetPath
        }
        if ([string]::IsNullOrWhiteSpace($jsonRaw)) { return $state }

        if ($jsonRaw -match '"Computer Model"') {
            $jsonRaw = $jsonRaw -replace '"Computer Model"\s*:', '"computerModel":'
        }

        $jsonData = $jsonRaw | ConvertFrom-Json
        if ($null -eq $jsonData) { return $state }

        $phaseNames = @{
            1 = "HardwarePreCheck"
            2 = "WorkflowSelection"
            3 = "DiskPreparation"
            4 = "OSInstallation"
            5 = "PostInstall"
        }

        if (Test-LiteDeployProgressHasProperty -InputObject $jsonData -Name "DeploymentUid") {
            # ---- Full Engine DeploymentState.json ----
            $state["DeploymentId"] = [string](Get-LiteDeployProgressProperty -InputObject $jsonData -Name "DeploymentUid" -Default "")

            $rawStatus = [string](Get-LiteDeployProgressProperty -InputObject $jsonData -Name "Status" -Default "")
            $state["RawStatus"] = $rawStatus
            $state["Status"] = Get-LiteDeployProgressUiStatus -RawStatus $rawStatus

            $phaseParsed = 0
            $phaseRaw = [string](Get-LiteDeployProgressProperty -InputObject $jsonData -Name "CurrentPhase" -Default "0")
            if ([int]::TryParse($phaseRaw, [ref]$phaseParsed) -and $phaseNames.ContainsKey($phaseParsed)) {
                $state["Phase"] = [string]$phaseNames[$phaseParsed]
                $state["StepNumber"] = $phaseParsed
                $state["TotalSteps"] = 5
            }

            $execution = Get-LiteDeployProgressProperty -InputObject $jsonData -Name "Execution"
            $step = [string](Get-LiteDeployProgressProperty -InputObject $execution -Name "CurrentStep" -Default "")
            if (-not [string]::IsNullOrWhiteSpace($step)) {
                $state["CurrentStep"] = $step
            }

            $percentParsed = 0
            $percentRaw = [string](Get-LiteDeployProgressProperty -InputObject $execution -Name "PercentComplete" -Default "")
            if ([int]::TryParse($percentRaw, [ref]$percentParsed)) {
                $state["OverallPercent"] = $percentParsed
                $state["StepPercent"] = $percentParsed
            }

            $errorList = @(Get-LiteDeployProgressProperty -InputObject $execution -Name "Errors" -Default @())
            $lastError = ""
            if ($errorList.Count -gt 0) {
                $lastError = [string]$errorList[$errorList.Count - 1]
            }

            if (Test-LiteDeployProgressTerminalFailure -RawStatus $rawStatus) {
                $state["Message"] = if ($lastError) { $lastError } elseif ($step) { $step } else { "Deployment failed." }
                $state["LogMessage"] = if ($lastError) { $lastError } else { "Status: $rawStatus" }
                $state["Status"] = "Failed"
            }
            elseif (Test-LiteDeployProgressTerminalSuccess -RawStatus $rawStatus) {
                $state["Message"] = if ($step) { $step } else { "Deployment completed." }
                $state["LogMessage"] = "Status: $rawStatus"
                $state["Status"] = "Completed"
            }
            else {
                $state["Message"] = if ($step) { $step } else { [string]$state["Phase"] }
                $state["LogMessage"] = if ($lastError) { $lastError } else { "Status: $rawStatus" }
            }

            $workflow = Get-LiteDeployProgressProperty -InputObject $jsonData -Name "Workflow"
            $selection = Get-LiteDeployProgressProperty -InputObject $workflow -Name "SelectionData"
            $workflowName = Get-LiteDeployProgressProperty -InputObject $selection -Name "WorkflowName"
            if ($null -ne $workflowName -and -not [string]::IsNullOrWhiteSpace([string]$workflowName)) {
                $state["WorkflowName"] = [string]$workflowName
                $state["OperatingSystem"] = [string]$workflowName
            }
            $computerName = Get-LiteDeployProgressProperty -InputObject $selection -Name "ComputerName"
            if ($null -ne $computerName -and -not [string]::IsNullOrWhiteSpace([string]$computerName)) {
                $state["ComputerName"] = [string]$computerName
            }

            $boot = Get-LiteDeployProgressProperty -InputObject $jsonData -Name "BootObject"
            if ($null -ne $boot) {
                $isWinPE = Get-LiteDeployProgressProperty -InputObject $boot -Name "IsWinPE"
                if ($null -ne $isWinPE) {
                    $state["Environment"] = if ([bool]$isWinPE) { "WinPE" } else { "FullOS" }
                }
                $deployType = [string](Get-LiteDeployProgressProperty -InputObject $boot -Name "DeploymentType" -Default "")
                if ($deployType -ieq "Network") { $state["Source"] = "Network Share" }
                elseif ($deployType -ieq "Media") { $state["Source"] = "Local (Media) Repository" }
            }

            if ([string]::IsNullOrWhiteSpace([string]$state["ProductName"])) {
                $state["ProductName"] = "LiteDeploy"
            }
        }
        else {
            # ---- Legacy camelCase progress schema ----
            $stateData = @{}
            $jsonData.PSObject.Properties | ForEach-Object { $stateData[$_.Name] = $_.Value }

            if ($stateData["windowTitle"])       { $state["WindowTitle"]     = [string]$stateData["windowTitle"] }
            if ($stateData["productName"])       { $state["ProductName"]     = [string]$stateData["productName"] }
            if ($stateData["workflowName"])      { $state["WorkflowName"]    = [string]$stateData["workflowName"] }
            if ($stateData["environment"])       { $state["Environment"]     = [string]$stateData["environment"] }
            if ($stateData["status"]) {
                $state["RawStatus"] = [string]$stateData["status"]
                $state["Status"] = Get-LiteDeployProgressUiStatus -RawStatus ([string]$stateData["status"])
            }
            if ($stateData["phase"])             { $state["Phase"]           = [string]$stateData["phase"] }
            if ($stateData["currentStep"])       { $state["CurrentStep"]     = [string]$stateData["currentStep"] }
            if ($stateData["message"])           { $state["Message"]         = [string]$stateData["message"] }
            if ($stateData["logMessage"])        { $state["LogMessage"]      = [string]$stateData["logMessage"] }
            if ($null -ne $stateData["stepPercent"])    { $state["StepPercent"]    = [int]$stateData["stepPercent"] }
            if ($null -ne $stateData["overallPercent"]) { $state["OverallPercent"] = [int]$stateData["overallPercent"] }
            if ($stateData["deploymentId"])      { $state["DeploymentId"]    = [string]$stateData["deploymentId"] }
            elseif ($stateData["DeploymentID"])  { $state["DeploymentId"]    = [string]$stateData["DeploymentID"] }
            if ($stateData["computerName"])      { $state["ComputerName"]    = [string]$stateData["computerName"] }
            if ($stateData["computerModel"])     { $state["ComputerModel"]   = [string]$stateData["computerModel"] }
            if ($stateData["operatingSystem"])   { $state["OperatingSystem"] = [string]$stateData["operatingSystem"] }
            if ($stateData["source"])            { $state["Source"]          = [string]$stateData["source"] }
            elseif ($stateData["repository"])    { $state["Source"]          = [string]$stateData["repository"] }

            if ($stateData["overallText"] -and $stateData["overallText"] -match '(?:Action|Step)\s+(\d+)\s+of\s+(\d+)') {
                $state["StepNumber"] = [int]$Matches[1]
                $state["TotalSteps"] = [int]$Matches[2]
            }
        }
    }
    catch {}

    return $state
}

# Initial baseline UI state
$initialEnv = "FullOS"
if ($Environment -ne "Auto") {
    $initialEnv = $Environment
}

$UIState = @{
    WindowTitle     = $WindowTitle
    ProductName     = "LiteDeploy"
    WorkflowName    = "Standard Workstation Workflow"
    Environment     = $initialEnv
    Status          = "Running"
    RawStatus       = "Running"
    Phase           = "Initializing"
    CurrentStep     = "Starting Deployment"
    Message         = "Initializing Progress Host..."
    StepNumber      = 1
    TotalSteps      = 5
    StepPercent     = 0
    OverallPercent  = 0
    LogMessage      = "Waiting for deployment state..."
    DeploymentId    = "LD-000000-000"
    ComputerName    = $env:COMPUTERNAME
    ComputerModel   = "Standard PC"
    OperatingSystem = "Windows OS"
    Source          = "Deployment Repository"
}

if (Test-Path $script:StatePath -PathType Leaf) {
    $UIState = Get-DeploymentStateFromFile $script:StatePath $UIState
}

# Build Layout Window
if ($Environment -eq "WinPE" -or ($Environment -eq "Auto" -and $UIState.Environment -eq "WinPE")) {
    $script:ActiveLayout = "WinPE"
    Build-WpfWinPEWindow $Palette
} else {
    $script:ActiveLayout = "FullOS"
    Build-WpfFullOSWindow $Palette
}

if (-not [string]::IsNullOrWhiteSpace($WindowTitle)) {
    $script:WpfWindow.Title = $WindowTitle
}
if ($TopMost -eq "On") {
    $script:WpfWindow.Topmost = $true
}

if ($ShowBackdrop) {
    $script:WpfWindow.add_Closed({
        if ($script:BackdropForm -and -not $script:BackdropForm.IsDisposed) {
            $script:BackdropForm.Close()
        }
    })
}

$script:IsClosing = $false
$script:WpfWindow.add_Closing({
    $script:IsClosing = $true
    if ($script:BackdropForm -and -not $script:BackdropForm.IsDisposed) {
        $script:BackdropForm.Close()
    }
})

$script:WpfWindow.Show()
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

Sync-LiteDeployUI -State $UIState

# Active Host Monitoring Loop
# Success (Completed / OSImageApplied) auto-closes unless -KeepOpen.
# Failure (Failed / Cancelled) stays open so the technician can see the fault.
# State source: RAM memory-map (preferred) then SystemDrive DeploymentState.json.
while ($script:WpfWindow -and -not $script:IsClosing) {
    $UIState = Get-DeploymentStateFromFile $script:StatePath $UIState
    Sync-LiteDeployUI -State $UIState

    $rawStatus = if ($UIState.ContainsKey("RawStatus") -and $UIState["RawStatus"]) {
        [string]$UIState["RawStatus"]
    } else {
        [string]$UIState["Status"]
    }

    if ((Test-LiteDeployProgressTerminalSuccess -RawStatus $rawStatus) -and -not $KeepOpen) {
        NonBlocking-Sleep -Milliseconds 2000
        break
    }

    NonBlocking-Sleep -Milliseconds 250
}

if (-not $KeepOpen -and $script:WpfWindow) {
    $rawClose = if ($UIState.ContainsKey("RawStatus") -and $UIState["RawStatus"]) {
        [string]$UIState["RawStatus"]
    } else {
        [string]$UIState["Status"]
    }
    # Never auto-dismiss a failure window.
    if (-not (Test-LiteDeployProgressTerminalFailure -RawStatus $rawClose)) {
        try { $script:WpfWindow.Close() } catch {}
    }
}
