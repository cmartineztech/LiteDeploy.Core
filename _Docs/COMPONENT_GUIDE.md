# Component documentation index

See [ComputerSetup mapping](guides/COMPUTER_SETUP_MAPPING.md) for configuration-to-UI/state/answer-file behavior, including `SkipSetupHardwareRequirements` (Setup.exe WinPE LabConfig/MoSetup) vs `Startup.SkipHardwarePreCheck` (Precheck UI).

Guides cover entry points, dependencies, parameters, effects, results and limits. Examples use Windows PowerShell 5.1 from the repository root. Sample paths are **generic lab placeholders** only (`C:\DeploymentShare`, `C:\LiteDeploy-Staging`, `\\Server\Share$`, `X:\` / `Z:\` / `W:\`) — do not commit personal profile paths (`C:\Users\<you>\…`, Desktop checkouts). Documentation review does not certify WinPE or end-to-end deployment.

| Component | Guide |
| --- | --- |
| Admin.Build | [Guide](../Engine/Admin/000-Build/README.md) |
| Admin.Content | [Guide](../Engine/Admin/010-Content/README.md) |
| Admin.Images | [Guide](../Engine/Admin/020-Images/README.md) |
| Admin.Drivers | [Guide](../Engine/Admin/030-Drivers/README.md) |
| Admin.Packages | [Guide](../Engine/Admin/040-Packages/README.md) |
| Admin.Workflows | [Guide](../Engine/Admin/050-Workflows/README.md) |
| Admin.Config | [Guide](../Engine/Admin/060-Config/README.md) |
| Admin.Validation | [Guide](../Engine/Admin/070-Validation/README.md) |
| Admin.Utilities | [Guide](../Engine/Admin/080-Utilities/README.md) |
| Admin.UI.Drivers | [Guide](../Engine/Admin/090-UI/Drivers/README.md) |
| Admin.UI.Images | [Guide](../Engine/Admin/090-UI/Images/README.md) |
| PE.Boot | [Guide](../Engine/Runtime/000-Boot/README.md) |
| PE.Engine | [Guide](../Engine/Runtime/010-Engine/README.md) (`LiteDeploy.PE.Engine.ps1`) |
| OS.Engine | Same guide as Engine ([010-Engine](../Engine/Runtime/010-Engine/README.md)) — `LiteDeploy.OS.Engine.ps1`; live monitor is integrated |
| Environment | [Guide](../Engine/Runtime/020-Environment/README.md) |
| Session | [Guide](../Engine/Runtime/030-Session/README.md) |
| Hardware | [Guide](../Engine/Runtime/040-Hardware/README.md) |
| Workflow | [Guide](../Engine/Runtime/050-Workflow/README.md) |
| Disk | [Guide](../Engine/Runtime/060-Disk/README.md) |
| Drivers | [Guide](../Engine/Runtime/070-Drivers/README.md) |
| Image | [Guide](../Engine/Runtime/080-Image/README.md) |
| Packages | [Guide](../Engine/Runtime/090-Packages/README.md) |
| UI.HardwarePrecheck | [Guide](../Engine/Runtime/100-UI/HardwarePrecheck/README.md) |
| UI.HostShell | [Guide](../Engine/Runtime/100-UI/HostShell/README.md) |
| UI.Progress | [Guide](../Engine/Runtime/100-UI/Progress/README.md) |
| UI.WorkflowSelection | [Guide](../Engine/Runtime/100-UI/WorkflowSelection/README.md) |
| UI.WorkflowSelectionDriverPicker | [Guide](../Engine/Runtime/100-UI/WorkflowSelection/DRIVER_PICKER.md) |
| UI.Theme | [Guide](../Engine/Runtime/100-UI/Theme/README.md) |
| Architecture checks | [Guide](../_Tests/README.md) (`_Tests\` — not published) |
| Component templates / inventory | [Guide](../_Templates/README.md) (`_Templates\` — not published) |
| Progress emulator | [Guide](../Engine/Runtime/100-UI/Progress/TESTING.md) |

FullOS (`LiteDeploy.OS.Engine.ps1`: HKLM Run first launch staged by Image specialize when actions > 0, universal High Performance power plan + 0 timeouts, Environment Shielding with GPO freeze and CAD/Notice suppression for non-Administrator accounts, HKCU console handoff on load for consoles started afterward, re-arm for reboot survival, kill sysprep.exe, in-memory WinPECT, native `New-SmbMapping` Z: + `EnableLinkedConnections`, Domain Join temporary UAC bypass + teardown restore, live interactive monitor) is implemented; package orchestration and real Progress dispatch are next. Admin.UI.Images still uses legacy backend lookup; its guide records the direct Admin.Images alternative. Doc map: [`README.md`](README.md).

## Deployment setup and agreed designs

- [WinPE files and startup](guides/WINPE_BOOTSTRAP.md): exact bootstrap payload, startnet, share/media layout and prerequisites.
- [Driver handling](guides/DRIVER_HANDLING.md): matching, SHA-256 verification, staging, extraction and offline DISM injection.
- [Logging and failures](guides/LOGGING_AND_FAILURE_DESIGN.md): console, credentials, inventory, notices and all major Boot branches.
- [Architecture diagrams](architecture/LITEDEPLOY_DEPLOYMENT_DIAGRAM.md): full end-to-end pipeline diagrams.
- [Component Responsibility Audit](architecture/COMPONENT_RESPONSIBILITY_AUDIT.md): audit of single-responsibility adherence and deduplication opportunities across components.
- [Fast Transition Spec & Rollback Plan](architecture/FAST_TRANSITION_NETWORK_SPECIFICATION.md): sub-second (<0.4s) network transition specification, RAM catalog caching rules, and rollback procedure.
- [Credentials / WinPECT](integrations/Credentials/README.md): WinPE → FullOS credential handoff and FullOS entry.
- [Deployment share template](../DeploymentShare/README.md): publish layout, flat runtime, Tools sync.
- [FullOS Shielding & Teardown Matrix](architecture/FULLOS_SHIELDING_AND_CLEANUP_MATRIX.md): complete matrix of power plans, GPO freezes, legal notices, CAD, UAC bypass, and cleanup restoration.
- [Upcoming Ideas & Designs](planning/IDEAS_FOR_IMPLEMENTATION.md): ephemeral `LD-<UID>` account, Packages orchestration, console UX.
- [Release status](architecture/LITEDEPLOY_PROJECT_STATUS.md): implemented work versus remaining blockers.
