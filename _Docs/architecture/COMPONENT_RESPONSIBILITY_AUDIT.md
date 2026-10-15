# LiteDeploy Runtime Component Responsibility Audit

**Date:** 2026-10-08  
**Scope:** Runtime Architecture v2 (`Engine\Scripts\Runtime\*`)  
**Objective:** Evaluate Single Responsibility Principle adherence, detect overlapping responsibilities and duplicated logic, and verify composability without over-engineering.

---

## 1. Executive Summary

The LiteDeploy Runtime architecture implements a clean, deterministic deployment sequence:
$$\text{Boot} \longrightarrow \text{Environment} \longrightarrow \text{Hardware} \longrightarrow \text{UI (Precheck / Selection)} \longrightarrow \text{Disk} \longrightarrow \text{Image (DISM / Setup)} \longrightarrow \text{Handoff} \longrightarrow \text{Reboot}$$

### Core Architectural Strengths
- **Disk & Image Separation**: [LiteDeploy.Disk.ps1](../../Engine/Scripts/Runtime/060-Disk/LiteDeploy.Disk.ps1) exclusively formats, partitions, and labels volumes (`W:`, `S:`). [LiteDeploy.Image.ps1](../../Engine/Scripts/Runtime/080-Image/LiteDeploy.Image.ps1) applies the OS image (WIM/ESD) and writes bootloader records without altering disk geometry or partitioning.
- **Drivers & Image Separation**: [LiteDeploy.Drivers.ps1](../../Engine/Scripts/Runtime/070-Drivers/LiteDeploy.Drivers.ps1) handles model detection, SHA-256 validation against `Drivers.json`, and archive extraction into staging. It leaves offline DISM driver injection (`/Add-Driver`) to the Image component.
- **Security & Redaction**: [LiteDeploy.State.ps1](../../Engine/Scripts/Runtime/040-State/LiteDeploy.State.ps1) and [LiteDeploy.Logs.ps1](../../Engine/Scripts/Runtime/010-Logs/LiteDeploy.Logs.ps1) enforce strict property filtering and redaction routines, ensuring passwords and sensitive credentials are never written to disk or logs.
- **Path Resolution Contract**: [LiteDeploy.Environment.ps1](../../Engine/Scripts/Runtime/020-Environment/LiteDeploy.Environment.ps1) is the **only** component that normalizes Development/Production layouts and maps required component **names** to files (`Get-LiteDeployComponentPath`, `Get-LiteDeployRuntimePaths`, `Resolve-LiteDeployContentPath`). Engine declares names; Environment resolves. Missing files fail closed—no alternate-layout search, no speculative directory creation.

Canonical rule (also in [architecture v2](LITEDEPLOY_COMPONENT_REFACTOR_V2.md)):

$$\text{Engine declares names} \;\longrightarrow\; \text{Environment maps paths} \;\longrightarrow\; \text{consumers use BootObject / RuntimePaths / Resolve-LiteDeployContentPath}$$

---

## 2. Identified Responsibility Overlaps & Duplications

The audit identified **4 primary areas** where responsibilities overlap or logic is duplicated across components:

### 1. Catalog & Workflow Business Logic Duplication
- **Affected Components**: `050-Workflow` ([LiteDeploy.Workflow.ps1](../../Engine/Scripts/Runtime/050-Workflow/LiteDeploy.Workflow.ps1)) vs `110-UI\WorkflowSelection` ([LiteDeploy.UI.WorkflowSelection.ps1](../../Engine/Scripts/Runtime/110-UI/WorkflowSelection/LiteDeploy.UI.WorkflowSelection.ps1))
- **Finding**:
  - `050-Workflow` was designed as the domain component to validate and parse `catalog.json` and `WorkFlows\*.json` (`Get-LiteDeployOperatingSystemsCatalog`, `New-LiteDeployWorkflowSelectionResult`, `Save-LiteDeployWorkflowSelectionJson`).
  - `110-UI\WorkflowSelection` re-implemented and embedded identical versions of these functions directly inside the UI script to support standalone STA execution.
