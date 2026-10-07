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
  LogWriter            Central CMTrace XML logging used by all components
  HostShell            WinPE console window geometry, presets, and theme management
  BootInitializer      Device startup entry point (startnet parent process, network, Z:\ mount)
  DeploymentEngine     Sequences HardwarePreCheck, WorkflowSelection, DiskPreparation, and OSInstallation
  HardwarePreCheck     9-point hardware, firmware, network, and source readiness UI
  WorkflowSelection    Computer identity, workflow, target disk, LocalCatalog drivers, and driver picker UI
  DiskPreparation      Bare-metal disk wipe, UEFI (GPT) and Legacy (MBR) partitioning, and WinRE flags
  DriverStaging        LocalCatalog detection helpers; stage/inject reserved
  AnswerFileGenerator  Reserved. Build X:\unattended.xml
  OSInstallation       Windows Setup (setup.exe /NoReboot) and the answer file
  CredentialTransfer   Reserved. Move credentials from WinPE onto the installed OS
  DeploymentCleanup    Reserved. Clean the deployment session after credential transfer
  Progress             Read-only deployment progress UI (WinPE & FullOS)
  Credentials             [DeployVault] + [WinPECT]: Encrypted secrets across the WinPE → FullOS reboot
```

## Component Inventory

### Administrative Tooling (`Admin`)

| Component | Path | Description | Status |
| :--- | :--- | :--- | :--- |
| **SetConfig** | [Engine/Scripts/Admin/LiteDeploy.SetConfig.ps1](Engine/Scripts/Admin/LiteDeploy.SetConfig.ps1) | Generates `BootConfig.json` for `BootWim`, `DeploymentShare`, and `Media` deployment modes. | Exists |
| **SetDeploymentShareAcl** | [Engine/Scripts/Admin/LiteDeploy.SetDeploymentShareAcl.ps1](Engine/Scripts/Admin/LiteDeploy.SetDeploymentShareAcl.ps1) | Provisions folder hierarchy, SMB shares, and CREATOR-OWNER log isolation ACLs. | Exists |
| **SyncComponents** | [Engine/Scripts/Admin/LiteDeploy.SyncComponents.ps1](Engine/Scripts/Admin/LiteDeploy.SyncComponents.ps1) | Synchronizes repository modules to Deployment Shares, WinPE Builder staging, and Media roots. | Exists |
| **ImportOSMedia** | [Engine/Scripts/Admin/LiteDeploy.ImportOSMedia.ps1](Engine/Scripts/Admin/LiteDeploy.ImportOSMedia.ps1) | Ingests Windows setup media/ISOs, extracts edition metadata via DISM/7-Zip, and publishes `catalog.json`. | Exists |
| **Credentials** | [Engine/Scripts/Admin/LiteDeploy.Credentials.ps1](Engine/Scripts/Admin/LiteDeploy.Credentials.ps1) | Integration architecture for server-side vaulting ([DeployVault](https://github.com/cmartinezone/DeployVault)) and cross-reboot transfer ([WinPECT](https://github.com/cmartinezone/WinPECT)). | Documented |
| **WinPEBuilder** | [WinPEBuilder](https://github.com/cmartinezone/WinPEBuilder) | Builds bootable WinPE ISO media or `Boot.wim` for WDS/PXE. | Separate repo |

### Runtime Engine (`Runtime`)

| Component | Path | Description | Status |
| :--- | :--- | :--- | :--- |
| **LogWriter** | [Engine/Scripts/Runtime/000-LogWriter](Engine/Scripts/Runtime/000-LogWriter) | Standardized CMTrace XML logging module. Component id `LogWriter`. | Exists |
| **HostShell** | [Engine/Scripts/Runtime/000-HostShell](Engine/Scripts/Runtime/000-HostShell) | WinPE console window geometry, positioning, themes, and shell presets. Component id `HostShell`. | Exists |
| **Progress** | [Engine/Scripts/Runtime/000-Progress](Engine/Scripts/Runtime/000-Progress) | Zero-dependency WPF progress dashboard reading `DeploymentState.json` (WinPE & FullOS). Component id `Progress`. | Exists |
| **BootInitializer** | [Engine/Scripts/Runtime/010-BootInitializer](Engine/Scripts/Runtime/010-BootInitializer) | Discovers `BootConfig.json`, validates network, maps `Z:\`, constructs `BootObject`, and launches DeploymentEngine. Component id `BootInitializer`. | Exists |
| **DeploymentEngine** | [Engine/Scripts/Runtime/020-DeploymentEngine](Engine/Scripts/Runtime/020-DeploymentEngine) | Orchestrates HardwarePreCheck, WorkflowSelection, DiskPreparation, and OSInstallation in WinPE. Component id `DeploymentEngine`. | Exists |
| **HardwarePreCheck** | [Engine/Scripts/Runtime/030-HardwarePreCheck](Engine/Scripts/Runtime/030-HardwarePreCheck) | 9-point system readiness WPF UI (separated `.ps1` + `.xaml`; `SingleFile\` reference variant). Component id `HardwarePreCheck`. | Exists |
| **WorkflowSelection** | [Engine/Scripts/Runtime/040-WorkflowSelection](Engine/Scripts/Runtime/040-WorkflowSelection) | PreCheck-chrome WPF wizard (identity, firmware, catalog workflows, Hardware disk grid, DriverStaging LocalCatalog + media online when reachable). Component id `WorkflowSelection`. | Exists |
| **DiskPreparation** | [Engine/Scripts/Runtime/050-DiskPreparation](Engine/Scripts/Runtime/050-DiskPreparation) | Bare-metal disk wipe, UEFI (GPT) and Legacy (MBR) partitioning, formatting, and WinRE attribute assignment. Component id `DiskPreparation`. | Exists |
| **DriverStaging** | [Engine/Scripts/Runtime/060-DriverStaging](Engine/Scripts/Runtime/060-DriverStaging) | LocalCatalog driver detection + online reachability (imported by WorkflowSelection). Extract/inject still reserved. Component id `DriverStaging`. | Exists (detection) |
| **AnswerFileGenerator** | [Engine/Scripts/Runtime/070-AnswerFileGenerator](Engine/Scripts/Runtime/070-AnswerFileGenerator) | Reserved folder for generating `X:\unattended.xml`. | Placeholder |
| **OSInstallation** | [Engine/Scripts/Runtime/080-OSInstallation](Engine/Scripts/Runtime/080-OSInstallation) | Orchestrates Windows Setup (`setup.exe /NoReboot`) with automated unattended answer file generation. Component id `OSInstallation`. | Exists |
| **CredentialTransfer** | [Engine/Scripts/Runtime/090-CredentialTransfer](Engine/Scripts/Runtime/090-CredentialTransfer) | Reserved folder for moving credentials from WinPE onto the installed OS. | Placeholder |
| **DeploymentCleanup** | [Engine/Scripts/Runtime/100-DeploymentCleanup](Engine/Scripts/Runtime/100-DeploymentCleanup) | Reserved folder for cleaning the deployment session after credential transfer. | Placeholder |

On a client device, the live runtime chain is:

```text
startnet.cmd
  → LiteDeploy.BootInitializer.ps1 (Parent Shell)
    → LiteDeploy.DeploymentEngine.ps1 (Pipeline Orchestrator)
      ├── LiteDeploy.HardwarePreCheck.ps1 (Readiness Assessment)
      ├── LiteDeploy.WorkflowSelection.ps1 (Technician Selections)
      ├── LiteDeploy.DiskPreparation.ps1 (Target Disk Preparation)
      ├── LiteDeploy.OSInstallation.ps1 (Setup.exe Engine & Unattend Generation)
      └── LiteDeploy.Progress.ps1 (Parallel Progress Reader)
