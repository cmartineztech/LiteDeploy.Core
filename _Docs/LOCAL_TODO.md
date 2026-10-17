# LiteDeploy Local TODO & Roadmap

---

## 1. Completed Milestones (v2 Architecture)

- [x] **Modular Repository Layout:** Numbered development folders under `Engine\Scripts\Runtime` and `Engine\Scripts\Admin`.
- [x] **Flat Published Production Layout:** Automated publishing via `LiteDeploy.Admin.Build.ps1` to `C:\DeploymentShare`.
- [x] **Strict Architecture & Safety Gates:** Plain PowerShell 5.1 with `Set-StrictMode -Version 2.0` compliance across all runtime components.
- [x] **Hardware Pre-Check & Inventory:** UEFI/BIOS detection, Secure Boot, CPU, RAM, Disk health, and network connectivity.
- [x] **Dynamic Disk Partitioning:** UEFI/GPT layout (ESP `S:`, MSR, OS `W:`, WinRE) and Legacy BIOS/MBR layout with `-ConfirmDestroy` safety gate.
- [x] **Driver Pipeline & Security:**
  - [x] Automatic driver matching by Manufacturer, Model, SKU, and Architecture.
  - [x] Fast sub-millisecond SMB candidate discovery (`Length > 0` metadata check, zero network hash delays).
  - [x] Staging to target volume (`W:\~LiteDeploy\Content\Drivers`).
  - [x] Post-copy transfer byte-size comparison verifying 100% complete network copy.
  - [x] Cryptographic SHA-256 integrity verification locally on fast SSD storage before extraction.
  - [x] Native WinPE extraction (`expand.exe` for CABs, vendor command switches for Dell, Lenovo, HP).
  - [x] Automatic fallback to Windows Inbox drivers upon corrupted/missing packages.
- [x] **Dual Imaging Engines:**
  - [x] `dism.exe`: Bare-metal `/Apply-Image` + `bcdboot.exe` (UEFI/BIOS) + offline driver servicing (`/Add-Driver /Recurse`) + Panther `unattend.xml` staging.
  - [x] `setup.exe`: Traditional Windows Setup with `/NoReboot` and dynamic answer file generation.
  - [x] Unified return object structure (`Success`, `Engine`, `SetupPath`, `ImagePath`, `ExitCode`, `DurationSeconds`).
  - [x] Audit Mode Reseal: `<Reseal><Mode>Audit</Mode></Reseal>` configured in `Standard.xml` and `IntuneReady.xml` for pre-OOBE package orchestration.
- [x] **Console & UI Shell UX:**
  - [x] Unminimized live PowerShell host console window during all phases for live diagnostics.
  - [x] Non-blocking offline network socket probe (200 ms).
  - [x] Instant synchronous UI dropdown population on window launch.
- [x] **Triple Mirror Logging & State:** Live Memory-Mapped File (MMF) IPC, WinPE Ramdisk (`X:`), Remote Deployment Share (`Z:`), and Target OS Volume (`W:\~LiteDeploy`).
- [x] **Automated Architecture Test Suite:** 155 tests passing with 0 failures (`_Tests\Test-LiteDeployArchitectureV2.ps1`).
- [x] **Repo tooling folders:** `Templates` → `_Templates`; `Engine\Scripts\Tests` → `_Tests` (docs + RepoRoot inference updated).
- [x] **In-Memory WinPECT Credential Transfer:** Dynamic in-memory secret decryption (`Read-WPCTCredentialTransfer`), zero plaintext or DPAPI `.xml` files written to disk.
- [x] **Native PowerShell Network Share Connect:** `New-SmbMapping` & `New-PSDrive` passing in-memory `PSCredential` (completely eliminates `net.exe use` and command-line credential exposure).
- [x] **Direct Interactive FullOS Execution:** specialize stages `HKLM\...\Run\LiteDeployFullOS` when workflow actions > 0 (short `reg add` / `powershell.exe -File`; no `auditUser`); FullOS starts at interactive logon and may re-arm Run for reboot survival; kills `sysprep.exe` (stock Setup CmdLine left intact); `EnableLinkedConnections = 1` for Explorer-visible `Z:`; scheduled tasks gated off.
- [x] **Specialize Path hardened:** nested-quoted PowerShell inside `reg add /d` rejected by Setup; short `powershell.exe` Path validated (Standard + Domain Join specialize parse OK).
- [x] **WorkflowTag.Actions gating:** selection Tag carries `Actions`; Image gates FullOS Run + Audit reseal on `actions.Count > 0`.
- [x] **WinPECT robustness (lab):** Audit Administrator FullOS unseals DeploymentShare secret in RAM and reconnects `Z:` successfully (elevated context).
- [x] **Domain Join AutoLogon path (non-Audit):** temporary `EnableLUA=0` + `UacBypassed` marker when template has no `<!--AuditMode-->` and actions > 0; FullOS cleanup restores `EnableLUA=1` via `Clear-LiteDeployFullOSRunKey` / `Restore-LiteDeployFullOSUacBypass`.

