<#
.SYNOPSIS
    WPF Hardware PreCheck for LiteDeploy (BootConfigPath + inventory) - single-file variant.
.DESCRIPTION
    Same readiness wizard as the separated production script, with WPF markup inlined in
    this .ps1. Lives under SingleFile\ for side-by-side comparison. Not Engine-wired.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$BootConfigPath = "",

    # Optional in-memory cache from Engine. Path remains mandatory for STA/F5/audit.
    # First paint uses object when present; Run Again / F5 always reload from BootConfigPath.
    [psobject]$BootConfig = $null,

    [string]$DeploymentShare = "",
    [int]$MaxNetworkWaitSeconds = 30,
    [int]$NetworkPollMilliseconds = 500,
    [int]$SmbConnectTimeoutMilliseconds = 2000,
    [int]$MinDiskSizeGB = 32,
    [int]$MinMemoryGB = 4,
    [bool]$HaltOnFailure = $true,
    [ValidateSet("Light", "Dark")][string]$Theme = "Light",
    [ValidateSet("On", "Off")][string]$TopMost = "On",
    # Do NOT name this $Metadata — BootConfig has a Metadata object and $metadata =
    # assignments collide with the optimized parameter (PS is case-insensitive).
    [Alias("Metadata")]
    [switch]$GetComponentMetadata
)

# ==============================================================================
# COMPONENT METADATA
# ==============================================================================

function Get-LiteDeployComponentMetadata {
    return [PSCustomObject]@{
        ComponentId          = "HardwarePreCheck"
        Name                 = "LiteDeploy Hardware PreCheck"
        Version              = "1.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "WinPE"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("LogWriter", "Hardware")
        Description          = "Single-file (inlined XAML) PreCheck variant. Production uses separated .ps1 + .xaml."
    }
}

$script:ComponentMetadata = Get-LiteDeployComponentMetadata

if ($GetComponentMetadata) {
    $script:ComponentMetadata
    return
}

if ([string]::IsNullOrWhiteSpace($BootConfigPath)) {
    throw "LiteDeploy.HardwarePreCheck.ps1 requires -BootConfigPath."
}

# ------------------------------------------------------------------------------
# 1. STA MODE & WPF ASSEMBLY LOAD
# ------------------------------------------------------------------------------
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path $powershellExe)) { $powershellExe = "powershell.exe" }
    # Named params are not in $args — rebuild so -BootConfigPath survives relaunch.
    $relaunch = @(
        "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass",
        "-File", $PSCommandPath,
        "-BootConfigPath", $BootConfigPath
    )
    if ($DeploymentShare) { $relaunch += @("-DeploymentShare", $DeploymentShare) }
    if ($GetComponentMetadata) { $relaunch += "-GetComponentMetadata" }
    # Theme is resolved from BootConfig in the STA child when not forced here.
    if ($PSBoundParameters.ContainsKey("Theme")) { $relaunch += @("-Theme", $Theme) }
    & $powershellExe @relaunch
    return
}

