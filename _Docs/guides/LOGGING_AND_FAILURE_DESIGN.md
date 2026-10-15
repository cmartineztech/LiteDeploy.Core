# Console, logging, and failure design

Updated 2026-10-07. **Logging changes are approved direction, not implemented.** The separate returned-BootConfig/confirmed-target safeguard is now implemented. Examples below are proposed output. Current Logs writes console and CMTrace entries; centralized NDJSON, DEBUG, hardware-inventory snapshots, and uniform failure presentation are not complete.

## Ownership and formats

Keep Write-LiteDeployLog in Logs as the central entry point; small component wrappers may forward to it. Separate severity from component. Render INFO/Boot as [BOOT], INFO/Disk as [DISK], and results as [SUCCESS], [WARNING], [ERROR], [RETRY], or [NOTICE]. Other activity labels: CONFIG, MODE, NETWORK, SHARE, ENGINE, HARDWARE, WORKFLOW, DRIVERS, IMAGE, PACKAGES, STATE. No normal console timestamps, duplicate tags, raw stack traces, or repeated percentage output. Use color as reinforcement, never the sole meaning.

Keep LiteDeploy.Execution.log in CMTrace format. Do not mix bracketed plain-text records into it. Optional LiteDeploy.Execution.ndjson holds structured events. Use Level=DEBUG for file-only details, not a separate custom -Debug switch. Prefer existing NoConsole and LogPath concepts, one banner helper and one failure-summary helper over many formatting functions.

Fields: UTC timestamp, level, component, environment (WinPE/FullOS), phase, step, deploymentId, computerName, message; exception type/message, source script/line and process exit code when relevant. Use one deploymentId, not an independent ID per component. Before selection it is null; preserve original startup events when copying logs after confirmation. Never log passwords, credentials, tokens, product keys or decrypted secrets; sanitize messages and command arguments before every sink. Current State still retains ProductKey during serialization: that is a separate unresolved defect, not a guarantee of the current implementation.

```json
{"timestamp":"2026-10-07T19:11:32.412Z","level":"SUCCESS","component":"Disk","environment":"WinPE","phase":"DiskPreparation","step":"ValidateLayout","deploymentId":"261007-A3F1","computerName":"CONF-12345","message":"Disk layout validated."}
```

Keep local diagnostics under the Environment-resolved runtime paths; examples use X:\~LiteDeploy\WorkLogs. Create the share deployment folder only after selection passes and target validation. Share mirroring failure warns and leaves local logging available. Continue only if the next operation does not require the unavailable source. Preserve logical deployment identity across the future FullOS handoff.

## Hardware inventory

Current HardwarePrecheck returns inventory; Engine retains it in memory after a pass. Boot importing Hardware does not log a complete snapshot. Planned: log a readable hardware summary once plus detailed inventory and readiness results in file output, including available inventory on failure/cancellation and when checks are skipped. Reuse the inventory rather than repeatedly querying it. Missing data is Unknown/Unavailable, not success.

Record manufacturer, model, SKU, serial, UUID, CPU, memory, architecture, firmware/BIOS, Secure Boot, TPM, disks, network adapters/MAC/IP and readiness outcomes. Keep details file-visible at INFO, not DEBUG-only. Log collection limitations. Hardware inventory failure should affect deployment only where a required readiness condition cannot be established.

## Proposed normal console sequence

```text
==========================================================================
                            LiteDeploy v2.0
==========================================================================
 Environment : WinPE
 Log         : X:\~LiteDeploy\WorkLogs\LiteDeploy.Execution.log
--------------------------------------------------------------------------
 [BOOT]       Loading bootstrap components...
 [BOOT]       Initializing WinPE services and networking...
 [CONFIG]     Loading bootstrap configuration...
 [SUCCESS]    Bootstrap configuration loaded.
 [MODE]       Deployment source: Network
 [NETWORK]    Checking network adapter and link...
 [SUCCESS]    Network link is active.
 [NETWORK]    Waiting for a usable IPv4 address...
 [SUCCESS]    IPv4 address available: 10.20.30.145
 [NETWORK]    Checking deployment server connectivity...
 [SUCCESS]    Deployment server is reachable over SMB.
 [SHARE]      Sign-in required.
              Enter deployment-share credentials in the dialog.
              Use DOMAIN\username or username@domain.
 [SHARE]      Attempting to connect...
 [SUCCESS]    Deployment share connected as Z:
 [CONFIG]     Loading deployment configuration from the share...
 [ENGINE]     Launching LiteDeploy Engine...
 [HARDWARE]   Collecting hardware inventory and checking readiness...
 [SUCCESS]    Hardware precheck passed.
 [WORKFLOW]   Opening workflow selection...
              Deployment ID: 261007-A3F1
 [SUCCESS]    Workflow selection confirmed.
 [STATE]      Creating deployment log folder and copying startup logs...
 [DISK]       Preparing confirmed target: Disk 0...
              Existing data on this disk will be erased.
 [SUCCESS]    Disk layout created and validated.
 [DRIVERS]    Preparing the selected driver content...
 [IMAGE]      Generating the Windows answer file...
 [IMAGE]      Starting Windows Setup...
 [SUCCESS]    Windows Setup process completed.
 [IMAGE]      Checking the target installation...
```

