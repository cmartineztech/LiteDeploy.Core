[CmdletBinding()]
param(
    [psobject]$BootObject = $null
)

# Ensured Single-Threaded Apartment (STA) mode for WPF
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    if ($BootObject) {
        throw "LiteDeploy.SelectWorkFlow.ps1 must be invoked from the BootInitializer STA process when BootObject is supplied. Relaunching would discard the in-memory credential."
    }
    powershell.exe -STA -ExecutionPolicy Bypass -File "$PSCommandPath"
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Force software rendering after WPF is loaded for WinPE display-driver compatibility.
[System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly

# Prefer Windows Forms for validation alerts, with a WPF fallback for minimal WinPE images.
$script:WindowsFormsAlertsAvailable = $false
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $script:WindowsFormsAlertsAvailable = $true
} catch {
    Write-Warning "Windows Forms alerts are unavailable; WPF alerts will be used."
}

if ($BootObject) {
    $global:LiteDeployBootObject = $BootObject
} elseif (Test-Path Variable:global:LiteDeployBootObject) {
    $BootObject = $global:LiteDeployBootObject
}

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

# Load the WPF-only folder picker used by the driver selection control.
$driverPathPickerScript = Join-Path $PSScriptRoot "LiteDeploy.SelecWorkflowDriverPicker.ps1"
if (Test-Path -LiteralPath $driverPathPickerScript) {
    . $driverPathPickerScript
}

# Resolve BootConfig.json in the same order as LiteDeploy.PreCheck.ps1.
function Find-Configuration {
    $paths = @(
        (Join-Path $PSScriptRoot "..\01-Config\BootConfig.json"),
        (Join-Path $PSScriptRoot "Config\BootConfig.json"),
        (Join-Path $PSScriptRoot "BootConfig.json")
    )

    foreach ($path in $paths) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    return $null
}

$configPath = $null
$bootConfig = $null

# Prefer the exact configuration object already validated by BootInitializer and
# PreCheck. Standalone launches retain the existing local discovery behavior.
if ($BootObject -and $BootObject.PSObject.Properties['Config'] -and $BootObject.Config) {
    $bootConfig = $BootObject.Config
    if ($BootObject.PSObject.Properties['ConfigPath']) {
        $configPath = [string]$BootObject.ConfigPath
    }
} else {
    $configPath = Find-Configuration
}

