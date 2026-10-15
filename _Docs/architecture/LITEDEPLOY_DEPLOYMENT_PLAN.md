# LiteDeploy Deployment Plan (Architecture v2)

## Goal

Bare-metal Windows deployment from WinPE with a thin Boot parent, domain Runtime components, and WPF UI screens. Numbered source folders are **dev/repo organization only**; production loads **flat** published scripts.

## Principles

1. PowerShell 5.1 + WinPE; `Set-StrictMode -Version 2.0`.
2. Boot remains the WinPE parent STA process (`startnet`).
3. Environment owns named paths. Engine verifies requirements, visibly imports missing helpers, then sequences phases.
4. Credentials stay in-memory (`PSCredential`); share mount via native PowerShell only.
5. Disk/Image are non-destructive unless Engine passes `-ConfirmDestroy` / `-ExecuteSetup`.
6. UI theme comes from `BootConfig.Ui.Theme` and is shared across Precheck, WorkflowSelection, Progress.

## Execution sequence

```text
1. startnet.cmd → powershell -STA LiteDeploy.Boot.ps1
2. Boot discovers BootConfig.json (media or local), optional network share map to Z:
3. Boot builds BootObject (paths, mode, credential, Config) and launches Engine
4. Engine creates provisional local state without an ID; resolves Ui.Theme
5. Phase 1 — UI.HardwarePrecheck
6. Assign deployment ID; Phase 2 — UI.WorkflowSelection; after Passed=true and valid target, create remote log folder
7. Start UI.Progress; Phase 3 — Disk format; Logs enables the selected OS-volume handoff
8. Phase 4 — Image (setup.exe /NoReboot)
9. Success — Status Completed; artifacts on RAM + share + OS volume
10. Failure — Status Failed/Cancelled; Progress stays visible (if started); console NOTICE
```

## Publish

```powershell
.\Engine\Scripts\Admin\000-Build\LiteDeploy.Admin.Build.ps1 `
  -DeploymentShare "C:\DeploymentShare" -Clean
```

Produces:

- `Engine\Scripts\Runtime\` — flat domain scripts
- `Engine\Scripts\Runtime\UI\` — flat UI
- `Engine\Scripts\Admin\` — flat admin

## WinPE inject (minimal)

```text
X:\~LiteDeploy\
  Boot\LiteDeploy.Boot.ps1
  Runtime\LiteDeploy.Logs.ps1
  Runtime\LiteDeploy.Environment.ps1
  Runtime\LiteDeploy.Hardware.ps1
  Config\BootConfig.json
```

Full Engine/UI come from the mapped share (`Z:\Engine\…`) or offline media `~\LiteDeploy\Engine\…`.

## Soft-fail policy

Unhandled throws and phase failures set deployment `Status` to `Failed` or `Cancelled`, save state, restore console, and print `[NOTICE]` / `startnet` guidance. Disk formatting starts only after a confirmed selection and valid target index. A failed format can still leave the disk partially changed.

FullOS resume (specialize-staged HKLM Run → `LiteDeploy.FullOS.ps1`, re-arm for reboot survival, kill sysprep.exe, in-memory WinPECT, native `New-SmbMapping` Z:, Interactive Probe second window) is implemented; Packages orchestration and driver application gaps remain. See [current diagrams](LITEDEPLOY_DEPLOYMENT_DIAGRAM.md) and [maintenance](../guides/MAINTENANCE.md) before release.

