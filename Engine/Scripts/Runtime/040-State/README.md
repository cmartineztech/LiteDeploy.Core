# State

**ComponentId:** `State`  
**Dev folder:** `Runtime/040-State`  
**Published:** `Engine\Scripts\Runtime\LiteDeploy.State.ps1`

## Purpose

Owns `DeploymentState.json`, live `$global:LiteDeployDeployment`, resume/validation helpers, and Progress-compatible readers.

## Persistence / IPC

Saved state omits RegisteredOrganization and RegisteredOwner when null, empty, or whitespace.
Populated strings are retained. Other false/null configuration values are not removed by this
rule, and the in-memory BootConfig is not modified.

| Target | Mechanism |
| :--- | :--- |
| RAM IPC | Named memory-map `Local\LiteDeploy.DeploymentState` (Progress polls this first) |
| Local file | `X:\~LiteDeploy\DeploymentState.json` (WinPE RAM disk) |
| Share | `LogLocations.RemoteLogDir\DeploymentState.json` |
| OS volume | `W:\~LiteDeploy\DeploymentState.json` when OfflineOs paths are set |

Credentials are stripped on serialize. Never logged.

<!-- component-contract -->
## Usage and contract

Maintain deployment state and publish it to memory and files.

**Source:** [LiteDeploy.State.ps1](LiteDeploy.State.ps1).

### Requirements and environment

PowerShell 5.1, writable destinations, Windows memory maps. Engine supplies state and paths; Logs is used when available.

### What runs and changes

Import defines helpers; direct execution reads/displays state. New/Update/Save/Resume can change active state and write files. Resume reactivates state; it does not run FullOS orchestration.

### Results and failures

Get returns state. Test returns a boolean by default; with Detailed it returns IsValid, Errors, Warnings. Save returns state with PassThru. Inspect validation/write warnings before relying on recovery data.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| StatePath | String | <code>""</code> | [Parameter(Mandatory = $false)] |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
. '.\Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
$component = '.\Engine\Scripts\Runtime\040-State\LiteDeploy.State.ps1'
. $component
$state = Get-LiteDeployState -Path 'C:\LiteDeploy-Staging\DeploymentState.json' -FromFile
Test-LiteDeployState -State $state -Detailed
~~~

### Get-LiteDeployState

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Path = "",

        [Parameter(Mandatory = $false)]
        [switch]$FromFile
    )
~~~

### Save-LiteDeployDeploymentState

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $true)]
        [psobject]$DeploymentState,

        [Parameter(Mandatory = $false)]
        [string]$Path = "",

        [Parameter(Mandatory = $false)]
        [switch]$NoRemote,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )
~~~

### Test-LiteDeployState

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $false, Position = 0)]
        [psobject]$State = $null,

        [Parameter(Mandatory = $false)]
        [string]$Path = "",

        [Parameter(Mandatory = $false)]
        [switch]$Persisted,

        [Parameter(Mandatory = $false)]
        [switch]$Detailed
    )
~~~

### Resume-LiteDeployState

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $false)]
        [string]$Path = "",

        [Parameter(Mandatory = $false)]
        [string]$DeploymentUid = "",

        [Parameter(Mandatory = $false)]
        [psobject]$BootObject = $null,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [switch]$NoActivate,

        [Parameter(Mandatory = $false)]
        [switch]$NoSave
    )
~~~

Engine calls New-LiteDeployDeploymentObject -DeferUid for provisional pre-check state. It assigns DeploymentUid just before WorkflowSelection launches. Other callers retain automatic ID generation by default. Remote paths remain empty until selection passes and its target is validated. Provisional state is diagnostic, not a resumable deployment.

## Current behavior and agreed follow-up

See [the detailed guide](../../../../_Docs/guides/LOGGING_AND_FAILURE_DESIGN.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.
