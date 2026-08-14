<#
.SYNOPSIS
    Pure WPF Native System Pre-Check for LiteDeploy in WinPE.
.DESCRIPTION
    Validates configuration, networking, deployment-source reachability, storage,
    memory, firmware, and Secure Boot readiness before deployment using a native WPF host.
#>
[CmdletBinding()]
param(
    [string]$DeploymentShare = "",
    [int]$MaxNetworkWaitSeconds = 30,
    [int]$NetworkPollMilliseconds = 500,
    [int]$SmbConnectTimeoutMilliseconds = 2000,
    [int]$MinDiskSizeGB = 32,
    [int]$MinMemoryGB = 4,
    [bool]$HaltOnFailure = $true,
    [ValidateSet("Light", "Dark")][string]$Theme = "Light",
    [ValidateSet("On", "Off")][string]$TopMost = "On",
    [switch]$ShowBackdrop,
    [ValidateRange(0, 60)][int]$SuccessCloseSeconds = 3,
    [psobject]$BootObject = $null
)

# ------------------------------------------------------------------------------
# 1. STA MODE & WPF ASSEMBLY LOAD
# ------------------------------------------------------------------------------
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    if ($BootObject) {
        throw "LiteDeploy.PreCheck.ps1 must be invoked from the BootInitializer STA process when BootObject is supplied. Relaunching would discard the in-memory credential."
    }
    $powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path $powershellExe)) { $powershellExe = "powershell.exe" }
    & $powershellExe -STA -ExecutionPolicy Bypass -File "$PSCommandPath" @args
    return
}

try { [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly } catch {}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if ($BootObject) {
    $global:LiteDeployBootObject = $BootObject
}
elseif (Test-Path Variable:global:LiteDeployBootObject) {
    $BootObject = $global:LiteDeployBootObject
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
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LiteDeploy System Pre-Check" WindowState="Normal" WindowStyle="SingleBorderWindow"
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
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="$buttonHoverBg"/></Trigger>
                <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="$buttonPressedBg"/><Setter Property="Foreground" Value="$fgColor"/></Trigger>
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
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <Border Grid.Column="0" Background="#28FFFFFF" CornerRadius="4" Width="40" Height="40">
                            <TextBlock Text="LD" Foreground="White" FontWeight="Bold" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="12,0,0,0">
                            <TextBlock Name="TxtBrand" Text="LiteDeploy" Foreground="White" FontSize="18" FontWeight="Bold"/>
                            <TextBlock Name="TxtSubtitle" Text="System Readiness Assessment" Foreground="#D9EFFF" FontSize="11"/>
                        </StackPanel>
                        <Border Grid.Column="2" Background="#23FFFFFF" CornerRadius="4" Padding="10,5" VerticalAlignment="Center">
                            <TextBlock Text="WINPE PRE-CHECK" Foreground="White" FontSize="10" FontWeight="Bold"/>
                        </Border>
                    </Grid>
                </Border>

                <Grid Grid.Row="1" Margin="30,8,30,6">
                    <Grid Name="Page1" Visibility="Visible">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Text="Preparing this device for deployment" FontSize="16" FontWeight="Bold" Foreground="$fgColor" HorizontalAlignment="Center" Margin="0,0,0,2"/>
                        <TextBlock Grid.Row="1" Name="TxtMessage" Text="Initializing environment and discovering configuration..." FontSize="11.5" Foreground="$secFgColor" HorizontalAlignment="Center" Margin="0,0,0,6"/>
                        <ProgressBar Grid.Row="2" Name="ProgressBarPreCheck" Style="{StaticResource ModernProgressBarStyle}" Minimum="0" Maximum="100" Value="5" Margin="20,0,20,4"/>
                        <TextBlock Grid.Row="3" Name="TxtPercent" Text="0% Complete" FontSize="13" FontWeight="Bold" Foreground="$fgColor" HorizontalAlignment="Center" Margin="0,0,0,6"/>
                        <TextBlock Grid.Row="4" Text="ASSESSMENT RESULTS" FontSize="10.5" FontWeight="Bold" Foreground="$mutedFgColor" Margin="0,0,0,4"/>
                        <DataGrid Grid.Row="5" Name="GridPreCheckResults" AutoGenerateColumns="False" HeadersVisibility="Column" GridLinesVisibility="None" Background="$surfaceBg" BorderBrush="$borderColor" BorderThickness="1" RowHeight="25" SelectionMode="Single" IsReadOnly="True" CanUserResizeColumns="False" Margin="0,0,0,8" ColumnHeaderStyle="{StaticResource DataGridHeaderStyle}" RowStyle="{StaticResource DataGridRowStyle}">
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
                            <TextBlock Name="TxtStatusBanner" Text="Assessment is running..." FontSize="12" FontWeight="Bold" Foreground="#0078D4" HorizontalAlignment="Center"/>
                        </Border>
                    </Grid>
                </Grid>

                <Border Grid.Row="2" Background="$footerBg" Padding="20,12" BorderBrush="$borderColor" BorderThickness="0,1,0,0">
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Name="TxtConfigSource" Text="Configuration: Discovering..." FontSize="11" Foreground="$mutedFgColor" VerticalAlignment="Center"/>
                        <StackPanel Grid.Column="1" Orientation="Horizontal">
                            <Button Name="BtnDiagnostics" Content="Run CMD" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,10,0"/>
                            <Button Name="BtnRunAgain" Content="Run Again" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,10,0"/>
                            <Button Name="BtnContinue" Content="Continue" Style="{StaticResource PrimaryButtonStyle}"/>
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

$backdropWindow = $null
if ($ShowBackdrop) {
    $backdropWindow = New-Object System.Windows.Window
    $backdropWindow.WindowStyle = "None"; $backdropWindow.WindowState = "Maximized"
    $backdropWindow.Background = [System.Windows.Media.Brushes]::Black
    $backdropWindow.ShowInTaskbar = $false; $backdropWindow.Show()
}

$txtBrand = $window.FindName("TxtBrand")
$txtSubtitle = $window.FindName("TxtSubtitle")
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
$global:PreCheckPassed = $true

# ------------------------------------------------------------------------------
# 5. ASSESSMENT FUNCTIONS & CLEAN CONFIGURATION FINDER
# ------------------------------------------------------------------------------
function Do-Events {
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Render)
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
    Do-Events
}

function Set-PreCheckProgress([int]$Percent, [string]$Message) {
    $progressBarPreCheck.Value = [math]::Min(100, [math]::Max(0, $Percent))
    $txtPercent.Text = "$Percent% Complete"
    $txtMessage.Text = $Message
    Do-Events
}

function Find-Configuration {
    $paths = @(
        (Join-Path $PSScriptRoot "..\01-Config\BootConfig.json"),
        (Join-Path $PSScriptRoot "Config\BootConfig.json"),
        (Join-Path $PSScriptRoot "BootConfig.json")
    )
    foreach ($path in $paths) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return (Resolve-Path -LiteralPath $path).Path }
    }
    return $null
}

