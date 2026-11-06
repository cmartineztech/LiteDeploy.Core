# Disk

**ComponentId:** `Disk`  
**Dev folder:** `Runtime/060-Disk`  
**Published:** `Engine\Scripts\Runtime\LiteDeploy.Disk.ps1`

## Purpose

Bare-metal wipe, UEFI/Legacy layout, format, WinRE flags. Called by Engine with `-ConfirmDestroy`.

## Safety

Standalone execution is **read-only** unless `-ConfirmDestroy` / `-ForceWipe` is passed. Default OS staging letter is typically `W:`.

<!-- component-contract -->
## Usage and contract

Inspect storage or prepare the selected disk.

**Source:** [LiteDeploy.Disk.ps1](LiteDeploy.Disk.ps1).

### Requirements and environment

Elevated PowerShell 5.1, storage providers and target disk. Intended deployment use is WinPE; full Windows inspection is useful, formatting the running OS is not.

### What runs and changes

Without ConfirmDestroy standalone use inspects. ConfirmDestroy/ForceWipe enables wipe/partition/format. Standalone DiskNumber defaults to 0: specify it for destructive use. Engine independently validates selection. Import only defines helpers.

### Results and failures

Inspection returns validity/issues. Preparation returns Success and partition details including OSDriveLetter. Failure throws and can leave a partially changed disk; no rollback.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| DiskNumber | Int32 | <code>0</code> | [Parameter(Mandatory = $false)] |
| BootMode | String | <code>"UEFI"</code> | [Parameter(Mandatory = $false)] [ValidateSet("UEFI", "LEGACY")] |
| OSTempDriveLetter | String | <code>$null</code> | [Parameter(Mandatory = $false)] |
| ConfirmDestroy | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] [Alias("ForceWipe")] |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
. '.\Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
$component = '.\Engine\Scripts\Runtime\060-Disk\LiteDeploy.Disk.ps1'
& $component -DiskNumber 0 -BootMode UEFI # Inspection: no ConfirmDestroy.
~~~

### Get-LiteDeployDisk

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Alias("DiskNumber")]
        [int]$Number = 0
    )
~~~

### Test-LiteDeployDiskLayout

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Alias("DiskNumber")]
        [int]$Number = 0,

        [ValidateSet("UEFI", "LEGACY")]
        [string]$ExpectedBootMode = "UEFI"
    )
~~~

### Invoke-DiskPreparation

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [int]$TargetDiskNumber,
        [string]$TargetBootMode,
        [string]$TargetDriveLetter
    )
~~~
