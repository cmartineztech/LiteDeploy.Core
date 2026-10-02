# LiteDeploy Deployment Engine Module Documentation

**Script File**: `Scripts_Engine_Components\Runtime\LiteDeploy.DeploymentEngine.ps1\LiteDeploy.DeploymentEngine.ps1`  
**Documentation File**: `Scripts_Engine_Components\Runtime\LiteDeploy.DeploymentEngine.ps1\README.md`  
**Target Environment**: Windows PE (WinPE 5.1 / 10 / 11)  
**PowerShell Version**: PowerShell 5.1+ (`Set-StrictMode -Version 2.0`)  

---

## 1. Overview & Purpose

`LiteDeploy.DeploymentEngine.ps1` is the central runtime pipeline orchestrator for **LiteDeploy Core**.

It executes in WinPE immediately following `BootInitializer`, coordinating the sequenced transitions across deployment phases:
1. **Phase 1: Pre-Flight Assessment (`PreCheck`)** — Validates network reachability, RAM, storage, CPU architecture, and Secure Boot readiness.
2. **Phase 2: Workflow & Identity Selection (`SelectWorkflow`)** — Collects computer name, OS workflow image, target physical disk, and driver pack choices.
3. **Phase 3: Disk Preparation (`DiskFormat`)** — Wipes and partitions target disk (UEFI/GPT or Legacy/MBR), mounts temporary staging volume, and stamps WinRE flags.
4. **Phase 4: OS Image Application (`ApplyOSImage`)** — Generates customized `X:\unattended.xml` from `Autopilot.xml` template and executes `setup.exe /NoReboot`.
5. **Phase 5: Execution Handoff & Summary** — Aggregates and verifies pipeline outputs before offline staging handoff.

---

## 2. Component Metadata

```powershell
Get-LiteDeployComponentMetadata
```

| Property | Value |
| :--- | :--- |
| **ComponentId** | `DeploymentEngine` |
| **Name** | `LiteDeploy Deployment Engine` |
| **Version** | `1.0.0` |
| **Category** | `Runtime` |
| **TargetEnvironment** | `WinPE` |
| **MinPowerShellVersion** | `5.1` |
| **Author** | `LiteDeploy Team` |
| **Dependencies** | `LogWriter`, `PreCheck`, `SelectWorkflow`, `DiskFormat`, `ApplyOSImage`, `ProgressHost` |

---

## 3. Parameters

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `-BootObject` | `[psobject]` | `$null` | In-memory bootstrap context containing share mount status, credentials, and drive mappings. |
| `-SkipPreCheck` | `[switch]` | `$false` | Skips Phase 1 and directly launches Phase 2 (useful for rapid testing / re-deployments). |
| `-Metadata` | `[switch]` | `$false` | Fast-exit switch returning the standard `PSCustomObject` metadata. |

---

## 4. Pipeline Flow & State Management

```mermaid
flowchart TD
    A["BootInitializer (Parent Shell)"] -->|"Passes in-memory BootObject"| B["DeploymentEngine"]
    B --> C{"SkipPreCheck?"}
    C -- No --> D["Launch PreCheck.ps1"]
    D --> E{"PreCheck Passed?"}
    E -- No / Cancelled --> F["Halt & Log Cancellation"]
    E -- Yes --> G["Launch SelectWorkFlow.ps1"]
    C -- Yes --> G
    G --> H{"Deployment Confirmed?"}
    H -- No / Cancelled --> I["Halt & Log Cancellation"]
    H -- Yes --> J["Output Pipeline State Object"]
```

---

## 5. Deployment UID & State Management

Each session receives a cryptographically randomized, compact, date-prefixed identifier:
```powershell
function Get-LiteDeployUid {
    $bytes = [Byte[]]::new(2)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $hex = [System.BitConverter]::ToString($bytes) -replace '-'
    return "$((Get-Date).ToString('yyMMdd'))-$hex"
}
```

The returned and persisted `$Deployment` state object (`X:\~LiteDeploy\DeploymentState.json`):

```powershell
[PSCustomObject]@{
    DeploymentUid   = "260929-A3F1"
    Status          = "ReadyForDeployment"    # Initializing, PreCheck, WorkflowSelection, ReadyForDeployment, Staging, Completed, Cancelled, Failed
    CurrentPhase    = 2
    StartTime       = "2026-09-29T22:55:00.000Z"
    EndTime         = $null
    BootObject      = $BootObject
    PreCheck        = [PSCustomObject]@{
        Passed         = $true
        CompletedTime  = "2026-09-29T22:55:10.000Z"
    }
    Workflow        = [PSCustomObject]@{
        Confirmed      = $true
        SelectionData  = $workflowOutput
        CompletedTime  = "2026-09-29T22:55:30.000Z"
    }
    Disk            = [PSCustomObject]@{
        Formatted      = $true
        DiskNumber     = 0
        OSDriveLetter  = "W:\"
        CompletedTime  = "2026-09-29T22:56:00.000Z"
    }
    OSInstall       = [PSCustomObject]@{
        Applied        = $true
        Engine         = "Setup.exe"
        SetupPath      = "Z:\Content\OS\setup.exe"
        UnattendPath   = "X:\unattended.xml"
        ExitCode       = 0
        DurationSeconds= 210
        CompletedTime  = "2026-09-29T22:59:30.000Z"
    }
    Execution       = [PSCustomObject]@{
        CurrentStep    = "Initialized"
        PercentComplete = 70
        LocalLogDir    = "X:\~LiteDeploy\WorkLogs"
        Errors         = @()
    }
}
```

---

## 6. Verification & CLI Usage

To inspect component metadata:
```powershell
powershell -ExecutionPolicy Bypass -File ".\Scripts_Engine_Components\Runtime\LiteDeploy.DeploymentEngine.ps1\LiteDeploy.DeploymentEngine.ps1" -Metadata
```

To run full deployment pipeline:
```powershell
powershell -STA -ExecutionPolicy Bypass -File ".\Scripts_Engine_Components\Runtime\LiteDeploy.DeploymentEngine.ps1\LiteDeploy.DeploymentEngine.ps1" -BootObject $bootObj
```
