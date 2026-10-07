# LiteDeploy Hardware PreCheck

**ComponentId**: `HardwarePreCheck`  
**Version**: `1.0.0`  
**Target Environment**: WinPE  
**Dependencies**: `LogWriter` (optional for CMTrace), `Hardware`

WPF readiness wizard. Loads `BootConfig.json` from a mandatory path (optional in-memory `-BootConfig` for first paint), gathers inventory via [`LiteDeploy.Hardware`](../000-Hardware/README.md), runs policy/network/hardware checks, and returns a structured result to DeploymentEngine.

> For the Mermaid lifecycle diagram, see [PRECHECK_DIAGRAM.md](PRECHECK_DIAGRAM.md).

---

## Files

| Path | Role |
| :--- | :--- |
| [`LiteDeploy.HardwarePreCheck.ps1`](LiteDeploy.HardwarePreCheck.ps1) | **Production** logic — loads external markup, runs assessment, returns result |
| [`LiteDeploy.HardwarePreCheck.UI.xaml`](LiteDeploy.HardwarePreCheck.UI.xaml) | **Production** WPF markup (`{{paletteVar}}` tokens replaced at load) |
| [`SingleFile/LiteDeploy.HardwarePreCheck.ps1`](SingleFile/LiteDeploy.HardwarePreCheck.ps1) | Same logic and UI with markup **inlined** in one `.ps1` (reference only) |
| [`PRECHECK_DIAGRAM.md`](PRECHECK_DIAGRAM.md) | Execution flowchart and UI copy table |

**Production (Engine-wired):** separated `.ps1` + `.xaml` at the component root.  
**SingleFile:** side-by-side reference under `SingleFile\`. Not Engine-wired. SyncComponents skips any `SingleFile\` folder so it does not collide with the production script name in flat Runtime.

**Keep in sync:** any logic or UI change to the production split files must also be applied under `SingleFile\` (logic in the `.ps1`; markup mirrored into the inlined XAML).

---

## Contract

### Input

```powershell
# Path only (always required)
& .\LiteDeploy.HardwarePreCheck.ps1 -BootConfigPath "Z:\Config\BootConfig.json"

# Path + optional in-memory object (Engine first paint; F5 / Run Again reloads from path)
& .\LiteDeploy.HardwarePreCheck.ps1 `
    -BootConfigPath "Z:\Config\BootConfig.json" `
    -BootConfig $BootConfig