if ($bootConfig) {
    # Configuration was supplied in memory by the trusted WinPE parent process.
} elseif ($configPath) {
    try {
        $bootConfig = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        Show-DeploymentWarning -Title "Invalid Deployment Configuration" -Message (
            "BootConfig.json could not be parsed:`r`n`r`n$configPath`r`n`r`n$($_.Exception.Message)"
        )
        return $false
    }
} else {
    Show-DeploymentWarning -Title "Deployment Configuration Not Found" -Message (
        "BootConfig.json was not found in any expected LiteDeploy configuration location."
    )
    return $false
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows Setup" 
        WindowState="Normal" 
        WindowStyle="SingleBorderWindow"
        ResizeMode="NoResize"
        Width="1024" Height="820"
        MinWidth="800" MinHeight="600"
        WindowStartupLocation="CenterScreen"
        Background="#FFFFFF">
    
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

    <DockPanel LastChildFill="True" Margin="48,20">
        
        <!-- Header (Docked Top) -->
        <TextBlock DockPanel.Dock="Top" Name="TxtHeader" 
                   Text="Configure deployment settings" 
                   FontSize="24" FontFamily="Segoe UI Light" 
                   Foreground="#005A9E" Margin="0,0,0,12"/>

        <!-- Footer Navigation Bar (Docked Bottom) -->
        <DockPanel DockPanel.Dock="Bottom" Margin="0,16,0,0">
            <!-- Navigation Buttons -->
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" HorizontalAlignment="Right">
                <Button Name="BtnBack" Content="Cancel" Width="90" Height="32" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,10,0"/>
                <Button Name="BtnNext" Content="Start Deployment" Width="135" Height="32" Style="{StaticResource PrimaryButtonStyle}"/>
            </StackPanel>
        </DockPanel>

        <!-- Main Body Area -->
        <StackPanel Name="MainSetupPanel" VerticalAlignment="Top" HorizontalAlignment="Stretch">
            
            <!-- SECTION 1: Computer Identification -->
            <TextBlock Name="HeaderComputerID" Text="Computer Identification" FontSize="13" FontWeight="SemiBold" Foreground="#005A9E" Margin="0,2,0,4" FontFamily="Segoe UI"/>

            <Border Name="CardComputerID" Background="#FFFFFF" BorderBrush="#D9E0E7" BorderThickness="1" CornerRadius="5" Padding="12,10" Margin="0,0,0,8" HorizontalAlignment="Stretch">
                <StackPanel Name="ContainerComputerID" HorizontalAlignment="Stretch">
                    <Grid Name="RowComputerName" Margin="0,0,0,8" Visibility="Collapsed" HorizontalAlignment="Stretch">
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
                            <TextBox Grid.Row="0" Name="TxtComputerName" Height="28" HorizontalAlignment="Stretch"/>
                            <TextBlock Grid.Row="1" Name="TxtComputerNameError" Foreground="#D13438" FontSize="11" Margin="2,2,0,0" Height="14" Visibility="Hidden" TextWrapping="NoWrap" FontFamily="Segoe UI"/>
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
            <TextBlock Text="Select deployment workflow" FontSize="13" FontWeight="SemiBold" Foreground="#005A9E" Margin="0,2,0,4" FontFamily="Segoe UI"/>
            
            <Border Background="#FFFFFF" BorderBrush="#D9E0E7" BorderThickness="1" CornerRadius="5" Height="200" Margin="0,0,0,8" HorizontalAlignment="Stretch">
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
            <TextBlock Name="TxtWorkflowError" Foreground="#D13438" FontSize="11" Margin="2,-5,0,6" Height="14" Visibility="Hidden" TextWrapping="NoWrap" FontFamily="Segoe UI"/>

            <!-- SECTION 3: Hard Drive Selection -->
            <Grid Margin="0,2,0,4" HorizontalAlignment="Stretch">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Select target hard drive" FontSize="13" FontWeight="SemiBold" Foreground="#005A9E" VerticalAlignment="Center" FontFamily="Segoe UI"/>
                <Button Grid.Column="1" Name="BtnRefresh" Content="Refresh Disks" Style="{StaticResource ActionLinkStyle}"/>
            </Grid>

            <Border Background="#FFFFFF" BorderBrush="#CCCCCC" BorderThickness="1" CornerRadius="4" Height="100" Margin="0,0,0,8" HorizontalAlignment="Stretch">
                <DataGrid Name="GridDisks" AutoGenerateColumns="False" 
                          HeadersVisibility="Column" GridLinesVisibility="None" 
                          Background="White" BorderThickness="0" 
                          RowHeight="28" SelectionMode="Single" IsReadOnly="True"
                          CanUserAddRows="False" CanUserDeleteRows="False"
                          CanUserResizeColumns="True" HorizontalAlignment="Stretch">
                    <DataGrid.Resources>
                        <!-- Keep the selected disk blue when keyboard focus moves elsewhere. -->
                        <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#0078D4"/>
                        <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightBrushKey}" Color="#0078D4"/>
                    </DataGrid.Resources>
                    <DataGrid.CellStyle>
                        <Style TargetType="DataGridCell">
                            <Style.Triggers>
                                <!-- PowerShell 5 otherwise changes inactive selected text to black. -->
                                <Trigger Property="IsSelected" Value="True">
                                    <Setter Property="Foreground" Value="#FFFFFF"/>
                                </Trigger>
                            </Style.Triggers>
                        </Style>
                    </DataGrid.CellStyle>
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="Disk Index" Binding="{Binding Index}" Width="100"/>
                        <DataGridTextColumn Header="Model / Drive Name" Binding="{Binding Model}" Width="*"/>
                        <DataGridTextColumn Header="Capacity" Binding="{Binding Capacity}" Width="110"/>
                        <DataGridTextColumn Header="Estimated Usage" Binding="{Binding UsedSpace}" Width="120"/>
                        <DataGridTextColumn Header="Available Space" Binding="{Binding FreeSpace}" Width="120"/>
                    </DataGrid.Columns>
                </DataGrid>
            </Border>

            <!-- Disk Validation Error Message -->
            <TextBlock Name="TxtDiskError" Foreground="#D13438" FontSize="11" Margin="2,-5,0,6" Height="14" Visibility="Hidden" TextWrapping="NoWrap" FontFamily="Segoe UI"/>

            <!-- SECTION 4: Drivers & Hardware Injections -->
            <TextBlock Text="Drivers &amp; Hardware Injections" FontSize="13" FontWeight="SemiBold" Foreground="#005A9E" Margin="0,2,0,4" FontFamily="Segoe UI"/>
            
            <Border Background="#FFFFFF" BorderBrush="#D9E0E7" BorderThickness="1" CornerRadius="5" Padding="12,10" HorizontalAlignment="Stretch">
                <StackPanel Name="ContainerDrivers" HorizontalAlignment="Stretch">
                    
                    <!-- WMI Detection Hardware Banner -->
                    <Grid Margin="0,0,0,8" HorizontalAlignment="Stretch">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="170"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Text="Manufacturer &amp; Model:" FontWeight="SemiBold" FontSize="12.5" Foreground="#374151" FontFamily="Segoe UI"/>
                        <TextBlock Grid.Column="1" Name="TxtDetectedHardware" Text="Detecting..." FontSize="12.5" Foreground="#005A9E" FontWeight="SemiBold" FontFamily="Segoe UI"/>
                    </Grid>

                    <!-- Manual Driver Pack Selection -->
                    <Grid Name="RowManualDriverSelection" Margin="0,0,0,8" Visibility="Collapsed" HorizontalAlignment="Stretch">
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
    </DockPanel>
