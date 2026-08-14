# Ensured Single-Threaded Apartment (STA) mode for WPF
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    powershell.exe -STA -ExecutionPolicy Bypass -File "$PSCommandPath"
    exit
}

# --------------------------------------------------
# CONFIGURATION: Set to $false to disable the dark backdrop
# --------------------------------------------------
$EnableBackdrop = $true
# --------------------------------------------------

# Force Software Rendering for WinPE Driver Compatibility
[System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Load the WPF-only folder picker. Windows Forms dialogs are not guaranteed in WinPE.
$driverPathPickerScript = Join-Path $PSScriptRoot "SelectDrivePath.ps1"
if (Test-Path -LiteralPath $driverPathPickerScript) {
    . $driverPathPickerScript
}

# Load Configuration from BootConfig.json
$configPath = Join-Path $PSScriptRoot "Config\BootConfig.json"
if (-not (Test-Path $configPath)) {
    $configPath = ".\Config\BootConfig.json"
}

$bootConfig = $null
if (Test-Path $configPath) {
    try {
        $bootConfig = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "Could not parse BootConfig.json: $_"
    }
}

# Window configuration based on backdrop setting
if ($EnableBackdrop) {
    $windowStyle = "None"
    $windowState = "Maximized"
    $resizeMode  = "NoResize"
    $bgStyle     = "Background=`"#002040`""
} else {
    $windowStyle = "SingleBorderWindow"
    $windowState = "Normal"
    $resizeMode  = "CanResize"
    $bgStyle     = "Background=`"#F3F3F3`""
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows Setup" 
        WindowState="$windowState" 
        WindowStyle="$windowStyle" 
        ResizeMode="$resizeMode"
        Width="960" Height="720"
        WindowStartupLocation="CenterScreen"
        $bgStyle>
    
    <Window.Resources>
        <Style x:Key="ActionLinkStyle" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Foreground" Value="#005A9E"/>
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
            <Setter Property="Background" Value="#005A9E"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#005A9E"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="24,7"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="border" Property="Background" Value="#0078D4"/><Setter TargetName="border" Property="BorderBrush" Value="#0078D4"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="border" Property="Background" Value="#004E8C"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="border" Property="Background" Value="#F3F4F6"/><Setter TargetName="border" Property="BorderBrush" Value="#E5E7EB"/><Setter Property="Foreground" Value="#9CA3AF"/><Setter Property="Cursor" Value="No"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SecondaryButtonStyle" TargetType="Button">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#1F2937"/>
            <Setter Property="BorderBrush" Value="#D9E0E7"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="16,6"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="border" Property="Background" Value="#F3F4F6"/><Setter TargetName="border" Property="BorderBrush" Value="#005A9E"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="border" Property="Background" Value="#E5E7EB"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Modern Clean Styled TextBox -->
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#1A1A1A"/>
            <Setter Property="BorderBrush" Value="#D9E0E7"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Padding" Value="8,4"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>

        <!-- Workflow / Parent Header Template -->
        <DataTemplate x:Key="WorkflowHeaderTemplate">
            <StackPanel Orientation="Horizontal" Margin="0,2">
                <Path Width="18" Height="18" Stretch="Uniform" Fill="#005A9E" Margin="0,0,8,0"
                      Data="M19,13H13V19H19V13M11,13H5V19H11V13M19,5H13V11H19V5M11,5H5V11H11V5M3,3H21V21H3V3Z"/>
                <TextBlock Text="{Binding HeaderText}" FontWeight="Bold" FontSize="13" Foreground="#005A9E" VerticalAlignment="Center"/>
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

                <Path x:Name="ItemIcon" Grid.Column="0" Width="16" Height="16" Stretch="Uniform" Fill="#005A9E" Margin="0,0,10,0" VerticalAlignment="Center"
                      Data="M6,2H18A2,2 0 0,1 20,4V20A2,2 0 0,1 18,22H6A2,2 0 0,1 4,20V4A2,2 0 0,1 6,2M6,4V8H18V4H6M6,20H18V10H6V20M16,15A1,1 0 0,0 15,14A1,1 0 0,0 14,15A1,1 0 0,0 16,15Z"/>

                <TextBlock x:Name="ItemName" Grid.Column="1" Text="{Binding Name}" FontSize="13" Foreground="#1F2937" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,30,0"/>

                <TextBlock x:Name="ItemDate" Grid.Column="3" Text="{Binding DateText}" FontSize="12" Foreground="#6B7280" VerticalAlignment="Center" Margin="0,0,16,0"/>
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
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Style.Resources>
                <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#0078D4" />
                <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#FFFFFF" />
                <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightBrushKey}" Color="#0078D4" />
                <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightTextBrushKey}" Color="#FFFFFF" />
            </Style.Resources>
        </Style>

        <Style x:Key="HeaderNodeStyle" TargetType="TreeViewItem" BasedOn="{StaticResource {x:Type TreeViewItem}}">
            <Setter Property="IsExpanded" Value="True"/>
            <Setter Property="HeaderTemplate" Value="{StaticResource WorkflowHeaderTemplate}"/>
        </Style>

        <Style x:Key="ChildNodeStyle" TargetType="TreeViewItem" BasedOn="{StaticResource {x:Type TreeViewItem}}">
            <Setter Property="HeaderTemplate" Value="{StaticResource OSItemTemplate}"/>
        </Style>
    </Window.Resources>

    <!-- Viewbox scales content to fit any window size or screen resolution -->
    <Viewbox Stretch="Uniform">
        <Border Width="950" Height="760" Padding="20">
            <!-- Centered Setup Card -->
            <Border Width="900" Height="720" Background="#FFFFFF" CornerRadius="8" Padding="32,20">
                <Border.Effect>
                    <DropShadowEffect BlurRadius="15" ShadowDepth="1" Opacity="0.15" Color="#000000"/>
                </Border.Effect>

                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <!-- Header -->
                    <TextBlock Grid.Row="0" Name="TxtHeader" 
                               Text="Configure deployment settings" 
                               FontSize="24" FontFamily="Segoe UI Light" 
                               Foreground="#005A9E" Margin="0,0,0,12"/>

                    <!-- Scrollable Main Setup Section Area -->
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="0,0,4,0">
                    <StackPanel Name="MainSetupPanel" VerticalAlignment="Top" HorizontalAlignment="Stretch">
                        
                        <!-- SECTION 1: Computer Identification -->
                        <StackPanel Name="HeaderComputerID" Orientation="Horizontal" Margin="0,0,0,4">
                            <Rectangle Width="3" Height="14" Fill="#005A9E" RadiusX="1" RadiusY="1" Margin="0,0,8,0" VerticalAlignment="Center"/>
                            <TextBlock Text="Computer Identification" FontSize="13" FontWeight="SemiBold" Foreground="#005A9E" FontFamily="Segoe UI" VerticalAlignment="Center"/>
                        </StackPanel>

                        <Border Name="CardComputerID" Background="#FAFBFC" BorderBrush="#D9E0E7" BorderThickness="1" CornerRadius="5" Padding="12,8" Margin="0,0,0,6" HorizontalAlignment="Stretch">
                            <StackPanel Name="ContainerComputerID" HorizontalAlignment="Stretch">
                                <Grid Name="RowComputerName" Margin="0,0,0,6" Visibility="Collapsed" HorizontalAlignment="Stretch">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="170"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Text="Computer name" VerticalAlignment="Center" FontSize="12.5" Foreground="#374151" FontFamily="Segoe UI"/>
                                    <Grid Grid.Column="1" HorizontalAlignment="Stretch">
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="Auto"/>
                                            <RowDefinition Height="Auto"/>
                                        </Grid.RowDefinitions>
                                        <TextBox Grid.Row="0" Name="TxtComputerName" Height="28" HorizontalAlignment="Stretch" ToolTip="e.g. PC-OFFICE-001"/>
                                        <TextBlock Grid.Row="1" Name="TxtComputerNameError" Foreground="#D13438" FontSize="11" Margin="2,2,0,0" Height="14" Visibility="Hidden" TextWrapping="Wrap" FontFamily="Segoe UI"/>
                                    </Grid>
                                </Grid>

                                <Grid Name="RowComputerDescription" Margin="0,0,0,0" Visibility="Collapsed" HorizontalAlignment="Stretch">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="170"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Text="Computer description" VerticalAlignment="Center" FontSize="12.5" Foreground="#374151" FontFamily="Segoe UI"/>
                                    <TextBox Grid.Column="1" Name="TxtComputerDescription" Height="28" HorizontalAlignment="Stretch"/>
                                </Grid>
                            </StackPanel>
                        </Border>

                        <!-- SECTION 2: Deployment Workflow Selection -->
                        <StackPanel Orientation="Horizontal" Margin="0,2,0,4">
                            <Rectangle Width="3" Height="14" Fill="#005A9E" RadiusX="1" RadiusY="1" Margin="0,0,8,0" VerticalAlignment="Center"/>
                            <TextBlock Text="Select deployment workflow" FontSize="13" FontWeight="SemiBold" Foreground="#005A9E" FontFamily="Segoe UI" VerticalAlignment="Center"/>
                        </StackPanel>
                        
                        <Border Background="#FAFBFC" BorderBrush="#D9E0E7" BorderThickness="1" CornerRadius="5" Height="160" Margin="0,0,0,4" HorizontalAlignment="Stretch">
                            <TreeView Name="treeViewWorkflows" Grid.IsSharedSizeScope="True" Background="Transparent" BorderThickness="0" Padding="4" HorizontalContentAlignment="Stretch" ScrollViewer.VerticalScrollBarVisibility="Auto">
                                
                                <!-- Standard Workflow -->
                                <TreeViewItem Style="{StaticResource HeaderNodeStyle}" Name="nodeStandard">
                                    <TreeViewItem Style="{StaticResource ChildNodeStyle}" Name="itemStdEnt" Tag="W11-ENT-STD"/>
                                    <TreeViewItem Style="{StaticResource ChildNodeStyle}" Name="itemStdPro" Tag="W11-PRO-STD"/>
                                </TreeViewItem>

                                <!-- Intune Workflow -->
                                <TreeViewItem Style="{StaticResource HeaderNodeStyle}" Name="nodeIntune">
                                    <TreeViewItem Style="{StaticResource ChildNodeStyle}" Name="itemApEnt" Tag="W11-ENT-AP"/>
                                    <TreeViewItem Style="{StaticResource ChildNodeStyle}" Name="itemApPro" Tag="W11-PRO-AP"/>
                                </TreeViewItem>

                            </TreeView>
                        </Border>

                        <!-- Workflow Validation Error Message -->
                        <TextBlock Name="TxtWorkflowError" Foreground="#D13438" FontSize="11" Margin="2,-4,0,2" Height="14" Visibility="Hidden" TextWrapping="Wrap" FontFamily="Segoe UI"/>

                        <!-- SECTION 3: Hard Drive Selection -->
                        <Grid Margin="0,2,0,4" HorizontalAlignment="Stretch">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <Rectangle Grid.Column="0" Width="3" Height="14" Fill="#005A9E" RadiusX="1" RadiusY="1" Margin="0,0,8,0" VerticalAlignment="Center"/>
                            <TextBlock Grid.Column="1" Text="Select target hard drive" FontSize="13" FontWeight="SemiBold" Foreground="#005A9E" VerticalAlignment="Center" FontFamily="Segoe UI"/>
                            <Button Grid.Column="2" Name="BtnRefresh" Content="Refresh Disks" Style="{StaticResource ActionLinkStyle}"/>
                        </Grid>

                        <Border Background="#FAFBFC" BorderBrush="#CCCCCC" BorderThickness="1" CornerRadius="4" Height="90" Margin="0,0,0,4" HorizontalAlignment="Stretch">
                            <DataGrid Name="GridDisks" AutoGenerateColumns="False" 
                                      HeadersVisibility="Column" GridLinesVisibility="None" 
                                      Background="White" BorderThickness="0" 
                                      RowHeight="28" SelectionMode="Single" IsReadOnly="True"
                                      CanUserAddRows="False" CanUserDeleteRows="False"
                                      CanUserResizeColumns="True" HorizontalAlignment="Stretch">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Disk Index" Binding="{Binding Index}" Width="100"/>
                                    <DataGridTextColumn Header="Model / Drive Name" Binding="{Binding Model}" Width="*"/>
                                    <DataGridTextColumn Header="Capacity" Binding="{Binding Capacity}" Width="110"/>
                                    <DataGridTextColumn Header="Current Usage" Binding="{Binding UsedSpace}" Width="120"/>
                                    <DataGridTextColumn Header="Available Space" Binding="{Binding FreeSpace}" Width="120"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </Border>

                        <!-- Disk Validation Error Message -->
                        <TextBlock Name="TxtDiskError" Foreground="#D13438" FontSize="11" Margin="2,-4,0,2" Height="14" Visibility="Hidden" TextWrapping="Wrap" FontFamily="Segoe UI"/>

                        <!-- SECTION 4: Drivers & Hardware Injections -->
                        <StackPanel Orientation="Horizontal" Margin="0,2,0,4">
                            <Rectangle Width="3" Height="14" Fill="#005A9E" RadiusX="1" RadiusY="1" Margin="0,0,8,0" VerticalAlignment="Center"/>
                            <TextBlock Text="Drivers &amp; Hardware Injections" FontSize="13" FontWeight="SemiBold" Foreground="#005A9E" FontFamily="Segoe UI" VerticalAlignment="Center"/>
                        </StackPanel>
                        
                        <Border Background="#FAFBFC" BorderBrush="#D9E0E7" BorderThickness="1" CornerRadius="5" Padding="12,8" HorizontalAlignment="Stretch">
                            <StackPanel Name="ContainerDrivers" HorizontalAlignment="Stretch">
                                
                                <!-- WMI Detection Hardware Banner -->
                                <Grid Margin="0,0,0,6" HorizontalAlignment="Stretch">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="170"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Text="Manufacturer &amp; Model:" FontWeight="SemiBold" FontSize="12.5" Foreground="#374151" FontFamily="Segoe UI"/>
                                    <TextBlock Grid.Column="1" Name="TxtDetectedHardware" Text="Detecting..." FontSize="12.5" Foreground="#005A9E" FontWeight="SemiBold" FontFamily="Segoe UI"/>
                                </Grid>

                                <!-- Manual Driver Pack Selection -->
                                <Grid Name="RowManualDriverSelection" Margin="0,0,0,6" Visibility="Collapsed" HorizontalAlignment="Stretch">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="170"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Text="Driver pack location" VerticalAlignment="Center" FontSize="12.5" Foreground="#374151" FontFamily="Segoe UI"/>
                                    <ComboBox Grid.Column="1" Name="CmbDriverPackPath" Height="28" VerticalContentAlignment="Center" FontSize="12" Margin="0,0,8,0" HorizontalAlignment="Stretch"/>
                                    <Button Grid.Column="2" Name="BtnBrowseDriverFolder" Content="Select Folder..." Style="{StaticResource ActionLinkStyle}" Height="28"/>
                                </Grid>

                                <!-- Auto Online Download Checkbox -->
                                <CheckBox Name="ChkOnlineDrivers" Content="Automatically download driver pack online during USB media imaging" 
                                          FontSize="12.5" Foreground="#374151" FontFamily="Segoe UI"/>
                            </StackPanel>
                        </Border>

                    </StackPanel>
                    </ScrollViewer>

                    <!-- Footer Navigation Bar -->
                    <Grid Grid.Row="2" Margin="0,12,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Name="TxtFooterInfo" Text="" FontSize="11" Foreground="#9CA3AF" VerticalAlignment="Center" FontFamily="Segoe UI"/>
                        <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right">
                            <Button Name="BtnBack" Content="Cancel" Width="90" Height="32" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,10,0"/>
                            <Button Name="BtnNext" Content="Start Deployment" Width="135" Height="32" Style="{StaticResource PrimaryButtonStyle}"/>
                        </StackPanel>
                    </Grid>

                </Grid>
            </Border>
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
    exit
}

