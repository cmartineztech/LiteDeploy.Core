# WorkflowSelection and DriverPicker flow

Source: [controller](../LiteDeploy.UI.WorkflowSelection.ps1),
[view](../LiteDeploy.UI.WorkflowSelection.xaml), and
[picker](../LiteDeploy.UI.WorkflowSelectionDriverPicker.ps1).
Published location: `Engine\Scripts\Runtime\UI`.

```mermaid
flowchart TD
    Input["Engine supplies configuration, source root, RuntimeFiles, and theme"] --> STA["Use the existing STA session"]
    STA --> Helpers["Reuse Logs, Hardware, Drivers; import only missing helpers"]
    Helpers --> Picker["Load DriverPicker once from its named path"]
    Picker --> View["Load RuntimeFiles.WorkflowSelectionView"]
    View --> Config["Read initial configuration and apply policies"]
    Config --> Data["Read hardware, disk choices, OS catalog, and driver matches"]
    Data --> Screen["Technician reviews computer, workflow, disk, and driver choices"]
    Screen -- Browse --> Browse["Open picker with RuntimeFiles.DriverPickerView"]
    Browse --> Folder["Validate selected folder and driver files"]
    Folder --> Screen
    Screen -- "Refresh Disks" --> Disks["Refresh disks while preserving other selections"]
    Disks --> Screen
    Screen -- F5 --> Reload["Reload configuration and refresh choices"]
    Reload --> Config
    Screen -- "Start Deployment" --> Valid{"Required values valid?"}
    Valid -- No --> Screen
    Valid -- Yes --> Confirm{"Technician confirms?"}
    Confirm -- No --> Screen
    Confirm -- Yes --> Save["Save WorkflowSelection.json on system drive"]
    Save --> Result["Return Passed, effective BootConfig and named selection fields"]
    Screen -- "Confirmed cancel" --> Cancel["Return Passed=false"]
    Result --> Engine["Engine adopts returned config, revalidates ImageEngine and confirmed disk"]
    Engine --> Next["After valid confirmation create share logs; Progress, then Disk"]
    Cancel --> Stop["Engine stops"]
```

Returned fields include ComputerName, WorkflowName, WorkflowTag, TargetDiskIndex,
DriverFolderPath, DeploymentUid, and SelectionJsonPath. The JSON location is based on
the system drive, typically `X:\WorkflowSelection.json` in WinPE.

Driver selection records the chosen source. It does not establish that drivers were installed.
The picker validates folders and looks for driver files before returning a path. It is loaded
once per screen; Browse does not repeatedly import it. Reopen the screen to load edited code.

Standalone use requires an STA session and preloaded Environment when RuntimeFiles is omitted.
The legacy non-STA relaunch does not preserve the in-memory Environment/file map. Use the
documented STA entry point. Actual WPF behavior still needs testing in the target boot image.


Engine assigns DeploymentUid before this screen opens. DriveSelection=false requires Disk 0; otherwise the UI supplies the selected disk. Engine adopts the returned effective configuration after confirmation. Policy/confirmed-target disagreement stops before destructive work.

