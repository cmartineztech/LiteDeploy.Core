function Show-DriverPathDialog {
    [CmdletBinding()]
    param(
        [ValidateSet("Light", "Dark")]
        [string]$Theme = "Light",

        [string]$WindowTitle = "Select Driver Folder",

        [string]$InitialPath,

        [System.Windows.Window]$Owner
    )

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly

    if ($Theme -eq "Dark") {
        $bgWindow        = "#1E1E1E"
        $bgTree          = "#252526"
        $borderTree      = "#3F3F46"
        $fgText          = "#FFFFFF"
        $fgTitle         = "#FFFFFF"
        $bgButton        = "#333337"
        $borderButton    = "#555555"
        $fgButton        = "#FFFFFF"
        $selectionColor  = "#3F3F46"
        $fixedDriveColor = "#0078D4"
    } else {
        $bgWindow        = "#F3F3F3"
        $bgTree          = "#FFFFFF"
        $borderTree      = "#CCCCCC"
        $fgText          = "#000000"
        $fgTitle         = "#000000"
        $bgButton        = "#E1E1E1"
        $borderButton    = "#ADADAD"
        $fgButton        = "#000000"
        $selectionColor  = "#E5E5E5"
        $fixedDriveColor = "#0078D4"
    }

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Select Driver Folder" Height="480" Width="440"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        ShowInTaskbar="False" Background="$bgWindow">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0" Text="Browse for a driver folder" FontSize="14"
                   FontWeight="SemiBold" Margin="0,0,0,10" Foreground="$fgTitle"/>

        <TreeView Name="FolderTree" Grid.Row="1" BorderThickness="1"
                  BorderBrush="$borderTree" Background="$bgTree">
            <TreeView.Resources>
                <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="$selectionColor"/>
                <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightBrushKey}" Color="$selectionColor"/>
                <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="$fgText"/>
                <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightTextBrushKey}" Color="$fgText"/>
                <Geometry x:Key="FixedDriveIcon">M2 4C2 2.9 2.9 2 4 2H20C21.1 2 22 2.9 22 4V16C22 17.1 21.1 18 20 18H4C2.9 18 2 17.1 2 16V4M4 4V16H20V4H4M6 13H8V15H6V13M16 13H18V15H16V13Z</Geometry>
                <Geometry x:Key="FolderIcon">M10 4H4C2.9 4 2 4.9 2 6V18C2 19.1 2.9 20 4 20H20C21.1 20 22 19.1 22 18V8C22 6.9 21.1 6 20 6H12L10 4Z</Geometry>
            </TreeView.Resources>
        </TreeView>

        <TextBlock Name="SelectedPathText" Grid.Row="2" Margin="2,8,2,0"
                   Foreground="$fgText" TextTrimming="CharacterEllipsis"/>

        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button Name="BtnSelect" Content="Select" Width="85" Height="28" Margin="0,0,8,0"
                    IsDefault="True" IsEnabled="False" Background="$bgButton"
                    BorderBrush="$borderButton" Foreground="$fgButton"/>
            <Button Name="BtnCancel" Content="Cancel" Width="85" Height="28" IsCancel="True"
                    Background="$bgButton" BorderBrush="$borderButton" Foreground="$fgButton"/>
        </StackPanel>
    </Grid>
