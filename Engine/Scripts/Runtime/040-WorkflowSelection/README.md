# LiteDeploy WinPE Workflow Selection UI

Technician selection wizard after Hardware PreCheck.

> Visual flow: **[SELECTWORKFLOW_DIAGRAM.md](SELECTWORKFLOW_DIAGRAM.md)**.

---

## Files

| Path | Role |
| :--- | :--- |
| [`LiteDeploy.WorkflowSelection.ps1`](LiteDeploy.WorkflowSelection.ps1) | **Production** logic — loads external markup, policies, validation, result |
| [`LiteDeploy.WorkflowSelection.UI.xaml`](LiteDeploy.WorkflowSelection.UI.xaml) | **Production** main wizard markup (`{{paletteVar}}` tokens replaced at load) |
| [`LiteDeploy.WorkflowSelectionDriverPicker.ps1`](LiteDeploy.WorkflowSelectionDriverPicker.ps1) | **Production** `Show-DriverPathDialog` logic |
| [`LiteDeploy.WorkflowSelectionDriverPicker.UI.xaml`](LiteDeploy.WorkflowSelectionDriverPicker.UI.xaml) | **Production** picker markup (same token pattern) |
| [`SingleFile/LiteDeploy.WorkflowSelection.ps1`](SingleFile/LiteDeploy.WorkflowSelection.ps1) | Inlined main UI + logic (reference only) |
| [`SingleFile/LiteDeploy.WorkflowSelectionDriverPicker.ps1`](SingleFile/LiteDeploy.WorkflowSelectionDriverPicker.ps1) | Inlined picker UI + logic (reference only) |
| [`SELECTWORKFLOW_DIAGRAM.md`](SELECTWORKFLOW_DIAGRAM.md) | Mermaid execution / driver / validation diagrams |

**Production (Engine-wired):** separated `.ps1` + `.xaml` at the component root (same pattern as Hardware PreCheck).  
**SingleFile:** side-by-side reference under `SingleFile\`. Not Engine-wired. SyncComponents skips any `SingleFile\` folder so inlined scripts do not overwrite production names in flat Runtime. SingleFile still **imports** flat/sibling `LogWriter`, `Hardware`, and `DriverStaging` (detection/disk helpers are not inlined).

**Keep in sync:** any logic or UI change to the production split files must also be applied under `SingleFile\` (logic edits in the `.ps1`; markup edits mirrored into the inlined XAML). Treat SingleFile as a second deliverable, not a stale snapshot.

**Runtime dependencies (flat after SyncComponents):** `LiteDeploy.LogWriter.ps1`, `LiteDeploy.Hardware.ps1` (incl. `Get-HardwarePhysicalDisks`), `LiteDeploy.DriverStaging.ps1`, plus WorkflowSelection `.ps1`/`.xaml` and DriverPicker `.ps1`/`.xaml`. Unhandled throws bubble to BootInitializer, which logs `[NOTICE]` and prompts `startnet`.

Both production scripts and both `.xaml` files must stay together under `Engine\Scripts` after SyncComponents.

---

## Contract

| Parameter | Required | Notes |
| :--- | :--- | :--- |
| `-BootConfigPath` | Yes | Path to `BootConfig.json` (STA relaunch / F5 / audit). |
| `-BootConfig` | No | In-memory object for first paint only; F5 always reloads from path. |
| `-DeploymentSharePath` | Yes | Share/media root (`Root` / `DeploymentRoot` aliases). Catalog + drivers. |
| `-DeploymentUid` | No | Session ID (`yyMMdd-XXXX` from Engine `Get-LiteDeployUid`). Footer display. |
| `-Theme` | No | `Light` / `Dark`; else `Ui.Theme` / Light. |

**Return** (confirm → also writes `%SystemDrive%\WorkflowSelection.json`, typically `X:\WorkflowSelection.json`)

| Outcome | Result |
| :--- | :--- |
| Confirm | `Passed=$true`, `Status=Confirmed`, selection fields below |
| Cancel / Esc / X | `Passed=$false`, `Status=Cancelled`, no JSON |
| Fail | `Passed=$false`, `Status` set (e.g. `XamlError`, `SaveFailed`) |

Current confirm fields:

| Property | Notes |
| :--- | :--- |
| `DeploymentUid` | Session ID from Engine |
| `BootConfigPath` / `DeploymentSharePath` | Paths used by the wizard |
| `ComputerName` / `ComputerDescription` | Identity prompts |
| `WorkflowName` / `WorkflowTag` | Catalog selection (`WorkflowTag` carries image index / paths) |
| `TargetDiskIndex` / `TargetDiskModel` | Wipe target |
| `DriverFolderPath` / `AutoDetectDrivers` | Resolved driver source path (folder or OEM `.exe`) |

**Planned enrichments** (for Engine / DriverStaging continue): last effective `BootConfig` object (`$script:bootConfig` after F5), structured `Drivers` metadata (`Source`, `SourceKind`, `MatchBy`, `FileName`, `SHA256`, `PackModel`, `IsOem`). Prefer returning the in-memory BootConfig snapshot so Phase 3+ matches what the technician confirmed.

Standalone (use share/media roots — do not document personal machine paths):

```powershell
& .\LiteDeploy.WorkflowSelection.ps1 `
    -BootConfigPath "Z:\Config\BootConfig.json" `
    -DeploymentSharePath "Z:" `
    -DeploymentUid "260806-A3F1"
```

---

## BootConfig properties consumed

