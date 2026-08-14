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

.EXAMPLE
    .\LiteDeploy.Progress.ps1 -Environment FullOS -Theme Light

.EXAMPLE
    .\LiteDeploy.Progress.ps1 -Environment WinPE -Theme Dark -KeepOpen
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
    [switch]$KeepOpen
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Absolute StatePath Resolution (PowerShell 5.1 Compatible Syntax)
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $scriptDir = [System.IO.Path]::GetDirectoryName($PSCommandPath)
    } else {
        $scriptDir = [System.Environment]::CurrentDirectory
    }
}

$targetStateFile = "DeploymentState.json"
if (-not [string]::IsNullOrWhiteSpace($StatePath)) {
    $targetStateFile = $StatePath
}
if (-not [System.IO.Path]::IsPathRooted($targetStateFile)) {
    $targetStateFile = Join-Path $scriptDir $targetStateFile
}
$script:StatePath = [System.IO.Path]::GetFullPath($targetStateFile)

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
        Start-Process -FilePath "powershell.exe" -ArgumentList $argList -WorkingDirectory $scriptDir -WindowStyle Normal
        return
    }
}

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
    "Warning"   = "#D97706"
    "Running"   = "#0078D4"
    "Pending"   = "#CBD5E1"
}

function Get-StatusColor([string]$StatusName) {
    $hex = "#0078D4"
    if ($script:StatusHexMap.ContainsKey($StatusName)) {
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
                        <StackPanel Margin="0,0,0,22"><TextBlock Text="COMPUTER NAME" FontSize="11" FontWeight="Bold" Foreground="$($Pal.WpfTextMuted)"/><TextBlock x:Name="lblComputerName" Text="X1-DESKTOP01" FontSize="15" FontWeight="SemiBold" Foreground="$($Pal.WpfTextPrimary)" Margin="0,3,0,0"/></StackPanel>
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
                    <StackPanel Grid.Column="1" HorizontalAlignment="Center"><TextBlock Text="COMPUTER NAME" FontSize="11" FontWeight="Bold" Foreground="$($Pal.WpfTextMuted)" HorizontalAlignment="Center"/><TextBlock x:Name="lblComputerName" Text="X1-DESKTOP01" FontSize="14" FontWeight="Bold" Foreground="$($Pal.WpfTextPrimary)" Margin="0,2,0,0" HorizontalAlignment="Center"/></StackPanel>
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

# StrictMode Safe JSON Reader
function Get-DeploymentStateFromFile([string]$Path, [hashtable]$DefaultState) {
    $state = $DefaultState.Clone()
    $targetPath = $script:StatePath
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $targetPath = $Path
    }
    if (-not [System.IO.Path]::IsPathRooted($targetPath)) {
        $targetPath = [System.IO.Path]::GetFullPath((Join-Path $scriptDir $targetPath))
    }

    if (Test-Path $targetPath -PathType Leaf) {
        try {
            $fs = [System.IO.FileStream]::new($targetPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
            $jsonRaw = $sr.ReadToEnd(); $sr.Dispose(); $fs.Dispose()

            if (-not [string]::IsNullOrWhiteSpace($jsonRaw)) {
                if ($jsonRaw -match '"Computer Model"') {
                    $jsonRaw = $jsonRaw -replace '"Computer Model"\s*:', '"computerModel":'
                }
                $jsonData = $jsonRaw | ConvertFrom-Json
                $stateData = @{}
                $jsonData.PSObject.Properties | ForEach-Object { $stateData[$_.Name] = $_.Value }

                if ($stateData['windowTitle'])       { $state.WindowTitle     = [string]$stateData['windowTitle'] }
                if ($stateData['productName'])       { $state.ProductName     = [string]$stateData['productName'] }
                if ($stateData['workflowName'])      { $state.WorkflowName    = [string]$stateData['workflowName'] }
                if ($stateData['environment'])       { $state.Environment     = [string]$stateData['environment'] }
                if ($stateData['status'])            { $state.Status          = [string]$stateData['status'] }
                if ($stateData['phase'])             { $state.Phase           = [string]$stateData['phase'] }
                if ($stateData['currentStep'])       { $state.CurrentStep     = [string]$stateData['currentStep'] }
                if ($stateData['message'])           { $state.Message         = [string]$stateData['message'] }
                if ($stateData['logMessage'])        { $state.LogMessage      = [string]$stateData['logMessage'] }
                if ($null -ne $stateData['stepPercent'])    { $state.StepPercent    = [int]$stateData['stepPercent'] }
                if ($null -ne $stateData['overallPercent']) { $state.OverallPercent = [int]$stateData['overallPercent'] }
                if ($stateData['deploymentId'])      { $state.DeploymentId    = [string]$stateData['deploymentId'] }
                elseif ($stateData['DeploymentID'])  { $state.DeploymentId    = [string]$stateData['DeploymentID'] }
                if ($stateData['computerName'])      { $state.ComputerName    = [string]$stateData['computerName'] }
                if ($stateData['computerModel'])     { $state.ComputerModel   = [string]$stateData['computerModel'] }
                if ($stateData['operatingSystem'])   { $state.OperatingSystem = [string]$stateData['operatingSystem'] }
                if ($stateData['source'])            { $state.Source          = [string]$stateData['source'] }
                elseif ($stateData['repository'])    { $state.Source          = [string]$stateData['repository'] }

                if ($stateData['overallText'] -and $stateData['overallText'] -match '(?:Action|Step)\s+(\d+)\s+of\s+(\d+)') {
                    $state.StepNumber = [int]$Matches[1]
                    $state.TotalSteps = [int]$Matches[2]
                }
            }
        } catch {}
    }
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
    Phase           = "Initializing"
    CurrentStep     = "Starting Deployment"
    Message         = "Initializing Progress Host..."
    StepNumber      = 1
    TotalSteps      = 1
    StepPercent     = 0
    OverallPercent  = 0
    LogMessage      = "Waiting for task sequence state..."
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
while ($script:WpfWindow -and -not $script:IsClosing) {
    if (Test-Path $script:StatePath -PathType Leaf) {
        $UIState = Get-DeploymentStateFromFile $script:StatePath $UIState
        Sync-LiteDeployUI -State $UIState
    }

    if ($UIState.Status -eq "Completed" -and -not $KeepOpen) {
        NonBlocking-Sleep -Milliseconds 2000
        break
    }

    NonBlocking-Sleep -Milliseconds 250
}

if (-not $KeepOpen -and $script:WpfWindow) {
    try { $script:WpfWindow.Close() } catch {}
}
