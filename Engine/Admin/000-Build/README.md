# Admin.Build

**ComponentId:** `Admin.Build`  
**Dev folder:** `Admin/000-Build` (repo organization only)  
**Published:** `Engine\Scripts\Admin\LiteDeploy.Admin.Build.ps1`

## Purpose

Publishes from numbered **dev** folders into the share layout:

```text
Engine\Scripts\Runtime\          # flat LiteDeploy.Boot / Logs / … / Engine.ps1
Engine\Scripts\Runtime\
  LiteDeploy.DeploymentEngine.ps1   # byte-identical BootInitializer alias
Engine\Scripts\Runtime\UI\       # LiteDeploy.UI.* + .xaml
Engine\Scripts\Admin\            # flat LiteDeploy.Admin.*
Engine\Scripts\Admin\UI\         # LiteDeploy.Admin.UI.*
Engine\Tools\                    # from repo Engine\Tools\ (WinPECT, …)
```

Numbered folders (`000-Boot`, `110-UI`, …) stay in the git repo only. Edit tools under repo `Engine\Tools\`, not only on the share. Always target the **live** lab share path (e.g. `C:\DeploymentShare`) — never hardcode a personal profile path in docs or config samples.

## Usage

```powershell
.\LiteDeploy.Admin.Build.ps1 -DeploymentShare "C:\DeploymentShare"
.\LiteDeploy.Admin.Build.ps1 -WinPEStagingPath "C:\WinPE\Mount"
.\LiteDeploy.Admin.Build.ps1 -MediaRoot "D:\LiteDeployMedia"
```

## WinPE bootstrap map

| Source | Injected as |
| :--- | :--- |
| `LiteDeploy.Boot.ps1` | `~\LiteDeploy\Boot\LiteDeploy.Boot.ps1` |
| `LiteDeploy.Logs.ps1` | `~\LiteDeploy\Runtime\LiteDeploy.Logs.ps1` |
| `LiteDeploy.Environment.ps1` | `~\LiteDeploy\Runtime\LiteDeploy.Environment.ps1` |
| `LiteDeploy.Hardware.ps1` | `~\LiteDeploy\Runtime\LiteDeploy.Hardware.ps1` |

<!-- component-contract -->
## Usage and contract

Publish source components and stage minimal bootstrap.

**Source:** [LiteDeploy.Admin.Build.ps1](LiteDeploy.Admin.Build.ps1).

### Requirements and environment

Full Windows authoring host, source checkout and writable destinations. Actual boot.wim/ISO building is separate.

### What runs and changes

Synchronizes immediately, even when dot-sourced. Clean removes destination scripts; Overwrite controls replacing. Choose DeploymentShare/MediaRoot/WinPEStagingPath.

### Results and failures

Console status, not structured deployment result. Bootstrap has Boot/Logs/Environment/Hardware. Copy success does not validate bootability; source/I/O errors can stop publishing.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| DeploymentShare | String | <code>""</code> | [Parameter(Mandatory = $false)] |
| WinPEStagingPath | String | <code>""</code> | [Parameter(Mandatory = $false)] |
| WinPEInjectionPath | String | <code>"~LiteDeploy"</code> | [Parameter(Mandatory = $false)] |
| MediaRoot | String | <code>""</code> | [Parameter(Mandatory = $false)] |
| Clean | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |
| Overwrite | Boolean | <code>$true</code> | [Parameter(Mandatory = $false)] |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
$component = '.\Engine\Scripts\Admin\000-Build\LiteDeploy.Admin.Build.ps1'
& $component -DeploymentShare 'C:\LiteDeploy-Staging'
~~~

## Current behavior and agreed follow-up

See [the detailed guide](../../../../_Docs/guides/WINPE_BOOTSTRAP.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.