if ($null -eq $window) {
    Write-Error "Window object returned null."
    exit
}

# -------------------------------------------------------------------
# BUSINESS LOGIC
# -------------------------------------------------------------------

# Map UI Elements
$btnNext                  = $window.FindName("BtnNext")
$btnBack                  = $window.FindName("BtnBack")
$btnRefresh               = $window.FindName("BtnRefresh")
$txtHeader                = $window.FindName("TxtHeader")
$gridDisks                = $window.FindName("GridDisks")
$headerComputerID         = $window.FindName("HeaderComputerID")
$cardComputerID           = $window.FindName("CardComputerID")
$rowComputerName          = $window.FindName("RowComputerName")
$txtComputerName          = $window.FindName("TxtComputerName")
$txtComputerNameError     = $window.FindName("TxtComputerNameError")
$rowComputerDescription   = $window.FindName("RowComputerDescription")
$txtComputerDescription   = $window.FindName("TxtComputerDescription")
$treeView                 = $window.FindName("treeViewWorkflows")
$txtWorkflowError         = $window.FindName("TxtWorkflowError")
$txtDiskError             = $window.FindName("TxtDiskError")
$txtDetectedHardware      = $window.FindName("TxtDetectedHardware")
$rowManualDriverSelection = $window.FindName("RowManualDriverSelection")
$cmbDriverPackPath        = $window.FindName("CmbDriverPackPath")
$btnBrowseDriverFolder    = $window.FindName("BtnBrowseDriverFolder")
$chkOnlineDrivers         = $window.FindName("ChkOnlineDrivers")
$txtFooterInfo            = $window.FindName("TxtFooterInfo")

