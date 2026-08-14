# LiteDeploy Native WinPE System Pre-Check Architecture & Technical Documentation

This document provides complete technical specifications, architecture diagrams, parameter references, and deployment guidelines for the **LiteDeploy Native WinPE System Pre-Check Engine** (`LiteDeploy.PreCheck.ps1`).

---

## 🏗️ 1. Architecture & Pre-Check Lifecycle

The LiteDeploy System Pre-Check engine validates device readiness, configuration policy, network connectivity, and hardware requirements in WinPE prior to launching OS image deployment. 

It is written entirely in native PowerShell and WPF, running as a zero-dependency host with Software Rendering enforced for WinPE RAMDisk environments.

> [!NOTE]
> For the complete visual execution flowchart and lifecycle diagram, see **[PRECHECK_DIAGRAM.md](PRECHECK_DIAGRAM.md)**.

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│ LiteDeploy.PreCheck.ps1 Lifecycle Pipeline                                                  │
│                                                                                             │
│  1. Check STA Apartment State  ──► (Relaunch with powershell.exe -STA if needed)             │
│  2. Force WPF Software Rendering ([RenderOptions]::ProcessRenderMode = SoftwareOnly)         │
│  3. Calculate 4:3 Window Viewbox Scaling & Apply Selected Theme (Light / Dark)              │
│  4. Paint Window UI Frame & Progress Track Instantly via Add_ContentRendered                │
│  5. Execute 8-Point Readiness Assessment & Render Real-Time Status Pill Badges               │
│  6. Evaluate Readiness Status  ──► Enable Continue / Halt Execution                          │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 📋 2. Assessment Results Sequence & Rules

Pre-Check evaluates device readiness across 9 core assessment points in strict order:

| Order | Assessment Check | Description & Evaluation Rules | Status Badges |
| :---: | :--- | :--- | :--- |
| **1** | **Deployment Mode** | Resolves deployment type (`Local (Media)` or `Network`) from `BootConfig.json`. | `OK` (Pass)<br>`FAIL` (Missing Config / Path)<br>`WARN` (Unknown Mode) |
| **2** | **Deployment Server** | Tests TCP SMB port 445 connectivity to target deployment share server. | `OK` (Reachable)<br>`FAIL` (Unreachable on Network mode)<br>*Skipped on Media mode* |
| **3** | **Network Adapter** | Scans for active physical network interfaces. | `OK` (Connected)<br>`WARN` (Missing on Media mode)<br>`FAIL` (Missing on Network mode) |
| **4** | **IPv4 Address** | Awaits valid IPv4 address assignment (ignoring APIPA `169.254.*` & loopback). Appends IPv6 when available. | `OK` (Assigned)<br>`WARN` (Unassigned on Media mode)<br>`FAIL` (Unassigned on Network mode) |
| **5** | **Internal Storage** | Scans non-USB internal storage drives against minimum size requirement (`MinDiskSizeGB`). | `OK` (Meets requirement)<br>`FAIL` (Disk smaller than minimum / Not found) |
| **6** | **System RAM** | Validates installed physical RAM capacity against minimum requirements (`MinMemoryGB`). | `OK` (Meets requirement)<br>`WARN` (Below recommended RAM) |
| **7** | **BIOS Mode** | Detects firmware environment (`UEFI` vs `Legacy BIOS`). | `OK` (UEFI)<br>`WARN` (Legacy BIOS) |
| **8** | **Secure Boot** | Queries UEFI Secure Boot state and parses UEFI `db` signature database for Microsoft 2011 & 2023 CA readiness (Evaluated on UEFI systems; omitted on Legacy BIOS). | `OK` (Enabled (2011/2023 CA Ready))<br>`OK` (Enabled (2023 CA Ready))<br>`WARN` (Enabled (2011 CA Only - BIOS Update Recommended))<br>`WARN` (Disabled) |
| **9** | **TPM Status** | Queries WMI `Win32_Tpm` and PnP device fallback for TPM version and state. Non-blocking assessment (`OK` or `WARN`). | `OK` (TPM 2.0 (Enabled))<br>`WARN` (TPM 2.0 (Disabled))<br>`WARN` (TPM 1.2 (Enabled))<br>`WARN` (Not Detected) |

---

## ⚙️ 3. Script Parameter Reference

