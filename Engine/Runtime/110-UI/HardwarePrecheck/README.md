# UI.HardwarePrecheck

**ComponentId:** `UI.HardwarePrecheck`  
**Dev:** `110-UI/HardwarePrecheck`  
**Published:** `Engine\Scripts\Runtime\UI\LiteDeploy.UI.HardwarePrecheck.ps1` (+ `.xaml`)

Phase 1 readiness UI. Theme: `-Theme` or `BootConfig.Ui.Theme` (default Light). Diagram: `Docs/PRECHECK_DIAGRAM.md`.

The header badge matches Workflow Selection: a 40×40 `#28FFFFFF` square. It shows **LD** unless `Config\logo.png` sits next to BootConfig.

Engine passes the verified RuntimeFiles map. For standalone use, start Windows PowerShell 5.1 with -STA and load Environment with the correct mode first. The screen then uses named paths and reuses loaded backend helpers.

### BootConfig.Startup

| Key | Effect |
| --- | --- |
| `SkipHardwarePreCheck` | When `true` (also accepts legacy `SkipPreCheck`), the screen bypasses the readiness gate and can still gather inventory |

This is **not** `ComputerSetup.SkipSetupHardwareRequirements` (that flag is owned by Image for Setup.exe LabConfig/MoSetup bypasses).

<!-- component-contract -->
## Usage and contract

Display readiness checks and return an explicit result.

**Source:** [LiteDeploy.UI.HardwarePrecheck.ps1](LiteDeploy.UI.HardwarePrecheck.ps1).

### Requirements and environment

PowerShell 5.1 STA, WPF, Hardware, BootConfigPath and named XAML. Engine supplies RuntimeFiles; standalone preloads Environment. Validate actual WinPE WPF.

### What runs and changes

Opens modal UI and reads hardware/network. F5 reloads the config file. Open CMD launches a process. Legacy non-STA relaunch loses in-memory context: start in STA.

### Results and failures

Returns Passed/Inventory; null is not passed. Policy bypass can still gather inventory. UI initialization may throw. Failed/cancelled readiness stops Engine.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| BootConfigPath | String | <code>""</code> | [Parameter(Mandatory = $false)] |
| BootConfig | PSObject | <code>$null</code> |  |
| RuntimeFiles | PSObject | <code>$null</code> |  |
| DeploymentShare | String | <code>""</code> |  |
| MaxNetworkWaitSeconds | Int32 | <code>30</code> |  |
| NetworkPollMilliseconds | Int32 | <code>500</code> |  |
| SmbConnectTimeoutMilliseconds | Int32 | <code>2000</code> |  |
| MinDiskSizeGB | Int32 | <code>32</code> |  |
| MinMemoryGB | Int32 | <code>4</code> |  |
| HaltOnFailure | Boolean | <code>$true</code> |  |
| Theme | String | <code>"Light"</code> | [ValidateSet("Light", "Dark")] |
| TopMost | String | <code>"On"</code> | [ValidateSet("On", "Off")] |
| GetComponentMetadata | SwitchParameter | <code>$false</code> | [Alias("Metadata")] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
. '.\Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
$component = '.\Engine\Scripts\Runtime\110-UI\HardwarePrecheck\LiteDeploy.UI.HardwarePrecheck.ps1'
$result = & $component -BootConfigPath 'C:\LiteDeploy-Staging\Config\BootConfig.json'
$result.Passed
~~~

## Current behavior and agreed follow-up

See [the detailed guide](../../../../../_Docs/guides/LOGGING_AND_FAILURE_DESIGN.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.
