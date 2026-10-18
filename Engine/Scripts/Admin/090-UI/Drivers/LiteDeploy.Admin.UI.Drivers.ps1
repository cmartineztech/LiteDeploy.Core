<#
.SYNOPSIS
    LiteDeploy Driver Pack Manager - Modern WPF Graphical Interface.
.DESCRIPTION
    WPF frontend for Admin.Drivers: initialize share layout, refresh OEM catalogs,
    download driver packs (archive-only by default), and manage ComputerModels.csv fleet status.
.PARAMETER DefaultDeploymentShare
    Initial deployment share directory path.
.PARAMETER Theme
    Theme design system ("Light" or "Dark"). Auto-detects Windows theme if unsupplied.
.PARAMETER WindowTitle
    Custom title string displayed in the main window title bar.
.PARAMETER DarkMode
    Switch to enforce Dark theme mode directly.
#>
# region 1. SCRIPT PARAMETERS & ELEVATION / STA BOOTSTRAPPER
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$DefaultDeploymentShare = "",
    [ValidateSet("Light", "Dark")][string]$Theme = "Light",
    [string]$WindowTitle = "LiteDeploy - Driver Pack Manager",
    [switch]$DarkMode,
    [Parameter(Mandatory = $false)][switch]$Metadata
)

function Get-LiteDeployComponentMetadata {
    return [PSCustomObject]@{
        ComponentId          = "Admin.UI.Drivers"
        Name                 = "LiteDeploy Driver Pack Manager GUI"
        Version              = "2.0.0"
        Category             = "Admin"
        TargetEnvironment    = "Host"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("Admin.Drivers")
        Description          = "WPF management frontend for OEM driver pack download and fleet status under Content\Drivers."
    }
}

if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $procInfo = New-Object System.Diagnostics.ProcessStartInfo -Property @{
        FileName  = "powershell.exe"
        Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        Verb      = "runas"
    }
    try { [System.Diagnostics.Process]::Start($procInfo) | Out-Null } catch {}
    exit
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path $powershellExe)) { $powershellExe = "powershell.exe" }
    & $powershellExe -STA -ExecutionPolicy Bypass -File "$PSCommandPath" @args
    exit
}

