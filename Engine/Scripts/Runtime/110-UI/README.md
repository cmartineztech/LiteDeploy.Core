# Runtime UI

**Dev folder:** `Runtime/110-UI\<Screen>\` (repo organization only)  
**Published:** flat files under `Engine\Scripts\Runtime\UI\`

| Screen | Files |
| :--- | :--- |
| HostShell | `LiteDeploy.UI.HostShell.ps1` (console controls; no XAML) |
| Theme | `LiteDeploy.UI.Theme.xaml` |
| HardwarePrecheck | `LiteDeploy.UI.HardwarePrecheck.ps1` + `.xaml` |
| WorkflowSelection | `LiteDeploy.UI.WorkflowSelection.ps1` + `.xaml` + DriverPicker |
| Progress | `LiteDeploy.UI.Progress.ps1` (+ optional `.xaml`) |

All interactive screens honor **`-Theme Light|Dark`** from Engine / `BootConfig.Ui.Theme`.

Progress runs as a **separate STA process** (Engine keeps working), prefers RAM state map, uses `-WinPE` when Engine is in WinPE, stays open on Failed/Cancelled.

Engine supplies verified RuntimeFiles to selection screens. Standalone use requires an STA session and preloaded Environment with the selected mode. HostShell only changes the console when explicitly called.
