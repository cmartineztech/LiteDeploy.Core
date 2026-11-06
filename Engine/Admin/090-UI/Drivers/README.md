# Admin.UI.Drivers

**ComponentId:** `Admin.UI.Drivers`  
**Dev:** `Admin/090-UI/Drivers`  
**Published:** `Engine\Scripts\Admin\UI\LiteDeploy.Admin.UI.Drivers.ps1`

Desktop WPF front end for driver catalog / model / download / custom packs on a deployment share.

<!-- component-contract -->
## Usage and contract

Desktop driver catalog/model/download/custom front end.

**Source:** [LiteDeploy.Admin.UI.Drivers.ps1](LiteDeploy.Admin.UI.Drivers.ps1).

### Requirements and environment

Full Windows STA/WPF, preloaded Environment, named AdminDrivers backend. Specify DefaultDeploymentShare. Backend network/extraction/elevation requirements apply.

### What runs and changes

Opens UI; actions download/extract/change catalogs/models. Closing does not undo changes. Theme/DarkMode controls presentation.

### Results and failures

No deployment object. UI logs/dialogs report errors. AddCustom registers a folder but does not populate it. Not a WinPE deployment screen.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| DefaultDeploymentShare | String | <code>""</code> | [Parameter(Mandatory = $false)] |
| Theme | String | <code>"Light"</code> | [ValidateSet("Light", "Dark")] |
| WindowTitle | String | <code>"LiteDeploy - Driver Pack Manager"</code> |  |
| DarkMode | SwitchParameter | <code>$false</code> |  |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
. '.\Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
$component = '.\Engine\Scripts\Admin\090-UI\Drivers\LiteDeploy.Admin.UI.Drivers.ps1'
& $component -DefaultDeploymentShare 'C:\LiteDeploy-Staging' -Theme Light
~~~

## Current behavior and agreed follow-up

See [the detailed guide](../../../../../_Docs/guides/DRIVER_HANDLING.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.
