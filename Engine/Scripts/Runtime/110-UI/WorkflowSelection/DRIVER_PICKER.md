# UI.WorkflowSelectionDriverPicker

**ComponentId:** `DriverPicker`  
**Dev:** `Runtime/110-UI/WorkflowSelection`  
**Published:** `Engine\Scripts\Runtime\UI\LiteDeploy.UI.WorkflowSelectionDriverPicker.ps1`

Folder picker used by WorkflowSelection for custom/OEM driver paths; blocks system/root locations.

<!-- component-contract -->
## Usage and contract

Choose a driver folder while blocking system/root locations.

**Source:** [LiteDeploy.UI.WorkflowSelectionDriverPicker.ps1](LiteDeploy.UI.WorkflowSelectionDriverPicker.ps1).

### Requirements and environment

PowerShell 5.1 STA, WPF and picker XAML. Supply ViewPath or preload Environment for named DriverPickerView.

### What runs and changes

Import defines functions; direct execution opens dialog. Enumeration/file checks read disk, not copy/install drivers.

### Results and failures

Returns selected path or null on cancel. Invalid folders remain unselected. Missing view/API or access problems can prevent use.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
. '.\Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
$component = '.\Engine\Scripts\Runtime\110-UI\WorkflowSelection\LiteDeploy.UI.WorkflowSelectionDriverPicker.ps1'
. $component
$folder = Show-DriverPathDialog -ViewPath (Get-LiteDeployComponentPath -Name DriverPickerView)
~~~

### Show-DriverPathDialog

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
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
~~~

## Current behavior and agreed follow-up

See [the detailed guide](../../../../../_Docs/guides/DRIVER_HANDLING.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.
