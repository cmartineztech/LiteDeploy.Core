# LiteDeploy Architecture and Execution Diagrams

Updated 2026-10-13. LiteDeploy Core v2 Architecture:
- **WinPE Engine** ([`100-Engine/LiteDeploy.Engine.ps1`](../../Engine/Scripts/Runtime/100-Engine/LiteDeploy.Engine.ps1); publish alias [`DeploymentEngine.ps1`](../../DeploymentShare/Engine/Scripts/Runtime/LiteDeploy.DeploymentEngine.ps1))
- **FullOS Engine** ([`100-Engine/LiteDeploy.FullOS.ps1`](../../Engine/Scripts/Runtime/100-Engine/LiteDeploy.FullOS.ps1))
- **Actions gating** — `WorkflowTag.Actions`; FullOS Run (+ Audit reseal / Domain Join UAC bypass) only when `actions.Count > 0` (e.g. Intune Ready with 0 actions → OOBE only, no Run)
- **First FullOS entry** — unattend **specialize** stages `HKLM\...\Run\LiteDeployFullOS` when actions > 0 (short `powershell.exe -File` / `REG_EXPAND_SZ`; no `auditUser`); keep **HKLM Run** as primary resume (not Startup / Task Scheduler)
- **Logon models** — Standard = Audit Admin (elevated); Domain Join = AutoLogon local admin + temporary `EnableLUA=0` / `UacBypassed` when no `<!--AuditMode-->` and actions > 0; FullOS cleanup restores `EnableLUA=1`
- **Direct Interactive Desktop Execution** (Session 1):
  - In-memory WinPECT secret unsealing (`Read-WPCTCredentialTransfer` targeting `LiteDeploy\CredentialTransfer`)
  - Native PowerShell `New-SmbMapping` + `New-PSDrive`; `EnableLinkedConnections = 1` so `Z:` is Explorer-visible
  - Log mirroring (`WorkLogs\Deployments\<UID>`)
  - On load, `HKCU\Console\%%Startup` `DelegationConsole` and `DelegationTerminal` (`{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}`) so consoles started afterward hand off to Windows Terminal. The window that already launched FullOS is unchanged. A registry failure does not stop resume
  - Kill `sysprep.exe` process; leave stock Setup `CmdLine` (sysprep) intact
  - Interactive Probe in a second independent PowerShell window (`Start-LiteDeployFullOSInteractiveProbe`); real Progress / packages still open
- **Reboot Survival** (same HKLM Run value; FullOS may re-arm; LiteDeploy_* scheduled tasks gated off / cleaned)
- **MDT reference** — stock MDT uses Startup `LiteTouch.lnk` / `RunOnce` / `FirstLogonCommands`→`LTIBootstrap`, not Task Scheduler; LiteDeploy stays on HKLM Run
- **Future Headless Exploration Roadmap** (Decoupled SYSTEM worker + IPC progress bar, detailed in [`IDEAS_FOR_IMPLEMENTATION.md`](../planning/IDEAS_FOR_IMPLEMENTATION.md) §3)

---

## 0. End-to-End Imaging Process (overview image)

*(Removed — prior `litedeploy-e2e-imaging-process.jpg` was incomplete / outdated. Re-add only after a regenerated overview that matches the live HKLM Run + actions-gating baseline.)*

---

## 1. End-to-End Execution Sequence Diagram

```mermaid
sequenceDiagram
    autonumber
    participant PE as "WinPE / Engine"
    participant OSVol as "OS volume"
    participant WSetup as "Windows Setup"
    participant Admin as "Session 1 / FullOS"
    participant Share as "DeploymentShare Z:"

    Note over PE,OSVol: 1. WinPE imaging and staging
    PE->>OSVol: Apply OS image (WIM / Setup.exe)
    PE->>OSVol: Stage drivers under ~LiteDeploy/Content/Drivers
    PE->>OSVol: Stage unattend.xml (specialize Run + Audit/AutoLogon)
    PE->>OSVol: Copy Runtime and Tools under ~LiteDeploy
    PE->>OSVol: WinPECT seals credentials in SOFTWARE hive
    PE->>OSVol: Save DeploymentState.json
    PE->>WSetup: Reboot into Windows

    alt No workflow actions (e.g. Intune Ready)
        WSetup->>WSetup: Specialize skips FullOS Run - continue to OOBE only
    else Workflow has actions
        Note over WSetup,Admin: 2. Specialize arms Run - first interactive FullOS
        WSetup->>WSetup: Order 1 description - Order 2 reg add HKLM Run
        opt Domain Join without AuditMode marker
            WSetup->>WSetup: Order 3 EnableLUA=0 - Order 4 UacBypassed marker
        end
        WSetup->>Admin: Interactive logon (Audit Admin or Domain Join AutoLogon)
        WSetup->>Admin: HKLM Run launches LiteDeploy.FullOS.ps1

        Note over Admin,Share: 3. Interactive FullOS Session 1
        Admin->>Admin: HKCU console handoff for later windows
        Admin->>Admin: Kill sysprep.exe process
        Admin->>OSVol: Re-arm HKLM Run LiteDeployFullOS
        Admin->>OSVol: Read DeploymentState.json (FullOS / Phase 5)
        Admin->>OSVol: WinPECT unseals secrets in RAM
        Admin->>Share: New-SmbMapping Z: with EnableLinkedConnections
        Admin->>Share: Mirror WorkLogs to share WorkLogs/Deployments/UID
        Admin->>Admin: Start Interactive Probe second window
        Note over Admin,Share: Packages orchestration planned - not fully wired

        opt Mid-deploy reboot via re-arm path
            Admin->>WSetup: Restart-Computer
            Note over WSetup,Admin: 4. Reboot survival via HKLM Run
            WSetup->>Admin: Autologon / interactive logon
            WSetup->>Admin: HKLM Run launches LiteDeploy.FullOS.ps1
            Admin->>OSVol: Increment ResumeCount and continue
        end

        Note over Admin,OSVol: 5. Finalization
        Admin->>OSVol: Clear HKLM Run - restore EnableLUA if UacBypassed
        Admin->>OSVol: Save DeploymentState.json Status Completed
        Admin->>Share: Final log mirror
    end
```

