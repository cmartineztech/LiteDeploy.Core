# LiteDeploy Configuration Engine

This directory contains the configuration generator and schema definitions for the **LiteDeploy WinPE Deployment Framework**.

---

## Files Overview

| File | Description |
| :--- | :--- |
| **[LiteDeploy-SetConfig.ps1](file:///c:/Users/CMartinez/Desktop/HostShell/Config/LiteDeploy-SetConfig.ps1)** | PowerShell script to generate `BootConfig.json` for target deployment targets. |
| **[LiteDeploy-Reference.json](file:///c:/Users/CMartinez/Desktop/HostShell/Config/LiteDeploy-Reference.json)** | Consolidated JSON reference file containing master schemas for all 3 deployment modes. |
| **[BootConfig.json](file:///c:/Users/CMartinez/Desktop/HostShell/Config/BootConfig.json)** | Active configuration file consumed by `LiteDeploy-PreCheck.ps1` at boot time. |

---

## Deployment Modes

LiteDeploy supports three distinct deployment modes:

### 1. `BootWim` (PXE / Boot.wim Mode)
- **Deployment Type**: `"Network"`
- **Purpose**: Minimal configuration schema used when booting directly from WinPE (`Boot.wim` / WDS / PXE).
- **NetworkPath**: **MANDATORY** via `-NetworkPath` parameter.
- **Schema Features**: Includes only essential network boot parameters (`Type` & `NetworkPath`).

### 2. `DeploymentShare` (Network Deployment Share)
- **Deployment Type**: `"Network"`
- **Purpose**: Full network deployment configuration when connecting to a network share.
- **NetworkPath**: **MANDATORY** via `-NetworkPath` parameter.
- **Schema Features**: Includes interactive setup flags (`WorkingRootName`, `ComputerSetup`).

### 3. `Media` (Offline USB / ISO Media)
- **Deployment Type**: `"Media"`
- **Purpose**: Offline deployment from local media (USB flash drives, offline ISOs).
- **NetworkPath**: Automatically set to `null`.
- **Schema Features**: Includes interactive setup flags (`WorkingRootName`, `ComputerSetup`).

---

## Parameter Reference (`LiteDeploy-SetConfig.ps1`)

| Parameter | Type | Required? | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| **`-Mode`** | `[string]` | Optional | `'DeploymentShare'` | Mode selector (`BootWim`, `DeploymentShare`, `Media`). |
| **`-NetworkPath`** | `[string]` | **Mandatory** for `BootWim` & `DeploymentShare` | `""` | UNC Network path (e.g. `\\Server\Share$`). |
| **`-Environment`** | `[string]` | Optional | `$null` | Environment identifier (e.g. `Production`, `Dev`). |
| **`-Comment`** | `[string]` | Optional | `""` | Note added to `_Comments` field in the JSON file. |
| **`-OutputPath`** | `[string]` | Optional | `'BootConfig.json'` | Target filepath (resolves relative to caller `$PWD`). |

---

## JSON Schema Property Reference

| Property Path | Data Type | Description |
| :--- | :--- | :--- |
| **`$schemaVersion`** | `String` | Version tag for LiteDeploy engine schema (Default: `"1.0"`). |
| **`Metadata.Name`** | `String` | Application name (`"LiteDeploy"`). |
| **`Metadata.Environment`** | `String` / `null` | Target environment identifier (e.g., `"Production"` or `null`). |
| **`Metadata.Version`** | `String` | Package version (Default: `"1.0"`). |
| **`Startup.SkipPreCheck`** | `Boolean` | Hardware pre-check toggle (`true`/`false`). |
| **`Deployment.Type`** | `String` | `"Network"` or `"Media"`. |
| **`Deployment.NetworkPath`** | `String` / `null` | UNC Share path (e.g., `"\\\\Server\\Share$"` or `null`). |
| **`Deployment.WorkingRootName`** | `String` | Working root folder name (e.g., `"~LiteDeploy"`). |
| **`Deployment.ComputerSetup`** | `Object` | Object containing `PromptForComputerName` and `PromptForComputerDescription`. |
| **`_Comments`** | `String` | Optional comment or documentation string. |

---

## Quick Usage Examples

### Generate Configuration for Network Deployment Share
```powershell
.\Config\LiteDeploy-SetConfig.ps1 -Mode DeploymentShare -NetworkPath "\\Server01\DeploymentShare$" -Environment "Production"
```

### Generate Minimal Configuration for PXE / Boot.wim
```powershell
.\Config\LiteDeploy-SetConfig.ps1 -Mode BootWim -NetworkPath "\\PXEServer\Share$" -Comment "PXE Boot Setup"
```

### Generate Configuration for Offline USB Media
```powershell
.\Config\LiteDeploy-SetConfig.ps1 -Mode Media -Environment "Production" -Comment "USB Offline Media"
```