```

`-BootConfigPath` is required. DeploymentEngine passes the share/media BootConfig path (and may pass the already-loaded object).

### Output

```powershell
[PSCustomObject]@{
    Passed         = $true   # or $false if cancelled / failed
    Inventory      = $inv    # Get-HardwareInventory + Assessment + Results
}
```

Continue only closes the window. **DeploymentEngine** calls WorkflowSelection next — Precheck does not launch other phases.

### Inventory handoff

`Inventory` is built by `Get-HardwareInventory -Assessment … -Results …` so Engine can log identity and network detail without re-gathering. Important fields for logging:

| Area | Properties |
| :--- | :--- |
| Identity | `Vendor`, `Model`, `SerialNumber`, `UUID`, `AssetTag`, `IsVM` |
| Form / CPU | `Chassis`, `Architecture`, `MemoryGB`, `ProcessorName` |
| Firmware | `FirmwareType`, `SecureBootDisplay`, TPM fields |
| Network | `PrimaryNicName`, `PrimaryMacAddress`, `IPAddress`, `IPv4Cidr`, `IPv6Address`, `DnsServers`, `NICs` |
| Storage | `HardDrives` / assessment `Disks` (per-disk Number, Model, Size) |
| Precheck | `Results[]`, `Passed`, `SkippedByPolicy`, `DeploymentMode`, `NetworkPath` |

---

## Lifecycle

1. STA check (relaunch with `-BootConfigPath` preserved if needed; optional `-BootConfig` is process-local only)
2. Import `LiteDeploy.Hardware.ps1` only if not already loaded (must sit beside this script in flat Runtime / DeploymentShare layout)
3. Resolve theme: explicit `-Theme` → `BootConfig.Ui.Theme` → `Light` (peek object or path; does not consume one-shot `-BootConfig`)
4. Size window (~70% screen height, 800×600 design in Viewbox), load `LiteDeploy.HardwarePreCheck.UI.xaml`, apply theme tokens
5. Apply brand header **before** `ShowDialog` (empty XAML placeholders filled from Metadata)
6. On `ContentRendered`: run assessment; refresh device identity in header
7. Always build inventory (including SkipPreCheck bypass)
8. Return `{ Passed, Inventory }`

---

## BootConfig load rules

| Call | Source |
| :--- | :--- |
| First paint | Optional `-BootConfig` object if passed; otherwise JSON at `-BootConfigPath` |
| **F5** / **Run Again** | Always reload from `-BootConfigPath` (`-ReloadFromDisk`) |

Path stays mandatory for STA relaunch, audit footer (`Configuration: …`), and refresh.

---

## Assessment sequence

| Order | Check | Rules |
| :---: | :--- | :--- |
| 1 | Deployment Mode | From BootConfig `Deployment.Type` (`Network` / `Media`) |
| 2 | Deployment Server | SMB TCP 445 to share host (Network mode only) |
| 3 | Network Adapter | Primary NIC via Hardware (`Inventory.NICs` holds all) |
| 4 | IPv4 Address | First usable IPv4 (IPv6 shown in details when present). Soft on Media. Full addressing (CIDR / DNS) lives on Inventory for Engine logs |
| 5 | Internal Storage | One result row per non-USB disk; pass if any meets `MinDiskSizeGB` |
| 6 | System RAM | WARN if below `MinMemoryGB` (does not fail Continue) |
| 7 | BIOS Mode | UEFI OK; Legacy WARN |
| 8 | Secure Boot | UEFI only; CA display from Hardware helpers |
| 9 | TPM Status | UEFI only; WARN if missing/not ready (`RequireTPM` recorded, not enforced yet) |

### Policy bypass

If `Startup.SkipHardwarePreCheck` or `Startup.SkipPreCheck` is `$true`, mode/share checks still run (**5% → 15%**), hardware tests are skipped, progress jumps to **95%** (`Finalizing hardware details...`) while inventory is built, then **100%** with under-headline `Device PreCheck Skipped.` and banner `DEVICE PRECHECK SKIPPED BY POLICY`. Continue is enabled with `Passed = $true`.

---

## Progress milestones

Fixed UI steps (not a live work estimate). The bar stays at **95%** through TPM and inventory finalization; **100%** is applied together with the outcome banner color.

| % | Message (under headline) |
| :---: | :--- |
| 5 | Loading configuration... |
| 15 | Testing deployment source connectivity... |
| 35 | Scanning for active network hardware... |
| 55 | Awaiting IPv4 address assignment... |
| 75 | Validating internal storage and system memory... |
| 90 | Analyzing firmware and Secure Boot... |
| 95 | Evaluating TPM security status... → Finalizing hardware details... |
| 100 (Passed / Failed) | `Device PreCheck Completed.` + outcome banner |
| 100 (Skipped) | `Device PreCheck Skipped.` + banner `DEVICE PRECHECK SKIPPED BY POLICY` |

Skip path: after share check, **95%** (`Finalizing hardware details...`) → **100%** skipped messages above.

**Run Again** and **F5** restart `Invoke-HardwarePreCheck -ReloadFromDisk`: reload BootConfig from path, clear results, reset the bar to blue, set Continue to **Running...**, and restore banner `DEVICE PRECHECK IS RUNNING...`.

---

## Parameters

```powershell
param(
    [string]$BootConfigPath = "",
    [psobject]$BootConfig = $null,
    [string]$DeploymentShare = "",
    [int]$MaxNetworkWaitSeconds = 30,
    [int]$NetworkPollMilliseconds = 500,
    [int]$SmbConnectTimeoutMilliseconds = 2000,
    [int]$MinDiskSizeGB = 32,
    [int]$MinMemoryGB = 4,
    [bool]$HaltOnFailure = $true,
    [ValidateSet("Light", "Dark")][string]$Theme = "Light",
    [ValidateSet("On", "Off")][string]$TopMost = "On",
    [Alias("Metadata")]
    [switch]$GetComponentMetadata
)
```

| Parameter | Default | Description |
| :--- | :--- | :--- |
| `-BootConfigPath` | *(required)* | Full path to `BootConfig.json` |
| `-BootConfig` | `$null` | Optional in-memory BootConfig for first paint; ignored on F5 / Run Again |
| `-DeploymentShare` | `""` | Optional UNC override for SMB check; else `Deployment.NetworkPath` |
| `-MaxNetworkWaitSeconds` | `30` | DHCP / IPv4 wait budget |
| `-NetworkPollMilliseconds` | `500` | IP poll interval (UI stays pumped) |
| `-SmbConnectTimeoutMilliseconds` | `2000` | TCP 445 connect timeout |
| `-MinDiskSizeGB` | `32` | Minimum acceptable internal disk size |
| `-MinMemoryGB` | `4` | Soft RAM floor (WARN only) |
| `-HaltOnFailure` | `$true` | Disable Continue when any critical FAIL |
| `-Theme` | `"Light"` | Overrides `BootConfig.Ui.Theme` when passed explicitly |
| `-TopMost` | `"On"` | Keep window above others (cleared when opening CMD) |
| `-GetComponentMetadata` / `-Metadata` | | Return component metadata and exit |

---

## BootConfig usage

| Path | Used for |
| :--- | :--- |
| `Metadata.Name` | Header brand (`TxtBrand`); default `LiteDeploy` if missing |
| `Metadata.Environment` / `Version` | Subtitle `{Environment} Environment \| v{Version}` when Environment is set |
| *(no Environment)* | Subtitle falls back to component `Name \| v{Version}` |
| `Deployment.Type` / `NetworkPath` | Mode and SMB target |
| `Startup.SkipHardwarePreCheck` / `SkipPreCheck` | Assessment bypass |
| `ComputerSetup.RequireTPM` | Stored on inventory (`RequireTpm`); not a hard fail yet |
| `Ui.Theme` | `Light` / `Dark` when `-Theme` not passed |

---

## UI notes

Naming pattern: **Hardware PreCheck** = product/screen name (title + headline); **Device PreCheck** / **DEVICE PRECHECK** = this machine’s check status (under-headline + banners).

- Window title: `{ComponentMetadata.Name} v{ComponentMetadata.Version}` (e.g. `LiteDeploy Hardware PreCheck v1.0.0`)  
- Page headline: `Hardware PreCheck` (Title Case; not ALL CAPS)  
- Results section label: `PRECHECK RESULTS`  
- Results grid columns: **STATUS** / **CHECK** / **DETAILS** (bound to `Status`, `Check`, `Details`)  
- Header left (`TxtBrand` / `TxtSubtitle`): filled at runtime from BootConfig Metadata (XAML placeholders are empty + comment)  
- Header right: raw manufacturer `/ Model: {model}` + `Serial: {number} / SKU: {sku}` (SKU omitted when empty)  
  - While gathering: `Loading device information...`  
  - After inventory with no identity: `Device information: unavailable`  
- Results grid updates live; multi-disk shows one row per disk  
- Theme colors are baked into XAML at load (resolve theme before paint); markup is `LiteDeploy.HardwarePreCheck.UI.xaml`  
- Results grid is display-only (selection highlight styled away)  
- Footer buttons: **Open CMD**, **Run Again**, **Continue**  
  - While running: Continue shows **Running...** (disabled)  
  - Continue uses `MinWidth="110"` so the footer does not shift when the label changes  
- **F5** = **Run Again** (reload BootConfig from path + full assessment)  
- Banners (ALL CAPS):  
  - Running → `DEVICE PRECHECK IS RUNNING...`  
  - Passed → `DEVICE READY FOR IMAGE DEPLOYMENT` (green bar)  
  - Failed → `DEVICE PRECHECK FOUND ISSUES` (red bar)  
  - Skipped → `DEVICE PRECHECK SKIPPED BY POLICY`  
- Under headline at 100% (Title Case): `Device PreCheck Completed.` or `Device PreCheck Skipped.`  
- Close / Esc confirmation: `Close PreCheck and cancel this deployment?` (Yes → `Passed = $false`)

---

## Fault tolerance

1. **Close confirmation** — X / Alt+F4 / Escape asks `Close PreCheck and cancel this deployment?`; Yes sets `Passed = $false`.
2. **Software rendering** — `RenderMode = SoftwareOnly` for WinPE.
3. **Hardware import** — throws clearly if `LiteDeploy.Hardware.ps1` is missing after sync.

---

## Examples

```powershell
# Engine-style call (path only)
& "Z:\Engine\Scripts\Runtime\LiteDeploy.HardwarePreCheck.ps1" `
    -BootConfigPath "Z:\Config\BootConfig.json"

# Engine Draft-style call (path + object)
& ".\LiteDeploy.HardwarePreCheck.ps1" `
    -BootConfigPath "Z:\Config\BootConfig.json" `
    -BootConfig $BootConfig

# Force dark theme (ignores BootConfig.Ui.Theme)
& ".\LiteDeploy.HardwarePreCheck.ps1" `
    -BootConfigPath "C:\path\BootConfig.json" `
    -Theme Dark

# Metadata only
& ".\LiteDeploy.HardwarePreCheck.ps1" -Metadata
```

---

## Sync layout

After SyncComponents, flat Runtime must contain:

- `LiteDeploy.HardwarePreCheck.ps1`
- `LiteDeploy.HardwarePreCheck.UI.xaml`
- `LiteDeploy.Hardware.ps1`

`SingleFile\LiteDeploy.HardwarePreCheck.ps1` is **not** copied (folder excluded).
