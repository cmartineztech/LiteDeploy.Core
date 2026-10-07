# LiteDeploy.SyncComponents.ps1

**Component Name**: LiteDeploy Component Synchronization Engine  
**Component ID**: `SyncComponents`  
**Category**: Admin  
**Target Environment**: Host / Admin Workstation / CI/CD  
**Script File**: `Engine\Scripts\Admin\LiteDeploy.SyncComponents.ps1\LiteDeploy.SyncComponents.ps1`  

---

## 🎯 Purpose & Overview

During development, LiteDeploy modules live under `Engine\Scripts\Admin\` and numbered folders under `Engine\Scripts\Runtime\` (`000-LogWriter`, `010-BootInitializer`, `030-HardwarePreCheck`, and the rest of the pipeline).

In production, `SyncComponents` copies each `.ps1` (and Runtime `.xaml` UI assets) by file name into a flat `Engine\Scripts\Runtime` folder:
1. **Network deployment share**: `Z:\Engine\Scripts\Runtime\LiteDeploy.<Component>.ps1` (+ sibling `.xaml` when present)
2. **WinPE boot image**: injected under `~LiteDeploy\Scripts\` (or `Windows\System32\`)
3. **Offline media**: `E:\~LiteDeploy\Engine\Scripts\Runtime\LiteDeploy.<Component>.ps1`

`LiteDeploy.SyncComponents.ps1` automates this distribution seamlessly without manual copy-pasting or path mistakes.

---

## 🚀 Parameters

| Parameter | Type | Description |
| :--- | :--- | :--- |
| `-DeploymentShare` | String | Target root path of the deployment share (e.g. `\\Server\DeploymentShare$` or `D:\DeploymentShare`). |
| `-WinPEStagingPath` | String | Target root path of mounted WinPE image (e.g. `C:\WinPE_Build\Mount` or `C:\WinPE_Build\Staging`). |
| `-WinPEInjectionPath`| String | Subdirectory inside WinPE staging for LiteDeploy scripts (default: `~LiteDeploy\Scripts`). |
| `-MediaRoot` | String | Target root path of offline USB or ISO staging folder (e.g. `E:\`). |
| `-Clean` | Switch | Deletes old target `.ps1` / `.xaml` files before copying to prevent stale scripts. |
| `-Overwrite` | Boolean | Overwrites existing target files (default: `$true`). |
| `-Metadata` | Switch | Returns component metadata PSCustomObject for inventory queries. |

---

## 💡 Usage Examples

### 1. Sync to a Network Deployment Share
```powershell
.\LiteDeploy.SyncComponents.ps1 -DeploymentShare "\\Server01\DeploymentShare$"
```

### 2. Inject Components into a Mounted WinPE Image
```powershell
.\LiteDeploy.SyncComponents.ps1 -WinPEStagingPath "C:\WinPE_Build\Mount" -Clean
```

### 3. Sync to both Share and WinPE Builder Simultaneously
```powershell
.\LiteDeploy.SyncComponents.ps1 `
    -DeploymentShare "\\Server01\DeploymentShare$" `
    -WinPEStagingPath "C:\WinPE_Build\Mount"
```

### 4. Stage an Offline USB Media Drive
```powershell
.\LiteDeploy.SyncComponents.ps1 -MediaRoot "E:\" -Clean
```

---

## 📁 Distribution Targets Mapping

```text
Repository Layout (Dev)                              Target Layout (Production)
─────────────────────────────────────────────────   ──────────────────────────────────────────────────
Engine\Scripts\Admin\*\*.ps1       ───>  <DeploymentShare>\Engine\Scripts\Admin\*.ps1
Engine\Scripts\Runtime\*\*.ps1     ───>  <DeploymentShare>\Engine\Scripts\Runtime\*.ps1
Engine\Scripts\Runtime\*\*.xaml    ───>  <DeploymentShare>\Engine\Scripts\Runtime\*.xaml
Core Bootstrap Scripts (BootInitializer, etc)───>  <WinPEMount>\~LiteDeploy\Scripts\*.ps1
```

`SingleFile\` folders under Runtime are skipped so reference inlined scripts do not overwrite production names in flat Runtime.

**WorkflowSelection runtime siblings** (must all be present in flat `Engine\Scripts\Runtime` after sync): `LiteDeploy.LogWriter.ps1` (includes `-Level NOTICE`), `LiteDeploy.Hardware.ps1` (`Get-HardwarePhysicalDisks`), `LiteDeploy.DriverStaging.ps1`, WorkflowSelection + DriverPicker `.ps1`/`.xaml`. Prefer `-Clean` when APIs move between modules so stale copies are not left on the share.