</Window>
"@

# Load XAML safely
$reader = New-Object System.Xml.XmlNodeReader $xaml

try {
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
} catch {
    Write-Error "Failed to parse XAML: $_"
    return $false
}

if ($null -eq $window) {
    Write-Error "Window object returned null."
    return $false
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

function Clear-InlineValidationError {
    param([System.Windows.Controls.TextBlock]$ErrorTextBlock)

    if ($null -ne $ErrorTextBlock) {
        $ErrorTextBlock.Text = ""
        $ErrorTextBlock.Visibility = [System.Windows.Visibility]::Hidden
    }
}

# Clear stale validation text as soon as the user completes the related action.
if ($null -ne $txtComputerName) {
    $txtComputerName.Add_TextChanged({
        Clear-InlineValidationError -ErrorTextBlock $txtComputerNameError
    })
}

if ($null -ne $gridDisks) {
    $gridDisks.Add_SelectionChanged({
        if ($null -ne $gridDisks.SelectedItem) {
            Clear-InlineValidationError -ErrorTextBlock $txtDiskError
        }
    })
}

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

$computerSetupConfig = Get-LiteDeployProperty $bootConfig "ComputerSetup"
if ($null -ne $computerSetupConfig) {
    $configuredPromptComputerName = Get-LiteDeployProperty $computerSetupConfig "PromptForComputerName"
    $configuredMaxNameLength = Get-LiteDeployProperty $computerSetupConfig "MaxComputerNameLength"
    $configuredNamePrefix = Get-LiteDeployProperty $computerSetupConfig "ComputerNamePrefix"
    $configuredPromptDescription = Get-LiteDeployProperty $computerSetupConfig "PromptForComputerDescription"

    if ($null -ne $configuredPromptComputerName) {
        $promptComputerName = [bool]$configuredPromptComputerName
    }
    if ($null -ne $configuredMaxNameLength -and [int]$configuredMaxNameLength -gt 0) {
        $maxNameLength = [int]$configuredMaxNameLength
    }
    if (-not [string]::IsNullOrEmpty([string]$configuredNamePrefix)) {
        $namePrefix = [string]$configuredNamePrefix
    }
    if ($null -ne $configuredPromptDescription) {
        $promptDescription = [bool]$configuredPromptDescription
    }
}

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
            $rawManuf = "Dell Inc."
            $rawModel = "Latitude 7450"
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
        $txtDetectedHardware.Text = "$($script:DetectionResult.Manufacturer) $($script:DetectionResult.Model)"
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

# Returns free filesystem bytes plus unallocated bytes. Unreadable partitions
# contribute no free bytes and are therefore conservatively counted as used.
function Get-StorageAvailableBytes {
    param(
        [int]$DiskNumber,
        [double]$TotalBytes
    )

    if (-not (Get-Command Get-Partition -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        $partitions = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop)
        $partitionedBytes = 0.0
        $readableFreeBytes = 0.0
        $canReadVolumes = $null -ne (Get-Command Get-Volume -ErrorAction SilentlyContinue)

        foreach ($partition in $partitions) {
            $partitionBytes = [math]::Max(0.0, [double]$partition.Size)
            $partitionedBytes += $partitionBytes

            if ($canReadVolumes) {
                try {
                    $volume = $partition | Get-Volume -ErrorAction Stop | Select-Object -First 1
                    if ($null -ne $volume -and $null -ne $volume.SizeRemaining) {
                        $volumeFreeBytes = [math]::Max(0.0, [double]$volume.SizeRemaining)
                        $readableFreeBytes += [math]::Min($partitionBytes, $volumeFreeBytes)
                    }
                } catch {
                    # Locked, RAW, hidden, or unmounted partitions count fully as used.
                }
            }
        }

        $unallocatedBytes = [math]::Max(0.0, $TotalBytes - $partitionedBytes)
        return [math]::Min($TotalBytes, $unallocatedBytes + $readableFreeBytes)
    } catch {
        return $null
    }
}

# WMI fallback for WinPE images without the Storage PowerShell cmdlets.
function Get-WmiAvailableBytes {
    param(
        [int]$DiskIndex,
        [double]$TotalBytes,
        [int]$ExpectedPartitionCount = 0
    )

    try {
        $partitions = @(Get-WmiObject -Class Win32_DiskPartition -Filter "DiskIndex = $DiskIndex" -ErrorAction Stop)
        if ($ExpectedPartitionCount -gt 0 -and $partitions.Count -eq 0) {
            return $null
        }

        $partitionedBytes = 0.0
        $readableFreeBytes = 0.0

        foreach ($partition in $partitions) {
            $partitionBytes = [math]::Max(0.0, [double]$partition.Size)
            $partitionedBytes += $partitionBytes

            try {
                $partitionId = ([string]$partition.DeviceID).Replace("'", "''")
                $query = "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$partitionId'} WHERE AssocClass=Win32_LogicalDiskToPartition"
                $logicalDisks = @(Get-WmiObject -Query $query -ErrorAction Stop)
                $partitionFreeBytes = 0.0

                foreach ($logicalDisk in $logicalDisks) {
                    if ($null -ne $logicalDisk.FreeSpace) {
                        $partitionFreeBytes += [math]::Max(0.0, [double]$logicalDisk.FreeSpace)
                    }
                }

                $readableFreeBytes += [math]::Min($partitionBytes, $partitionFreeBytes)
            } catch {
                # If WMI cannot map a filesystem, count the partition fully as used.
            }
        }

        $unallocatedBytes = [math]::Max(0.0, $TotalBytes - $partitionedBytes)
        return [math]::Min($TotalBytes, $unallocatedBytes + $readableFreeBytes)
    } catch {
        return $null
    }
}

function New-WinPEDiskRow {
    param(
        [int]$DiskNumber,
        [string]$Model,
        [double]$TotalBytes,
        $AvailableBytes
    )

    # Unknown space is handled conservatively: all capacity is considered used.
    $safeAvailableBytes = if ($null -eq $AvailableBytes) {
        0.0
    } else {
        [math]::Min($TotalBytes, [math]::Max(0.0, [double]$AvailableBytes))
    }

    # Derive usage from rounded display values so Capacity = Usage + Available.
    $totalGB = [math]::Round($TotalBytes / 1GB, 1)
    $availableGB = [math]::Round($safeAvailableBytes / 1GB, 1)
    $usedGB = [math]::Max(0.0, [math]::Round($totalGB - $availableGB, 1))

    return [PSCustomObject]@{
        Index      = "Disk $DiskNumber"
        Model      = $Model
        Capacity   = "$totalGB GB"
        UsedSpace  = "$usedGB GB"
        FreeSpace  = "$availableGB GB"
        DiskNumber = $DiskNumber
    }
}

# Physical Hard Drive Retrieval Logic (aligned with LiteDeploy.PreCheck.ps1)
function Get-WinPEPhysicalDisks {
    $diskList = @()

    try {
        if (Get-Command Get-Disk -ErrorAction SilentlyContinue) {
            $disks = @(Get-Disk -ErrorAction Stop | Where-Object {
                $_.BusType -ne "USB" -and [double]$_.Size -gt 0 -and
                ($_.OperationalStatus -eq "Online" -or $_.OperationalStatus -contains "Online")
            } | Sort-Object Number)

            foreach ($disk in $disks) {
                $totalBytes = [double]$disk.Size
                $model = if ($disk.Model) {
                    $disk.Model.Trim()
                } elseif ($disk.FriendlyName) {
                    $disk.FriendlyName.Trim()
                } else {
                    "Internal Drive"
                }

                $availableBytes = Get-StorageAvailableBytes -DiskNumber $disk.Number -TotalBytes $totalBytes
                if ($null -eq $availableBytes) {
                    $availableBytes = Get-WmiAvailableBytes -DiskIndex $disk.Number -TotalBytes $totalBytes -ExpectedPartitionCount $disk.NumberOfPartitions
                }

                $diskList += New-WinPEDiskRow -DiskNumber $disk.Number -Model $model -TotalBytes $totalBytes -AvailableBytes $availableBytes
            }
        }
    } catch {
        $diskList = @()
    }

    if ($diskList.Count -eq 0) {
        try {
            $wmiDisks = @(Get-WmiObject -Class Win32_DiskDrive -ErrorAction Stop | Where-Object {
                $_.InterfaceType -ne "USB" -and $_.MediaType -notlike "*Removable*" -and [double]$_.Size -gt 0
            } | Sort-Object Index)

            foreach ($disk in $wmiDisks) {
                $totalBytes = [double]$disk.Size
                $model = if ($disk.Model) { $disk.Model.Trim() } else { "Internal Drive" }
                $availableBytes = Get-WmiAvailableBytes -DiskIndex $disk.Index -TotalBytes $totalBytes -ExpectedPartitionCount $disk.Partitions
                $diskList += New-WinPEDiskRow -DiskNumber $disk.Index -Model $model -TotalBytes $totalBytes -AvailableBytes $availableBytes
            }
        } catch {
            $diskList = @()
        }
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
}

# Unified Action Handler (Start Deployment / Validate All Sections)
$script:DeploymentRequested = $false

if ($null -ne $btnNext) {
    $btnNext.Add_Click({
        $hasError = $false
        $validationMessages = @()
        $firstInvalidControl = $null

        # Hidden preserves the reserved validation rows so errors never shift the UI.
        if ($null -ne $txtComputerNameError) { $txtComputerNameError.Visibility = [System.Windows.Visibility]::Hidden; $txtComputerNameError.Text = "" }
        if ($null -ne $txtWorkflowError)     { $txtWorkflowError.Visibility     = [System.Windows.Visibility]::Hidden; $txtWorkflowError.Text = "" }
        if ($null -ne $txtDiskError)         { $txtDiskError.Visibility         = [System.Windows.Visibility]::Hidden; $txtDiskError.Text = "" }

        # 1. Validate Computer Name (if enabled)
        if ($promptComputerName -and $null -ne $txtComputerName) {
            $compName = $txtComputerName.Text.Trim()

            if ([string]::IsNullOrWhiteSpace($compName)) {
                $txtComputerNameError.Text = "Computer name cannot be empty."
                $txtComputerNameError.Visibility = [System.Windows.Visibility]::Visible
                $validationMessages += "- Enter a computer name."
                $firstInvalidControl = $txtComputerName
                $hasError = $true
            } elseif ($compName.Length -gt $maxNameLength) {
                $txtComputerNameError.Text = "Computer name must not exceed $maxNameLength characters."
                $txtComputerNameError.Visibility = [System.Windows.Visibility]::Visible
                $validationMessages += "- Computer name must not exceed $maxNameLength characters."
                $firstInvalidControl = $txtComputerName
                $hasError = $true
            } elseif ($compName -match '[\\/:\*\?"<>\|\s]') {
                $txtComputerNameError.Text = 'Computer name contains invalid characters (\ / : * ? " < > | or spaces).'
                $txtComputerNameError.Visibility = [System.Windows.Visibility]::Visible
                $validationMessages += '- Computer name contains invalid characters (\ / : * ? " < > | or spaces).'
                $firstInvalidControl = $txtComputerName
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
            $txtWorkflowError.Text = "Please select an OS workflow from the list above."
            $txtWorkflowError.Visibility = [System.Windows.Visibility]::Visible
            $validationMessages += "- Select an operating-system workflow."
            if ($null -eq $firstInvalidControl) { $firstInvalidControl = $treeView }
            $hasError = $true
        } else {
            $script:SelectedWorkflowTag = $selectedItem.Tag
            $script:SelectedOSName      = $selectedItem.Header.Name
        }

        # 3. Validate Target Hard Drive Selection
        $selectedDisk = $gridDisks.SelectedItem
        if (-not $selectedDisk) {
            if ($gridDisks.Items.Count -eq 0) {
                $txtDiskError.Text = "No internal disks were detected. Load the storage driver and refresh."
                $validationMessages += "- No internal disks were detected. Load the storage driver and refresh."
            } else {
                $txtDiskError.Text = "Please select a target hard drive from the table above."
                $validationMessages += "- Select a target hard drive."
            }
            $txtDiskError.Visibility = [System.Windows.Visibility]::Visible
            if ($null -eq $firstInvalidControl) { $firstInvalidControl = $gridDisks }
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
                      "Driver Path: $($script:SelectedDriverFolderPath)"

        $confirm = [System.Windows.MessageBox]::Show(
            $confirmMsg,
            "Confirm Deployment",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Information
        )

        if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
            $script:DeploymentRequested = $true
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
                    $txtDiskError.Text = ""
                    $txtDiskError.Visibility = [System.Windows.Visibility]::Hidden
                    Show-DeploymentWarning -Message "No internal disks were detected. Load the storage driver and refresh."
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
return $script:DeploymentRequested
