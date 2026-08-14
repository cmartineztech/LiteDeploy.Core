# LiteDeploy WinPE Workflow Selection UI — Technical Documentation

This folder contains the native PowerShell and WPF interface used to collect deployment choices after the LiteDeploy system pre-check completes.

The primary interface is **[LiteDeploy.SelectWorkFlow.ps1](LiteDeploy.SelectWorkFlow.ps1)**. The companion **[LiteDeploy.SelecWorkflowDriverPicker.ps1](LiteDeploy.SelecWorkflowDriverPicker.ps1)** script provides the WinPE-compatible driver-folder browser.

> [!NOTE]
> For the visual execution and validation flow, see **[SELECTWORKFLOW_DIAGRAM.md](SELECTWORKFLOW_DIAGRAM.md)**.

---

## 1. Architecture and lifecycle

The workflow selection stage gathers four categories of deployment data:

1. Computer identity
2. Operating-system workflow
3. Target physical disk
4. Driver source

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ LiteDeploy.SelectWorkFlow.ps1                                            │
│                                                                          │
│  STA validation and WinPE software rendering                             │
│              │                                                           │
│              ▼                                                           │
│  Resolve and parse BootConfig.json                                       │
│              │                                                           │
│              ▼                                                           │
│  Apply ComputerSetup, Deployment, and Drivers policies                   │
│              │                                                           │
│              ▼                                                           │
│  Detect hardware, driver pack, and internal disks                        │
│              │                                                           │
│              ▼                                                           │
│  Collect technician selections                                           │
│              │                                                           │
│              ▼                                                           │
│  Validate required values → confirm deployment → close UI                │
└──────────────────────────────────────────────────────────────────────────┘
```

The interface uses WPF with software rendering to reduce display-driver dependencies in WinPE. Windows Forms is used for validation alerts when available, with a WPF message-box fallback for minimal WinPE images.

---

## 2. Files

| File | Purpose |
| :--- | :--- |
| `LiteDeploy.SelectWorkFlow.ps1` | Main workflow, computer, disk, and driver-selection UI. |
| `LiteDeploy.SelecWorkflowDriverPicker.ps1` | Reusable WPF folder-selection dialog used by **Select Folder**. |
| `SELECTWORKFLOW_DIAGRAM.md` | Mermaid execution and decision-flow diagrams. |
| `bk/` | Historical or experimental copies; not part of the active workflow. |

The main script dot-sources the picker using `$PSScriptRoot`, so the two active scripts must remain in the same directory.

---

## 3. Configuration resolution

The UI resolves `BootConfig.json` in the same priority order as `LiteDeploy.PreCheck.ps1`:

1. `..\01-Config\BootConfig.json`
2. `Config\BootConfig.json`
3. `BootConfig.json`

All paths are relative to `$PSScriptRoot`; the current PowerShell working directory is not used. The first existing file wins.

JSON parsing is strict. A missing or invalid configuration displays an alert and terminates the workflow UI rather than continuing with an unknown deployment policy.

### Consumed configuration properties

| JSON property | Default | UI behavior |
| :--- | :--- | :--- |
| `Deployment.Type` | `Media` | Controls media/network behavior and online driver availability. |
| `ComputerSetup.PromptForComputerName` | `true` | Shows or hides the computer-name input. |
| `ComputerSetup.ComputerNamePrefix` | Empty | Prepopulates the computer-name input. |
| `ComputerSetup.MaxComputerNameLength` | `15` | Sets input length and validation limit. |
| `ComputerSetup.PromptForComputerDescription` | `true` | Shows or hides the description input. |
| `Drivers.AutoDetectDrivers` | `true` | Enables manufacturer/model driver-pack detection. |
| `Drivers.AllowManualSelection` | `true` | Enables the driver dropdown and **Select Folder** button. |
| `Drivers.AutoOnlineDownloadOnMedia` | `true` | Makes online driver download available in Media mode. |

---

## 4. User-interface sections

### Computer Identification

The section is driven by `ComputerSetup` policy. Computer names are validated for:

- Required input when prompting is enabled
- Configured maximum length
- Spaces and invalid Windows computer-name characters

### Deployment Workflow

The current UI exposes these workflow tags:

| Displayed workflow | Tag |
| :--- | :--- |
| Windows 11 Enterprise | `W11-ENT-STD` |
| Windows 11 Professional | `W11-PRO-STD` |
| Windows 11 Enterprise Autopilot | `W11-ENT-AP` |
| Windows 11 Professional Autopilot | `W11-PRO-AP` |

Parent categories automatically redirect selection to their first child so only deployable workflow entries are accepted.

### Target Hard Drive

Disk discovery follows this order:

1. `Get-Disk` and `Get-Partition`, when the Storage module is available
2. `Win32_DiskDrive` through WMI as a WinPE fallback

USB and removable disks are excluded. Results are always converted to an `object[]` before DataGrid binding, preventing the single-disk `ItemsSource` failure that can occur on physical hardware.

Space is calculated conservatively:

- Readable volumes contribute their actual filesystem free space.
- Unallocated disk capacity counts as available.
- Locked, RAW, hidden, damaged, or otherwise unreadable partitions count fully as used.
- If neither Storage cmdlets nor WMI can measure a disk, all capacity is treated as used rather than overstating free space.

The display is calculated so `Capacity = Estimated Usage + Available Space` after rounding. Unreadable partitions are counted fully as used, so **Estimated Usage** indicates potential data presence rather than guaranteed user-file usage.

Zero-capacity devices and sample/fabricated disks are not shown. If no internal disk is detected, deployment is blocked and the technician is instructed to load the required storage driver and refresh.

### Drivers and Hardware Injections

Automatic driver detection uses:

```text
Content\Drivers\<Normalized Manufacturer>\<WMI Model>
```

Manufacturer values are normalized for Dell, HP, and Lenovo. Driver choice precedence is:

1. Detected local driver pack
2. Online download in eligible Media deployments
3. Standard Windows in-box drivers

The **Select Folder** action opens the companion WPF picker. A custom selection is stored as the actual filesystem path rather than the `Custom:` display label.

---

## 5. Validation and interaction behavior

Clicking **Start Deployment** validates all required inputs and shows:

- Red inline messages in fixed-height reserved rows
- One consolidated Windows Forms warning dialog
- A WPF warning fallback when Windows Forms is unavailable

Reserved rows use `Visibility="Hidden"` rather than `Collapsed`, so validation messages do not move surrounding controls. Inline errors clear when the technician corrects the computer name, selects a workflow, or selects a disk.

The selected disk remains blue with white text after the DataGrid loses keyboard focus.

If validation succeeds, a confirmation dialog summarizes the computer name, workflow, disk, and driver choice before closing the window.

---

## 6. Result variables

After a successful confirmation, the main script stores the following script-scoped values for the next deployment stage:

| Variable | Contents |
| :--- | :--- |
| `$script:ComputerName` | Validated computer name. |
| `$script:ComputerDescription` | Optional technician-entered description. |
| `$script:SelectedWorkflowTag` | Stable workflow identifier. |
| `$script:SelectedOSName` | Selected workflow display name. |
| `$script:SelectedDiskIndex` | Display disk index, such as `Disk 0`. |
| `$script:SelectedDiskModel` | Detected disk model. |
| `$script:AutoDetectDrivers` | Effective automatic-detection policy. |
| `$script:SelectedDriverFolderPath` | Custom/detected path or built-in/online driver choice. |

These values currently live in the script scope. A caller that launches the script in a separate `powershell.exe` process must use an agreed handoff mechanism if it needs to consume them after the process exits.

---

## 7. Driver picker reference

`Show-DriverPathDialog` accepts:

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `-Theme` | `Light` or `Dark` | `Light` | Applies the picker color palette. |
| `-WindowTitle` | String | `Select Driver Folder` | Dialog title. |
| `-InitialPath` | String | Empty | Selects the matching root drive when possible. |
| `-Owner` | WPF Window | None | Centers the picker over the main UI. |

The picker enumerates ready fixed, removable, and network drives and lazily loads subdirectories when a node is expanded. Access-denied or unavailable directories are left empty instead of terminating the UI.

---

## 8. WinPE requirements and scaling

Recommended WinPE optional components:

- WinPE-WMI
- WinPE-NetFX
- WinPE-PowerShell
- WinPE-StorageWMI

The primary window currently uses a fixed `1024 × 820` WPF size with `ResizeMode="NoResize"`. Unlike the PreCheck UI, it does not yet calculate its size from the physical screen or wrap its design surface in an outer `Viewbox`. It can therefore be clipped at low resolution or high DPI.

The folder picker uses a fixed `440 × 480` window.

---

## 9. Execution examples

### Standard WinPE launch

```cmd
powershell.exe -STA -ExecutionPolicy Bypass -File "%SystemDrive%\Engine\Scripts\LiteDeploy.SelectWorkFlow.ps1"
```

### PowerShell launch

```powershell
& "$PSScriptRoot\LiteDeploy.SelectWorkFlow.ps1"
```

Keep `LiteDeploy.SelecWorkflowDriverPicker.ps1` beside the main script in the deployed `Engine\Scripts` directory.
