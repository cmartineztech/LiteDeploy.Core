# LiteDeploy WinPE Deployment Share & Media Management Framework v2

A high-performance, modular PowerShell & WPF framework for Windows OS setup media ingestion, WIM edition cataloging, custom Gold Master payload management, and central `catalog.json` generation.

---

## 🌟 Architecture Overview

```
                                      ┌───────────────────────────────┐
                                      │  Windows ISO / Custom WIM     │
                                      └──────────────┬────────────────┘
                                                     │
                                                     ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                   LiteDeploy.ImportOSMedia.ps1 (Ingestion Engine)                      │
│ ┌──────────────────────────────┐  ┌───────────────────────────┐  ┌───────────────────┐ │
│ │ Get-NormalizedArchitecture   │  │ Get-SafeProp (StrictMode) │  │ Get-MediaLanguages│ │
│ └──────────────────────────────┘  └───────────────────────────┘  └───────────────────┘ │
│ ┌──────────────────────────────┐  ┌───────────────────────────┐  ┌───────────────────┐ │
│ │ 7-Zip DisplayVersion (<1ms)  │  │ Native DISM Metadata      │  │ Dynamic Lang Tag  │ │
│ └──────────────────────────────┘  └───────────────────────────┘  └───────────────────┘ │
└──────────────────────────────┬─────────────────────────────────────────────────────────┘
                               │
                               ▼
            ┌──────────────────────────────────────┐
            │ Content\OperatingSystems\<FolderName>│
            │  ├── install.wim / setup.exe         │
            │  └── os.json                         │
            └──────────────────┬───────────────────┘
                               │
                               ▼
            ┌──────────────────────────────────────┐
            │ Content\OperatingSystems\catalog.json│
            └──────────────────┬───────────────────┘
                               │
                               ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                   LiteDeploy.ImportOSMediaGUI.ps1 (WPF Frontend)                       │
│ ┌────────────────────────────────────────────────────────────────────────────────────┐ │
│ │ Region 1: Script Parameters & Elevation / STA Bootstrapper                        │ │
│ │ Region 2: Theme Design System & Color Tokens (-Theme Light / Dark)                 │ │
│ │ Region 3: Reusable XAML Generators (Get-SharedXamlResources & Viewbox Stretch=Fill) │ │
│ │ Region 4: Logging, Utility & Controller Services                                   │ │
│ │ Region 5: Control Mapping, Event Handlers & Application Launch                     │ │
│ └────────────────────────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 📦 Component Reference

### 1. `LiteDeploy.ImportOSMedia.ps1` (Ingestion & Catalog Engine)
Automates setup media ingestion, integrity verification, metadata parsing, multi-threaded payload extraction, and JSON catalog generation.

- **DISM `Languages` & `DefaultLanguageIndex` Direct Resolution**: Reads native DISM properties (`Languages : {es-ES}`, `DefaultLanguageIndex : 0`) directly from WIM image headers as well as `sources\lang.ini` to guarantee exact language detection.
- **Dynamic Multi-Language ISO Coexistence**: Automatically appends language tags to `targetFolderName` and `osId` for non-English ISOs (e.g. `win11_25H2_26200_8037_eses`), allowing multi-language ISOs of the exact same build to coexist side-by-side cleanly.
- **Focused 7-Zip Registry Extraction**: Reads `DisplayVersion` (`25H2`, `24H2`, `22H2`) via 7-Zip CLI in `<1ms` without mounting WIM; automatically resolves `7z.exe` from system PATH and standard installation paths (`C:\Program Files\7-Zip\7z.exe`). Falls back to DISM metadata if 7-Zip is unsupplied or for `.esd` files.
- **Native DISM `EditionId` Direct Extraction**: Pulls `skuCode` directly from WIM metadata (`"Professional"`, `"ProfessionalN"`, `"Core"`, `"CoreN"`, `"Enterprise"`, etc.) per index.
- **Per-Edition Complete Metadata**: Records `buildVersion`, `arch`, `defaultLanguage`, `supportedLanguages`, `createdTime`, and `modifiedTime` directly per edition inside the `editions` array.
- **Exact DISM Metadata Timestamps**: Formats `createdTime` and `modifiedTime` using raw DISM metadata datetime strings (`M/d/yyyy h:mm:ss tt`, e.g. `6/27/2026 5:53:47 PM`).
- **Guaranteed Central Catalog Existence**: Generates a valid empty `catalog.json` (`"operatingSystems": []`) if no local OS packages exist, preventing missing file errors.
- **Side-by-Side Payload Coexistence**: Appends `_custom` to folder names and `-custom` to `osId` when `-CustomWimPath` is supplied.
- **Dual Execution Mode**: Supports interactive CLI (`Out-GridView`) and headless WPF/CI-CD automation (`-SelectAllEditions`, `-SelectedIndices`, `-OSName`, `-PassThru`).

#### Parameters
| Parameter | Type | Description |
| :--- | :--- | :--- |
| `-DeploymentShare` | `[string]` *(Mandatory)* | Path to root LiteDeploy deployment share |
| `-SourcePath` | `[string]` *(Mandatory)* | Path to ISO file, drive letter (`E:`), or unpacked folder |
| `-Use7Zip` | `[switch]` | Fast <1ms `DisplayVersion` extraction via 7-Zip CLI |
| `-SevenZipPath` | `[string]` | Path to `7z.exe` (Default: Auto-detected or `C:\Program Files\7-Zip\7z.exe`) |
| `-CustomWimPath` | `[string]` | Path to custom `.wim` / `.esd` payload to replace default image |
| `-SelectedIndices`| `[int[]]` | Explicit WIM image indices to enable (e.g. `1, 6`) |
| `-SelectAllEditions`|`[switch]` | Enable all WIM editions automatically (bypasses `Out-GridView`) |
| `-OSName` | `[string]` | OS name override for Native DISM mode (bypasses `Read-Host`) |
| `-PassThru` | `[switch]` | Returns generated local OS custom object |
| `-RebuildCatalog` | `[switch]` | Rebuild central `catalog.json` from existing local `os.json` files |

---

### 2. `LiteDeploy.ImportOSMediaGUI.ps1` (WPF Frontend Importer & Catalog Manager)
Modern WPF frontend matching the design system, palette, and STA bootstrapper structure of `LiteDeploy.PreCheck.ps1`.

- **Elevation & Apartment State Bootstrapper**:
  - Programmatic UAC self-elevation (`runas`) with `-STA` and `-ExecutionPolicy Bypass`.
  - Seamless double-clicking or launching from non-administrator prompts.
- **Theme & Title Customization**:
  - Supports `-Theme Light` and `-Theme Dark` parameters (auto-detects Windows Apps system theme if omitted).
  - Supports `-WindowTitle` parameter for white-labeling.
- **Vector-Scaled Full Window Fitting (`Stretch="Fill"`)**:
  - Uses `<Viewbox Stretch="Fill">` to scale controls and typography vectorially so text and buttons look large, crisp, and prominent across screen resolutions without side padding gaps.
- **Tab 1: Import New OS Media**:
  - Form inputs with **`Clear Inputs`** footer button for fast resets.
  - Retains inputs after import completes so users can re-use or edit values easily.
  - Interactive validation and dynamic enabling/disabling of buttons.
  - Real-time execution console log box with auto-scrolling.
- **Tab 2: Manage Catalog & Payloads**:
  - DataGrid displaying package details: **`STATUS`** | **`FULL NAME`** | **`LANG`** | **`PAYLOAD TYPE`** | **`IMPORTED DATE`** | **`MEDIA ROOT FOLDER`**.
  - **Double-Click Shortcut**: Double-clicking any row opens the WIM Edition Manager.
  - **Delete OS Payload**: Permanently removes OS payload directory and rebuilds `catalog.json`.
- **Modal Dialog: WIM Edition Manager (`880x540`)**:
  - Expanded modal window displaying index-level details: **`ENABLED`** | **`INDEX`** | **`EDITION NAME`** | **`BUILD`** | **`ARCH`** | **`LANG`** | **`MODIFIED TIME`**.
  - Includes **`Select All`** and **`Deselect All`** action buttons.
  - Automatically updates `catalog.json` upon saving changes.

#### Parameters
| Parameter | Type | Description |
| :--- | :--- | :--- |
| `-DefaultDeploymentShare` | `[string]` | Initial deployment share path pre-filled in GUI |
| `-Theme` | `[string]` | Theme design system: `"Light"` or `"Dark"` (Default: Auto-detected) |
| `-WindowTitle` | `[string]` | Custom window title |
| `-DarkMode` | `[switch]` | Quick switch to force Dark theme |

---

## 🏷️ SKU Code Direct Extraction & Normalization

SKU codes are pulled directly from native DISM `EditionId` metadata (`"Core"`, `"Professional"`, `"Education"`, etc.). When raw strings require normalization, the engine maps them as follows:

| Windows Edition | Native DISM `EditionId` / SKU Code |
| :--- | :--- |
| `Windows 11 Home` | `Core` |
| `Windows 11 Home Single Language` | `CoreSingleLanguage` |
| `Windows 11 Pro` | `Professional` |
| `Windows 11 Education` | `Education` |
| `Windows 11 Pro Education` | `ProfessionalEducation` |
| `Windows 11 Pro for Workstations` | `ProfessionalWorkstation` |
| `Windows 11 Home N` | `CoreN` |
| `Windows 11 Pro N` | `ProfessionalN` |
| `Windows 11 Education N` | `EducationN` |
| `Windows 11 Pro Education N` | `ProfessionalEducationN` |
| `Windows 11 Pro N for Workstations` | `ProfessionalWorkstationN` |

---

## 🚀 Quick Start Guide

### 1. Launching the GUI (Light Theme)
```powershell
.\LiteDeploy.ImportOSMediaGUI.ps1 -Theme Light
```

### 2. Launching the GUI (Dark Theme)
```powershell
.\LiteDeploy.ImportOSMediaGUI.ps1 -Theme Dark
```

### 3. Launching with Custom Title & Deployment Share
```powershell
.\LiteDeploy.ImportOSMediaGUI.ps1 -DefaultDeploymentShare "D:\Deploy" -WindowTitle "Corporate OS Importer"
```

### 4. Importing Media via Interactive CLI
```powershell
.\LiteDeploy.ImportOSMedia.ps1 -DeploymentShare "C:\DeploymentShare" -SourcePath "E:\" -Use7Zip
```

### 5. Importing Media Headlessly (CI/CD Pipeline)
```powershell
.\LiteDeploy.ImportOSMedia.ps1 -DeploymentShare "C:\DeploymentShare" -SourcePath "C:\ISOs\Win11.iso" -Use7Zip -SelectedIndices 1,6 -PassThru
```

### 6. Rebuilding Central Catalog Only
```powershell
.\LiteDeploy.ImportOSMedia.ps1 -DeploymentShare "C:\DeploymentShare" -RebuildCatalog
```

---

## 📄 Schema Specification (`os.json` & `catalog.json`)

### Sample `os.json` (Spanish `es-ES` Payload Example)
```json
{
  "osId": "win11-26h2-es-es-26300.8772-x64",
  "fullName": "Windows 11 26H2",
  "osName": "Windows 11 26H2 (26300.8772)",
  "version": "26H2",
  "buildVersion": "10.0.26300.8772",
  "defaultLanguage": "es-ES",
  "supportedLanguages": [
    "es-es"
  ],
  "importedDate": "2026-08-10",
  "arch": "x64",
  "isCustomImage": false,
  "enabled": true,
  "mediaRoot": "Content/OperatingSystems/win11_26H2_26300_8772_eses",
  "setupPath": "Content/OperatingSystems/win11_26H2_26300_8772_eses/setup.exe",
  "imagePath": "Content/OperatingSystems/win11_26H2_26300_8772_eses/sources/install.wim",
  "editions": [
    {
      "editionId": "win11-26h2-windows-11-pro-26300.8772-x64",
      "editionName": "Windows 11 Pro",
      "skuCode": "Professional",
      "imageIndex": 6,
      "enabled": true,
      "buildVersion": "10.0.26300.8772",
      "arch": "x64",
      "defaultLanguage": "es-ES",
      "supportedLanguages": [
        "es-es"
      ],
      "createdTime": "6/27/2026 5:53:47 PM",
      "modifiedTime": "6/27/2026 6:31:58 PM"
    }
  ]
}
```
