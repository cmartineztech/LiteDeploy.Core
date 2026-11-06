# Hardware

**ComponentId:** `Hardware`  
**Dev folder:** `Runtime/030-Hardware`  
**Published:** `Engine\Scripts\Runtime\LiteDeploy.Hardware.ps1`

## Purpose

Hardware inventory and readiness helpers used by Boot bootstrap, Engine, and UI.HardwarePrecheck (domain logic; UI stays in `110-UI`).

`Test-LiteDeployHardwareRequirements` is LiteDeploy’s own readiness check (memory/disk/TPM helpers for Precheck). It is **not** `ComputerSetup.SkipSetupHardwareRequirements` (Setup.exe LabConfig/MoSetup bypass owned by Image).

<!-- component-contract -->
## Usage and contract

Read identity, firmware, memory, network, disks, and readiness facts.

**Source:** [LiteDeploy.Hardware.ps1](LiteDeploy.Hardware.ps1).

### Requirements and environment

PowerShell 5.1, CIM/WMI, storage/firmware APIs. WinPE needs optional components and device drivers; missing APIs can yield unavailable values.

### What runs and changes

Import defines helpers. Direct execution prints read-only inventory; PassThru returns it too. Clear-HardwareCache resets cached facts. No disks are formatted or drivers installed.

### Results and failures

Inventory returns device fields; requirements check returns Passed and Checks. Unknown TPM/firmware values do not prove compliance. Inspect actual returned facts.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |
| PassThru | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
. '.\Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
$component = '.\Engine\Scripts\Runtime\030-Hardware\LiteDeploy.Hardware.ps1'
$inventory = & $component -PassThru
$inventory | Select-Object Vendor, Model, MemoryGB, DiskCount
~~~

### Get-LiteDeployHardwareInventory

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [psobject]$Assessment = $null,
        [object[]]$Results = @(),
        [bool]$Passed = $true,
        [switch]$Force
    )
~~~

### Test-LiteDeployHardwareRequirements

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [int]$MinMemoryGB = 4,
        [int]$MinDiskGB = 64,
        [switch]$RequireTpm
    )
~~~

### Clear-HardwareCache

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
# No parameters.
~~~

## Current behavior and agreed follow-up

See [the detailed guide](../../../../_Docs/guides/LOGGING_AND_FAILURE_DESIGN.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.
