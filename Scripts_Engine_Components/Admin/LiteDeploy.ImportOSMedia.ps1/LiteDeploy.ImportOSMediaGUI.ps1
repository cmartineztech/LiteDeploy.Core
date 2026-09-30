<#
.SYNOPSIS
    Windows OS Media Importer & Catalog Manager - Modern WPF Graphical Interface.
.DESCRIPTION
    Modern WPF application for importing Windows OS setup media (ISO/WIM/ESD), managing
    WIM edition selections, viewing payload catalog metadata, and generating central catalog.json.
.PARAMETER DefaultDeploymentShare
    Initial deployment share directory path. Defaults to parent folder of script root.
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
    [Parameter(Mandatory = $false)][string]$DefaultDeploymentShare = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet("Light", "Dark")][string]$Theme = "Light",
    [string]$WindowTitle = "LiteDeploy - Windows OS Media Importer & Catalog Manager",
    [switch]$DarkMode
)

# Enforce Administrator Rights & Self-Elevate if required
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

# Enforce STA (Single Threaded Apartment) Mode required for WPF UI controls
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
$screenWidth  = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
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

# Palette Color Definitions
$bgColor           = if ($isDark) { "#121212" } else { "#FFFFFF" }
$fgColor           = if ($isDark) { "#F3F4F6" } else { "#111827" }
$secFgColor        = if ($isDark) { "#9CA3AF" } else { "#4B5563" }
$mutedFgColor      = if ($isDark) { "#9CA3AF" } else { "#687684" }
$surfaceBg         = if ($isDark) { "#1E1E1E" } else { "#F7F9FB" }
$footerBg          = if ($isDark) { "#181818" } else { "#F7F9FB" }
$headerBg          = if ($isDark) { "#005A9E" } else { "#005A9E" }
$headerFg          = if ($isDark) { "#FFFFFF" } else { "#FFFFFF" }
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
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="$fgColor"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="6,2"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="DataGridCell">
                        <Border Background="{TemplateBinding Background}" BorderThickness="0" Padding="{TemplateBinding Padding}">
                            <ContentPresenter VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="Transparent"/>
                    <Setter Property="Foreground" Value="$fgColor"/>
                </Trigger>
                <Trigger Property="IsFocused" Value="True">
                    <Setter Property="Background" Value="Transparent"/>
                    <Setter Property="Foreground" Value="$fgColor"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="ModernProgressBarStyle" TargetType="ProgressBar">
            <Setter Property="Height" Value="8"/><Setter Property="Background" Value="$trackBg"/>
            <Setter Property="Foreground" Value="$headerColor"/><Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Grid x:Name="TemplateRoot">
                            <Border x:Name="PART_Track" Background="{TemplateBinding Background}" CornerRadius="4"/>
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
            <Setter Property="Padding" Value="20,5"/><Setter Property="Cursor" Value="Hand"/>
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
                            <ContentPresenter x:Name="ContentSite" VerticalAlignment="Center" HorizontalAlignment="Center" ContentSource="Header"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="$surfaceBg"/>
                                <Setter TargetName="Border" Property="BorderBrush" Value="$headerColor"/>
                                <Setter Property="Foreground" Value="$headerColor"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="$buttonHoverBg"/>
                            </Trigger>
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
                            <Trigger Property="IsFocused" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="$headerColor"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="$disabledBg"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="$disabledBorder"/>
                                <Setter Property="Foreground" Value="$disabledFg"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="$fgColor"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>

        <Style TargetType="ScrollBar">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Width" Value="8"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid x:Name="Bg" Background="Transparent" SnapsToDevicePixels="true">
                            <Track x:Name="PART_Track" IsDirectionReversed="true">
                                <Track.Thumb>
                                    <Thumb x:Name="Thumb">
                                        <Thumb.Template>
                                            <ControlTemplate TargetType="Thumb">
                                                <Border Background="$borderColor" CornerRadius="4"/>
                                            </ControlTemplate>
                                        </Thumb.Template>
                                    </Thumb>
                                </Track.Thumb>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
"@
}

