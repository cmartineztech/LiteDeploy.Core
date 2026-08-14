# LiteDeploy HostShell

Single-file PowerShell console toolkit for the **LiteDeploy** deployment
environment. Controls the classic console window that appears in **Windows PE**:
position, size, state, frame style, colors, and progress display.
The task-sequence picker lives in the companion file
`LiteDeploy-TaskSequence.ps1`.

- **One file, no dependencies** — nothing to install, nothing to import
- **Windows PE / PowerShell 5.1** compatible (also runs on pwsh 7)
- **Classic Console Host (conhost) only** — window control is not reliable
  under Windows Terminal
- Win32 interop limited to `kernel32.dll` / `user32.dll`

## Files & Deployment Location

Deployment Share Location: **`DeploymentShare\Engine\Scripts\LiteDeploy.HostShell.ps1`** (Mapped Drive: `Z:\Engine\Scripts\LiteDeploy.HostShell.ps1`)

| File | Purpose |
|---|---|
| `LiteDeploy.HostShell.ps1` | The console-window toolkit (theme, geometry, presets, progress). |
| `LiteDeploy.PreCheck.ps1` | WinPE system pre-check engine (Network, IPv4, SMB share, Storage, Firmware/Secure Boot/RAM/TPM). |
| `LiteDeploy.TaskSequence.ps1` | Task-sequence toolkit: console picker and task-sequence execution engine. Standalone. |
| `Config/LiteDeploy.SetConfig.ps1` | Configuration generator script for `BootWim`, `DeploymentShare`, and `Media` deployment modes. |
| `Config/LiteDeploy.Template.BootConfig.json` | Consolidated JSON reference schemas for all deployment modes. |
| `Config/BootConfig.json` | Active deployment configuration payload file. |
| `LiteDeploy.BootInitilizer.ps1` | WinPE initialization bootstrap script (`wpeinit.exe`, High Performance power plan, launches `LiteDeploy.PreCheck.ps1`). |

## Quick start

Dot-source the file once at the top of any script, then call its functions:

```powershell
# Load from deployment share mapped drive Z:\
. "Z:\Engine\Scripts\LiteDeploy.HostShell.ps1"

Set-HostShellTheme -Theme LiteDeploy -ClearScreen
Set-HostShellWindow -Position Top -WidthPercent 100 -HeightPercent 30 -Title "LiteDeploy"
Set-HostShellWindowStyle -WindowStyle Fixed
Write-HostShellProgress -Percent 40
```

Every function has built-in help:

```powershell
Get-Help Set-HostShellWindow -Full
```

## Configuration generator — `Config/LiteDeploy.SetConfig.ps1`

Generates target `BootConfig.json` configuration files for deployment targets (`BootWim`, `DeploymentShare`, `Media`).

### Supported Modes

| Mode | `Deployment.Type` | `Deployment.NetworkPath` | Included Schema Properties |
| :--- | :--- | :--- | :--- |
| **`BootWim`** | `"Network"` | **Mandatory** via `-NetworkPath` | Minimal schema (`Type` & `NetworkPath` only) |
| **`DeploymentShare`** | `"Network"` | **Mandatory** via `-NetworkPath` | Full schema (`LocalRootName`, top-level `Startup`, top-level `ComputerSetup`) |
| **`Media`** | `"Media"` | Automatically set to `null` | Full schema (`LocalRootName`, top-level `Startup`, top-level `ComputerSetup`) |

### Usage Examples

```powershell
# Generate Network Deployment Share configuration (BootConfig.json)
.\components\01-Config\LiteDeploy.SetConfig.ps1 -BootConfig -Mode DeploymentShare -NetworkPath "\\Server01\DeploymentShare$" -Environment "Production"

# Generate Minimal PXE / Boot.wim configuration
.\components\01-Config\LiteDeploy.SetConfig.ps1 -BootConfig -Mode BootWim -NetworkPath "\\PXEServer\Share$" -Comment "PXE Boot Setup"

# Generate Standalone Offline USB Media configuration
.\components\01-Config\LiteDeploy.SetConfig.ps1 -BootConfig -Mode Media -Environment "Production" -Comment "USB Offline Media"
```

> For full schema property details and reference templates, see **Config/README.md**.

## WinPE System Pre-Check Engine — `LiteDeploy.PreCheck.ps1`

Evaluates minimal imaging prerequisites in Windows PE prior to launching task sequences:

