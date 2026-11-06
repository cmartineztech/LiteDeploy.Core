# Admin.Config

**ComponentId:** `Admin.Config`  
**Dev:** `Admin/060-Config`  
**Published:** `Engine\Scripts\Admin\LiteDeploy.Admin.Config.ps1`

Generates `BootConfig.json` for BootWim / DeploymentShare / Media modes.

## Generated BootConfig sections (DeploymentShare / Media)

| Section | Notable keys | Notes |
| --- | --- | --- |
| `Startup` | `SkipHardwarePreCheck` | When `true`, skips UI.HardwarePrecheck. **Do not** emit removed `SkipHardwareRequirments` |
| `ComputerSetup` | `ImageEngine`, `SkipSetupHardwareRequirements`, prompts, locales, registration | `SkipSetupHardwareRequirements` defaults `false`; Setup.exe-only LabConfig/MoSetup bypass (Image owns apply) |
| `Drivers` | `AutoDetectDrivers`, `AllowManualSelection`, `AutoOnlineDownloadOnMedia` | Driver policy for WorkflowSelection |
| `Ui` | `Theme` | `Light` \| `Dark` |

BootWim mode emits a minimal config (Metadata + Deployment only).

## Ui.Theme

Optional `Ui.Theme` = `Light` | `Dark` (default Light). Engine and all Runtime UI hosts consume this so Precheck, WorkflowSelection, and Progress stay visually consistent.

<!-- component-contract -->
## Usage and contract

Generate BootConfig.json for boot/share/media.

**Source:** [LiteDeploy.Admin.Config.ps1](LiteDeploy.Admin.Config.ps1).

### Requirements and environment

Full Windows authoring host and writable OutputPath. NetworkPath is required at runtime for BootWim and DeploymentShare modes even though its parameter attribute is optional. BootWim/DeploymentShare/Media Mode is separate from Environment mode.

### What runs and changes

Writes config even when dot-sourced. Set OutputPath explicitly; existing file can be replaced. Review generated policies.

### Results and failures

Returns resolved filename. Validation/I/O failures stop generation. Generated config does not prove connectivity. Metadata avoids writes.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| BootConfig | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |
| Mode | String | <code>'DeploymentShare'</code> | [Parameter(Mandatory = $false, Position = 0)] [ValidateSet('BootWim', 'DeploymentShare', 'Media')] |
| NetworkPath | String | <code>""</code> | [Parameter(Mandatory = $false)] |
| Environment | String | <code>$null</code> | [Parameter(Mandatory = $false)] [AllowNull()] |
| Comment | String | <code>""</code> | [Parameter(Mandatory = $false)] |
| RegisteredOrganization | String | <code>""</code> | [Parameter(Mandatory = $false)] |
| RegisteredOwner | String | <code>""</code> | [Parameter(Mandatory = $false)] |
| OutputPath | String | <code>(not supplied)</code> | [Parameter(Mandatory = $false)] |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
$component = '.\Engine\Scripts\Admin\060-Config\LiteDeploy.Admin.Config.ps1'
& $component -BootConfig -Mode DeploymentShare -NetworkPath '\\Server01\DeploymentShare$' -OutputPath 'C:\LiteDeploy-Staging\Config\BootConfig.json'
~~~
