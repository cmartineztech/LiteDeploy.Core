# Understand and control Engine

The design follows the sequence: **declare -> verify -> load -> run -> check result**.
**Engine declares required component names. Environment normalizes the environment and maps
those names to exact paths.** Domain components and UI hosts consume BootObject / RuntimePaths /
`Resolve-LiteDeployContentPath` — they do not guess sibling folders or invent a second layout
when a file is missing. Each phase returns a result the next phase can use. No generic task
runner or new module framework was added.

An explicit `ComputerSetup.DriveSelection=false` means Disk 0. With true or an absent setting,
Engine requires the WorkflowSelection disk number. Fixed mode never substitutes another disk
when Disk 0 is missing; the screen blocks confirmation.

`ComputerSetup.ImageEngine` supports both `dism.exe` and `setup.exe`. Image owns the sequence switch;
Engine calls its `ValidateEngineOnly` check before any UI or disk changes. An absent setting defaults to `setup.exe` for backwards compatibility.

`ComputerSetup.SkipSetupHardwareRequirements` (default `false`) is Setup.exe-only: when `true`,
Image writes WinPE `LabConfig` / `MoSetup` registry bypasses immediately before launching Setup.
`/Compat IgnoreWarning` is not used (not applicable from WinPE). See
[ComputerSetup mapping](COMPUTER_SETUP_MAPPING.md) and the Image README.

## Where to look

| Question | Location |
| :--- | :--- |
| Which components does each environment require? | Engine: `REQUIREMENTS BY ENVIRONMENT` |
| Where are those files? | Environment: `Get-LiteDeployRuntimePaths` |
| Are any files missing? | Environment: `Test-LiteDeployRequiredFiles` |
| What gets loaded? | Engine: `LOAD SHARED HELPERS ONCE` |
| In what order does deployment run? | Engine: `Start-LiteDeployPipeline` |
| What does a component return? | The contract table below and its component README |
| How is the source found and connected? | Boot; it passes the resulting BootObject to Engine |

Source locations:

- `Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1`
- `Engine\Scripts\Runtime\100-Engine\LiteDeploy.Engine.ps1`

Published share also has `LiteDeploy.DeploymentEngine.ps1` as a **byte-identical** BootInitializer alias of Engine (Admin.Build). Prefer editing `100-Engine\LiteDeploy.Engine.ps1`, then publish to `C:\DeploymentShare`.

## The important variables

| Variable | Meaning |
| :--- | :--- |
| `$EngineRequirements` | Shared, WinPE, FullOS (implemented resume), and optional FullOS component names |
| `$BootObject` | Boot's source, configuration, and in-memory credential context |
| `$RuntimePaths` | Environment's single path plan for this Engine invocation |
| `$RequiredFiles` | Named files from that plan, such as `.Logs`, `.Disk`, `.HardwarePrecheck` |
| `$EngineBootConfig` | Configuration passed by Boot, or read once from the declared file |
| `$deploymentUid` | ID used for this deployment's logs/state |
| `$precheckResult` | Readiness result from HardwarePrecheck |
| `$workflowResult` | Confirmed OS, computer, driver, and target-disk selection |
| `$diskResult` | Prepared partition details, including OSDriveLetter |
| `$imageResult` | OS apply result (DISM or Setup.exe), exit code, answer-file path, and timing |

Load Environment once with `-Mode Development` or `-Mode Production` (default). Its top-level path settings own both layouts. `Get-LiteDeployComponentPath -Name Engine` returns the configured engine location. Published Engine can load adjacent Environment when it has not already been loaded.

## What runs and why

The environment lists near the top of Engine are intentionally simple:

- **Shared:** Environment, BootConfig, Logs, State.
- **WinPE:** Hardware, Drivers, the precheck/selection/picker screens and their views,
  HostShell, Progress, Disk, Image.
- **FullOS:** Shared plus Hardware, Packages, HostShell. Progress is optional for interactive use.

`$EngineRequirements.FullOSImplemented` is **true**. Primary FullOS entry is **HKLM Run**
(`LiteDeployFullOS`), staged in unattend specialize when the workflow has actions; FullOS may
re-arm that key for mid-deploy reboots. There is no `auditUser` FullOS launch. Engine
`-ResumeFullOS` remains a compat path (not `-BootObject`). ValidateOnly still checks the WinPE
pipeline and returns both `ValidationProfile` and `RequirementsByEnvironment` for inspection:

```powershell
$plan.RequirementsByEnvironment | Format-List
```

Environment resolves the names selected by Engine; it never imports them automatically.

| Component | How Engine uses it | Expected result / stop condition |
| :--- | :--- | :--- |
| Environment | Load once; build paths and check requirements | Complete path list; report all missing files and stop |
| Logs | Dot-source once | `Write-LiteDeployLog`; no standalone logging action on import |
| Hardware | Dot-source once | Inventory functions used by the screens |
| State | Dot-source once | Create/save deployment state |
| Drivers | Dot-source once | Driver detection, staging, SHA-256 validation and archive extraction |
| HardwarePrecheck | Execute in the current STA process | Object with boolean `Passed`; Inventory when available. Empty/cancelled results stop |
| WorkflowSelection | Execute in the current STA process | Object with boolean `Passed` and integer `TargetDiskIndex`. Explicit DriveSelection=false resolves Disk 0; otherwise require the selected disk |
| Progress | Explicit separate process | Show state while Disk/Image run; startup failure is logged and deployment can continue without this display |
| Disk | Execute once with `-ConfirmDestroy` | `Success`, disk/partition details, `OSDriveLetter`; failure stops Image |
| Image | Execute once with `-ExecuteSetup` | `Success`, `Engine`, `ExitCode`, `SetupPath`/`ImagePath`, `UnattendPath`, index/timing; failure stops completion |
| Log/state handoff | Copy artifacts to the OS volume | Handoff result; failure is reported as a warning |

