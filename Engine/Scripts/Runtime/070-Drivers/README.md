# Drivers

**ComponentId:** `Drivers`  
**Dev folder:** `Runtime/070-Drivers`  
**Published:** `Engine\Scripts\Runtime\LiteDeploy.Drivers.ps1`

## Purpose

LocalCatalog / driver folder detection is implemented. Runtime extraction, staging and Setup /InstallDrivers integration are not implemented.

For standalone use, load Environment first with the correct mode. Drivers reuses existing
Logs and Hardware functions; if absent, it imports their named Environment paths once.

**Paths:** Engine/UI must pass an explicit ShareRoot / DeploymentRoot. The standalone
fallback that defaults to `Z:\` when ShareRoot is empty is an authoring convenience only —
not the Environment path contract for the live pipeline.

<!-- component-contract -->
## Usage and contract

Match hardware/catalogs and expose extraction/staging helpers.

**Source:** [LiteDeploy.Drivers.ps1](LiteDeploy.Drivers.ps1).

### Requirements and environment

PowerShell 5.1, preloaded Environment for Logs/Hardware paths, ShareRoot and LocalCatalog.json. Extraction needs appropriate archive support.

### What runs and changes

Standalone detects without installing. Import loads helpers/dependencies once. Expand/Stage are non-destructive stubs: they do not extract, copy or apply drivers. Engine detection does not complete Windows driver application.

### Results and failures

Test returns CatalogFound, IsDetected, MatchBy, SourceKind, RelativePath, PathExists, Passed, Detection. In-box fallback can pass without a matched pack. Standalone errors warn and may return null.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |
| ShareRoot | String | <code>""</code> | [Parameter(Mandatory = $false)] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
. '.\Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
$component = '.\Engine\Scripts\Runtime\070-Drivers\LiteDeploy.Drivers.ps1'
. $component
Test-LiteDeployDrivers -ShareRoot 'C:\LiteDeploy-Staging'
~~~

### Get-SystemDriverDetection

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $true)]
        [string]$ShareRoot
    )
~~~

### Test-LiteDeployDrivers

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param([string]$ShareRoot = "")
~~~

### Stage-LiteDeployDrivers

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [string]$ShareRoot = "",
        [psobject]$Detection = $null,
        [string]$DestinationPath = ""
    )
~~~


## Current behavior and agreed follow-up

See [the detailed guide](../../../../_Docs/guides/DRIVER_HANDLING.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.