try { [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly } catch {}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# Import Hardware only if not already loaded (e.g. DeploymentEngine imported it first).
# Flat Runtime / DeploymentShare layout only: LiteDeploy.Hardware.ps1 beside this script.
if (-not (Get-Command Get-HardwareInventory -ErrorAction SilentlyContinue)) {
    $hardwareModule = Join-Path $PSScriptRoot "LiteDeploy.Hardware.ps1"
    if (-not (Test-Path -LiteralPath $hardwareModule -PathType Leaf)) {
        throw "LiteDeploy.Hardware.ps1 was not found beside PreCheck (flat Runtime layout)."
    }
    Import-Module -Name $hardwareModule -Force
}
# Keep PreCheck metadata on $script:ComponentMetadata (import may overwrite Get-LiteDeployComponentMetadata).

$script:BootConfigPath = $BootConfigPath
$script:PassedBootConfig = $BootConfig
$script:UsePassedBootConfigOnce = ($null -ne $BootConfig)

function Get-EffectiveBootConfig {
    param([switch]$ForceReload)

    if (-not $ForceReload -and $script:UsePassedBootConfigOnce -and $null -ne $script:PassedBootConfig) {
        $script:UsePassedBootConfigOnce = $false
        return $script:PassedBootConfig
    }

    if (-not (Test-Path -LiteralPath $script:BootConfigPath -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $script:BootConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        throw
    }
}

# Resolve theme before XAML is built (colors are baked into the markup).
# Precedence: explicit -Theme param > BootConfig.Ui.Theme > Light.
# Peek only — do not consume the one-shot optional -BootConfig object.
$themeExplicit = $PSBoundParameters.ContainsKey("Theme")
if (-not $themeExplicit) {
    try {
        $bootForTheme = $null
        if ($null -ne $script:PassedBootConfig) {
            $bootForTheme = $script:PassedBootConfig
        }
        elseif (Test-Path -LiteralPath $script:BootConfigPath -PathType Leaf) {
            $bootForTheme = Get-Content -LiteralPath $script:BootConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        $uiTheme = $null
        if ($bootForTheme -and $bootForTheme.PSObject.Properties["Ui"] -and $bootForTheme.Ui) {
            if ($bootForTheme.Ui.PSObject.Properties["Theme"] -and $bootForTheme.Ui.Theme) {
                $uiTheme = [string]$bootForTheme.Ui.Theme
            }
        }
        if ($uiTheme) {
            switch -Regex ($uiTheme.Trim()) {
                '^(?i)light$' { $Theme = "Light" }
                '^(?i)dark$'  { $Theme = "Dark" }
            }
        }
    }
    catch {
        # Keep param/default Theme if BootConfig cannot be read yet.
    }
}

# ------------------------------------------------------------------------------
# 2. ADAPTIVE WINDOW SIZE & THEME PALETTE
# ------------------------------------------------------------------------------
$screenWidth = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
$screenHeight = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height
$targetHeight = [Math]::Min(840, [Math]::Max(500, [int]($screenHeight * 0.70)))
$targetWidth = [int]($targetHeight * (800 / 600))

$isDark = ($Theme -eq "Dark")
$bgColor = if ($isDark) { "#121212" } else { "#FFFFFF" }
$fgColor = if ($isDark) { "#F3F4F6" } else { "#111827" }
$secFgColor = if ($isDark) { "#9CA3AF" } else { "#4B5563" }
$mutedFgColor = if ($isDark) { "#9CA3AF" } else { "#687684" }
$surfaceBg = if ($isDark) { "#1E1E1E" } else { "#F7F9FB" }
$footerBg = if ($isDark) { "#181818" } else { "#F7F9FB" }
$headerBg = if ($isDark) { "#2A2A2A" } else { "#F3F4F6" }
$headerFg = if ($isDark) { "#E5E7EB" } else { "#374151" }
$borderColor = if ($isDark) { "#333333" } else { "#D9E0E7" }
$buttonBg = if ($isDark) { "#2A2A2A" } else { "#FFFFFF" }
$buttonFg = if ($isDark) { "#F3F4F6" } else { "#1F2937" }
$buttonHoverBg = if ($isDark) { "#383838" } else { "#F3F4F6" }
$buttonPressedBg = if ($isDark) { "#404040" } else { "#E5E7EB" }
$trackBg = if ($isDark) { "#2D2D2D" } else { "#E6EBF0" }
$headerColor = if ($isDark) { "#3B82F6" } else { "#005A9E" }
$primaryHoverBg = if ($isDark) { "#2563EB" } else { "#0078D4" }
$primaryPressedBg = if ($isDark) { "#1D4ED8" } else { "#004E8C" }
$disabledBg = if ($isDark) { "#262626" } else { "#F3F4F6" }
$disabledBorder = if ($isDark) { "#333333" } else { "#E5E7EB" }
$disabledFg = if ($isDark) { "#6B7280" } else { "#9CA3AF" }

# ------------------------------------------------------------------------------
# 3. WPF XAML INTERFACE
# ------------------------------------------------------------------------------
$componentVersion = [string]$script:ComponentMetadata.Version
$componentName = [string]$script:ComponentMetadata.Name
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$componentName v$componentVersion"
        WindowState="Normal" WindowStyle="SingleBorderWindow"
        ResizeMode="NoResize" Width="$targetWidth" Height="$targetHeight"
        WindowStartupLocation="CenterScreen" Background="$bgColor">

    <Window.Resources>
        <Style x:Key="DataGridHeaderStyle" TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="$headerBg"/><Setter Property="Foreground" Value="$headerFg"/>
            <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="FontSize" Value="11"/>
            <Setter Property="Padding" Value="10,6"/><Setter Property="BorderThickness" Value="0,0,0,1"/>
            <Setter Property="BorderBrush" Value="$borderColor"/>
        </Style>

        <Style x:Key="DataGridRowStyle" TargetType="DataGridRow">
            <Setter Property="Background" Value="$surfaceBg"/><Setter Property="Foreground" Value="$fgColor"/>
            <Setter Property="BorderThickness" Value="0,0,0,1"/><Setter Property="BorderBrush" Value="$borderColor"/>
            <Setter Property="Focusable" Value="False"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="$buttonHoverBg"/></Trigger>
                <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="$surfaceBg"/><Setter Property="Foreground" Value="$fgColor"/></Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="DataGridCellStyle" TargetType="DataGridCell">
            <Setter Property="BorderThickness" Value="0"/><Setter Property="Focusable" Value="False"/>
            <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="$fgColor"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="$fgColor"/>
                    <Setter Property="BorderBrush" Value="Transparent"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="ModernProgressBarStyle" TargetType="ProgressBar">
            <Setter Property="Height" Value="10"/><Setter Property="Background" Value="$trackBg"/>
            <Setter Property="Foreground" Value="#0078D4"/><Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Grid x:Name="TemplateRoot">
                            <Border x:Name="PART_Track" Background="{TemplateBinding Background}" CornerRadius="5"/>
                            <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" CornerRadius="5" HorizontalAlignment="Left"/>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="PrimaryButtonStyle" TargetType="Button">
            <Setter Property="Background" Value="$headerColor"/><Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="$headerColor"/><Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="12"/><Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="24,7"/><Setter Property="Cursor" Value="Hand"/>
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
            <Setter Property="Background" Value="$buttonBg"/><Setter Property="Foreground" Value="$buttonFg"/>
            <Setter Property="BorderBrush" Value="$borderColor"/><Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="11.5"/><Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="16,6"/><Setter Property="Cursor" Value="Hand"/>
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
    </Window.Resources>

    <Viewbox Stretch="Fill">
        <Border Width="800" Height="600" Padding="0">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="78"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="60"/>
                </Grid.RowDefinitions>

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
                            <TextBlock Name="TxtDeviceIdentity" Text="Loading device information..." Foreground="White" FontSize="14" FontWeight="SemiBold"
                                       TextAlignment="Right" TextTrimming="CharacterEllipsis"/>
                            <TextBlock Name="TxtDeviceSerial" Text="" Foreground="#D9EFFF" FontSize="12"
                                       TextAlignment="Right" TextTrimming="CharacterEllipsis" Visibility="Collapsed"/>
                        </StackPanel>
                    </Grid>
                </Border>

                <Grid Grid.Row="1" Margin="30,8,30,6">
                    <Grid Name="Page1" Visibility="Visible">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Text="Hardware PreCheck" FontSize="16" FontWeight="Bold" Foreground="$fgColor" HorizontalAlignment="Center" Margin="0,0,0,2"/>
                        <TextBlock Grid.Row="1" Name="TxtMessage" Text="Initializing environment and discovering configuration..." FontSize="11.5" Foreground="$secFgColor" HorizontalAlignment="Center" Margin="0,0,0,6"/>
                        <ProgressBar Grid.Row="2" Name="ProgressBarPreCheck" Style="{StaticResource ModernProgressBarStyle}" Minimum="0" Maximum="100" Value="5" Margin="20,0,20,4"/>
                        <TextBlock Grid.Row="3" Name="TxtPercent" Text="0% Complete" FontSize="13" FontWeight="Bold" Foreground="$fgColor" HorizontalAlignment="Center" Margin="0,0,0,6"/>
                        <TextBlock Grid.Row="4" Text="PRECHECK RESULTS" FontSize="10.5" FontWeight="Bold" Foreground="$mutedFgColor" Margin="0,0,0,4"/>
                        <DataGrid Grid.Row="5" Name="GridPreCheckResults" AutoGenerateColumns="False" HeadersVisibility="Column" GridLinesVisibility="None" Background="$surfaceBg" BorderBrush="$borderColor" BorderThickness="1" RowHeight="25" SelectionMode="Single" IsReadOnly="True" CanUserResizeColumns="False" Focusable="False" Margin="0,0,0,8" ColumnHeaderStyle="{StaticResource DataGridHeaderStyle}" RowStyle="{StaticResource DataGridRowStyle}" CellStyle="{StaticResource DataGridCellStyle}">
                            <DataGrid.Columns>
                                <DataGridTemplateColumn Header="STATUS" Width="85">
                                    <DataGridTemplateColumn.CellTemplate>
                                        <DataTemplate>
                                            <Border Background="{Binding StatusBg}" CornerRadius="3" Padding="6,2" Margin="3,1" HorizontalAlignment="Center">
                                                <TextBlock Text="{Binding Status}" Foreground="{Binding StatusFg}" FontWeight="Bold" FontSize="11" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                            </Border>
                                        </DataTemplate>
                                    </DataGridTemplateColumn.CellTemplate>
                                </DataGridTemplateColumn>
                                <DataGridTextColumn Header="CHECK" Binding="{Binding Check}" Width="230"/>
                                <DataGridTextColumn Header="DETAILS" Binding="{Binding Details}" Width="*"/>
                            </DataGrid.Columns>
                        </DataGrid>
                        <Border Grid.Row="6" Name="BannerStatus" Background="$surfaceBg" BorderBrush="$borderColor" BorderThickness="1" CornerRadius="4" Padding="12,8">
                            <TextBlock Name="TxtStatusBanner" Text="DEVICE PRECHECK IS RUNNING..." FontSize="12" FontWeight="Bold" Foreground="#0078D4" HorizontalAlignment="Center"/>
                        </Border>
                    </Grid>
                </Grid>

                <Border Grid.Row="2" Background="$footerBg" Padding="20,12" BorderBrush="$borderColor" BorderThickness="0,1,0,0">
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Name="TxtConfigSource" Text="Configuration: Discovering..." FontSize="11" Foreground="$mutedFgColor" VerticalAlignment="Center"/>
                        <StackPanel Grid.Column="1" Orientation="Horizontal">
                            <Button Name="BtnDiagnostics" Content="Open CMD" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,10,0"/>
                            <Button Name="BtnRunAgain" Content="Run Again" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,10,0"/>
                            <Button Name="BtnContinue" Content="Continue" MinWidth="110" Style="{StaticResource PrimaryButtonStyle}"/>
                        </StackPanel>
                    </Grid>
                </Border>
            </Grid>
        </Border>
    </Viewbox>
</Window>
"@

# ------------------------------------------------------------------------------
# 4. LOAD XAML SAFELY & MAP CONTROLS
# ------------------------------------------------------------------------------
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)
if ($null -eq $window) { return $false }

if ($TopMost -eq "On") { $window.Topmost = $true }
# Map controls
$txtBrand = $window.FindName("TxtBrand")
$txtSubtitle = $window.FindName("TxtSubtitle")
$txtDeviceIdentity = $window.FindName("TxtDeviceIdentity")
$txtDeviceSerial = $window.FindName("TxtDeviceSerial")
$txtMessage = $window.FindName("TxtMessage")
$txtPercent = $window.FindName("TxtPercent")
$txtConfigSource = $window.FindName("TxtConfigSource")
$txtStatusBanner = $window.FindName("TxtStatusBanner")
$bannerStatus = $window.FindName("BannerStatus")
$progressBarPreCheck = $window.FindName("ProgressBarPreCheck")
$gridPreCheckResults = $window.FindName("GridPreCheckResults")
$btnDiagnostics = $window.FindName("BtnDiagnostics")
$btnRunAgain = $window.FindName("BtnRunAgain")
$btnContinue = $window.FindName("BtnContinue")

$script:Summary = New-Object System.Collections.Generic.List[object]
$script:ShareWasSpecified = $PSBoundParameters.ContainsKey("DeploymentShare")
$script:PreCheckPassed = $true
$script:Inventory = $null
$script:InventoryState = [ordered]@{
    BootConfigPath   = $BootConfigPath
    DeploymentMode   = $null
    NetworkPath      = $null
    NetworkAdapter   = $null
    IpAddress        = $null
    DeploymentServer = $null
    Disks            = @()
    MemoryGB         = $null
    FirmwareType     = $null
    SecureBoot       = $null
    TpmPresent       = $null
    TpmVersion       = $null
    TpmState         = $null
    RequireTpm       = $false
    SkippedByPolicy  = $false
}

# ------------------------------------------------------------------------------
# 5. ASSESSMENT HELPERS & TEST FUNCTIONS
# ------------------------------------------------------------------------------
function Invoke-UiPump {
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Render)
}

function Reset-InventoryState {
    $script:InventoryState.BootConfigPath = $BootConfigPath
    $script:InventoryState.DeploymentMode = $null
    $script:InventoryState.NetworkPath = $null
    $script:InventoryState.NetworkAdapter = $null
    $script:InventoryState.IpAddress = $null
    $script:InventoryState.DeploymentServer = $null
    $script:InventoryState.Disks = @()
    $script:InventoryState.MemoryGB = $null
    $script:InventoryState.FirmwareType = $null
    $script:InventoryState.SecureBoot = $null
    $script:InventoryState.TpmPresent = $null
    $script:InventoryState.TpmVersion = $null
    $script:InventoryState.TpmState = $null
    $script:InventoryState.RequireTpm = $false
    $script:InventoryState.SkippedByPolicy = $false
}

function Set-PreCheckBanner {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Passed", "Failed", "Skipped")]
        [string]$Outcome
    )
    # Reach 100% only with the final outcome so the bar does not sit full while still blue.
    switch ($Outcome) {
        "Passed" {
            Set-PreCheckProgress 100 "Device PreCheck Completed."
            $progressBarPreCheck.Foreground = Brush $(if ($isDark) { "#4ADE80" } else { "#107C10" })
            $txtStatusBanner.Text = "DEVICE READY FOR IMAGE DEPLOYMENT"
            $bannerStatus.Background = Brush $(if ($isDark) { "#163820" } else { "#EAF6EA" })
            $bannerStatus.BorderBrush = Brush $(if ($isDark) { "#225431" } else { "#C6E7C6" })
            $txtStatusBanner.Foreground = Brush $(if ($isDark) { "#4ADE80" } else { "#107C10" })
            $btnContinue.IsEnabled = $true
            $btnContinue.Content = "Continue"
        }
        "Failed" {
            Set-PreCheckProgress 100 "Device PreCheck Completed."
            $progressBarPreCheck.Foreground = Brush $(if ($isDark) { "#F87171" } else { "#D13438" })
            $txtStatusBanner.Text = "DEVICE PRECHECK FOUND ISSUES"
            $bannerStatus.Background = Brush $(if ($isDark) { "#3E1719" } else { "#FDECEC" })
            $bannerStatus.BorderBrush = Brush $(if ($isDark) { "#642225" } else { "#FACDCD" })
            $txtStatusBanner.Foreground = Brush $(if ($isDark) { "#F87171" } else { "#D13438" })
            $btnContinue.Content = "Continue"
            $btnContinue.IsEnabled = (-not $HaltOnFailure)
        }
        "Skipped" {
            Set-PreCheckProgress 100 "Device PreCheck Skipped."
            $txtStatusBanner.Text = "DEVICE PRECHECK SKIPPED BY POLICY"
            $bannerStatus.Background = Brush $(if ($isDark) { "#2D2410" } else { "#FFF7E0" })
            $txtStatusBanner.Foreground = Brush "#D97706"
            $btnContinue.IsEnabled = $true
            $btnContinue.Content = "Continue"
        }
    }
    Invoke-UiPump
}