```powershell
param(
    [string]$DeploymentShare = "",
    [int]$MaxNetworkWaitSeconds = 30,
    [int]$NetworkPollMilliseconds = 500,
    [int]$SmbConnectTimeoutMilliseconds = 2000,
    [int]$MinDiskSizeGB = 32,
    [int]$MinMemoryGB = 4,
    [bool]$HaltOnFailure = $true,
    [ValidateSet("Light", "Dark")][string]$Theme = "Light",
    [ValidateSet("On", "Off")][string]$TopMost = "On",
    [switch]$ShowBackdrop,
    [ValidateRange(0, 60)][int]$SuccessCloseSeconds = 3,
    [psobject]$BootObject = $null
)
```

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `-DeploymentShare` | String | `""` | Optional UNC path override for deployment server SMB connectivity validation. |
| `-MaxNetworkWaitSeconds` | Int | `30` | Maximum time to await valid IPv4 address assignment before timing out. |
| `-NetworkPollMilliseconds` | Int | `500` | Polling interval for checking network adapter IP assignment. |
| `-SmbConnectTimeoutMilliseconds` | Int | `2000` | Timeout threshold for testing SMB Port 445 TCP connection to deployment server. |
| `-MinDiskSizeGB` | Int | `32` | Minimum required internal hard drive capacity in GB. |
| `-MinMemoryGB` | Int | `4` | Minimum required system RAM in GB. |
| `-HaltOnFailure` | Bool | `$true` | When `$true`, disables the **Continue** button (`IsEnabled = $false`) if any critical assessment fails. |
| `-Theme` | String | `"Light"` | Visual palette theme (`Light` or `Dark`). |
| `-TopMost` | String | `"On"` | Keeps window on top of desktop windows when set to `On`. Disabled dynamically when launching CMD. |
| `-ShowBackdrop` | Switch | `False` | Displays a solid full-screen black backdrop behind the Pre-Check window. |
| `-SuccessCloseSeconds` | Int | `3` | Seconds delay before closing upon auto-success (if configured). |
| `-BootObject` | PSObject | `$null` | Discovered boot payload object returned from `Get-LiteDeployBootConfig` containing credentials, network paths, and config metadata. |

---

## 📁 4. Configuration Resolution (`BootConfig.json`)

Pre-Check resolves its configuration file relative to `$PSScriptRoot` without relying on volatile RAM (`X:\`) or drive-letter scanning:

1. `..\01-Config\BootConfig.json` (LiteDeploy Core component layout)
2. `Config\BootConfig.json`
3. `BootConfig.json`

### Policy Bypass (`SkipHardwarePreCheck`)
If `Startup.SkipHardwarePreCheck` or `Startup.SkipPreCheck` is set to `true` in `BootConfig.json`, Pre-Check displays deployment mode and server reachability, logs `Pre-Check: Bypassed via configuration` (`INFO` badge), updates the status banner to `SYSTEM PRE-CHECK BYPASSED BY POLICY`, and immediately unlocks the **Continue** button.

---

## 🔒 5. Fault Tolerance & Safety Controls

1. **Window Close Confirmation Modal**:
   If a technician attempts to close the Pre-Check window via the `X` title bar button, `Alt+F4`, or `Escape` key before continuing, a confirmation dialog appears:
   > *Are you sure you want to cancel? If you close this window, the deployment will be cancelled.*
   - Clicking **No** cancels the close request and keeps Pre-Check open.
   - Clicking **Yes** closes the window and flags deployment failure (`$global:PreCheckPassed = $false`).

2. **WinPE Software Rendering**:
   Forces `[RenderOptions]::ProcessRenderMode = SoftwareOnly` to eliminate GPU driver crashes in bare-metal WinPE RAMDisk environments.

---

## 💻 6. Execution Examples

### Standard WinPE Task Sequence Startup (Light Theme)
```cmd
cmd.exe /c powershell.exe -ExecutionPolicy Bypass -File "%SystemDrive%\Engine\Scripts\PreCheck\LiteDeploy.PreCheck.ps1" -Theme Light
```

### High-Contrast Dark Mode Execution
```cmd
cmd.exe /c powershell.exe -ExecutionPolicy Bypass -File "%SystemDrive%\Engine\Scripts\PreCheck\LiteDeploy.PreCheck.ps1" -Theme Dark -TopMost On
```
