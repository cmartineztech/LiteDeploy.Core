# Engine Scripts (Architecture v2)

## Dev vs production

**Numbered folders (`000-Boot`, `110-UI`, …) are for development and repository organization only.**

| Location | Role |
| :--- | :--- |
| `Engine\Scripts\Runtime\<NNN-*>\` | Dev source (this repo) |
| `Engine\Scripts\Runtime\110-UI\` | Dev Runtime UI source |
| `Engine\Scripts\Admin\<NNN-*>\` | Dev Admin source |
| **Published share** `Engine\Scripts\Runtime\*.ps1` | Flat domain scripts |
| **Published share** `Engine\Scripts\Runtime\UI\` | Runtime UI |
| **Published share** `Engine\Scripts\Admin\*.ps1` | Flat Admin tools |
| **Published share** `Engine\Scripts\Admin\UI\` | Admin UI |

Publish with:

```powershell
.\Admin\000-Build\LiteDeploy.Admin.Build.ps1 -DeploymentShare "C:\DeploymentShare" -Clean
```

Environment owns the explicit layout, selected once when it is loaded:

1. `-Mode Production` (default): flat scripts with screens beneath `UI`.
2. `-Mode Development`: numbered source locations declared in Environment's top-level map.

**Environment normalizes the environment and supplies paths.** Engine declares required
component **names**; Environment maps them to exact files. Domain/UI consumers use
`Get-LiteDeployComponentPath`, RuntimeFiles, or `Resolve-LiteDeployContentPath` — they do
not guess sibling `DeploymentShare` trees, invent layouts when a file is missing, or create
content directories unsolicited. Environment builds the required-file list once; Engine does
not fall back to another layout.
See [Understand and control Engine](../../_Docs/guides/ENGINE_READING_GUIDE.md) for the file map,
visible imports, result contracts, and `-ValidateOnly` inspection.

## Runtime (dev folders)

| Folder | Component | Published file |
| :--- | :--- | :--- |
| `000-Boot` | Boot | `LiteDeploy.Boot.ps1` |
| `010-Logs` | Logs | `LiteDeploy.Logs.ps1` |
| `020-Environment` | Environment | `LiteDeploy.Environment.ps1` |
| `030-Hardware` | Hardware | `LiteDeploy.Hardware.ps1` |
| `040-State` | State | `LiteDeploy.State.ps1` |
| `050-Workflow` | Workflow | `LiteDeploy.Workflow.ps1` |
| `060-Disk` | Disk | `LiteDeploy.Disk.ps1` |
| `070-Drivers` | Drivers | `LiteDeploy.Drivers.ps1` |
| `080-Image` | Image | `LiteDeploy.Image.ps1` |
| `090-Packages` | Packages | `LiteDeploy.Packages.ps1` |
| `100-Engine` | Engine | `LiteDeploy.Engine.ps1` |
| `100-Engine` | FullOS | `LiteDeploy.FullOS.ps1` |
| `110-UI\...` | UI.* | `LiteDeploy.UI.*` → `Engine\Scripts\Runtime\UI\` |

### Execution

```text
startnet → Boot → Engine
  Load required components once at script scope (stop on import failure)
  → UI.HardwarePrecheck (honors Startup.SkipHardwarePreCheck)
  → UI.WorkflowSelection
  → UI.Progress (-WinPE, TopMost, theme from BootConfig)
  → Disk (-ConfirmDestroy)
  → Image (-ExecuteSetup; if Setup.exe + SkipSetupHardwareRequirements, LabConfig/MoSetup first)
```

BootConfig hardware-related flags: `Startup.SkipHardwarePreCheck` (Precheck UI) vs
`ComputerSetup.SkipSetupHardwareRequirements` (Setup.exe WinPE registry bypass). See
[_Docs/guides/COMPUTER_SETUP_MAPPING.md](../../_Docs/guides/COMPUTER_SETUP_MAPPING.md).

## Admin (dev folders)

| Folder | Component | Published file |
| :--- | :--- | :--- |
| `000-Build` | Admin.Build | `LiteDeploy.Admin.Build.ps1` |
| `010-Content` | Admin.Content | `LiteDeploy.Admin.Content.ps1` |
| `020-Images` | Admin.Images | `LiteDeploy.Admin.Images.ps1` |
| `030-Drivers` | Admin.Drivers | `LiteDeploy.Admin.Drivers.ps1` |
| `040-Packages` | Admin.Packages | `LiteDeploy.Admin.Packages.ps1` |
| `050-Workflows` | Admin.Workflows | `LiteDeploy.Admin.Workflows.ps1` |
| `060-Config` | Admin.Config | `LiteDeploy.Admin.Config.ps1` |
| `070-Validation` | Admin.Validation | `LiteDeploy.Admin.Validation.ps1` |
| `080-Utilities` | Admin.Utilities | `LiteDeploy.Admin.Utilities.ps1` |
| `090-UI` | Admin UI | `LiteDeploy.Admin.UI.*` |

Admin may reuse Runtime helpers. Runtime never depends on Admin.

## Rules

1. PowerShell 5.1 + WinPE + `Set-StrictMode -Version 2.0`
2. Keep one clear responsibility per component; split only when it makes maintenance easier
3. Standalone Disk/Image are non-destructive unless explicit switches
4. Credentials: `_Docs/integrations/Credentials/`
5. Architecture: `_Docs/architecture/LITEDEPLOY_COMPONENT_REFACTOR_V2.md`

See [operation and maintenance](../../_Docs/guides/MAINTENANCE.md) for current support limits
and the Windows PowerShell 5.1 smoke-test command. The architecture suite lives at
[`_Tests\`](../../_Tests/README.md) (not under `Engine\Scripts`). Component authoring
blueprints and inventory live at [`_Templates\`](../../_Templates/README.md). Dot-sourcing
Engine loads its helpers without running the deployment pipeline; executing it starts
deployment.

## Current behavior and agreed follow-up

See [the detailed guide](../../_Docs/guides/WINPE_BOOTSTRAP.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.
