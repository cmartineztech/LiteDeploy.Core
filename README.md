# LiteDeploy Core

Development repository for LiteDeploy. Components are organized by operational scope into administrative tooling (`Admin`) and WinPE / target OS deployment engines (`Runtime`).

The production product repo is **LiteDeploy**. A component moves there only after it is approved.

## Working Order & Pipeline Flow

```text
Admin Scope (Preparation & Share Provisioning):
  SetConfig               Admin generates BootConfig.json for BootWim, Share, or Media
  SetDeploymentShareAcl   Admin creates and hardens the deployment share layout and log ACLs
  ImportOSMedia           Admin imports Windows OS media/ISOs and publishes catalog.json
  WinPEBuilder            Builds ISO or Boot.wim for WDS/PXE (separate repository)

Runtime Scope (WinPE Execution & Target Deployment):
  LogWriter               Central CMTrace XML + NDJSON logging used by all components
  HostShell               WinPE console window geometry, presets, and theme management
  BootInitializer         Device startup entry point (startnet parent process, network, Z:\ mount)
  PreCheck                9-point hardware, firmware, network, and source readiness UI
  SelectWorkflow          Computer identity, workflow, target disk, and driver picker UI
  — DeploymentEngine —    Orchestration engine (planned): Setup /NoReboot, offline staging, handoff
  Progress                Read-only deployment progress UI (WinPE & FullOS)
  Credentials             [DeployVault] + [WinPECT]: Encrypted secrets across the WinPE → FullOS reboot
```

## Component Inventory

### Administrative Tooling (`Admin`)

