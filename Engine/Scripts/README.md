# Engine Scripts

This directory contains the primary PowerShell engine modules, graphical interfaces, and administrative tooling for **LiteDeploy**.

The components are divided into two operational scopes:
- **`Admin/`**: Tools executed by deployment administrators on server/technician workstations to configure shares, ingest media, generate configurations, and prepare credentials.
- **`Runtime/`**: Engines and interfaces executed during WinPE boot and the target machine deployment pipeline.

---

## 🛠️ Administrative Components (`Admin/`)

These tools prepare and maintain the deployment environment before a client device boots:

| Component | Folder | Description |
| :--- | :--- | :--- |
| **SetConfig** | [`Admin/LiteDeploy.SetConfig.ps1`](Admin/LiteDeploy.SetConfig.ps1) | Generates `BootConfig.json` templates and active configurations for `BootWim`, `DeploymentShare`, and `Media` modes. |
| **SetDeploymentShareAcl** | [`Admin/LiteDeploy.SetDeploymentShareAcl.ps1`](Admin/LiteDeploy.SetDeploymentShareAcl.ps1) | Provisions local deployment share folder structures, SMB share permissions, and isolated NTFS write-only ACLs for deployment logs. |
| **SyncComponents** | [`Admin/LiteDeploy.SyncComponents.ps1`](Admin/LiteDeploy.SyncComponents.ps1) | Synchronizes repository scripts to production Deployment Shares, WinPE Builder staging directories, and Media roots. |
| **ImportOSMedia** | [`Admin/LiteDeploy.ImportOSMedia.ps1`](Admin/LiteDeploy.ImportOSMedia.ps1) | High-performance CLI and WPF tool for ingesting Windows ISOs/WIMs, resolving DISM edition metadata, and publishing `catalog.json`. |
| **Credentials** | [`Admin/LiteDeploy.Credentials.ps1`](Admin/LiteDeploy.Credentials.ps1) | Integration architecture and technical guides for server-side vaulting ([DeployVault](https://github.com/cmartinezone/DeployVault)) and cross-reboot credential transfer ([WinPECT](https://github.com/cmartinezone/WinPECT)). |

---

## ⚡ Runtime Deployment Components (`Runtime/`)

These engines execute inside Windows PE on the target device:

| Component | Folder | ComponentId | Execution Timing & Purpose |
| :--- | :--- | :--- | :--- |
| **LogWriter** | [`Runtime/000-LogWriter`](Runtime/000-LogWriter) | `LogWriter` | Core logging engine. Generates live colored console output and Microsoft CMTrace XML logs. |
| **Hardware** | [`Runtime/000-Hardware`](Runtime/000-Hardware) | `Hardware` | WinPE-first `Get-Hardware*` inventory (identity, firmware, NIC/IP/CIDR/DNS, disks) for Precheck and Engine logs; `Get-HardwarePhysicalDisks` for WorkflowSelection grid. |
| **HostShell** | [`Runtime/000-HostShell`](Runtime/000-HostShell) | `HostShell` | Manages classic WinPE console window geometry, positioning, border styles, color palettes, and shell presets. |
| **Progress** | [`Runtime/000-Progress`](Runtime/000-Progress) | `Progress` | Zero-dependency WPF progress dashboard that renders real-time state from `DeploymentState.json` in both WinPE and FullOS phases. |
| **BootInitializer** | [`Runtime/010-BootInitializer`](Runtime/010-BootInitializer) | `BootInitializer` | WinPE entry point started by `startnet.cmd`. Discovers `BootConfig.json`, tests network connectivity, authenticates and maps `Z:\`, launches DeploymentEngine; unhandled engine errors → `[NOTICE]` / `startnet`. |
| **DeploymentEngine** | [`Runtime/020-DeploymentEngine`](Runtime/020-DeploymentEngine) | `DeploymentEngine` | Pipeline orchestrator. Sequences HardwarePreCheck, WorkflowSelection, DiskPreparation, and OSInstallation in WinPE. |
| **HardwarePreCheck** | [`Runtime/030-HardwarePreCheck`](Runtime/030-HardwarePreCheck) | `HardwarePreCheck` | BootConfigPath-driven WPF readiness wizard (`.ps1` + `.xaml`); inventory via Hardware; returns `{ Passed, Inventory }` to the Engine. |
| **WorkflowSelection** | [`Runtime/040-WorkflowSelection`](Runtime/040-WorkflowSelection) | `WorkflowSelection` | PreCheck-chrome wizard: identity, firmware, catalog workflows, disk (`DriveSelection`), drivers (OEM Info dialog, truncated OEM paths, picker BFS depth 8). Returns selection object + `%SystemDrive%\WorkflowSelection.json`. |
| **DiskPreparation** | [`Runtime/050-DiskPreparation`](Runtime/050-DiskPreparation) | `DiskPreparation` | Bare-metal disk wipe, UEFI (GPT) and Legacy (MBR) partitioning, formatting, and WinRE flags. |
| **DriverStaging** | [`Runtime/060-DriverStaging`](Runtime/060-DriverStaging) | `DriverStaging` | LocalCatalog detection + pack metadata + online reachability (imported by WorkflowSelection). Extract/inject/download still reserved. |
| **AnswerFileGenerator** | [`Runtime/070-AnswerFileGenerator`](Runtime/070-AnswerFileGenerator) | — | Reserved. Builds `X:\unattended.xml` from the workflow selection and disk result. |
| **OSInstallation** | [`Runtime/080-OSInstallation`](Runtime/080-OSInstallation) | `OSInstallation` | Generates the unattended answer file and runs `setup.exe /NoReboot`. |
| **CredentialTransfer** | [`Runtime/090-CredentialTransfer`](Runtime/090-CredentialTransfer) | — | Reserved. Moves in-memory credentials from WinPE onto the installed OS. |
| **DeploymentCleanup** | [`Runtime/100-DeploymentCleanup`](Runtime/100-DeploymentCleanup) | — | Reserved. Cleans the deployment session after credential transfer. |

---

## 🔄 Deployment Share Mapping

When promoted to production or staged on a deployment share root (see [`DeploymentShare`](../../DeploymentShare)), scripts are published into matching `Engine\Scripts` subdirectories:

```text
DeploymentShare\Engine\Scripts\
├── Admin\
│   ├── LiteDeploy.ImportOSMedia.ps1
│   ├── LiteDeploy.ImportOSMediaGUI.ps1
│   ├── LiteDeploy.SetConfig.ps1
│   └── LiteDeploy.SetDeploymentShareAcl.ps1
└── Runtime\
    ├── LiteDeploy.LogWriter.ps1
    ├── LiteDeploy.Hardware.ps1
    ├── LiteDeploy.HostShell.ps1
    ├── LiteDeploy.Progress.ps1
    ├── LiteDeploy.BootInitializer.ps1
    ├── LiteDeploy.DeploymentEngine.ps1
    ├── LiteDeploy.HardwarePreCheck.ps1
    ├── LiteDeploy.HardwarePreCheck.UI.xaml
    ├── LiteDeploy.WorkflowSelection.ps1
    ├── LiteDeploy.WorkflowSelection.UI.xaml
    ├── LiteDeploy.WorkflowSelectionDriverPicker.ps1
    ├── LiteDeploy.WorkflowSelectionDriverPicker.UI.xaml
    ├── LiteDeploy.DiskPreparation.ps1
    ├── LiteDeploy.DriverStaging.ps1
    └── LiteDeploy.OSInstallation.ps1
```

`SingleFile\` folders under Runtime components are **not** synced (reference inlined scripts only).

---

## 📋 Development Rules

1. **Category Separation**: Keep technician/host administrative scripts under `Admin/` and WinPE/target-OS runtime code under `Runtime/`.
2. **Path Agnostic**: Runtime scripts must resolve sibling scripts using `$PSScriptRoot` and the deployment share root rather than hardcoded development repository paths. Documentation examples use only generic roots (`Z:\`, `\\Server\Share$`, `E:\~LiteDeploy\`, `X:\`) — never personal profile or desktop paths.
3. **Strict Validation**: All runtime scripts must maintain `Set-StrictMode -Version 2.0` and handle single-item arrays correctly for PowerShell 5.1 compatibility.
4. **Experiments Boundary**: Prototyping and scratch work belongs in [`_Experiments`](../../_Experiments) and is not promoted to production shares.
