<#
.SYNOPSIS
    WinPE-friendly console task-sequence selector for LiteDeploy.

.DESCRIPTION
    Displays task sequences as an aligned console table and allows selection
    with Up/Down arrows, Enter, and Escape.

    The selected task sequence is returned as a PowerShell object.

.NOTES
    Designed for Windows PowerShell in classic Console Host and Windows PE.
    No WPF, WinForms, Out-GridView, HTA, or external modules are required.

.EXAMPLE
    .\Test-LiteDeployTaskSequenceSelector.ps1
#>

[CmdletBinding()]
param(
    [string]$Title = "LiteDeploy Task Sequences"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Get-TruncatedText {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [ValidateRange(4, 500)]
        [int]$Width
    )

    $Text = [string]$Value

    if ($Text.Length -le $Width) {
        return $Text
    }

    return $Text.Substring(0, $Width - 3) + "..."
}

function Clear-ConsoleRegion {
    param(
        [Parameter(Mandatory)]
        [int]$StartTop,

        [Parameter(Mandatory)]
        [int]$LineCount
    )

    $BufferWidth = [Math]::Max(1, [Console]::BufferWidth - 1)
    $BlankLine = " " * $BufferWidth

    for ($Line = 0; $Line -lt $LineCount; $Line++) {
        $TargetTop = $StartTop + $Line

        if ($TargetTop -ge [Console]::BufferHeight) {
            break
        }

        [Console]::SetCursorPosition(0, $TargetTop)
        Write-Host $BlankLine -NoNewline
    }

    [Console]::SetCursorPosition(0, $StartTop)
}

function Select-LiteDeployTaskSequence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [object[]]$TaskSequences,

        [string]$Title = "LiteDeploy Task Sequences"
    )

    if ($TaskSequences.Count -eq 0) {
        throw "No task sequences were provided."
    }

    $OriginalCursorVisible = [Console]::CursorVisible
    $SelectedIndex = 0
    $StartTop = [Console]::CursorTop
    $RenderedLineCount = 0

    try {
        [Console]::CursorVisible = $false

        $IdWidth = [Math]::Max(
            4,
            [int](($TaskSequences |
                ForEach-Object { ([string]$_.Id).Length } |
                Measure-Object -Maximum
            ).Maximum)
        )

        $NameWidth = [Math]::Max(
            20,
            [int](($TaskSequences |
                ForEach-Object { ([string]$_.Name).Length } |
                Measure-Object -Maximum
            ).Maximum)
        )

        $ArchitectureWidth = [Math]::Max(
            12,
            [int](($TaskSequences |
                ForEach-Object { ([string]$_.Architecture).Length } |
                Measure-Object -Maximum
            ).Maximum)
        )

        $VersionWidth = [Math]::Max(
            8,
            [int](($TaskSequences |
                ForEach-Object { ([string]$_.Version).Length } |
                Measure-Object -Maximum
            ).Maximum)
        )

        $AvailableWidth = [Math]::Max(80, [Console]::WindowWidth - 1)

        $FixedWidth = (
            2 +                 # Selection marker
            $IdWidth + 2 +
            $NameWidth + 2 +
            $ArchitectureWidth + 2 +
            $VersionWidth + 2
        )

        $DescriptionWidth = [Math]::Max(20, $AvailableWidth - $FixedWidth)

        do {
            if ($RenderedLineCount -gt 0) {
                Clear-ConsoleRegion `
                    -StartTop $StartTop `
                    -LineCount $RenderedLineCount
            }

            [Console]::SetCursorPosition(0, $StartTop)

            Write-Host $Title -ForegroundColor Cyan
            Write-Host "Use Up/Down arrows, Enter to select, or Esc to cancel." -ForegroundColor DarkGray
            Write-Host

            $Header = (
                "  {0,-$IdWidth}  {1,-$NameWidth}  {2,-$ArchitectureWidth}  {3,-$VersionWidth}  {4,-$DescriptionWidth}" -f
                "ID",
                "Name",
                "Architecture",
                "Version",
                "Description"
            )

            Write-Host $Header -ForegroundColor White
            Write-Host ("-" * [Math]::Min($Header.Length, $AvailableWidth)) -ForegroundColor DarkGray

            for ($Index = 0; $Index -lt $TaskSequences.Count; $Index++) {
                $TaskSequence = $TaskSequences[$Index]

                $Marker = if ($Index -eq $SelectedIndex) { ">" } else { " " }

                $Row = (
                    "{0} {1,-$IdWidth}  {2,-$NameWidth}  {3,-$ArchitectureWidth}  {4,-$VersionWidth}  {5,-$DescriptionWidth}" -f
                    $Marker,
                    (Get-TruncatedText -Value $TaskSequence.Id -Width $IdWidth),
                    (Get-TruncatedText -Value $TaskSequence.Name -Width $NameWidth),
                    (Get-TruncatedText -Value $TaskSequence.Architecture -Width $ArchitectureWidth),
                    (Get-TruncatedText -Value $TaskSequence.Version -Width $VersionWidth),
                    (Get-TruncatedText -Value $TaskSequence.Description -Width $DescriptionWidth)
                )

                $Row = $Row.PadRight([Math]::Min($AvailableWidth, $Row.Length))

                if ($Index -eq $SelectedIndex) {
                    Write-Host $Row `
                        -ForegroundColor Black `
                        -BackgroundColor Cyan
                }
                else {
                    Write-Host $Row `
                        -ForegroundColor Gray `
                        -BackgroundColor Black
                }
            }

            Write-Host
            Write-Host "Selected:" -NoNewline -ForegroundColor DarkGray
            Write-Host " $($TaskSequences[$SelectedIndex].Name)" -ForegroundColor Cyan

            Write-Host "Image:" -NoNewline -ForegroundColor DarkGray
            Write-Host " $($TaskSequences[$SelectedIndex].ImagePath)" -ForegroundColor Gray

            Write-Host "Index:" -NoNewline -ForegroundColor DarkGray
            Write-Host " $($TaskSequences[$SelectedIndex].ImageIndex)" -ForegroundColor Gray

            $RenderedLineCount = 8 + $TaskSequences.Count

            $Key = [Console]::ReadKey($true)

            switch ($Key.Key) {
                "UpArrow" {
                    if ($SelectedIndex -gt 0) {
                        $SelectedIndex--
                    }
                    else {
                        $SelectedIndex = $TaskSequences.Count - 1
                    }
                }

                "DownArrow" {
                    if ($SelectedIndex -lt ($TaskSequences.Count - 1)) {
                        $SelectedIndex++
                    }
                    else {
                        $SelectedIndex = 0
                    }
                }

                "Home" {
                    $SelectedIndex = 0
                }

                "End" {
                    $SelectedIndex = $TaskSequences.Count - 1
                }

                "Enter" {
                    return $TaskSequences[$SelectedIndex]
                }

                "Escape" {
                    return $null
                }
            }
        }
        while ($true)
    }
    finally {
        [Console]::CursorVisible = $OriginalCursorVisible

        if ($RenderedLineCount -gt 0) {
            [Console]::SetCursorPosition(
                0,
                [Math]::Min(
                    [Console]::BufferHeight - 1,
                    $StartTop + $RenderedLineCount
                )
            )
        }
    }
}