# Bind Parent Nodes
$nodeStandard = $window.FindName("nodeStandard")
$nodeIntune   = $window.FindName("nodeIntune")
if ($null -ne $nodeStandard) { $nodeStandard.Header = [PSCustomObject]@{ HeaderText = "Standard Workflow (Zero Touch)" } }
if ($null -ne $nodeIntune)   { $nodeIntune.Header   = [PSCustomObject]@{ HeaderText = "Intune Autopilot Workflow" } }

# Helper function to create clean OS objects for DataBinding
function New-OSItem {
    param([string]$Name, [string]$Date)
    $formattedDate = [datetime]::Parse($Date).ToString("MMM dd, yyyy")
    return [PSCustomObject]@{
        Name     = $Name
        DateText = "Updated: $formattedDate"
    }
}

# Bind OS Child Item Data
if ($null -ne $window.FindName("itemStdEnt")) { $window.FindName("itemStdEnt").Header = New-OSItem -Name "Windows 11 Enterprise" -Date "2026-03-15" }
if ($null -ne $window.FindName("itemStdPro")) { $window.FindName("itemStdPro").Header = New-OSItem -Name "Windows 11 Professional" -Date "2026-03-20" }
if ($null -ne $window.FindName("itemApEnt"))  { $window.FindName("itemApEnt").Header  = New-OSItem -Name "Windows 11 Enterprise Autopilot" -Date "2026-04-01" }
if ($null -ne $window.FindName("itemApPro"))  { $window.FindName("itemApPro").Header  = New-OSItem -Name "Windows 11 Professional Autopilot" -Date "2026-04-05" }