try { [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly } catch {}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
# endregion

# region 2. THEME DESIGN SYSTEM & COLOR TOKENS
$screenHeight = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height
$targetHeight = [Math]::Min(860, [Math]::Max(550, [int]($screenHeight * 0.75)))
$targetWidth  = [int]($targetHeight * (960 / 710))

if (-not $PSBoundParameters.ContainsKey('Theme') -and -not $DarkMode.IsPresent) {
    try {
        $regPath    = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        $lightTheme = (Get-ItemProperty -Path $regPath -Name "AppsUseLightTheme" -ErrorAction SilentlyContinue).AppsUseLightTheme
        if ($null -ne $lightTheme -and $lightTheme -eq 0) { $Theme = "Dark" } else { $Theme = "Light" }
    } catch { $Theme = "Light" }
}
if ($DarkMode.IsPresent) { $Theme = "Dark" }

$isDark   = ($Theme -eq "Dark")
$xmlTitle = [System.Security.SecurityElement]::Escape($WindowTitle)

$bgColor           = if ($isDark) { "#121212" } else { "#FFFFFF" }
$fgColor           = if ($isDark) { "#F3F4F6" } else { "#111827" }
$secFgColor        = if ($isDark) { "#9CA3AF" } else { "#4B5563" }
$mutedFgColor      = if ($isDark) { "#9CA3AF" } else { "#687684" }
$surfaceBg         = if ($isDark) { "#1E1E1E" } else { "#F7F9FB" }
$footerBg          = if ($isDark) { "#181818" } else { "#F7F9FB" }
$headerBg          = "#005A9E"
$headerFg          = "#FFFFFF"
$borderColor       = if ($isDark) { "#333333" } else { "#D9E0E7" }
$buttonBg          = if ($isDark) { "#2A2A2A" } else { "#FFFFFF" }
$buttonFg          = if ($isDark) { "#F3F4F6" } else { "#1F2937" }
$buttonHoverBg     = if ($isDark) { "#383838" } else { "#F3F4F6" }
$buttonPressedBg   = if ($isDark) { "#404040" } else { "#E5E7EB" }
$trackBg           = if ($isDark) { "#2D2D2D" } else { "#E6EBF0" }
$headerColor       = if ($isDark) { "#3B82F6" } else { "#005A9E" }
$primaryHoverBg    = if ($isDark) { "#2563EB" } else { "#0078D4" }
$primaryPressedBg  = if ($isDark) { "#1D4ED8" } else { "#004E8C" }
$disabledBg        = if ($isDark) { "#262626" } else { "#F3F4F6" }
$disabledBorder    = if ($isDark) { "#333333" } else { "#E5E7EB" }
$disabledFg        = if ($isDark) { "#6B7280" } else { "#9CA3AF" }
$dangerBg          = if ($isDark) { "#DC2626" } else { "#D13438" }
$dangerHoverBg     = if ($isDark) { "#B91C1C" } else { "#A80000" }
$dangerPressedBg   = if ($isDark) { "#991B1B" } else { "#750000" }
$inputBg           = if ($isDark) { "#1E1E1E" } else { "#FFFFFF" }
$logBg             = if ($isDark) { "#0F0F0F" } else { "#1E1E1E" }
$logFg             = if ($isDark) { "#4ADE80" } else { "#00FF66" }
# endregion

# region 3. REUSABLE XAML MARKUP & RESOURCE GENERATORS
function Get-SharedXamlResources {
    return @"
        <Style x:Key="DataGridHeaderStyle" TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="$surfaceBg"/><Setter Property="Foreground" Value="$headerColor"/>
            <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="FontSize" Value="11"/>
            <Setter Property="Padding" Value="10,6"/><Setter Property="BorderThickness" Value="0,0,1,1"/>
            <Setter Property="BorderBrush" Value="$borderColor"/>
        </Style>
        <Style x:Key="DataGridRowStyle" TargetType="DataGridRow">
            <Setter Property="Background" Value="$surfaceBg"/><Setter Property="Foreground" Value="$fgColor"/>
            <Setter Property="BorderThickness" Value="0,0,0,1"/><Setter Property="BorderBrush" Value="$borderColor"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="$buttonHoverBg"/></Trigger>
                <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="$buttonPressedBg"/><Setter Property="Foreground" Value="$fgColor"/></Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="DataGridCellStyle" TargetType="DataGridCell">
            <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="$fgColor"/>
            <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="6,2"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="DataGridCell">
                        <Border Background="{TemplateBinding Background}" BorderThickness="0" Padding="{TemplateBinding Padding}">
                            <ContentPresenter VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ModernProgressBarStyle" TargetType="ProgressBar">
            <Setter Property="Height" Value="8"/><Setter Property="Background" Value="$trackBg"/>
            <Setter Property="Foreground" Value="$headerColor"/><Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Grid>
                            <Border Background="{TemplateBinding Background}" CornerRadius="4"/>
                            <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" CornerRadius="4" HorizontalAlignment="Left"/>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="PrimaryButtonStyle" TargetType="Button">
            <Setter Property="Background" Value="$headerColor"/><Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="$headerColor"/><Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="12"/><Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="16,5"/><Setter Property="Cursor" Value="Hand"/>
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
            <Setter Property="Padding" Value="12,2"/><Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="border" Property="Background" Value="$buttonHoverBg"/><Setter TargetName="border" Property="BorderBrush" Value="$headerColor"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="border" Property="Background" Value="$buttonPressedBg"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="border" Property="Background" Value="$disabledBg"/><Setter TargetName="border" Property="BorderBrush" Value="$disabledBorder"/><Setter Property="Foreground" Value="$disabledFg"/><Setter Property="Cursor" Value="No"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DangerButtonStyle" TargetType="Button">
            <Setter Property="Background" Value="$dangerBg"/><Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="$dangerBg"/><Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="11.5"/><Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="16,5"/><Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="border" Property="Background" Value="$dangerHoverBg"/><Setter TargetName="border" Property="BorderBrush" Value="$dangerHoverBg"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="border" Property="Background" Value="$dangerPressedBg"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="border" Property="Background" Value="$disabledBg"/><Setter TargetName="border" Property="BorderBrush" Value="$disabledBorder"/><Setter Property="Foreground" Value="$disabledFg"/><Setter Property="Cursor" Value="No"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="TabItem">
            <Setter Property="Background" Value="$buttonBg"/><Setter Property="Foreground" Value="$secFgColor"/>
            <Setter Property="BorderBrush" Value="$borderColor"/><Setter Property="Padding" Value="16,8"/><Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border x:Name="Border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="0,0,0,2" Margin="0,0,4,0" Padding="{TemplateBinding Padding}">
                            <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center" ContentSource="Header"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="$surfaceBg"/>
                                <Setter TargetName="Border" Property="BorderBrush" Value="$headerColor"/>
                                <Setter Property="Foreground" Value="$headerColor"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Border" Property="Background" Value="$buttonHoverBg"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="$inputBg"/><Setter Property="Foreground" Value="$fgColor"/>
            <Setter Property="BorderBrush" Value="$borderColor"/><Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,4"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
                            <ScrollViewer x:Name="PART_ContentHost" Focusable="False" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsFocused" Value="True"><Setter TargetName="border" Property="BorderBrush" Value="$headerColor"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="border" Property="Background" Value="$disabledBg"/><Setter TargetName="border" Property="BorderBrush" Value="$disabledBorder"/><Setter Property="Foreground" Value="$disabledFg"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="$inputBg"/><Setter Property="Foreground" Value="$fgColor"/>
            <Setter Property="BorderBrush" Value="$borderColor"/><Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="6,4"/><Setter Property="Height" Value="26"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="$fgColor"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>
"@
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$xmlTitle" WindowState="Normal" WindowStyle="SingleBorderWindow"
        ResizeMode="NoResize" Width="$targetWidth" Height="$targetHeight"
        WindowStartupLocation="CenterScreen" Background="$bgColor">
    <Window.Resources>
$(Get-SharedXamlResources)
    </Window.Resources>
    <Viewbox Stretch="Fill">
        <Border Width="960" Height="710" Background="$bgColor">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="65"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="55"/>
                </Grid.RowDefinitions>

                <Border Grid.Row="0" Background="$headerBg" Padding="20,0">
                    <Grid VerticalAlignment="Center">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <Border Grid.Column="0" Width="38" Height="38" Background="#26FFFFFF" CornerRadius="6" Margin="0,0,14,0">
                            <TextBlock Text="LD" Foreground="White" FontWeight="Bold" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <StackPanel Grid.Column="1" VerticalAlignment="Center">
                            <TextBlock Text="LiteDeploy" Foreground="White" FontWeight="Bold" FontSize="17"/>
                            <TextBlock Text="Driver Pack Manager" Foreground="#D9EFFF" FontSize="11.5" Margin="0,1,0,0"/>
                        </StackPanel>
                        <Border Grid.Column="2" Background="#20FFFFFF" CornerRadius="4" Padding="10,5" VerticalAlignment="Center">
                            <TextBlock Text="DRIVER MANAGER" Foreground="White" FontSize="10.5" FontWeight="Bold"/>
                        </Border>
                    </Grid>
                </Border>

                <Grid Grid.Row="1" Margin="20,14,20,10">
                    <TabControl Name="mainTabControl" Background="Transparent" BorderThickness="0">
                        <!-- TAB 1: DOWNLOAD / CATALOG -->
                        <TabItem Header="Download &amp; Catalog">
                            <Grid Margin="0,14,0,0">
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="*"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>

                                <Border Grid.Row="0" Background="$surfaceBg" BorderBrush="$borderColor" BorderThickness="1" CornerRadius="6" Padding="16,14" Margin="0,0,0,10">
                                    <StackPanel>
                                        <TextBlock Text="DEPLOYMENT SHARE &amp; DOWNLOAD OPTIONS" FontSize="11" FontWeight="Bold" Foreground="$mutedFgColor" Margin="0,0,0,10"/>
                                        <Grid Margin="0,0,0,10">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="150"/>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="95"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Deployment Share Root:" VerticalAlignment="Center" FontWeight="SemiBold" Foreground="$fgColor" FontSize="11.5"/>
                                            <TextBox Name="txtDeploymentShare" Grid.Column="1" Margin="0,0,8,0" Height="26" VerticalContentAlignment="Center" FontSize="11.5"/>
                                            <Button Name="btnBrowseShare" Grid.Column="2" Content="Browse..." Style="{StaticResource SecondaryButtonStyle}" Width="95" Height="26" HorizontalAlignment="Right"/>
                                        </Grid>
                                        <TextBlock Name="txtShareValidation" Text="" FontSize="11" Margin="150,0,0,8" TextWrapping="Wrap"/>
                                        <Grid Margin="0,0,0,10">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="150"/>
                                                <ColumnDefinition Width="160"/>
                                                <ColumnDefinition Width="90"/>
                                                <ColumnDefinition Width="140"/>
                                                <ColumnDefinition Width="*"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Manufacturer:" VerticalAlignment="Center" FontWeight="SemiBold" Foreground="$fgColor" FontSize="11.5"/>
                                            <ComboBox Name="cmbManufacturer" Grid.Column="1" Margin="0,0,12,0" VerticalContentAlignment="Center"/>
                                            <TextBlock Grid.Column="2" Text="OS Target:" VerticalAlignment="Center" FontWeight="SemiBold" Foreground="$fgColor" FontSize="11.5"/>
                                            <ComboBox Name="cmbOsCode" Grid.Column="3" Margin="0,0,12,0" VerticalContentAlignment="Center"/>
                                        </Grid>
                                        <Grid>
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="Auto"/>
                                                <ColumnDefinition Width="Auto"/>
                                                <ColumnDefinition Width="*"/>
                                            </Grid.ColumnDefinitions>
                                            <CheckBox Name="chkExtract" Grid.Column="0" Content="Extract after download" Margin="0,0,20,0" ToolTip="Off by default: keeps verified archive only under Content\Drivers"/>
                                            <CheckBox Name="chkCleanTemp" Grid.Column="1" Content="Clean temp after catalog" ToolTip="Delete raw vendor CAB/XML from Content\Temp after GetCatalog"/>
                                        </Grid>
                                    </StackPanel>
                                </Border>

                                <Border Grid.Row="1" Background="$surfaceBg" BorderBrush="$borderColor" BorderThickness="1" CornerRadius="6" Padding="12,10" Margin="0,0,0,10">
                                    <WrapPanel>
                                        <Button Name="btnInit" Content="Initialize" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,8,0" Height="30" ToolTip="Create Content\Drivers, Content\Temp, CSV, LocalCatalog"/>
                                        <Button Name="btnGetCatalog" Content="Get Catalog" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,8,0" Height="30" ToolTip="Download/convert OEM vendor catalogs"/>
                                        <Button Name="btnCheckUpdate" Content="Check Updates" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,8,0" Height="30"/>
                                        <Button Name="btnDownloadAll" Content="Download Fleet" Style="{StaticResource PrimaryButtonStyle}" Height="30" ToolTip="Download all models in ComputerModels.csv"/>
                                    </WrapPanel>
                                </Border>

                                <Border Grid.Row="2" Background="$logBg" BorderBrush="$borderColor" BorderThickness="1" CornerRadius="6" Padding="8">
                                    <Grid>
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="Auto"/>
                                            <RowDefinition Height="*"/>
                                        </Grid.RowDefinitions>
                                        <TextBlock Grid.Row="0" Text="EXECUTION LOG" FontSize="10" FontWeight="Bold" Foreground="#6B7280" Margin="4,0,0,6"/>
                                        <TextBox Name="txtLog" Grid.Row="1" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                                                 Background="Transparent" Foreground="$logFg" BorderThickness="0" FontFamily="Consolas" FontSize="11.5" AcceptsReturn="True"/>
                                    </Grid>
                                </Border>

                                <Grid Grid.Row="3" Margin="0,10,0,0">
                                    <ProgressBar Name="pbBusy" Style="{StaticResource ModernProgressBarStyle}" Height="8" Visibility="Collapsed" IsIndeterminate="True"/>
                                    <TextBlock Name="txtStatusSummary" Text="" Foreground="$mutedFgColor" FontSize="11" VerticalAlignment="Center" Margin="0,12,0,0"/>
                                </Grid>
                            </Grid>
                        </TabItem>

                        <!-- TAB 2: Managed Computer Models = ComputerModels.csv only -->
                        <TabItem Name="tabModels" Header="Managed Computer Models">
                            <Grid Margin="0,14,0,0">
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="*"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>
                                <StackPanel Grid.Row="0" Margin="0,0,0,8">
                                    <TextBlock Text="Models listed in ComputerModels.csv (the fleet you manage for Download Fleet)."
                                               Foreground="$mutedFgColor" FontSize="11.5"/>
                                    <TextBlock Name="txtModelsSummary" Text="" Foreground="$secFgColor" FontSize="11" Margin="0,4,0,0"
                                               ToolTip="File: Content\Drivers\ComputerModels.csv"/>
                                </StackPanel>
                                <DataGrid Name="dgModels" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True" Background="$surfaceBg"
                                          BorderBrush="$borderColor" BorderThickness="1" GridLinesVisibility="None" SelectionMode="Single"
                                          FontSize="12" RowHeight="28" ColumnHeaderStyle="{StaticResource DataGridHeaderStyle}"
                                          RowStyle="{StaticResource DataGridRowStyle}" CellStyle="{StaticResource DataGridCellStyle}"
                                          HeadersVisibility="Column" RowHeaderWidth="0">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="MANUFACTURER" Binding="{Binding Manufacturer}" Width="120"/>
                                        <DataGridTextColumn Header="MODEL" Binding="{Binding Model}" Width="180"/>
                                        <DataGridTextColumn Header="SKU" Binding="{Binding SystemSKU}" Width="100"/>
                                        <DataGridTextColumn Header="PACK STATUS" Binding="{Binding Status}" Width="120">
                                            <DataGridTextColumn.CellStyle>
                                                <Style TargetType="DataGridCell" BasedOn="{StaticResource DataGridCellStyle}">
                                                    <Setter Property="ToolTip" Value="Download state from LocalCatalog (if a pack exists for this CSV row)"/>
                                                </Style>
                                            </DataGridTextColumn.CellStyle>
                                        </DataGridTextColumn>
                                        <DataGridTextColumn Header="CONTENT LOCATION" Binding="{Binding ContentLocation}" Width="*"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                                <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,12,0,0" HorizontalAlignment="Right">
                                    <Button Name="btnRefreshModels" Content="Refresh" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,10,0"/>
                                    <Button Name="btnEditCsv" Content="Edit ComputerModels.csv..." Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,10,0"
                                            ToolTip="Edit ComputerModels.csv — the managed model list"/>
                                    <Button Name="btnAddCustom" Content="Add Custom Model..." Style="{StaticResource PrimaryButtonStyle}" Margin="0,0,10,0"/>
                                    <Button Name="btnDeleteModel" Content="Delete Model" Style="{StaticResource DangerButtonStyle}" Margin="0,0,10,0"
                                            ToolTip="Remove selected row from ComputerModels.csv"/>
                                    <Button Name="btnOpenDriversFolder" Content="Open Drivers Folder" Style="{StaticResource SecondaryButtonStyle}"/>
                                </StackPanel>
                            </Grid>
                        </TabItem>

                        <!-- TAB 3: Local Catalog (LocalCatalog.json DrivePacks) -->
                        <TabItem Name="tabLocalCatalog" Header="Local Catalog">
                            <Grid Margin="0,14,0,0">
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="*"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>
                                <TextBlock Name="txtCatalogSummary" Grid.Row="0" Text="" Foreground="$mutedFgColor" FontSize="11.5" Margin="0,0,0,8"
                                           ToolTip="Source: Content\Drivers\LocalCatalog.json"/>
                                <DataGrid Name="dgLocalCatalog" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True" Background="$surfaceBg"
                                          BorderBrush="$borderColor" BorderThickness="1" GridLinesVisibility="None" SelectionMode="Single"
                                          FontSize="12" RowHeight="28" ColumnHeaderStyle="{StaticResource DataGridHeaderStyle}"
                                          RowStyle="{StaticResource DataGridRowStyle}" CellStyle="{StaticResource DataGridCellStyle}"
                                          HeadersVisibility="Column" RowHeaderWidth="0">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="STATUS" Binding="{Binding Status}" Width="120"/>
                                        <DataGridTextColumn Header="MANUFACTURER" Binding="{Binding Manufacturer}" Width="110"/>
                                        <DataGridTextColumn Header="MODEL" Binding="{Binding Model}" Width="160"/>
                                        <DataGridTextColumn Header="SKU" Binding="{Binding SystemSKU}" Width="90"/>
                                        <DataGridTextColumn Header="FILE" Binding="{Binding FileName}" Width="180"/>
                                        <DataGridTextColumn Header="OS" Binding="{Binding OSVersion}" Width="100"/>
                                        <DataGridTextColumn Header="RELEASED" Binding="{Binding ReleaseDate}" Width="90"/>
                                        <DataGridTextColumn Header="EXTRACTED" Binding="{Binding ExtractedText}" Width="80"/>
                                        <DataGridTextColumn Header="CONTENT LOCATION" Binding="{Binding ContentLocation}" Width="*"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                                <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,12,0,0" HorizontalAlignment="Right">
                                    <Button Name="btnRefreshCatalog" Content="Refresh" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,10,0"/>
                                    <Button Name="btnSyncCatalog" Content="Sync CSV to Local Catalog" Style="{StaticResource PrimaryButtonStyle}" Margin="0,0,10,0"
                                            ToolTip="Reconcile LocalCatalog.json with ComputerModels.csv and on-disk packs"/>
                                    <Button Name="btnOpenCatalogFolder" Content="Open Drivers Folder" Style="{StaticResource SecondaryButtonStyle}"/>
                                </StackPanel>
                            </Grid>
                        </TabItem>
                    </TabControl>
                </Grid>

                <Border Grid.Row="2" Background="$footerBg" BorderBrush="$borderColor" BorderThickness="0,1,0,0" Padding="20,0">
                    <Grid VerticalAlignment="Center">
                        <TextBlock Text="Catalog: Content\Drivers\LocalCatalog.json  |  Log: WorkLogs\Admin\DriverManagement.log  |  Temp: Content\Temp"
                                   Foreground="$mutedFgColor" FontSize="11" VerticalAlignment="Center"/>
                        <Button Name="btnClearLog" Content="Clear Log" Style="{StaticResource SecondaryButtonStyle}" HorizontalAlignment="Right" Height="28"/>
                    </Grid>
                </Border>
            </Grid>
        </Border>
    </Viewbox>
</Window>
"@
# endregion

# region 4. CONTROLLER SERVICES
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)
if ($null -eq $window) { exit }

@(
    "mainTabControl", "txtDeploymentShare", "btnBrowseShare", "txtShareValidation", "cmbManufacturer", "cmbOsCode",
    "chkExtract", "chkCleanTemp", "btnInit", "btnGetCatalog", "btnCheckUpdate",
    "btnDownloadAll", "txtLog", "pbBusy", "txtStatusSummary",
    "tabModels", "txtModelsSummary", "dgModels", "btnRefreshModels", "btnEditCsv", "btnAddCustom", "btnDeleteModel", "btnOpenDriversFolder",
    "tabLocalCatalog", "txtCatalogSummary", "dgLocalCatalog", "btnRefreshCatalog", "btnSyncCatalog", "btnOpenCatalogFolder",
    "btnClearLog"
) | ForEach-Object { Set-Variable -Name $_ -Value ($window.FindName($_)) -Scope Script }

$cmbManufacturer.ItemsSource = @("All", "Dell", "Lenovo", "HP", "Custom")
$cmbManufacturer.SelectedIndex = 0
$cmbOsCode.ItemsSource = @("Windows11", "Windows10")
$cmbOsCode.SelectedIndex = 0
$chkExtract.IsChecked = $false
$chkCleanTemp.IsChecked = $false

function Do-Events {
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Render)
}

