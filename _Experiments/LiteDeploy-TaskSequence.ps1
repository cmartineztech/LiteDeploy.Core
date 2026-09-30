<#
.SYNOPSIS
    LiteDeploy task-sequence toolkit for Windows PE.

.DESCRIPTION
    Dot-source to load task-sequence functionality into the current session:

        . X:\LiteDeploy\LiteDeploy-TaskSequence.ps1

        Select-LiteDeployTaskSequence  Console task-sequence picker.

    This file is the home for future task-sequence implementations
    (loading from Config/inventory, filtering, validation, ...).

    Windows PE / PowerShell 5.1. Standalone: no dependencies, no Win32
    interop - it does NOT require LiteDeploy-HostShell.ps1.

.NOTES
    Dot-sourcing enables StrictMode 2.0 and $ErrorActionPreference = "Stop"
    in the calling session (intentional: engine scripts should fail fast).

.EXAMPLE
    $Selected = Select-LiteDeployTaskSequence -TaskSequences $TaskSequences
    if ($null -eq $Selected) { return }
#>

#region 1 - Bootstrap: strict session defaults.

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

#endregion

#region 2 - Console helpers (plain [Console] / string logic only).

function Get-TruncatedText {
    <#
    .SYNOPSIS
        Truncates text to a column width, ending with "..." when cut.
        Text that already fits is returned unchanged.
    .EXAMPLE
        Get-TruncatedText -Value "A very long task sequence name" -Width 12  # "A very lo..."
    #>
    [CmdletBinding()]
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

    $Text.Substring(0, $Width - 3) + "..."
}

function Get-MaxTextLength {
    <#
    .SYNOPSIS
        Longest text length of one property across all rows, with a floor.
        Used by Select-LiteDeployTaskSequence to size table columns.
    .EXAMPLE
        Get-MaxTextLength -Rows $TaskSequences -Property Name -Minimum 20
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [string]$Property,

        [Parameter(Mandatory)]
        [int]$Minimum
    )

    [Math]::Max(
        $Minimum,
        [int](($Rows | ForEach-Object { ([string]$_.$Property).Length } | Measure-Object -Maximum).Maximum)
    )
}

function Clear-ConsoleRegion {
    <#
    .SYNOPSIS
        Blanks a block of console lines and parks the cursor at its top.
        Lets the selector redraw in place without Clear-Host flicker.
    .EXAMPLE
        Clear-ConsoleRegion -StartTop 5 -LineCount 12
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$StartTop,

        [Parameter(Mandatory)]
        [int]$LineCount
    )

    $BlankLine = " " * [Math]::Max(1, [Console]::BufferWidth - 1)

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

#endregion

#region 3 - Public functions.

function Select-LiteDeployTaskSequence {
    <#
    .SYNOPSIS
        Console task-sequence picker: aligned table, Up/Down arrows,
        Home/End, Enter to select, Escape to cancel. Returns the selected
        task-sequence object, or $null on Escape.
        WinPE-friendly: no WPF, WinForms, Out-GridView, HTA, or modules.
        Expected properties: Id, Name, Architecture, Version, Description,
        ImagePath, ImageIndex.
    .EXAMPLE
        $Selected = Select-LiteDeployTaskSequence -TaskSequences $TaskSequences
        if ($null -eq $Selected) { return }
    #>
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

        # Column widths grow to fit the longest value in each column.
        $IdWidth           = Get-MaxTextLength -Rows $TaskSequences -Property Id           -Minimum 4
        $NameWidth         = Get-MaxTextLength -Rows $TaskSequences -Property Name         -Minimum 20
        $ArchitectureWidth = Get-MaxTextLength -Rows $TaskSequences -Property Architecture -Minimum 12
        $VersionWidth      = Get-MaxTextLength -Rows $TaskSequences -Property Version      -Minimum 8

        $AvailableWidth = [Math]::Max(80, [Console]::WindowWidth - 1)

        # 2 chars of padding per column, plus 2 for the selection marker.
        $FixedWidth = 2 + $IdWidth + 2 + $NameWidth + 2 + $ArchitectureWidth + 2 + $VersionWidth + 2

        # Description takes whatever width is left.
        $DescriptionWidth = [Math]::Max(20, $AvailableWidth - $FixedWidth)

        do {
            if ($RenderedLineCount -gt 0) {
                Clear-ConsoleRegion -StartTop $StartTop -LineCount $RenderedLineCount
            }

            [Console]::SetCursorPosition(0, $StartTop)

            Write-Host $Title -ForegroundColor Cyan
            Write-Host "Use Up/Down arrows, Enter to select, or Esc to cancel." -ForegroundColor DarkGray
            Write-Host

            $Header = (
                "  {0,-$IdWidth}  {1,-$NameWidth}  {2,-$ArchitectureWidth}  {3,-$VersionWidth}  {4,-$DescriptionWidth}" -f
                "ID", "Name", "Architecture", "Version", "Description"
            )

            Write-Host $Header -ForegroundColor White
            Write-Host ("-" * [Math]::Min($Header.Length, $AvailableWidth)) -ForegroundColor DarkGray

            for ($Index = 0; $Index -lt $TaskSequences.Count; $Index++) {
                $TaskSequence = $TaskSequences[$Index]

                $Marker = if ($Index -eq $SelectedIndex) { ">" } else { " " }

                $Row = (
                    "{0} {1,-$IdWidth}  {2,-$NameWidth}  {3,-$ArchitectureWidth}  {4,-$VersionWidth}  {5,-$DescriptionWidth}" -f
                    $Marker,
                    (Get-TruncatedText -Value $TaskSequence.Id           -Width $IdWidth),
                    (Get-TruncatedText -Value $TaskSequence.Name         -Width $NameWidth),
                    (Get-TruncatedText -Value $TaskSequence.Architecture -Width $ArchitectureWidth),
                    (Get-TruncatedText -Value $TaskSequence.Version      -Width $VersionWidth),
                    (Get-TruncatedText -Value $TaskSequence.Description  -Width $DescriptionWidth)
                )

                $Row = $Row.PadRight([Math]::Min($AvailableWidth, $Row.Length))

                if ($Index -eq $SelectedIndex) {
                    Write-Host $Row -ForegroundColor Black -BackgroundColor Cyan
                }
                else {
                    Write-Host $Row -ForegroundColor Gray -BackgroundColor Black
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
                    # Wrap around at the top.
                    if ($SelectedIndex -gt 0) { $SelectedIndex-- } else { $SelectedIndex = $TaskSequences.Count - 1 }
                }
                "DownArrow" {
                    # Wrap around at the bottom.
                    if ($SelectedIndex -lt ($TaskSequences.Count - 1)) { $SelectedIndex++ } else { $SelectedIndex = 0 }
                }
                "Home"   { $SelectedIndex = 0 }
                "End"    { $SelectedIndex = $TaskSequences.Count - 1 }
                "Enter"  { return $TaskSequences[$SelectedIndex] }
                "Escape" { return $null }
            }
        }
        while ($true)
    }
    finally {
        [Console]::CursorVisible = $OriginalCursorVisible

        # Park the cursor below the picker so follow-up output does not overwrite it.
        if ($RenderedLineCount -gt 0) {
            [Console]::SetCursorPosition(0, [Math]::Min([Console]::BufferHeight - 1, $StartTop + $RenderedLineCount))
        }
    }
}

#endregion
