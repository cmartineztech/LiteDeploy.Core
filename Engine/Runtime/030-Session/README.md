# Session

**ComponentId:** `Session`  
**Dev folder:** `Runtime/030-Session`  
**Published:** `Engine\Runtime\LiteDeploy.Session.ps1`

## Purpose

Unified runtime component owning deployment state JSON, RAM IPC for Progress UI, aligned console output, Microsoft CMTrace logging (`LiteDeploy.Execution.log`), destination resolution (local / share / OS volume), and artifact synchronization and verification across WinPE and FullOS.

## Logging & Triple Mirror (append; history preserved)

1. **Local / RAM:** `$env:SystemDrive\~LiteDeploy\WorkLogs\`
2. **Share:** `$global:LiteDeployRemoteLogDir` / `LogLocations.RemoteLogDir`
3. **OS volume:** `$global:LiteDeployOsLogDir` / `LogLocations.OfflineOsLogDir` (e.g. `W:\~LiteDeploy\WorkLogs`) after Disk prep

Each `Write-LiteDeployLog` writes to local storage and mirrors entries to the share and OS volume when configured.

## State & Memory-Mapped IPC

`LiteDeploy.Session` manages `DeploymentState.json` persistence and provides a 1 MB named memory-mapped region (`Local\LiteDeploy.DeploymentState`) for real-time progress synchronization to the separate Progress UI process without disk bottlenecks.

## Security & Redaction

Credentials, secrets, tokens, and sensitive properties are stripped during serialization with `ConvertTo-LiteDeploySerializableObject` and redacted from logged strings via `Protect-LiteDeployStateText`. In-memory objects are never mutated by serialization.

## Usage and contract

```powershell
. '.\Engine\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
$component = '.\Engine\Runtime\030-Session\LiteDeploy.Session.ps1'
. $component

# Write a log entry
Write-LiteDeployLog -Message "Pipeline started" -Level SUCCESS

# Initialize deployment state
$state = New-LiteDeployDeploymentObject -Uid "260806-A3F1"
Save-LiteDeployDeploymentState -DeploymentState $state
```