# Construct Main Application XAML Markup
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

                <!-- Top Header Banner -->
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
                            <TextBlock Text="Windows OS Media Importer &amp; Catalog Manager" Foreground="#D9EFFF" FontSize="11.5" Margin="0,1,0,0"/>
                        </StackPanel>

                        <Border Grid.Column="2" Background="#20FFFFFF" CornerRadius="4" Padding="10,5" VerticalAlignment="Center">
                            <TextBlock Text="MEDIA MANAGER" Foreground="White" FontSize="10.5" FontWeight="Bold"/>
                        </Border>
                    </Grid>
                </Border>

                <!-- Body Content Area -->
                <Grid Grid.Row="1" Margin="20,14,20,10">
                    <TabControl Name="mainTabControl" Background="Transparent" BorderThickness="0">
                        <!-- TAB 1: IMPORT OS MEDIA -->
                        <TabItem Header="Import New OS Media">
                            <Grid Margin="0,14,0,0">
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="*"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>

                                <!-- Configuration Card -->
                                <Border Grid.Row="0" Background="$surfaceBg" BorderBrush="$borderColor" BorderThickness="1" CornerRadius="6" Padding="16,14" Margin="0,0,0,10">
                                    <StackPanel>
                                        <TextBlock Text="DEPLOYMENT SHARE &amp; SOURCE MEDIA LOCATION" FontSize="11" FontWeight="Bold" Foreground="$mutedFgColor" Margin="0,0,0,10"/>
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

                                        <Grid Margin="0,0,0,10">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="150"/>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="230"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Source ISO or Folder:" VerticalAlignment="Center" FontWeight="SemiBold" Foreground="$fgColor" FontSize="11.5"/>
                                            <TextBox Name="txtSourcePath" Grid.Column="1" Margin="0,0,8,0" Height="26" VerticalContentAlignment="Center" FontSize="11.5" ToolTip="Drag and drop an ISO file or folder here"/>
                                            <StackPanel Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right">
                                                <Button Name="btnBrowseIso" Content="Select ISO..." Style="{StaticResource SecondaryButtonStyle}" Width="105" Height="26" Margin="0,0,6,0"/>
                                                <Button Name="btnBrowseFolder" Content="Select Folder..." Style="{StaticResource SecondaryButtonStyle}" Width="115" Height="26"/>
                                            </StackPanel>
                                        </Grid>

                                        <Grid Margin="0,0,0,8">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="150"/>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="105"/>
                                            </Grid.ColumnDefinitions>
                                            <CheckBox Name="chkUseCustomWim" Grid.Column="0" Content="Use Custom WIM/ESD:" VerticalAlignment="Center" FontWeight="SemiBold" FontSize="11.5"/>
                                            <TextBox Name="txtCustomWim" Grid.Column="1" Margin="0,0,8,0" Height="26" VerticalContentAlignment="Center" IsEnabled="False" FontSize="11.5" ToolTip="Drag and drop a custom install.wim file here"/>
                                            <Button Name="btnBrowseWim" Grid.Column="2" Content="Select Image..." Style="{StaticResource SecondaryButtonStyle}" Width="105" Height="26" HorizontalAlignment="Right" IsEnabled="False"/>
                                        </Grid>

                                        <Grid Margin="0,0,0,0">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="150"/>
                                                <ColumnDefinition Width="*"/>
                                            </Grid.ColumnDefinitions>
                                            <CheckBox Name="chkUse7Zip" Grid.Column="0" Content="7-Zip Auto Extract" IsChecked="True" VerticalAlignment="Center" FontWeight="SemiBold" FontSize="11.5" ToolTip="Uses 7-Zip CLI to extract registry &amp; auto-detect official OS Name"/>
                                            <StackPanel Grid.Column="1">
                                                <TextBlock Name="lblOsName" Text="OS Full Name (Auto-Extracted via 7-Zip Registry Extractor):" FontSize="10.5" Foreground="$secFgColor" Margin="0,0,0,3"/>
                                                <TextBox Name="txtOsName" Height="26" VerticalContentAlignment="Center" IsEnabled="False" FontSize="11.5"/>
                                            </StackPanel>
                                        </Grid>
                                    </StackPanel>
                                </Border>

                                <TextBlock Grid.Row="1" Text="EXECUTION &amp; EXTRACTION LOG" FontSize="11" FontWeight="Bold" Foreground="$mutedFgColor" Margin="0,0,0,6"/>

                                <!-- Log Output Console Box -->
                                <Border Grid.Row="2" Background="$logBg" BorderBrush="$borderColor" BorderThickness="1" CornerRadius="5" Padding="6,4">
                                    <TextBox Name="txtLog" BorderThickness="0" Background="Transparent" Foreground="$logFg" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" IsReadOnly="True" FontFamily="Consolas" FontSize="11.5"/>
                                </Border>

                                <!-- Progress Bar & Primary Action Bar -->
                                <StackPanel Grid.Row="3" Margin="0,10,0,0">
                                    <ProgressBar Name="pbImport" Style="{StaticResource ModernProgressBarStyle}" Visibility="Collapsed" Margin="0,0,0,10"/>
                                    <Grid>
                                        <Button Name="btnRebuildOnly" Content="Rebuild Catalog Only" Style="{StaticResource SecondaryButtonStyle}" HorizontalAlignment="Left"/>
                                        <Button Name="btnImport" Content="Import OS Media" Style="{StaticResource PrimaryButtonStyle}" HorizontalAlignment="Right"/>
                                    </Grid>
                                </StackPanel>
                            </Grid>
                        </TabItem>

                        <!-- TAB 2: MANAGE CATALOG -->
                        <TabItem Name="tabManage" Header="Manage Catalog &amp; Payloads">
                            <Grid Margin="0,14,0,0">
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="*"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>

                                <DockPanel Grid.Row="0" Margin="0,0,0,10">
                                    <TextBlock Text="IMPORTED OS MEDIA PAYLOAD CATALOG" FontSize="11" FontWeight="Bold" Foreground="$mutedFgColor" DockPanel.Dock="Left"/>
                                    <TextBlock Name="txtCatalogSummary" Text="Total Payloads: 0  |  Active: 0" Foreground="$secFgColor" FontSize="11.5" FontWeight="SemiBold" HorizontalAlignment="Right" DockPanel.Dock="Right"/>
                                </DockPanel>

                                <DataGrid Name="dgOsCatalog" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True" Background="$surfaceBg" BorderBrush="$borderColor" BorderThickness="1" GridLinesVisibility="None" SelectionMode="Single" FontSize="12" RowHeight="28" ColumnHeaderStyle="{StaticResource DataGridHeaderStyle}" RowStyle="{StaticResource DataGridRowStyle}" CellStyle="{StaticResource DataGridCellStyle}" HeadersVisibility="Column" RowHeaderWidth="0" ToolTip="Double-click any row to manage its WIM editions">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="STATUS" Binding="{Binding EnabledText}" Width="100"/>
                                        <DataGridTextColumn Header="FULL NAME" Binding="{Binding FullName}" Width="180"/>
                                        <DataGridTextColumn Header="LANG" Binding="{Binding DefaultLanguage}" Width="60"/>
                                        <DataGridTextColumn Header="PAYLOAD TYPE" Binding="{Binding IsCustomText}" Width="110"/>
                                        <DataGridTextColumn Header="IMPORTED DATE" Binding="{Binding ImportedDate}" Width="110"/>
                                        <DataGridTextColumn Header="MEDIA ROOT FOLDER" Binding="{Binding MediaRoot}" Width="*"/>
                                    </DataGrid.Columns>
                                </DataGrid>

                                <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
                                    <Button Name="btnRefreshCatalog" Content="Refresh List" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,10,0"/>
                                    <Button Name="btnManageEditions" Content="Manage Editions..." Style="{StaticResource PrimaryButtonStyle}" Margin="0,0,10,0"/>
                                    <Button Name="btnDeleteOs" Content="Delete OS Media Payload" Style="{StaticResource DangerButtonStyle}"/>
                                </StackPanel>
                            </Grid>
                        </TabItem>
                    </TabControl>
                </Grid>

                <!-- Footer Bar -->
                <Border Grid.Row="2" Background="$footerBg" Padding="20,12" BorderBrush="$borderColor" BorderThickness="0,1,0,0">
                    <Grid>
                        <TextBlock Name="TxtStatusSummary" Text="LiteDeploy Importer Ready. Configure inputs and click 'Import OS Media'." Foreground="$secFgColor" FontSize="11" VerticalAlignment="Center" HorizontalAlignment="Left"/>
                        <Button Name="btnClearForm" Content="Clear Inputs" Style="{StaticResource SecondaryButtonStyle}" HorizontalAlignment="Right" ToolTip="Reset all input fields and clear execution logs"/>
                    </Grid>
                </Border>
            </Grid>
        </Border>
    </Viewbox>
