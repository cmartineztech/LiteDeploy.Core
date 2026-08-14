# Components

Folders are numbered in the order LiteDeploy works. Numbers are for this development repo only. Production still publishes sibling scripts under `Engine\Scripts`.

## Before a device boots

| # | Folder | Runs when |
| ---: | --- | --- |
| 01 | `01-Config` | An administrator generates `BootConfig.json` for the boot image or share. |
| 02 | `02-DeploymentShareACL` | An administrator creates the share, SMB permissions, and log ACLs. |
| 03 | `03-LogWriter` | Loaded by later components as soon as WinPE logging starts. |
| 04 | `04-HostShell` | Loaded by BootInitializer to control the WinPE console. |

## On the device

| # | Folder | Runs when |
| ---: | --- | --- |
| 05 | `05-BootInitializer` | `startnet.cmd` starts the parent PowerShell process. |
| 06 | `06-PreCheck` | BootInitializer invokes it with `BootObject`. |
| 07 | `07-SelectWorkflow` | PreCheck Continue currently launches it in the same process. |
| — | DeploymentEngine | Planned next stage after a confirmed workflow selection. |
| 08 | `08-Progress` | Planned as a separate process while the engine runs. |
| 09 | `09-Credentials` | Planned during offline handoff and FullOS SYSTEM import. |

When DeploymentEngine is added, it becomes `08-DeploymentEngine` and Progress / Credentials shift to `09` and `10`. Do not add new work under the old `01_BootInitlizer` names.

## Rules

- Put new work in the matching numbered folder, or add the next number at the point it runs.
- Keep production script names (`LiteDeploy.PreCheck.ps1`, not a new name per folder).
- `experiments/` is not part of this sequence and does not promote to LiteDeploy.