# Prevent parent categories from being selected directly
if ($null -ne $treeView) {
    $treeView.add_SelectedItemChanged({
        param($sender, $e)
        if ($treeView.SelectedItem -and $treeView.SelectedItem.HasItems) {
            $firstChild = $treeView.SelectedItem.Items[0]
            $firstChild.IsSelected = $true
        }
    })
}

# Read Configuration Options from BootConfig -> Deployment
$deploymentType = "Media"
if ($null -ne $bootConfig -and $null -ne $bootConfig.Deployment -and -not [string]::IsNullOrWhiteSpace($bootConfig.Deployment.Type)) {
    $deploymentType = $bootConfig.Deployment.Type
}

# Read Configuration Options from BootConfig -> ComputerSetup
$promptComputerName = $true
$maxNameLength      = 15
$namePrefix         = ""
$promptDescription  = $true

if ($null -ne $bootConfig -and $null -ne $bootConfig.ComputerSetup) {
    if ($null -ne $bootConfig.ComputerSetup.PromptForComputerName) {
        $promptComputerName = [bool]$bootConfig.ComputerSetup.PromptForComputerName
    }
    if ($null -ne $bootConfig.ComputerSetup.MaxComputerNameLength -and [int]$bootConfig.ComputerSetup.MaxComputerNameLength -gt 0) {
        $maxNameLength = [int]$bootConfig.ComputerSetup.MaxComputerNameLength
    }
    if (-not [string]::IsNullOrEmpty($bootConfig.ComputerSetup.ComputerNamePrefix)) {
        $namePrefix = $bootConfig.ComputerSetup.ComputerNamePrefix
    }
    if ($null -ne $bootConfig.ComputerSetup.PromptForComputerDescription) {
        $promptDescription = [bool]$bootConfig.ComputerSetup.PromptForComputerDescription
    }
}