| JSON property | Default | Behavior |
| :--- | :--- | :--- |
| `Metadata.Name` / `Environment` / `Version` | — | Brand header + subtitle (component fallback). |
| `Deployment.Type` | `Media` | Media vs Network; online driver option. |
| `ComputerSetup.PromptForComputerName` | `true` | Show/hide name field. |
| `ComputerSetup.ComputerNamePrefix` | Empty | Prefill when name box empty. |
| `ComputerSetup.MaxComputerNameLength` | `15` | Cap (never above 15). |
| `ComputerSetup.PromptForComputerDescription` | `true` | Show/hide description field. |
| `ComputerSetup.DriveSelection` | `true` | Show disk picker, or hide + auto-pick first internal disk. |
| `ComputerSetup.ImageEngine` | `"Setup.exe"` | Consumed later by Engine / OS install. |
| `Drivers.AutoDetectDrivers` | `true` | Via imported [`LiteDeploy.DriverStaging`](../060-DriverStaging): match `Content\Drivers\LocalCatalog.json` only (paths from catalog fields). Custom (Make+Model+SKU) → Custom (Make+SKU) → Custom (Make+Model) → OEM Make then SKU then Model. Model-only matches skip packs that declare `SystemSKU`. Dell/Lenovo: `ContentLocation` if extracted + `.inf`/`.sys`/`.cat` within 10 levels; else archive beside Content (`FileName` + SHA256 when present). Custom: model root depth 5. HP/others: extracted Content folder. Missing catalog / no match → in-box (wizard continues). Detection logs: INFO when catalog loads; SUCCESS only on match. |
| `Drivers.AllowManualSelection` | `true` | Combo + Browse. |
| `Drivers.AutoOnlineDownloadOnMedia` | `true` | Offer online download when Media **and** internet is reachable; checkbox and “Download latest driver pack” dropdown item are hidden otherwise. Re-checked on F5. |
| `Ui.Theme` | `"Light"` | Light / Dark palette. |

---

## UI sections

### Header (PreCheck chrome)

- Brand / subtitle from Metadata
- Device identity: raw manufacturer `/ Model: …`, then `Serial: … / SKU: …` (SKU omitted when empty)
- Window title: `{ComponentMetadata.Name} v{Version}`

### Computer Identification

- **Left:** computer name / description (right-aligned labels). Policy can hide either or both.
- **Right:** firmware snapshot (always visible): BIOS mode, Secure Boot, TPM, BIOS version/date (Legacy → `N/A` for Secure Boot / TPM).

When **both** name and description prompts are off, firmware expands full width.

### Deployment workflow

From `Content\OperatingSystems\catalog.json` on `-DeploymentSharePath`.

### Target hard drive

Rows from `Get-HardwarePhysicalDisks` (Capacity / Used / Free; 0 GB disks are shown). **Continue** blocks via `Test-HardwareDiskSelectionHasCapacity` when the selected disk is under 1 GB. UI wiring (auto-select, Refresh Disks) stays here.

| `DriveSelection` | UI |
| :--- | :--- |
| `true` | Disk grid + **Refresh Disks** |
| `false` | Hidden; first internal disk auto-selected |

### Drivers

Detected LocalCatalog pack (`Get-SystemDriverDetection` from DriverStaging) → online (Media + internet via `Test-OfferOnlineDriverDownload`) → in-box. Online is omitted from the combo when offline. Detected packs: Custom shows the full relative path (`Detected pack: Content\Drivers\Custom\FolderName`); OEM truncates long paths (`Detected pack: Content\Drivers\LENOVO\...filename.exe`, max ~64 chars with `...`). **Info** (beside the combo) opens pack details (model, match, file name, SHA256, release/downloaded dates, source, full path) for OEM Content or Archive only - not Custom/in-box/browse. **Browse…** opens DriverPicker (`Show-DriverPathDialog` + `LiteDeploy.WorkflowSelectionDriverPicker.UI.xaml`); Select confirms a folder with at least one `.inf`/`.sys`/`.cat` within 8 levels.

### Footer

`Configuration: …` and `Deployment ID: {DeploymentUid}`.

---

## Refresh behavior

| Action | Effect |
| :--- | :--- |
| **Refresh Disks** | Rediscover disks only. |
| **F5** | Reload BootConfig from path; refresh brand, ComputerSetup UI flags, DriveSelection, catalog, disks, drivers, firmware. |

---

## Driver picker

Themed Viewbox dialog; **DeploymentShare (Z:)** last, rooted at `Content\Drivers`; live Select disable for drive roots / Windows / share Drivers root; BFS depth 8 for `.inf`/`.sys`/`.cat`.

Caller:

```powershell
. (Join-Path $PSScriptRoot "LiteDeploy.WorkflowSelectionDriverPicker.ps1")
Show-DriverPathDialog -Theme $Theme -DeploymentSharePath $script:DeploymentSharePath -Owner $window
```

---

## WinPE

Optional components: WinPE-WMI, WinPE-NetFX, WinPE-PowerShell, WinPE-StorageWMI.  
Adaptive sizing + `Viewbox`. Software rendering forced.

---

## Maintenance notes

Appropriately complex: Engine contract, F5 vs Refresh Disks, ComputerSetup/`DriveSelection`, firmware card, catalog tree, DriverPicker for WinPE.

Follow-ups: dedupe F5 vs init policy helpers; enrich confirm return with last `BootConfig` + structured `Drivers` pack metadata. Disk free-space discovery lives in Hardware (`Get-HardwarePhysicalDisks`).

**Path examples in docs** use only generic roots (`Z:\`, `\\Server\Share$`, media `E:\~LiteDeploy\`, WinPE `X:\`). Do not document personal profile or workstation paths.