---

## 2. Priority Research: Scheduled Tasks Entering 'Queued' State

- [x] **Alternative Dispatch Mechanism (HKLM Run):** Adopted as live FullOS entry (specialize-staged); Task Scheduler left gated off for FullOS resume.
- [x] **MDT resume model (research, 2026-10-13):** Stock MDT does **not** use Task Scheduler for LiteTouch resume. First Full OS entry is unattend `FirstLogonCommands` → `LTIBootstrap.vbs` (+ AutoLogon). Mid-deploy reboot survival (`SetStartMDT` in `LiteTouch.wsf`) is either **All Users Startup** shortcut `LiteTouch.lnk` (when Explorer is present) or **`HKLM\...\RunOnce\LiteTouch`** (Server Core / `HideShell`). Goal is Session 1 reliability after shell load — not speed. LiteDeploy’s `HKLM\...\Run` is the same family of interactive-logon hooks.
- [ ] **Task Scheduler 'Queued' Status Root Cause Analysis:** *(deferred — not on critical path while HKLM Run is primary)*
  - [ ] **MultipleInstancesPolicy Evaluation:** Investigate why tasks enter the `Queued` state instead of immediately executing (`Running`). Compare behavior of `MultipleInstances = Parallel` vs `IgnoreNew` vs `Queue` vs `StopExisting`.
  - [ ] **Logon Synchronization & Session 1 Timing:** Audit Windows Audit Mode AutoLogon sequence (`winlogon.exe` → `userinit.exe` → `explorer.exe` → desktop readiness). Verify if Task Scheduler delays execution until the interactive desktop message pump is fully active.
  - [ ] **Account & Principal Binding:** Compare `-UserId 'Administrator'` vs `BUILTIN\Administrators` vs dynamic SID resolution (`*-500`), and test impact of `-LogonType Interactive` vs `ServiceAccount` on queue behavior.
  - [ ] **Task Settings & Power Gates:** Test the effect of `StartWhenAvailable`, `Priority` (default 7 vs 4 vs 0), `DisallowStartIfOnBatteries`, and `ExecutionTimeLimit` settings.

---

## 3. Next Session: Console & Terminal UX Modernization

- [ ] **Console wrap / host lag:** FullOS + Probe windows can slow under heavy colored log + word-wrap; consider minimized Probe, file-first logging, or narrower banner output.
- [ ] **In-Place Driver Progress Counter:** Replace 400+ line terminal floods with a dynamic single-line carriage return counter (`[DRIVERS] Installing: 285/441 (65%) - Intel_I2C.inf`).
- [ ] **Modern Unicode Box-Art Banners:** Add styled framing for phase headers matching active Dark/Light theme tokens.
- [ ] **Pre-Reboot Summary Dashboard Card:** Print an executive summary box (Model, Target Disk, Boot Mode, Image Applied, Drivers Injected, Total Elapsed Time, Log URI) before handoff.
- [ ] **Interactive Reboot Countdown:** 10-second countdown with keypress cancellation (`Press 'C' to cancel reboot`).

---

## 4. Phase 6: FullOS Resume & Package Orchestration