</Window>
"@

    try {
        $reader = New-Object System.Xml.XmlNodeReader $xaml
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
    } catch {
        throw "Unable to load the driver folder picker: $($_.Exception.Message)"
    }

    $window.Title = $WindowTitle
    if ($null -ne $Owner) {
        $window.Owner = $Owner
        $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
    }

    $treeView        = $window.FindName("FolderTree")
    $btnSelect       = $window.FindName("BtnSelect")
    $btnCancel       = $window.FindName("BtnCancel")
    $selectedPathText = $window.FindName("SelectedPathText")
    $fixedDriveGeometry = $treeView.FindResource("FixedDriveIcon")
    $folderGeometry     = $treeView.FindResource("FolderIcon")
    $selectionState     = @{ Path = $null }

    function New-VectorIconElement {
        param(
            [System.Windows.Media.Geometry]$Geometry,
            [string]$Color
        )

        $viewbox = New-Object System.Windows.Controls.Viewbox
        $viewbox.Width = 16
        $viewbox.Height = 16
        $viewbox.Margin = "0,0,6,0"

        $path = New-Object System.Windows.Shapes.Path
        $path.Data = $Geometry
        $path.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
        $viewbox.Child = $path
        return $viewbox
    }

    function New-TreeHeader {
        param(
            [string]$Text,
            [System.Windows.FrameworkElement]$IconElement,
            [string]$TextColor
        )

        $stack = New-Object System.Windows.Controls.StackPanel
        $stack.Orientation = "Horizontal"

        $textBlock = New-Object System.Windows.Controls.TextBlock
        $textBlock.Text = $Text
        $textBlock.VerticalAlignment = "Center"
        $textBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($TextColor)

        $null = $stack.Children.Add($IconElement)
        $null = $stack.Children.Add($textBlock)
        return $stack
    }

    try {
        $readyDrives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }
    } catch {
        $readyDrives = @()
    }

    foreach ($drive in $readyDrives) {
        $driveName = $drive.Name.TrimEnd('\')
        switch ($drive.DriveType.ToString()) {
            "Removable" { $color = "#107C41"; $typeLabel = "Removable Disk" }
            "Fixed"     { $color = $fixedDriveColor; $typeLabel = "Local Disk" }
            "Network"   { $color = "#6B69D6"; $typeLabel = "Network Drive" }
            Default     { $color = "#6B69D6"; $typeLabel = "Drive" }
        }

        $displayName = if ($drive.VolumeLabel) {
            "$($drive.VolumeLabel) ($driveName)"
        } else {
            "$typeLabel ($driveName)"
        }

        $item = New-Object System.Windows.Controls.TreeViewItem
        $item.Header = New-TreeHeader -Text $displayName -IconElement (New-VectorIconElement -Geometry $fixedDriveGeometry -Color $color) -TextColor $fgText
        $item.Tag = $drive.RootDirectory.FullName
        $null = $item.Items.Add("")
        $null = $treeView.Items.Add($item)

        if ($InitialPath -and $InitialPath.StartsWith($drive.RootDirectory.FullName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $item.IsExpanded = $true
            $item.IsSelected = $true
        }
    }

    $treeView.AddHandler(
        [System.Windows.Controls.TreeViewItem]::ExpandedEvent,
        [System.Windows.RoutedEventHandler]{
            param($sender, $e)
            $expandedItem = $e.OriginalSource
            if ($expandedItem.Items.Count -ne 1 -or $expandedItem.Items[0] -ne "") {
                return
            }

            $expandedItem.Items.Clear()
            try {
                $directory = New-Object System.IO.DirectoryInfo([string]$expandedItem.Tag)
                foreach ($subDirectory in $directory.GetDirectories() | Sort-Object Name) {
                    $subItem = New-Object System.Windows.Controls.TreeViewItem
                    $subItem.Header = New-TreeHeader -Text $subDirectory.Name -IconElement (New-VectorIconElement -Geometry $folderGeometry -Color "#E8A200") -TextColor $fgText
                    $subItem.Tag = $subDirectory.FullName
                    $null = $subItem.Items.Add("")
                    $null = $expandedItem.Items.Add($subItem)
                }
            } catch {
                # Access-denied and unavailable folders are intentionally left empty.
            }
        }
    )

    $treeView.Add_SelectedItemChanged({
        if ($treeView.SelectedItem -and $treeView.SelectedItem.Tag) {
            $selectionState.Path = [string]$treeView.SelectedItem.Tag
            $selectedPathText.Text = $selectionState.Path
            $btnSelect.IsEnabled = $true
        }
    })

    $treeView.Add_MouseDoubleClick({
        if ($selectionState.Path) {
            $window.DialogResult = $true
            $window.Close()
        }
    })

    $btnSelect.Add_Click({
        if ($selectionState.Path) {
            $window.DialogResult = $true
            $window.Close()
        }
    })

    $btnCancel.Add_Click({ $window.Close() })

    if ($window.ShowDialog() -eq $true) {
        return [string]$selectionState.Path
    }

    return $null
}

# Keep the picker useful as a standalone script while allowing setup UIs to dot-source it.
if ($MyInvocation.InvocationName -ne '.') {
    $selectedPath = Show-DriverPathDialog
    if ($selectedPath) {
        Write-Output $selectedPath
    }
}
