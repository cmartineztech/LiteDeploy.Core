# LiteDeploy Pre-Check Execution & Architecture Flowchart

This document provides a dedicated visual flowchart detailing the complete execution lifecycle, environment initialization, configuration resolution, 9-point assessment pipeline, and UI state handling of **[LiteDeploy.PreCheck.ps1](LiteDeploy.PreCheck.ps1)**.

---

## 📊 Pre-Check Execution Flowchart

```mermaid
flowchart TD
    Start["Pre-Check Execution Launch"] --> CheckSTA{"Thread Apartment State == STA?"}

    subgraph Initialization ["1. Environment & WPF Host Setup"]
        CheckSTA -- "No" --> RelaunchSTA["Relaunch: powershell.exe -STA -ExecutionPolicy Bypass -File PreCheck.ps1"]
        CheckSTA -- "Yes" --> ForceSoftwareRender["Set WPF RenderMode = SoftwareOnly (WinPE GPU Crash Safeguard)"]
        
        ForceSoftwareRender --> CalcScale["Calculate 4:3 Aspect Ratio Window Scaling based on Screen Height"]
        CalcScale --> ApplyTheme["Apply Selected Color Palette (Light / Dark Theme)"]
        ApplyTheme --> PaintUI["Render WPF UI Window Frame & Progress Tracks"]
    end

    subgraph ConfigResolution ["2. BootConfig.json & Policy Resolution"]
        PaintUI --> FindConfig["Resolve BootConfig.json Location"]
        FindConfig --> CheckBypass{"SkipHardwarePreCheck == true?"}
        
        CheckBypass -- "Yes" --> PolicyBypass["Set Banner: PRE-CHECK BYPASSED BY POLICY<br/>Set Status: INFO (Skipped by Policy)<br/>Unlock Continue Button"]
        CheckBypass -- "No" --> AssessmentPipeline["Execute 9-Point System Readiness Assessment"]
    end

    subgraph Assessment ["3. 9-Point Hardware Readiness Assessment Pipeline"]
        AssessmentPipeline --> Check1["1. Deployment Mode (Network vs Media)"]
        Check1 --> Check2["2. Deployment Server Reachability (SMB TCP 445)"]
        Check2 --> Check3["3. Network Adapter Detection (Get-NetAdapter / .NET)"]
        Check3 --> Check4["4. IPv4 / IPv6 Address Assignment Polling"]
        Check4 --> Check5["5. Internal Storage Disk Capacity (MinDiskSizeGB)"]
        Check5 --> Check6["6. Installed Physical RAM Capacity (MinMemoryGB)"]
        Check6 --> Check7["7. BIOS / Firmware Mode Detection (UEFI vs Legacy)"]
        Check7 --> Check8["8. Secure Boot CA Readiness Check (2011/2023 CA)"]
        Check8 --> Check9["9. TPM Security Status Check (TPM 2.0 / 1.2)"]
    end

    subgraph Evaluation ["4. Results Evaluation & UI State Binding"]
        Check9 --> EvalResults{"Any Assessment Critical FAIL?"}
        
        EvalResults -- "No (All OK / WARN)" --> PassState["Set Banner: SYSTEM READY FOR DEPLOYMENT<br/>Enable Continue Button"]
        EvalResults -- "Yes (FAIL & HaltOnFailure=true)" --> FailState["Set Banner: CRITICAL PRE-CHECK ISSUES DETECTED<br/>Disable Continue Button (Blocked)"]
    end

    subgraph UserInteraction ["5. User Actions & Close Protection"]
        PassState --> WaitAction["Await Technician Action"]
        FailState --> WaitAction
        
        WaitAction -- "Click Continue" --> AllowExit["Set AllowClose = true<br/>Set $global:PreCheckPassed = true<br/>Close Window"]
        WaitAction -- "Click Re-Run" --> AssessmentPipeline
        WaitAction -- "Click Run CMD" --> OpenCMD["Set Topmost = false<br/>Launch System32/cmd.exe"]
        
        WaitAction -- "Close Window / Alt+F4 / Esc" --> ConfirmClose{"Confirm Close Dialog"}
        ConfirmClose -- "Click No" --> WaitAction
        ConfirmClose -- "Click Yes" --> CancelExit["Set $global:PreCheckPassed = false<br/>Exit Deployment"]
    end

    PolicyBypass --> WaitAction
```

---

## 📑 Workflow Section Descriptions

### 1. Environment & WPF Host Setup
* **STA Relaunch Guard**: Detects if the current PowerShell host thread is running in Single-Threaded Apartment (STA) mode. If not, it transparently relaunches itself using `powershell.exe -STA`.
* **Software Rendering**: Enforces `[RenderOptions]::ProcessRenderMode = SoftwareOnly` to eliminate GPU driver crashes in WinPE RAMDisk environments.
* **Dynamic Scaling & Themes**: Dynamically computes 4:3 viewbox scaling based on primary monitor height ($75\%$ height scaling) and applies theme brushes (`Light` or `Dark`).
* **BootObject Storage**: Accepts an optional `[psobject]$BootObject` parameter passed from `BootInitilizer` (which encapsulates credentials, network paths, drive letters, and config metadata) and holds it intact in `$BootObject` and `$global:LiteDeployBootObject`.

### 2. Configuration Resolution & Policy Bypass
* Resolves `BootConfig.json` across strict priority paths.
* If `Startup.SkipHardwarePreCheck` is set to `true`, hardware checks are bypassed, an `INFO` badge is logged, and the deployment is immediately unlocked.

### 3. The 9-Point Assessment Pipeline
1. **Deployment Mode**: Identifies whether the run is `Network` or `Media` (Offline).
2. **Deployment Server**: Tests SMB TCP Port 445 connectivity to the deployment server.
3. **Network Adapter**: Scans for active physical Ethernet adapters.
4. **IP Address**: Polls for a valid non-APIPA IPv4/IPv6 address.
5. **Hard Drive**: Scans internal fixed drives against `-MinDiskSizeGB`.
6. **System RAM**: Compares installed RAM against `-MinMemoryGB` with VM WMI OS fallback.
7. **BIOS Mode**: Queries `UEFI` vs `Legacy BIOS` state.
8. **Secure Boot**: Queries UEFI Secure Boot CA database (`Get-SecureBootUEFI db`) for 2011/2023 CAs.
9. **TPM Status**: Evaluates TPM 2.0 / 1.2 version and state (`OK` or non-blocking `WARN`).

### 4. Results Evaluation & Close Protection
* **HaltOnFailure Enforcement**: Disables the **Continue** button (`Blocked`) if any required check fails when `-HaltOnFailure $true` is set.
* **Confirmation Modal**: Intercepts `Alt+F4`, `Escape`, or window `X` clicks to prevent accidental deployment cancellation.
