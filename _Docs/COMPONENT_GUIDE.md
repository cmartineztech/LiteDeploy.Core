# Component documentation index

See [ComputerSetup mapping](guides/COMPUTER_SETUP_MAPPING.md) for configuration-to-UI/state/answer-file behavior, including `SkipSetupHardwareRequirements` (Setup.exe WinPE LabConfig/MoSetup) vs `Startup.SkipHardwarePreCheck` (Precheck UI).

Guides cover entry points, dependencies, parameters, effects, results and limits. Examples use Windows PowerShell 5.1 from the repository root. Sample paths are **generic lab placeholders** only (`C:\DeploymentShare`, `C:\LiteDeploy-Staging`, `\\Server\Share$`, `X:\` / `Z:\` / `W:\`) — do not commit personal profile paths (`C:\Users\<you>\…`, Desktop checkouts). Documentation review does not certify WinPE or end-to-end deployment.

| Component | Guide |
| --- | --- |
| Admin.Build | [Guide](../Engine/Scripts/Admin/000-Build/README.md) |
| Admin.Content | [Guide](../Engine/Scripts/Admin/010-Content/README.md) |
| Admin.Images | [Guide](../Engine/Scripts/Admin/020-Images/README.md) |
| Admin.Drivers | [Guide](../Engine/Scripts/Admin/030-Drivers/README.md) |
| Admin.Packages | [Guide](../Engine/Scripts/Admin/040-Packages/README.md) |
| Admin.Workflows | [Guide](../Engine/Scripts/Admin/050-Workflows/README.md) |
| Admin.Config | [Guide](../Engine/Scripts/Admin/060-Config/README.md) |
| Admin.Validation | [Guide](../Engine/Scripts/Admin/070-Validation/README.md) |
| Admin.Utilities | [Guide](../Engine/Scripts/Admin/080-Utilities/README.md) |
| Admin.UI.Drivers | [Guide](../Engine/Scripts/Admin/090-UI/Drivers/README.md) |
| Admin.UI.Images | [Guide](../Engine/Scripts/Admin/090-UI/Images/README.md) |
| Boot | [Guide](../Engine/Scripts/Runtime/000-Boot/README.md) |
| Logs | [Guide](../Engine/Scripts/Runtime/010-Logs/README.md) |
| Environment | [Guide](../Engine/Scripts/Runtime/020-Environment/README.md) |
| Hardware | [Guide](../Engine/Scripts/Runtime/030-Hardware/README.md) |
| State | [Guide](../Engine/Scripts/Runtime/040-State/README.md) |
| Workflow | [Guide](../Engine/Scripts/Runtime/050-Workflow/README.md) |
| Disk | [Guide](../Engine/Scripts/Runtime/060-Disk/README.md) |
| Drivers | [Guide](../Engine/Scripts/Runtime/070-Drivers/README.md) |
| Image | [Guide](../Engine/Scripts/Runtime/080-Image/README.md) |
| Packages | [Guide](../Engine/Scripts/Runtime/090-Packages/README.md) |
| Engine | [Guide](../Engine/Scripts/Runtime/100-Engine/README.md) |
| FullOS | Same guide as Engine ([100-Engine](../Engine/Scripts/Runtime/100-Engine/README.md)) — `LiteDeploy.FullOS.ps1`; Interactive Probe is temporary |
| UI.HardwarePrecheck | [Guide](../Engine/Scripts/Runtime/110-UI/HardwarePrecheck/README.md) |
| UI.HostShell | [Guide](../Engine/Scripts/Runtime/110-UI/HostShell/README.md) |
| UI.Progress | [Guide](../Engine/Scripts/Runtime/110-UI/Progress/README.md) |
| UI.WorkflowSelection | [Guide](../Engine/Scripts/Runtime/110-UI/WorkflowSelection/README.md) |
| UI.WorkflowSelectionDriverPicker | [Guide](../Engine/Scripts/Runtime/110-UI/WorkflowSelection/DRIVER_PICKER.md) |
| UI.Theme | [Guide](../Engine/Scripts/Runtime/110-UI/Theme/README.md) |
| Architecture checks | [Guide](../_Tests/README.md) (`_Tests\` — not published) |
| Component templates / inventory | [Guide](../_Templates/README.md) (`_Templates\` — not published) |
| Progress emulator | [Guide](../Engine/Scripts/Runtime/110-UI/Progress/TESTING.md) |

FullOS (`LiteDeploy.FullOS.ps1`: HKLM Run first launch staged by Image specialize when actions > 0, re-arm for reboot survival, kill sysprep.exe, in-memory WinPECT, native `New-SmbMapping` Z: + `EnableLinkedConnections`, Domain Join temporary UAC bypass + restore, Interactive Probe in a second window) is implemented; package orchestration and real Progress dispatch are next. Admin.UI.Images still uses legacy backend lookup; its guide records the direct Admin.Images alternative. Doc map: [`README.md`](README.md).

## Deployment setup and agreed designs

- [WinPE files and startup](guides/WINPE_BOOTSTRAP.md): exact bootstrap payload, startnet, share/media layout and prerequisites.
- [Driver handling](guides/DRIVER_HANDLING.md): matching, SHA-256 verification, staging, extraction and offline DISM injection.
- [Logging and failures](guides/LOGGING_AND_FAILURE_DESIGN.md): console, credentials, inventory, notices and all major Boot branches.
- [Architecture diagrams](architecture/LITEDEPLOY_DEPLOYMENT_DIAGRAM.md): full end-to-end pipeline diagrams.
- [Component Responsibility Audit](architecture/COMPONENT_RESPONSIBILITY_AUDIT.md): audit of single-responsibility adherence and deduplication opportunities across components.
- [Fast Transition Spec & Rollback Plan](architecture/FAST_TRANSITION_NETWORK_SPECIFICATION.md): sub-second (<0.4s) network transition specification, RAM catalog caching rules, and rollback procedure.
- [Credentials / WinPECT](integrations/Credentials/README.md): WinPE → FullOS credential handoff and FullOS entry.
- [Deployment share template](../DeploymentShare/README.md): publish layout, `DeploymentEngine.ps1` BootInitializer alias, Tools sync.
- [Upcoming Ideas & Designs](planning/IDEAS_FOR_IMPLEMENTATION.md): ephemeral `LD_<UID>` account, Packages orchestration, console UX (future; current FullOS uses specialize-staged HKLM Run).
- [Release status](architecture/LITEDEPLOY_PROJECT_STATUS.md): implemented work versus remaining blockers.
