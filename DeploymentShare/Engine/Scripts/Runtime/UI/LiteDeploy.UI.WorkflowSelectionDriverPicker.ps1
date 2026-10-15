[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Metadata
)

# ==============================================================================
# COMPONENT METADATA
# ==============================================================================

function Get-LiteDeployComponentMetadata {
    return [PSCustomObject]@{
        ComponentId          = "DriverPicker"
        Name                 = "LiteDeploy Driver Folder Picker"
        Version              = "1.1.0"
        Category             = "Runtime"
        TargetEnvironment    = "WinPE"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @()
        Description          = "WinPE WPF driver-folder browser; markup in LiteDeploy.WorkflowSelectionDriverPicker.UI.xaml; DeploymentShare (Z:) labeling, live Select blocking, and .inf/.sys/.cat validation."
    }
}

if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

function Show-DriverPathDialog {
    [CmdletBinding()]
    param(
        [ValidateSet("Light", "Dark")]
        [string]$Theme = "Light",

        [string]$WindowTitle = "Select Driver Folder",

        [string]$InitialPath,

        [string]$DeploymentSharePath,

        # Supplied by WorkflowSelection from Environment; standalone uses the current peer file.
        [string]$ViewPath = '',

        [System.Windows.Window]$Owner
    )

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly

    $deploymentShareRoot = $null
    $deploymentDriversRoot = $null
    $labelAsDeploymentShare = $false

    if (-not [string]::IsNullOrWhiteSpace($DeploymentSharePath)) {
        try {
            $shareInput = $DeploymentSharePath.Trim()
            # GetFullPath("Z:") uses the process CWD on that drive - force a real root.
            if ($shareInput -match '^([A-Za-z]):\\?$') {
                $letter = $Matches[1].ToUpperInvariant()
                $deploymentShareRoot = ($letter + ':')
            } else {
                $deploymentShareRoot = [System.IO.Path]::GetFullPath($shareInput).TrimEnd('\', '/')
            }
            $deploymentDriversRoot = [System.IO.Path]::GetFullPath((Join-Path ($deploymentShareRoot.TrimEnd('\') + '\') 'Content\Drivers'))
        } catch {
            $deploymentShareRoot = $null
            $deploymentDriversRoot = $null
        }
    }

    # Z:\ is always labeled DeploymentShare when that volume is present.
    try {
        $zDrive = [System.IO.DriveInfo]::new('Z')
        if ($zDrive.IsReady) {
            $labelAsDeploymentShare = $true
            if (-not $deploymentShareRoot -or $deploymentShareRoot -notmatch '^(?i)Z:') {
                $deploymentShareRoot = 'Z:'
                $deploymentDriversRoot = 'Z:\Content\Drivers'
            } elseif (-not $deploymentDriversRoot) {
                $deploymentDriversRoot = [System.IO.Path]::GetFullPath((Join-Path ($deploymentShareRoot.TrimEnd('\') + '\') 'Content\Drivers'))
            }
        }
    } catch {
        # Z: not available
    }

    $isDark = ($Theme -eq "Dark")

    if ($isDark) {
        $bgWindow        = "#121212"
        $surfaceBg       = "#1E1E1E"
        $footerBg        = "#181818"
        $borderColor     = "#333333"
        $fgText          = "#F3F4F6"
        $secFg           = "#9CA3AF"
        $buttonBg        = "#2A2A2A"
        $buttonFg        = "#F3F4F6"
        $buttonHoverBg   = "#383838"
        $buttonPressedBg = "#404040"
        $headerColor     = "#3B82F6"
        $primaryHoverBg  = "#2563EB"
        $primaryPressedBg = "#1D4ED8"
        $disabledBg      = "#262626"
        $disabledBorder  = "#333333"
        $disabledFg      = "#6B7280"
        $selectionColor  = "#2563EB"
        $selectionText   = "#FFFFFF"
        $fixedDriveColor = "#3B82F6"
    } else {
        $bgWindow        = "#FFFFFF"
        $surfaceBg       = "#F7F9FB"
        $footerBg        = "#F7F9FB"
        $borderColor     = "#D9E0E7"
        $fgText          = "#111827"
        $secFg           = "#4B5563"
        $buttonBg        = "#FFFFFF"
        $buttonFg        = "#1F2937"
        $buttonHoverBg   = "#F3F4F6"
        $buttonPressedBg = "#E5E7EB"
        $headerColor     = "#005A9E"
        $primaryHoverBg  = "#0078D4"
        $primaryPressedBg = "#004E8C"
        $disabledBg      = "#F3F4F6"
        $disabledBorder  = "#E5E7EB"
        $disabledFg      = "#9CA3AF"
        $selectionColor  = "#CCE8FF"
        $selectionText   = "#111827"
        $fixedDriveColor = "#0078D4"
    }

    # Adaptive dialog size (same idea as HardwarePreCheck / WorkflowSelection).
    # Design canvas stays 480x560; the window scales to the screen and Viewbox fills it.
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue | Out-Null
    try {
        $screenWidth  = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
        $screenHeight = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height
    } catch {
        $screenWidth  = [int][System.Windows.SystemParameters]::PrimaryScreenWidth
        $screenHeight = [int][System.Windows.SystemParameters]::PrimaryScreenHeight
    }

    $designWidth  = 480
    $designHeight = 560
    $targetHeight = [Math]::Min(720, [Math]::Max(420, [int]($screenHeight * 0.55)))
    $targetWidth  = [int]($targetHeight * ($designWidth / [double]$designHeight))
    if ($targetWidth -gt [int]($screenWidth * 0.55)) {
        $targetWidth  = [int]($screenWidth * 0.55)
        $targetHeight = [int]($targetWidth * ($designHeight / [double]$designWidth))
    }
    if ($targetHeight -lt 400) {
        $targetHeight = 400
        $targetWidth  = [int]($targetHeight * ($designWidth / [double]$designHeight))
    }
    if ($targetWidth -lt 360) {
        $targetWidth  = 360
        $targetHeight = [int]($targetWidth * ($designHeight / [double]$designWidth))
    }

    # Load UI from external XAML (PreCheck pattern)
    $xamlPath = if ($ViewPath) { $ViewPath } else { Get-LiteDeployComponentPath -Name DriverPickerView }
    if (-not (Test-Path -LiteralPath $xamlPath -PathType Leaf)) {
        throw "Driver picker UI markup was not found: $xamlPath"
    }

    $xamlText = Get-Content -LiteralPath $xamlPath -Raw -ErrorAction Stop
    foreach ($name in @(
            "bgWindow", "fgText", "secFg", "footerBg", "headerColor", "primaryHoverBg", "primaryPressedBg",
            "buttonBg", "buttonFg", "buttonHoverBg", "buttonPressedBg", "borderColor", "surfaceBg",
            "disabledBg", "disabledBorder", "disabledFg", "selectionColor", "selectionText",
            "targetHeight", "targetWidth", "designWidth", "designHeight"
        )) {
        $xamlText = $xamlText.Replace("{{$name}}", [string](Get-Variable -Name $name -ValueOnly))
    }

    try {
        $window = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xamlText)))
    } catch {
        throw "Unable to load the driver folder picker: $($_.Exception.Message)"
    }

    $window.Title = $WindowTitle

    $window.Width = $targetWidth
    $window.Height = $targetHeight

    if ($null -ne $Owner) {
        $window.Owner = $Owner
        $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
    }

    $treeView         = $window.FindName("FolderTree")
    $btnSelect        = $window.FindName("BtnSelect")
    $btnCancel        = $window.FindName("BtnCancel")
    $selectedPathText = $window.FindName("SelectedPathText")
    $fixedDriveGeometry = $treeView.FindResource("FixedDriveIcon")
    $folderGeometry     = $treeView.FindResource("FolderIcon")
    $selectionState     = @{ Path = $null }
    $brushConverter     = New-Object System.Windows.Media.BrushConverter
    $selectedPathText.Foreground = $brushConverter.ConvertFromString($secFg)
    $driverScanMaxDepth = 8
    $driverScanMaxDirs  = 500

    function Test-IsDriveRootPath {
        param([string]$Path)

        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

        try {
            $full = [System.IO.Path]::GetFullPath($Path)
        } catch {
            return $false
        }

        $root = [System.IO.Path]::GetPathRoot($full)
        if ([string]::IsNullOrWhiteSpace($root)) { return $false }

        return ($full.TrimEnd('\', '/') -eq $root.TrimEnd('\', '/'))
    }

    function Test-IsBlockedSystemPath {
        param([string]$Path)

        if ([string]::IsNullOrWhiteSpace($Path)) { return $true }

        # Drive roots (C:\, X:\, Z:\) stay visible but Select stays disabled.
        if (Test-IsDriveRootPath -Path $Path) {
            return $true
        }

        try {
            $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        } catch {
            return $true
        }

        # DeploymentShare (Z:) root is Content\Drivers - require a subfolder (vendor/model pack).
        if ($deploymentDriversRoot) {
            $driversRootTrimmed = [System.IO.Path]::GetFullPath($deploymentDriversRoot).TrimEnd('\', '/')
            if ($full.Equals($driversRootTrimmed, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }

        # Always block the Windows tree at any depth (C:\Windows, C:\Windows\INF, X:\Windows\...).
        if ($full -match '(?i)(^|[\\/])Windows([\\/]|$)') {
            return $true
        }

        # Block well-known folders only when selected at the drive root.
        # Example: C:\Users is blocked, but C:\Users\Public\Drivers is allowed.
        $rootOnlyNames = @(
            'Users',
            'Program Files',
            'Program Files (x86)',
            'ProgramData',
            'PerfLogs',
            'Recovery',
            'Boot',
            'Windows.old',
            '$Recycle.Bin',
            'System Volume Information',
            'Documents and Settings'
        )
        $rootOnlyPattern = ($rootOnlyNames | ForEach-Object { [regex]::Escape($_) }) -join '|'

        if ($full -match ("(?i)^[A-Za-z]:\\(?:{0})$" -f $rootOnlyPattern)) {
            return $true
        }

        # On the DeploymentShare volume, only Content\Drivers (and below) may be selected.
        if ($deploymentShareRoot -and $deploymentDriversRoot) {
            $shareRootTrimmed = $deploymentShareRoot.TrimEnd('\', '/')
            if ($full.StartsWith($shareRootTrimmed, [System.StringComparison]::OrdinalIgnoreCase)) {
                $driversRootTrimmed = $deploymentDriversRoot.TrimEnd('\', '/')
                if (-not $full.StartsWith($driversRootTrimmed, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $true
                }
            }
        }

        return $false
    }

    function Test-FolderContainsDriverFiles {
        param(
            [string]$RootPath,
            [int]$MaxDepth = 8,
            [int]$MaxDirectories = 500
        )

        if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
            return $false
        }

        $queue = New-Object System.Collections.Generic.Queue[object]
        $queue.Enqueue([pscustomobject]@{ Path = $RootPath; Depth = 0 })
        $visited = 0

        while ($queue.Count -gt 0 -and $visited -lt $MaxDirectories) {
            $current = $queue.Dequeue()
            $visited++

            try {
                $directory = New-Object System.IO.DirectoryInfo($current.Path)

                # Prefer *.inf; fall back to *.sys / *.cat. Stop at first hit.
                foreach ($pattern in @("*.inf", "*.sys", "*.cat")) {
                    foreach ($driverFile in $directory.EnumerateFiles($pattern)) {
                        return $true
                    }
                }

                if ($current.Depth -ge $MaxDepth) { continue }

                foreach ($subDirectory in $directory.EnumerateDirectories()) {
                    if (($subDirectory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        continue
                    }

                    $name = $subDirectory.Name
                    if ($name -match '^(?i)(Windows|\$Recycle\.Bin|System Volume Information)$') {
                        continue
                    }

                    $queue.Enqueue([pscustomobject]@{
                        Path  = $subDirectory.FullName
                        Depth = $current.Depth + 1
                    })
                }
            } catch {
                # Access-denied / transient IO errors: keep scanning siblings.
            }
        }

        return $false
    }

    function Confirm-DriverFolderSelection {
        param([string]$Path)

        if ([string]::IsNullOrWhiteSpace($Path)) {
            return $false
        }

        if (Test-IsBlockedSystemPath -Path $Path) {
            [System.Windows.MessageBox]::Show(
                "That system folder cannot be used as a driver source.`n`nYou can browse into folders like Users and select a deeper driver pack folder.`n`nSelected:`n$Path",
                "Invalid Driver Folder",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            ) | Out-Null
            return $false
        }

        $previousContent = $btnSelect.Content
        $btnSelect.Content = "Checking..."
        $btnSelect.IsEnabled = $false
        $btnCancel.IsEnabled = $false

        try {
            $window.Dispatcher.Invoke(
                [Action]{},
                [System.Windows.Threading.DispatcherPriority]::Background
            )

            $hasDrivers = Test-FolderContainsDriverFiles -RootPath $Path -MaxDepth $driverScanMaxDepth -MaxDirectories $driverScanMaxDirs
        } finally {
            $btnSelect.Content = $previousContent
            $btnSelect.IsEnabled = $true
            $btnCancel.IsEnabled = $true
        }

        if (-not $hasDrivers) {
            [System.Windows.MessageBox]::Show(
                "No driver files (.inf, .sys, or .cat) were found within $driverScanMaxDepth folder levels under:`n`n$Path`n`nChoose a folder that contains a driver pack.",
                "No Drivers Found",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            ) | Out-Null
            return $false
        }

        return $true
    }

    function Update-DriverSelectionUi {
        param([string]$Path)

        if ([string]::IsNullOrWhiteSpace($Path)) {
            $selectionState.Path = $null
            $selectedPathText.Text = "Select a drive or folder"
            $selectedPathText.Foreground = $brushConverter.ConvertFromString($secFg)
            $btnSelect.IsEnabled = $false
            return
        }

        $selectionState.Path = $Path
        $selectedPathText.Text = $Path

        if (Test-IsBlockedSystemPath -Path $Path) {
            $selectedPathText.Foreground = $brushConverter.ConvertFromString($secFg)
            $btnSelect.IsEnabled = $false
        } else {
            $selectedPathText.Foreground = $brushConverter.ConvertFromString($fgText)
            $btnSelect.IsEnabled = $true
        }
    }

    function New-VectorIconElement {
        param(
            [System.Windows.Media.Geometry]$Geometry,
            [string]$Color
        )

        $viewbox = New-Object System.Windows.Controls.Viewbox
        $viewbox.Width = 16
        $viewbox.Height = 16
        $viewbox.Margin = "0,0,8,0"

        $path = New-Object System.Windows.Shapes.Path
        $path.Data = $Geometry
        $path.Fill = $brushConverter.ConvertFromString($Color)
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
        $textBlock.FontSize = 14
        $textBlock.FontFamily = "Segoe UI"
        $textBlock.Foreground = $brushConverter.ConvertFromString($TextColor)

        $null = $stack.Children.Add($IconElement)
        $null = $stack.Children.Add($textBlock)
        return $stack
    }

    try {
        $readyDrives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }
    } catch {
        $readyDrives = @()
    }

    $treeView.Add_SelectedItemChanged({
        if ($treeView.SelectedItem -and $treeView.SelectedItem.Tag) {
            Update-DriverSelectionUi -Path ([string]$treeView.SelectedItem.Tag)
        } else {
            Update-DriverSelectionUi -Path $null
        }
    })

    foreach ($drive in $readyDrives) {
        $driveName = $drive.Name.TrimEnd('\')
        $driveRootFull = $drive.RootDirectory.FullName

        # Hide raw Z: when it is shown as DeploymentShare (Z:).
        if ($labelAsDeploymentShare -and
            ($driveRootFull.TrimEnd('\', '/') -eq 'Z:')) {
            continue
        }

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
        $item.Tag = $driveRootFull
        $item.Cursor = [System.Windows.Input.Cursors]::Hand
        $null = $item.Items.Add("")
        $null = $treeView.Items.Add($item)

        if ($InitialPath -and $InitialPath.StartsWith($driveRootFull, [System.StringComparison]::OrdinalIgnoreCase) -and
            -not ($deploymentShareRoot -and $InitialPath.StartsWith($deploymentShareRoot, [System.StringComparison]::OrdinalIgnoreCase))) {
            $item.IsExpanded = $true
            $item.IsSelected = $true
            Update-DriverSelectionUi -Path $driveRootFull
        }
    }

    # DeploymentShare (Z:) stays last - same position Z: would have in the list.
    if ($labelAsDeploymentShare -and $deploymentShareRoot -and $deploymentDriversRoot) {
        $shareItem = New-Object System.Windows.Controls.TreeViewItem
        $shareItem.Header = New-TreeHeader -Text "DeploymentShare (Z:)" -IconElement (New-VectorIconElement -Geometry $fixedDriveGeometry -Color $fixedDriveColor) -TextColor $fgText
        $shareItem.Tag = $deploymentDriversRoot
        $shareItem.Cursor = [System.Windows.Input.Cursors]::Hand
        $null = $shareItem.Items.Add("")
        $null = $treeView.Items.Add($shareItem)

        if ($InitialPath -and (
                $InitialPath.StartsWith($deploymentDriversRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
                $InitialPath.StartsWith($deploymentShareRoot, [System.StringComparison]::OrdinalIgnoreCase)
            )) {
            $shareItem.IsExpanded = $true
            $shareItem.IsSelected = $true
            Update-DriverSelectionUi -Path $(
                if ($InitialPath.StartsWith($deploymentDriversRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $InitialPath
                } else {
                    $deploymentDriversRoot
                }
            )
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
                if (-not $directory.Exists) { return }

                foreach ($subDirectory in $directory.GetDirectories() | Sort-Object Name) {
                    $subItem = New-Object System.Windows.Controls.TreeViewItem
                    $subItem.Header = New-TreeHeader -Text $subDirectory.Name -IconElement (New-VectorIconElement -Geometry $folderGeometry -Color "#E8A200") -TextColor $fgText
                    $subItem.Tag = $subDirectory.FullName
                    $subItem.Cursor = [System.Windows.Input.Cursors]::Hand
                    $null = $subItem.Items.Add("")
                    $null = $expandedItem.Items.Add($subItem)
                }
            } catch {
                # Access-denied and unavailable folders are intentionally left empty.
            }
        }
    )

    $treeView.Add_MouseDoubleClick({
        if (-not $selectionState.Path) { return }
        if (Test-IsBlockedSystemPath -Path $selectionState.Path) { return }
        if (Confirm-DriverFolderSelection -Path $selectionState.Path) {
            $window.DialogResult = $true
            $window.Close()
        }
    })

    $btnSelect.Add_Click({
        if (-not $selectionState.Path) { return }
        if (Test-IsBlockedSystemPath -Path $selectionState.Path) { return }
        if (Confirm-DriverFolderSelection -Path $selectionState.Path) {
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
