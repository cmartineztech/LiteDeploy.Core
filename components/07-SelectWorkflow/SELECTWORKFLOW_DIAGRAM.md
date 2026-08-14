# LiteDeploy Workflow Selection Execution and Architecture Flowchart

This document visualizes the execution lifecycle, configuration resolution, hardware discovery, user selections, validation, and result handling of **[LiteDeploy.SelectWorkFlow.ps1](LiteDeploy.SelectWorkFlow.ps1)** and **[LiteDeploy.SelecWorkflowDriverPicker.ps1](LiteDeploy.SelecWorkflowDriverPicker.ps1)**.

---

## Main execution flow

```mermaid
flowchart TD
    Start["Launch LiteDeploy.SelectWorkFlow.ps1"] --> STA{"Thread is STA?"}

    subgraph Init ["1. WinPE and UI Initialization"]
        STA -- No --> Relaunch["Relaunch powershell.exe with -STA"]
        Relaunch --> ExitOriginal["Exit original process"]
        STA -- Yes --> WPF["Load WPF assemblies and force software rendering"]
        WPF --> Alerts["Load Windows Forms alerts<br/>or enable WPF fallback"]
        Alerts --> Picker["Dot-source LiteDeploy.SelecWorkflowDriverPicker.ps1"]
    end

    subgraph Config ["2. BootConfig.json Resolution"]
        Picker --> Search["Search four paths relative to PSScriptRoot"]
        Search --> Found{"Configuration found?"}
        Found -- No --> MissingAlert["Show configuration-not-found alert"]
        MissingAlert --> Stop["Exit with failure"]
        Found -- Yes --> Parse["Read and strictly parse JSON"]
        Parse --> ValidJSON{"JSON valid?"}
        ValidJSON -- No --> InvalidAlert["Show invalid-configuration alert"]
        InvalidAlert --> Stop
        ValidJSON -- Yes --> Policy["Apply Deployment, ComputerSetup,<br/>and Drivers policy"]
    end

    subgraph Discovery ["3. Hardware and Driver Discovery"]
        Policy --> Computer["Read manufacturer and model through CIM/WMI"]
        Computer --> DriverMatch{"Matching Content\\Drivers pack exists?"}
        DriverMatch -- Yes --> LocalDriver["Select detected local driver pack"]
        DriverMatch -- No --> DriverFallback["Select online or in-box fallback"]
        LocalDriver --> Disks["Discover non-USB internal disks"]
        DriverFallback --> Disks
        Disks --> StorageCmdlets{"Get-Disk available and returns disks?"}
        StorageCmdlets -- Yes --> PartitionData["Combine readable volume free space<br/>with unallocated capacity"]
        StorageCmdlets -- No --> WMIData["Map WMI partitions to logical disks"]
        PartitionData --> Conservative["Count unreadable partitions fully as used"]
        WMIData --> Conservative
        Conservative --> Bind["Balance Capacity = Estimated Usage + Available<br/>and bind result as object array"]
        Bind --> ShowUI["Show workflow selection window"]
    end

    subgraph Interaction ["4. Technician Interaction"]
        ShowUI --> Inputs["Enter computer identity<br/>Select workflow<br/>Select disk<br/>Choose driver source"]
        Inputs --> Browse{"Select Folder clicked?"}
        Browse -- Yes --> FolderDialog["Open WPF driver path picker"]
        FolderDialog --> CustomPath["Return selected filesystem path"]
        CustomPath --> Inputs
        Browse -- No --> StartClick["Click Start Deployment"]
        Inputs --> StartClick
    end

    subgraph Validation ["5. Validation and Completion"]
        StartClick --> Validate{"All required values valid?"}
        Validate -- No --> Inline["Show fixed-position red inline errors"]
        Inline --> Dialog["Show consolidated warning dialog"]
        Dialog --> Focus["Focus first invalid control"]
        Focus --> Inputs
        Validate -- Yes --> Confirm["Show deployment summary confirmation"]
        Confirm --> Proceed{"Technician selects Yes?"}
        Proceed -- No --> Inputs
        Proceed -- Yes --> Save["Store selected values in script scope"]
        Save --> Close["Close workflow window"]
    end

    ShowUI --> Cancel["Cancel, Escape, or window close"]
    Cancel --> Close
```

---

## Driver-selection precedence

```mermaid
flowchart TD
    Start["Resolve driver choice"] --> Auto{"AutoDetectDrivers enabled?"}
    Auto -- Yes --> Detect["Look for Content\\Drivers\\Manufacturer\\Model"]
    Auto -- No --> Default["Standard Windows in-box drivers"]
    Detect --> Match{"Matching folder found?"}
    Match -- Yes --> Local["Auto-Detect local driver pack"]
    Match -- No --> Media{"Deployment.Type is Media<br/>and online download enabled?"}
    Media -- Yes --> Online["Online Download"]
    Media -- No --> Default
    Local --> Manual{"Technician selects a custom folder?"}
    Online --> Manual
    Default --> Manual
    Manual -- Yes --> Picker["Open WinPE WPF folder picker"]
    Picker --> Custom["Use selected filesystem path"]
    Manual -- No --> Selected["Keep automatically selected choice"]
```

---

## Validation state behavior

```mermaid
stateDiagram-v2
    [*] --> AwaitingInput
    AwaitingInput --> Invalid: Start Deployment with missing or invalid values
    Invalid --> AwaitingInput: Warning dialog dismissed
    Invalid --> Corrected: User completes related field or selection
    Corrected --> AwaitingInput: Inline red message is cleared
    AwaitingInput --> Confirming: All required values are valid
    Confirming --> AwaitingInput: User selects No
    Confirming --> Complete: User selects Yes
    Complete --> [*]
```

The inline validation rows have fixed height and use `Hidden` instead of `Collapsed`. This preserves layout position whether an error is visible or cleared.

---

## Configuration path priority

```text
<ScriptRoot>\..\01-Config\BootConfig.json
              ↓ if missing
<ScriptRoot>\Config\BootConfig.json
              ↓ if missing
<ScriptRoot>\BootConfig.json
              ↓ if missing
Show alert and terminate
```

This matches the resolution order used by `components\06-PreCheck\LiteDeploy.PreCheck.ps1`.