function Test-NetworkHardware([string]$Mode) {
    try {
        $name = ""
        if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
            $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne "Disabled" } | Select-Object -First 1
            if ($adapter) { $name = if ($adapter.InterfaceDescription) { $adapter.InterfaceDescription.Trim() } else { $adapter.Name } }
        }
        if ([string]::IsNullOrWhiteSpace($name)) {
            $adapter = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object { $_.NetworkInterfaceType -ne "Loopback" -and $_.OperationalStatus -eq "Up" } | Select-Object -First 1
            if ($adapter) { $name = $adapter.Description.Trim() }
        }
        if ($name) { Add-Result "Network Adapter: Connected ($name)" "OK"; return $true }
        $status = if ($Mode -eq "Media") { "WARN" } else { "FAIL" }
        Add-Result "Network Adapter: Not Detected" $status
        return ($Mode -eq "Media")
    }
    catch {
        $status = if ($Mode -eq "Media") { "WARN" } else { "FAIL" }
        Add-Result "Network Adapter: Not Detected" $status
        return ($Mode -eq "Media")
    }
}

function Test-NetworkIPAddress([int]$TimeoutSeconds, [int]$PollIntervalMs, [string]$Mode) {
    try {
        $ipv4 = ""; $ipv6 = ""
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds -and -not $ipv4) {
            $adapters = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object { $_.NetworkInterfaceType -ne "Loopback" -and $_.OperationalStatus -eq "Up" }
            foreach ($adapter in $adapters) {
                foreach ($address in $adapter.GetIPProperties().UnicastAddresses) {
                    $candidate = $address.Address.IPAddressToString
                    if ($address.Address.AddressFamily -eq "InterNetwork" -and $candidate -notlike "169.254.*" -and $candidate -ne "127.0.0.1") { if (-not $ipv4) { $ipv4 = $candidate } }
                    if ($address.Address.AddressFamily -eq "InterNetworkV6" -and $candidate -notlike "fe80:*" -and $candidate -ne "::1") { if (-not $ipv6) { $ipv6 = $candidate } }
                }
                if ($ipv4) { break }
            }
            if (-not $ipv4) { Do-Events; Start-Sleep -Milliseconds $PollIntervalMs }
        }
        if ($ipv4) {
            Add-Result "IPv4 Address: $(if ($ipv6) { "$ipv4 (IPv6: $ipv6)" } else { $ipv4 })" "OK"
            return $true
        }
        $status = if ($Mode -eq "Media") { "WARN" } else { "FAIL" }
        Add-Result "IPv4 Address: Not Detected" $status
        return ($Mode -eq "Media")
    }
    catch {
        $status = if ($Mode -eq "Media") { "WARN" } else { "FAIL" }
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
    if ($connected) { Add-Result "Deployment Server: Reachable ($server)" "OK"; return $true }
    Add-Result "Deployment Server: Unreachable ($server) on SMB port 445" "FAIL"
    $false
}