# Read Configuration Options from BootConfig -> Drivers
$autoDetectDrivers    = $true
$allowManualSelection  = $true
$autoOnlineDownload    = $true

if ($null -ne $bootConfig -and $null -ne $bootConfig.Drivers) {
    if ($null -ne $bootConfig.Drivers.AutoDetectDrivers) {
        $autoDetectDrivers = [bool]$bootConfig.Drivers.AutoDetectDrivers
    }
    if ($null -ne $bootConfig.Drivers.AllowManualSelection) {
        $allowManualSelection = [bool]$bootConfig.Drivers.AllowManualSelection
    }
    if ($null -ne $bootConfig.Drivers.AutoOnlineDownloadOnMedia) {
        $autoOnlineDownload = [bool]$bootConfig.Drivers.AutoOnlineDownloadOnMedia
    }
}

# Set Footer Deployment Type Info
if ($null -ne $txtFooterInfo) {
    $txtFooterInfo.Text = "Deployment: $deploymentType Mode"
}

# Apply Computer Identification Card & Field Settings
if ($promptComputerName -or $promptDescription) {
    if ($null -ne $headerComputerID) { $headerComputerID.Visibility = [System.Windows.Visibility]::Visible }
    if ($null -ne $cardComputerID)   { $cardComputerID.Visibility   = [System.Windows.Visibility]::Visible }

    if ($promptComputerName) {
        if ($null -ne $rowComputerName) { $rowComputerName.Visibility = [System.Windows.Visibility]::Visible }
        if ($null -ne $txtComputerName) {
            $txtComputerName.MaxLength = $maxNameLength
            if (-not [string]::IsNullOrEmpty($namePrefix)) {
                $txtComputerName.Text = $namePrefix
            }
        }
    } else {
        if ($null -ne $rowComputerName) { $rowComputerName.Visibility = [System.Windows.Visibility]::Collapsed }
    }

    if ($promptDescription) {
        if ($null -ne $rowComputerDescription) { $rowComputerDescription.Visibility = [System.Windows.Visibility]::Visible }
    } else {
        if ($null -ne $rowComputerDescription) { $rowComputerDescription.Visibility = [System.Windows.Visibility]::Collapsed }
    }
} else {
    # If BOTH PromptForComputerName and PromptForComputerDescription are false, collapse Section 1 completely!
    if ($null -ne $headerComputerID)       { $headerComputerID.Visibility       = [System.Windows.Visibility]::Collapsed }
    if ($null -ne $cardComputerID)         { $cardComputerID.Visibility         = [System.Windows.Visibility]::Collapsed }
    if ($null -ne $rowComputerName)        { $rowComputerName.Visibility        = [System.Windows.Visibility]::Collapsed }
    if ($null -ne $rowComputerDescription) { $rowComputerDescription.Visibility = [System.Windows.Visibility]::Collapsed }
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
}

# Hide Online Driver Download checkbox unless Deployment Type is Media AND AutoOnlineDownloadOnMedia is true
if ($null -ne $chkOnlineDrivers) {
    if ($deploymentType -eq "Media" -and $autoOnlineDownload) {
        $chkOnlineDrivers.Visibility = [System.Windows.Visibility]::Visible
    } else {
        $chkOnlineDrivers.Visibility = [System.Windows.Visibility]::Collapsed
        $chkOnlineDrivers.IsChecked = $false
    }
}

