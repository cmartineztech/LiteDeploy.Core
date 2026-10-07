# Deployment Share Root Template

This directory provides the initial skeleton and folder structure for a **LiteDeploy** deployment share. It can be copied or provisioned as a network SMB share (e.g. `\\Server\DeploymentShare$`) or used as an offline local deployment tree (`~LiteDeploy`).

---

## 📁 Share Directory Layout

```text
DeploymentShare\
├── Config\                       # Runtime policy & BootConfig.json
├── Content\                      # Ingested payloads to deploy
│   ├── BootMedia\
│   │   ├── ISO\                  # Bootable WinPE ISO media
│   │   └── WIM\                  # PXE / WDS Boot.wim images
│   ├── Drivers\                  # Model-specific driver packages (OEM / Custom trees)
│   │   └── LocalCatalog.json     # Catalog for WorkflowSelection / DriverStaging (Custom then OEM; ContentLocation / FileName / SHA256 / dates)
│   ├── OperatingSystems\         # Ingested Windows OS media and custom WIMs
│   │   └── catalog.json          # OS edition & payload catalog (ImportOSMedia)
│   ├── Packages\                 # Application and software packages (MSI/EXE/MSIX)
│   │   └── catalog.json          # Software package catalog
│   ├── Temp\                     # Scratch directory for staging operations
│   └── Unattend\                 # Unattend.xml answer file templates
├── Engine\                       # Execution tools and scripts
│   ├── Scripts\
│   │   ├── Admin\                # Administrative tools (SetConfig, ImportOSMedia, etc.)
│   │   └── Runtime\              # Published WinPE scripts (flat LiteDeploy.<Component>.ps1 files)
│   └── Tools\                    # External helper binaries (7-Zip, CMTrace, etc.)
├── WorkFlows\                    # Deployment sequence definitions
│   ├── Standard Workflow.json
│   └── Intune Ready Workflow.json
└── WorkLogs\                     # Diagnostic and execution logs
    ├── Admin\                    # Management and ingestion logs
    └── Deployments\              # Client machine deployment logs (isolated ACLs)
```

On a network boot this tree is the share root, mapped as `Z:\`. On media boot the same tree lives under `E:\~LiteDeploy\` (letter follows the media volume). Runtime scripts are flat files in `Engine\Scripts\Runtime\`, not the numbered repository folders.

Documentation path examples use only these generic roots (`Z:\`, `\\Server\DeploymentShare$`, `E:\~LiteDeploy\`, WinPE `X:\`) — never personal profile or desktop paths.

---

## 🏛️ Directory Roles & Architecture

| Folder | Role |
| :--- | :--- |
| **`Config`** | Stores runtime policy and configuration files (`BootConfig.json`). |
| **`Content`** | Houses all deployment payloads: OS setup media, driver packs, software installers, and boot media. |
| **`Engine`** | Contains production PowerShell scripts (`Admin`, `Runtime`) and portable command-line tools. |
| **`WorkFlows`** | Holds JSON deployment workflow definitions detailing ordered actions and package sequences. |
| **`WorkLogs`** | Central repository for deployment execution logs, segregated into administrative logs and client logs. |

---

## ⚙️ Provisioning & Permissions

- **ACL Hardening**: Use [LiteDeploy.SetDeploymentShareAcl.ps1](../Engine/Scripts/Admin/LiteDeploy.SetDeploymentShareAcl.ps1/LiteDeploy.SetDeploymentShareAcl.ps1) to apply secure SMB permissions and granular NTFS ACLs (`CREATOR OWNER` isolation on `WorkLogs\Deployments`).
- **OS Media Ingestion**: Use [LiteDeploy.ImportOSMedia.ps1](../Engine/Scripts/Admin/LiteDeploy.ImportOSMedia.ps1/LiteDeploy.ImportOSMedia.ps1) or the WPF frontend [LiteDeploy.ImportOSMediaGUI.ps1](../Engine/Scripts/Admin/LiteDeploy.ImportOSMedia.ps1/LiteDeploy.ImportOSMediaGUI.ps1) to populate `Content\OperatingSystems` and generate `catalog.json`.
- **Boot Configuration**: Use [LiteDeploy.SetConfig.ps1](../Engine/Scripts/Admin/LiteDeploy.SetConfig.ps1/LiteDeploy.SetConfig.ps1) to generate `BootConfig.json` under `Config\`.
- **Architecture Specifications**: See [`_Docs/architecture`](../_Docs/architecture) for full workflow, catalog, and deployment orchestration specifications.