Disk and Image are checked at startup but are not imported as helpers. The Workflow domain
component is not loaded because the current selection screen owns its catalog logic. Packages
are not loaded or required because the pipeline has no FullOS package phase. Progress builds
its markup internally, so its unused external XAML/theme files are not runtime requirements.

The two selection screens receive the verified file map and reuse loaded backend functions.
DriverPicker is loaded once per WorkflowSelection screen, not every time Browse is clicked.
Screen F5/Run Again still explicitly reloads configuration; this is a user action, not automatic
path searching. Reopen the screen to load edited picker code.

## Inspect without deploying

From a Boot session on the published share:

```powershell
$plan = & 'Z:\Engine\Scripts\Runtime\LiteDeploy.Engine.ps1' `
    -BootObject $global:LiteDeployBootObject -ValidateOnly
$plan | Select-Object Mode, DeploymentRoot, RuntimeRoot, HelpersToLoad, Phases
$plan.RequiredFiles | Format-List
```

For a source checkout, explicitly select Development. From the repository root in Windows
PowerShell 5.1, this example uses a separate local deployment-share folder:

```powershell
$boot = [pscustomobject]@{
    DeploymentType = 'Network'
    DriveLetter = 'C:\LiteDeploy-Staging'
    ConfigPath = 'C:\LiteDeploy-Staging\Config\BootConfig.json'
}
. '.\Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
$enginePath = Get-LiteDeployComponentPath -Name Engine
$plan = & $enginePath `
    -BootObject $boot -ValidateOnly
$plan.RequiredFiles | Format-List
```

The config file must exist and contain a JSON object. ValidateOnly checks declared files and
configuration, returns the plan, and exits. It does not load deployment helpers, show UI,
start processes, write deployment logs/state, format disks, or certify hardware compatibility.

Executing without ValidateOnly starts the real pipeline. Dot-sourcing without ValidateOnly
loads helpers but does not start the pipeline. Both require an explicit BootObject; normal
execution/import also requires Windows PowerShell `-STA`. Engine never silently relaunches.
`-SkipPreCheck` skips readiness only; it is not a dry run.

## Deliberate boundaries and next improvements

- Boot still owns source discovery and connection, including its existing compatibility paths.
  Engine consumes the result and never assumes a missing source means Z:.
- Standalone Drivers and selection screens require Environment to be loaded first. They reuse loaded helpers and named paths. Admin Drivers UI also uses the named AdminDrivers path.
- Add future dependencies to Engine's environment lists and Environment's path map, then add a visible import or
  phase call and document its inputs/result. Avoid hidden import registries or auto-discovery.
- Logs owns log-copy and OS handoff functions. Engine passes RuntimePaths explicitly. UI.HostShell owns console window controls; importing it does not change the window.
- Offline driver staging and offline DISM servicing are operational. FullOS resume (WinPECT, Z: reconnect, **HKLM Run** specialize-staged / re-armed) is implemented; package execution and interactive Progress dispatch after reboot remain open. See [Credentials](../integrations/Credentials/README.md).

## One layout setting

Environment's top-level `LiteDeployPathSettings` contains `ProductionRuntimePath`,
`ProductionFiles`, and `DevelopmentFolders`. Numbered source folders belong only in this map.
Consumers request names, such as `Get-LiteDeployComponentPath -Name Drivers`.
For a custom staging location, load Environment with an absolute `-RuntimeRoot`.
Missing files stop validation; there is no fallback search through alternate layouts.

Boot normally loads Environment from `$env:SystemDrive\~LiteDeploy\Runtime`.
For source testing, preload Environment with `-Mode Development`, then use its named Boot path.
For a different boot staging folder, pass Boot an explicit `-EnvironmentPath`.

## Component size

Aim for fewer than 1,000 lines per non-UI component. Split by responsibility, never by an
arbitrary line count. Environment now owns configuration and platform helpers; Logs owns
log storage; UI.HostShell owns console presentation; Engine owns execution order.
UI components may stay larger when keeping event handlers and their screen together makes the behavior easier to follow.

## Deployment ID and log-folder timing

HardwarePreCheck uses local startup logs and provisional state with an empty DeploymentUid. Immediately before launching WorkflowSelection, Engine generates one deployment ID and passes it to the screen. Cancellation, exceptions, or an invalid target do not create a deployment share log folder.

After WorkflowSelection returns boolean Passed=true and its disk target is validated, Engine creates WorkLogs\Deployments\<DeploymentUid> on the deployment source, copies the existing local logs, and records the remote log/state paths. Subsequent logs and state can then mirror there. If the share is unavailable, local logging continues with a warning.

Sequence: local startup/pre-check -> assign ID -> WorkflowSelection -> validate confirmation/target -> create deployment log folder -> disk preparation.

## Effective configuration after selection

WorkflowSelection returns its current BootConfig object in memory, including F5 reloads. After Passed=true, Engine requires that object, adopts it for subsequent phases and BootObject.Config in deployment state, and revalidates ImageEngine before disk preparation. It does not reread the configuration file. Selection JSON and nested SelectionData omit the duplicate BootConfig; state retains its existing BootObject.Config serialization behavior.

DriveSelection=false resolves Disk 0 and requires the confirmed TargetDiskIndex to be 0. Otherwise Engine uses the confirmed nonnegative disk number. Missing returned configuration, invalid target, or a policy/confirmation mismatch stops before deployment-folder creation and disk preparation. The technician must reopen selection and confirm again; Engine never silently substitutes a different disk.