# WMI Driver Detection Engine (Content\Drivers\<Manufacturer>\<Model>)
function Get-SystemDriverDetection {
    $driversRoot = Join-Path $PSScriptRoot "Content\Drivers"
    
    $rawManuf = ""
    $rawModel = ""
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $rawManuf = $cs.Manufacturer.Trim()
        $rawModel = $cs.Model.Trim()
    } catch {
        try {
            $wmiCs = Get-WmiObject Win32_ComputerSystem -ErrorAction Stop
            $rawManuf = $wmiCs.Manufacturer.Trim()
            $rawModel = $wmiCs.Model.Trim()
        } catch {
            $rawManuf = "Unknown"
            $rawModel = "Unknown Model"
        }
    }

    # Normalize Manufacturer name
    $manuf = $rawManuf
    if ($rawManuf -like "*Dell*") { $manuf = "Dell" }
    elseif ($rawManuf -like "*HP*" -or $rawManuf -like "*Hewlett*") { $manuf = "HP" }
    elseif ($rawManuf -like "*Lenovo*") { $manuf = "Lenovo" }

    $targetFolder = Join-Path $driversRoot "$manuf\$rawModel"
    $detected = Test-Path $targetFolder

    $relPath = if ($detected) { "Content\Drivers\$manuf\$rawModel" } else { "Standard OS In-Box Drivers" }

    return [PSCustomObject]@{
        Manufacturer = $manuf
        Model        = $rawModel
        RelativePath = $relPath
        FullPath     = if ($detected) { $targetFolder } else { $null }
        IsDetected   = $detected
    }
}

# Run WMI Auto-Detection if policy enables it
if ($autoDetectDrivers) {
    $script:DetectionResult = Get-SystemDriverDetection

    if ($null -ne $txtDetectedHardware) {
        if ($script:DetectionResult.IsDetected) {
            $txtDetectedHardware.Text = "$($script:DetectionResult.Manufacturer) $($script:DetectionResult.Model)"
        } else {
            $txtDetectedHardware.Text = "$($script:DetectionResult.Manufacturer) $($script:DetectionResult.Model) - No driver pack found"
            $txtDetectedHardware.Foreground = [System.Windows.Media.Brushes]::DarkGoldenrod
        }
    }
} else {
    $script:DetectionResult = [PSCustomObject]@{
        Manufacturer = "N/A"
        Model        = "Auto-Detect Disabled"
        RelativePath = "Standard OS In-Box Drivers"
        FullPath     = $null
        IsDetected   = $false
    }

    if ($null -ne $txtDetectedHardware) {
        $txtDetectedHardware.Text = "Auto-Detection Disabled by Policy"
        $txtDetectedHardware.Foreground = [System.Windows.Media.Brushes]::Gray
    }
}

# Populate Driver Selection ComboBox cleanly
if ($null -ne $cmbDriverPackPath) {
    $cmbDriverPackPath.Items.Clear()

    # Auto-Detect Option (Only included if a matching driver pack was found on disk/share)
    if ($script:DetectionResult.IsDetected) {
        $null = $cmbDriverPackPath.Items.Add("Auto-Detect: $($script:DetectionResult.RelativePath)")
    }

    # Standard OS In-Box Drivers Option
    $null = $cmbDriverPackPath.Items.Add("Standard OS In-Box Drivers (Windows Default)")

    # Online Download Option (If Media mode & AutoOnlineDownloadOnMedia is enabled)
    if ($deploymentType -eq "Media" -and $autoOnlineDownload) {
        $null = $cmbDriverPackPath.Items.Add("Online Download (Web Repository)")
    }

    # Precedence Rules on Window Launch:
    # 1. Local driver pack detected -> Default to Auto-Detect local pack
    # 2. Local driver pack missing & Media Online Download enabled -> Default to Online Download
    # 3. Otherwise -> Default to Standard OS In-Box Drivers
    if ($script:DetectionResult.IsDetected) {
        $cmbDriverPackPath.SelectedIndex = 0
        if ($null -ne $chkOnlineDrivers) { $chkOnlineDrivers.IsChecked = $false }
    } elseif ($deploymentType -eq "Media" -and $autoOnlineDownload) {
        for ($i = 0; $i -lt $cmbDriverPackPath.Items.Count; $i++) {
            if ($cmbDriverPackPath.Items[$i].ToString() -like "*Online Download*") {
                $cmbDriverPackPath.SelectedIndex = $i
                break
            }
        }
        if ($null -ne $chkOnlineDrivers) { $chkOnlineDrivers.IsChecked = $true }
    } else {
        $cmbDriverPackPath.SelectedIndex = 0
        if ($null -ne $chkOnlineDrivers) { $chkOnlineDrivers.IsChecked = $false }
    }
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

        $initialDriverPath = if ($script:DetectionResult.FullPath) {
            $script:DetectionResult.FullPath
        } else {
            Join-Path $PSScriptRoot "Content\Drivers"
        }

        $customPath = Show-DriverPathDialog -WindowTitle "Select Driver Folder" -InitialPath $initialDriverPath -Owner $window
        if ($customPath) {
            $customEntry = "Custom: $customPath"
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
            if ($cmbDriverPackPath.Items[$i].ToString() -like "*Online Download*") {
                $cmbDriverPackPath.SelectedIndex = $i
                break
            }
        }
    })

    $chkOnlineDrivers.add_Unchecked({
        if ($cmbDriverPackPath.SelectedItem -and $cmbDriverPackPath.SelectedItem.ToString() -like "*Online Download*") {
            $cmbDriverPackPath.SelectedIndex = 0
        }
    })

    $cmbDriverPackPath.add_SelectionChanged({
        if ($cmbDriverPackPath.SelectedItem) {
            if ($cmbDriverPackPath.SelectedItem.ToString() -like "*Online Download*") {
                $chkOnlineDrivers.IsChecked = $true
            } else {
                $chkOnlineDrivers.IsChecked = $false
            }
        }
    })
}