</Window>
"@
# endregion

# region 4. LOGGING, UTILITY & CONTROLLER SERVICES
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)
if ($null -eq $window) { exit }

# Map Controls from XAML DOM
@("mainTabControl", "txtDeploymentShare", "txtSourcePath", "chkUseCustomWim", "txtCustomWim",
  "btnBrowseWim", "txtOsName", "lblOsName", "chkUse7Zip", "txtLog", "pbImport", "TxtStatusSummary",
  "btnBrowseShare", "btnBrowseIso", "btnBrowseFolder", "btnRebuildOnly", "btnImport", "btnClearForm",
  "tabManage", "dgOsCatalog", "txtCatalogSummary", "btnRefreshCatalog", "btnManageEditions", "btnDeleteOs"
) | ForEach-Object { Set-Variable -Name $_ -Value ($window.FindName($_)) -Scope Script }
$txtStatusSummary = $TxtStatusSummary

# Controller Helper Functions
function Get-SafeProp {
    param([psobject]$Obj, [string[]]$PropNames, [object]$DefaultValue = $null)
    if (-not $Obj) { return $DefaultValue }
    foreach ($pName in $PropNames) {
        $prop = $Obj.PSObject.Properties | Where-Object { $_.Name -eq $pName }
        if ($prop -and $null -ne $prop.Value) { return $prop.Value }
    }
    return $DefaultValue
}

function Format-CleanJson {
    param([object]$InputObject)
    $json = $InputObject | ConvertTo-Json -Depth 10
    return ($json -replace '(?m)^(\s*"[^"]+":)\s{2,}', '$1 ')
}

function Do-Events {
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Render)
}

