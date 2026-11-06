# Logs

**ComponentId:** `Logs`  
**Dev folder:** `Runtime/010-Logs`  
**Published:** `Engine\Scripts\Runtime\LiteDeploy.Logs.ps1`

## Purpose

Aligned console logging + CMTrace XML (`LiteDeploy.Execution.log`).

## Triple mirror (append; history preserved)

1. **Local / RAM:** `$env:SystemDrive\~LiteDeploy\WorkLogs\`
2. **Share:** `$global:LiteDeployRemoteLogDir` / `LogLocations.RemoteLogDir`
3. **OS volume:** `$global:LiteDeployOsLogDir` / `LogLocations.OfflineOsLogDir` (e.g. `W:\~LiteDeploy\WorkLogs`) after Disk prep

Each `Write-LiteDeployLog` uses `Add-Content`. Enabling a new mirror copies the full existing file so earlier history is not lost.

## Copying and OS handoff

Logs also owns Initialize-LiteDeployDeploymentShareLogDir, Sync-LiteDeployLogsToShare,
and Sync-LiteDeployArtifactsToOsVolume. Engine passes RuntimePaths explicitly rather than
making these helpers reconstruct folder locations. OS handoff uses the selected OS drive,
copies logs/state, and reports its result. Persisted state does not implement FullOS resume.

<!-- component-contract -->
## Usage and contract

Write console/CMTrace logs and copy logs/state for handoff.

**Source:** [LiteDeploy.Logs.ps1](LiteDeploy.Logs.ps1).

### Requirements and environment

PowerShell 5.1 and writable destinations. Engine supplies RuntimePaths. Read-only sources can reject share copies.

### What runs and changes

Import defines helpers. Direct execution without Message reports settings and may create the log directory while resolving its path; with Message it appends logs. Mirroring writes local/remote/OS destinations. Copy functions can create folders and overwrite copies.

### Results and failures

Initialize share logs returns path or null with warning. OS handoff returns Success, TargetRoot, LogsCopied, StateCopied, Message. Share-copy errors may be suppressed: void output is not verified durability.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| Message | String | <code>""</code> | [Parameter(Mandatory = $false, Position = 0)] [AllowEmptyString()] |
| Level | String | <code>"INFO"</code> | [Parameter(Mandatory = $false, Position = 1)] [ValidateSet("INFO", "SUCCESS", "INIT", "CHECK", "NOTICE", "WARNING", "RETRY", "ERROR", "BOOT", "NETWORK", "ENGINE")] |
| Component | String | <code>"LiteDeploy"</code> | [Parameter(Mandatory = $false, Position = 2)] |
| ForegroundColor | ConsoleColor | <code>[System.ConsoleColor]::White</code> | [Parameter(Mandatory = $false)] |
| LogFileName | String | <code>"LiteDeploy.Execution.log"</code> | [Parameter(Mandatory = $false)] |
| LogPath | String | <code>""</code> | [Parameter(Mandatory = $false)] |
| NoConsole | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |
| NoPrefix | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
. '.\Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
$component = '.\Engine\Scripts\Runtime\010-Logs\LiteDeploy.Logs.ps1'
. $component
Write-LiteDeployLog -Message 'Example entry' -Component Documentation -LogPath 'C:\LiteDeploy-Staging\WorkLogs'
~~~

### Write-LiteDeployLog

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $false, Position = 0)]
        [AllowEmptyString()]
        [string]$Message = "",

        [Parameter(Mandatory = $false, Position = 1)]
        [ValidateSet("INFO", "SUCCESS", "INIT", "CHECK", "NOTICE", "WARNING", "RETRY", "ERROR", "BOOT", "NETWORK", "ENGINE")]
        [string]$Level = "INFO",

        [Parameter(Mandatory = $false, Position = 2)]
        [string]$Component = "LiteDeploy",

        [Parameter(Mandatory = $false)]
        [System.ConsoleColor]$ForegroundColor = [System.ConsoleColor]::White,

        [Parameter(Mandatory = $false)]
        [string]$LogFileName = "LiteDeploy.Execution.log",

        [Parameter(Mandatory = $false)]
        [string]$LogPath = "",

        [Parameter(Mandatory = $false)]
        [switch]$NoConsole,

        [Parameter(Mandatory = $false)]
        [switch]$NoPrefix
    )
~~~

### Sync-LiteDeployLogsToShare

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $true)][psobject]$RuntimePaths,
        
        [string]$RemoteLogDir
    )
~~~

### Sync-LiteDeployArtifactsToOsVolume

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $true)][psobject]$RuntimePaths,
        
        [Parameter(Mandatory = $true)]
        [string]$OsDriveLetter,

        [Parameter(Mandatory = $false)]
        [psobject]$DeploymentState = $null,

        [Parameter(Mandatory = $false)]
        [string]$LocalRootName = "~LiteDeploy"
    )
~~~

## Current behavior and agreed follow-up

See [the detailed guide](../../../../_Docs/guides/LOGGING_AND_FAILURE_DESIGN.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.
