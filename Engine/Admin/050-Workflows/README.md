# Admin.Workflows

**ComponentId:** `Admin.Workflows`  
**Dev:** `Admin/050-Workflows`  
**Published:** `Engine\Scripts\Admin\LiteDeploy.Admin.Workflows.ps1`

Workflow definition helpers under `WorkFlows\` on the share.

<!-- component-contract -->
## Usage and contract

Inspect workflow files and basic authoring checks.

**Source:** [LiteDeploy.Admin.Workflows.ps1](LiteDeploy.Admin.Workflows.ps1).

### Requirements and environment

Full Windows authoring host and ShareRoot/workflow JSON. Runtime.Workflow provides deeper validation.

### What runs and changes

Import defines helpers; standalone prints report, without root prints metadata. Reads definitions without running actions.

### Results and failures

Returns Passed, Count, Errors, Workflows. Shallow checks; malformed definitions may be skipped. Passed/empty list does not prove a runnable deployment.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| ShareRoot | String | <code>""</code> | [Parameter(Mandatory = $false)] |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
$component = '.\Engine\Scripts\Admin\050-Workflows\LiteDeploy.Admin.Workflows.ps1'
. $component
Test-LiteDeployAdminWorkflows -ShareRoot 'C:\LiteDeploy-Staging'
~~~

### Get-LiteDeployAdminWorkflows

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param([Parameter(Mandatory = $true)][string]$ShareRoot)
~~~

### Test-LiteDeployAdminWorkflows

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param([Parameter(Mandatory = $true)][string]$ShareRoot)
~~~