- **Impact**:
  - `LiteDeploy.Engine.ps1` bypasses loading `Workflow.ps1` during WinPE execution because the UI script already contains the embedded domain logic.
  - Two distinct sources of truth exist for workflow and OS catalog schema validation.

### 2. Network Reachability & TCP Probing Proliferation
- **Affected Components**: `000-Boot`, `030-Hardware`, `070-Drivers`, `110-UI\HardwarePrecheck`
- **Finding**:
  - Four independent implementations instantiate `[System.Net.Sockets.TcpClient]` to test network connectivity:
    1. **`000-Boot`** ([LiteDeploy.Boot.ps1](../../Engine/Scripts/Runtime/000-Boot/LiteDeploy.Boot.ps1)): Probes TCP 445 on the deployment share server.
    2. **`030-Hardware`** ([LiteDeploy.Hardware.ps1](../../Engine/Scripts/Runtime/030-Hardware/LiteDeploy.Hardware.ps1)): Implements `Test-LiteDeployNetworkServer` for remote server probing.
    3. **`070-Drivers`** ([LiteDeploy.Drivers.ps1](../../Engine/Scripts/Runtime/070-Drivers/LiteDeploy.Drivers.ps1)): Implements `Test-LiteDeployInternetConnection` probing `1.1.1.1:443` and `8.8.8.8:53`.
    4. **`110-UI\HardwarePrecheck`** ([LiteDeploy.UI.HardwarePrecheck.ps1](../../Engine/Scripts/Runtime/110-UI/HardwarePrecheck/LiteDeploy.UI.HardwarePrecheck.ps1)): Performs embedded TCP socket checks during pre-flight checks.
- **Impact**:
  - The `Hardware` component has assumed network application reachability responsibilities outside its primary domain of local hardware inventory (CPU, RAM, Disks, TPM, Firmware).

### 3. Share Connection Responsibility Overlap
- **Affected Components**: `000-Boot` ([LiteDeploy.Boot.ps1](../../Engine/Scripts/Runtime/000-Boot/LiteDeploy.Boot.ps1)) vs `020-Environment` ([LiteDeploy.Environment.ps1](../../Engine/Scripts/Runtime/020-Environment/LiteDeploy.Environment.ps1))
- **Finding**:
  - `LiteDeploy.Environment.ps1` defines `Connect-LiteDeployShare` and `Disconnect-LiteDeployShare` via `New-PSDrive` / `New-SmbMapping`.
  - `LiteDeploy.Boot.ps1` implements its own full WinPE network initialization, DHCP/DNS waiting, adapter binding, and SMB mount retries (`Connect-NetworkShare` / `Test-NetworkShareConnection`).
- **Impact**:
  - `Environment` functions for share connection are largely unused in the live pipeline because `Boot` owns the actual network bootstrap and transport layer.

### 4. UI Theming & Styling Fragmentation
- **Affected Components**: `110-UI\Theme` ([LiteDeploy.UI.Theme.xaml](../../Engine/Scripts/Runtime/110-UI/Theme/LiteDeploy.UI.Theme.xaml)), `110-UI\HostShell` ([LiteDeploy.UI.HostShell.ps1](../../Engine/Scripts/Runtime/110-UI/HostShell/LiteDeploy.UI.HostShell.ps1)), `110-UI\Progress` ([LiteDeploy.UI.Progress.ps1](../../Engine/Scripts/Runtime/110-UI/Progress/LiteDeploy.UI.Progress.ps1))
- **Finding**:
  - `Theme.xaml` establishes the central WPF resource dictionary for interactive screens (`HardwarePrecheck`, `WorkflowSelection`, `DriverPicker`).
  - `Progress.ps1` generates its own inline XAML and color brushes in a separate process rather than referencing `Theme.xaml`.
  - `HostShell.ps1` manages Win32 console host colors and geometry independently.
- **Impact**:
  - Styling changes in `Theme.xaml` do not propagate automatically to the progress overlay window.

