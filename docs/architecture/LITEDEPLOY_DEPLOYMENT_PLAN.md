# LiteDeploy Deployment Orchestration Plan

Status: **Proposed implementation plan; orchestration code is not yet implemented.**

This document defines how LiteDeploy will move from WinPE selection into Windows Setup, preserve credentials securely across the reboot, resume the selected workflow in the installed operating system, and display deployment progress.

Related project documents:

- [LITEDEPLOY_DEPLOYMENT_DIAGRAM.md](LITEDEPLOY_DEPLOYMENT_DIAGRAM.md) — architecture and sequence diagrams.
- [LITEDEPLOY_CATALOG_WORKFLOW_SPEC.md](LITEDEPLOY_CATALOG_WORKFLOW_SPEC.md) — OS, workflow, action, and package JSON contracts.
- [LITEDEPLOY_PROJECT_STATUS.md](LITEDEPLOY_PROJECT_STATUS.md) — current implementation inventory and continuation checklist.
- [WinPEBuilder](https://github.com/cmartinezone/WinPEBuilder) — WinPE ISO and `Boot.wim` builder for WDS/PXE (separate repository).
- [DeployVault](https://github.com/cmartinezone/DeployVault) — encrypted credential vault (separate repository).
- [WinPECT](https://github.com/cmartinezone/WinPECT) — WinPE to FullOS credential transfer (separate repository).

## 1. Design goals

- Keep `LiteDeploy.BootInitilizer.ps1` as the parent WinPE shell started by `startnet.cmd`.
- Run PreCheck and workflow selection in the same PowerShell process so the in-memory `BootObject` and deployment-share `PSCredential` are preserved.
- Generate an unattended answer file from the validated workflow selections.
- Run Windows Setup with `/NoReboot` and let LiteDeploy control the first reboot.
- Stage the FullOS engine, progress host, state, and encrypted credentials before rebooting.
- Use `SetupComplete.cmd` to register and start the FullOS continuation tasks.
- Run the deployment engine as `NT AUTHORITY\SYSTEM` and keep its WPF progress UI in an interactive user session.
- Make every transition resumable and idempotent so an unexpected reboot does not repeat destructive disk or Setup operations.
- Never store plaintext credentials in the unattended file, JSON state, command-line arguments, or logs.

## 2. Component responsibilities

| Component | Phase | Responsibility |
| --- | --- | --- |
| `LiteDeploy.BootInitilizer.ps1` | WinPE | Persistent parent shell; loads configuration, initializes networking, maps the deployment source, obtains the share credential, and sequences the UI and engine. |
| `LiteDeploy.PreCheck.ps1` | WinPE | Validates configuration, networking, storage, memory, firmware, Secure Boot, and TPM readiness. Returns a structured result to the parent. |
| `LiteDeploy.SelectWorkFlow.ps1` | WinPE | Collects computer identity, workflow, target disk, and driver selection. Returns a structured selection object. |
| `LiteDeploy.SelecWorkflowDriverPicker.ps1` | WinPE | Reusable WinPE-compatible WPF directory picker used by workflow selection. |
| `LiteDeploy.DeploymentEngine.ps1` | Both | Planned orchestration engine. In WinPE it validates and starts Setup; in FullOS it resumes workflow actions from persisted state. |
| `LiteDeploy.Progress.ps1` | Both | Read-only WPF progress client. It renders `DeploymentState.json`; it does not own deployment operations. |
| [DeployVault](https://github.com/cmartinezone/DeployVault) | WinPE/server | Resolves only the credential IDs declared by the selected workflow. The vault files remain on the deployment source. |
| [WinPECT](https://github.com/cmartinezone/WinPECT) | WinPE to FullOS | Encrypts the required `PSCredential` objects for the target machine and imports them into SYSTEM-owned DPAPI CLIXML after boot. |
| `SetupComplete.cmd` | FullOS bootstrap | Registers the scheduled tasks and immediately starts the engine-resume task. It contains no workflow logic or secrets. |
| Task Scheduler | FullOS | Runs the engine reliably as SYSTEM and starts the progress UI in an interactive session. |

### Planned production layout

The development repository currently separates components into numbered folders. In production, the scripts are expected to be siblings under the deployment source:

```text
<DeploymentRoot>\Engine\Scripts\
  LiteDeploy.BootInitilizer.ps1
  LiteDeploy.PreCheck.ps1
  LiteDeploy.SelectWorkFlow.ps1
  LiteDeploy.SelecWorkflowDriverPicker.ps1
  LiteDeploy.DeploymentEngine.ps1
  LiteDeploy.Progress.ps1
```

The deployment engine must resolve sibling scripts from `$PSScriptRoot`. It must not depend on the numbered development-directory names.

## 3. End-to-end execution sequence

### Phase A: WinPE initialization and selection

1. `startnet.cmd` launches `LiteDeploy.BootInitilizer.ps1` in Windows PowerShell 5.1 STA mode.
2. BootInitializer discovers `BootConfig.json`, initializes networking, connects the deployment source, and creates `BootObject`.
3. BootInitializer invokes PreCheck with `& $preCheckPath -BootObject $bootObject`.
4. PreCheck closes and returns a structured result.
5. If PreCheck did not pass or Continue was not selected, BootInitializer stops without changing a disk.
6. BootInitializer invokes workflow selection in the same process and passes `BootObject`.
7. Workflow selection returns a structured selection object.
8. If the technician cancels, BootInitializer stops without changing a disk.

### Phase B: validation, credentials, and Setup preparation

1. The deployment engine validates the target disk number again against current hardware immediately before any destructive operation.
2. It resolves the selected image, edition/index, drivers, workflow definition, and required credential IDs.
3. It obtains `DeploymentShare` from `BootObject.Credential` when FullOS needs access to the share.
4. It resolves only the selected workflow's required IDs through DeployVault.
5. Missing, disabled, or duplicate required credentials stop deployment before disk modification.
6. It generates the unattended answer file without passwords or serialized credentials.
7. It creates the deployment state and starts the WinPE progress host as a separate process.
8. It launches Windows Setup, waits for it to exit, and records the exit code.

Conceptual invocation:

```powershell
$process = Start-Process `
    -FilePath $setupPath `
    -ArgumentList $setupArguments `
    -Wait `
    -PassThru
```

`$setupArguments` must include `/NoReboot` and the generated unattended answer-file argument. The final command builder will add only switches supported by the selected Setup media.

### Phase C: controlled pre-reboot handoff

LiteDeploy reboots only after all of the following succeed:

1. Windows Setup returns an accepted success code.
2. The installed Windows volume is rediscovered by its Windows directory; drive letter `C:` is not assumed in WinPE.
3. The offline Windows installation and `Windows\System32\Config\SOFTWARE` hive exist.
4. The local LiteDeploy runtime is copied to the installed operating system.
5. The workflow selection and deployment state are persisted atomically.
6. WinPECredentialTransfer writes `Secrets.bin` and its hardware-bound bootstrap material to the offline SOFTWARE hive.
7. `Windows\Setup\Scripts\SetupComplete.cmd` and the FullOS bootstrap script are staged.
8. Every required handoff artifact is re-opened and validated.
9. The state advances to `RebootRequested`.
10. WinPE calls `wpeutil reboot`.

If any verification fails, LiteDeploy does not reboot. It marks the deployment `Failed`, leaves the WinPE console available, and shows a Windows Forms alert containing a safe error message and log location.

## 4. Windows Setup `/NoReboot` requirements

Microsoft documents that `/NoReboot` suppresses only the first reboot. Subsequent Windows Setup reboots are not suppressed. WinPE support begins with Windows 11 version 24H2 Setup.

Required behavior:

- Inspect the Setup executable version before launch.
- Require Windows 11 24H2/26100-or-newer Setup when using `/NoReboot` from WinPE.
- Fail closed when the media does not meet the requirement.
- Never infer success only because `setup.exe` returned; validate its exit code, logs, and offline Windows artifacts.
- Do not reboot after a failed or indeterminate Setup result.

Reference: [Windows Setup command-line options](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-command-line-options?view=windows-11).

## 5. Installed-OS staging layout

The WinPE drive letter for the installed OS is temporary. All paths are built relative to the detected offline Windows volume. After boot, that volume is expected to be `C:` and the runtime layout is:

```text
C:\~LiteDeploy\
  Engine\
    Scripts\
      LiteDeploy.DeploymentEngine.ps1
      LiteDeploy.Progress.ps1
      LiteDeploy.FullOSBootstrap.ps1
    Credentials\
      WinPECredentialTransfer.ps1
      LiteDeploy-FullOS-Credential.ps1
    Secrets\
      <CredentialId>.xml
  State\
    DeploymentSelection.json
    DeploymentState.json
    Secrets.bin
  Logs\
    LiteDeploy.Engine.log
    LiteDeploy.Setup.log

C:\Windows\Setup\Scripts\
  SetupComplete.cmd
```

`Engine\Secrets` must be ACL-restricted to SYSTEM and Administrators. `Secrets.bin` and the temporary bootstrap registry material are deleted after a successful DPAPI import.

## 6. SetupComplete and scheduled-task design

### SetupComplete responsibilities

`SetupComplete.cmd` runs as Local System. It must remain small and deterministic:

1. Call `LiteDeploy.FullOSBootstrap.ps1` using the local Windows PowerShell executable.
2. Pass only the local state path; never pass credentials.
3. Record a bootstrap exit code in the LiteDeploy log.
4. Return control to Windows Setup promptly.

The bootstrap script performs idempotent registration of two tasks and starts the engine task immediately with `schtasks /Run` or the Task Scheduler API.

### Task 1: `\LiteDeploy\EngineResume`

| Setting | Specification |
| --- | --- |
| Identity | `NT AUTHORITY\SYSTEM` |
| Run level | Highest |
| Interaction | Background only |
| Trigger | At system startup; SetupComplete also starts it immediately |
| Action | Windows PowerShell 5.1 with `-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ...\LiteDeploy.DeploymentEngine.ps1 -Resume -StatePath ...\DeploymentState.json` |
| Multiple instances | Ignore new instance |
| Restart policy | Three attempts, 60-second interval |
| Power policy | Do not stop because the device changes to battery power |
| Network | Engine performs its own network readiness wait before share access |
| Completion | Remove or disable the task only after workflow state becomes `Completed`; retain it on failure for diagnostics/retry |

This task imports the WPCT package under SYSTEM, which ensures the resulting DPAPI CLIXML files can be consumed by later SYSTEM workflow actions.

### Task 2: `\LiteDeploy\ProgressUI`

| Setting | Specification |
| --- | --- |
| Identity | Interactive logged-on user |
| Privilege | Standard interactive token is sufficient because the UI only reads state |
| Trigger | At logon |
| Action | Windows PowerShell 5.1 STA mode running `LiteDeploy.Progress.ps1 -Environment FullOS -StatePath ...\DeploymentState.json` |
| Data access | Read-only access to deployment state; no access to credential CLIXML files |
| Completion | Exit when state is `Completed`; remain available for a terminal `Failed` screen |

A task running as SYSTEM does not have interactive logon rights, so its WPF window is not a reliable user-visible progress surface. The engine and UI therefore share the state file but run in different security sessions.

References: [custom Windows Setup scripts](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/add-a-custom-script-to-windows-setup?view=windows-11), [schtasks commands](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/schtasks), and [schtasks create](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/schtasks-create).

### SetupComplete licensing safeguard

Microsoft states that SetupComplete is disabled when an OEM product key is used, except for Enterprise and Windows Server editions. Because LiteDeploy includes Professional workflows, SetupComplete cannot be the only continuation path.

The unattended file should also call the same idempotent `LiteDeploy.FullOSBootstrap.ps1` through `Microsoft-Windows-Deployment\RunSynchronous` in the `specialize` pass. That pass runs in SYSTEM context. Either entry point may run first; both must produce the same task definitions without duplicating workflow execution.

Reference: [RunSynchronous in the specialize pass](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-deployment-runsynchronous).

## 7. Process and data contracts

### PreCheck result

```json
{
  "ContinueRequested": true,
  "PreCheckPassed": true,
  "Status": "Passed"
}
```

The existing PreCheck currently returns only a Boolean when dot-sourced. It must be changed to return this object without launching the next UI itself.

### Workflow-selection result

```json
{
  "DeploymentRequested": true,
  "ComputerName": "X1-DESKTOP01",
  "ComputerDescription": "Finance laptop",
  "WorkflowId": "W11-ENT-STD",
  "WorkflowName": "Windows 11 Enterprise",
  "OperatingSystem": "Windows 11 Enterprise 25H2",
  "DiskNumber": 0,
  "DiskModel": "KBG50ZNS256G NVMe KIOXIA 256GB",
  "DriverMode": "Repository",
  "DriverPath": "Content\\Drivers\\Lenovo\\21KC004AUS",
  "RequiredCredentialIds": [
    "DeploymentShare",
    "DomainJoin"
  ]
}
```

`DiskNumber` must be numeric. Display labels such as `Disk 0` must never be passed to disk-management commands.

### Persisted selection

`DeploymentSelection.json` contains non-secret selections and credential IDs only. It must never contain a username, password, secure string, `PSCredential`, vault seed, or vault payload.

### Deployment state

`DeploymentState.json` is the durable coordination contract between the engine and progress host:

```json
{
  "schemaVersion": 1,
  "deploymentId": "LD-20260812-001",
  "environment": "FullOS",
  "phase": "Workflow",
  "status": "Running",
  "currentStep": "Installing applications",
  "stepNumber": 7,
  "totalSteps": 12,
  "stepPercent": 40,
  "overallPercent": 68,
  "message": "Installing required software",
  "logMessage": "Started workflow action App.Install.Office",
  "lastUpdatedUtc": "2026-08-12T18:30:00Z"
}
```

State writes must use a temporary file followed by an atomic replacement. Readers must tolerate a short sharing violation and retry without resetting the displayed state.

## 8. State machine and resume rules

| State | Owner | Resume behavior |
| --- | --- | --- |
| `Initialized` | WinPE engine | Validate selection and credentials. |
| `SetupStarting` | WinPE engine | Launch Setup only if no successful Setup marker exists. |
| `SetupReturned` | WinPE engine | Validate result and offline Windows installation. |
| `OfflineHandoffStaged` | WinPE engine | Revalidate runtime, state, SetupComplete, and WPCT package. |
| `RebootRequested` | WinPE engine | Reboot once; never rerun Setup. |
| `FullOSBootstrap` | FullOS bootstrap | Register tasks idempotently and start EngineResume. |
| `CredentialImport` | SYSTEM engine | Import WPCT once and verify every required ID. |
| `WorkflowRunning` | SYSTEM engine | Resume at the first incomplete action. |
| `Completed` | SYSTEM engine | Remove temporary transfer data, disable tasks, and close progress UI. |
| `Failed` | Current owner | Preserve safe logs and state; do not advance automatically unless the action explicitly supports retry. |

Each workflow action requires a stable action ID and a completion record. Destructive actions must be idempotent or guarded by durable completion evidence.

## 9. Credential lifecycle

1. The deployment-share `PSCredential` remains in `BootObject.Credential` during WinPE.
2. Workflow definitions declare `RequiredCredentialIds`.
3. The WinPE engine resolves the minimum required credential set from BootObject and DeployVault.
4. Credentials remain as in-memory `PSCredential` objects until passed directly to WinPECredentialTransfer.
5. WPCT creates `C:\~LiteDeploy\State\Secrets.bin` and stores bootstrap material in the offline `HKLM\SOFTWARE\LiteDeploy\Temp` location.
6. The FullOS SYSTEM engine imports the package to `C:\~LiteDeploy\Engine\Secrets\<CredentialId>.xml` using SYSTEM DPAPI.
7. Workflow actions request a declared credential by ID and validate that the imported object is a `PSCredential`.
8. Successful import deletes the transfer package and temporary registry material.
9. Final workflow cleanup removes DPAPI credential files when they are no longer required.

Prohibited:

- Copying `localvault.bin` or `localseed.bin` onto the target OS.
- Writing plaintext or reversible passwords into `Unattend.xml`.
- Serializing credentials into `DeploymentState.json` or `DeploymentSelection.json`.
- Passing passwords on a process command line.
- Logging secure strings, password values, or serialized credential objects.

## 10. Logging and diagnostics

- WinPE logs: `X:\~LiteDeploy\WorkLogs` until the offline OS is available.
- Before reboot, copy relevant WinPE logs into the installed OS `C:\~LiteDeploy\Logs` directory.
- FullOS engine log: `C:\~LiteDeploy\Logs\LiteDeploy.Engine.log`.
- Record timestamps in UTC, deployment ID, phase, action ID, status, safe message, and exit code.
- Collect Windows Setup logs after Setup returns and after FullOS starts, but do not copy unrelated sensitive content into the UI state.
- The progress UI displays a friendly error and log path; detailed exceptions remain in the engine log.

## 11. Failure policy

- Before disk modification: show an alert and return to selection where safe.
- After disk modification but before Setup: mark `Failed`; do not silently restart selection.
- Setup failure: capture the exit code and Setup logs; do not reboot.
- Handoff validation failure: do not reboot.
- FullOS credential import failure: stop workflow actions that require credentials and preserve the scheduled task for repair.
- Workflow action failure: apply only the retry policy declared for that action.
- Progress UI failure: must not stop the engine; restarting the UI reconstructs its view from state.

## 12. Implementation order

1. Add structured return contracts to PreCheck and workflow selection.
2. Define the workflow catalog schema, image metadata, action IDs, and `RequiredCredentialIds`.
3. Create `LiteDeploy.DeploymentEngine.ps1` with state-machine and atomic-state helpers.
4. Implement unattended generation and media/version validation.
5. Implement Setup launch with `/NoReboot`, exit-code handling, and offline Windows discovery.
6. Integrate DeployVault and WinPECredentialTransfer before reboot.
7. Create the FullOS bootstrap and idempotent scheduled-task definitions.
8. Add SetupComplete and `specialize` fallback generation.
9. Connect the FullOS engine resume path and workflow action runner.
10. Connect the interactive progress task.
11. Add VM tests, PowerShell 5.1 tests, forced-reboot resume tests, credential cleanup tests, and physical WinPE validation.

## 13. Acceptance criteria

- Canceling PreCheck or workflow selection never changes a disk.
- A single detected physical disk binds to the UI without `ItemsSource` conversion errors.
- Setup never reboots before LiteDeploy has staged and verified the FullOS handoff.
- Unsupported Setup media is rejected before Setup starts.
- Re-running SetupComplete or the `specialize` bootstrap does not create duplicate engines or duplicate workflow actions.
- The SYSTEM engine continues without an interactive user.
- The progress window becomes visible after an interactive logon and accurately reconstructs current state.
- Required credentials survive the reboot encrypted, import under SYSTEM, and are never present in plaintext artifacts.
- A reboot during FullOS workflow execution resumes at the first incomplete action.
- Successful completion removes temporary credential-transfer material and disables or removes continuation tasks.