function Write-UiLog {
    param([string]$Message)
    $txtLog.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] $Message`n")
    $txtLog.ScrollToEnd()
    $txtStatusSummary.Text = $Message
    Do-Events
}

function Show-Msg {
    param([string]$Message, [string]$Title = "Notice", [string]$Icon = "Information", [string]$Buttons = "OK")
    return [System.Windows.MessageBox]::Show($Message, $Title, [System.Windows.MessageBoxButton]::$Buttons, [System.Windows.MessageBoxImage]::$Icon)
}

function Get-DriversScriptPath {
    if (-not (Get-Command Get-LiteDeployComponentPath -ErrorAction SilentlyContinue)) {
        throw 'Load LiteDeploy.Environment.ps1 once before starting the driver management UI.'
    }
    $path = Get-LiteDeployComponentPath -Name AdminDrivers
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Admin.Drivers missing: $path" }
    return $path
}

function Resolve-InitialSharePath {
    if (-not [string]::IsNullOrWhiteSpace($DefaultDeploymentShare) -and (Test-Path -LiteralPath $DefaultDeploymentShare)) {
        return (Resolve-Path -LiteralPath $DefaultDeploymentShare).Path
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LiteDeployShareRoot) -and (Test-Path -LiteralPath $env:LiteDeployShareRoot)) {
        return (Resolve-Path -LiteralPath $env:LiteDeployShareRoot).Path
    }
    $probe = $PSScriptRoot
    for ($i = 0; $i -lt 8 -and $probe; $i++) {
        if ((Test-Path (Join-Path $probe "Content")) -and (Test-Path (Join-Path $probe "Engine"))) {
            return (Resolve-Path -LiteralPath $probe).Path
        }
        $parent = Split-Path -Parent $probe
        if (-not $parent -or $parent -eq $probe) { break }
        $probe = $parent
    }
    if (Test-Path "C:\DeploymentShare") { return "C:\DeploymentShare" }
    return ""
}

function Get-ShareValidation {
    # Valid LiteDeploy share: folder exists and Config\BootConfig.json is present.
    $share = if ($txtDeploymentShare) { $txtDeploymentShare.Text.Trim() } else { "" }
    if ([string]::IsNullOrWhiteSpace($share)) {
        return [PSCustomObject]@{ IsValid = $false; ShareRoot = ""; BootConfigPath = ""; Message = "Enter a Deployment Share Root." }
    }
    if (-not (Test-Path -LiteralPath $share)) {
        return [PSCustomObject]@{ IsValid = $false; ShareRoot = $share; BootConfigPath = ""; Message = "Path does not exist: $share" }
    }
    $bootConfig = Join-Path $share "Config\BootConfig.json"
    if (-not (Test-Path -LiteralPath $bootConfig -PathType Leaf)) {
        return [PSCustomObject]@{
            IsValid        = $false
            ShareRoot      = $share
            BootConfigPath = $bootConfig
            Message        = "Not a valid LiteDeploy share: Config\BootConfig.json is missing."
        }
    }
    return [PSCustomObject]@{
        IsValid        = $true
        ShareRoot      = $share
        BootConfigPath = $bootConfig
        Message        = "Valid share (BootConfig.json found)."
    }
}

function Test-ShareReady {
    return [bool](Get-ShareValidation).IsValid
}

function Update-ShareValidationUi {
    $v = Get-ShareValidation
    if ($txtShareValidation) {
        $txtShareValidation.Text = $v.Message
        $txtShareValidation.Foreground = if ($v.IsValid) {
            [System.Windows.Media.BrushConverter]::new().ConvertFromString("#059669")
        } else {
            [System.Windows.Media.BrushConverter]::new().ConvertFromString($dangerBg)
        }
    }
    $canUse = [bool]$v.IsValid
    foreach ($btn in @(
        $btnInit, $btnGetCatalog, $btnCheckUpdate, $btnDownloadAll,
        $btnRefreshModels, $btnEditCsv, $btnAddCustom, $btnDeleteModel, $btnOpenDriversFolder,
        $btnRefreshCatalog, $btnSyncCatalog, $btnOpenCatalogFolder
    )) {
        if ($btn) { $btn.IsEnabled = $canUse }
    }
    return $v
}

function Set-Busy {
    param([bool]$Busy)
    $pbBusy.Visibility = if ($Busy) { "Visible" } else { "Collapsed" }
    $pbBusy.IsIndeterminate = $Busy
    if ($Busy) {
        foreach ($btn in @(
            $btnInit, $btnGetCatalog, $btnCheckUpdate, $btnDownloadAll,
            $btnRefreshModels, $btnEditCsv, $btnAddCustom, $btnDeleteModel,
            $btnRefreshCatalog, $btnSyncCatalog
        )) {
            if ($btn) { $btn.IsEnabled = $false }
        }
    }
    else {
        Update-ShareValidationUi | Out-Null
    }
    Do-Events
}

function ConvertTo-ProcessArg {
    # Quote values so paths with spaces (e.g. ...\LiteDeploy Core\...) survive Start-Process.
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value -match '[\s"]') {
        return ('"{0}"' -f ($Value -replace '"', '\"'))
    }
    return $Value
}

function Invoke-DriverEngine {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [hashtable]$Extra = @{}
    )
    $shareCheck = Get-ShareValidation
    if (-not $shareCheck.IsValid) {
        throw $shareCheck.Message
    }

    $scriptPath = Get-DriversScriptPath
    $sharePath  = $txtDeploymentShare.Text.Trim()
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("-NoProfile")
    $parts.Add("-ExecutionPolicy")
    $parts.Add("Bypass")
    $parts.Add("-File")
    $parts.Add((ConvertTo-ProcessArg $scriptPath))
    $parts.Add("-DeploymentShare")
    $parts.Add((ConvertTo-ProcessArg $sharePath))
    $parts.Add("-Action")
    $parts.Add((ConvertTo-ProcessArg $Action))

    $mfr = [string]$cmbManufacturer.SelectedItem
    $forceAll = ($Extra.ContainsKey("All") -and [bool]$Extra["All"])

    if ($forceAll) {
        $parts.Add("-All")
    }
    elseif ($mfr -and $mfr -ne "All") {
        $parts.Add("-Manufacturer")
        $parts.Add((ConvertTo-ProcessArg $mfr))
    }
    elseif ($Action -in @("GetCatalog", "CheckUpdate", "Status", "Sync") -and $mfr -eq "All") {
        $parts.Add("-All")
    }

    $parts.Add("-OSCode")
    $parts.Add((ConvertTo-ProcessArg ([string]$cmbOsCode.SelectedItem)))

    if ($Action -eq "Download") {
        $parts.Add("-Extract")
        $parts.Add( $(if ([bool]$chkExtract.IsChecked) { "true" } else { "false" }) )
    }
    if ([bool]$chkCleanTemp.IsChecked -and $Action -in @("GetCatalog", "CheckUpdate")) {
        $parts.Add("-CleanTemp")
    }
    foreach ($key in $Extra.Keys) {
        if ($key -eq "All") { continue }
        $val = $Extra[$key]
        if ($val -is [switch] -or $val -eq $true) {
            $parts.Add("-$key")
        }
        elseif ($null -ne $val -and "$val" -ne "") {
            $parts.Add("-$key")
            $parts.Add((ConvertTo-ProcessArg ([string]$val)))
        }
    }

    # Single argument string keeps quoted paths intact (array form splits on spaces).
    $argString = ($parts -join " ")
    Write-UiLog "Running Admin.Drivers -Action $Action ..."
    $tmpOut = [IO.Path]::GetTempFileName()
    $tmpErr = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList $argString -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        foreach ($line in @(Get-Content -LiteralPath $tmpOut -ErrorAction SilentlyContinue)) {
            if ($line) { Write-UiLog $line }
        }
        foreach ($line in @(Get-Content -LiteralPath $tmpErr -ErrorAction SilentlyContinue)) {
            if ($line) { Write-UiLog "ERR: $line" }
        }
        if ($null -eq $p -or $p.ExitCode -ne 0) {
            $code = if ($p) { $p.ExitCode } else { "null" }
            throw "Admin.Drivers exited with code $code. See WorkLogs\Admin\DriverManagement.log."
        }
        Write-UiLog "Completed: $Action"
    }
    finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    }
}

function Get-SafeName {
    param([string]$Name)
    return ($Name -replace '[\\/:*?"<>|]', "-").Trim(" .")
}

function Test-FolderHasContent {
    param([string]$Path)
    return (Test-Path -LiteralPath $Path) -and [bool](Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Get-LocalCatalogPath {
    param([string]$ShareRoot)
    return (Join-Path $ShareRoot "Content\Drivers\LocalCatalog.json")
}

function Get-PropValue {
    param([psobject]$Obj, [string]$Name, [object]$Default = "")
    if (-not $Obj) { return $Default }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($prop -and $null -ne $prop.Value) { return $prop.Value }
    return $Default
}

function Get-VendorFolderName {
    # Matches Admin.Drivers Get-SafeName(Vendor.Name) folder layout under Content\Drivers.
    param([string]$CsvManufacturer)
    switch -Regex ($CsvManufacturer) {
        '^Dell'   { return (Get-SafeName "Dell Inc.") }
        '^Lenovo' { return (Get-SafeName "LENOVO") }
        '^(HP|Hewlett)' { return (Get-SafeName "HP") }
        '^Custom' { return "Custom" }
        default   { return (Get-SafeName $CsvManufacturer) }
    }
}

function Get-AllLocalDrivePacks {
    param([string]$LocalCatalogPath)
    $packs = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $LocalCatalogPath)) { return $packs }

    try {
        $raw = [System.IO.File]::ReadAllText($LocalCatalogPath)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $packs }
        $localCat = $raw | ConvertFrom-Json
    }
    catch {
        Write-UiLog "WARN: Could not parse LocalCatalog.json: $_"
        return $packs
    }

    $manufacturers = Get-PropValue -Obj $localCat -Name "Manufacturers" -Default $null
    if (-not $manufacturers) { return $packs }

    foreach ($mfrProp in @($manufacturers.PSObject.Properties)) {
        $vendorKey = [string]$mfrProp.Name
        $entry = $mfrProp.Value
        if (-not $entry) { continue }
        foreach ($record in @(Get-PropValue -Obj $entry -Name "DrivePacks" -Default @())) {
            if (-not $record) { continue }
            $packs.Add([PSCustomObject]@{
                VendorKey = $vendorKey
                Record    = $record
            })
        }
    }
    return $packs
}

function Resolve-PackStatus {
    param(
        [psobject]$Record,
        [string]$DriversRoot,
        [string]$ContentLocation,
        [switch]$IsCustom
    )

    $fileName = ""
    $osVersion = ""
    $releaseDate = ""
    $extractedFlag = $false
    $modelFromPack = ""

    if ($Record) {
        $fileName = [string](Get-PropValue -Obj $Record -Name "FileName")
        $osVersion = [string](Get-PropValue -Obj $Record -Name "OSVersion")
        $releaseDate = [string](Get-PropValue -Obj $Record -Name "ReleaseDate")
        $modelFromPack = [string](Get-PropValue -Obj $Record -Name "Model")
        $extractedRaw = Get-PropValue -Obj $Record -Name "ContentExtracted" -Default $false
        if ($extractedRaw -eq $true -or "$extractedRaw" -eq "true") { $extractedFlag = $true }
        $locFromPack = [string](Get-PropValue -Obj $Record -Name "ContentLocation")
        if ($locFromPack) { $ContentLocation = $locFromPack }
    }

    $contentPath = if ($ContentLocation) {
        [IO.Path]::GetFullPath((Join-Path $DriversRoot $ContentLocation))
    } else { "" }

    $hasContent = $contentPath -and (Test-FolderHasContent $contentPath)
    $hasArchive = $false
    if ($contentPath -and $fileName) {
        $hasArchive = Test-Path -LiteralPath (Join-Path (Split-Path -Parent $contentPath) $fileName)
    }

    $status = if ($IsCustom) {
        if ($hasContent) { "Ready" } else { "Empty" }
    }
    elseif ($Record -and $extractedFlag -and $hasContent) { "Current" }
    elseif ($Record -and $hasArchive) { "Downloaded" }
    elseif ($hasContent) { "Present" }
    elseif ($Record) { "NotDownloaded" }
    else { "Registered" }

    return [PSCustomObject]@{
        Status          = $status
        FileName        = $fileName
        OSVersion       = $osVersion
        ReleaseDate     = $releaseDate
        ExtractedText   = if ($extractedFlag) { "Yes" } else { "No" }
        ContentLocation = $ContentLocation
        ContentPath     = $contentPath
        ModelFromPack   = $modelFromPack
    }
}

function Load-ManagedModelsGrid {
    # Managed list = ComputerModels.csv (with pack status from LocalCatalog when present).
    $shareCheck = Get-ShareValidation
    if (-not $shareCheck.IsValid) {
        $dgModels.ItemsSource = @()
        $txtModelsSummary.Text = $shareCheck.Message
        return
    }

    $share = $shareCheck.ShareRoot
    $driversRoot = Join-Path $share "Content\Drivers"
    $csvPath = Join-Path $driversRoot "ComputerModels.csv"
    $localCatPath = Get-LocalCatalogPath -ShareRoot $share
    $gridItems = [System.Collections.Generic.List[object]]::new()

    if (-not (Test-Path -LiteralPath $csvPath)) {
        $dgModels.ItemsSource = @()
        $txtModelsSummary.Text = "ComputerModels.csv missing - run Initialize on the Download tab."
        return
    }

    $allPacks = @(Get-AllLocalDrivePacks -LocalCatalogPath $localCatPath)

    foreach ($row in @(Import-Csv -LiteralPath $csvPath)) {
        $mfrRaw = [string]$row.Manufacturer
        $sku    = [string]$row.SystemSKUNumber
        $model  = [string]$row.ComputerModel
        if ([string]::IsNullOrWhiteSpace($mfrRaw)) { continue }

        $isCustom = $mfrRaw -like "Custom*"
        $folderVendor = Get-VendorFolderName $mfrRaw
        $nameForFolder = if ($model) { $model } else { $sku }
        $expectedLocation = if ($isCustom) {
            "Custom\$(Get-SafeName $nameForFolder)\Content"
        } else {
            "$folderVendor\$(Get-SafeName $nameForFolder)\Content"
        }

        $record = $null
        foreach ($packEntry in $allPacks) {
            $rec = $packEntry.Record
            $loc = [string](Get-PropValue -Obj $rec -Name "ContentLocation")
            $recModel = [string](Get-PropValue -Obj $rec -Name "Model")
            $skuVal = Get-PropValue -Obj $rec -Name "SystemSKU" -Default @()
            $skuList = @($skuVal | ForEach-Object { "$_" })

            $locMatch = $loc -and (
                ([IO.Path]::GetFullPath((Join-Path $driversRoot $loc)) -eq [IO.Path]::GetFullPath((Join-Path $driversRoot $expectedLocation)))
            )
            $modelMatch = $model -and $recModel -and ($recModel -eq $model)
            $skuMatch = $sku -and ($skuList -contains $sku)

            if ($locMatch -or ($modelMatch -and ($skuMatch -or -not $sku)) -or ($skuMatch -and $modelMatch)) {
                $record = $rec
                break
            }
        }

        $info = Resolve-PackStatus -Record $record -DriversRoot $driversRoot -ContentLocation $expectedLocation -IsCustom:$isCustom
        $gridItems.Add([PSCustomObject]@{
            Status          = $info.Status
            Manufacturer    = $mfrRaw
            Model           = $model
            SystemSKU       = $sku
            ContentLocation = $info.ContentLocation
            ContentPath     = $info.ContentPath
            Source          = "ComputerModels.csv"
        })
    }

    $dgModels.ItemsSource = [object[]]$gridItems
    $txtModelsSummary.Text = ('ComputerModels.csv rows: {0}  |  {1}' -f $gridItems.Count, $csvPath)
}

function Load-LocalCatalogGrid {
    # Downloaded / registered packs from LocalCatalog.json only.
    $shareCheck = Get-ShareValidation
    if (-not $shareCheck.IsValid) {
        $dgLocalCatalog.ItemsSource = @()
        $txtCatalogSummary.Text = $shareCheck.Message
        return
    }

    $share = $shareCheck.ShareRoot
    $driversRoot = Join-Path $share "Content\Drivers"
    $localCatPath = Get-LocalCatalogPath -ShareRoot $share
    $gridItems = [System.Collections.Generic.List[object]]::new()

    if (-not (Test-Path -LiteralPath $localCatPath)) {
        $dgLocalCatalog.ItemsSource = @()
        $txtCatalogSummary.Text = "LocalCatalog.json missing - run Initialize on the Download tab."
        return
    }

    foreach ($packEntry in @(Get-AllLocalDrivePacks -LocalCatalogPath $localCatPath)) {
        $rec = $packEntry.Record
        $loc = [string](Get-PropValue -Obj $rec -Name "ContentLocation")
        if (-not $loc) { continue }

        $displayMfr = [string](Get-PropValue -Obj $rec -Name "Manufacturer")
        if ([string]::IsNullOrWhiteSpace($displayMfr)) { $displayMfr = [string]$packEntry.VendorKey }
        $model = [string](Get-PropValue -Obj $rec -Name "Model")
        $skuVal = Get-PropValue -Obj $rec -Name "SystemSKU" -Default @()
        $skuText = if ($skuVal -is [System.Array]) { (@($skuVal) -join ",") } else { [string]$skuVal }
        $isCustom = ($packEntry.VendorKey -eq "Custom") -or ($loc -like "Custom\*")
        $info = Resolve-PackStatus -Record $rec -DriversRoot $driversRoot -ContentLocation $loc -IsCustom:$isCustom

        $gridItems.Add([PSCustomObject]@{
            Status           = $info.Status
            Manufacturer     = $displayMfr
            Model            = $model
            SystemSKU        = $skuText
            FileName         = $info.FileName
            OSVersion        = $info.OSVersion
            ReleaseDate      = $info.ReleaseDate
            ExtractedText    = $info.ExtractedText
            ContentLocation  = $info.ContentLocation
            ContentPath      = $info.ContentPath
            LocalCatalogPath = $localCatPath
            Source           = "LocalCatalog.json"
        })
    }

    $dgLocalCatalog.ItemsSource = [object[]]$gridItems
    $ready = @($gridItems | Where-Object { $_.Status -in @("Current", "Ready", "Downloaded") }).Count
    $txtCatalogSummary.Text = ('LocalCatalog packs: {0}  |  Ready/Downloaded: {1}  |  {2}' -f $gridItems.Count, $ready, $localCatPath)
}

function Refresh-DriverGrids {
    Load-ManagedModelsGrid
    Load-LocalCatalogGrid
}

function Get-ComputerModelsCsvPath {
    param([string]$ShareRoot)
    return (Join-Path $ShareRoot "Content\Drivers\ComputerModels.csv")
}

function Show-ComputerModelsCsvEditor {
    # In-app editor for Content\Drivers\ComputerModels.csv (fleet support list).
    $shareCheck = Get-ShareValidation
    if (-not $shareCheck.IsValid) {
        Show-Msg $shareCheck.Message "Invalid Share" "Warning"
        return $false
    }

    $share = $txtDeploymentShare.Text.Trim()
    $csvPath = Get-ComputerModelsCsvPath -ShareRoot $share
    if (-not (Test-Path -LiteralPath $csvPath)) {
        $create = Show-Msg "ComputerModels.csv does not exist yet.`n`nRun Initialize first, or create an empty CSV now?" "CSV Missing" "Question" "YesNo"
        if ($create -ne [System.Windows.MessageBoxResult]::Yes) { return $false }
        $driversDir = Split-Path -Parent $csvPath
        if (-not (Test-Path -LiteralPath $driversDir)) { New-Item -ItemType Directory -Path $driversDir -Force | Out-Null }
        Set-Content -Path $csvPath -Value "`"Manufacturer`",`"SystemSKUNumber`",`"ComputerModel`"`n`"Dell`",`"WinPE`",`"WinPE`"" -Encoding UTF8
    }

    $rowList = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach ($row in @(Import-Csv -LiteralPath $csvPath)) {
        $rowList.Add([PSCustomObject]@{
            Manufacturer    = [string]$row.Manufacturer
            SystemSKUNumber = [string]$row.SystemSKUNumber
            ComputerModel   = [string]$row.ComputerModel
        })
    }

    # OEM dropdown values; Custom / Custom_<Maker> entries are added when using Add Custom.
    $mfrOptions = [System.Collections.ObjectModel.ObservableCollection[string]]::new()
    foreach ($oem in @("Dell", "Lenovo", "HP")) { $mfrOptions.Add($oem) }
    foreach ($existing in @($rowList)) {
        $m = [string]$existing.Manufacturer
        if ($m -like "Custom*" -and -not (@($mfrOptions) -contains $m)) { $mfrOptions.Add($m) }
    }

    $dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Edit ComputerModels.csv" Height="520" Width="780" WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip"
        MinHeight="360" MinWidth="640" Background="$bgColor">
    <Window.Resources>$(Get-SharedXamlResources)</Window.Resources>
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,10">
            <TextBlock Text="FLEET SUPPORT LIST" FontSize="11" FontWeight="Bold" Foreground="$mutedFgColor"/>
            <TextBlock Text="$([System.Security.SecurityElement]::Escape($csvPath))" FontSize="11" Foreground="$secFgColor" Margin="0,4,0,0" TextWrapping="Wrap"/>
            <TextBlock Text="Pick Dell / Lenovo / HP from the dropdown. Use Add Custom for Custom or Custom_&lt;Maker&gt; models."
                       FontSize="11" Foreground="$mutedFgColor" Margin="0,6,0,0" TextWrapping="Wrap"/>
        </StackPanel>
        <DataGrid Name="dgCsv" Grid.Row="1" AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False"
                  Background="$surfaceBg" BorderBrush="$borderColor" BorderThickness="1" GridLinesVisibility="Horizontal"
                  FontSize="12" RowHeight="28" HeadersVisibility="Column" RowHeaderWidth="28"
                  ColumnHeaderStyle="{StaticResource DataGridHeaderStyle}"
                  RowStyle="{StaticResource DataGridRowStyle}" CellStyle="{StaticResource DataGridCellStyle}">
            <DataGrid.Columns>
                <DataGridComboBoxColumn Header="MANUFACTURER" SelectedItemBinding="{Binding Manufacturer, UpdateSourceTrigger=PropertyChanged}" Width="160"/>
                <DataGridTextColumn Header="SYSTEM SKU" Binding="{Binding SystemSKUNumber, UpdateSourceTrigger=PropertyChanged}" Width="140"/>
                <DataGridTextColumn Header="COMPUTER MODEL" Binding="{Binding ComputerModel, UpdateSourceTrigger=PropertyChanged}" Width="*"/>
            </DataGrid.Columns>
        </DataGrid>
        <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,10,0,0">
            <Button Name="btnAddRow" Content="Add OEM Row" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,8,0" Height="28" ToolTip="Add Dell / Lenovo / HP row"/>
            <Button Name="btnAddCustomRow" Content="Add Custom..." Style="{StaticResource PrimaryButtonStyle}" Margin="0,0,8,0" Height="28" ToolTip="Add a Custom or Custom_Maker model"/>
            <Button Name="btnRemoveRow" Content="Remove Selected" Style="{StaticResource SecondaryButtonStyle}" Height="28"/>
            <CheckBox Name="chkSyncAfterSave" Content="Sync Local Catalog after save" IsChecked="True" Margin="16,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button Name="btnOpenExternal" Content="Open in Notepad" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,8,0" Height="28"/>
            <Button Name="btnCancel" Content="Cancel" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,8,0" Width="90" Height="28"/>
            <Button Name="btnSave" Content="Save" Style="{StaticResource PrimaryButtonStyle}" Width="100" Height="28"/>
        </StackPanel>
    </Grid>
