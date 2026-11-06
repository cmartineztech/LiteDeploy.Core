# Admin.Utilities

**ComponentId:** `Admin.Utilities`  
**Dev:** `Admin/080-Utilities`  
**Published:** `Engine\Scripts\Admin\LiteDeploy.Admin.Utilities.ps1`

Shared admin utility helpers.

<!-- component-contract -->
## Usage and contract

Hash/JSON checks, backups, safe names and content copies.

**Source:** [LiteDeploy.Admin.Utilities.ps1](LiteDeploy.Admin.Utilities.ps1).

### Requirements and environment

Full Windows authoring host and path access. No deployment session needed.

### What runs and changes

Import loads helpers, direct execution prints metadata. Checks read; Backup writes timestamped copy; Copy creates parents and recursively copies with optional Force replacement.

### Results and failures

Backup returns path, Copy returns destination, safe-name returns string. Missing source/permission errors throw; no rollback of partial copy.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
$component = '.\Engine\Scripts\Admin\080-Utilities\LiteDeploy.Admin.Utilities.ps1'
. $component
Test-LiteDeployJson -Path 'C:\LiteDeploy-Staging\Config\BootConfig.json'
~~~

### Get-LiteDeployFileHash

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet("SHA256", "SHA1", "MD5")][string]$Algorithm = "SHA256"
    )
~~~

### Test-LiteDeployJson

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param([Parameter(Mandatory = $true)][string]$Path)
~~~

### Backup-LiteDeployConfig

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$BackupDirectory = ""
    )
~~~

### Copy-LiteDeployAdminContent

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Force
    )
~~~