# Physical Hard Drive Retrieval Logic (aligned with LiteDeploy.PreCheck.ps1)
function Get-WinPEPhysicalDisks {
    $diskList = @()
    try {
        if (Get-Command Get-Disk -ErrorAction SilentlyContinue) {
            $disks = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -ne "USB" -and $_.OperationalStatus -eq "Online" } | Sort-Object Number
            foreach ($d in $disks) {
                $totalGB = if ($d.Size) { [math]::Round([double]$d.Size / 1GB, 1) } else { 0 }
                $model = if ($d.Model) { $d.Model.Trim() } elseif ($d.FriendlyName) { $d.FriendlyName.Trim() } else { "Internal Drive" }
                
                $usedGB = 0
                try {
                    $partitions = Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue
                    if ($partitions) {
                        $allocatedBytes = ($partitions | Measure-Object -Property Size -Sum).Sum
                        if ($null -ne $allocatedBytes) {
                            $usedGB = [math]::Round([double]$allocatedBytes / 1GB, 1)
                        }
                    }
                } catch {}

                $availGB = [math]::Max(0, [math]::Round($totalGB - $usedGB, 1))

                $diskList += [PSCustomObject]@{
                    Index        = "Disk $($d.Number)"
                    Model        = $model
                    Capacity     = "$totalGB GB"
                    UsedSpace    = "$usedGB GB"
                    FreeSpace    = "$availGB GB"
                    DiskNumber   = $d.Number
                }
            }
        }

        if ($diskList.Count -eq 0) {
            $wmiDisks = Get-WmiObject Win32_DiskDrive -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceType -ne "USB" -and $_.MediaType -notlike "*Removable*" } | Sort-Object Index
            foreach ($wd in $wmiDisks) {
                $totalGB = if ($wd.Size) { [math]::Round([double]$wd.Size / 1GB, 1) } else { 0 }
                $model = if ($wd.Model) { $wd.Model.Trim() } else { "Internal Drive" }
                
                $diskList += [PSCustomObject]@{
                    Index        = "Disk $($wd.Index)"
                    Model        = $model
                    Capacity     = "$totalGB GB"
                    UsedSpace    = "$totalGB GB"
                    FreeSpace    = "0 GB"
                    DiskNumber   = $wd.Index
                }
            }
        }
    } catch {
        Write-Warning "Disk query fallback: $_"
    }

    if ($diskList.Count -gt 0) {
        return $diskList
    }

    # Never expose sample disks in WinPE; an empty result safely blocks deployment.
    return @()
}

# Auto-populate physical disk list on launch
if ($null -ne $gridDisks) {
    [object[]]$detectedDisks = @(Get-WinPEPhysicalDisks)
    $gridDisks.ItemsSource = $detectedDisks
    if ($detectedDisks.Count -eq 0 -and $null -ne $txtDiskError) {
        $txtDiskError.Text = "No internal disks were detected. Load the storage driver and refresh."
        $txtDiskError.Visibility = [System.Windows.Visibility]::Visible
    }
}