---

## 2. Execution & Privilege Architecture

```mermaid
graph TD
    subgraph WinPE ["WinPE Environment (SYSTEM)"]
        Boot["LiteDeploy.Boot.ps1<br/>(Network and Share Z:)"] --> Engine["LiteDeploy.Engine.ps1<br/>(Precheck, Disk, Image)"]
        Engine --> Handoff["Handoff<br/>1. Stage Runtime + Tools<br/>2. WinPECT SOFTWARE hive credentials"]
    end

    subgraph WindowsFirstBoot ["Windows First Boot"]
        ActionsGate{"actions.Count > 0?"}
        ActionsGate -->|No| OOBE["OOBE only (no FullOS Run)"]
        ActionsGate -->|Yes| Specialize["specialize: Order 2 HKLM Run<br/>+ DJ Orders 3–4 EnableLUA=0 if needed"]
        Specialize --> Logon["Interactive logon<br/>Audit Admin or AutoLogon"]
        Logon --> FullOSLaunch["HKLM Run → FullOS.ps1"]
    end

    subgraph Session1 ["Session 1 (Interactive Desktop)"]
        FullOSLaunch --> FullOS["LiteDeploy.FullOS.ps1"]
        FullOS --> ConsoleHost["HKCU console handoff"]
        ConsoleHost --> KillSysprep["Stop-Process sysprep.exe"]
        FullOS --> Unseal["WinPECT in-memory secret unseal"]
        Unseal --> MountZ["New-SmbMapping Z:<br/>EnableLinkedConnections=1"]
        MountZ --> Mirror["Log mirror to remote UID"]
        Mirror --> Arm["Re-arm HKLM Run"]
        Arm --> Probe["Interactive Probe second window"]
        Arm --> Pkg["Packages (planned)"]
        Pkg -->|Reboot when wired| RebootLoop["Reboot Computer"]
        RebootLoop --> RunKey["HKLM Run LiteDeployFullOS"]
        RunKey --> FullOS
        FullOS --> Cleanup["Clear Run + restore EnableLUA if bypassed"]
    end

    Handoff ==>|Machine Reboots into OS| WindowsFirstBoot
    WindowsFirstBoot ==> Session1
```

---

## 3. WinPE Runtime Pipeline Architecture

```mermaid
flowchart TD
    subgraph BootPhase["Phase 0: WinPE Bootstrap"]
        StartNet["startnet.cmd"] --> BootInit["LiteDeploy.Boot.ps1<br/>or legacy BootInitializer"]
        BootInit --> NetConn["Network / DHCP / SMB Connect"]
        NetConn --> MountShare["Mount Deployment Share (Z:)"]
        MountShare --> HandEngine["LiteDeploy.Engine.ps1<br/>alias: DeploymentEngine.ps1"]
    end

    subgraph EnginePhase["Phases 1-4: Precheck through Image"]
        HandEngine --> Precheck["UI.HardwarePrecheck"]
        Precheck --> Selection["UI.WorkflowSelection"]
        Selection --> Progress["UI.Progress host"]
        Progress --> Disk["LiteDeploy.Disk -ConfirmDestroy"]
        Disk --> Image["LiteDeploy.Image -ExecuteSetup"]
    end

    subgraph HandoffPhase["Phase 5: Handoff and Staging"]
        Image --> StagePayload["Stage Runtime + Tools"]
        StagePayload --> WinPECT["WinPECT export (RAM secrets + SOFTWARE hive)"]
        WinPECT --> HandoffLogs["Logs and State Mirror to W:/~LiteDeploy"]
        HandoffLogs --> StopProgress["Stop-LiteDeployProgressHost"]
        HandoffLogs --> RebootTarget["Reboot into installed Windows"]
    end
```

---

## 4. Component Responsibility Matrix