function Update-PreCheckDeviceIdentity {
    $vendor = $null
    $model = $null
    $serial = $null
    $sku = $null

    if ($script:Inventory) {
        # Prefer raw OEM string for the header; fall back to normalized Vendor.
        if ($script:Inventory.PSObject.Properties["VendorRaw"] -and $script:Inventory.VendorRaw) {
            $vendor = $script:Inventory.VendorRaw
        }
        else {
            $vendor = $script:Inventory.Vendor
        }
        $model = $script:Inventory.Model
        $serial = $script:Inventory.SerialNumber
        $sku = $script:Inventory.Sku
    }
    else {
        try { $vendor = Get-HardwareVendorRaw } catch {}
        try { $model = Get-HardwareModel } catch {}
        try { $serial = Get-HardwareSerialNumber } catch {}
        try { $sku = Get-HardwareComputerSku } catch {}
    }

    $identityParts = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$vendor)) { $identityParts += ([string]$vendor).Trim() }
    if (-not [string]::IsNullOrWhiteSpace([string]$model)) { $identityParts += "Model: $(([string]$model).Trim())" }
    $device = $identityParts -join " / "
    $hasDevice = -not [string]::IsNullOrWhiteSpace($device)
    $hasSerial = -not [string]::IsNullOrWhiteSpace([string]$serial)
    $hasSku = -not [string]::IsNullOrWhiteSpace([string]$sku)

    $detailParts = @()
    if ($hasSerial) { $detailParts += "Serial: $serial" }
    if ($hasSku) { $detailParts += "SKU: $sku" }
    $detailLine = $detailParts -join " / "
    $hasDetail = $detailParts.Count -gt 0

    if ($null -eq $txtDeviceIdentity) { return }

    if (-not $hasDevice -and -not $hasDetail) {
        # While inventory is still building, show loading — not "unavailable".
        $emptyText = if ($script:Inventory) {
            "Device information: unavailable"
        } else {
            "Loading device information..."
        }
        $txtDeviceIdentity.Text = $emptyText
        $txtDeviceIdentity.ToolTip = $emptyText
        if ($null -ne $txtDeviceSerial) {
            $txtDeviceSerial.Text = ""
            $txtDeviceSerial.ToolTip = $null
            $txtDeviceSerial.Visibility = [System.Windows.Visibility]::Collapsed
        }
    }
    elseif ($hasDevice) {
        # Primary = raw manufacturer / Model:, secondary = Serial: / SKU:
        $txtDeviceIdentity.Text = $device
        $txtDeviceIdentity.ToolTip = $device
        if ($null -ne $txtDeviceSerial) {
            if ($hasDetail) {
                $txtDeviceSerial.Text = $detailLine
                $txtDeviceSerial.ToolTip = $detailLine
                $txtDeviceSerial.Visibility = [System.Windows.Visibility]::Visible
            }
            else {
                $txtDeviceSerial.Text = ""
                $txtDeviceSerial.ToolTip = $null
                $txtDeviceSerial.Visibility = [System.Windows.Visibility]::Collapsed
            }
        }
    }
    else {
        # Serial/SKU only — promote to primary line
        $txtDeviceIdentity.Text = $detailLine
        $txtDeviceIdentity.ToolTip = $detailLine
        if ($null -ne $txtDeviceSerial) {
            $txtDeviceSerial.Text = ""
            $txtDeviceSerial.ToolTip = $null
            $txtDeviceSerial.Visibility = [System.Windows.Visibility]::Collapsed
        }
    }

    Invoke-UiPump
}

