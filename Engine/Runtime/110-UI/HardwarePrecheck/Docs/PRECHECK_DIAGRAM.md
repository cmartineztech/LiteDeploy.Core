# HardwarePrecheck flow

Source: [controller](../LiteDeploy.UI.HardwarePrecheck.ps1) and
[view](../LiteDeploy.UI.HardwarePrecheck.xaml).
Published location: `Engine\Scripts\Runtime\UI`.

```mermaid
flowchart TD
    Input["Engine: BootConfigPath, BootConfig, RuntimeFiles, Theme"] --> STA["Run in the existing STA session"]
    STA --> Paths["Use RuntimeFiles.Hardware and HardwarePrecheckView"]
    Paths --> Load["Reuse Hardware functions; import only if absent"]
    Load --> View["Resolve theme, load named XAML, show screen"]
    View --> Config["Use supplied BootConfig initially; otherwise read configured path"]
    Config --> Policy{"Policy skips checks?"}
    Policy -- Yes --> Inventory["Collect inventory and show skipped result"]
    Policy -- No --> Assess["Assess deployment mode, network, disks, RAM, firmware, Secure Boot, TPM"]
    Assess --> Evaluate["Evaluate results using configured policy"]
    Evaluate --> Wait["Show readiness; enable Continue when permitted"]
    Inventory --> Wait
    Wait -- "F5 or Run Again" --> Reload["Reload configuration from BootConfigPath"]
    Reload --> Config
    Wait -- Continue --> Pass["Return Passed=true and Inventory"]
    Wait -- "Confirmed cancel" --> Cancel["Return Passed=false and Inventory"]
    Pass --> Engine["Engine validates result before selection"]
    Cancel --> Stop["Engine stops deployment"]
```

Standalone use must start in Windows PowerShell 5.1 with `-STA` and preload Environment
with the correct mode when RuntimeFiles is omitted. The controller retains a legacy non-STA
relaunch path, but that child does not preserve the in-memory Environment or RuntimeFiles;
do not rely on it for this configuration. Engine enforces STA before launching screens.

An empty result is not a successful precheck. Engine requires an explicit boolean Passed.
Engine's SkipPreCheck bypasses the whole screen; the screen's policy bypass still gathers
inventory. F5 is an explicit configuration refresh, not component-path discovery.

This is the code's execution flow, not proof of WPF support in a standard WinPE image.
