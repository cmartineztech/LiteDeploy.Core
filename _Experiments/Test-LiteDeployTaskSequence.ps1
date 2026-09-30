<#
.SYNOPSIS
    Manual verification harness for LiteDeploy-TaskSequence.ps1.

.DESCRIPTION
    Call it from one Windows shell (classic Console Host or Windows PE)
    and it executes ALL tests visually:

    Section 1 (unattended):
        Assertion checks for the helper functions (text truncation,
        column-width math). Prints PASS/FAIL per check and sets the
        exit code.

    Section 2 (visual, runs right after Section 1):
        The task-sequence picker with sample data: Up/Down arrows,
        Home/End, Enter to select, Escape to cancel.

.EXAMPLE
    .\Test-LiteDeployTaskSequence.ps1

    Runs everything: assertions, then the interactive picker demo.

.EXAMPLE
    .\Test-LiteDeployTaskSequence.ps1 -AssertionsOnly

    Runs only the unattended Section 1 assertions (no visual tests).
#>

[CmdletBinding()]
param(
    [switch]$AssertionsOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$ToolkitPath = Join-Path $PSScriptRoot "LiteDeploy-TaskSequence.ps1"

if (-not (Test-Path -LiteralPath $ToolkitPath -PathType Leaf)) {
    throw "Task-sequence toolkit not found: $ToolkitPath"
}

. $ToolkitPath

# ============================================================================
#  Section 1 - Helper assertions (unattended)
# ============================================================================

$script:PassCount = 0
$script:FailCount = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Expected,

        [AllowNull()]
        [object]$Actual
    )

    if ($Expected -eq $Actual) {
        $script:PassCount++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    }
    else {
        $script:FailCount++
        Write-Host "  [FAIL] $Name  expected=[$Expected] actual=[$Actual]" -ForegroundColor Red
    }
}

Write-Host "============================================================"
Write-Host "Section 1: helper assertions"
Write-Host "============================================================"

Write-Host ""
Write-Host "Get-TruncatedText"

Assert-Equal -Name "Short text unchanged"      -Expected "hello"       -Actual (Get-TruncatedText -Value "hello" -Width 10)
Assert-Equal -Name "Exact-fit text unchanged"  -Expected "1234567890"  -Actual (Get-TruncatedText -Value "1234567890" -Width 10)
Assert-Equal -Name "Long text gets ellipsis"   -Expected "hello w..."  -Actual (Get-TruncatedText -Value "hello world foo" -Width 10)
Assert-Equal -Name "Null becomes empty string" -Expected ""            -Actual (Get-TruncatedText -Value $null -Width 10)

Write-Host ""
Write-Host "Get-MaxTextLength"

$Rows = @(
    [PSCustomObject]@{ Name = "abc" }
    [PSCustomObject]@{ Name = "seventeenchars_long!" }
    [PSCustomObject]@{ Name = "abcdefgh" }
)
Assert-Equal -Name "Finds longest value"    -Expected 20 -Actual (Get-MaxTextLength -Rows $Rows -Property Name -Minimum 4)
Assert-Equal -Name "Floor wins when short"  -Expected 25 -Actual (Get-MaxTextLength -Rows $Rows -Property Name -Minimum 25)

Write-Host ""
Write-Host "============================================================"

if ($script:FailCount -gt 0) {
    Write-Host "Section 1 FAILED: $($script:PassCount) passed, $($script:FailCount) failed." -ForegroundColor Red
    Write-Host "============================================================"
    exit 1
}

Write-Host "Section 1 PASSED: $($script:PassCount) of $($script:PassCount) checks." -ForegroundColor Green
Write-Host "============================================================"

if ($AssertionsOnly) {
    exit 0
}

# ============================================================================
#  Section 2 - Interactive picker demo (visual)
# ============================================================================

# Sample task sequences for the picker demo.
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

Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "Task-sequence picker demo (sample data)" -ForegroundColor Cyan
Write-Host "------------------------------------------------------------"

$Selected = Select-LiteDeployTaskSequence -TaskSequences $TaskSequences

Write-Host ""

if ($null -eq $Selected) {
    Write-Host "Selection cancelled (Escape)." -ForegroundColor Yellow
    exit 1
}

Write-Host "Selected:" -ForegroundColor Green
$Selected | Format-List Id, Name, Description, Architecture, Version, ImagePath, ImageIndex, UnattendPath
exit 0
