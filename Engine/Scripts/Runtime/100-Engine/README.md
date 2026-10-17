# Engine

ComputerSetup.DriveSelection=false explicitly selects Disk 0. True (or an absent policy)
requires the disk number from WorkflowSelection. The screen requires Disk 0 to be present
and have usable capacity in fixed-disk mode; it never substitutes the first enumerated disk.
Engine applies the same policy and records the resolved target in the selection result.

Engine owns the execution order and required component **names**. Environment owns path
normalization and maps those names to exact files (`Get-LiteDeployRuntimePaths` /
RequiredFiles). Engine must not guess alternate roots when a required file is missing.
The `REQUIREMENTS BY ENVIRONMENT` block near the top declares **Shared**, **WinPE**, and
**FullOS** component names.

| List | Components |
| --- | --- |
| Shared | Environment, BootConfig, Logs, State |
| WinPE | HostShell, Hardware, Drivers, HardwarePrecheck, WorkflowSelection, DriverPicker, their XAML views, Progress, Disk, Image |
| FullOS | Shared + Hardware, Packages, HostShell; Progress optional for interactive sessions |

`$EngineRequirements.FullOSImplemented` is **true**. WinPE still uses `-BootObject`. FullOS first
entry is **HKLM Run** (`LiteDeployFullOS`), staged in unattend **specialize** when the workflow
has actions (not `auditUser`). Interactive session = Audit Admin (Standard) or AutoLogon
(Domain Join; temporary `EnableLUA=0` when no Audit marker). FullOS may re-arm the same Run key
for mid-deploy reboots, kills `sysprep.exe` (stock Setup CmdLine left intact), restores UAC on
cleanup when bypassed, and starts Interactive Probe in a second window. On direct
execution, before resume, FullOS sets `HKCU\Console\%%Startup` `DelegationConsole` and
`DelegationTerminal` to `{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}` so consoles started after
that (including the probe) hand off to Windows Terminal. The already-open FullOS window
is unchanged. A registry failure does not stop resume. Engine `-ResumeFullOS`
remains for compat. `-ValidateOnly` checks the WinPE profile (`ValidationProfile = WinPE`) and
still returns `RequirementsByEnvironment` for inspection.

Scheduled-task registration in FullOS is **gated off** for now.

Read [Understand and control Engine](../../../../_Docs/guides/ENGINE_READING_GUIDE.md) for variables,
component inputs/results, the execution sequence, and safe inspection examples.

## Source and publish

- Development: `Runtime/100-Engine/LiteDeploy.Engine.ps1` (preload Environment with `-Mode Development`).
- Published: `Engine\Scripts\Runtime\LiteDeploy.Engine.ps1` (Environment defaults to `-Mode Production`).
- **BootInitializer compat:** Admin.Build also writes `LiteDeploy.DeploymentEngine.ps1` as a **byte-identical copy** of Engine. Legacy WinPE BootInitializer still launches that name; it must never lag behind Engine on the live share (`C:\DeploymentShare`).
- Flat repo `Runtime\LiteDeploy.DeploymentEngine.ps1` (if present) is not a second source — keep it equal to Engine or rely on Admin.Build on the share only.
- Boot supplies the source context; Environment owns the selected layout. Engine does not search alternate roots.

## Startup

Before UI or disk changes, Engine asks Image to validate `ComputerSetup.ImageEngine`
(`setup.exe` or `dism.exe`; unknown/blank values stop startup). ValidateOnly includes
the resolved ImageEngine in its returned plan.

`Startup.SkipHardwarePreCheck` can skip Phase 1 UI.HardwarePrecheck. Setup hardware-requirement
bypasses are **not** Engine Startup flags — they live under
`ComputerSetup.SkipSetupHardwareRequirements` and are applied by Image immediately before
`setup.exe` (see Image README).

1. Require BootObject and, for normal execution/import, Windows PowerShell 5.1 in STA mode.
2. Reuse Environment, or load the adjacent published Environment. Build `$RuntimePaths` and `$RequiredFiles` once.
3. Check every required file. Report all missing names/paths together and stop.
4. Use Boot's config object or read the declared config file once.
5. With `-ValidateOnly`, return paths and phase names, then stop.
6. Load Logs, Hardware, State, Drivers, and HostShell once at script scope.

Disk and Image are executed later, not imported here. The Workflow and Packages domain
APIs are not currently called by this pipeline and are not imported.

## Run modes