function Brush([string]$Color) {
    [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function Property($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $null }
}

function Add-Result([string]$Message, [string]$Status = "INFO") {
    $parts = $Message.Split(":", 2)
    $fg = switch ($Status) {
        "OK" { if ($isDark) { "#4ADE80" } else { "#107C10" } }
        "FAIL" { if ($isDark) { "#F87171" } else { "#D13438" } }
        "WARN" { if ($isDark) { "#FBBF24" } else { "#D97706" } }
        default { if ($isDark) { "#60A5FA" } else { "#0078D4" } }
    }
    $bg = switch ($Status) {
        "OK" { if ($isDark) { "#163820" } else { "#DCFCE7" } }
        "FAIL" { if ($isDark) { "#3E1719" } else { "#FEE2E2" } }
        "WARN" { if ($isDark) { "#3D3010" } else { "#FEF3C7" } }
        default { if ($isDark) { "#1E293B" } else { "#DBEAFE" } }
    }
    $script:Summary.Add([PSCustomObject]@{ Status = $Status; StatusFg = $fg; StatusBg = $bg; Check = $parts[0].Trim(); Details = if ($parts.Count -gt 1) { $parts[1].Trim() } else { $Message } })
    $gridPreCheckResults.ItemsSource = $script:Summary.ToArray()
    Invoke-UiPump
}

function Set-PreCheckProgress([int]$Percent, [string]$Message) {
    $progressBarPreCheck.Value = [math]::Min(100, [math]::Max(0, $Percent))
    $txtPercent.Text = "$Percent% Complete"
    $txtMessage.Text = $Message
    Invoke-UiPump
}

function Complete-LiteDeployInventory {
    param([bool]$Passed)
    $results = @($script:Summary | ForEach-Object {
            [PSCustomObject]@{ Status = $_.Status; Check = $_.Check; Details = $_.Details }
        })
    $script:Inventory = Get-HardwareInventory -Assessment ([pscustomobject]$script:InventoryState) -Results $results -Passed $Passed
    Update-PreCheckDeviceIdentity
    return $script:Inventory
}

function New-LiteDeployPreCheckResult {
    param([bool]$Passed)
    if (-not $script:Inventory) {
        Complete-LiteDeployInventory -Passed $Passed | Out-Null
    }
    return [PSCustomObject]@{
        Passed    = [bool]$Passed
        Inventory = $script:Inventory
    }
}

function Test-NetworkHardware([string]$Mode) {
    try {
        $name = Get-HardwarePrimaryNicName
        if ($name) {
            $script:InventoryState.NetworkAdapter = $name
            Add-Result "Network Adapter: Connected ($name)" "OK"
            return $true
        }
        $status = if ($Mode -eq "Media") { "WARN" } else { "FAIL" }
        $script:InventoryState.NetworkAdapter = $null
        Add-Result "Network Adapter: Not Detected" $status
        return ($Mode -eq "Media")
    }
    catch {
        $status = if ($Mode -eq "Media") { "WARN" } else { "FAIL" }
        $script:InventoryState.NetworkAdapter = $null
        Add-Result "Network Adapter: Not Detected" $status
        return ($Mode -eq "Media")
    }
}

function Test-NetworkIPAddress([int]$TimeoutSeconds, [int]$PollIntervalMs, [string]$Mode) {
    try {
        # Poll with UI pump so WPF stays responsive while Hardware waits for DHCP.
        $ipv4 = $null; $ipv6 = $null
        $timer = [Diagnostics.Stopwatch]::StartNew()
        do {
            $ipv4 = Get-HardwareIPAddress
            $ipv6 = Get-HardwareIPv6Address
            if ($ipv4) { break }
            if ($TimeoutSeconds -le 0) { break }
            Invoke-UiPump
            Start-Sleep -Milliseconds $PollIntervalMs
        } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)

        if ($ipv4) {
            $script:InventoryState.IpAddress = $ipv4
            Add-Result "IPv4 Address: $(if ($ipv6) { "$ipv4 (IPv6: $ipv6)" } else { $ipv4 })" "OK"
            return $true
        }
        $status = if ($Mode -eq "Media") { "WARN" } else { "FAIL" }
        $script:InventoryState.IpAddress = $null
        Add-Result "IPv4 Address: Not Detected" $status
        return ($Mode -eq "Media")
    }
    catch {
        $status = if ($Mode -eq "Media") { "WARN" } else { "FAIL" }
        $script:InventoryState.IpAddress = $null
        Add-Result "IPv4 Address: Not Detected" $status
        return ($Mode -eq "Media")
    }
}

