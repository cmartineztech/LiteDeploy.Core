# Packages

**ComponentId:** `Packages`  
**Dev folder:** `Runtime/090-Packages`  
**Published:** `Engine\Scripts\Runtime\LiteDeploy.Packages.ps1`

## Purpose

Package discovery/install helpers for future FullOS phases. The current Engine neither imports
nor executes Packages. Its FullOS requirements list describes a planned baseline; automatic
resume and package orchestration remain unfinished.

<!-- component-contract -->
## Usage and contract

Discover/validate packages and provide explicit staging/install functions.

**Source:** [LiteDeploy.Packages.ps1](LiteDeploy.Packages.ps1).

### Requirements and environment

PowerShell 5.1, ShareRoot, package.json, payload and required executable/services. WinPE only runs compatible payloads; FullOS installers may need elevation/user session.

### What runs and changes

Standalone lists; import defines helpers. Invoke runs payloads; Install can stage and run them, changing OS state. Current Engine does not import/run Packages.

### Results and failures

Detailed validation returns IsValid/errors. Invocation reports Success, Status, ExitCode, RebootRequired and execution details. Install reports staging/invocation. Check results even without exceptions; timeout is failure.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| ShareRoot | String | <code>""</code> | [Parameter(Mandatory = $false)] |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
. '.\Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
$component = '.\Engine\Scripts\Runtime\090-Packages\LiteDeploy.Packages.ps1'
. $component
Get-LiteDeployPackages -ShareRoot 'C:\LiteDeploy-Staging' -IncludeDisabled
~~~

### Get-LiteDeployPackages

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = "",

        [Parameter(Mandatory = $false)]
        [string]$PackageType = "",

        [Parameter(Mandatory = $false)]
        [switch]$IncludeDisabled
    )
~~~

### Test-LiteDeployPackage

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$PackageId = "",

        [Parameter(Mandatory = $false)]
        [psobject]$Package = $null,

        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = "",

        [Parameter(Mandatory = $false)]
        [string]$PayloadPath = "",

        [Parameter(Mandatory = $false)]
        [switch]$Detailed
    )
~~~

### Invoke-LiteDeployPackage

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$PackageId = "",

        [Parameter(Mandatory = $false)]
        [psobject]$Package = $null,

        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = "",

        [Parameter(Mandatory = $false)]
        [string]$PayloadPath = "",

        [Parameter(Mandatory = $false)]
        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $false)]
        [hashtable]$Parameters = @{},

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 0,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeDisabled
    )
~~~

### Install-LiteDeployPackage

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$PackageId = "",

        [Parameter(Mandatory = $false)]
        [psobject]$Package = $null,

        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = "",

        [Parameter(Mandatory = $false)]
        [string]$Destination = "",

        [Parameter(Mandatory = $false)]
        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $false)]
        [hashtable]$Parameters = @{},

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 0,

        [Parameter(Mandatory = $false)]
        [switch]$StageOnly,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeDisabled
    )
~~~