</Window>
"@

    $dlgReader = New-Object System.Xml.XmlNodeReader ([xml]$dlgXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($dlgReader)
    $dlg.Owner = $window

    $dgCsv = $dlg.FindName("dgCsv")
    $btnAddRow = $dlg.FindName("btnAddRow")
    $btnAddCustomRow = $dlg.FindName("btnAddCustomRow")
    $btnRemoveRow = $dlg.FindName("btnRemoveRow")
    $chkSyncAfterSave = $dlg.FindName("chkSyncAfterSave")
    $btnOpenExternal = $dlg.FindName("btnOpenExternal")
    $btnSave = $dlg.FindName("btnSave")
    $btnCancel = $dlg.FindName("btnCancel")

    # Wire manufacturer ComboBox items (Dell / Lenovo / HP + any existing Custom_* labels).
    $mfrCol = $dgCsv.Columns | Where-Object { $_.Header -eq "MANUFACTURER" } | Select-Object -First 1
    if ($mfrCol) { $mfrCol.ItemsSource = $mfrOptions }

    $dgCsv.ItemsSource = $rowList
    $script:csvEditorSaved = $false
    $script:csvEditorSync = $false

    function Add-CsvEditorRow {
        param([string]$Manufacturer, [string]$SystemSKU = "", [string]$ComputerModel = "")
        if ($Manufacturer -like "Custom*" -and -not (@($mfrOptions) -contains $Manufacturer)) {
            $mfrOptions.Add($Manufacturer)
        }
        $rowList.Add([PSCustomObject]@{
            Manufacturer    = $Manufacturer
            SystemSKUNumber = $SystemSKU
            ComputerModel   = $ComputerModel
        })
        $dgCsv.Items.Refresh()
        if ($rowList.Count -gt 0) {
            $dgCsv.SelectedIndex = $rowList.Count - 1
            $dgCsv.ScrollIntoView($dgCsv.SelectedItem)
        }
    }

    $btnAddRow.add_Click({
        Add-CsvEditorRow -Manufacturer "Dell"
    })

    $btnAddCustomRow.add_Click({
        $data = Show-AddCustomDialog
        if (-not $data) { return }
        $label = if ($data.CustomManufacturer) { "Custom_$($data.CustomManufacturer)" } else { "Custom" }
        Add-CsvEditorRow -Manufacturer $label -SystemSKU $data.SystemSKU -ComputerModel $data.ComputerModel
    })

    $btnRemoveRow.add_Click({
        $sel = $dgCsv.SelectedItem
        if (-not $sel) {
            Show-Msg "Select a row to remove." "Selection Required" "Warning"
            return
        }
        if ($rowList.Contains($sel)) {
            $null = $rowList.Remove($sel)
        }
        $dgCsv.Items.Refresh()
    })

    $btnOpenExternal.add_Click({
        Start-Process -FilePath "notepad.exe" -ArgumentList $csvPath
        Show-Msg "Opened in Notepad. Save there, then Cancel this dialog and click Refresh List (or re-open Edit and reload)." "Opened Externally" "Information"
    })

    $btnCancel.add_Click({ $dlg.DialogResult = $false; $dlg.Close() })

    $btnSave.add_Click({
        try {
            $dgCsv.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true)
        } catch {}

        $export = [System.Collections.Generic.List[object]]::new()
        foreach ($item in @($dgCsv.Items)) {
            if ($null -eq $item -or $item -is [System.Windows.Data.CollectionViewGroup]) { continue }
            if ($item.ToString() -eq "{NewItemPlaceholder}") { continue }

            $mfr = ""
            $sku = ""
            $mdl = ""
            try {
                $mfr = [string](Get-PropValue -Obj $item -Name "Manufacturer")
                $sku = [string](Get-PropValue -Obj $item -Name "SystemSKUNumber")
                $mdl = [string](Get-PropValue -Obj $item -Name "ComputerModel")
            } catch { continue }

            if ([string]::IsNullOrWhiteSpace($mfr) -and [string]::IsNullOrWhiteSpace($sku) -and [string]::IsNullOrWhiteSpace($mdl)) {
                continue
            }
            if ([string]::IsNullOrWhiteSpace($mfr)) {
                Show-Msg "Every row needs a Manufacturer (use the dropdown or Add Custom)." "Validation" "Warning"
                return
            }
            if ($mfr -notin @("Dell", "Lenovo", "HP") -and $mfr -notlike "Custom*") {
                Show-Msg "Manufacturer '$mfr' is not valid. Use Dell, Lenovo, HP, or Add Custom." "Validation" "Warning"
                return
            }
            $export.Add([pscustomobject]@{
                Manufacturer    = $mfr.Trim()
                SystemSKUNumber = $sku.Trim()
                ComputerModel   = $mdl.Trim()
            })
        }

        if ($export.Count -eq 0) {
            Show-Msg "CSV would be empty. Add at least one model row, or Cancel." "Validation" "Warning"
            return
        }

        @($export) | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-UiLog "Saved ComputerModels.csv ($($export.Count) row(s))."
        $script:csvEditorSaved = $true
        $script:csvEditorSync = [bool]$chkSyncAfterSave.IsChecked
        $dlg.DialogResult = $true
        $dlg.Close()
    })

    $dlg.Add_KeyDown({ if ($_.Key -eq [System.Windows.Input.Key]::Escape) { $dlg.Close() } })
    $null = $dlg.ShowDialog()

    return [PSCustomObject]@{
        Saved = [bool]$script:csvEditorSaved
        Sync  = [bool]$script:csvEditorSync
    }
}