function Test-DeploymentShare([string]$SharePath, [int]$TimeoutMs, [string]$Mode) {
    if ($Mode -eq "Media" -or [string]::IsNullOrWhiteSpace($SharePath)) { return $true }
    $server = $SharePath.TrimStart("\").Split("\")[0]
    $client = New-Object Net.Sockets.TcpClient; $connected = $false
    try {
        $request = $client.BeginConnect($server, 445, $null, $null)
        if ($request.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { $client.EndConnect($request); $connected = $true }
    }
    catch {} finally { $client.Dispose() }
    if ($connected) {
        $script:InventoryState.DeploymentServer = "Reachable ($server)"
        Add-Result "Deployment Server: Reachable ($server)" "OK"
        return $true
    }
    $script:InventoryState.DeploymentServer = "Unreachable ($server)"
    Add-Result "Deployment Server: Unreachable ($server) on SMB port 445" "FAIL"
    $false
}

function Test-InternalStorage([int]$MinimumGB) {
    $drives = @(Get-HardwareHardDrives)
    $items = @($drives | ForEach-Object {
            [pscustomobject]@{ Number = $_.Number; Model = $_.Model; Size = $_.SizeGB }
        })
    if (-not $items) {
        $script:InventoryState.Disks = @()
        Add-Result "Internal Storage: Not Detected" "FAIL"
        return $false
    }

    $script:InventoryState.Disks = @($items)
    $validCount = 0
    foreach ($item in $items) {
        $belowMinimum = ($item.Size -gt 0 -and $item.Size -lt $MinimumGB)
        $status = if ($belowMinimum) { "FAIL" } else { "OK" }
        if ($status -eq "OK") { $validCount++ }

        $sizeText = if ($item.Size -gt 0) { " ($($item.Size) GB)" } else { "" }
        if ($belowMinimum) { $sizeText += " [Below minimum $MinimumGB GB]" }
        Add-Result "Internal Storage: Disk $($item.Number) - $($item.Model)$sizeText" $status
    }
    return ($validCount -gt 0)
}

function Test-SystemMemory([int]$MinimumGB) {
    try {
        $gb = Get-HardwareMemoryGB
        if ($gb -le 0) { return $true }
        $script:InventoryState.MemoryGB = $gb
        Add-Result "System RAM: $gb GB" $(if ($gb -ge $MinimumGB) { "OK" } else { "WARN" })
        return ($gb -ge $MinimumGB)
    }
    catch { $true }
}

function Test-SystemEnvironment {
    try {
        $firmware = Get-HardwareFirmwareType
        $script:InventoryState.FirmwareType = $firmware
        if (Get-HardwareIsUEFI) {
            Add-Result "BIOS Mode: UEFI" "OK"
            $display = Get-HardwareSecureBootDisplay
            $statusName = Get-HardwareSecureBootStatus
            if ($statusName -eq "Enabled") {
                $status = if ($display -like "*BIOS Update Recommended*") { "WARN" } else { "OK" }
                $script:InventoryState.SecureBoot = $display
                Add-Result "Secure Boot: $display" $status
            }
            else {
                $script:InventoryState.SecureBoot = $statusName
                Add-Result "Secure Boot: $statusName" "WARN"
            }
        }
        else {
            $script:InventoryState.SecureBoot = $null
            Add-Result "BIOS Mode: $firmware (Legacy BIOS)" "WARN"
        }
        $true
    }
    catch { Add-Result "System Environment: Unable to detect full specifications" "WARN"; $true }
}

function Test-SystemTPM {
    try {
        if (-not (Get-HardwareIsUEFI)) {
            return $true
        }

        $present = Get-HardwareTpmPresent
        $version = Get-HardwareTpmVersion
        $state = Get-HardwareTpmState
        $script:InventoryState.TpmPresent = $present
        $script:InventoryState.TpmVersion = $version
        $script:InventoryState.TpmState = $state

        if ($present) {
            if ((Get-HardwareTpmIsReady)) {
                Add-Result "TPM Status: TPM 2.0 (Enabled)" "OK"
            }
            else {
                Add-Result "TPM Status: $version ($state)" "WARN"
            }
            return $true
        }

        Add-Result "TPM Status: Not Detected" "WARN"
        return $true
    }
    catch {
        $script:InventoryState.TpmPresent = $false
        $script:InventoryState.TpmState = "Not Detected"
        Add-Result "TPM Status: Not Detected" "WARN"
        return $true
    }
}

function Invoke-HardwarePreCheck {
    param([switch]$ReloadFromDisk)

    $script:PreCheckPassed = $true
    $script:Summary.Clear()
    $script:Inventory = $null
    Reset-InventoryState

    $gridPreCheckResults.ItemsSource = $null
    $btnContinue.IsEnabled = $false
    $btnContinue.Content = "Running..."
    $progressBarPreCheck.Foreground = Brush $(if ($isDark) { "#60A5FA" } else { "#0078D4" })
    if ($null -ne $txtStatusBanner) {
        $txtStatusBanner.Text = "DEVICE PRECHECK IS RUNNING..."
        $txtStatusBanner.Foreground = Brush $(if ($isDark) { "#60A5FA" } else { "#0078D4" })
    }
    if ($null -ne $bannerStatus) {
        $bannerStatus.Background = Brush $surfaceBg
        $bannerStatus.BorderBrush = Brush $borderColor
    }

    Set-PreCheckProgress 5 "Loading configuration..."
    Update-PreCheckDeviceIdentity

    $configPath = $script:BootConfigPath
    $config = $null
    $mode = $null
    $share = $DeploymentShare
    $name = "LiteDeploy"
    $version = ""
    $environment = ""

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        Add-Result "Configuration: BootConfig path not found - $configPath" "FAIL"
        $script:PreCheckPassed = $false
        $txtConfigSource.Text = "Configuration: Not found"
    }
    else {
        try {
            $config = Get-EffectiveBootConfig -ForceReload:$ReloadFromDisk
        }
        catch {
            Add-Result "Configuration: Invalid JSON - $($_.Exception.Message)" "FAIL"
            $script:PreCheckPassed = $false
        }
    }

    if ($config) {
        $configMeta = Property $config "Metadata"
        $deployment = Property $config "Deployment"
        if (Property $configMeta "Name") { $name = Property $configMeta "Name" }
        if (Property $configMeta "Version") { $version = Property $configMeta "Version" }
        if (Property $configMeta "Environment") { $environment = Property $configMeta "Environment" }
        $mode = Property $deployment "Type"
        if (-not $script:ShareWasSpecified -and (Property $deployment "NetworkPath")) {
            $share = Property $deployment "NetworkPath"
        }
        $script:InventoryState.DeploymentMode = $mode
        $script:InventoryState.NetworkPath = $share
    }

    $txtBrand.Text = $name
    $txtSubtitle.Text = if ($environment) { "$environment Environment | v$version" } else { "$componentName   | v$componentVersion" }
    $txtConfigSource.Text = if ($config -and $configPath) { "Configuration: $configPath" } else { "Configuration: Not found" }

    $computerSetup = Property $config "ComputerSetup"
    $script:InventoryState.RequireTpm = ($computerSetup -and (Property $computerSetup "RequireTPM") -eq $true)

    if (-not $config) {
        Add-Result "Deployment Mode: Configuration File Not Found" "FAIL"
        $script:PreCheckPassed = $false
    }
    elseif ($mode -eq "Media") {
        Add-Result "Deployment Mode: Local (Media)" "OK"
    }
    elseif ($mode -eq "Network" -and $share) {
        Add-Result "Deployment Mode: Network ($share)" "OK"
    }
    elseif ($mode -eq "Network") {
        Add-Result "Deployment Mode: Network (Missing NetworkPath)" "FAIL"
        $script:PreCheckPassed = $false
    }
    else {
        Add-Result "Deployment Mode: $mode" "WARN"
    }

    Set-PreCheckProgress 15 "Testing deployment source connectivity..."
    if (-not (Test-DeploymentShare $share $SmbConnectTimeoutMilliseconds $mode)) {
        $script:PreCheckPassed = $false
    }

    $startup = Property $config "Startup"
    $skipPreCheck = ((Property $startup "SkipHardwarePreCheck") -eq $true) -or ((Property $startup "SkipPreCheck") -eq $true)
    if ($skipPreCheck) {
        # Assessment bypassed — still build inventory for Engine / later stages.
        $script:InventoryState.SkippedByPolicy = $true
        $script:PreCheckPassed = $true
        Add-Result "Precheck: Bypassed via configuration" "INFO"
        Set-PreCheckProgress 95 "Finalizing hardware details..."
        Clear-HardwareCache
        Complete-LiteDeployInventory -Passed $true | Out-Null
        Set-PreCheckBanner -Outcome "Skipped"
        return "Skipped"
    }

    # Fresh NIC/IP probe for assessment (share test may have raced DHCP).
    Clear-HardwareCache
    Set-PreCheckProgress 35 "Scanning for active network hardware..."
    if (-not (Test-NetworkHardware $mode)) { $script:PreCheckPassed = $false }
    Set-PreCheckProgress 55 "Awaiting IPv4 address assignment..."
    if (-not (Test-NetworkIPAddress $MaxNetworkWaitSeconds $NetworkPollMilliseconds $mode)) { $script:PreCheckPassed = $false }
    Set-PreCheckProgress 75 "Validating internal storage and system memory..."
    if (-not (Test-InternalStorage $MinDiskSizeGB)) { $script:PreCheckPassed = $false }
    Test-SystemMemory $MinMemoryGB | Out-Null
    Set-PreCheckProgress 90 "Analyzing firmware and Secure Boot..."
    Test-SystemEnvironment | Out-Null
    Set-PreCheckProgress 95 "Evaluating TPM security status..."
    Test-SystemTPM | Out-Null

    # Stay at 95% while inventory is assembled; 100% is applied with the outcome banner.
    Set-PreCheckProgress 95 "Finalizing hardware details..."
    Complete-LiteDeployInventory -Passed $script:PreCheckPassed | Out-Null

    if ($script:PreCheckPassed) {
        Set-PreCheckBanner -Outcome "Passed"
        return "Passed"
    }

    Set-PreCheckBanner -Outcome "Failed"
    return "Failed"
}

# ------------------------------------------------------------------------------
# 6. EVENT BINDING & EXECUTION
# ------------------------------------------------------------------------------
$script:AllowClose = $false

# Continue only closes PreCheck; DeploymentEngine calls WorkflowSelection next.

if ($null -ne $btnContinue) {
    $btnContinue.Add_Click({
            $script:AllowClose = $true
            $window.Close()
        })
}
if ($null -ne $btnRunAgain) { $btnRunAgain.Add_Click({ Invoke-HardwarePreCheck -ReloadFromDisk }) }
if ($null -ne $btnDiagnostics) {
    $btnDiagnostics.Add_Click({
            $window.Topmost = $false
            Start-Process "$env:SystemRoot\System32\cmd.exe"
        })
}

$window.Add_Closing({
        param($sender, $e)
        if (-not $script:AllowClose) {
            $msg = "Close PreCheck and cancel this deployment?"
            $result = [System.Windows.Forms.MessageBox]::Show(
                $msg,
                "Cancel Deployment",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($result -eq [System.Windows.Forms.DialogResult]::No) {
                $e.Cancel = $true
            }
            else {
                $script:PreCheckPassed = $false
            }
        }
    })

$window.Add_PreviewKeyDown({
        param($sender, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::F5) {
            $e.Handled = $true
            Invoke-HardwarePreCheck -ReloadFromDisk
        }
    })
$window.Add_KeyDown({ if ($_.Key -eq [System.Windows.Input.Key]::Escape) { $window.Close() } })
$window.Add_ContentRendered({ Invoke-HardwarePreCheck })

# Fill empty XAML brand placeholders before show (peek only — do not consume optional -BootConfig).
$brandConfig = $null
if ($null -ne $script:PassedBootConfig) {
    $brandConfig = $script:PassedBootConfig
}
elseif (Test-Path -LiteralPath $script:BootConfigPath -PathType Leaf) {
    try {
        $brandConfig = Get-Content -LiteralPath $script:BootConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch { }
}
$name = "LiteDeploy"
$version = ""
$environment = ""
if ($brandConfig) {
    $configMeta = Property $brandConfig "Metadata"
    if (Property $configMeta "Name") { $name = Property $configMeta "Name" }
    if (Property $configMeta "Version") { $version = Property $configMeta "Version" }
    if (Property $configMeta "Environment") { $environment = Property $configMeta "Environment" }
}
if ($null -ne $txtBrand) { $txtBrand.Text = $name }
if ($null -ne $txtSubtitle) {
    $txtSubtitle.Text = if ($environment) { "$environment Environment | v$version" } else { "$componentName   | v$componentVersion" }
}

$null = $window.ShowDialog()

# Always return Passed + Inventory for Engine.
if (-not $script:Inventory) {
    Complete-LiteDeployInventory -Passed ([bool]$script:PreCheckPassed) | Out-Null
}
return (New-LiteDeployPreCheckResult -Passed ([bool]$script:PreCheckPassed))