| Component | Execution Context | Trigger | Key Responsibilities |
| :--- | :--- | :--- | :--- |
| [`LiteDeploy.Engine.ps1`](../../Engine/Scripts/Runtime/100-Engine/LiteDeploy.Engine.ps1) | WinPE (SYSTEM) | [`LiteDeploy.Boot.ps1`](../../Engine/Scripts/Runtime/000-Boot/LiteDeploy.Boot.ps1) | Hardware precheck, disk wipe/partitioning, imaging, driver/unattend staging, WinPECT export, Runtime/Tools staging. |
| [`LiteDeploy.FullOS.ps1`](../../Engine/Scripts/Runtime/100-Engine/LiteDeploy.FullOS.ps1) | Session 1 (interactive admin) | HKLM Run (specialize-staged; FullOS may re-arm) | On load, HKCU console handoff for later windows; state progression (Phase 5), kill sysprep.exe, WinPECT unseal, `Z:` reconnect (`EnableLinkedConnections`), log mirror, re-arm HKLM Run, Interactive Probe window; clear Run + restore UAC on finish. Packages planned. Scheduled tasks gated off. |
| [`LiteDeploy.FullOS.InteractiveProbe.ps1`](../../Engine/Scripts/Runtime/100-Engine/LiteDeploy.FullOS.InteractiveProbe.ps1) | Session 1 | `Start-Process` from FullOS | Temporary Progress dry-run in a second window; monitors state / `Z:`. |
| [`LiteDeploy.Image.ps1`](../../Engine/Scripts/Runtime/080-Image/LiteDeploy.Image.ps1) | WinPE | Engine Image phase | Unattend: Order 1 description; Order 2 FullOS Run when `WorkflowTag.Actions` > 0; Orders 3–4 `EnableLUA=0` + marker when Domain Join (no Audit) + actions; Audit reseal when `<!--AuditMode-->` + actions. |
| **HKLM Run** | Interactive admin | specialize first arm; logon thereafter | Primary FullOS entry + mid-deploy reboot survival (`LiteDeployFullOS`). Kept for now (not MDT Startup / Task Scheduler). |
| **Setup CmdLine (sysprep)** | Windows Setup / Audit | stock Audit continue | Left intact; FullOS kills the `sysprep.exe` process instead of rewriting Setup. |

---

## 5. Disk Layout Architectures

```mermaid
classDiagram
    class UEFI_GPT_Layout {
        +Partition 1: EFI System Partition (ESP) - FAT32 (S:) [100 MB - 500 MB]
        +Partition 2: Microsoft Reserved (MSR) [16 MB - 128 MB]
        +Partition 3: Windows OS Partition - NTFS (W:) [Primary Volume]
        +Partition 4: Windows Recovery (WinRE) - NTFS [500 MB - 1 GB]
    }

    class BIOS_MBR_Layout {
        +Partition 1: System Reserved (Active / Boot) - NTFS (S:) [500 MB]
        +Partition 2: Windows OS Partition - NTFS (W:) [Primary Volume]
    }
```

---

## 6. Logs & State Synchronization (Quad Mirror Architecture)

```mermaid
flowchart LR
    StateSource["LiteDeploy State and Log Generator"]

    StateSource -->|1. Live IPC / MMF| RAM["RAM / Memory-Mapped File"]
    StateSource -->|2. WinPE Ramdisk| LocalDisk["X:/~LiteDeploy/WorkLogs/"]
    StateSource -->|3. OS Volume Target| TargetVolume["C:/~LiteDeploy/WorkLogs/"]
    StateSource -->|4. Deployment Share| RemoteShare["Z:/WorkLogs/Deployments/UID/"]
```

---

## 7. Component Ownership & Publishing Layout

```mermaid
flowchart LR
    subgraph DevelopmentRepo["Development Repository"]
        AdminSrc["Engine/Scripts/Admin/000-090"]
        RuntimeSrc["Engine/Scripts/Runtime/000-110"]
        UISrc["Runtime/110-UI"]
        ToolsSrc["Engine/Tools/WinPECT/"]
    end

    subgraph AdminBuild["Admin.Build to DeploymentShare"]
        AdminSrc --> BuildProc["LiteDeploy.Admin.Build.ps1"]
        RuntimeSrc --> BuildProc
        UISrc --> BuildProc
        ToolsSrc --> BuildProc
    end

    subgraph PublishedShare["Production share layout"]
        BuildProc --> FlatRuntime["Engine/Scripts/Runtime/LiteDeploy.Engine.ps1"]
        BuildProc --> FlatFullOS["Engine/Scripts/Runtime/LiteDeploy.FullOS.ps1"]
        BuildProc --> CompatAlias["LiteDeploy.DeploymentEngine.ps1<br/>byte-identical alias"]
        FlatRuntime -.->|copy| CompatAlias
        BuildProc --> FlatUI["Runtime/UI/"]
        BuildProc --> FlatAdmin["Engine/Scripts/Admin/"]
        BuildProc --> FlatTools["Engine/Tools/WinPECT/"]
        FlatTools --> StageOS["WinPE handoff to OS volume"]
        FlatRuntime --> StageOS
        FlatFullOS --> StageOS
    end
```