# Unified Action Handler (Start Deployment / Validate All Sections)
if ($null -ne $btnNext) {
    $btnNext.Add_Click({
        $hasError = $false

        # Reset Error Messages (use Hidden, not Collapsed, to preserve layout)
        if ($null -ne $txtComputerNameError) { $txtComputerNameError.Visibility = [System.Windows.Visibility]::Hidden; $txtComputerNameError.Text = "" }
        if ($null -ne $txtWorkflowError)     { $txtWorkflowError.Visibility     = [System.Windows.Visibility]::Hidden; $txtWorkflowError.Text = "" }
        if ($null -ne $txtDiskError)         { $txtDiskError.Visibility         = [System.Windows.Visibility]::Hidden; $txtDiskError.Text = "" }

        # 1. Validate Computer Name (if enabled)
        if ($promptComputerName -and $null -ne $txtComputerName) {
            $compName = $txtComputerName.Text.Trim()

            if ([string]::IsNullOrWhiteSpace($compName)) {
                $txtComputerNameError.Text = "Computer name cannot be empty."
                $txtComputerNameError.Visibility = [System.Windows.Visibility]::Visible
                $txtComputerName.Focus()
                $hasError = $true
            } elseif ($compName.Length -gt $maxNameLength) {
                $txtComputerNameError.Text = "Computer name must not exceed $maxNameLength characters."
                $txtComputerNameError.Visibility = [System.Windows.Visibility]::Visible
                $txtComputerName.Focus()
                $hasError = $true
            } elseif ($compName -match '[\\/:\*\?"<>\|\s]') {
                $txtComputerNameError.Text = "Computer name contains invalid characters (\ / : * ? `" < > | or spaces)."
                $txtComputerNameError.Visibility = [System.Windows.Visibility]::Visible
                $txtComputerName.Focus()
                $hasError = $true
            } else {
                $script:ComputerName = $compName
            }
        }

        if ($promptDescription -and $null -ne $txtComputerDescription) {
            $script:ComputerDescription = $txtComputerDescription.Text.Trim()
        }

        # 2. Validate Deployment Workflow Selection
        $selectedItem = $treeView.SelectedItem
        if (-not $selectedItem -or -not $selectedItem.Tag) {
            if ($null -ne $txtWorkflowError) {
                $txtWorkflowError.Text = "Please select an OS workflow from the list above."
                $txtWorkflowError.Visibility = [System.Windows.Visibility]::Visible
            }
            $hasError = $true
        } else {
            $script:SelectedWorkflowTag = $selectedItem.Tag
            $script:SelectedOSName      = $selectedItem.Header.Name
        }

        # 3. Validate Target Hard Drive Selection
        $selectedDisk = $gridDisks.SelectedItem
        if (-not $selectedDisk) {
            if ($null -ne $txtDiskError) {
                if ($gridDisks.Items.Count -eq 0) {
                    $txtDiskError.Text = "No internal disks were detected. Load the storage driver and refresh."
                } else {
                    $txtDiskError.Text = "Please select a target hard drive from the table above."
                }
                $txtDiskError.Visibility = [System.Windows.Visibility]::Visible
            }
            $hasError = $true
        } else {
            $script:SelectedDiskIndex = $selectedDisk.Index
            $script:SelectedDiskModel = $selectedDisk.Model
        }

        # 4. Save Driver Selection Path
        $script:AutoDetectDrivers = $autoDetectDrivers
        if ($null -ne $cmbDriverPackPath -and $null -ne $cmbDriverPackPath.SelectedItem) {
            $selectedDriverChoice = $cmbDriverPackPath.SelectedItem.ToString()
            if ($selectedDriverChoice.StartsWith("Custom: ")) {
                $script:SelectedDriverFolderPath = $selectedDriverChoice.Substring(8)
            } elseif ($selectedDriverChoice.StartsWith("Auto-Detect: ") -and $script:DetectionResult.FullPath) {
                $script:SelectedDriverFolderPath = $script:DetectionResult.FullPath
            } else {
                $script:SelectedDriverFolderPath = $selectedDriverChoice
            }
        } else {
            $script:SelectedDriverFolderPath = $script:DetectionResult.RelativePath
        }

        if ($hasError) {
            return
        }

        # Confirm & Complete Setup
        $confirmMsg = "Ready to proceed with deployment?`n`n" +
                      "Computer Name: $($script:ComputerName)`n" +
                      "Workflow: $($script:SelectedOSName)`n" +
                      "Target Disk: $($script:SelectedDiskIndex) ($($script:SelectedDiskModel))`n" +
                      "Driver Path: $($script:SelectedDriverFolderPath)"

        $confirm = [System.Windows.MessageBox]::Show(
            $confirmMsg,
            "Confirm Deployment",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Information
        )

        if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
            $window.Close()
        }
    })
}

if ($null -ne $btnBack) {
    $btnBack.Add_Click({
        $window.Close()
    })
}

if ($null -ne $btnRefresh) {
    $btnRefresh.Add_Click({
        if ($null -ne $gridDisks) {
            [object[]]$detectedDisks = @(Get-WinPEPhysicalDisks)
            $gridDisks.ItemsSource = $detectedDisks
            if ($null -ne $txtDiskError) {
                if ($detectedDisks.Count -eq 0) {
                    $txtDiskError.Text = "No internal disks were detected. Load the storage driver and refresh."
                    $txtDiskError.Visibility = [System.Windows.Visibility]::Visible
                } else {
                    $txtDiskError.Text = ""
                    $txtDiskError.Visibility = [System.Windows.Visibility]::Hidden
                }
            }
        }
    })
}

$window.Add_KeyDown({
    if ($_.Key -eq [System.Windows.Input.Key]::Escape) { $window.Close() }
})

# Display Window
$window.ShowDialog() | Out-Null