---

## 3. Responsibility Matrix: Current vs. Canonical

| Component | Canonical Single Responsibility | Detected Extra / Overlapping Scope |
| :--- | :--- | :--- |
| **`000-Boot`** | WinPE bootstrap, network stack init, SMB share mounting, BootObject generation. | None (appropriately owns initial transport). |
| **`010-Logs`** | Standardized console/file logging, log synchronization. | None. |
| **`020-Environment`** | Normalize environment; component layout map; content path join; WinPE detection; process helper; theme read. | SMB helpers (`Connect-LiteDeployShare`) overlap Boot’s live mount path. |
| **`030-Hardware`** | Local hardware inventory WMI/CIM (CPU, RAM, Disks, TPM, Firmware); LiteDeploy readiness helpers. | Remote TCP probing (`Test-LiteDeployNetworkServer`) outside local inventory. |
| **`040-State`** | Deployment state lifecycle, JSON serialization, credential filtering. | None. |
| **`050-Workflow`** | Schema validation, workflow/OS catalog domain, plan resolution. | Domain helpers still duplicated inside `UI.WorkflowSelection.ps1`. |
| **`060-Disk`** | Partitioning / formatting; staging letters (`W:`, `S:`). | None. |
| **`070-Drivers`** | Model matching, SHA-256, archive staging. | Internet TCP probe; standalone ShareRoot fallback to `Z:\` (path guess). |
| **`080-Image`** | `dism.exe` / `setup.exe` apply, unattend, BCD; optional Setup LabConfig bypass. | Standalone `Get-LiteDeployImageDeploymentRoot` can walk to sibling `DeploymentShare` when BootObject/Environment are absent (path guess). Live Engine path should use BootObject + Environment only. |
| **`090-Packages`** | FullOS package ordering / execution. | None (isolated for FullOS). |
| **`100-Engine`** | Declare required names; phase orchestration; result gates. | Must not re-resolve component files outside Environment’s RequiredFiles. |
| **`110-UI`** | Interaction only; receives RuntimeFiles / DeploymentSharePath. | `WorkflowSelection` embeds catalog domain logic; may join Workflow.ps1 under share when RuntimeFiles incomplete; `Progress` does not reuse `Theme.xaml`. |

---

## 4. Path ownership assessment

| Allowed | Not allowed |
| :--- | :--- |
| Engine: `RequiredComponents = @('Logs','Disk',…)` | Engine: `Join-Path $PSScriptRoot 'LiteDeploy.Disk.ps1'` as primary resolve |
| Environment: map name → exact path; join content to DeploymentRoot | Environment: create `Content\` / `WorkFlows\` trees unsolicited |
| Image/Drivers: `Resolve-LiteDeployContentPath` / passed ShareRoot | Image/Drivers: invent layout from `$PSScriptRoot` in the Engine pipeline |
| UI: use Engine-supplied RuntimeFiles | UI: maintain a parallel path map |

**Verdict:** Roles are mostly separated (Disk / Image / Drivers / Engine). Remaining overlap is (1) Boot vs Environment share helpers, (2) Workflow domain duplicated in UI, (3) network probes scattered, (4) a few **standalone path fallbacks** that violate the Environment contract when BootObject is missing. Treat those fallbacks as authoring conveniences, not WinPE architecture.

---

## 5. Composability & Architecture Assessment

1. **No Over-Engineering**: Procedural pipeline (`Start-LiteDeployPipeline`) without a generic task framework.
2. **True Modularity**: Disk, Image, Drivers, Logs, and State stay cohesive when they consume Environment paths.
3. **Refactoring opportunities**:
   - Keep share mount in Boot; trim unused Environment SMB helpers or make Boot call Environment exclusively.
   - UI.WorkflowSelection must call Workflow domain APIs (no embedded catalog fork).
   - Remove Image/Drivers/UI path guesses from any path exercised by Engine.
   - Centralize TCP probing or confine it to Boot / Precheck.
