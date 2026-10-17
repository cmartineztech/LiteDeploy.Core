# UI.WorkflowSelection

ComputerSetup.DriveSelection=false hides the picker and targets Disk 0 only. If Disk 0 is
missing or has no usable capacity, confirmation is blocked. True uses the selected row.

The folder browser has a separate [DriverPicker contract](DRIVER_PICKER.md).

**ComponentId:** `UI.WorkflowSelection`  
**Dev:** `110-UI/WorkflowSelection`  
**Published:** `Engine\Scripts\Runtime\UI\LiteDeploy.UI.WorkflowSelection.ps1` (+ `.xaml`, DriverPicker)

Phase 2 technician wizard (identity, workflow, disk, drivers). Theme follows Engine / `BootConfig.Ui.Theme`. Diagram: `Docs/SELECTWORKFLOW_DIAGRAM.md`.

The tree parent is the workflow name. Each child title comes from Workflow: `editionName`, with ` (version)` added only when that name does not already contain the version text. The subtitle is `Imported: <date> | Leng: <lang> | Build <build>`.

Workflow `computerSetup` (and returned BootConfig) may carry `ImageEngine` and
`SkipSetupHardwareRequirements`; Image applies those during Phase 4. This screen does not
write LabConfig registry keys.

Engine passes the verified RuntimeFiles map. For standalone use, start Windows PowerShell 5.1 with -STA and load Environment with the correct mode first. The screen then uses named paths and reuses loaded backend helpers.

<!-- component-contract -->
## Usage and contract

Collect confirmed computer, OS/workflow, disk and driver choices.

**Source:** [LiteDeploy.UI.WorkflowSelection.ps1](LiteDeploy.UI.WorkflowSelection.ps1).

### Requirements and environment

PowerShell 5.1 STA, WPF, config/source, Logs/Hardware/Drivers, screen/picker views and DriverPicker. RuntimeFiles comes from Engine or preloaded Environment.

### What runs and changes

Opens wizard, reads catalogs/hardware, writes WorkflowSelection.json on system drive after confirmation. F5 reloads config; picker imports once. No disk format or driver install.

### Results and failures

Returns Passed, Status, ComputerName, WorkflowName/Tag, TargetDiskIndex, DriverFolderPath, SelectionJsonPath. Cancel returns false; save failure returns SaveFailed. Engine validates target index. Initialization can throw.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| BootConfigPath | String | <code>""</code> | [Parameter(Mandatory = $false)] |
| BootConfig | PSObject | <code>$null</code> |  |
| RuntimeFiles | PSObject | <code>$null</code> |  |
| DeploymentSharePath | String | <code>""</code> | [Parameter(Mandatory = $false)] [Alias("Root", "DeploymentRoot")] |
| DeploymentUid | String | <code>""</code> | [Alias("DeploymentId", "DeployUid")] |
| Theme | String | <code>"Light"</code> | [ValidateSet("Light", "Dark")] |
| GetComponentMetadata | SwitchParameter | <code>$false</code> | [Alias("Metadata")] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
. '.\Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
$component = '.\Engine\Scripts\Runtime\110-UI\WorkflowSelection\LiteDeploy.UI.WorkflowSelection.ps1'
$selection = & $component -BootConfigPath 'C:\LiteDeploy-Staging\Config\BootConfig.json' -DeploymentSharePath 'C:\LiteDeploy-Staging'
$selection | Select-Object Passed, Status, TargetDiskIndex
~~~

## Current behavior and agreed follow-up

See [the detailed guide](../../../../../_Docs/guides/DRIVER_HANDLING.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.

## Effective configuration after selection (implemented)

WorkflowSelection returns its current BootConfig object in memory, including F5 reloads. After Passed=true, Engine requires that object, adopts it for subsequent phases and BootObject.Config in deployment state, and revalidates ImageEngine before disk preparation. It does not reread the configuration file. Selection JSON and nested SelectionData omit the duplicate BootConfig; state retains its existing BootObject.Config serialization behavior.

DriveSelection=false resolves Disk 0 and requires the confirmed TargetDiskIndex to be 0. Otherwise Engine uses the confirmed nonnegative disk number. Missing returned configuration, invalid target, or a policy/confirmation mismatch stops before deployment-folder creation and disk preparation. The technician must reopen selection and confirm again; Engine never silently substitutes a different disk.

This resolves the previously reported F5/stale-policy target mismatch. Automated checks cover both policy-change directions, disagreement, missing configuration, cancellation and the in-memory/JSON result contract. Real WinPE imaging remains unverified. Other release blockers remain open.