function Brush([string]$Color) {
    [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function Write-UiLog {
    param([string]$Message)
    $txtLog.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] $Message`n")
    $txtLog.ScrollToEnd()
    if ($txtStatusSummary) { $txtStatusSummary.Text = $Message }
    Do-Events
}

function Show-Msg {
    param([string]$Message, [string]$Title = "Notice", [string]$Icon = "Information", [string]$Buttons = "OK")
    return [System.Windows.MessageBox]::Show($Message, $Title, [System.Windows.MessageBoxButton]::$Buttons, [System.Windows.MessageBoxImage]::$Icon)
}

function Get-ImportScriptPath {
    $candidates = @(
        (Join-Path $PSScriptRoot "LiteDeploy.ImportOSMedia.ps1"),
        (Join-Path (Get-Location).Path "LiteDeploy.ImportOSMedia.ps1"),
        (Join-Path (Split-Path -Parent $PSScriptRoot) "LiteDeploy.ImportOSMedia.ps1"),
        (Join-Path $PSScriptRoot "Import-OSMedia.ps1")
    )
    foreach ($cand in $candidates) {
        if (Test-Path $cand) { return (Resolve-Path $cand).Path }
    }
    return (Join-Path $PSScriptRoot "LiteDeploy.ImportOSMedia.ps1")
}

function Clear-ImportForm {
    param([switch]$ClearLog)
    $txtSourcePath.Text = ""
    $chkUseCustomWim.IsChecked = $false
    $txtCustomWim.Text = ""
    $chkUse7Zip.IsChecked = $true
    $txtOsName.Text = ""
    if ($ClearLog) {
        $txtLog.Text = ""
        Write-UiLog "LiteDeploy Importer Ready. Configure inputs and click 'Import OS Media'."
    }
    Update-ImportButtonState
}

function Load-CatalogDataGrid {
    $shareDir  = $txtDeploymentShare.Text
    $osRootDir = Join-Path $shareDir "Content\OperatingSystems"
    $gridItems = [System.Collections.Generic.List[object]]::new()

    if (Test-Path $osRootDir) {
        $osJsonFiles = Get-ChildItem -Path $osRootDir -Recurse -Filter "os.json"
        foreach ($file in $osJsonFiles) {
            try {
                $rawJson = [System.IO.File]::ReadAllText($file.FullName)
                if ([string]::IsNullOrWhiteSpace($rawJson)) { continue }
                $osData = $rawJson | ConvertFrom-Json
                if (-not $osData) { continue }

                $editions = Get-SafeProp -Obj $osData -PropNames "editions"
                $enabledCount = 0
                if ($editions) {
                    $enabledCount = @($editions | Where-Object {
                        $ed = $_
                        $isEdEnabled = Get-SafeProp -Obj $ed -PropNames "enabled"
                        $isEdEnabled -eq $true -or $isEdEnabled -eq "true"
                    }).Count
                }

                $isOsActive  = ($enabledCount -gt 0)
                $statusText  = if ($isOsActive) { "Active ($enabledCount ed.)" } else { "Disabled" }

                $isCustom    = [bool](Get-SafeProp -Obj $osData -PropNames "isCustomImage", "is_custom_image" -DefaultValue $false)
                $customText  = if ($isCustom) { "Custom WIM" } else { "Standard ISO" }

                $impDateVal  = Get-SafeProp -Obj $osData -PropNames "importedDate", "imported_date"
                $impDateStr  = if ($impDateVal) { $impDateVal.ToString() } else { "" }
                $impDate     = if ($impDateStr) { ($impDateStr -split ' ')[0] } else { $file.CreationTime.ToString("yyyy-MM-dd") }

                $modDateVal = ""
                if ($editions) {
                    $firstActiveEd = $editions | Where-Object { $ed = $_; (Get-SafeProp -Obj $ed -PropNames "enabled") -eq $true } | Select-Object -First 1
                    if (-not $firstActiveEd) { $firstActiveEd = $editions | Select-Object -First 1 }
                    if ($firstActiveEd) { $modDateVal = Get-SafeProp -Obj $firstActiveEd -PropNames "modifiedTime", "modified_time", "ModifiedTime" }
                }
                if (-not $modDateVal) { $modDateVal = Get-SafeProp -Obj $osData -PropNames "updatedDate", "modifiedDate" }
                $modDateStr = if ($modDateVal) { $modDateVal.ToString() } else { "" }
                $modDate    = if ($modDateStr) { ($modDateStr -split ' ')[0] } else { $file.LastWriteTime.ToString("yyyy-MM-dd") }

                $osId        = Get-SafeProp -Obj $osData -PropNames "osId", "os_id" -DefaultValue ""
                $fullName    = Get-SafeProp -Obj $osData -PropNames "fullName", "full_name" -DefaultValue ""
                $version     = Get-SafeProp -Obj $osData -PropNames "version" -DefaultValue ""
                $buildVer    = Get-SafeProp -Obj $osData -PropNames "buildVersion", "build_version" -DefaultValue ""
                $arch        = Get-SafeProp -Obj $osData -PropNames "arch", "architecture" -DefaultValue "x64"
                $defLang     = Get-SafeProp -Obj $osData -PropNames "defaultLanguage", "default_language" -DefaultValue "en-US"
                $mediaRoot   = Get-SafeProp -Obj $osData -PropNames "mediaRoot", "media_root" -DefaultValue ""

                $gridItems.Add([PSCustomObject]@{
                    OSId            = $osId
                    FullName        = $fullName
                    Version         = $version
                    BuildVersion    = $buildVer
                    Arch            = $arch
                    DefaultLanguage = $defLang
                    IsEnabled       = $isOsActive
                    EnabledText     = $statusText
                    IsCustom        = $isCustom
                    IsCustomText    = $customText
                    ImportedDate    = $impDate
                    ModifiedDate    = $modDate
                    MediaRoot       = $mediaRoot
                    OsJsonPath      = $file.FullName
                    FolderDir       = $file.DirectoryName
                })
            } catch {
                Write-UiLog "DEBUG WARNING: Failed to parse catalog file '$($file.FullName)': $_"
            }
        }
    }

    $dgOsCatalog.ItemsSource = [object[]]$gridItems
    $activeCount = @($gridItems | Where-Object { $_.IsEnabled -eq $true }).Count
    $txtCatalogSummary.Text = "Total Payloads: $($gridItems.Count)  |  Active: $activeCount"
}

function Show-EditionManagerDialog {
    param([string]$JsonPath, [string]$FullName)

    $osData = [System.IO.File]::ReadAllText($JsonPath) | ConvertFrom-Json
    if (-not $osData.editions) { Show-Msg "No edition information found in os.json." "No Editions"; return $false }

    $editionList = [System.Collections.Generic.List[object]]::new()
    foreach ($ed in $osData.editions) {
        $cTime    = Get-SafeProp -Obj $ed -PropNames "createdTime", "creationTime"
        $mTime    = Get-SafeProp -Obj $ed -PropNames "modifiedTime", "lastWriteTime"
        $defLang  = Get-SafeProp -Obj $ed -PropNames "defaultLanguage", "default_language" -DefaultValue "en-US"
        $buildVer = Get-SafeProp -Obj $ed -PropNames "buildVersion", "build_version" -DefaultValue (Get-SafeProp -Obj $osData -PropNames "buildVersion", "build_version" -DefaultValue "")
        $archVal  = Get-SafeProp -Obj $ed -PropNames "arch", "architecture" -DefaultValue (Get-SafeProp -Obj $osData -PropNames "arch", "architecture" -DefaultValue "x64")

        $editionList.Add([PSCustomObject]@{
            ImageIndex      = [int]$ed.imageIndex
            EditionName     = [string]$ed.editionName
            BuildVersion    = [string]$buildVer
            Arch            = [string]$archVal
            DefaultLanguage = [string]$defLang
            IsEnabled       = [bool]$ed.enabled
            CreatedTime     = $cTime
            ModifiedTime    = $mTime
        })
    }

    [xml]$dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Manage WIM Editions - $FullName" Height="540" Width="880" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="$bgColor">
    <Window.Resources>
$(Get-SharedXamlResources)
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="55"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="55"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <Border Grid.Row="0" Background="$headerBg" Padding="15,10">
            <TextBlock Text="MANAGE WIM EDITIONS FOR CENTRAL CATALOG" Foreground="White" FontWeight="Bold" FontSize="14" VerticalAlignment="Center"/>
        </Border>

        <!-- DataGrid Content -->
        <Grid Grid.Row="1" Margin="15,10">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Text="Check WIM Editions to Enable in Catalog:" FontWeight="SemiBold" Foreground="$mutedFgColor" FontSize="11" Margin="0,0,0,8"/>
            <DataGrid Name="dgEditions" Grid.Row="1" AutoGenerateColumns="False" CanUserAddRows="False" Background="$surfaceBg" BorderBrush="$borderColor" BorderThickness="1" GridLinesVisibility="None" FontSize="12" RowHeight="28" ColumnHeaderStyle="{StaticResource DataGridHeaderStyle}" RowStyle="{StaticResource DataGridRowStyle}" CellStyle="{StaticResource DataGridCellStyle}" HeadersVisibility="Column" RowHeaderWidth="0">
                <DataGrid.Columns>
                    <DataGridCheckBoxColumn Header="ENABLED" Binding="{Binding IsEnabled, UpdateSourceTrigger=PropertyChanged}" Width="70"/>
                    <DataGridTextColumn Header="INDEX" Binding="{Binding ImageIndex}" IsReadOnly="True" Width="55"/>
                    <DataGridTextColumn Header="EDITION NAME" Binding="{Binding EditionName}" IsReadOnly="True" Width="*"/>
                    <DataGridTextColumn Header="BUILD" Binding="{Binding BuildVersion}" IsReadOnly="True" Width="125"/>
                    <DataGridTextColumn Header="ARCH" Binding="{Binding Arch}" IsReadOnly="True" Width="55"/>
                    <DataGridTextColumn Header="LANG" Binding="{Binding DefaultLanguage}" IsReadOnly="True" Width="60"/>
                    <DataGridTextColumn Header="MODIFIED TIME" Binding="{Binding ModifiedTime}" IsReadOnly="True" Width="185"/>
                </DataGrid.Columns>
            </DataGrid>
        </Grid>

        <!-- Footer -->
        <Border Grid.Row="2" Background="$footerBg" Padding="15,10" BorderBrush="$borderColor" BorderThickness="0,1,0,0">
            <Grid>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Left">
                    <Button Name="btnSelectAll" Content="Select All" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,8,0"/>
                    <Button Name="btnDeselectAll" Content="Deselect All" Style="{StaticResource SecondaryButtonStyle}"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                    <Button Name="btnDlgCancel" Content="Cancel" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,8,0"/>
                    <Button Name="btnDlgSave" Content="Save &amp; Rebuild Catalog" Style="{StaticResource PrimaryButtonStyle}"/>
                </StackPanel>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

    $dlgReader = New-Object System.Xml.XmlNodeReader $dlgXaml
    $dlgWindow = [System.Windows.Markup.XamlReader]::Load($dlgReader)
    $dlgReader.Dispose()
    $dlgWindow.Owner = $window

    $dgEditions     = $dlgWindow.FindName("dgEditions")
    $btnSelectAll   = $dlgWindow.FindName("btnSelectAll")
    $btnDeselectAll = $dlgWindow.FindName("btnDeselectAll")
    $btnDlgSave     = $dlgWindow.FindName("btnDlgSave")
    $btnDlgCancel   = $dlgWindow.FindName("btnDlgCancel")

    $dgEditions.ItemsSource = $editionList
    $script:dialogSaved = $false

    $btnSelectAll.add_Click({ foreach ($item in $editionList) { $item.IsEnabled = $true }; $dgEditions.Items.Refresh() })
    $btnDeselectAll.add_Click({ foreach ($item in $editionList) { $item.IsEnabled = $false }; $dgEditions.Items.Refresh() })

    $btnDlgSave.add_Click({
        $anyEnabled = $false
        foreach ($item in $editionList) {
            $matchingEd = $osData.editions | Where-Object { [int]$_.imageIndex -eq [int]$item.ImageIndex }
            if ($matchingEd) {
                $matchingEd.enabled = [bool]$item.IsEnabled
                if ($item.IsEnabled) { $anyEnabled = $true }
            }
        }
        $osData.enabled = $anyEnabled
        Format-CleanJson $osData | Set-Content -Path $JsonPath -Encoding UTF8
        $script:dialogSaved = $true
        $dlgWindow.DialogResult = $true; $dlgWindow.Close()
    })

    $btnDlgCancel.add_Click({ $dlgWindow.DialogResult = $false; $dlgWindow.Close() })
    $dlgWindow.Add_KeyDown({ if ($_.Key -eq [System.Windows.Input.Key]::Escape) { $dlgWindow.Close() } })
    $null = $dlgWindow.ShowDialog()
    return $script:dialogSaved
}
# endregion

# Dynamic Real-time Button State Evaluator
function Update-ImportButtonState {
    # 1. Deployment Share Directory
    $share = $txtDeploymentShare.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($share) -or -not (Test-Path $share)) {
        $btnImport.IsEnabled = $false; return
    }

    # 2. Source Media Path & Format Check
    $source = $txtSourcePath.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path $source)) {
        $btnImport.IsEnabled = $false; return
    }
    if (-not (Test-Path $source -PathType Container)) {
        $ext = [System.IO.Path]::GetExtension($source).ToLower()
        if ($ext -notmatch '^\.(iso|wim|esd)$') {
            $btnImport.IsEnabled = $false; return
        }
    }

    # 3. Custom WIM / ESD Payload (when Use Custom WIM is checked)
    if ([bool]$chkUseCustomWim.IsChecked) {
        $wim = $txtCustomWim.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($wim) -or -not (Test-Path $wim -PathType Leaf)) {
            $btnImport.IsEnabled = $false; return
        }
        $wimExt = [System.IO.Path]::GetExtension($wim).ToLower()
        if ($wimExt -notmatch '^\.(wim|esd)$') {
            $btnImport.IsEnabled = $false; return
        }
    }

    # 4. OS Full Name (when 7-Zip auto-extract is unchecked for Native DISM mode)
    if (-not [bool]$chkUse7Zip.IsChecked -and [string]::IsNullOrWhiteSpace($txtOsName.Text)) {
        $btnImport.IsEnabled = $false; return
    }

    # All scenario criteria satisfied!
    $btnImport.IsEnabled = $true
}

# Dynamic UI Element Triggers & Text Change Listeners
$txtDeploymentShare.add_TextChanged({ Update-ImportButtonState })
$txtSourcePath.add_TextChanged({ Update-ImportButtonState })
$txtCustomWim.add_TextChanged({ Update-ImportButtonState })
$txtOsName.add_TextChanged({ Update-ImportButtonState })

$chkUseCustomWim.add_Checked({ $txtCustomWim.IsEnabled = $false; $btnBrowseWim.IsEnabled = $true; Update-ImportButtonState })
$chkUseCustomWim.add_Unchecked({ $txtCustomWim.IsEnabled = $false; $btnBrowseWim.IsEnabled = $false; $txtCustomWim.Text = ""; Update-ImportButtonState })

$chkUse7Zip.add_Checked({ $txtOsName.IsEnabled = $false; $lblOsName.Text = "OS Full Name (Auto-Extracted via 7-Zip Registry Extractor):"; Update-ImportButtonState })
$chkUse7Zip.add_Unchecked({ $txtOsName.IsEnabled = $true; $lblOsName.Text = "OS Full Name (REQUIRED for Native DISM Mode, e.g. 'Windows 11 25H2'):"; $txtOsName.Focus(); Update-ImportButtonState })

# Drag-and-Drop Event Handlers
$fileDropHandler = {
    param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $files = $e.Data.GetData([System.Windows.DataFormats]::FileDrop)
        if ($files -and $files.Count -gt 0) { $sender.Text = $files[0]; Update-ImportButtonState }
    }
}
$dragOverHandler = { param($sender, $e); $e.Effects = [System.Windows.DragDropEffects]::Copy; $e.Handled = $true }

$txtSourcePath.add_PreviewDragOver($dragOverHandler)
$txtSourcePath.add_Drop($fileDropHandler)
$txtCustomWim.add_PreviewDragOver($dragOverHandler)
$txtCustomWim.add_Drop($fileDropHandler)

# Double-click DataGrid Row Handler
$dgOsCatalog.add_MouseDoubleClick({
    param($sender, $e)
    if ($dgOsCatalog.SelectedItem) {
        $btnManageEditions.RaiseEvent((New-Object System.Windows.RoutedEventArgs -ArgumentList ([System.Windows.Controls.Button]::ClickEvent)))
    }
})

# Initial Share Path Resolution
if (Test-Path $DefaultDeploymentShare) { $txtDeploymentShare.Text = (Resolve-Path $DefaultDeploymentShare).Path }
else {
    $parentShare = Split-Path -Parent $PSScriptRoot
    if (Test-Path (Join-Path $parentShare "Content")) { $txtDeploymentShare.Text = (Resolve-Path $parentShare).Path }
    else { $txtDeploymentShare.Text = (Resolve-Path $PSScriptRoot).Path }
}

Update-ImportButtonState
Write-UiLog "LiteDeploy Importer Ready. Configure inputs and click 'Import OS Media'."

# Tab Selection & Action Button Listeners
$mainTabControl.add_SelectionChanged({
    param($sender, $e)
    if ($e.Source -eq $mainTabControl -and $mainTabControl.SelectedItem -eq $tabManage) { Load-CatalogDataGrid }
})

$btnBrowseShare.add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog -Property @{ Description = "Select LiteDeploy Deployment Share Root Directory" }
    if (Test-Path $txtDeploymentShare.Text) { $dlg.SelectedPath = $txtDeploymentShare.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtDeploymentShare.Text = $dlg.SelectedPath; Load-CatalogDataGrid; Update-ImportButtonState }
})

$btnBrowseIso.add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog -Property @{ Filter = "Windows ISO Files (*.iso)|*.iso|All Files (*.*)|*.*"; Title = "Select Source Windows ISO" }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtSourcePath.Text = $dlg.FileName; Update-ImportButtonState }
})

$btnBrowseFolder.add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog -Property @{ Description = "Select Source Media Directory or Drive Letter" }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtSourcePath.Text = $dlg.SelectedPath; Update-ImportButtonState }
})

$btnBrowseWim.add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog -Property @{ Filter = "Windows Image Files (*.wim;*.esd)|*.wim;*.esd|All Files (*.*)|*.*"; Title = "Select Custom WIM/ESD File" }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtCustomWim.Text = $dlg.FileName; Update-ImportButtonState }
})

$btnRefreshCatalog.add_Click({ Load-CatalogDataGrid })

$btnManageEditions.add_Click({
    $selectedOS = $dgOsCatalog.SelectedItem
    if (-not $selectedOS) { Show-Msg "Please select an OS entry from the grid to manage its editions." "Selection Required" "Warning"; return }
    try {
        if (Show-EditionManagerDialog -JsonPath $selectedOS.OsJsonPath -FullName $selectedOS.FullName) {
            & (Get-ImportScriptPath) -DeploymentShare $txtDeploymentShare.Text -RebuildCatalog
            Load-CatalogDataGrid; Write-UiLog "Updated WIM editions for '$($selectedOS.FullName)' & rebuilt catalog.json."
        }
    } catch { Show-Msg "Failed to manage editions: $_" "Error" "Error" }
})

$btnDeleteOs.add_Click({
    $selectedOS = $dgOsCatalog.SelectedItem
    if (-not $selectedOS) { Show-Msg "Please select an OS entry from the grid to delete." "Selection Required" "Warning"; return }
    $confirm = Show-Msg "Are you sure you want to permanently DELETE this OS media entry and its files?`n`nOS Name: $($selectedOS.FullName)`nFolder:  $($selectedOS.FolderDir)`n`nTHIS ACTION CANNOT BE UNDONE." "CONFIRM DELETE" "Stop" "YesNo"

    if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
        try {
            if (Test-Path $selectedOS.FolderDir) { Remove-Item -Path $selectedOS.FolderDir -Recurse -Force; Write-UiLog "Deleted directory: $($selectedOS.FolderDir)" }
            & (Get-ImportScriptPath) -DeploymentShare $txtDeploymentShare.Text -RebuildCatalog
            Load-CatalogDataGrid; Show-Msg "OS media payload successfully deleted." "Deleted" "Information"
        } catch { Show-Msg "Failed to delete OS media folder: $_" "Delete Error" "Error" }
    }
})

