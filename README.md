# LiteDeploy Core

Development repository for LiteDeploy. Components are numbered in the order they work, from share preparation through the WinPE technician flow.

The production product repo is **LiteDeploy**. A component moves there only after it is approved.

## Working order

```text
01 Config                 Admin generates BootConfig.json
   WinPEBuilder           Builds ISO or Boot.wim for WDS/PXE (separate repo)
   DeploymentShare        Initial deployment-share folder layout
02 DeploymentShareACL     Admin creates and hardens the deployment share
03 LogWriter              Logging used by every later component
04 HostShell              WinPE console window
05 BootInitializer        Device starts here (startnet parent process)
06 PreCheck               Hardware and source readiness UI
07 SelectWorkflow         Computer, workflow, disk, and driver UI
08 DeploymentEngine       Orchestrates PreCheck → SelectWorkflow → Setup (Setup stubbed)
09 Progress               Read-only deployment progress UI
10 Credentials            Encrypted secrets across the WinPE → FullOS reboot
```

| # | Component | What it does | Status |
| ---: | --- | --- | --- |
| 01 | [Config](components/01-Config) | Generates `BootConfig.json` for BootWim, DeploymentShare, and Media | Exists |
| — | [WinPEBuilder](https://github.com/cmartinezone/WinPEBuilder) | Builds boot ISO or `Boot.wim` for WDS/PXE | Separate repo |
| — | [DeploymentShare](DeploymentShare) | Initial deployment-share folder layout | Exists |
| 02 | [DeploymentShareACL](components/02-DeploymentShareACL) | Share folders, SMB, and NTFS log isolation | Exists |
| 03 | [LogWriter](components/03-LogWriter) | CMTrace + NDJSON logging | Exists |
| 04 | [HostShell](components/04-HostShell) | WinPE console geometry, theme, and presets | Exists |
| 05 | [BootInitializer](components/05-BootInitializer) | Discovers config, maps `Z:\`, builds `BootObject`, starts DeploymentEngine | Exists |
| 06 | [PreCheck](components/06-PreCheck) | Nine-point readiness UI; returns structured result | Exists |
| 07 | [SelectWorkflow](components/07-SelectWorkflow) | Identity, workflow, disk, and drivers; returns structured selection | Exists |
| 08 | [DeploymentEngine](components/08-DeploymentEngine) | WinPE orchestration; Setup `/NoReboot` still stubbed | Scaffold |
| 09 | [Progress](components/09-Progress) | Reads `DeploymentState.json` and renders progress | Exists |
| 10 | [Credentials](components/10-Credentials) | [DeployVault](https://github.com/cmartinezone/DeployVault) + [WinPECT](https://github.com/cmartinezone/WinPECT) | Separate repos |

`ImportOSMedia` will sit after Config when it is in this repository. It publishes the OS catalog that SelectWorkflow and the engine will consume.

On a device, the live chain is:

```text
startnet
  → 05 BootInitializer
  → 08 DeploymentEngine
       → 06 PreCheck
       → 07 SelectWorkflow
       → (planned) Setup /NoReboot + handoff
  → 09 Progress (separate process, read-only)
  → 10 Credentials (handoff, then FullOS import)
```

## Repository layout

```text
LiteDeploy Core/
  components/                 Numbered in working order
  DeploymentShare/            Initial deployment-share folder layout
  docs/architecture/          Product design, diagrams, and status
  experiments/                Historical and scratch scripts; not shippable
  ImportOSMedia/              Planned OS importer (empty)
```

Script file names stay as they are so WinPE and the future `Engine\Scripts` layout do not change. Folder numbers exist only in this Core repo so the sequence is visible.

## Related repositories

These stay in their own GitHub repos. LiteDeploy Core consumes them; it does not copy their source.

| Repository | Role in LiteDeploy |
| --- | --- |
| [WinPEBuilder](https://github.com/cmartinezone/WinPEBuilder) | Creates WinPE boot media as ISO or `Boot.wim` for WDS/PXE. |
| [DeployVault](https://github.com/cmartinezone/DeployVault) | Encrypted credential vault on the deployment share. |
| [WinPECT](https://github.com/cmartinezone/WinPECT) | Hardware-bound credential transfer from WinPE to FullOS. |

## Architecture

- [Deployment plan](docs/architecture/LITEDEPLOY_DEPLOYMENT_PLAN.md)
- [Architecture diagrams](docs/architecture/LITEDEPLOY_DEPLOYMENT_DIAGRAM.md)
- [Catalog and workflow spec](docs/architecture/LITEDEPLOY_CATALOG_WORKFLOW_SPEC.md)
- [Project status](docs/architecture/LITEDEPLOY_PROJECT_STATUS.md)
