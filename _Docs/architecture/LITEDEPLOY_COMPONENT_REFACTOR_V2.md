# LiteDeploy Component Architecture v2

**Status:** Active (v2 is the only Runtime/Admin layout in this repo)  
**Date:** 2026-10-07

## Critical rule: folders vs publish

Numbered folders under `Engine\Scripts\Runtime\` and `Engine\Scripts\Admin\` exist **only for development and repository organization**.

| Layer | Path | Purpose |
| :--- | :--- | :--- |
| Dev / git | `Engine\Scripts\Runtime\<NNN-*>\` + `110-UI\` | Repo organization only |
| Dev / git | `Engine\Scripts\Admin\<NNN-*>\` + `090-UI\` | Repo organization only |
| Published | `Engine\Scripts\Runtime\*.ps1` | Flat domain scripts |
| Published | `Engine\Scripts\Runtime\UI\` | Runtime UI |
| Published | `Engine\Scripts\Admin\*.ps1` | Flat Admin tools |
| Published | `Engine\Scripts\Admin\UI\` | Admin UI |
| WinPE inject | `X:\~LiteDeploy\Boot` + `Runtime` | Minimal bootstrap only |

Environment selects one mode when loaded: Production (default) or Development.
Its top-level path settings own production composition and numbered development folders.
Boot resolves Engine through that map; it does not try alternate layouts. Engine receives
the source context from Boot and asks Environment for the selected required component names.

---

## Environment path contract (non-negotiable)

**Environment normalizes the runtime and supplies paths.** Other components consume those
paths; they do not invent alternate layouts, guess sibling folders, or create directory
trees “just in case.”

| Actor | Owns | Must not |
| :--- | :--- | :--- |
| **Environment** | Mode (`Development` / `Production`), named component map, `Get-LiteDeployRuntimePaths`, `Get-LiteDeployComponentPath`, `Resolve-LiteDeployContentPath`, WinPE detection, process helper, theme read | Import every component; invent a second layout when a file is missing; create log/content trees unsolicited |
| **Engine** | Which component **names** are required per environment; phase order; adopting BootConfig | Hardcode `Z:\…\LiteDeploy.*.ps1` paths; search alternate roots when RequiredFiles fails |
| **Boot** | Discover BootConfig, network/media source, mount share, build BootObject, launch Engine | Duplicate Environment’s production/dev file map |
| **Domain components** (Disk, Image, Drivers, Workflow, …) | Domain work using paths already resolved (BootObject / RuntimePaths / `Resolve-LiteDeployContentPath`) | Guess `..\..\DeploymentShare`, invent `Z:\` when ShareRoot omitted in the live pipeline, or recompose Engine script trees |
| **UI hosts** | Presentation; call domain helpers with `DeploymentSharePath` / RuntimeFiles from Engine | Embed a second catalog/path resolver that bypasses Environment |

### Rules

1. **Declare → resolve → verify → use.** Engine declares required **names**. Environment maps
   names to exact files. `Test-LiteDeployRequiredFiles` reports all missing entries. Missing
   files **stop**; they never trigger a layout search.
2. **One content joiner.** Catalog-relative paths (`Content/…`) go through
   `Resolve-LiteDeployContentPath -DeploymentRoot <root>`. Absolute/UNC paths pass through.
3. **No path creation by default.** Environment’s path APIs return locations; they do not
   create directories. Log/state folders are created by Logs/State (or Engine) when those
   components explicitly need them—not by every consumer “ensuring” trees exist.
4. **BootObject / RuntimePaths are authoritative in WinPE.** Prefer
   `$BootObject.DeploymentRoot` and `$RequiredFiles.<Name>` over reconstructing paths from
   `$PSScriptRoot`.

Known deviations (to remove over time): Image standalone fallback that walks to a sibling
`DeploymentShare`; Drivers standalone default to `Z:\` when `-ShareRoot` is omitted;
WorkflowSelection optional local join to `Engine\Scripts\Runtime\LiteDeploy.Workflow.ps1`
when RuntimeFiles.Workflow is absent. Live Engine pipeline must not rely on those fallbacks.

---

## Pipeline

```text
startnet
  → Boot (Logs/Env/Hardware bootstrap)
      native share connect (New-PSDrive / New-SmbMapping; never net use + password)
      → Engine -BootObject
          Verify required paths; reuse/load Logs, Hardware, State, Drivers, UI.HostShell
          Phase 1  UI.HardwarePrecheck   (local logs/state; no deployment ID)
          Phase 2  Assign deployment ID -> UI.WorkflowSelection -> validate target -> create share log folder
          Display  start UI.Progress (separate STA process)
          Phase 3  Disk -ConfirmDestroy
                   enable OS-volume mirror W:\~LiteDeploy
          Phase 4  Image -ExecuteSetup
          Success  Status=Completed; local state saved; share/OS artifact copies attempted (check results)
          Fail     Status=Failed; Progress stays red; console NOTICE / startnet
