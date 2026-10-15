# LiteDeploy Core simplification review

Reviewed October 13, 2026 against the current working tree, including untracked source.

**Currency (2026-10-15):** Flat editable `Engine/Scripts` mirrors were removed and gitignored;
architecture suite moved to `_Tests\`; component templates/inventory moved to `_Templates\`.
Latest architecture smoke with DeploymentShare Runtime: **155 / 155**. Historical counts and
“divergent flat copy” findings below describe the tree as of the review date.

## Verdict

The core architecture is appropriate for a Windows deployment tool. It is not fundamentally over-engineered. Bootstrapping WinPE, selecting an explicit disk, installing Windows, transferring credentials, and continuing after reboot justify separate components and careful state handling.

There is avoidable complexity in duplicated source layouts, UI/domain overlap, implicit PowerShell scope, and legacy/experimental execution paths. Simplify those incrementally; a rewrite or a generic deployment framework would add risk without solving the main problems.

The numbered source folders contain 29 product PowerShell scripts totaling approximately 24,138 physical lines, including comments and whitespace, plus a 277-line Progress test script. Size alone is not evidence of over-engineering. Some functions are difficult to maintain because they combine several phases or responsibilities.

## Scope and verification

Inspection covered the first-party Runtime and Admin component inventory, entry points and imports, build/publish behavior, state/log handling, workflow selection, disk/image boundaries, driver staging, FullOS resume, templates, credential integration, documentation, and the existing architecture test suite. Experimental implementations were sampled, including BunWinPeSuite and FastWorkflowSelection. Bundled third-party OSD/DriverAutomationTool source, downloaded driver payloads, and binaries were not audited line by line.

CodeGraph was checked first as required. Lazy initialization failed, and `codegraph status` reported a missing installed `npm-shim.js`. Direct source and PowerShell AST inspection were used afterward. No CodeGraph lifecycle administration was attempted.

Windows PowerShell 5.1 architecture checks passed **186/186** with an absolute PublishedRuntimeRoot pointing to DeploymentShare. An initial invocation used a relative published root and failed two checks because the runtime deliberately requires absolute paths; correcting the invocation resolved both failures.

Separate temporary fixtures reproduced malformed-JSON validation and overwrite behavior. Application code and existing configuration were not edited. No actual disk wipe, Windows installation, live share configuration, credential transfer, package installation, or reboot was performed. Passing smoke checks does not establish end-to-end deployment compatibility.

## Findings and recommended changes

### 1. Establish one editable source and generated publish outputs — highest cleanup value

Many components exist in numbered source folders, flat Engine/Scripts folders, and DeploymentShare. Comparing text after normalizing line endings found **10 divergent copies**: nine flat Engine copies (Boot, Disk, Drivers, Workflow, HostShell, and the HardwarePrecheck/WorkflowSelection scripts and XAML) and the published DeploymentShare Engine.

Admin.Build discovers numbered sources at `Engine/Scripts/Admin/000-Build/LiteDeploy.Admin.Build.ps1:180`. The flat Engine copies are excluded by that discovery rule. Editing one of those copies can therefore leave the actual next publish unaffected. The published Engine difference historically concerned SetupComplete; FullOS entry is now specialize-staged HKLM Run → `LiteDeploy.FullOS.ps1` (SetupComplete is not staged; no `auditUser`).

Keep numbered folders as the editable source for the first cleanup. Generate flat deployment output into a clearly identified staging/output folder. Add a publish manifest or content comparison so a tested release can be tied to its source. Before retiring existing flat copies, preserve and compare their differences and inspect external launchers. Do not indiscriminately delete DeploymentShare: it also contains configuration and deployment content.

### 2. Declare Workflow explicitly and remove UI/domain duplication

Engine's WinPE requirements at `Runtime/100-Engine/LiteDeploy.Engine.ps1:95` omit Workflow. Selection receives that requirements object as RuntimeFiles. In `Runtime/110-UI/WorkflowSelection/LiteDeploy.UI.WorkflowSelection.ps1:126`, the UI then falls back to a flat Workflow script beneath DeploymentShare when no Workflow path is supplied. Source execution can consequently combine development UI with published domain code, and Engine validation does not check this dependency.

The UI also redefines domain functions already supplied by Workflow: catalog loading, catalog date text, selection result creation, JSON path determination, JSON serialization, and JSON validation. These implementations are not all interchangeable. For example, the UI result constructor at line 376 includes effective BootConfig, whereas the Workflow constructor at `Runtime/050-Workflow/LiteDeploy.Workflow.ps1:742` has a different parameter/result contract.

Add Workflow to Engine's declared dependencies and resolve it through Environment. Move catalog and selection-contract ownership into Workflow, explicitly passing effective configuration and other context. Remove UI copies only after the shared function preserves the actual UI behavior. Keep tree controls and event handlers in the UI. This needs contract tests for cancellation, BootConfig exclusion from persisted selection, target disk, architecture filtering, and driver choices.

### 3. Consolidate validation that currently reports false success

`Admin/050-Workflows/LiteDeploy.Admin.Workflows.ps1:34` silently catches invalid workflow JSON. Its validator can return Passed=true and Count=0 when the only file is malformed. A temporary fixture reproduced exactly that result.

`Admin/070-Validation/LiteDeploy.Admin.Validation.ps1:44` checks only that BootConfig exists, and its workflow check at line 103 counts files. Both accepted malformed JSON in isolated fixtures. The declared dependency list does not make these functions invoke the actual domain validators.

Use the existing Workflow and Packages parsing/validation functions where their contracts fit. Report each failed file and make invalid input fail validation. Keep a small Admin aggregation function for the overall result. Distinguish optional missing content from corrupt content. This both removes parallel rules and improves behavior; it is a correctness fix rather than a strictly behavior-preserving refactor.

### 4. Repair the publish overwrite contract

Admin.Build exposes `-Overwrite` at line 73, but all publishing copies use unconditional `Copy-Item -Force`, starting at line 297. A scratch destination containing an existing Engine file was overwritten with `-Overwrite $false`.

Implement the documented overwrite choice in one small copy helper, or deliberately retire the option through a compatibility change. For the current public interface, honoring the option is preferable. Keep the separate share, media, and WinPE target layouts; those are real deployment requirements. Test both preservation and replacement against temporary publish directories.

### 5. Shorten the orchestrator while preserving its visible sequence

`Start-LiteDeployPipeline` at `Runtime/100-Engine/LiteDeploy.Engine.ps1:819` spans 598 lines. Boot's configuration/bootstrap function spans 306 lines, and FullOS's resume function spans 306 lines. These mix validation, state mutations, UI/process management, result mapping, logging, and phase execution.

Extract a few cohesive phase functions inside the existing components: precheck/selection, disk execution, selected-driver staging, imaging, and handoff. Keep their order explicit in the main function. A shared failure-state helper can replace repeated failure/error/end-time/save sequences, provided it preserves each cancellation and failure contract.

Do not replace the pipeline with a plugin registry, dependency injection container, or universal task engine. Pass existing RuntimePaths and deployment state explicitly where it reduces reliance on global variables. Retain standalone script interfaces until their callers are migrated.

### 6. Reduce scope coupling and repeated support code selectively

Engine must save and restore BootObject around dot-sourced imports at line 205 because imported parameter blocks share caller scope. Multiple scripts define the same metadata function name. Global settings and command-existence checks can also retain helpers from an earlier import. These are maintenance hazards, even where present tests cover the expected load order.

Prefer explicit context parameters and avoid top-level imported variables that collide with the caller. Standardizing a small import contract is sufficient; converting every script to a module is not a prerequisite.

TCP probing is repeated in Boot, Hardware, Drivers, and Precheck. Extract the socket/timeout/disposal mechanism only; keep SMB readiness and internet availability as distinct policies. Boot already calls Environment's share connection helper at `Runtime/000-Boot/LiteDeploy.Boot.ps1:462`, so the older responsibility audit's claim that these helpers are largely unused is no longer accurate.

Admin Images and Drivers duplicate WPF resource-building helpers. Share common palette/resources while retaining each screen's controls. Progress has separate process/native-host requirements; do not force console and WPF rendering into one implementation.

State and Progress also have separate state-to-display readers. Their phase maps already differ: State names phase 5 FullOS, while Progress calls it PostInstall. A small shared read-only projection/phase contract would reduce drift without importing the entire mutable State component into the Progress process.

### 7. Clarify implemented functionality before pruning FullOS compatibility

`Runtime/100-Engine/LiteDeploy.FullOS.ps1:849` explicitly logs that package orchestration is pending. The function loads Packages and establishes resume infrastructure, but does not call Install-LiteDeployPackage/Invoke-LiteDeployPackage in a package loop. README lines 71 and 122 suggest a package loop and package-reboot behavior that are not implemented by this FullOS path.

Separate the documented status of package execution helpers, scheduled resume infrastructure, and automatic package sequencing. Building the missing sequencing is feature work, not cleanup.

FullOS still has scheduled-task helper functions, but registration is gated off (`$script:LiteDeployFullOSRegisterTasks = $false`). Live entry/resume is `HKLM\...\Run\LiteDeployFullOS` (first arm in unattend specialize; FullOS may re-arm). Stock Setup sysprep CmdLine is left intact; FullOS kills the process. Temporary Interactive Probe runs as a second `Start-Process` window; replace with real Progress when ready.

### 8. Keep compatibility and experiments bounded

Thin public wrappers around Disk/Image/Drivers are not automatically wasteful: they support standalone inspection and explicit destructive-operation gates. Get-LiteDeployComponentMetadata and -Metadata support inventory tooling. Preserve these interfaces unless usage evidence supports removal.

The compatibility DeploymentEngine alias and Engine -ResumeFullOS delegation can eventually become small wrappers after old boot-media callers are accounted for. Remove obsolete examples and version banners alongside that migration.

Experiments contain alternate driver/workflow implementations and third-party reference projects. Keep them out of production discovery and label their status. BunWinPeSuite's ddd.ts and catalogNormalize.ts repeat XML/catalog utilities; consolidate them only if both remain maintained. There is no demonstrated need to unify the experimental Bun runtime and production PowerShell engine.

One small correctness cleanup: `Runtime/080-Image/LiteDeploy.Image.ps1:1184` restarts the DISM stopwatch immediately before stopping it, losing the elapsed imaging duration. Preserve the stopwatch started at line 1079. This was identified statically, not through an actual imaging run.

## Preserve these design decisions

- Disk/Image/Drivers separation and explicit target-disk validation.
- -ConfirmDestroy and -ExecuteSetup execution gates.
- Credential-safe state serialization and in-memory credential handling.
- Persistent JSON for reboot handoff and remote/local log recovery.
- A separate Progress process while blocking deployment operations run.
- Distinct WinPE bootstrap and published-share layouts.
- PowerShell 5.1/WinPE compatibility and explicit development/production path selection.

The RAM memory-map transport is a candidate for later measurement, not an immediate deletion. It adds a second transport, but changing it could alter UI responsiveness and host compatibility. Similarly, log mirrors serve recovery and diagnostics; reducing their count would remove behavior.

## Suggested implementation order

1. Capture a source/publish manifest and preserve divergent copies. Identify one editable source.
2. Add focused regressions for invalid JSON, overwrite=false, and the missing Workflow dependency; fix those defects.
3. Unify Workflow/UI contracts and remove duplicate domain implementations.
4. Extract a few phase functions and reduce scope collisions without changing entry points.
5. Consolidate repeated network and UI support mechanics where the contracts match.
6. Update functionality documentation and retire legacy/probe paths only after compatibility checks.

Run the existing 5.1 architecture suite after each stage. Before declaring behavior preserved, exercise a disposable VM matrix covering Setup and DISM, network and media deployment, cancellation/invalid disk selection, custom/OEM/in-box drivers, credential handoff, FullOS reconnect, and reboot/resume. Package sequencing needs its own tests when implemented.

No reliable percentage reduction can be promised before reconciling copies and interfaces. The expected improvement is fewer independently maintained implementations and clearer execution contracts, rather than an arbitrary smaller line count.