```

## Repository Structure

```text
LiteDeploy Core/
├── DeploymentShare/              # Root deployment share template & folder skeleton
│   ├── Config/                   # Boot configuration & runtime policy files
│   ├── Content/                  # Deployment payloads (BootMedia, Drivers, OperatingSystems, Packages, Temp, Unattend)
│   ├── Engine/                   # Scripts (Admin/Runtime) and execution tools
│   ├── WorkFlows/                # JSON workflow definitions (Standard, Intune Ready, etc.)
│   └── WorkLogs/                 # Execution log destinations (Admin, Deployments)
├── Engine/
│   └── Scripts/                  # Core PowerShell engine modules and management tools
│       ├── Admin/                # Administrative & share setup scripts
│       │   ├── LiteDeploy.Credentials.ps1/
│       │   ├── LiteDeploy.ImportOSMedia.ps1/
│       │   ├── LiteDeploy.SetConfig.ps1/
│       │   ├── LiteDeploy.SetDeploymentShareAcl.ps1/
│       │   └── LiteDeploy.SyncComponents.ps1/
│       └── Runtime/              # WinPE & client deployment runtime components
│           ├── 000-LogWriter/
│           ├── 000-HostShell/
│           ├── 000-Progress/
│           ├── 010-BootInitializer/
│           ├── 020-DeploymentEngine/
│           ├── 030-HardwarePreCheck/     # .ps1 + .UI.xaml (prod); SingleFile\ (reference)
│           ├── 040-WorkflowSelection/
│           ├── 050-DiskPreparation/
│           ├── 060-DriverStaging/
│           ├── 070-AnswerFileGenerator/
│           ├── 080-OSInstallation/
│           ├── 090-CredentialTransfer/
│           └── 100-DeploymentCleanup/
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