Only print success when verified. Optional computer/registration values appear only when applicable; no product key. Media skips network/share authentication. Driver details and fallback are defined in [Driver handling](DRIVER_HANDLING.md). Staging is not installation. Future FullOS output must show the same Engine/deployment ID, state validation, package actions, final checks and actual completion. Current Completed means the WinPE imaging phase, not FullOS/packages.

## Boot scenario coverage

| Condition | Current branch and proposed presentation |
| --- | --- |
| Metadata request | Return metadata before initialization; no normal boot output. |
| Bootstrap Environment/Logs/Hardware missing | Can throw before current catch. Planned minimal console fallback if Logs cannot load; no promise a file was written. |
| WinPE initialization/power operation fails | Some failures are currently suppressed. Check results before success messages; distinguish optional tuning from required initialization. |
| Explicit configuration path supplied | Checked first; missing explicit file currently falls back to RAM/media. Make fallback visible. |
| No explicit configuration found | In WinPE check system-drive ~LiteDeploy\Config, then external media. First discovered candidate wins. |
| Configuration on USB declares Network | Still run network branch; physical file location does not decide mode. |
| Missing/unreadable/empty/malformed bootstrap config | Current parsing can conflate these with missing file. Proposed distinct error + stop notice. |
| Missing/unknown Deployment.Type | Proposed explicit Network/Media validation; current branches lack this diagnostic. |
| Media | Resolve Engine from configuration drive + LocalRootName. No network checks. |
| NetworkPath missing | Error dialog/notice; do not request credentials. |
| NIC absent | Retry/Cancel; Retry reinitializes WinPE networking and scans again. |
| Link down | Retry/Cancel; explain cable/adapter/switch checks. |
| No IPv4 after 30 seconds | Retry/Cancel; current checks exclude loopback and 169.254.*. Do not claim IPv6 support or DHCP success merely because a static address exists. |
| SMB TCP 445 unavailable | Retry/Cancel. Success proves endpoint reachability, not share authorization. |
| Share sign-in | Existing Get-Credential controls prompt appearance. Show target share and wait message; never credentials. |
| Sign-in cancelled | One cancellation notice; no Engine launch. |
| Share connection fails | Retry/Cancel, request credentials again. Do not assume every error is a wrong password. |
| Existing Z: | Current code attempts disconnection then accepts an accessible drive. Verify its actual remote target before claiming correct share. |
| Share BootConfig absent | Current warning and retain bootstrap settings; Engine must validate retained config. |
| Share BootConfig malformed | Throws outside current Engine-launch catch. Planned outer Boot handler must present a standard failure. |
| Engine missing | Show resolved expected path, stop notice. |
| Engine throws | Current Boot catches escaped Engine invocation exceptions, logs, shows GUI error and notice. |
| Engine handles failure internally | No throw reaches Boot. Avoid duplicate summaries. |
| Retry dialog cannot display | Current helper returns Retry; this can loop. Proposed console fallback and stop, never automatic retry. |
| Full Windows invocation | Skips WinPE initialization; this Boot path is not the future FullOS resume implementation. |
| Dot-source Boot | No standalone Engine launch, but current top-level initialization/banner still run. |

Standalone Boot currently forces MountShare and ShowGuiError on its configuration call. Noninteractive helper calls can return Stop when GUI retries are not enabled. FullOS should not receive a WinPE startnet recovery instruction.

## Failure presentation

A throw reaches catch; a returned Success=false or Status=Failed does not. Each caller must inspect results. Planned outer Boot handler catches otherwise-unhandled initialization errors; Engine handles phase failures and returns a clear outcome. Present a failure once through the shared helper. OK acknowledges a stop, Retry retries only the defined operation, Cancel stops. Recoverable extraction failure continues without a blocking dialog.

```text
 [ERROR]      Windows Setup failed.
              Component: Image
              Step: RunWindowsSetup
              Exit code: <actual process exit code>

 [NOTICE]     Deployment has stopped.
              Review the execution log and correct the issue.
              Run startnet to restart LiteDeploy in WinPE.
              Restarting may repeat disk preparation.
```

GUI: concise sanitized message, component/step/exit code, consequences, log location and OK. No raw stack trace. If GUI fails, console still reports stop. If logging fails, retain console failure and do not claim diagnostics were saved. Do not call a stopped operation paused/resumable without a real resume mechanism.

```text
 [SHARE]      Sign-in cancelled.
 [NOTICE]     Boot initialization stopped.
              Deployment Engine was not launched.
              Run startnet when ready to try again.
```

```text
 [WARNING]    Driver pack extraction failed.
 [DRIVERS]    Clearing deployment staging...
 [NOTICE]     Continuing with Windows inbox drivers.
              Additional drivers may need installation afterward.
```

Cancellation is not a deployment-failed banner. Share-copy warnings do not imply source content is available. Missing Windows artifacts must not be reported as verified installation. FullOS invalid state stops package execution without inventing a new deployment ID. Do not assert disks are unchanged if Engine might already have formatted them.

## Verification still required

Test normal/cancelled credentials, inaccessible GUI, invalid configuration, denied/read-only logs, lost share, retry cancellation, disk mismatch, missing artifacts, extractor timeout/failure, and FullOS state failure in appropriate fixtures and disposable VMs. Do not add a new progress bar or percentage stream as part of this proposal; current Progress behavior is unchanged until explicitly revised.