```powershell
# Inspect the published runtime from an existing Boot session, without deploying.
$plan = & '.\LiteDeploy.Engine.ps1' -BootObject $global:LiteDeployBootObject -ValidateOnly
$plan.RequiredFiles | Format-List

# Load helpers only in the same STA session.
. '.\LiteDeploy.Engine.ps1' -BootObject $global:LiteDeployBootObject

# Execute WinPE deployment. This eventually wipes the explicitly selected target disk.
& '.\LiteDeploy.Engine.ps1' -BootObject $global:LiteDeployBootObject

# FullOS resume (compat path; primary entry is HKLM Run → FullOS.ps1) — no BootObject.
& '.\LiteDeploy.Engine.ps1' -ResumeFullOS -LocalRootName '~LiteDeploy' -OsDriveLetter $env:SystemDrive
```

For a source checkout, load Environment with -Mode Development before running Engine. An explicit -RuntimeRoot belongs to Environment, not Engine. Missing files never change the selected layout.
`-SkipPreCheck` is not a preview mode. Normal execution never relaunches another PowerShell
process to recover STA, because doing so would lose in-memory inputs.

## Pipeline

**WinPE:** HardwarePrecheck → WorkflowSelection → Progress → Disk → Image → handoff
(stage Runtime/Tools → WinPECT export → reboot).

**FullOS (HKLM Run → `LiteDeploy.FullOS.ps1` at interactive logon):** console-host handoff (`HKCU\Console\%%Startup` DelegationConsole / DelegationTerminal) → state → kill sysprep.exe → WinPECT in-memory secret decryption → `New-SmbMapping` Z: reconnect → log mirror → re-arm `HKLM\...\Run\LiteDeployFullOS` (reboot survival) → start Interactive Probe in a second window. Packages and real Progress dispatch are next. First arm of Run is unattend specialize (`reg add` / `REG_EXPAND_SZ`), not FullOS. The console key applies to consoles created after it is written.

Read the numbered phase comments in `Start-LiteDeployPipeline` / `Start-LiteDeployFullOSResume`.
Precheck and selection require an explicit boolean Passed result. Selection must supply a
non-negative integer TargetDiskIndex; absent/malformed input never means Disk 0.
Disk receives `-ConfirmDestroy`; Image receives `-ExecuteSetup`. These are real operations.