```

### Cross-cutting behaviors

| Concern | Behavior |
| :--- | :--- |
| Theme | `BootConfig.Ui.Theme` (`Light`\|`Dark`) via `Get-LiteDeployUiTheme`; Engine passes `-Theme` to all UI |
| Progress | Separate process; polls RAM memory-map `Local\LiteDeploy.DeploymentState` then file; `-WinPE` for layout |
| State | In-memory `$global:LiteDeployDeployment` + file + RAM map + share + OS volume |
| Logs | Append CMTrace; mirror to RAM, share `RemoteLogDir`, and `OfflineOsLogDir` when present |
| Credentials | `PSCredential` / `SecureString` only; never on process command lines |

---

## Runtime components (roles — avoid overlap)

| # | Id | File | Single responsibility |
| ---: | :--- | :--- | :--- |
| 000 | Boot | `LiteDeploy.Boot.ps1` | Parent STA shell; source discovery; share mount; BootObject; hand off to Engine |
| 010 | Logs | `LiteDeploy.Logs.ps1` | CMTrace + mirrors (local / share / OS volume when enabled) |
| 020 | Environment | `LiteDeploy.Environment.ps1` | **Normalize environment**; named path map; content path join; process helper; theme read |
| 030 | Hardware | `LiteDeploy.Hardware.ps1` | Local inventory / LiteDeploy readiness facts (not Setup LabConfig) |
| 040 | State | `LiteDeploy.State.ps1` | DeploymentState + RAM IPC; credential filtering |
| 050 | Workflow | `LiteDeploy.Workflow.ps1` | Workflow/OS catalog domain (UI must not fork a second copy long-term) |
| 060 | Disk | `LiteDeploy.Disk.ps1` | Partition/format only with `-ConfirmDestroy` |
| 070 | Drivers | `LiteDeploy.Drivers.ps1` | Detect / stage packs; Image injects offline when engine is DISM |
| 080 | Image | `LiteDeploy.Image.ps1` | `setup.exe` / `dism.exe` apply + unattend; Setup LabConfig when configured |
| 090 | Packages | `LiteDeploy.Packages.ps1` | Primarily FullOS / later |
| 100 | Engine | `LiteDeploy.Engine.ps1` | Orchestrator: required names, phases, result gates |
| 110 | UI.* | under `110-UI\` → publish `Engine\Scripts\Runtime\UI\` | Precheck, WorkflowSelection, Progress, Theme, HostShell |

**Separation reminders**

- Disk never applies WIM; Image never repartitions.
- Drivers never own layout maps; they receive ShareRoot / RuntimePaths from Engine or caller.
- Hardware readiness ≠ `ComputerSetup.SkipSetupHardwareRequirements` (Image / Setup.exe).
- UI does not own deployment roots; Engine passes `DeploymentSharePath` and RuntimeFiles.

## Admin components

| # | Id | File |
| ---: | :--- | :--- |
| 000 | Admin.Build | `LiteDeploy.Admin.Build.ps1` |
| 010 | Admin.Content | `LiteDeploy.Admin.Content.ps1` |
| 020 | Admin.Images | `LiteDeploy.Admin.Images.ps1` |
| 030 | Admin.Drivers | `LiteDeploy.Admin.Drivers.ps1` |
| 040 | Admin.Packages | `LiteDeploy.Admin.Packages.ps1` |
| 050 | Admin.Workflows | `LiteDeploy.Admin.Workflows.ps1` |
| 060 | Admin.Config | `LiteDeploy.Admin.Config.ps1` |
| 070 | Admin.Validation | `LiteDeploy.Admin.Validation.ps1` |
| 080 | Admin.Utilities | `LiteDeploy.Admin.Utilities.ps1` |
| 090 | Admin UI | `LiteDeploy.Admin.UI.*.ps1` |

Admin may call Runtime helpers. Runtime never depends on Admin.

---

## Load order

```text
Boot: Environment → Logs → Hardware
Engine: verify requirements → reuse/load Logs, Hardware, State, Drivers, UI.HostShell
Disk and Image execute only in their phases. Workflow and Packages are not imported.
UI hosts are invoked by Engine (not permanently loaded into the domain set).
```

## Size targets

Aim below 1,000 lines per non-UI component. Keep UI or complex cohesive components together when justified. Review Engine, Image, Hardware, State, Workflow, Packages and Admin.Drivers against this target; line counts change and are not a release guarantee.

## Known gaps (honest)

- Driver selection is collected in Workflow UI; runtime driver staging and Setup `/InstallDrivers` continue to evolve.
- Packages are not a WinPE post-image phase yet.
- Logs/state persist on the selected OS volume; FullOS resume (specialize-staged HKLM Run / WinPECT / Z:) is implemented. Package orchestration after resume remains open.
- Path-contract debt: eliminate Image sibling-`DeploymentShare` guess, Drivers silent `Z:\` default in the Engine path, and UI-local Workflow.ps1 discovery when RuntimeFiles is incomplete (see Environment path contract).
- Domain logic still partially duplicated in UI.WorkflowSelection vs Workflow (see [responsibility audit](COMPONENT_RESPONSIBILITY_AUDIT.md)).

## Related docs

- [Deployment Plan](LITEDEPLOY_DEPLOYMENT_PLAN.md)
- [Diagrams](LITEDEPLOY_DEPLOYMENT_DIAGRAM.md)
- [Catalog / Workflow](LITEDEPLOY_CATALOG_WORKFLOW_SPEC.md)
- [Project Status](LITEDEPLOY_PROJECT_STATUS.md)
- [Responsibility audit](COMPONENT_RESPONSIBILITY_AUDIT.md)
- [ComputerSetup mapping](../guides/COMPUTER_SETUP_MAPPING.md)
- [Engine Scripts README](../../Engine/Scripts/README.md)