$btnImport.add_Click({
    # 1. Deployment Share Path Validation
    $sharePath = $txtDeploymentShare.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($sharePath) -or -not (Test-Path $sharePath)) {
        Show-Msg "Please specify a valid LiteDeploy Deployment Share directory." "Invalid Share Directory" "Warning"
        $txtDeploymentShare.Focus(); return
    }

    # 2. Source Media Path Validation & File Format Check
    $sourcePath = $txtSourcePath.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($sourcePath) -or -not (Test-Path $sourcePath)) {
        Show-Msg "Please select a valid Source Windows ISO file, Drive Letter, or Media Folder." "Invalid Source Path" "Warning"
        return
    }
    if (-not (Test-Path $sourcePath -PathType Container)) {
        $sourceExt = [System.IO.Path]::GetExtension($sourcePath).ToLower()
        if ($sourceExt -notmatch '^\.(iso|wim|esd)$') {
            Show-Msg "Invalid media file format '$sourceExt'.`n`nSupported media formats are ISO files (*.iso) or Windows Image files (*.wim; *.esd)." "Invalid File Format" "Warning"
            return
        }
    }

    # 3. Custom WIM / ESD File Validation
    if ([bool]$chkUseCustomWim.IsChecked) {
        $customWim = $txtCustomWim.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($customWim) -or -not (Test-Path $customWim -PathType Leaf)) {
            Show-Msg "Custom WIM mode is enabled.`nPlease click 'Select Image...' to select a valid Custom WIM or ESD payload file." "Custom WIM File Required" "Warning"
            return
        }
        $wimExt = [System.IO.Path]::GetExtension($customWim).ToLower()
        if ($wimExt -notmatch '^\.(wim|esd)$') {
            Show-Msg "Invalid Custom WIM format '$wimExt'.`n`nCustom payload must be a .wim or .esd file." "Invalid Custom Payload" "Warning"
            return
        }
    }

    # 4. Native DISM Mode OS Name Validation
    if (-not [bool]$chkUse7Zip.IsChecked -and [string]::IsNullOrWhiteSpace($txtOsName.Text)) {
        Show-Msg "Native DISM Mode requires an OS Full Name (e.g. 'Windows 11 25H2').`nPlease enter the OS Name in the 'OS Full Name' text box." "OS Name Required" "Warning"
        $txtOsName.Focus(); return
    }

    $scriptPath = Get-ImportScriptPath
    Write-UiLog "Starting OS Media Import pipeline..."
    Write-UiLog "Deployment Share: $($txtDeploymentShare.Text)"
    Write-UiLog "Source Path:      $($txtSourcePath.Text)"
    if ([bool]$chkUseCustomWim.IsChecked -and $txtCustomWim.Text) { Write-UiLog "Custom WIM:       $($txtCustomWim.Text)" }

    $btnImport.IsEnabled = $false; $btnRebuildOnly.IsEnabled = $false
    $pbImport.Visibility = "Visible"; $pbImport.IsIndeterminate = $true

    try {
        $splat = @{
            DeploymentShare   = $txtDeploymentShare.Text
            SourcePath        = $txtSourcePath.Text
            Use7Zip           = [bool]$chkUse7Zip.IsChecked
            SelectAllEditions = $true
            PassThru          = $true
        }
        if ([bool]$chkUseCustomWim.IsChecked -and -not [string]::IsNullOrWhiteSpace($txtCustomWim.Text)) { $splat['CustomWimPath'] = $txtCustomWim.Text }
        if (-not [bool]$chkUse7Zip.IsChecked -and -not [string]::IsNullOrWhiteSpace($txtOsName.Text)) { $splat['OSName'] = $txtOsName.Text }

        $rawResults  = & $scriptPath @splat
        $importedObj = @($rawResults) | Where-Object { $_ -and $_.PSObject.Properties['setupPath'] } | Select-Object -Last 1

        if (-not $importedObj) {
            throw "Import completed but output OS payload object could not be resolved from script output."
        }

        Write-UiLog "SUCCESS: Media imported successfully!"

        $setupPathVal     = $importedObj.setupPath
        $targetFolderName = Split-Path -Leaf (Split-Path -Parent $setupPathVal)
        $newJsonPath      = Join-Path $txtDeploymentShare.Text "Content\OperatingSystems\$targetFolderName\os.json"

        if (Test-Path $newJsonPath) {
            Write-UiLog "Opening WIM Edition Selection dialog..."
            if (Show-EditionManagerDialog -JsonPath $newJsonPath -FullName $importedObj.fullName) {
                & $scriptPath -DeploymentShare $txtDeploymentShare.Text -RebuildCatalog
                Write-UiLog "WIM edition selection saved & central catalog.json updated!"
            }
        }

        Load-CatalogDataGrid
        $mainTabControl.SelectedItem = $tabManage

        Show-Msg "OS Media import & edition selection completed successfully!" "Import Complete" "Information"
    }
    catch {
        Write-UiLog "ERROR: $_"
        Show-Msg "Import operation failed:`n`n$_" "Import Error" "Error"
    }
    finally {
        $btnImport.IsEnabled = $true; $btnRebuildOnly.IsEnabled = $true
        $pbImport.Visibility = "Collapsed"; $pbImport.IsIndeterminate = $false
    }
})

$btnRebuildOnly.add_Click({
    if (-not (Test-Path $txtDeploymentShare.Text)) { Show-Msg "Please specify a valid Deployment Share directory." "Invalid Path" "Warning"; return }
    Write-UiLog "Rebuilding central catalog.json from local os.json files..."
    try {
        & (Get-ImportScriptPath) -DeploymentShare $txtDeploymentShare.Text -RebuildCatalog
        Write-UiLog "SUCCESS: Central catalog.json rebuilt!"; Load-CatalogDataGrid
    } catch { Write-UiLog "ERROR: $_" }
})

$btnClearForm.add_Click({ Clear-ImportForm -ClearLog })
$window.Add_KeyDown({ if ($_.Key -eq [System.Windows.Input.Key]::Escape) { $window.Close() } })

Load-CatalogDataGrid
$null = $window.ShowDialog()
# endregion
