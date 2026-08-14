# LiteDeploy Project Status and Continuation Handoff

Last architecture review: **August 12, 2026**

Purpose: preserve the current design decisions, implementation inventory, risks, and next steps so development can resume without reconstructing prior discussions.

Related documents:

- [LITEDEPLOY_DEPLOYMENT_PLAN.md](LITEDEPLOY_DEPLOYMENT_PLAN.md)
- [LITEDEPLOY_DEPLOYMENT_DIAGRAM.md](LITEDEPLOY_DEPLOYMENT_DIAGRAM.md)
- [LITEDEPLOY_CATALOG_WORKFLOW_SPEC.md](LITEDEPLOY_CATALOG_WORKFLOW_SPEC.md)
- [WinPEBuilder](https://github.com/cmartinezone/WinPEBuilder) — ISO and `Boot.wim` for WDS/PXE
- [DeployVault](https://github.com/cmartinezone/DeployVault) — credential vault
- [WinPECT](https://github.com/cmartinezone/WinPECT) — WinPE credential transfer

## 1. Product direction

LiteDeploy is being built as an OS-agnostic, JSON-driven bare-metal deployment platform for WinPE and Windows PowerShell 5.1.

The target architecture separates:

- Operating-system media and editions
- Deployment workflows
- Ordered workflow actions
- Reusable packages
- Credentials referenced by ID
- Deployment engine execution
- Read-only progress presentation

The intended production chain is:

```text
startnet.cmd
    → BootInitializer
    → PreCheck
    → SelectWorkflow
    → DeploymentEngine (WinPE)
    → setup.exe /NoReboot
    → Offline handoff staging
    → Controlled reboot
    → SetupComplete or specialize bootstrap
    → EngineResume task (SYSTEM)
    → Workflow actions
    → ProgressUI task (interactive user)
```

## 2. Existing components

### Boot initialization

Location: `components/05-BootInitializer/LiteDeploy.BootInitilizer.ps1`

Implemented:

- WinPE startup-shell behavior
- Boot configuration discovery
- Network initialization and checks
- Deployment-share mapping
- Technician credential prompt
- `BootObject` construction
- Same-process invocation of PreCheck

Required changes:

- Become the explicit sequence orchestrator via `LiteDeploy.DeploymentEngine.ps1`.
- Consume structured PreCheck and workflow results (engine does this).
- Invoke Setup `/NoReboot`, handoff, and FullOS resume from the engine (still stubbed).

### PreCheck UI

Location: `components/06-PreCheck/LiteDeploy.PreCheck.ps1`

Implemented:

- WinPE-compatible WPF UI
- Adaptive Viewbox scaling
- Hardware and configuration assessment
- BootObject input
- Continue, rerun, diagnostics, and cancellation handling

Required changes:

- ~~Return `{ ContinueRequested, PreCheckPassed, Status }`.~~ Done on engine-orchestration branch.
- ~~Close and return control without launching the next component.~~ Done (engine invokes SelectWorkflow).

### Workflow Selection UI

Locations:

- `components/07-SelectWorkflow/LiteDeploy.SelectWorkFlow.ps1`
- `components/07-SelectWorkflow/LiteDeploy.SelecWorkflowDriverPicker.ps1`

Implemented:

- Computer name and description input
- Workflow selection interface
- Internal disk discovery with PowerShell 5.1 single-object binding protection
- Capacity, Estimated Usage, and Available Space calculation
- Persistent blue disk selection after focus changes
- Driver auto-detection and custom WinPE folder picker
- Fixed-position red validation messages and Windows Forms warnings
- Strict BootConfig discovery

Required changes:

- Accept `BootObject` directly.
- Load OS editions from ImportOSMedia `catalog.json`.
- Load workflows and optional deployment profiles from JSON.
- Return a structured deployment selection containing stable IDs and numeric disk number.
- Preserve current UI behavior while making its content catalog-driven.

### OS media importer

Locations:

- `ImportOSMedia/LiteDeploy.ImportOSMedia.ps1`
- `ImportOSMedia/LiteDeploy.ImportOSMediaGUI.ps1`
- `ImportOSMedia/README.md`

Implemented:

- ISO, WIM, ESD, and custom-image ingestion
- DISM metadata and edition discovery
- Architecture, build, language, and SKU metadata
- OS and edition ID generation
- Enable/disable edition management
- Per-media `os.json`
- Central `Content/OperatingSystems/catalog.json`
- GUI and headless operation
- Catalog rebuild

Decision:

`Content/OperatingSystems/catalog.json` is the authoritative OS catalog. Do not build a competing catalog format.

Required additions:

- Add the referenced `schemas/os-catalog.schema.json`.
- Add explicit schema-version handling.
- Consider publishing SHA-256 hashes for Setup and image payloads.
- Always resolve an edition by the compound key `(osId, editionId)`.

### Progress UI

Location: `components/09-Progress/LiteDeploy.Progress.ps1`

Implemented:

- WinPE and FullOS layouts
- JSON deployment-state reader
- Status and percentage rendering
- Completion behavior
- PowerShell 5.1 support

Required changes:

- Adopt the final versioned state schema.
- Tolerate atomic replacement/sharing retries.
- Run as a separate WinPE process.
- Register as an interactive FullOS AtLogon task.

Decision:

The SYSTEM engine and visible progress UI are separate processes. A SYSTEM task is background-only and cannot reliably provide an interactive WPF window.

### Credential systems

Locations:

- [DeployVault](https://github.com/cmartinezone/DeployVault) — encrypted share vault (separate repository)
- [WinPECT](https://github.com/cmartinezone/WinPECT) — WinPE to FullOS credential transfer (separate repository)
- `components/10-Credentials/` — LiteDeploy integration notes and [EndToEndDeploymentGuide.md](../../components/10-Credentials/EndToEndDeploymentGuide.md)

Implemented:

- Encrypted central credential vault
- Credential lookup by ID
- Hardware-bound cross-reboot encrypted transfer
- Offline SOFTWARE-hive bootstrap storage
- FullOS import to DPAPI-protected CLIXML
- Required-secret verification and cleanup

Integration decisions:

- `DeploymentShare` comes from `BootObject.Credential` when needed after reboot.
- Workflows declare the minimum `RequiredCredentialIds`.
- DeployVault resolves only those IDs.
- Vault and seed files are never copied to the target OS.
- WPCT imports credentials under SYSTEM because SYSTEM runs the workflow engine.
- No credential is written to unattended files, JSON, logs, or process arguments.

## 3. Components not yet built

- Versioned workflow catalog and JSON schema
- Versioned package catalog and JSON schema
- Optional deployment-profile catalog
- Cross-catalog resolver and reference validator
- `LiteDeploy.DeploymentEngine.ps1` (Phase A orchestration scaffold; Setup `/NoReboot` still pending)
- Atomic deployment-state manager
- Deployment lock/single-instance manager
- Target-disk safety executor
- Unattended-file generator
- Windows Setup command builder and result validator
- Offline Windows volume locator
- Offline runtime and handoff stager
- `LiteDeploy.FullOSBootstrap.ps1`
- SetupComplete generator
- Unattended `specialize` fallback
- EngineResume scheduled-task registration
- ProgressUI scheduled-task registration
- Workflow runner
- Condition and dependency evaluator
- Package detection engine
- MSI, EXE, MSIX, PowerShell, and CMD package handlers
- Controlled reboot/resume coordinator
- Package integrity validator
- Unified engine logging and final deployment report
- End-to-end recovery and physical-device test suite

## 4. Decisions already made

1. BootInitializer remains the WinPE parent process.
2. PreCheck and SelectWorkflow run in the same PowerShell process as BootInitializer.
3. UI scripts close and return structured results; they do not start their successors.
4. Workflows are OS-agnostic.
5. ImportOSMedia owns OS-media ingestion and the OS catalog.
6. Selections persist both `osId` and `editionId`.
7. Workflows contain ordered actions and reference packages by `packageId`.
8. Initial package types are MSI, EXE, MSIX, PowerShell, and CMD.
9. Every action has a stable ID, detection/completion evidence, timeout, exit codes, and reboot policy.
10. Windows Setup runs with `/NoReboot`; LiteDeploy controls the first reboot.
11. WinPE `/NoReboot` requires compatible Windows 11 24H2-or-newer Setup media.
12. LiteDeploy stages and verifies its FullOS runtime before rebooting.
13. SetupComplete registers scheduled tasks and starts EngineResume immediately.
14. The same idempotent bootstrap is called from unattended `specialize` as an OEM-key safeguard.
15. The FullOS engine runs as SYSTEM.
16. The visible progress UI starts only in an interactive user session; administrator membership is not required.
17. Progress reads state and never controls the deployment engine.
18. Deployment state contains no credentials.
19. Completed workflow actions are never executed again after resume.
20. Failures stop safely and preserve diagnostic state instead of guessing or silently continuing.

## 5. Important operational constraints

### Setup and reboot

- `/NoReboot` suppresses only the first Setup reboot.
- LiteDeploy must wait for Setup and validate its result.
- LiteDeploy must not reboot if Setup or handoff verification fails.
- Windows Setup controls its subsequent installation reboots.
- The FullOS engine controls only workflow-requested reboots.

### SetupComplete

- SetupComplete runs as Local System.
- SetupComplete may be disabled with OEM keys outside Enterprise and Server editions.
- The unattended `specialize` fallback must call the same idempotent bootstrap.

### Progress visibility

- EngineResume begins in the background without requiring a login.
- ProgressUI appears when an interactive user logs on.
- Transferred credentials should not be used to create an insecure AutoLogon configuration.
- If immediate pre-login custom UI becomes mandatory, it requires a separate design and security review.

### Disk safety

- The displayed disk label is not an execution identifier.
- Persist and execute using numeric `DiskNumber`.
- Re-query disk identity immediately before destructive work.
- Reject changed, missing, USB, removable, or ambiguous targets.

## 6. Immediate implementation milestone

Build one complete vertical deployment path before adding more UI or package types:

```text
BootInitializer
    → structured PreCheck result
    → catalog-driven structured Workflow result
    → DeploymentEngine state initialization
    → generate Unattend.xml
    → validate and run Setup /NoReboot
    → stage local runtime + WPCT + bootstrap
    → validate handoff
    → controlled reboot
    → FullOS bootstrap
    → EngineResume under SYSTEM
    → import credentials
    → execute one idempotent PowerShell package
    → update progress state
    → complete and clean up
```

Recommended implementation order:

1. Add structured UI return contracts.
2. Create JSON schemas and the catalog resolver.
3. Implement the state manager and deployment lock.
4. Implement a minimal Deployment Engine.
5. Implement unattended generation and Setup execution.
6. Implement offline staging, WPCT integration, and controlled reboot.
7. Implement FullOS bootstrap and scheduled tasks.
8. Implement one PowerShell package handler with detection.
9. Complete VM interruption tests.
10. Validate on physical hardware before adding MSI, EXE, and MSIX handlers.

## 7. Reliability gates

Before production use:

- Zero wrong-disk operations in the destructive test suite.
- Unsupported or ambiguous media fails before Setup starts.
- Every forced interruption resumes or enters a documented recoverable failure state.
- Completed actions do not execute twice.
- Catalog changes cannot alter the definitions used by an in-progress deployment.
- No secret appears in JSON, unattended files, command lines, or logs.
- WPCT transfer artifacts are removed after verified import.
- Progress UI failure does not stop the engine.
- At least 100 consecutive automated VM deployments complete without an orchestration failure.
- Every supported physical hardware model passes storage, network, driver, scaling, reboot, and resume validation.

## 8. Questions intentionally left open

These decisions should be finalized during implementation:

- Exact workflow and package folder publishing convention
- Whether deployment profiles are mandatory or optional
- Exact Setup success/reboot exit-code allowlist
- Local package caching policy after FullOS boot
- Package signature/hash enforcement policy
- Workflow action rollback behavior where rollback is technically possible
- Final state/report retention period
- How an administrator manually resumes or abandons a failed deployment
- Whether a later management console will publish catalogs and packages

## 9. Definition of the next stopping point

The next milestone is complete only when a VM can:

1. Start from WinPE.
2. Pass PreCheck.
3. Select a real ImportOSMedia catalog edition and a JSON workflow.
4. Run Setup without allowing Setup to perform the first reboot.
5. Stage the engine and encrypted credentials.
6. Reboot under LiteDeploy control.
7. Resume the SYSTEM engine automatically.
8. Execute one declared package action exactly once.
9. Display current state after an interactive login.
10. Finish with verified credential and scheduled-task cleanup.