- [x] **specialize HKLM Run + WinPECT Credential Bridge:**
  - [x] Stage Runtime/Tools only (no Admin, no SetupComplete); Image stages HKLM Run; logon launches `LiteDeploy.FullOS.ps1`.
  - [x] Vendor WinPECT under repo `Engine\Tools\WinPECT\` (trimmed) + `LiteDeploy.WinPECT.ps1`; Admin.Build publishes to share; Engine WinPE handoff stages package when secrets are in memory.
  - [x] Publish `LiteDeploy.DeploymentEngine.ps1` as byte-identical Engine alias for legacy BootInitializer.
  - [x] In-memory secret retrieval (`Get-LiteDeployFullOSSecret`) avoiding disk DPAPI `.xml` exports.
  - [x] Native PowerShell `New-SmbMapping` share connect + mirror logs to `WorkLogs\Deployments\<UID>` (Network).
  - [ ] **Package orchestrator** — plan: [PACKAGE_ORCHESTRATOR_PLAN.md](planning/PACKAGE_ORCHESTRATOR_PLAN.md) (diagram + phases). Do not implement until scheduled after Domain Join lab.
    - [ ] **A:** Resolve `actions` → `package.json` Specs → `DeploymentState.Packages.Queue` at handoff (state = execution source).
    - [ ] **B:** FullOS `Start-LiteDeployPackageOrchestration` (Invoke/Install, Remote/Local, 3010 anti-loop, lock, Clear Run).
    - [ ] **C:** Hardening + Progress reads queue; lab no-reboot / 3010 / fail Stop.
  - [ ] **Future (not started):** integrate [DeployVault](https://github.com/cmartinezone/DeployVault) as optional Tools vault → `$global:LiteDeploySecretMap` (account create / run-as-X); see [IDEAS §12](planning/IDEAS_FOR_IMPLEMENTATION.md#12-future-tool-integration-deployvault-credentialvault--not-incorporated-yet). Do not incorporate until scheduled.
- [x] **Persistent User-Session Execution (Current Baseline):**
  - [x] First arm: unattend specialize `reg add` HKLM Run (short `powershell.exe -File`) when actions > 0; first launch at interactive logon → `LiteDeploy.FullOS.ps1`.
  - [x] Reboot survival: FullOS may re-arm `HKLM\...\Run\LiteDeployFullOS` (tasks gated off).
  - [x] Leave stock Setup sysprep CmdLine intact; kill `sysprep.exe` process from FullOS.
  - [x] Clean up legacy Session 0 / AtLogOn LiteDeploy_* tasks on FullOS startup.
  - [x] Auto-mount `Z:` via `New-SmbMapping` in interactive admin session with `EnableLinkedConnections = 1`.
  - [x] Temporary Interactive Probe started by FullOS in a second PowerShell window; replace with real Progress dispatch.
  - [x] WorkflowTag carries `Actions` so Image can gate FullOS Run / Audit reseal.
  - [x] Standard = Audit Admin (elevated); Domain Join = AutoLogon local admin + temporary `EnableLUA=0` when no `<!--AuditMode-->` and actions > 0; cleanup restores UAC.
  - [ ] **Lab verify Domain Join UAC bypass end-to-end** (specialize Orders 1–4 → AutoLogon `user` → FullOS/WinPECT/Z: → cleanup restores EnableLUA).
- [ ] **Future Exploration: Full Headless `SYSTEM` Execution with Decoupled Progress-Only UI:**
  - [ ] **System Execution Parity:** Audit and ensure all actions currently running under `Administrator` (package installs, scripts, registry tweaks, driver servicing) can execute under `NT AUTHORITY\SYSTEM` without desktop token dependencies.
  - [ ] **Silent Installer Validation & Watchdog:** Add process execution timeouts / watchdog guards so non-silent installers with hidden dialogs cannot hang headless in Session 0.
  - [ ] **Headless Network Access:** Utilize direct UNC paths (`\\Server\Share$\...`) or pre-staged local packages (`C:\~LiteDeploy\Content\Packages`), removing any requirement for user-visible mapped drives (`Z:`).
  - [ ] **Decoupled Progress-Only Shell:** User in Session 1 sees *only* a dedicated, full-screen or foreground WPF Progress Bar that observes progress via IPC / `DeploymentState.json` without access to Explorer, CMD, or network drives.
  - [ ] **Complete End-to-End Teardown in SYSTEM:** Cleanup of staging directories, secret stores, and final reseal/OOBE invocation executed entirely within the SYSTEM context.
- [ ] **Power Plan & GPO Immunization:**
  - [ ] Set High Performance (`powercfg`) & suppress screen lock / standby.
  - [ ] Temporarily block background GPO refresh (`DisableGPO = 1`) to prevent domain policies from breaking AutoLogon.
- [ ] **Ephemeral Deployment Service Account (`LD_<UID>`):**
  - [ ] Generate dynamic random GUID password in WinPE with salt.
  - [ ] Inject temporary admin account with `AutoLogonCount = 999` in `unattend.xml`.
  - [ ] Launch interactive desktop session (Session 1) for user-facing application installers and full-screen WPF progress display.
  - [ ] Implement Pre-Reboot Winlogon refresh hook to guarantee survival across intermediate restarts.
  - [ ] Implement automated teardown: delete local account, purge user profile in `C:\Users`, clean Winlogon registry keys, restore GPO, run `gpupdate /force`, and scrub Panther artifacts.
- [ ] **Hybrid Application Package Execution Engine** — folded into [Package Orchestrator Plan](planning/PACKAGE_ORCHESTRATOR_PLAN.md) Phase B (`ExecutionSource` Remote/Local, 3010, ordering via `actions[]`).

- [ ] **Provisioning Packages (`.ppkg`) & Intune / Autopilot Integration:**
  - [ ] Support offline DISM `.ppkg` injection in WinPE Phase 4 (`dism.exe /Image:W:\ /Add-ProvisioningPackage`).
  - [ ] Support `unattend.xml` template `<ProvisioningPackage>` tag expansion for `setup.exe` engine.
  - [ ] Stage offline Autopilot JSON profile (`W:\Windows\Provisioning\Autopilot\AutopilotConfigurationFile.json`) when Intune Ready workflow is selected.
- [ ] **Standard & Workgroup Pre-OOBE Silent App Installation & Native OOBE Handoff:**
  - [ ] Execute silent software package installations (MSI/EXE) under FullOS (Administrator interactive / future SYSTEM worker) before OOBE handoff.
  - [ ] Inject modern AppX/MSIX provisioned packages into offline OS in WinPE (`dism /Add-AppxProvisionedPackage`) for automatic user profile propagation.
  - [ ] Pair with `Standard.xml` (`<HideLocalAccountScreen>false</HideLocalAccountScreen>`) for seamless native interactive local account creation.

---

## 5. Runtime orchestrator names (discussed, not started)

- [ ] Rename the three phase entry points so the file name says where it runs. Shared components (`Disk`, `Image`, `Logs`, `State`, `Environment`, `Workflow`, UI) stay `LiteDeploy.*`.
  - [ ] `LiteDeploy.Boot.ps1` → `LiteDeploy.PE.Boot`
  - [ ] `LiteDeploy.Engine.ps1` → `LiteDeploy.PE.Engine` (WinPE pipeline)
  - [ ] `LiteDeploy.FullOS.ps1` → `LiteDeploy.OS.Engine` (Session 1 resume)
  - [ ] Decide the legacy alias `LiteDeploy.DeploymentEngine.ps1` (byte-identical copy for existing WinPE BootInitializer images).
  - [ ] Update specialize `HKLM Run` so new images launch `LiteDeploy.OS.Engine.ps1`. In-flight installs still point at `LiteDeploy.FullOS.ps1` until republished.

---

## 6. Future analysis (ideas only — do not implement yet)

- [ ] **JSONNormalizer / schema merge** vs current StrictMode `PSObject.Properties[...]` probing in catalog/workflow/BootConfig — see [IDEAS §13](planning/IDEAS_FOR_IMPLEMENTATION.md#13-future-analysis-json-schema-merge-jsonnormalizer-vs-defensive-property-probing). Keep State serializer (depth 8 / JSON depth 10) as-is.
- [x] **Repo source layout:** removed untracked flat `Engine\Scripts\Runtime|Admin\LiteDeploy*.ps1` (+ `UI\`) mirrors; `.gitignore` blocks them. Edit numbered folders only; publish flat to `DeploymentShare` via Admin.Build.
- [x] **`_Templates` / `_Tests`:** underscored root folders for blueprints/inventory and architecture smoke tests (not part of Admin.Build publish).

---

## 7. Documentation & References

- [Docs map](README.md) — architecture / guides / integrations / planning
- [Package Orchestrator Plan](planning/PACKAGE_ORCHESTRATOR_PLAN.md) *(plan + diagrams; not implemented)*
- [Ideas for Implementation](planning/IDEAS_FOR_IMPLEMENTATION.md) *(planning only — not live path)*
- [Component Guide](COMPONENT_GUIDE.md)
- [Architecture smoke tests](../_Tests/README.md)
- [Component templates / inventory](../_Templates/README.md)
- [Driver Handling](guides/DRIVER_HANDLING.md)
- [Architecture Diagrams](architecture/LITEDEPLOY_DEPLOYMENT_DIAGRAM.md)
- [Engine Reading Guide](guides/ENGINE_READING_GUIDE.md)
- [Project Status](architecture/LITEDEPLOY_PROJECT_STATUS.md)
- [Maintenance](guides/MAINTENANCE.md)
