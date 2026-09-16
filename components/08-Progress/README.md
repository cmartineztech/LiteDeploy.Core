# LiteDeploy Native Progress Host

**Script File**: `components\08-Progress\LiteDeploy.Progress.ps1`  
**State Payload**: `components\08-Progress\DeploymentState.json`  
**Test Harness**: `components\08-Progress\Test-LiteDeployProgress.ps1`  
**Full Technical Documentation**: [NATIVE_HOST_DOCUMENTATION.md](NATIVE_HOST_DOCUMENTATION.md)  
**Target Environment**: Windows PE & Windows Host (Full OS)  
**PowerShell Version**: PowerShell 5.1+  

---

## 1. Overview & Purpose

`LiteDeploy.Progress.ps1` is a zero-dependency, native PowerShell and WPF progress host application for **LiteDeploy**. It replaces legacy HTML applications (`mshta.exe`), Node.js, and browser dependencies with a hardware-accelerated or software-rendered UI host.

It runs as a read-only progress client in both environments:
- **WinPE Phase**: Minimalist, high-visibility bare-metal progress display.
- **FullOS Phase**: Modern dashboard layout tracking post-installation workflow actions, driver injection, and domain configuration.

The deployment engine updates progress and persists state to **`DeploymentState.json`**, allowing the progress host to survive reboots and resume execution automatically.

---

## 2. Directory Layout & Files

| File | Purpose |
| :--- | :--- |
| **`LiteDeploy.Progress.ps1`** | Native WPF progress host application. Exports `Set-LiteDeployProgress`. |
| **`DeploymentState.json`** | JSON state schema tracking deployment phases, percentage, steps, and log records. |
| **`Test-LiteDeployProgress.ps1`** | Test harness for simulating deployment progress across WinPE and FullOS modes. |
| **`NATIVE_HOST_DOCUMENTATION.md`** | In-depth architectural specifications, lifecycle flow, and state transition details. |

---

## 3. Runtime Integration (`Set-LiteDeployProgress`)

The runtime engine invokes `Set-LiteDeployProgress` to update UI state in memory while persisting changes to disk:

```powershell
# Load the progress module
. .\components\08-Progress\LiteDeploy.Progress.ps1 -Environment WinPE -Theme Light -WindowTitle "LiteDeploy Workstation Setup"

# Update progress during disk configuration
Set-LiteDeployProgress -Phase "DiskSetup" -CurrentStep "Partitioning Target Disk" `
    -Message "Configuring GPT Disk 0" -StepPercent 50 -OverallPercent 20 `
    -LogMessage "Applying disk partition layout..."
```

---

## 4. Parameter Reference (`LiteDeploy.Progress.ps1`)

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `-StatePath` | `[string]` | `".\DeploymentState.json"` | Path to the state persistence payload file. |
| `-Environment` | `[string]` | `"Auto"` | Target layout view: `"FullOS"`, `"WinPE"`, or `"Auto"` (auto-detected from state). |
| `-Theme` | `[string]` | `"Light"` | Visual palette theme (`"Light"` or `"Dark"`). |
| `-TopMost` | `[string]` | `"Off"` | Keeps window top-most when set to `"On"`. |
| `-WindowTitle` | `[string]` | `""` | Custom title bar text for the progress window. |
| `-ShowBackdrop` | `[switch]` | `$false` | Shows a full-screen solid dark backdrop behind the window. |
| `-KeepOpen` | `[switch]` | `$false` | Prevents window from auto-closing upon reaching the `Completed` state. |

---

## 5. Verification and Testing

Run the progress test harness to visually preview state transitions and verify UI scaling:

```powershell
# Interactive test in WinPE mode
.\components\08-Progress\Test-LiteDeployProgress.ps1 -Environment WinPE -Theme Light

# Interactive test in FullOS mode
.\components\08-Progress\Test-LiteDeployProgress.ps1 -Environment FullOS -Theme Dark
```

> [!TIP]
> For complete technical details on memory isolation, process boundaries, and state schema definitions, see **[NATIVE_HOST_DOCUMENTATION.md](NATIVE_HOST_DOCUMENTATION.md)**.
