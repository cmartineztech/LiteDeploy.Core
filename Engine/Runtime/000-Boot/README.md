# PE.Boot

**ComponentId:** `PE.Boot`  
**Dev folder:** `Runtime/000-Boot` (repo organization only)  
**Published:** `Engine\Runtime\LiteDeploy.PE.Boot.ps1` (also WinPE `~LiteDeploy\Engine\Runtime\LiteDeploy.PE.Boot.ps1`)

## Purpose

WinPE parent process started by `startnet`. Discovers `BootConfig.json`, validates network hardware, link, and DHCP, tests SMB port 445 connectivity, prompts for credentials via CredUI dialog, mounts the deployment share with **native PowerShell** (`New-PSDrive` / `New-SmbMapping` + `PSCredential`), builds `BootObject`, and launches `LiteDeploy.PE.Engine.ps1` in the same STA process.

## Notes

- **Zero External Dependencies:** `Dependencies = @("None")`. Does not require `Environment.ps1`, `Logs.ps1`, or `Hardware.ps1` inside `boot.wim`. Contains embedded CMTrace logging and network detection.
- Never uses `net use` with passwords on a process command line.
- Native WinPE RAM location: `X:\~LiteDeploy\Engine\Runtime\LiteDeploy.PE.Boot.ps1`.
- Soft failures show GUI retry where applicable and `[NOTICE]` / `startnet` guidance.

<!-- component-contract -->
## Usage and contract

Connect the source and pass one in-memory BootObject to Engine.

**Source:** [LiteDeploy.PE.Boot.ps1](LiteDeploy.PE.Boot.ps1).

### Requirements and environment

Windows PowerShell 5.1 STA, BootConfig.json, network/media content, and SMB credentials when needed.

### What runs and changes

Direct execution discovers config, initializes WinPE networking, prompts for credentials and mounts `Z:`, then launches `LiteDeploy.PE.Engine.ps1`.

### Results and failures

Returns source/config/connection facts and EngineScriptPath through Get-LiteDeployBootConfig. Failures lead to retry/error guidance. Do not serialize credentials. Launches `Z:\Engine\Runtime\LiteDeploy.PE.Engine.ps1`. After imaging handoff, FullOS is entered via specialize-staged HKLM Run → `LiteDeploy.OS.Engine.ps1` at interactive logon.

### Script parameters

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| ExplicitConfigPath | String | <code>""</code> | [Parameter(Mandatory = $false)] |
| MountShare | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |
| ShowGuiError | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |

### Example

From the repository root in Windows PowerShell 5.1:

~~~powershell
$component = '.\Engine\Runtime\000-Boot\LiteDeploy.PE.Boot.ps1'
. $component # Helpers only.
~~~

### Get-LiteDeployBootConfig

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [string]$ConfigPath = "",
        [switch]$ShowGuiError,
        [switch]$MountShare
    )
~~~

## Current behavior and agreed follow-up

See [the detailed guide](../../../_Docs/guides/LOGGING_AND_FAILURE_DESIGN.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.

## Current behavior and agreed follow-up

See [the detailed guide](../../../_Docs/guides/WINPE_BOOTSTRAP.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.
