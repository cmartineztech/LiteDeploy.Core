# LiteDeploy Driver Staging

**ComponentId**: `DriverStaging`  
**Version**: `1.0.0`  
**Script File**: `Engine\Scripts\Runtime\060-DriverStaging\LiteDeploy.DriverStaging.ps1`  
**Target Environment**: WinPE-first

Importable helpers for LocalCatalog driver pack detection and media online reachability. WorkflowSelection imports this module for the Drivers UI. Pack extract / inject / online download execution are reserved for later.

## Import

```powershell
# Production (flat Runtime after SyncComponents)
Import-Module "Z:\Engine\Scripts\Runtime\LiteDeploy.DriverStaging.ps1" -Force

# Dev layout
Import-Module ".\Engine\Scripts\Runtime\060-DriverStaging\LiteDeploy.DriverStaging.ps1" -Force

Get-SystemDriverDetection -ShareRoot $shareRoot
Test-OfferOnlineDriverDownload -DeploymentType "Media" -AutoOnlineDownload $true
```

## Public helpers

| Function | Role |
|---|---|
| `Test-LiteDeployInternetConnection` | Quick TCP probe (`1.1.1.1:443` / `8.8.8.8:53`) |
| `Test-OfferOnlineDriverDownload` | Media + `AutoOnlineDownloadOnMedia` + internet |
| `Get-LiteDeployLocalDriverCatalog` | Load `Content\Drivers\LocalCatalog.json` (soft-fail) |
| `Get-SystemDriverDetection` | Custom then OEM match; in-box when no hit (`-ShareRoot`). OEM hits include pack metadata (`PackModel`, `FileName`, `SHA256`, `ReleaseDate`, `DownloadedOn`, `SourceKind`, `IsOem`) for the WorkflowSelection Info dialog |
| `Resolve-DriverPackHit` / `New-DriverPackHit` | Dell/Lenovo Content (BFS depth 10) vs `FileName`+SHA256; Custom scan (depth 5); HP Content; catalog details always attached |
| `Test-DriverFolderHasDriverFiles` | BFS for `.inf` / `.sys` / `.cat` (default depth 10; Custom resolve uses depth 5) |
| `New-InBoxDriverDetection` | Standard OS In-Box Drivers result object |
| Match helpers | Manufacturer / SKU (PadLeft) / Model / SystemSKU list presence |

## Match order

1. Custom: Make + Model + SKU  
2. Custom: Make + SKU  
3. Custom: Make + Model (packs without `SystemSKU`)  
4. OEM: manufacturer key → SKU → Model (packs without `SystemSKU`)  

Missing/invalid catalog or no match → Standard OS In-Box Drivers (soft-fail).

**Logs:** INFO `Driver catalog loaded.` when `LocalCatalog.json` parses; SUCCESS `Driver pack: {MatchBy} | Content|Archive | {PackModel}` only on a match. No log when there is no match.

## Dependencies

Flat Runtime beside this script after SyncComponents:

- `LiteDeploy.LogWriter.ps1`
- `LiteDeploy.Hardware.ps1`

## Sync layout

```text
Engine\Scripts\Runtime\LiteDeploy.DriverStaging.ps1
```

Must be published beside `LiteDeploy.WorkflowSelection.ps1` (and LogWriter / Hardware). Missing file → WorkflowSelection throws at import; unhandled errors are paused by BootInitializer with `[NOTICE]` / `startnet`.

## Path examples

Document only generic roots: `Z:\` (mapped share), `\\Server\Share$`, media `E:\~LiteDeploy\`, WinPE `X:\`. Do not use personal profile or workstation paths in docs.

## Not yet implemented

- Extract vendor `.exe` packs in WinPE (prefer short staging root when implemented)  
- Copy/inject drivers onto the OS volume  
- Perform online driver pack download  