function Test-InternalStorage([int]$MinimumGB) {
    $items = @()
    try {
        if (Get-Command Get-Disk -ErrorAction SilentlyContinue) {
            Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -ne "USB" -and $_.OperationalStatus -eq "Online" } | Sort-Object Number | ForEach-Object {
                $size = if ($_.Size) { [math]::Round([double]$_.Size / 1GB) } else { 0 }
                $model = if ($_.Model) { $_.Model.Trim() } elseif ($_.FriendlyName) { $_.FriendlyName.Trim() } else { "Internal Drive" }
                $items += [pscustomobject]@{ Number = $_.Number; Model = $model; Size = $size }
            }
        }
        if (-not $items) {
            Get-WmiObject Win32_DiskDrive -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceType -ne "USB" -and $_.MediaType -notlike "*Removable*" } | Sort-Object Index | ForEach-Object {
                $size = if ($_.Size) { [math]::Round([double]$_.Size / 1GB) } else { 0 }
                $items += [pscustomobject]@{ Number = $_.Index; Model = $_.Model.Trim(); Size = $size }
            }
        }
    }
    catch {}
    if (-not $items) { Add-Result "Internal Storage: Not Detected" "FAIL"; return $false }
    $valid = 0
    foreach ($item in $items) {
        $status = if ($item.Size -gt 0 -and $item.Size -lt $MinimumGB) { "FAIL" } else { $valid++; "OK" }
        $sizeText = if ($item.Size -gt 0) { " ($($item.Size) GB)" } else { "" }
        if ($status -eq "FAIL") { $sizeText += " [Below minimum $MinimumGB GB]" }
        Add-Result "Internal Storage: Disk $($item.Number) - $($item.Model)$sizeText" $status
    }
    $valid -gt 0
}

function Test-SystemMemory([int]$MinimumGB) {
    try {
        $bytes = 0
        Get-WmiObject Win32_PhysicalMemory -ErrorAction SilentlyContinue | ForEach-Object { $bytes += [double]$_.Capacity }
        if ($bytes -le 0) {
            $os = Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($os -and $os.TotalVisibleMemorySize) { $bytes = [double]$os.TotalVisibleMemorySize * 1KB }
        }
        if ($bytes -le 0) { return $true }
        $gb = [math]::Round($bytes / 1GB, 1)
        Add-Result "System RAM: $gb GB" $(if ($gb -ge $MinimumGB) { "OK" } else { "WARN" })
        return ($gb -ge $MinimumGB)
    }
    catch { $true }
}

function Get-SecureBootCertDetails {
    try {
        if (-not (Get-Command Get-SecureBootUEFI -ErrorAction SilentlyContinue)) { return "" }
        $dbBytes = (Get-SecureBootUEFI db -ErrorAction SilentlyContinue).Bytes
        if (-not $dbBytes -or $dbBytes.Count -eq 0) { return "" }
        $dbText = [System.Text.Encoding]::ASCII.GetString($dbBytes)

        $has2011 = $dbText -like "*Microsoft Windows Production PCA 2011*"
        $has2023 = $dbText -like "*Windows UEFI CA 2023*"

        if ($has2011 -and $has2023) { return " (2011/2023 CA Ready)" }
        elseif ($has2023) { return " (2023 CA Ready)" }
        elseif ($has2011) { return " (2011 CA Only - BIOS Update Recommended)" }
        return ""
    }
    catch { return "" }
}

