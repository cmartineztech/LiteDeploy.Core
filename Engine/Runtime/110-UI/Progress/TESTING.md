# Progress display emulator

`Test-LiteDeployProgress.ps1` writes simulated state and launches a separate progress window.
It is a manual UI exercise, not the architecture smoke suite or an actual deployment.
Use full Windows with Windows PowerShell 5.1 and WPF; selecting WinPE_WPF only changes the
display layout and does not prove compatibility inside WinPE.

## Host script

The harness launches the active controller:

`LiteDeploy.UI.Progress.ps1` (same folder; published as `Engine\Scripts\Runtime\UI\LiteDeploy.UI.Progress.ps1`).

You can also start the controller directly with an explicit `-StatePath` as documented in [README.md](README.md).

## Parameters and effects

| Parameter | Default / meaning |
| --- | --- |
| Interactive | Shows a menu; also the default when called without arguments |
| TestMode | Interactive, FullOS_WPF, WinPE_WPF, LiveJsonSync, or TestAllMatrix |
| Theme | Light by default; Dark also accepted |
| TopMost | Off by default; On also accepted |
| WindowTitle | Empty: let the host choose its title |
| KeepOpen | Leave the successful display open |
| StepDelayMs | 800 ms between simulated updates |

The harness creates/replaces `DeploymentState.json` beside itself and launches `powershell.exe`
with a visible window. It does not run Disk or Image. Use an isolated copy for UI experiments;
do not write simulated state over a real deployment's feed. Console output and visual state
are the results; it does not certify an installation. Missing host files or process failures
can prevent the emulator from displaying anything.
