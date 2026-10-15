# Admin.Validation

**ComponentId:** `Admin.Validation`  
**Dev:** `Admin/070-Validation`  
**Published:** `Engine\Scripts\Admin\LiteDeploy.Admin.Validation.ps1`

Share / content validation helpers before production use.

<!-- component-contract -->
## Usage and contract

Check share configuration, content, images, drivers, packages and workflows.

**Source:** [LiteDeploy.Admin.Validation.ps1](LiteDeploy.Admin.Validation.ps1).

### Requirements and environment

Full Windows authoring host, ShareRoot and readable files. No WinPE boot/install test.

### What runs and changes

Import defines helpers; standalone prints report or usage if no root. Reads files and prints status.

### Results and failures

Returns Passed, Results category booleans, ShareRoot. Passing shallow checks does not prove payloads, credentials, WPF or hardware compatibility.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| ShareRoot | String | <code>""</code> | [Parameter(Mandatory = $false)] |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
$component = '.\Engine\Scripts\Admin\070-Validation\LiteDeploy.Admin.Validation.ps1'
. $component
$report = Test-LiteDeployEnvironment -ShareRoot 'C:\LiteDeploy-Staging'
$report.Results | Format-List
~~~

### Test-LiteDeployEnvironment

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param([string]$ShareRoot)
~~~