Progress is a separate display process in WinPE. Its failure is logged, but Disk/Image may continue.
Read-only media can reject deployment-log writes; local logs remain at the path in RuntimePaths.
Credential paths: `Content\Credentials\` — see [_Docs/integrations/Credentials](../../../../_Docs/integrations/Credentials/README.md).

## Limits and troubleshooting

- Missing files: correct the named file or selected layout; publish the complete runtime.
- Missing configuration: correct BootObject.ConfigPath; there is no alternate-file search.
- STA error: start Boot/Engine in `powershell.exe -NoProfile -STA`.
- UI failure: validate the actual WinPE image; see [maintenance](../../../../_Docs/guides/MAINTENANCE.md).
- WinPE finishes at OS install + handoff. FullOS resume (credentials, Z:, HKLM Run) is implemented;
  package orchestration and interactive Progress dispatch remain open.

<!-- component-contract -->
## Usage and contract

Sequence verification, imports, readiness, selection, progress, disk, image and handoff.

**Source:** [LiteDeploy.Engine.ps1](LiteDeploy.Engine.ps1).

### Requirements and environment

WinPE: BootObject, configured Environment, required files, PowerShell 5.1 STA. FullOS: HKLM Run → `LiteDeploy.FullOS.ps1` as the interactive logged-on admin (Audit or AutoLogon) with staged Runtime on the OS volume.

### What runs and changes

ValidateOnly returns a WinPE plan without deployment. Import loads helpers without pipeline. Normal WinPE execution shows UI, writes state/logs, starts Progress, formats target disk and runs Setup, then stages FullOS payload + WinPECT. `-ResumeFullOS` imports credentials and reconnects the share when Network. SkipPreCheck is not a dry run.

### Results and failures

ValidateOnly returns Mode, RequiredFiles, environment requirements and phases. Pipeline state records failure/cancellation/completion. WinPE Completed means imaging + handoff, not FullOS packages. BootObject is required for WinPE import/validation; FullOS uses DeploymentState.json instead.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| BootObject | PSObject | <code>$null</code> | WinPE; required unless ResumeFullOS |
| ResumeFullOS | SwitchParameter | <code>$false</code> | FullOS compat entry (primary: HKLM Run → FullOS.ps1) |
| LocalRootName | String | <code>~LiteDeploy</code> | FullOS / handoff |
| OsDriveLetter | String | <code>$env:SystemDrive</code> | FullOS / handoff |
| StatePath | String | <code>''</code> | Optional override for DeploymentState.json |
| SkipPreCheck | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |
| ValidateOnly | SwitchParameter | <code>$false</code> |  |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
. '.\Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
$component = '.\Engine\Scripts\Runtime\100-Engine\LiteDeploy.Engine.ps1'
$plan = & $component -BootObject $global:LiteDeployBootObject -ValidateOnly
$plan.RequiredFiles | Format-List
~~~

### Start-LiteDeployPipeline

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
# No parameters.
~~~

## FullOS (`LiteDeploy.FullOS.ps1`)

**ComponentId:** `FullOS`  
**Published:** `Engine\Scripts\Runtime\LiteDeploy.FullOS.ps1`  
**Primary entry:** `HKLM\...\Run\LiteDeployFullOS` (specialize-staged when workflow actions > 0). Engine `-ResumeFullOS` remains a compat entry.

### Purpose

Interactive Session 1 resume after imaging: on direct execution, set `HKCU\Console\%%Startup` `DelegationConsole` and `DelegationTerminal` to `{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}` (Windows Terminal handoff for consoles started afterward; the current window stays as launched), then load DeploymentState, kill `sysprep.exe` (stock Setup CmdLine left intact), WinPECT in-memory unseal, native `Z:` reconnect, log mirror, re-arm HKLM Run for mid-deploy reboots, temporary Interactive Probe window. A failed console-host write is ignored. Package loop and real Progress dispatch are not fully wired yet. Domain Join path may restore `EnableLUA` when `UacBypassed` was set in specialize.

### Dependencies

Environment, Logs, State, Hardware, Packages (from staged Runtime on the OS volume).

### Script parameters

| Parameter | Type | Default | Notes |
| --- | --- | --- | --- |
| LocalRootName | String | `~LiteDeploy` | Folder name under OS drive |
| OsDriveLetter | String | `$env:SystemDrive` | Target OS volume |
| StatePath | String | `''` | Optional override for `DeploymentState.json` |
| ResumeFullOS | Switch | false | Compat / explicit resume path |
| ForceDirect | Switch | false | Bypass some guards when debugging |
| Metadata | Switch | false | Return metadata only |

### Example

~~~powershell
# Typical live path: launched by HKLM Run after interactive logon (no manual args).
# Compat / lab:
& '.\Engine\Scripts\Runtime\100-Engine\LiteDeploy.FullOS.ps1' -ResumeFullOS -LocalRootName '~LiteDeploy'
~~~

## Interactive Probe (`LiteDeploy.FullOS.InteractiveProbe.ps1`)

**Temporary** second-window monitor started by FullOS until real Progress owns Session 1.

- No `-Metadata` / contract param block (inventory scanner skips `*InteractiveProbe*`).
- Single-instance mutex `Global\LiteDeploy_InteractiveProbe_Mutex`.
- Reads `~\LiteDeploy\DeploymentState.json`, writes `WorkLogs\LiteDeploy.InteractiveProbe.log`.
- Not a package runner and not the production Progress UI.

## Deployment ID and log-folder timing

HardwarePreCheck uses local startup logs and provisional state with an empty DeploymentUid. Immediately before launching WorkflowSelection, Engine generates one deployment ID and passes it to the screen. Cancellation, exceptions, or an invalid target do not create a deployment share log folder.

After WorkflowSelection returns boolean Passed=true and its disk target is validated, Engine creates WorkLogs\Deployments\<DeploymentUid> on the deployment source, copies the existing local logs, and records the remote log/state paths. Subsequent logs and state can then mirror there. If the share is unavailable, local logging continues with a warning.

Sequence: local startup/pre-check -> assign ID -> WorkflowSelection -> validate confirmation/target -> create deployment log folder -> disk preparation.

## Current behavior and agreed follow-up

See [the detailed guide](../../../../_Docs/guides/LOGGING_AND_FAILURE_DESIGN.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.

## Effective configuration after selection (implemented)

WorkflowSelection returns its current BootConfig object in memory, including F5 reloads. After Passed=true, Engine requires that object, adopts it for subsequent phases and BootObject.Config in deployment state, and revalidates ImageEngine before disk preparation. It does not reread the configuration file. Selection JSON and nested SelectionData omit the duplicate BootConfig; state retains its existing BootObject.Config serialization behavior.

DriveSelection=false resolves Disk 0 and requires the confirmed TargetDiskIndex to be 0. Otherwise Engine uses the confirmed nonnegative disk number. Missing returned configuration, invalid target, or a policy/confirmation mismatch stops before deployment-folder creation and disk preparation. The technician must reopen selection and confirm again; Engine never silently substitutes a different disk.

This resolves the previously reported F5/stale-policy target mismatch. Automated checks cover both policy-change directions, disagreement, missing configuration, cancellation and the in-memory/JSON result contract. Real WinPE imaging remains unverified. Other release blockers remain open.
