# Admin.Drivers

**ComponentId:** `Admin.Drivers`  
**Dev:** `Admin/030-Drivers`  
**Published:** `Engine\Scripts\Admin\LiteDeploy.Admin.Drivers.ps1`

OEM driver pack management for the deployment share (Dell, Lenovo, HP experimental, Custom). Adapted from DynamicDriverDownload with LiteDeploy share layout.

## Share layout

| Path | Role |
| :--- | :--- |
| `<Share>\Content\Drivers\` | Driver packs, vendor catalogs, `LocalCatalog.json`, `ComputerModels.csv` |
| `<Share>\Content\Temp\` | Download / catalog build scratch |
| `<Share>\Engine\Tools\` | Optional bundled `curl` |
| `<Share>\WorkLogs\Admin\DriverManagement.log` | Execution log |

## Parameters

- **`-DeploymentShare`** (aliases: `ShareRoot`, `Root`) — deployment share root. Required unless `LiteDeployShareRoot` is set or the script can walk up to a folder that has both `Content` and `Engine`.
- **`-DriversPath`** — optional override of `Content\Drivers`.
- **`-Extract`** — default **`$false`**. Downloads keep the verified archive only; pass `-Extract $true` to expand into `...\Content\`.
- **`-Metadata`** — return component metadata and exit.

## Actions

`Init`, `GetCatalog`, `CheckUpdate`, `Detect`, `Search`, `Status`, `Sync`, `Download`, `AddCustom`

## Examples

```powershell
.\LiteDeploy.Admin.Drivers.ps1 -DeploymentShare C:\DeploymentShare -Action Init
.\LiteDeploy.Admin.Drivers.ps1 -DeploymentShare C:\DeploymentShare -Action GetCatalog -All
.\LiteDeploy.Admin.Drivers.ps1 -DeploymentShare C:\DeploymentShare -Action Download -All
.\LiteDeploy.Admin.Drivers.ps1 -DeploymentShare C:\DeploymentShare -Action Download -All -Extract $true
.\LiteDeploy.Admin.Drivers.ps1 -ShareRoot C:\DeploymentShare -Action Status -All
```

<!-- component-contract -->
## Usage and contract

Maintain model lists, vendor catalogs, packs and custom entries.

**Source:** [LiteDeploy.Admin.Drivers.ps1](LiteDeploy.Admin.Drivers.ps1).

### Requirements and environment

Full Windows, explicit DeploymentShare, network and archive tools. Extraction/ACL may need elevation. Use overrides for fleet models.

### What runs and changes

Action selects work. Initialization/logging may write even for listing. Extract unpacks, AddSupport updates CSV, AddCustom registers folders. Script calls exit: run in child PowerShell, never dot-source.

### Results and failures

Console/logs and exit code (0 dispatch completion, 1 caught failure). Inspect content/catalog after downloads. Custom registration still needs files; Engine does not install packs automatically.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| Action | String | <code>'Detect'</code> | [ValidateSet('Init', 'GetCatalog', 'CheckUpdate', 'Detect', 'Search', 'Status', 'Sync', 'Download', 'AddCustom')] |
| DeploymentShare | String | <code>''</code> | [Alias('ShareRoot', 'Root')] |
| Manufacturer | String | <code>(not supplied)</code> |  |
| SystemSKU | String | <code>(not supplied)</code> |  |
| ComputerModel | String | <code>(not supplied)</code> |  |
| CustomManufacturer | String | <code>(not supplied)</code> |  |
| All | SwitchParameter | <code>$false</code> |  |
| OSCode | String | <code>'Windows11'</code> | [ValidateSet('Windows11', 'Windows10')] |
| AddSupport | SwitchParameter | <code>$false</code> |  |
| Extract | Object | <code>$false</code> |  |
| DriversPath | String | <code>''</code> |  |
| CleanTemp | SwitchParameter | <code>$false</code> |  |
| Metadata | SwitchParameter | <code>$false</code> |  |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
$component = '.\Engine\Scripts\Admin\030-Drivers\LiteDeploy.Admin.Drivers.ps1'
powershell.exe -NoProfile -File $component -Action Status -DeploymentShare 'C:\LiteDeploy-Staging'
~~~

## Current behavior and agreed follow-up

See [the detailed guide](../../../../_Docs/guides/DRIVER_HANDLING.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.
