# LiteDeploy WinPE Initialization Engine Documentation

**Script**: `components\05-BootInitializer\LiteDeploy.BootInitilizer.ps1`  
**Documentation File**: `components\05-BootInitializer\README.md`  
**Target Environment**: Windows PE (WinPE 5.1 / 10 / 11) & Windows Host  
**PowerShell Version**: PowerShell 5.1+ (`Set-StrictMode -Version 2.0`)  

---

## 1. Overview & Purpose

`LiteDeploy.BootInitilizer.ps1` is the core initialization, configuration discovery, network validation, interactive authentication, and SMB share mounting engine for **LiteDeploy**.

The WinPE ISO or `Boot.wim` that launches this script is built with [WinPEBuilder](https://github.com/cmartinezone/WinPEBuilder) for USB/ISO media or WDS/PXE.

It automatically discovers `BootConfig.json` using dynamic RAM drive detection (`$env:SystemDrive`), performs network hardware & IP checks (when `DeploymentType` is `"Network"`), verifies deployment server reachability over SMB Port 445, prompts for user credentials securely via native `Get-Credential`, mounts the remote deployment share to drive **`Z:\`**, discovers `LiteDeploy.HostShell.ps1`, minimizes the console shell, and launches the target engine pre-check script (`LiteDeploy.PreCheck.ps1`).

---

## 2. Architecture & Execution Flow

```mermaid
flowchart TD
    Start["Boot Environment Startup (powercfg & wpeinit if WinPE)"] --> DiscoverConfig["Get-LiteDeployBootConfig"]

    subgraph Discovery ["1. Dynamic BootConfig.json Discovery"]
        P1["Priority 1: WinPE RAM ($env:SystemDrive)"]
        P2["Priority 2: Removable USB & Optical Media"]
        
        P1 --> CheckRAM{"Found in RAM?"}
        CheckRAM -- "Yes (PXE/WIM Embedded)" --> CheckMode{"Deployment Type?"}
        CheckRAM -- "No" --> P2
        P2 --> CheckMedia{"Found on USB/Media?"}
        CheckMedia -- "No" --> ConfigErr["Show-LiteDeployGuiError ('Config Missing')"]
        CheckMedia -- "Yes" --> CheckMode
    end

    subgraph MediaMode ["2. Media Mode (Offline)"]
        CheckMode -- "Media" --> MediaPath["Extract Drive Letter & LocalRootName"]
        MediaPath --> SetMediaEngine["Resolve EngineScriptPath via Resolve-Path"]
    end

    subgraph NetworkMode ["3. Network Pre-Validation Pipeline"]
        CheckMode -- "Network" --> PathCheck{"NetworkPath Configured?"}
        PathCheck -- "Missing" --> PathErr["Show-LiteDeployGuiError ('Misconfigured NetworkPath')"]
        PathCheck -- "Valid" --> NormPath["Format-LiteDeployUncPath (Normalize Slashes & Trim)"]
        
        NormPath --> Step1["Step 1: Scan Network Adapters (Multi-Adapter Prioritization)"]
        Step1 -- "NIC Missing" --> DriverErr["Show-LiteDeployGuiError ('Network Driver Missing - Retry/Cancel')"]
        DriverErr -- "Retry" --> Reload1["Flush Console & Print [RETRY]"] --> Step1
        
        Step1 -- "NIC Present" --> Step2["Step 2: Verify Physical Cable Link Connection"]
        Step2 -- "Cable Disconnected" --> CableErr["Show-LiteDeployGuiError ('Cable Disconnected - Retry/Cancel')"]
        CableErr -- "Retry" --> Reload2["Flush Console & Print [RETRY]"] --> Step1
        
        Step2 -- "Link Connected" --> Step3["Step 3: Poll Unicast IP Address (30s Window / Fast Break)"]
        Step3 -- "DHCP Timeout" --> IPErr["Show-LiteDeployGuiError ('IP Assignment Failed - Retry/Cancel')"]
        IPErr -- "Retry" --> Reload3["Flush Console & Print [RETRY]"] --> Step1
        
        Step3 -- "IP Assigned" --> NetAccessCheck{"Local Network Access (NIC + IP)?"}
        
        NetAccessCheck -- "No (No IP/NIC)" --> SkipServerCheck["Set ServerReachable = False (Skip SMB Test)"]
        NetAccessCheck -- "Yes (NIC + IP)" --> Step4["Step 4: Test SMB Port 445 Connectivity (5000ms + Test-Path)"]
        
        Step4 -- "Server Offline / Port 445 Blocked" --> ServerErr["Show-LiteDeployGuiError ('Server Unreachable - Retry/Cancel')"]
        ServerErr -- "Retry" --> Reload4["Flush Console & Print [RETRY]"] --> Step1
        Step4 -- "Port 445 Reachable" --> ConnectShare["Connect-LiteDeployDeploymentShare"]
    end

    subgraph AuthMount ["4. Pure PowerShell Auth & Drive Mount (Z:)"]
        ConnectShare --> CheckMounted{"Is Z: Already Connected?"}
        CheckMounted -- "Yes" --> MountSuccess["Return Mounted = True & $global:LiteDeployCredential"]
        CheckMounted -- "No" --> PromptCred["Prompt Credentials (Get-Credential)"]
        
        PromptCred --> TryMount["New-PSDrive / New-SmbMapping -Name Z (Out-Null Suppressed)"]
        TryMount -- "Success" --> MountSuccess
        TryMount -- "Failure" --> AuthErr["Show-LiteDeployGuiError ('Invalid Credentials - Retry/Cancel')"]
        
        AuthErr -- "Retry" --> ReloadAuth["Flush Console & Print [RETRY]"] --> PromptCred
        AuthErr -- "Cancel / Close" --> MountFail["Pause Initialization & Print Notice ('run startnet')"]
    end

    SetMediaEngine --> Handoff["Return Result PSCustomObject (Includes Strict-Mode Guards)"]
    MountSuccess --> SetNetEngine["Set EngineScriptPath = Z:/Engine/Scripts/LiteDeploy.PreCheck.ps1"]
    SetNetEngine --> Handoff
    Handoff --> LaunchEngine{"Standalone Launcher Run?"}
    LaunchEngine -- "Yes" --> HostShellCheck["Discover LiteDeploy.HostShell.ps1 & Set-HostShellWindow -Action Minimize"]
    HostShellCheck --> ExecScript["Execute Engine Pre-Check (& $res.EngineScriptPath -BootObject $res)"]
```

---

## 3. Configuration Discovery Priority Hierarchy

`Get-LiteDeployBootConfig` searches for `BootConfig.json` across locations in strict priority order. Internal fixed SATA, NVMe, and RAID disks are excluded to avoid consuming staging configs from previous OS installations.

| Priority | Scope | Description & Scanned Paths |
| :--- | :--- | :--- |
| **Priority 1 (Highest)** | **WinPE RAM (`$env:SystemDrive`)** | `$env:SystemDrive\~LiteDeploy\Config\BootConfig.json`<br>`$env:SystemDrive\*\Config\BootConfig.json`<br>`$env:SystemDrive\Windows\System32\BootConfig.json`<br>*(Bypasses external media scanning when found for instant PXE/WIM boot)* |
| **Priority 2** | **External Media** | Evaluated **only if not found in RAM**. Scans Removable USB Flash Drives, USB HDDs/SSDs (`BusType -in @('USB','1394','SD')`), CD-ROM/DVD-ROM Optical Media (`<Drive>:\~LiteDeploy\Config\BootConfig.json`, `<Drive>:\*\Config\BootConfig.json`). |

---

## 4. Pre-Validation Engine Checklist

When `Deployment.Type` is `"Network"` and `NetworkPath` is configured, the script executes an interactive 4-step pre-validation pipeline:

1. **Network Hardware Recognition & Multi-Adapter Prioritization**:
   * Scans active physical, USB, or virtual Ethernet network cards via `Get-NetAdapter` and `.NET` `NetworkInterface::GetAllNetworkInterfaces()`.
   * Automatically prioritizes any adapter with an active link (`Status -eq 'Up'`).
   * **Failure Action**: Triggers an interactive GUI Retry/Cancel dialog titled *"LiteDeploy - Network Driver Missing"*. Clicking **Retry** re-initializes WinPE networking (`wpeutil InitializeNetwork`) and re-scans hardware; clicking **Cancel** pauses initialization and drops to the WinPE shell.
2. **Physical Cable Link State Verification**:
   * Instantly verifies physical link connectivity (`MediaConnectionState -eq 'Connected'` / `OperationalStatus -eq 'Up'`).
   * **Failure Action**: Triggers an interactive GUI Retry/Cancel dialog titled *"LiteDeploy - Network Cable Disconnected"*. Clicking **Retry** re-evaluates physical link state; clicking **Cancel** pauses initialization and drops to the WinPE shell.
3. **IPv4 / IPv6 Address Assignment (30s Adaptive Polling)**:
   * Polls for assigned IPv4 or IPv6 unicast addresses for up to 30 seconds (ideal for enterprise Spanning Tree Protocol switches).
   * Filters out loopback (`127.0.0.1`, `::1`), APIPA (`169.254.x.x`), and IPv6 link-local (`fe80::*`).
   * **Instant Early Exit**: As soon as an IP is detected (e.g. at 1.5s), the loop breaks **immediately** without waiting for the remaining 30 seconds.
   * **Failure Action**: Triggers an interactive GUI Retry/Cancel dialog titled *"LiteDeploy - IP Address Assignment Failed"*.
4. **`NetworkPath` Validation & Universal Path Normalization**:
   * Accepts both forward slash and backslash formats in `BootConfig.json` (e.g. `"/X1/DeploymentShare$"`, `"//X1/DeploymentShare$"`, or `"\\\\X1\\DeploymentShare$"`).
   * Automatically normalizes any path to standard Windows UNC (`\\X1\DeploymentShare$`).
   * Tests TCP 445 socket connectivity to the deployment server via `.NET` `TcpClient` with a 5000ms timeout and `Test-Path` fallback for WinPE DNS lookup delays.
   * **Failure Action**: Triggers an interactive GUI Retry/Cancel dialog titled *"LiteDeploy - Server Unreachable"* displaying the target server name and `NetworkPath`.

---

## 5. Pure Native PowerShell Credential & Drive Mapping (`Z:\`)

* **100% Pure PowerShell**: Uses native PowerShell cmdlets (`New-PSDrive` and `New-SmbMapping`) for persistent SMB mapping.
* **Interactive Retry Loop**: Prompts for credentials via `Get-Credential`. If authentication fails, pops up a Windows Forms **Retry / Cancel** GUI dialog titled *"LiteDeploy - Authentication Failure"*. Clicking **Retry** re-prompts until successful or cancelled.
* **Graceful Cancellation Guidance**: If the user closes or cancels any prompt, initialization pauses cleanly with clear console instructions:
  `[NOTICE] Deployment initialization paused.`
  `To restart this process, run 'startnet' below.`
* **System-Wide SMB Access**: Under the hood, `-Persist` registers the authenticated SMB session with the Windows `MPR` / `WNet` Kernel driver. All child PowerShell processes, CMD windows, DISM commands, and `PreCheck.ps1` inherit access to `Z:\`.

---

## 6. Function Reference

### `Write-LiteDeployLog`
Outputs color-coded text live to the console screen and appends official Microsoft CMTrace.exe XML formatted entries to `X:\~LiteDeploy\WorkLogs\LiteDeploy.Execution.log`.
```powershell
Write-LiteDeployLog -Message "IP Address Assigned: 192.168.1.50" -Level "SUCCESS" -ForegroundColor Green -Component "BootInitilizer"
```

### `Format-LiteDeployUncPath`
Normalizes any slash combination (`/` or `\`) or trailing slashes to standard Windows UNC path syntax (`\\Server\Share$`).
```powershell
$uncPath = Format-LiteDeployUncPath -Path "//Server/DeploymentShare$/"
# Returns "\\Server\DeploymentShare$"
```

### `Show-LiteDeployGuiError`
Displays Windows Forms GUI error dialogs (`MessageBox`) with `try/catch` fallback to console warning.
```powershell
Show-LiteDeployGuiError -Message "Error message text" -Title "LiteDeploy Error" -IsRetryDialog:$false
```

### `Resolve-LiteDeployEnginePath`
Resolves target engine pre-check script paths on `Z:\` or offline media using multi-line wildcard `Resolve-Path`.
```powershell
$enginePath = Resolve-LiteDeployEnginePath -RootPath "Z:"
# Returns "Z:\Engine\Scripts\LiteDeploy.PreCheck.ps1"
```

### `Test-LiteDeployNetworkHardware`
Scans for active network interface cards and prioritizes connected adapters.
```powershell
$nic = Test-LiteDeployNetworkHardware
# Returns [PSCustomObject]@{ AdapterFound = $bool; AdapterName = $str; IsLinkConnected = $bool }
```

### `Test-LiteDeployIPAddress`
Polls for assigned IPv4/IPv6 addresses with instant early exit on IP detection.
```powershell
$ipInfo = Test-LiteDeployIPAddress -TimeoutSeconds 30
# Returns [PSCustomObject]@{ IPAddress, IPv4Address, IPv6Address, HasValidIP }
```

### `Test-LiteDeployDeploymentShare`
Tests SMB TCP Port 445 server reachability with 5000ms timeout and `Test-Path` UNC fallback.
```powershell
$shareInfo = Test-LiteDeployDeploymentShare -SharePath "\\Server\DeploymentShare$" -TimeoutMs 5000
# Returns [PSCustomObject]@{ Reachable = $bool; Server = "Server" }
```

### `Connect-LiteDeployDeploymentShare`
Handles interactive credential prompting, authentication retry loop, pipeline leak suppression, and `Z:\` drive mapping using pure PowerShell.
```powershell
$mountRes = Connect-LiteDeployDeploymentShare -NetworkPath "\\Server\DeploymentShare$" -DriveLetter "Z:" -ShowGuiError
# Returns [PSCustomObject]@{ Mounted, DriveLetter, NetworkPath, Credential }
```

### `Get-LiteDeployBootConfig`
Primary discovery and validation engine function. Returns a `[PSCustomObject]` with strict-mode property protection.
```powershell
$bootConfig = Get-LiteDeployBootConfig -ConfigPath "" -MountShare -ShowGuiError
```

---

## 7. Integration & Standalone Execution

### Standalone Execution
When executed directly (not dot-sourced), `LiteDeploy.BootInitilizer.ps1`:
1. Executes `Get-LiteDeployBootConfig`.
2. Extracts `$bootObj` with `Set-StrictMode 2.0` property protection.
3. Logs all checks, status, warnings, and errors to `X:\~LiteDeploy\WorkLogs\LiteDeploy.Execution.log` (CMTrace XML) and `X:\~LiteDeploy\WorkLogs\LiteDeploy.Execution.json` (NDJSON).
4. Verifies presence of target engine pre-check script (`LiteDeploy.PreCheck.ps1`).
   * **If Missing**: Logs `[ERROR] Engine script not found...` to `LiteDeploy.Execution.log` and `LiteDeploy.Execution.json`, displays GUI error dialog titled *"LiteDeploy - Script Missing"*, and pauses initialization cleanly.
   * **If Present**: Discovers `LiteDeploy.HostShell.ps1`, minimizes host console shell, and executes `& $enginePath -BootObject $bootObj` inside an error-capturing `try/catch` block.
5. Restores host shell window on completion or error.

---

## 8. Logging & Diagnostics Standard

* **Master Log Files**: `X:\~LiteDeploy\WorkLogs\LiteDeploy.Execution.log` and `X:\~LiteDeploy\WorkLogs\LiteDeploy.Execution.json`
* **Format**: 
  * **CMTrace XML**: Native XML Schema (`type="1"` Info/Success, `type="2"` Warning/Retry, `type="3"` Error).
  * **Structured NDJSON**: Single-line compressed JSON objects (`timestamp`, `level`, `type`, `component`, `message`, `file`).
* **Multi-Destination Output**: `Write-LiteDeployLog` writes live colored text to the console screen while simultaneously appending timestamped CMTrace XML lines to `LiteDeploy.Execution.log` and NDJSON objects to `LiteDeploy.Execution.json`.
* **Single Startup Banner**: Title banners (`======...`, `LiteDeploy WinPE Initialization Engine v1.0`, `======...`) appear **exactly once at initial script startup**. Screen clears (`Clear-Host`) and duplicate title headers inside retry loops are completely eliminated.
* **Standardized Bracket Tags**: All console and log entries use aligned bracketed prefixes:
  * ` [INIT]    ` — WinPE environment setup & power plan activation (`type="1"`)
  * ` [CHECK]   ` — Discovery and pre-validation check prompts (`type="1"`)
  * ` [SUCCESS] ` — Successful discovery, connection, or hardware detection (`type="1"`)
  * ` [INFO]    ` — Configuration mode and path parameter details (`type="1"`)
  * ` [WARNING] ` — Recoverable issues such as disconnected cable or DHCP timeout (`type="2"`, Yellow)
  * ` [RETRY]   ` — Re-scanning hardware, polling link/IP, or re-prompting credentials (`type="2"`, Yellow)
  * ` [ERROR]   ` — Unrecoverable errors or authentication failures (`type="3"`, Red)
* **100% History Retention**: Every event—including success states, fast-path checks, authentication failures, retries, and cancellation pauses—is recorded persistently in both log targets.
* **Specification Document**: Full details, component tags, and code examples are documented in [LogWriter README](../03-LogWriter/README.md).
