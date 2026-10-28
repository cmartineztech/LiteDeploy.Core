# ADR-0001: State Persistence Architecture and PSLocalBase Storage Boundaries

- **Status:** Accepted
- **Date:** 2026-10-27
- **Deciders:** LiteDeploy Architecture & Security Hardening Engineering
- **Scope:** `LiteDeploy.Core`, `PSLocalBase`
- **NIST SP 800-53 Rev 5 Controls:** SC-28 (Protection of Information at Rest), SI-7 (Software, Firmware, and Information Integrity), CM-6 (Configuration Settings), CP-10 (Information System Recovery and Reconstitution)

---

## Context

`LiteDeploy.Core` orchestrates bare-metal Windows deployments across multiple operating system phases and storage boundaries:

1. **WinPE Ephemeral RAM Execution (`X:\~LiteDeploy\Logs\DeploymentState.json`):**
   - Runs from the WinPE RAM disk (`X:`), coordinating Hardware Precheck, Workflow Selection, Disk Preparation, Driver Injection, and OS Image Application (`Setup.exe` or `DISM.exe`).
   - Progress updates between the deployment engine and the out-of-process WPF Progress Host (`LiteDeploy.UI.Progress.ps1`) require low-latency inter-process communication (IPC).

2. **Installed OS Volume Handoff (`<OsDrive>:\~LiteDeploy\Logs\DeploymentState.json`):**
   - Before WinPE reboots into the newly imaged Windows installation, runtime scripts, logs, WinPECT encrypted credential handoff packages, and `DeploymentState.json` are staged onto `<OsDrive>:\~LiteDeploy`.
   - In FullOS, `LiteDeploy.FullOS.ps1` and `LiteDeploy.FullOS.InteractiveProbe.ps1` resume execution, apply post-install packages, restore system security controls (`EnableLUA=1`), and record final deployment status.

3. **Deployment Share Telemetry Sink (`\\<Server>\<Share>\WorkLogs\Deployments\<UID>\DeploymentState.json`):**
   - Multiple concurrent WinPE and FullOS endpoints write per-deployment log files and state snapshots to a shared SMB network folder (`Z:\WorkLogs\Deployments\<UID>`).

During architectural review (`LD-06`, `LD-07`), two questions arose:
- How must `DeploymentState.json` be persisted to prevent partial/truncated files if power is lost or a process terminates mid-write?
- Should `LiteDeploy.Core` replace `DeploymentState.json` with `PSLocalBase` (embedded `winsqlite3.dll` SQLite database in Write-Ahead Logging `WAL` mode), or where are the strict architectural boundaries between JSON state snapshots and `PSLocalBase`?

---

## Decision

### 1. Three-Tier State Persistence Model in `LiteDeploy.Core`

`LiteDeploy.Core` retains its zero-dependency, human-auditable JSON state model for deployment lifecycle state, hardened with atomic crash-safe file replacement:

1. **Tier 1 — High-Frequency UI Progress IPC (Memory-Mapped File in RAM):**
   - Real-time progress bar updates (`Percent`, `Step`, `SubStatus`) between `LiteDeploy.Engine.ps1` and the out-of-process WPF `LiteDeploy.UI.Progress.ps1` run over a named `MemoryMappedFile` (`LiteDeploy_Progress_IPC`) guarded by a named mutex (`LiteDeploy_Progress_Mutex`).
   - High-frequency progress ticks do not hammer disk or SMB storage.

