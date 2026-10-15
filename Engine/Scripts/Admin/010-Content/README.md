# Admin.Content

**ComponentId:** `Admin.Content`  
**Dev:** `Admin/010-Content`  
**Published:** `Engine\Scripts\Admin\LiteDeploy.Admin.Content.ps1`

Share layout provisioning and ACL helpers (successor to SetDeploymentShareAcl concerns). Numbered folder is repo organization only.

<!-- component-contract -->
## Usage and contract

Create folders, deployment account, SMB share and ACLs.

**Source:** [LiteDeploy.Admin.Content.ps1](LiteDeploy.Admin.Content.ps1).

### Requirements and environment

Elevated full Windows with account/SMB/NTFS APIs; explicit intended identities and SharePath/ShareName. Not a WinPE phase.

### What runs and changes

Runs setup even when dot-sourced. May prompt, create account, alter existing share/ACLs. AdditionalUsers/ADGroups extend identities. Metadata avoids setup.

### Results and failures

Console summary, no structured success. Failures may follow earlier mutations; verify resulting access. No automatic rollback.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| SharePath | String | <code>"C:\DeploymentShare"</code> | [Parameter(Mandatory = $false)] |
| ShareName | String | <code>"DeploymentShare$"</code> | [Parameter(Mandatory = $false)] |
| LocalUser | String | <code>"deployer"</code> | [Parameter(Mandatory = $false)] |
| AdditionalUsers | String[] | <code>@()</code> | [Parameter(Mandatory = $false)] |
| ADGroups | String[] | <code>@()</code> | [Parameter(Mandatory = $false)] |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
$component = '.\Engine\Scripts\Admin\010-Content\LiteDeploy.Admin.Content.ps1'
& $component -SharePath 'C:\DeploymentShare' -ShareName 'DeploymentShare$' -LocalUser 'deployer' # Changes account/share/ACLs.
~~~
