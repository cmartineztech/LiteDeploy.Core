# Admin.Packages

**ComponentId:** `Admin.Packages`  
**Dev:** `Admin/040-Packages`  
**Published:** `Engine\Scripts\Admin\LiteDeploy.Admin.Packages.ps1`

Admin-side package content helpers for the deployment share.

<!-- component-contract -->
## Usage and contract

List definitions, report authoring warnings, create skeletons.

**Source:** [LiteDeploy.Admin.Packages.ps1](LiteDeploy.Admin.Packages.ps1).

### Requirements and environment

Full Windows authoring host and ShareRoot/Content/Packages. Listing does not run installers.

### What runs and changes

Import defines helpers; direct execution prints validation. New creates payload/package.json and may overwrite an existing ID definition.

### Results and failures

Test returns Passed, Count, Warnings, Packages. Passed stays true with warnings: read them. New returns FileInfo. Shallow validation; unreadable definitions may be omitted.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| ShareRoot | String | <code>""</code> | [Parameter(Mandatory = $false)] |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
$component = '.\Engine\Scripts\Admin\040-Packages\LiteDeploy.Admin.Packages.ps1'
. $component
Test-LiteDeployAdminPackages -ShareRoot 'C:\LiteDeploy-Staging'
~~~

### Get-LiteDeployAdminPackages

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param([Parameter(Mandatory = $true)][string]$ShareRoot)
~~~

### Test-LiteDeployAdminPackages

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param([Parameter(Mandatory = $true)][string]$ShareRoot)
~~~

### New-LiteDeployAdminPackage

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $true)][string]$ShareRoot,
        [Parameter(Mandatory = $true)][string]$PackageId,
        [string]$Name = "",
        [string]$PackageType = "Script"
    )
~~~
