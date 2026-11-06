# UI.Progress

The optional display emulator has a separate [testing guide](TESTING.md), including its
current legacy host-filename limitation. The external Progress XAML is not required by this
controller; it builds its active markup internally.

**ComponentId:** `UI.Progress`  
**Dev:** `110-UI/Progress`  
**Published:** `Engine\Scripts\Runtime\UI\LiteDeploy.UI.Progress.ps1`

## Purpose

Topmost WPF progress host. Engine starts it with `Start-Process` (non-blocking) after WorkflowSelection, before Disk/Image work.

## Switches

| Switch | Meaning |
| :--- | :--- |
| `-WinPE` | WinPE layout (aligns with Engine in WinPE); preferred over `-Environment WinPE` |
| `-Theme Light\|Dark` | From `BootConfig.Ui.Theme` (not forced Dark) |
| `-TopMost On` | Always on top while Disk/Image run |
| `-StatePath` | Fallback file; RAM map is preferred |

## State source

1. Named memory-map `Local\LiteDeploy.DeploymentState` (RAM)  
2. `DeploymentState.json` on SystemDrive / OS volume  

Failed/Cancelled → red UI, stays open. Completed → auto-close (~2s) unless `-KeepOpen`.

See `Docs/NATIVE_HOST_DOCUMENTATION.md`.

<!-- component-contract -->
## Usage and contract

Display state independently while Engine runs.

**Source:** [LiteDeploy.UI.Progress.ps1](LiteDeploy.UI.Progress.ps1).

### Requirements and environment

PowerShell 5.1 STA, WPF and memory-map/file state feed. Internal markup; external XAML not required. Actual WinPE WPF requires testing.

### What runs and changes

Opens display and polls. Success auto-closes unless KeepOpen; Failed/Cancelled remains. WinPE selects presentation, not deployment orchestration.

### Results and failures

No deployment object; process exit is not success. Missing feed can leave waiting/default information. Inspect Engine state. Engine records display-start failures separately.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| StatePath | String | <code>".\DeploymentState.json"</code> |  |
| Environment | String | <code>"Auto"</code> | [ValidateSet("Auto", "FullOS", "WinPE")] |
| Theme | String | <code>"Light"</code> | [ValidateSet("Light", "Dark")] |
| TopMost | String | <code>"Off"</code> | [ValidateSet("On", "Off")] |
| WindowTitle | String | <code>""</code> |  |
| ShowBackdrop | SwitchParameter | <code>$false</code> |  |
| KeepOpen | SwitchParameter | <code>$false</code> |  |
| WinPE | SwitchParameter | <code>$false</code> |  |
| Metadata | SwitchParameter | <code>$false</code> |  |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
. '.\Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
$component = '.\Engine\Scripts\Runtime\110-UI\Progress\LiteDeploy.UI.Progress.ps1'
& $component -StatePath 'C:\LiteDeploy-Staging\DeploymentState.json' -Environment FullOS -Theme Light -KeepOpen
~~~

## Current behavior and agreed follow-up

See [the detailed guide](../../../../../_Docs/guides/LOGGING_AND_FAILURE_DESIGN.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.