# Sample task sequences for WinPE testing.
$TaskSequences = @(
    [PSCustomObject]@{
        Id           = "TS001"
        Name         = "Windows 11 Enterprise"
        Description  = "Standard Windows 11 Enterprise deployment"
        Architecture = "x64"
        Version      = "24H2"
        ImagePath    = "X:\Images\Windows11-Enterprise.wim"
        ImageIndex   = 6
        UnattendPath = "X:\LiteDeploy\Unattend\Enterprise.xml"
    }

    [PSCustomObject]@{
        Id           = "TS002"
        Name         = "Windows 11 Developer"
        Description  = "Developer workstation with additional tools"
        Architecture = "x64"
        Version      = "24H2"
        ImagePath    = "X:\Images\Windows11-Developer.wim"
        ImageIndex   = 6
        UnattendPath = "X:\LiteDeploy\Unattend\Developer.xml"
    }

    [PSCustomObject]@{
        Id           = "TS003"
        Name         = "Windows 11 Clean"
        Description  = "Minimal clean Windows 11 deployment"
        Architecture = "x64"
        Version      = "24H2"
        ImagePath    = "X:\Images\Windows11-Clean.wim"
        ImageIndex   = 6
        UnattendPath = "X:\LiteDeploy\Unattend\Clean.xml"
    }
)

Clear-Host

$SelectedTaskSequence = Select-LiteDeployTaskSequence `
    -TaskSequences $TaskSequences `
    -Title $Title

Write-Host

if ($null -eq $SelectedTaskSequence) {
    Write-Host "Task-sequence selection cancelled." -ForegroundColor Yellow
    exit 1
}

Write-Host "Task sequence selected successfully." -ForegroundColor Green
Write-Host

$SelectedTaskSequence |
    Format-List `
        Id,
        Name,
        Description,
        Architecture,
        Version,
        ImagePath,
        ImageIndex,
        UnattendPath

# Example values that LiteDeploy could pass to the deployment engine.
$SelectedTaskSequenceId = $SelectedTaskSequence.Id
$SelectedImagePath = $SelectedTaskSequence.ImagePath
$SelectedImageIndex = $SelectedTaskSequence.ImageIndex
$SelectedUnattendPath = $SelectedTaskSequence.UnattendPath

Write-Host "Ready to deploy: $SelectedTaskSequenceId" -ForegroundColor Cyan
