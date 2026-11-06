# Admin.UI.Images

**ComponentId:** `Admin.UI.Images`  
**Dev:** `Admin/090-UI/Images`  
**Published:** `Engine\Scripts\Admin\UI\LiteDeploy.Admin.UI.Images.ps1`

Desktop WPF media-import and OS catalog editor. Prefer calling Admin.Images directly until legacy ImportOSMedia backend lookup is fixed.

<!-- component-contract -->
## Usage and contract

Desktop media-import and catalog editor.

**Source:** [LiteDeploy.Admin.UI.Images.ps1](LiteDeploy.Admin.UI.Images.ps1).

### Requirements and environment

Full Windows STA/WPF, tooling and share. Current limitation: Get-ImportScriptPath searches legacy LiteDeploy.ImportOSMedia.ps1/Import-OSMedia.ps1 names; normal v2 publish may not resolve Admin.Images.

### What runs and changes

Opens UI. Import/rebuild/edition actions modify media/catalogs. Specify DefaultDeploymentShare. Environment named backend mapping is not wired here.

### Results and failures

UI logs/dialogs report errors, no deployment object. Use Admin.Images directly until backend resolution is fixed. Window opening does not prove import works.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| DefaultDeploymentShare | String | <code>(Split-Path -Parent $PSScriptRoot)</code> | [Parameter(Mandatory = $false)] |
| Theme | String | <code>"Light"</code> | [ValidateSet("Light", "Dark")] |
| WindowTitle | String | <code>"LiteDeploy - Windows OS Media Importer & Catalog Manager"</code> |  |
| DarkMode | SwitchParameter | <code>$false</code> |  |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
$component = '.\Engine\Scripts\Admin\090-UI\Images\LiteDeploy.Admin.UI.Images.ps1'
& $component -DefaultDeploymentShare 'C:\LiteDeploy-Staging' -Theme Light # Backend limitation above applies.
~~~