2. **Tier 2 — Durable Phase Checkpoints (Crash-Safe Atomic JSON State Files):**
   - Phase transitions, workflow selections, disk identity records, and finalization outcomes are persisted to `DeploymentState.json` via `Write-LiteDeployStateFile` in `Engine/Scripts/Runtime/040-State/LiteDeploy.State.ps1`.
   - Every write serializes UTF-8 JSON to a process-isolated temporary file (`<Path>.<PID>.tmp`), forces an OS file buffer flush to storage media (`FileStream.Flush($true)`), and atomically swaps the file into place via `[System.IO.File]::Replace($tempPath, $Path, "$Path.bak", $true)` (or `[System.IO.File]::Move` on initial creation) with bounded exponential backoff for transient file locks.
   - **Prohibition of In-Place Truncation:** `Write-LiteDeployStateFile` MUST NEVER fall back to `[System.IO.File]::WriteAllText($Path, ...)` in place on failure, as in-place truncation destroys the existing state checkpoint if a crash or lock occurs mid-write.
   - **Automatic Backup Recovery:** `Read-LiteDeployStateFile` and `Read-LiteDeployStateFromDisk` automatically fall back to `<Path>.bak` if the primary `DeploymentState.json` is missing, zero-length, or fails JSON deserialization after an interrupted write.

3. **Tier 3 — Pluggable Local-Only Structured Store (`PSLocalBase` Integration Boundary):**
   - `Engine/Scripts/Runtime/040-State/LiteDeploy.State.ps1` exposes an optional local state storage provider contract (`Test-LiteDeployLocalDatabasePath`, `Register-LiteDeployStateStorageProvider`, `Get-LiteDeployStateStorageProvider`) for structured local querying or offline catalog indexing via `PSLocalBase`.

### 2. Strict Prohibition of SQLite WAL (`PSLocalBase`) on SMB / Network Shares

`PSLocalBase` databases (`winsqlite3.dll` using `PRAGMA journal_mode=WAL;`) **MUST NEVER** be hosted on or opened from:
- UNC paths (`\\server\share\...` or `\\?\UNC\...`),
- Mapped SMB network drives (`DriveType -eq [System.IO.DriveInfo]::Network`, e.g., `Z:\`), or
- Multi-host shared deployment folders (`WorkLogs\Deployments`).

`Test-LiteDeployLocalDatabasePath` and `Register-LiteDeployStateStorageProvider` enforce this invariant at runtime and reject any network, UNC, or SMB-mapped path before a database connection can be opened.

---

## Rationale

1. **SQLite WAL Incompatibility with SMB Opportunistic Locking:**
   - SQLite's Write-Ahead Logging (`WAL`) mode relies on shared-memory (`-shm` mmap) coordination and byte-range locking primitives that are not coherently supported across SMBv2/SMBv3 network redirectors. Opening a WAL database over SMB risks silent database corruption (`SQLITE_CORRUPT` / `SQLITE_IOERR`) and lock starvation across deployment clients.
2. **Zero-Dependency WinPE & Triage Simplicity:**
   - `DeploymentState.json` can be inspected directly by technicians and incident responders from WinPE, Windows, or Linux log collectors without binary database tooling, while `FileStream.Flush($true)` + `File.Replace` provides atomic durability across power loss and reboot boundaries.
3. **Defense-in-Depth Isolation:**
   - Keeping remote share state as per-deployment (`<UID>`) atomic JSON files eliminates cross-endpoint database contention and limits each endpoint's write surface to its own isolated `WorkLogs\Deployments\<UID>` directory.

---

## Consequences

- **Positive:**
  - Zero risk of truncated or half-written `DeploymentState.json` files during unexpected WinPE/FullOS reboots or power interruptions.
  - Automatic recovery from `.bak` snapshots when reading state across phase handoffs.
  - Hard programmatic guard (`Test-LiteDeployLocalDatabasePath`) prevents accidental misuse of `PSLocalBase` over SMB shares.
- **Negative / Trade-offs:**
  - `File.Replace` creates a companion `DeploymentState.json.bak` file alongside `DeploymentState.json` in local and remote log directories.
  - Central aggregation of thousands of historical deployment records requires an asynchronous collector indexing the per-deployment `DeploymentState.json` files into a local database rather than endpoints writing directly to a shared SQLite file over SMB.
