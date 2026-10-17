# Workflow

**ComponentId:** `Workflow`  
**Dev folder:** `Runtime/050-Workflow`  
**Published:** `Engine\Scripts\Runtime\LiteDeploy.Workflow.ps1`

## Purpose

Domain logic for OS/workflow catalogs and selection contracts consumed by `UI.WorkflowSelection`. WPF stays under `110-UI/WorkflowSelection`.

### Key Features & Design

1. **Modular Workflow Templates (`DeploymentShare\WorkFlows\*.json`)**:
   - Workflows are defined as independent JSON files with `order`, `expanded`, `enabled`, `comment`, `operatingSystems`, `computerSetup`, and `actions`.
   - Corrupted or invalid workflow JSON files are safely skipped with diagnostic logging.

2. **Native Architecture Filtering**:
   - Uses `Get-LiteDeployNativeArchitecture` to strictly detect hardware platform architecture (`x64`, `arm64`, `x86`).
   - Automatically filters out OS media and editions that do not match the booted machine's CPU architecture.
   - If an enabled workflow has no matching operating systems for the host architecture, a disabled placeholder node is displayed (`⚠️ No available operating systems assigned | Architecture: <arch>`) and deployment start is prevented.

3. **Uniform Presentation Format**:
   - OS catalog items and workflow child nodes are formatted into a single uniform string:
     `Windows 11 Pro (26H2)` with subtitle `Imported: 2026-10-16 | Leng: en-us | Build 10.0.26300.9457`
   - Each selectable child `Tag` includes `WorkflowId`, `UnattendPath`, `ComputerSetup`, **`Actions`**, and OS edition fields. Image uses `WorkflowTag.Actions` to decide whether to stage FullOS Run / Audit reseal in the answer file.

4. **OS Catalog Fallback Mode**:
   - If `WorkFlows\` contains no workflows or all workflows are disabled, the UI automatically falls back to `Content\OperatingSystems\LocalCatalog.json` using `Standard.xml` as default answer file.

5. **Workflow-Level Overrides (`computerSetup`)**:
   - Workflows can define `"computerSetup": { "ImageEngine": "dism.exe" }` (or `Setup.exe`) to override baseline `BootConfig.json` settings per workflow.
   - Optional `"SkipSetupHardwareRequirements": true` overrides BootConfig for Setup.exe LabConfig/MoSetup bypasses (Image applies them; ignored when engine is `dism.exe`).

<!-- component-contract -->
## Usage and contract

Read definitions, validate and resolve plans, and expose explicit action execution.

**Source:** [LiteDeploy.Workflow.ps1](LiteDeploy.Workflow.ps1).

### Requirements and environment

PowerShell 5.1, ShareRoot, workflow JSON and referenced content. Each executable action has its own command/component dependencies.

### What runs and changes

Import defines helpers; direct execution lists/validates. Invoke helpers currently report stub/planned actions; they do not execute workflow steps. Current Engine does not import Workflow; selection UI owns its catalog logic.

### Results and failures

Get returns definitions; Detailed validation returns IsValid/details; Resolve builds a plan. Check invocation results per step. Validation does not execute or guarantee payload success.

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
$component = '.\Engine\Scripts\Runtime\050-Workflow\LiteDeploy.Workflow.ps1'
. $component
Get-LiteDeployWorkflows -ShareRoot 'C:\LiteDeploy-Staging' -IncludeDisabled
~~~

### Get-LiteDeployWorkflows

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = "",

        [Parameter(Mandatory = $false)]
        [string]$OsId = "",

        [Parameter(Mandatory = $false)]
        [string]$EditionId = "",

        [Parameter(Mandatory = $false)]
        [switch]$IncludeDisabled
    )
~~~

### Test-LiteDeployWorkflow

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Identity = "",

        [Parameter(Mandatory = $false)]
        [psobject]$Workflow = $null,

        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = "",

        [Parameter(Mandatory = $false)]
        [switch]$Detailed
    )
~~~

### Resolve-LiteDeployWorkflow

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Identity = "",

        [Parameter(Mandatory = $false)]
        [psobject]$Workflow = $null,

        [Parameter(Mandatory = $false)]
        [psobject]$Selection = $null,

        [Parameter(Mandatory = $false)]
        [string]$OsId = "",

        [Parameter(Mandatory = $false)]
        [string]$EditionId = "",

        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = "",

        [Parameter(Mandatory = $false)]
        [switch]$ActionsOnly
    )
~~~

### Invoke-LiteDeployWorkflow

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Identity = "",

        [Parameter(Mandatory = $false)]
        [psobject]$Workflow = $null,

        [Parameter(Mandatory = $false)]
        [psobject]$Selection = $null,

        [Parameter(Mandatory = $false)]
        [string]$OsId = "",

        [Parameter(Mandatory = $false)]
        [string]$EditionId = "",

        [Parameter(Mandatory = $false)]
        [string]$ShareRoot = "",

        [Parameter(Mandatory = $false)]
        [switch]$ActionsOnly
    )
~~~


