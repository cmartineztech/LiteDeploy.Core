# Environment

**Role:** Normalize the LiteDeploy environment and provide the paths (and named component
locations) every other component needs. This is the single layout authority for Runtime.

Environment owns path settings, WinPE detection, optional share helpers, process execution,
content-path composition, and the shared UI theme setting. Console chrome lives in UI.HostShell.
Boot owns the live WinPE share mount used by the deployment pipeline.

### Contract

| Does | Does not |
| --- | --- |
| Map component **names** → exact script/XAML paths (`Get-LiteDeployComponentPath`) | Import all components automatically |
| Build `RuntimePaths` + `RequiredFiles` from BootObject + Engine’s name list | Guess a second layout when a file is missing |
| Join catalog-relative content to DeploymentRoot (`Resolve-LiteDeployContentPath`) | Create `Content\`, `WorkFlows\`, or log trees unsolicited |
| Expose process/theme helpers | Own Disk/Image/Driver domain work |

Consumers (Engine, Image, Drivers, UI, Admin) must use Environment APIs or Engine-supplied
RuntimeFiles — not `$PSScriptRoot` walks to `DeploymentShare`, silent `Z:\` defaults in the
live pipeline, or parallel path maps. See
[_Docs/architecture/LITEDEPLOY_COMPONENT_REFACTOR_V2.md](../../../../_Docs/architecture/LITEDEPLOY_COMPONENT_REFACTOR_V2.md).

Load Environment once before source components:

```powershell
. '.\Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
$enginePath = Get-LiteDeployComponentPath -Name Engine
```

Production is the default mode. Published scripts are flat beneath `Engine\Scripts\Runtime`,
with UI scripts in `UI`. Change composition in the path settings at the top of Environment.
`DevelopmentFolders` is the only runtime map of numbered repository folders.
An optional absolute `-RuntimeRoot` overrides the component root for staging or custom layouts.

`Get-LiteDeployRuntimePaths -BootObject $boot -RequiredComponents $names` returns deployment,
runtime, log, state, and named RequiredFiles paths. It neither imports components nor creates
directories. Engine declares which names are required for each environment.

Network sources require BootObject.DriveLetter. Media uses MediaDriveLetter plus LocalRootName
(DriveLetter is accepted when MediaDriveLetter is absent). ConfigPath is authoritative when
supplied; otherwise the config is composed beneath the deployment root. Missing files never
trigger a search for another layout or configuration.

`Test-LiteDeployRequiredFiles -Paths $paths.RequiredFiles` reports all missing names/paths.
`Resolve-LiteDeployContentPath` joins catalog-relative paths to the deployment root and rejects
drive-relative paths. `Resolve-LiteDeployEnginePath` lets Boot locate Engine through the same map.

<!-- component-contract -->
## Usage and contract

Own modes, named paths, detection, connections, and process execution.

**Source:** [LiteDeploy.Environment.ps1](LiteDeploy.Environment.ps1).

### Requirements and environment

Windows PowerShell 5.1 and Windows networking APIs for share calls. Load first in source use; DevelopmentFolders/ProductionFiles are the layout map.

### What runs and changes

Import sets shared path settings and defines helpers; it neither imports all components nor connects shares. Direct execution reports environment facts. Explicit connection/process calls perform those actions.

### Results and failures

RuntimePaths contains roots, log/state paths and RequiredFiles. File validation returns Ok/Missing. Unknown names or invalid source context fail rather than select another layout.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |
| Mode | String | <code>'Production'</code> | [ValidateSet('Development', 'Production')] |
| RuntimeRoot | String | <code>''</code> |  |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
. '.\Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
$enginePath = Get-LiteDeployComponentPath -Name Engine
~~~

### Get-LiteDeployComponentPath

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param([Parameter(Mandatory = $true)][string]$Name, [string]$RuntimeRoot = '')
~~~

### Get-LiteDeployRuntimePaths

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $true)][psobject]$BootObject,

        # Engine selects component names; Environment only maps them to exact locations.
        [string[]]$RequiredComponents = @()
    )
~~~

### Test-LiteDeployRequiredFiles

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param([Parameter(Mandatory = $true)][psobject]$Paths)
~~~

### Invoke-LiteDeployProcess

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$FilePath,

        [Parameter(Position = 1)]
        [string]$ArgumentList = "",

        [string]$WorkingDirectory = "",

        [ValidateRange(0, 86400)]
        [int]$TimeoutSeconds = 0,

        [switch]$CaptureOutput,
        [switch]$LogArguments
    )
~~~

## Current behavior and agreed follow-up

See [the detailed guide](../../../../_Docs/guides/WINPE_BOOTSTRAP.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.