1. **Network Hardware**: Scans active physical network interfaces (`Get-NetAdapter` with `.NET` fallback).
2. **IPv4 Address**: Polls for DHCP/Static IPv4 assignment (filters out APIPA `169.254.x.x` and loopback).
3. **Deployment Mode**: Discovers `BootConfig.json` and identifies `Network` vs `Media (Local)`.
4. **Deployment Server**: Tests SMB TCP Port 445 connectivity *(evaluates only when `NetworkPath` is configured)*.
5. **Hard Drive Available**: Scans for internal non-USB target hard drives (`WinPE-StorageWMI` / `Win32_DiskDrive`).
6. **System RAM**: Checks physical memory capacity against minimum threshold.
7. **BIOS Mode**: Identifies UEFI vs Legacy BIOS firmware.
8. **Secure Boot & TPM**: Reports Secure Boot state (`Enabled`/`Disabled`) and TPM 2.0 presence.

### Configuration Discovery Hierarchy ("The Law")

`LiteDeploy.PreCheck.ps1` targets **`BootConfig.json`** exclusively and follows a strict discovery order:

1. **Priority 1 (WinPE RAM `X:\`)** — *Highest Priority ("The Law")*: `X:\~LiteDeploy\Config\BootConfig.json` and `X:\BootConfig.json`. If found on `X:\`, discovery stops immediately!
2. **Priority 2 (External Media Drives)**: Scans removable USB flash drives, USB SSDs/HDDs, and optical CD-ROM/DVD drives (`DriveType Removable/CD-ROM` + `BusType USB`).
3. **Priority 3 (Script Root & Working Directory)**: Fallback search in `$PSScriptRoot` and `$PWD`.

> **Internal Drive Safeguard**: Internal SATA, NVMe, and RAID target disks are **100% excluded** from discovery to prevent loading stale configuration files from old operating systems.

## Function reference

### `Set-HostShellWindow` — window state, layout, title, prompt

| Parameter | Values | Notes |
|---|---|---|
| `-Action` | `None` (default), `Minimize`, `Restore`, `Maximize`, `Hide` | Window show state |
| `-Position` | `None` (default), `Top`, `TopLeft`, `TopRight`, `Center`, `Bottom`, `BottomLeft`, `BottomRight` | Named screen anchor |
| `-WidthPercent` / `-HeightPercent` | `0`–`100` | `0` = use the fixed `-Width`/`-Height` instead |
| `-Width` / `-Height` | `300`–`4000` / `200`–`3000` | Fixed pixel size (default 1000×700) |
| `-AlwaysOnTop` | `None` (default), `On`, `Off` | Topmost z-order |
| `-Title` | string | Only changed when explicitly supplied |
| `-Prompt` | string | See prompt behavior below |

**Prompt behavior** (only when `-Prompt` is supplied):

| Value | Effect |
|---|---|
| `"."` | Restore the standard `PS C:\>` prompt |
| `""` | Clear the visible prompt |
| `"LiteDeploy> "` | Set a custom prompt |

```powershell
Set-HostShellWindow -Action Minimize
Set-HostShellWindow -Position TopLeft -WidthPercent 25 -HeightPercent 100
Set-HostShellWindow -Position Bottom -WidthPercent 60 -HeightPercent 30
Set-HostShellWindow -Title "LiteDeploy Logs" -Prompt "" -AlwaysOnTop On
```

### `Set-HostShellWindowStyle` — window frame style

| Style | Effect |
|---|---|
| `Normal` (default) | Restores the style the window had when first called in the session |
| `Borderless` | Removes the title bar and resize border |
| `Fixed` | Keeps the title bar; disables resizing and the maximize button |
| `Minimal` | Keeps the title bar; removes the minimize/maximize buttons |

```powershell
Set-HostShellWindowStyle -WindowStyle Borderless
Set-HostShellWindowStyle -WindowStyle Normal
```

### `Set-HostShellTheme` — console colors

Named themes: `LiteDeploy` (default), `Midnight`, `Slate`, `Ocean`,
`HighContrast`, `Default`. Or pass custom colors — an omitted custom color
keeps the current one.

| Switch | Effect |
|---|---|
| `-ClearScreen` | Repaints the whole console with the new colors |
| `-ShowPreview` | Prints a sample INFO/OK/WARN/ERROR block |

```powershell
Set-HostShellTheme -Theme LiteDeploy -ClearScreen -ShowPreview
Set-HostShellTheme -ForegroundColor Cyan -BackgroundColor Black -ClearScreen
```

**Adding a theme:** add one line to the `$Themes` table inside
`Get-HostShellTheme` (region 3 of the toolkit) — `Set-HostShellTheme` picks
it up automatically.

### `Write-HostShellProgress` — in-place progress bar

Repeated calls redraw on the same line. Write a final newline after the last
call to move past the bar.

| Parameter | Values | Default |
|---|---|---|
| `-Percent` | `0`–`100` (required) | — |
| `-Width` | `10`–`100` chars | `40` |
| `-CompletedColor` / `-RemainingColor` / `-TextColor` | `[ConsoleColor]` | `Green` / `DarkGray` / `Gray` |

```powershell
1..100 | ForEach-Object {
    Write-HostShellProgress -Percent $_
    Start-Sleep -Milliseconds 50
}
Write-Host   # final newline past the bar
```

## Task sequences — `LiteDeploy.TaskSequence.ps1`

The console task picker lives in its own toolkit (future home of
task-sequence features). Dot-source it separately — it is standalone and
does not require `LiteDeploy.HostShell.ps1`:

```powershell
. "Z:\Engine\Scripts\LiteDeploy.TaskSequence.ps1"
```

`Select-LiteDeployTaskSequence`: aligned table with Up/Down arrows
(wrap-around), Home/End, **Enter** to select, **Esc** to cancel. Returns
the selected object, or `$null` on Escape.

Each task-sequence object must expose: `Id`, `Name`, `Architecture`,
`Version`, `Description`, `ImagePath`, `ImageIndex` (extra properties like
`UnattendPath` are fine and carried through).

```powershell
$Selected = Select-LiteDeployTaskSequence -TaskSequences $TaskSequences -Title "Pick an image"

if ($null -eq $Selected) {
    Write-Host "Cancelled by user."
    return
}

Write-Host "Deploying $($Selected.ImagePath) index $($Selected.ImageIndex)"
```

## Presets — launch a window with a behavior bundle

A preset bundles theme + frame style + position + size + state +
always-on-top + title + prompt into one call:

```powershell
Set-HostShellPreset -Name Main
```

| Preset | What you get |
|---|---|
| `Main` | LiteDeploy theme (cleared), Fixed frame, docked top 100%×30%, always-on-top, title `LiteDeploy`, prompt `LiteDeploy> ` |
| `Full` | LiteDeploy theme (cleared), maximized, title `LiteDeploy`, prompt `LiteDeploy> ` |
| `Logs` | Midnight theme (cleared), Minimal frame, bottom strip 100%×25%, always-on-top, title `LiteDeploy Logs`, hidden prompt |
| `Picker` | Ocean theme (cleared), Fixed frame, centered 70%×70% |

Apply order is handled for you (theme → frame style → geometry, because
border changes shift the client area). **Adding a preset:** add one entry
to the table in `Get-HostShellPreset` — fields may be omitted and missing
ones are skipped.

### Typical WinPE Boot Flow

```powershell
# BootInitializer mounts deployment share Z:\ and invokes PreCheck & Engine
. "Z:\Engine\Scripts\LiteDeploy.HostShell.ps1"
. "Z:\Engine\Scripts\LiteDeploy.TaskSequence.ps1"

$Selected = Select-LiteDeployTaskSequence -TaskSequences $TaskSequences
if ($null -eq $Selected) { exit 1 }

# ... deployment steps report progress ...
Write-HostShellProgress -Percent 25
```

## Verifying the toolkit

Run the harness from one console window (conhost or WinPE — **not** Windows
Terminal). With no switches it executes **all** tests visually: the assertion
checks, then a full visual walkthrough (window docking, frame styles, theme
cycle, preset cycle, progress demo, and the picker with sample data):

```powershell
.\Test-LiteDeployHostShell.ps1
```

For unattended runs (automation, CI) use `-AssertionsOnly` — prints PASS/FAIL
and sets the exit code (`0` = all 54 checks passed, `1` = failure):

```powershell
.\Test-LiteDeployHostShell.ps1 -AssertionsOnly
```

`-DelaySeconds 1..10` controls the pause between visual steps (default `2`).

## Behavior notes

- **Strict session on dot-source:** loading the toolkit enables
  `Set-StrictMode 2.0` and `$ErrorActionPreference = "Stop"` in the calling
  session. Intentional — engine scripts should fail fast.
- **Windows Terminal:** a warning is shown when `$env:WT_SESSION` is present;
  window control APIs target conhost and misbehave under the Terminal
  pseudoconsole.
- **Add-Type versioning:** the native class is compiled once per session as
  `Win32.LiteDeployHostShellV2`. If its declarations ever change, bump the
  name (`V1` → `V2`) — `Add-Type` cannot redefine a loaded type.
- **Session state:** the original window style is captured once per session
  (`$global:HostShellOriginalWindowStyle`) so `Normal` can restore it; a
  custom prompt is held in `$global:HostShellCustomPrompt`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "No console window is attached" | Running in a host without a console (ISE, some remoting). Use conhost or WinPE. |
| Window calls do nothing visible | Windows Terminal in use — run in classic Console Host. |
| Script won't run in WinPE | Ensure the WinPE image includes the **WinPE-PowerShell** optional component and use `-ExecutionPolicy Bypass` when launching. |
