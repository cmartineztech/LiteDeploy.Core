# LiteDeploy HostShell

Single-file PowerShell console toolkit for the **LiteDeploy** deployment
environment. Controls the classic console window that appears in **Windows PE**:
position, size, state, frame style, colors, progress display, and a
task-sequence picker.

- **One file, no dependencies** — nothing to install, nothing to import
- **Windows PE / PowerShell 5.1** compatible (also runs on pwsh 7)
- **Classic Console Host (conhost) only** — window control is not reliable
  under Windows Terminal
- Win32 interop limited to `kernel32.dll` / `user32.dll`

## Files

| File | Purpose |
|---|---|
| `LiteDeploy-HostShell.ps1` | The toolkit. This is the only file LiteDeploy needs at runtime. |
| `Start-LiteDeployShell.ps1` | Launcher: applies a named preset to its own window, then optionally runs your engine script. The WinPE entry point. |
| `Test-LiteDeployHostShell.ps1` | Manual verification harness (dev/test only — do not ship in the WinPE image). |

## Quick start

Dot-source the file once at the top of any script, then call its functions:

```powershell
. X:\LiteDeploy\LiteDeploy-HostShell.ps1

Set-HostShellTheme -Theme LiteDeploy -ClearScreen
Set-HostShellWindow -Position Top -WidthPercent 100 -HeightPercent 30 -Title "LiteDeploy"
Set-HostShellWindowStyle -WindowStyle Fixed
Write-HostShellProgress -Percent 40
```

Every function has built-in help:

```powershell
Get-Help Set-HostShellWindow -Full
```

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

### `Select-LiteDeployTaskSequence` — console task picker

Aligned table with Up/Down arrows (wrap-around), Home/End, **Enter** to
select, **Esc** to cancel. Returns the selected object, or `$null` on Escape.

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

### Launching a pre-configured window in WinPE

`powershell.exe` knows nothing about themes or geometry, so the window is
configured from *inside* the moment it opens — that is what
`Start-LiteDeployShell.ps1` does. Point `winpeshl.ini` or `startnet.cmd`
at it:

```
powershell.exe -NoExit -ExecutionPolicy Bypass -File X:\LiteDeploy\Start-LiteDeployShell.ps1 -Preset Main -Script X:\LiteDeploy\Engine.ps1
```

- Keep `-NoExit` for an interactive window; omit it when `-Script` runs
  the whole flow.
- `-Script` runs after the preset is applied — and because the launcher
  already dot-sourced the toolkit, the engine script can call every
  HostShell function directly.
- A preset failure degrades to a warning: WinPE always keeps a usable
  shell.

**Secondary windows (optional):** each PowerShell process owns its own
console window, so the engine can spawn another pre-configured window:

```powershell
Start-Process powershell -ArgumentList "-NoExit","-ExecutionPolicy Bypass","-File","X:\LiteDeploy\Start-LiteDeployShell.ps1","-Preset","Logs"
```

## Typical WinPE boot flow

```
REM startnet.cmd - one line boots a fully configured shell:
powershell.exe -NoExit -ExecutionPolicy Bypass -File X:\LiteDeploy\Start-LiteDeployShell.ps1 -Preset Main -Script X:\LiteDeploy\Engine.ps1
```

```powershell
# Engine.ps1 - the toolkit is already loaded by the launcher:
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
and sets the exit code (`0` = all 48 checks passed, `1` = failure):

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
  `Win32.LiteDeployHostShellV1`. If its declarations ever change, bump the
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