function Test-SystemEnvironment {
    try {
        $firmware = if ($env:firmware_type) { $env:firmware_type } else { "Unknown" }
        if ($firmware -eq "UEFI") {
            Add-Result "BIOS Mode: UEFI" "OK"
            $secureBoot = "Unknown"
            if (Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue) {
                try { $secureBoot = if (Confirm-SecureBootUEFI -ErrorAction Stop) { "Enabled" } else { "Disabled" } } catch {}
            }
            if ($secureBoot -eq "Unknown") {
                $state = Get-ItemProperty "HKLM:\System\CurrentControlSet\Control\SecureBoot\State" -ErrorAction SilentlyContinue
                if ($state) { $secureBoot = if ($state.UEFISecureBootEnabled -eq 1) { "Enabled" } else { "Disabled" } }
            }
            if ($secureBoot -eq "Enabled") {
                $certDetails = Get-SecureBootCertDetails
                $status = if ($certDetails -like "*BIOS Update Recommended*") { "WARN" } else { "OK" }
                Add-Result "Secure Boot: Enabled$certDetails" $status
            }
            else {
                Add-Result "Secure Boot: $secureBoot" "WARN"
            }
        }
        else {
            Add-Result "BIOS Mode: $firmware (Legacy BIOS)" "WARN"
        }
        $true
    }
    catch { Add-Result "System Environment: Unable to detect full specifications" "WARN"; $true }
}

function Test-SystemTPM {
    try {
        $firmware = if ($env:firmware_type) { $env:firmware_type } else { "Unknown" }
        if ($firmware -eq "Legacy" -or $firmware -eq "BIOS") {
            return $true
        }

        $tpm = Get-WmiObject -Namespace "root\cimv2\Security\MicrosoftTpm" -Class Win32_Tpm -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($tpm) {
            $spec = if ($tpm.SpecVersion) { $tpm.SpecVersion.Split(',')[0].Trim() } else { "2.0" }
            $version = if ($spec -like "2.0*") { "TPM 2.0" } elseif ($spec -like "1.2*") { "TPM 1.2" } else { "TPM $spec" }
            $enabled = $false
            try { $enabled = [bool]($tpm.IsEnabled().IsEnabled) } catch { try { $enabled = [bool]$tpm.IsEnabled_InitialValue } catch {} }

            $state = if ($enabled) { "Enabled" } else { "Disabled" }

            if ($version -eq "TPM 2.0" -and $enabled) {
                Add-Result "TPM Status: TPM 2.0 (Enabled)" "OK"
            }
            else {
                Add-Result "TPM Status: $version ($state)" "WARN"
            }
            return $true
        }

        # Fallback check: PnP Hardware Device Enumeration
        $tpmPnp = Get-WmiObject Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*Trusted Platform Module*" -or $_.DeviceID -like "*TPM*" } | Select-Object -First 1

        if ($tpmPnp) {
            $name = $tpmPnp.Name.Trim()
            $version = if ($name -like "*2.0*") { "TPM 2.0" } elseif ($name -like "*1.2*") { "TPM 1.2" } else { "TPM Present" }
            $status = if ($version -eq "TPM 2.0") { "OK" } else { "WARN" }
            Add-Result "TPM Status: $version (Enabled)" $status
            return $true
        }

        # No TPM device found
        Add-Result "TPM Status: Not Detected" "WARN"
        return $true
    }
    catch {
        Add-Result "TPM Status: Not Detected" "WARN"
        return $true
    }
}

