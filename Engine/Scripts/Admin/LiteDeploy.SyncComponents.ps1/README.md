# LiteDeploy.SyncComponents.ps1

**Component Name**: LiteDeploy Component Synchronization Engine  
**Component ID**: `SyncComponents`  
**Category**: Admin  
**Target Environment**: Host / Admin Workstation / CI/CD  
**Script File**: `Engine\Scripts\Admin\LiteDeploy.SyncComponents.ps1\LiteDeploy.SyncComponents.ps1`  

---

## 🎯 Purpose & Overview

During development, LiteDeploy modules are organized by component folders under `Engine\Scripts\Admin\` and `Engine\Scripts\Runtime\`. 

In production environments, scripts must be published into flat, standardized runtime structures:
1. **Deployment Share**: `Engine\Scripts\Admin\` and `Engine\Scripts\Runtime\`
2. **WinPE Boot Image / Staging**: Injected directly into `~LiteDeploy\Scripts\` (or `Windows\System32\`)
3. **Offline Media Root**: Placed on USB root under `Engine\Scripts\Runtime\` alongside `Config\`, `Content\`, and `WorkFlows\`.

`LiteDeploy.SyncComponents.ps1` automates this distribution seamlessly without manual copy-pasting or path mistakes.

---

## 🚀 Parameters

| Parameter | Type | Description |
| :--- | :--- | :--- |
| `-DeploymentShare` | String | Target root path of the deployment share (e.g. `\\Server\DeploymentShare$` or `D:\DeploymentShare`). |
| `-WinPEStagingPath` | String | Target root path of mounted WinPE image (e.g. `C:\WinPE_Build\Mount` or `C:\WinPE_Build\Staging`). |
| `-WinPEInjectionPath`| String | Subdirectory inside WinPE staging for LiteDeploy scripts (default: `~LiteDeploy\Scripts`). |
| `-MediaRoot` | String | Target root path of offline USB or ISO staging folder (e.g. `E:\`). |
| `-Clean` | Switch | Deletes old target `.ps1` files before copying to prevent stale scripts. |
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
Core Bootstrap Scripts (BootInitializer, etc)───>  <WinPEMount>\~LiteDeploy\Scripts\*.ps1
```