function Show-AddCustomDialog {
    $dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Add Custom Driver Model" Height="280" Width="480" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="$bgColor">
    <Window.Resources>$(Get-SharedXamlResources)</Window.Resources>
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid Grid.Row="0" Margin="0,0,0,10">
            <Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Text="Computer Model:" VerticalAlignment="Center" Foreground="$fgColor" FontWeight="SemiBold"/>
            <TextBox Name="txtModel" Grid.Column="1" Height="26"/>
        </Grid>
        <Grid Grid.Row="1" Margin="0,0,0,10">
            <Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Text="System SKU:" VerticalAlignment="Center" Foreground="$fgColor" FontWeight="SemiBold"/>
            <TextBox Name="txtSku" Grid.Column="1" Height="26"/>
        </Grid>
        <Grid Grid.Row="2" Margin="0,0,0,10">
            <Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock Text="Maker (optional):" VerticalAlignment="Center" Foreground="$fgColor" FontWeight="SemiBold"/>
            <TextBox Name="txtMaker" Grid.Column="1" Height="26" ToolTip="Stored as Custom_&lt;Maker&gt; (e.g. Panasonic)"/>
        </Grid>
        <TextBlock Grid.Row="3" Text="Creates Custom\&lt;Model&gt;\Content and a ComputerModels.csv row. Copy INF drivers into that Content folder."
                   TextWrapping="Wrap" Foreground="$mutedFgColor" FontSize="11"/>
        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="btnCancel" Content="Cancel" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,8,0" Width="90" Height="28"/>
            <Button Name="btnSave" Content="Add" Style="{StaticResource PrimaryButtonStyle}" Width="90" Height="28"/>
        </StackPanel>
    </Grid>
</Window>
"@
    $dlgReader = New-Object System.Xml.XmlNodeReader ([xml]$dlgXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($dlgReader)
    $dlg.Owner = $window
    $txtModel = $dlg.FindName("txtModel")
    $txtSku   = $dlg.FindName("txtSku")
    $txtMaker = $dlg.FindName("txtMaker")
    $btnSave  = $dlg.FindName("btnSave")
    $btnCancel = $dlg.FindName("btnCancel")
    $script:customResult = $null
    $btnCancel.add_Click({ $dlg.DialogResult = $false; $dlg.Close() })
    $btnSave.add_Click({
        if ([string]::IsNullOrWhiteSpace($txtModel.Text) -and [string]::IsNullOrWhiteSpace($txtSku.Text)) {
            Show-Msg "Enter a Computer Model and/or System SKU." "Required" "Warning"
            return
        }
        $script:customResult = @{
            ComputerModel      = $txtModel.Text.Trim()
            SystemSKU          = $txtSku.Text.Trim()
            CustomManufacturer = $txtMaker.Text.Trim()
        }
        $dlg.DialogResult = $true
        $dlg.Close()
    })
    $null = $dlg.ShowDialog()
    return $script:customResult
}

function Open-DriversContentFolder {
    $shareCheck = Get-ShareValidation
    if (-not $shareCheck.IsValid) {
        Show-Msg $shareCheck.Message "Invalid Share" "Warning"
        return
    }
    $path = Join-Path $shareCheck.ShareRoot "Content\Drivers"
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    Start-Process explorer.exe $path
}

function Remove-SelectedComputerModel {
    $selected = $dgModels.SelectedItem
    if (-not $selected) {
        Show-Msg "Select a model row on Managed Computer Models first." "Selection Required" "Warning"
        return
    }
    $mfr = [string]$selected.Manufacturer
    $sku = [string]$selected.SystemSKU
    $model = [string]$selected.Model
    $loc = [string]$selected.ContentLocation
    $contentPath = [string]$selected.ContentPath

    $confirm = Show-Msg ("Remove this managed computer model?`n`nManufacturer: {0}`nModel: {1}`nSKU: {2}`n`nComputerModels.csv and LocalCatalog.json will be updated. You can choose to delete driver files next." -f $mfr, $model, $sku) `
        "Confirm Delete Model" "Stop" "YesNo"
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $share = $txtDeploymentShare.Text.Trim()
    $driversRoot = Join-Path $share "Content\Drivers"
    $csvPath = Join-Path $driversRoot "ComputerModels.csv"
    $localCatPath = Get-LocalCatalogPath -ShareRoot $share

    if (-not (Test-Path -LiteralPath $csvPath)) {
        throw "ComputerModels.csv not found: $csvPath"
    }

    $keptCsv = [System.Collections.Generic.List[object]]::new()
    $removedCsv = 0
    foreach ($row in @(Import-Csv -LiteralPath $csvPath)) {
        $rowMfr = [string]$row.Manufacturer
        $rowSku = [string]$row.SystemSKUNumber
        $rowModel = [string]$row.ComputerModel
        if ($sku -and $model) {
            $match = ($rowMfr -eq $mfr) -and ($rowSku -eq $sku) -and ($rowModel -eq $model)
        }
        elseif ($sku) {
            $match = ($rowMfr -eq $mfr) -and ($rowSku -eq $sku)
        }
        elseif ($model) {
            $match = ($rowMfr -eq $mfr) -and ($rowModel -eq $model)
        }
        else {
            $match = $false
        }

        if ($match) {
            $removedCsv++
            continue
        }
        $keptCsv.Add([pscustomobject]@{
            Manufacturer    = $rowMfr
            SystemSKUNumber = $rowSku
            ComputerModel   = $rowModel
        })
    }

    if ($removedCsv -eq 0) {
        throw "No matching ComputerModels.csv row found for $mfr / $model / $sku."
    }

    @($keptCsv) | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-UiLog "Removed $removedCsv row(s) from ComputerModels.csv."

    if (Test-Path -LiteralPath $localCatPath) {
        $localCat = Get-Content -LiteralPath $localCatPath -Raw | ConvertFrom-Json
        $mfrNode = Get-PropValue -Obj $localCat -Name "Manufacturers" -Default $null
        if ($mfrNode) {
            foreach ($mfrProp in @($mfrNode.PSObject.Properties)) {
                $entry = $mfrProp.Value
                if (-not $entry) { continue }
                $packs = @(Get-PropValue -Obj $entry -Name "DrivePacks" -Default @())
                if (-not $packs) { continue }
                $keptPacks = foreach ($rec in $packs) {
                    if (-not $rec) { continue }
                    $recLoc = [string](Get-PropValue -Obj $rec -Name "ContentLocation")
                    $recModel = [string](Get-PropValue -Obj $rec -Name "Model")
                    $skuVal = Get-PropValue -Obj $rec -Name "SystemSKU" -Default @()
                    $skuList = @($skuVal | ForEach-Object { "$_" })

                    $drop = $false
                    if ($loc -and $recLoc) {
                        try {
                            $drop = ([IO.Path]::GetFullPath((Join-Path $driversRoot $recLoc)) -eq [IO.Path]::GetFullPath((Join-Path $driversRoot $loc)))
                        } catch { $drop = ($recLoc -eq $loc) }
                    }
                    if (-not $drop -and $model -and $recModel -and ($recModel -eq $model)) {
                        if (-not $sku -or ($skuList -contains $sku)) { $drop = $true }
                    }
                    if (-not $drop) { $rec }
                }
                $entry.DrivePacks = @($keptPacks)
            }
            ($localCat | ConvertTo-Json -Depth 8) | Set-Content -Path $localCatPath -Encoding UTF8
            Write-UiLog "Updated LocalCatalog.json (removed matching DrivePack entries)."
        }
    }

    $modelDir = $null
    if ($contentPath) { $modelDir = Split-Path -Parent $contentPath }
    elseif ($loc) {
        $contentPath = Join-Path $driversRoot $loc
        $modelDir = Split-Path -Parent $contentPath
    }

    if ($modelDir -and (Test-Path -LiteralPath $modelDir)) {
        $delFiles = Show-Msg ("Also delete driver files on disk?`n`n$modelDir`n`nThis cannot be undone.") "Delete Files" "Warning" "YesNo"
        if ($delFiles -eq [System.Windows.MessageBoxResult]::Yes) {
            Remove-Item -LiteralPath $modelDir -Recurse -Force
            Write-UiLog "Deleted folder: $modelDir"
        }
    }

    Invoke-DriverEngine -Action Sync -Extra @{ All = $true }
    Refresh-DriverGrids
    Show-Msg "Model removed and LocalCatalog synced." "Deleted" "Information"
}

# Initial share
$initialShare = Resolve-InitialSharePath
if ($initialShare) { $txtDeploymentShare.Text = $initialShare }

Write-UiLog "LiteDeploy Driver Manager ready. Select a share with Config\BootConfig.json, then Initialize / Get Catalog / Download."
Update-ShareValidationUi | Out-Null

$txtDeploymentShare.add_TextChanged({
    Update-ShareValidationUi | Out-Null
})

$mainTabControl.add_SelectionChanged({
    param($sender, $e)
    if ($e.Source -ne $mainTabControl) { return }
    if ($mainTabControl.SelectedItem -eq $tabModels) { Load-ManagedModelsGrid }
    elseif ($mainTabControl.SelectedItem -eq $tabLocalCatalog) { Load-LocalCatalogGrid }
})

$btnBrowseShare.add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog -Property @{ Description = "Select LiteDeploy Deployment Share Root (must contain Config\BootConfig.json)" }
    if (Test-Path $txtDeploymentShare.Text) { $dlg.SelectedPath = $txtDeploymentShare.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtDeploymentShare.Text = $dlg.SelectedPath
        $v = Update-ShareValidationUi
        if (-not $v.IsValid) {
            Show-Msg $v.Message "Invalid Deployment Share" "Warning"
        }
        Refresh-DriverGrids
    }
})

$btnClearLog.add_Click({
    $txtLog.Text = ""
    Write-UiLog "Log cleared."
})

$btnInit.add_Click({
    try {
        Set-Busy $true
        Invoke-DriverEngine -Action Init
        Refresh-DriverGrids
        Set-Busy $false

        $csvPath = Get-ComputerModelsCsvPath -ShareRoot $txtDeploymentShare.Text.Trim()
        if (Test-Path -LiteralPath $csvPath) {
            Write-UiLog "Opening ComputerModels.csv for editing..."
            $mainTabControl.SelectedItem = $tabModels
            $result = Show-ComputerModelsCsvEditor
            if ($result -and $result.Saved) {
                if ($result.Sync) {
                    Set-Busy $true
                    Write-UiLog "Syncing LocalCatalog.json after CSV edit..."
                    Invoke-DriverEngine -Action Sync -Extra @{ All = $true }
                }
                Refresh-DriverGrids
            }
        }
    }
    catch { Write-UiLog "ERROR: $_"; Show-Msg "$_" "Init Failed" "Error" }
    finally { Set-Busy $false }
})

$btnGetCatalog.add_Click({
    try {
        Set-Busy $true
        $extra = @{ All = ($cmbManufacturer.SelectedItem -eq "All") }
        Invoke-DriverEngine -Action GetCatalog -Extra $extra
    }
    catch { Write-UiLog "ERROR: $_"; Show-Msg "$_" "Get Catalog Failed" "Error" }
    finally { Set-Busy $false }
})

$btnCheckUpdate.add_Click({
    try {
        Set-Busy $true
        Invoke-DriverEngine -Action CheckUpdate -Extra @{ All = ($cmbManufacturer.SelectedItem -eq "All") }
    }
    catch { Write-UiLog "ERROR: $_"; Show-Msg "$_" "Check Update Failed" "Error" }
    finally { Set-Busy $false }
})

$btnDownloadAll.add_Click({
    $confirm = Show-Msg "Download driver packs for every model in ComputerModels.csv?`n`nExtract after download: $(if ([bool]$chkExtract.IsChecked) { 'Yes' } else { 'No (archives only)' })" "Confirm Fleet Download" "Question" "YesNo"
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }
    try {
        Set-Busy $true
        Invoke-DriverEngine -Action Download -Extra @{ All = $true }
        Refresh-DriverGrids
        $mainTabControl.SelectedItem = $tabLocalCatalog
        Show-Msg "Fleet download finished." "Download Complete" "Information"
    }
    catch { Write-UiLog "ERROR: $_"; Show-Msg "$_" "Fleet Download Failed" "Error" }
    finally { Set-Busy $false }
})

$btnRefreshModels.add_Click({ Load-ManagedModelsGrid })
$btnRefreshCatalog.add_Click({ Load-LocalCatalogGrid })

$btnEditCsv.add_Click({
    try {
        $result = Show-ComputerModelsCsvEditor
        if (-not $result -or -not $result.Saved) { return }
        if ($result.Sync) {
            Set-Busy $true
            Write-UiLog "Syncing LocalCatalog.json after CSV edit..."
            Invoke-DriverEngine -Action Sync -Extra @{ All = $true }
        }
        Refresh-DriverGrids
        Show-Msg "ComputerModels.csv saved$(if ($result.Sync) { ' and LocalCatalog synced' })." "CSV Saved" "Information"
    }
    catch { Write-UiLog "ERROR: $_"; Show-Msg "$_" "Edit CSV Failed" "Error" }
    finally { Set-Busy $false }
})

$btnSyncCatalog.add_Click({
    try {
        Set-Busy $true
        Write-UiLog "Syncing LocalCatalog.json to ComputerModels.csv and on-disk packs..."
        Invoke-DriverEngine -Action Sync -Extra @{ All = $true }
        Refresh-DriverGrids
        Show-Msg "LocalCatalog reconciled with ComputerModels.csv." "Sync Complete" "Information"
    }
    catch { Write-UiLog "ERROR: $_"; Show-Msg "$_" "Sync Failed" "Error" }
    finally { Set-Busy $false }
})

$btnDeleteModel.add_Click({
    try {
        Set-Busy $true
        Remove-SelectedComputerModel
    }
    catch { Write-UiLog "ERROR: $_"; Show-Msg "$_" "Delete Failed" "Error" }
    finally { Set-Busy $false }
})

$btnAddCustom.add_Click({
    $data = Show-AddCustomDialog
    if (-not $data) { return }
    try {
        Set-Busy $true
        $extra = @{
            ComputerModel = $data.ComputerModel
            SystemSKU     = $data.SystemSKU
        }
        if ($data.CustomManufacturer) { $extra["CustomManufacturer"] = $data.CustomManufacturer }
        Invoke-DriverEngine -Action AddCustom -Extra $extra
        Refresh-DriverGrids
        $mainTabControl.SelectedItem = $tabModels
        Show-Msg "Custom model registered. Copy INF drivers into its Content folder." "Custom Model Added" "Information"
    }
    catch { Write-UiLog "ERROR: $_"; Show-Msg "$_" "Add Custom Failed" "Error" }
    finally { Set-Busy $false }
})

$btnOpenDriversFolder.add_Click({ Open-DriversContentFolder })
$btnOpenCatalogFolder.add_Click({ Open-DriversContentFolder })

$window.Add_KeyDown({ if ($_.Key -eq [System.Windows.Input.Key]::Escape) { $window.Close() } })

if ((Get-ShareValidation).IsValid) { Refresh-DriverGrids }
$null = $window.ShowDialog()
# endregion