function Invoke-PreCheck {
    $global:PreCheckPassed = $true
    $script:Summary.Clear()
    $gridPreCheckResults.ItemsSource = $null
    $btnContinue.IsEnabled = $false; $btnContinue.Content = "Checking..."
    $progressBarPreCheck.Foreground = Brush $(if ($isDark) { "#60A5FA" } else { "#0078D4" })
    
    Set-PreCheckProgress 5 "Initializing environment and discovering configuration..."
    
    # PreCheck runs from the connected deployment source. Resolve the full
    # runtime BootConfig relative to this script first, matching the backup
    # implementation. BootObject is only the fallback for standalone/testing
    # layouts where no deployment-source config file is present.
    $configPath = Find-Configuration
    $config = $null; $mode = $null; $share = $DeploymentShare
    $name = "LiteDeploy"; $version = "1.0"; $environment = ""

    if ($configPath) {
        try {
            $config = Get-Content $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

            # Publish the exact configuration consumed by PreCheck back into
            # the shared in-memory object for SelectWorkflow and later stages.
            if ($BootObject) {
                if ($BootObject.PSObject.Properties['Config']) {
                    $BootObject.Config = $config
                }
                else {
                    $BootObject | Add-Member -NotePropertyName Config -NotePropertyValue $config
                }

                if ($BootObject.PSObject.Properties['ConfigPath']) {
                    $BootObject.ConfigPath = $configPath
                }
                else {
                    $BootObject | Add-Member -NotePropertyName ConfigPath -NotePropertyValue $configPath
                }
            }
        }
        catch { Add-Result "Configuration: Invalid JSON - $($_.Exception.Message)" "FAIL"; $global:PreCheckPassed = $false }
    }
    elseif ($BootObject -and (Property $BootObject "Config")) {
        $config = Property $BootObject "Config"
        $configPath = Property $BootObject "ConfigPath"
    }

    if ($config) {
        $metadata = Property $config "Metadata"; $deployment = Property $config "Deployment"
        if (Property $metadata "Name") { $name = Property $metadata "Name" }
        if (Property $metadata "Version") { $version = Property $metadata "Version" }
        if (Property $metadata "Environment") { $environment = Property $metadata "Environment" }
        $mode = Property $deployment "Type"
        if (-not $script:ShareWasSpecified -and (Property $deployment "NetworkPath")) { $share = Property $deployment "NetworkPath" }
    }
    $txtBrand.Text = $name
    $txtSubtitle.Text = if ($environment) { "$environment Environment | v$version" } else { "System Readiness Assessment | v$version" }
    $txtConfigSource.Text = if ($configPath) { "Configuration: $configPath" } else { "Configuration: Not found" }

    $computerSetup = Property $config "ComputerSetup"
    $requireTPM = if ($computerSetup -and (Property $computerSetup "RequireTPM") -eq $true) { $true } else { $false }

    if (-not $config) {
        Add-Result "Deployment Mode: Configuration File Not Found" "FAIL"; $global:PreCheckPassed = $false
    }
    elseif ($mode -eq "Media") {
        Add-Result "Deployment Mode: Local (Media)" "OK"
    }
    elseif ($mode -eq "Network" -and $share) {
        Add-Result "Deployment Mode: Network ($share)" "OK"
    }
    elseif ($mode -eq "Network") {
        Add-Result "Deployment Mode: Network (Missing NetworkPath)" "FAIL"; $global:PreCheckPassed = $false
    }
    else {
        Add-Result "Deployment Mode: $mode" "WARN"
    }

    Set-PreCheckProgress 15 "Testing deployment source connectivity..."
    if (-not (Test-DeploymentShare $share $SmbConnectTimeoutMilliseconds $mode)) { $global:PreCheckPassed = $false }

    $startup = Property $config "Startup"
    if ((Property $startup "SkipHardwarePreCheck") -eq $true -or (Property $startup "SkipPreCheck") -eq $true) {
        Add-Result "Pre-Check: Bypassed via configuration" "INFO"
        Set-PreCheckProgress 100 "System pre-check bypassed by deployment policy."
        $txtStatusBanner.Text = "SYSTEM PRE-CHECK BYPASSED BY POLICY"
        $bannerStatus.Background = Brush $(if ($isDark) { "#2D2410" } else { "#FFF7E0" })
        $txtStatusBanner.Foreground = Brush "#D97706"
        $btnContinue.IsEnabled = $true; $btnContinue.Content = "Continue"
        return "Skipped"
    }

    Set-PreCheckProgress 35 "Scanning for active network hardware..."
    if (-not (Test-NetworkHardware $mode)) { $global:PreCheckPassed = $false }
    Set-PreCheckProgress 55 "Awaiting IPv4 address assignment..."
    if (-not (Test-NetworkIPAddress $MaxNetworkWaitSeconds $NetworkPollMilliseconds $mode)) { $global:PreCheckPassed = $false }
    Set-PreCheckProgress 75 "Validating internal storage and system memory..."
    if (-not (Test-InternalStorage $MinDiskSizeGB)) { $global:PreCheckPassed = $false }
    Test-SystemMemory $MinMemoryGB | Out-Null
    Set-PreCheckProgress 90 "Analyzing firmware and Secure Boot..."
    Test-SystemEnvironment | Out-Null
    Set-PreCheckProgress 95 "Evaluating TPM security status..."
    Test-SystemTPM | Out-Null
    Set-PreCheckProgress 100 "System pre-check complete."

    if ($global:PreCheckPassed) {
        $progressBarPreCheck.Foreground = Brush $(if ($isDark) { "#4ADE80" } else { "#107C10" })
        $txtStatusBanner.Text = "SYSTEM READY FOR IMAGE DEPLOYMENT"
        $bannerStatus.Background = Brush $(if ($isDark) { "#163820" } else { "#EAF6EA" })
        $bannerStatus.BorderBrush = Brush $(if ($isDark) { "#225431" } else { "#C6E7C6" })
        $txtStatusBanner.Foreground = Brush $(if ($isDark) { "#4ADE80" } else { "#107C10" })
        $btnContinue.IsEnabled = $true; $btnContinue.Content = "Continue"
        return "Passed"
    }
    else {
        $progressBarPreCheck.Foreground = Brush $(if ($isDark) { "#F87171" } else { "#D13438" })
        $txtStatusBanner.Text = "CRITICAL PRE-CHECK ISSUES DETECTED"
        $bannerStatus.Background = Brush $(if ($isDark) { "#3E1719" } else { "#FDECEC" })
        $bannerStatus.BorderBrush = Brush $(if ($isDark) { "#642225" } else { "#FACDCD" })
        $txtStatusBanner.Foreground = Brush $(if ($isDark) { "#F87171" } else { "#D13438" })
        $btnContinue.Content = "Continue"
        if ($HaltOnFailure) {
            $btnContinue.IsEnabled = $false
        }
        else {
            $btnContinue.IsEnabled = $true
        }
        return "Failed"
    }
}

