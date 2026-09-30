# Scripts & Engine Components

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

| Component | Folder | Execution Timing & Purpose |
| :--- | :--- | :--- |
| **LogWriter** | [`Runtime/LiteDeploy.LogWriter.ps1`](Runtime/LiteDeploy.LogWriter.ps1) | Core dual-logging engine. Generates live colored console output, Microsoft CMTrace XML logs, and structured NDJSON entries. |
| **HostShell** | [`Runtime/LiteDeploy.HostShell.ps1`](Runtime/LiteDeploy.HostShell.ps1) | Manages classic WinPE console window geometry, positioning, border styles, color palettes, and shell presets. |
| **BootInitializer** | [`Runtime/LiteDeploy.BootInitilizer.ps1`](Runtime/LiteDeploy.BootInitilizer.ps1) | WinPE entry point started by `startnet.cmd`. Discovers `BootConfig.json`, tests network connectivity, authenticates and maps `Z:\`, and launches PreCheck. |
| **PreCheck** | [`Runtime/LiteDeploy.PreCheck.ps1`](Runtime/LiteDeploy.PreCheck.ps1) | 9-point hardware, firmware (UEFI/Secure Boot CA), TPM, RAM, disk, and network readiness assessment WPF wizard. |
| **DeploymentEngine** | [`Runtime/LiteDeploy.DeploymentEngine.ps1`](Runtime/LiteDeploy.DeploymentEngine.ps1) | Pipeline orchestrator. Sequences PreCheck, SelectWorkflow, and deployment execution in WinPE. |
| **Progress** | [`Runtime/LiteDeployProgress.ps1`](Runtime/LiteDeployProgress.ps1) | Zero-dependency WPF progress dashboard that renders real-time state from `DeploymentState.json` in both WinPE and FullOS phases. |

---

## 🔄 Deployment Share Mapping

When promoted to production or staged on a deployment share root (see [`DeploymentShare_Layout`](../DeploymentShare_Layout)), scripts are published into matching `Engine\Scripts` subdirectories:

```text
DeploymentShare\Engine\Scripts\
├── Admin\
│   ├── LiteDeploy.ImportOSMedia.ps1
│   ├── LiteDeploy.ImportOSMediaGUI.ps1
│   ├── LiteDeploy.SetConfig.ps1
│   └── LiteDeploy.SetDeploymentShareAcl.ps1
└── Runtime\
    ├── LiteDeploy.BootInitilizer.ps1
    ├── LiteDeploy.DeploymentEngine.ps1
    ├── LiteDeploy.HostShell.ps1
    ├── LiteDeploy.LogWriter.ps1
    ├── LiteDeploy.PreCheck.ps1
    ├── LiteDeploy.SelectWorkFlow.ps1
    ├── LiteDeploy.SelecWorkflowDriverPicker.ps1
    └── LiteDeploy.Progress.ps1
```

---

## 📋 Development Rules

1. **Category Separation**: Keep technician/host administrative scripts under `Admin/` and WinPE/target-OS runtime code under `Runtime/`.
2. **Path Agnostic**: Runtime scripts must resolve sibling scripts using `$PSScriptRoot` and the deployment share root rather than hardcoded development repository paths.
3. **Strict Validation**: All runtime scripts must maintain `Set-StrictMode -Version 2.0` and handle single-item arrays correctly for PowerShell 5.1 compatibility.
4. **Experiments Boundary**: Prototyping and scratch work belongs in [`_Experiments`](../_Experiments) and is not promoted to production shares.
