# LiteDeploy Configuration Engine

This directory contains the configuration generator and schema definitions for the **LiteDeploy WinPE Deployment Framework**.

---

## Files Overview

| File | Description |
| :--- | :--- |
| **`LiteDeploy.SetConfig.ps1`** | PowerShell script to generate `BootConfig.json` for target deployment targets. |
| **`LiteDeploy.Template.BootConfig.json`** | Consolidated JSON reference file containing master schemas for all 3 deployment modes. |
| **`BootConfig.json`** | Active configuration file consumed by `LiteDeploy.BootInitilizer.ps1` and `LiteDeploy.PreCheck.ps1` during WinPE startup. |

---

## Deployment Modes

LiteDeploy supports three distinct deployment modes:

### 1. `BootWim` (PXE / Boot.wim Mode)
- **Deployment Type**: `"Network"`
- **Purpose**: Minimal configuration schema used when booting directly from WinPE (`Boot.wim` / WDS / PXE).
- **NetworkPath**: **MANDATORY** via `-NetworkPath` parameter.
- **Schema Features**: Includes only essential network boot parameters (`Type` & `NetworkPath`). `Startup`, `ComputerSetup`, and `Drivers` sections are omitted.

### 2. `DeploymentShare` (Network Deployment Share)
- **Deployment Type**: `"Network"`
- **Purpose**: Full network deployment configuration when connecting to a network share.
- **NetworkPath**: **MANDATORY** via `-NetworkPath` parameter.
- **Schema Features**: Includes `LocalRootName`, top-level `Startup` flags (`SkipHardwarePreCheck`, `SkipHardwareRequirments`), `ComputerSetup` identity/locale flags, and `Drivers` management flags.

### 3. `Media` (Offline USB / ISO Media)
- **Deployment Type**: `"Media"`
- **Purpose**: Offline deployment from local media (USB flash drives, offline ISOs).
- **NetworkPath**: Automatically set to `null`.
- **Schema Features**: Includes `LocalRootName`, top-level `Startup` flags, `ComputerSetup` identity/locale flags, and `Drivers` management flags (including `AutoOnlineDownloadOnMedia`).

---

## Parameter Reference (`LiteDeploy.SetConfig.ps1`)

| Parameter | Type | Required? | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| **`-BootConfig`** | `[switch]` | Optional | (Active) | Switch specifying generation of BootConfig.json. |
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
| **`Deployment.Type`** | `String` | `"Network"` or `"Media"`. |
| **`Deployment.NetworkPath`** | `String` / `null` | UNC Share path (e.g., `"\\\\Server\\Share$"` or `null`). |
| **`Deployment.LocalRootName`** | `String` | Local root folder name (e.g., `"~LiteDeploy"`). Omitted in `BootWim`. |
| **`Startup`** | `Object` | Top-level startup behavior flags. Omitted in `BootWim`. |
| **`Startup.SkipHardwarePreCheck`** | `Boolean` | Hardware pre-check bypass toggle (`true`/`false`). |
| **`Startup.SkipHardwareRequirments`** | `Boolean` | Hardware requirements bypass toggle (`true`/`false`). |
| **`ComputerSetup`** | `Object` | Top-level object containing identity prompts, prefixes, length limits, and locale/time settings. Omitted in `BootWim`. |
| **`ComputerSetup.PromptForComputerName`** | `Boolean` | Interactive prompt toggle for computer name. |
| **`ComputerSetup.ComputerNamePrefix`** | `String` / `null` | Prefix string prepended to computer names (e.g., `"DESK-"` or `null`). |
| **`ComputerSetup.MaxComputerNameLength`** | `Integer` | Maximum character length limit for computer name (Default: `15`). |
| **`ComputerSetup.PromptForComputerDescription`** | `Boolean` | Interactive prompt toggle for computer description. |
| **`ComputerSetup.Language`** | `String` | System language locale code (Default: `"en-US"`). |
| **`ComputerSetup.KeyboardLocale`** | `String` | Keyboard input locale code (Default: `"0409:00000409"`). |
| **`ComputerSetup.TimeZone`** | `String` | System time zone identifier (Default: `"Eastern Standard Time"`). |
| **`Drivers`** | `Object` | Top-level object for hardware driver detection and management. Omitted in `BootWim`. |
| **`Drivers.AutoDetectDrivers`** | `Boolean` | Automatically detect Make/Model via WMI and inject matching driver pack (`true`/`false`). |
| **`Drivers.AllowManualSelection`** | `Boolean` | Allow operator/technician to manually browse or select driver pack (`true`/`false`). |
| **`Drivers.AutoOnlineDownloadOnMedia`** | `Boolean` | Automatically fetch missing driver packs from online web repository during USB media boot (`true`/`false`). |
| **`_Comments`** | `String` | Optional comment or documentation string. |

---

## Quick Usage Examples

### Generate Configuration for Network Deployment Share
```powershell
.\components\01-Config\LiteDeploy.SetConfig.ps1 -BootConfig -Mode DeploymentShare -NetworkPath "\\Server01\DeploymentShare$" -Environment "Production"
```

### Generate Minimal Configuration for PXE / Boot.wim
```powershell
.\components\01-Config\LiteDeploy.SetConfig.ps1 -BootConfig -Mode BootWim -NetworkPath "\\PXEServer\Share$" -Comment "PXE Boot Setup"
```

### Generate Configuration for Offline USB Media
```powershell
.\components\01-Config\LiteDeploy.SetConfig.ps1 -BootConfig -Mode Media -Environment "Production" -Comment "USB Offline Media"
```