# ------------------------------------------------------------------------------
# 6. EVENT BINDING & EXECUTION
# ------------------------------------------------------------------------------
# PreCheck returns a structured result to LiteDeploy.DeploymentEngine (or a
# standalone caller). It does not launch SelectWorkflow — the engine owns sequencing.
$script:AllowClose = $false
$script:ContinueRequested = $false

if ($null -ne $btnContinue) {
    $btnContinue.Add_Click({
            $script:ContinueRequested = $true
            $script:AllowClose = $true
            $window.Close()
        })
}
if ($null -ne $btnRunAgain) { $btnRunAgain.Add_Click({ Invoke-PreCheck }) }
if ($null -ne $btnDiagnostics) {
    $btnDiagnostics.Add_Click({
            $window.Topmost = $false
            Start-Process "$env:SystemRoot\System32\cmd.exe"
        })
}

$window.Add_Closing({
        param($sender, $e)
        if (-not $script:AllowClose) {
            $msg = "Are you sure you want to cancel? If you close this window, the deployment will be cancelled."
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
                $global:PreCheckPassed = $false
            }
        }
    })

$window.Add_KeyDown({ if ($_.Key -eq [System.Windows.Input.Key]::Escape) { $window.Close() } })
$window.Add_ContentRendered({ Invoke-PreCheck })

$null = $window.ShowDialog()
if ($backdropWindow) { $backdropWindow.Close() }

$preCheckPassed = $false
if (Test-Path Variable:global:PreCheckPassed) {
    $preCheckPassed = [bool]$global:PreCheckPassed
}

$status = if ($script:ContinueRequested -and $preCheckPassed) {
    "Continue"
}
elseif ($script:ContinueRequested -and -not $preCheckPassed) {
    "Failed"
}
elseif (-not $script:ContinueRequested) {
    "Cancelled"
}
else {
    "Unknown"
}

return [PSCustomObject]@{
    ContinueRequested = [bool]$script:ContinueRequested
    PreCheckPassed    = [bool]$preCheckPassed
    Status            = $status
}
