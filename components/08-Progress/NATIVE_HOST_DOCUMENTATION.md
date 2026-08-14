# LiteDeploy Native Progress Host Architecture & Technical Documentation

This document provides complete technical specifications, architecture diagrams, parameter reference, and deployment guidelines for the promoted **LiteDeploy Native Progress Host System** (`LiteDeploy.Progress.ps1`).

> [!NOTE]
> For dedicated WinPE Pre-Check architecture & specs, see [Pre-Check Documentation](../06-PreCheck/README.md).

---

## 🏗️ 1. System Overview & Task Sequence Runtime Integration

LiteDeploy provides a native, zero-dependency progress UI framework written entirely in PowerShell. It replaces legacy HTML Applications (`.HTA` / `mshta.exe`), Node.js, or external web browsers with a single, promoted, pure-WPF host engine: **`LiteDeploy.Progress.ps1`**.

The task sequence runtime engine (`LiteDeploy.Runtime.ps1`) consumes this progress script during execution, driving real-time UI updates via `Set-LiteDeployProgress` while persisting state updates to `DeploymentState.json` for reboot/restart recovery.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│ LiteDeploy.Runtime.ps1 (Task Sequence Runtime Engine)                                        │
│                                                                                              │
│   1. Dot-sources / Spawns LiteDeploy.Progress.ps1 -Environment [Auto|FullOS|WinPE]           │
│   2. Calls Set-LiteDeployProgress -Phase ... -Message ... -StepPercent ...                  │
│                                                                                              │
│         │                                                           │                        │
│         │ Real-Time In-Memory Update                                │ Persists Disk State    │
│         ▼                                                           ▼                        │
│ ┌───────────────────────────────┐                          ┌───────────────────────────────┐ │
│ │ Sync-LiteDeployUI           │                          │     DeploymentState.json      │ │
│ │ (Instant WPF Render)        │                          │  (Reboot Recovery Payload)    │ │
│ └───────────────────────────────┘                          └───────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 🛠️ 2. `LiteDeploy.Runtime.ps1` Integration Function (`Set-LiteDeployProgress`)

The native progress host script exports the `Set-LiteDeployProgress` function. `LiteDeploy.Runtime.ps1` calls this function during task sequence execution to update the UI instantly in memory while persisting the payload to disk.

### Function Signature
```powershell
Set-LiteDeployProgress `
    [-Message <string>] `
    [-CurrentStep <string>] `
    [-Phase <string>] `
    [-Status <string>] `
    [-StepPercent <int>] `
    [-OverallPercent <int>] `
    [-LogMessage <string>] `
    [-StepNumber <int>] `
    [-TotalSteps <int>] `
    [-ActionNumber <int>] `
    [-TotalActions <int>] `
    [-WindowTitle <string>] `
    [-StatePath <string>]
```

### Usage Example in `LiteDeploy.Runtime.ps1`
```powershell
# Dot-source the promoted native progress host script
. .\LiteDeploy.Progress.ps1 -Environment FullOS -Theme Light -WindowTitle "Enterprise Workstation Deployment"

# Action 1: Initialize Disk Setup Phase
Set-LiteDeployProgress -Phase "DiskSetup" -ActionNumber 2 -TotalActions 5 `
    -CurrentStep "Partitioning Target Disk" -Message "Configuring GPT Disk 0" `
    -StepPercent 0 -OverallPercent 20 -LogMessage "Diskpart.exe /s gpt_script.txt..."

# Action 2: Update Progress Percentage during DISM Apply-Image
Set-LiteDeployProgress -StepPercent 50 -OverallPercent 45 `
    -LogMessage "Applying image index 6 from Windows11-25H2-en-US-x64.iso..."

# Action 3: Mark Completion
Set-LiteDeployProgress -Status "Completed" -Message "Windows Setup Finished" `
    -StepPercent 100 -OverallPercent 100 -LogMessage "Rebooting system into Full OS..."
```

---

## ⚙️ 3. Promoted Host Engine Parameter Reference (`LiteDeploy.Progress.ps1`)

The promoted progress host script supports standard startup parameters:

```powershell
param(
    [string]$StatePath = ".\DeploymentState.json",
    [ValidateSet("Auto", "FullOS", "WinPE")][string]$Environment = "Auto",
    [ValidateSet("Light", "Dark")][string]$Theme = "Light",
    [ValidateSet("On", "Off")][string]$TopMost = "Off",
    [string]$WindowTitle = "",
    [switch]$ShowBackdrop,
    [switch]$KeepOpen
)
```

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `-StatePath` | String | `.\DeploymentState.json` | Path to `DeploymentState.json` state recovery file. Read on startup to restore state if resuming after a restart. |
| `-Environment` | String | `Auto` | Target layout view: `FullOS` (Dashboard Layout), `WinPE` (Enterprise Bare-Metal Layout), or `Auto` (Auto-detects from `DeploymentState.json`). |
| `-Theme` | String | `Light` | UI palette theme (`Light` or `Dark`). |
| `-TopMost` | String | `Off` | Window z-index ordering (`On` or `Off`). When `On`, stays on top of all desktop windows. |
| `-WindowTitle` | String | `""` | Optional custom title bar text for the progress host window. |
| `-ShowBackdrop` | Switch | `False` | Displays a full-screen solid backdrop overlay window behind the progress host. |
| `-KeepOpen` | Switch | `False` | Keeps the progress host window open upon deployment completion. |

---

## 📄 4. Unified State Payload Contract (`DeploymentState.json`)

The native host engine, functions, and testing emulator read and write a unified, consistent JSON state contract:

```json
{
  "windowTitle": "Enterprise Workstation Deployment",
  "productName": "LiteDeploy",
  "workflowName": "Standard Workstation Workflow",
  "environment": "FullOS",
  "status": "Running",
  "phase": "InstallWindows",
  "currentStep": "Applying Operating System",
  "message": "Installing Windows 11 Enterprise",
  "stepPercent": 100,
  "overallPercent": 50,
  "overallText": "Action 4 of 8",
  "logMessage": "Applying image index 6 from Windows11-25H2-en-US-x64.iso...",
  "computerName": "X1-DESKTOP01",
  "computerModel": "Latitude 7450",
  "operatingSystem": "Windows 11 Enterprise 25H2",
  "source": "USB Repository",
  "deploymentId": "LD-206072-001"
}
```

---

## 🧪 5. Execution Emulator & Test Suite

Use `Test-LiteDeployProgress.ps1` to test the promoted `LiteDeploy.Progress.ps1` host:

```powershell
# Interactive CLI Menu
powershell.exe -ExecutionPolicy Bypass -File .\Test-LiteDeployProgress.ps1

# Run Full Automated Matrix Emulation
powershell.exe -ExecutionPolicy Bypass -File .\Test-LiteDeployProgress.ps1 -TestMode TestAllMatrix
```