| Component | Path | Description | Status |
| :--- | :--- | :--- | :--- |
| **SetConfig** | [Scripts_Engine_Components/Admin/LiteDeploy.SetConfig.ps1](Scripts_Engine_Components/Admin/LiteDeploy.SetConfig.ps1) | Generates `BootConfig.json` for `BootWim`, `DeploymentShare`, and `Media` deployment modes. | Exists |
| **SetDeploymentShareAcl** | [Scripts_Engine_Components/Admin/LiteDeploy.SetDeploymentShareAcl.ps1](Scripts_Engine_Components/Admin/LiteDeploy.SetDeploymentShareAcl.ps1) | Provisions folder hierarchy, SMB shares, and CREATOR-OWNER log isolation ACLs. | Exists |
| **ImportOSMedia** | [Scripts_Engine_Components/Admin/LiteDeploy.ImportOSMedia.ps1](Scripts_Engine_Components/Admin/LiteDeploy.ImportOSMedia.ps1) | Ingests Windows setup media/ISOs, extracts edition metadata via DISM/7-Zip, and publishes `catalog.json`. | Exists |
| **Credentials** | [Scripts_Engine_Components/Admin/LiteDeploy.Credentials.ps1](Scripts_Engine_Components/Admin/LiteDeploy.Credentials.ps1) | Integration architecture for server-side vaulting ([DeployVault](https://github.com/cmartinezone/DeployVault)) and cross-reboot transfer ([WinPECT](https://github.com/cmartinezone/WinPECT)). | Documented |
| **WinPEBuilder** | [WinPEBuilder](https://github.com/cmartinezone/WinPEBuilder) | Builds bootable WinPE ISO media or `Boot.wim` for WDS/PXE. | Separate repo |

### Runtime Engine (`Runtime`)

| Component | Path | Description | Status |
| :--- | :--- | :--- | :--- |
| **LogWriter** | [Scripts_Engine_Components/Runtime/LiteDeploy.LogWriter.ps1](Scripts_Engine_Components/Runtime/LiteDeploy.LogWriter.ps1) | Standardized dual-logging module (CMTrace-compatible XML + NDJSON). | Exists |
| **HostShell** | [Scripts_Engine_Components/Runtime/LiteDeploy.HostShell.ps1](Scripts_Engine_Components/Runtime/LiteDeploy.HostShell.ps1) | WinPE console window geometry, positioning, themes, and shell presets. | Exists |
| **BootInitializer** | [Scripts_Engine_Components/Runtime/LiteDeploy.BootInitilizer.ps1](Scripts_Engine_Components/Runtime/LiteDeploy.BootInitilizer.ps1) | Discovers `BootConfig.json`, validates network, maps `Z:\`, constructs `BootObject`, and launches PreCheck. | Exists |
| **PreCheck** | [Scripts_Engine_Components/Runtime/LiteDeploy.PreCheck.ps1](Scripts_Engine_Components/Runtime/LiteDeploy.PreCheck.ps1) | 9-point system readiness and hardware assessment WPF UI with software rendering. | Exists |
| **SelectWorkflow** | [Scripts_Engine_Components/Runtime/LiteDeploy.SelectWorkFlow.ps1](Scripts_Engine_Components/Runtime/LiteDeploy.SelectWorkFlow.ps1) | WPF wizard for computer naming, workflow selection, disk targeting, and driver pack resolution. | Exists |
| **DeploymentEngine** | — | Orchestrates Windows Setup `/NoReboot`, offline staging, handoff verification, and FullOS resume. | Planned |
| **Progress** | [Scripts_Engine_Components/Runtime/LiteDeployProgress.ps1](Scripts_Engine_Components/Runtime/LiteDeployProgress.ps1) | Zero-dependency WPF progress dashboard reading `DeploymentState.json` (WinPE & FullOS). | Exists |

On a client device, the live runtime chain is:

```text
startnet.cmd
  → LiteDeploy.BootInitilizer.ps1 (Parent Shell)
    → LiteDeploy.PreCheck.ps1 (Readiness Assessment)
      → LiteDeploy.SelectWorkFlow.ps1 (Technician Selections)
        → LiteDeploy.DeploymentEngine.ps1 (Planned Orchestrator)
          ├── LiteDeploy.Progress.ps1 (Parallel Progress Reader)
          └── Windows Setup (/NoReboot) → Controlled First Reboot → FullOS Resume
```

## Repository Structure

```text
LiteDeploy Core/
├── DeploymentShare_Layout/       # Root deployment share template & folder skeleton
│   ├── Config/                   # Boot configuration & runtime policy files
│   ├── Content/                  # Deployment payloads (BootMedia, Drivers, OperatingSystems, Packages, Temp, Unattend)
│   ├── Engine/                   # Scripts (Admin/Runtime) and execution tools
│   ├── WorkFlows/                # JSON workflow definitions (Standard, Intune Ready, etc.)
│   └── WorkLogs/                 # Execution log destinations (Admin, Deployments)
├── Scripts_Engine_Components/    # Core PowerShell engine modules and management tools
│   ├── Admin/                    # Administrative & share setup scripts
│   │   ├── LiteDeploy.Credentials.ps1/
│   │   ├── LiteDeploy.ImportOSMedia.ps1/
│   │   ├── LiteDeploy.SetConfig.ps1/
│   │   └── LiteDeploy.SetDeploymentShareAcl.ps1/
│   └── Runtime/                  # WinPE & client deployment runtime components
│       ├── LiteDeploy.BootInitilizer.ps1/
│       ├── LiteDeploy.HostShell.ps1/
│       ├── LiteDeploy.LogWriter.ps1/
│       ├── LiteDeploy.PreCheck.ps1/
│       ├── LiteDeploy.SelectWorkFlow.ps1/
│       └── LiteDeployProgress.ps1/
├── Templates/                    # Master component blueprints & inventory scanner
│   ├── LiteDeploy.Component.Template.ps1
│   ├── Get-LiteDeployComponentInventory.ps1
│   └── README.md
├── _Docs/                        # Product architecture specifications and plans
│   └── architecture/             # Deployment plan, sequence diagrams, catalog specs, project status
└── _Experiments/                 # Historical prototypes, test harnesses, and laboratory scripts
```

## Related Repositories

These stay in their own GitHub repos. LiteDeploy Core consumes them; it does not duplicate their source trees:

| Repository | Role in LiteDeploy |
| :--- | :--- |
| [WinPEBuilder](https://github.com/cmartinezone/WinPEBuilder) | Creates WinPE boot media as ISO or `Boot.wim` for WDS/PXE. |
| [DeployVault](https://github.com/cmartinezone/DeployVault) | Encrypted credential vault on the deployment share. |
| [WinPECT](https://github.com/cmartinezone/WinPECT) | Hardware-bound credential transfer from WinPE to FullOS. |

## Architecture Documentation

- [Deployment Plan](_Docs/architecture/LITEDEPLOY_DEPLOYMENT_PLAN.md)
- [Architecture Diagrams](_Docs/architecture/LITEDEPLOY_DEPLOYMENT_DIAGRAM.md)
- [Catalog and Workflow Specification](_Docs/architecture/LITEDEPLOY_CATALOG_WORKFLOW_SPEC.md)
- [Project Status & Handoff](_Docs/architecture/LITEDEPLOY_PROJECT_STATUS.md)
