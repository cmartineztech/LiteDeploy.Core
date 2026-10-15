# Boot

**ComponentId:** `Boot`  
**Dev folder:** `Runtime/000-Boot` (repo organization only)  
**Published:** `Engine\Scripts\Runtime\LiteDeploy.Boot.ps1` (also WinPE `~\LiteDeploy\Boot\`)

## Purpose

WinPE parent process started by `startnet`. Discovers `BootConfig.json`, validates network when needed, mounts the deployment share with **native PowerShell** (`New-PSDrive` / `New-SmbMapping` + `PSCredential`), builds `BootObject`, launches `LiteDeploy.Engine.ps1` in the same STA process.

## Notes

- Never uses `net use` with passwords on a process command line.
- Bootstrap loads Environment from `$env:SystemDrive\~LiteDeploy\Runtime\LiteDeploy.Environment.ps1`.
  Use `-EnvironmentPath` for another bootstrap location. Environment then supplies named Logs
  and Hardware paths. These files are required.
- For source use, preload Environment with `-Mode Development`, then call the path returned
  by `Get-LiteDeployComponentPath -Name Boot`. Boot does not search numbered folders.
- Soft failures show GUI retry where applicable and `[NOTICE]` / `startnet` guidance.

<!-- component-contract -->
## Usage and contract

Connect the source and pass one in-memory BootObject to Engine.

**Source:** [LiteDeploy.Boot.ps1](LiteDeploy.Boot.ps1).

### Requirements and environment

Windows PowerShell 5.1 STA, Environment, Logs, Hardware, BootConfig.json, network/media content, and SMB credentials when needed.

### What runs and changes

Direct execution discovers config, may initialize networking, prompt for credentials and mount a share, then launches real deployment. Import loads helpers and prints a banner. Preload Environment for Development; EnvironmentPath selects the bootstrap file otherwise.

### Results and failures

Returns source/config/connection facts and EngineScriptPath through Get-LiteDeployBootConfig. Failures lead to retry/error guidance. Do not serialize credentials. Engine path prefers `LiteDeploy.Engine.ps1` and can fall back to the BootInitializer alias `LiteDeploy.DeploymentEngine.ps1`. After imaging handoff, FullOS is entered via specialize-staged HKLM Run → `LiteDeploy.FullOS.ps1` at interactive logon (Engine `-ResumeFullOS` remains for compat).

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| ExplicitConfigPath | String | <code>""</code> | [Parameter(Mandatory = $false)] |
| MountShare | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |
| ShowGuiError | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false)] |
| EnvironmentPath | String | <code>(Join-Path $env:SystemDrive '~LiteDeploy\Runtime\LiteDeploy.Environment.ps1')</code> |  |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
. '.\Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
$component = '.\Engine\Scripts\Runtime\000-Boot\LiteDeploy.Boot.ps1'
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

See [the detailed guide](../../../../_Docs/guides/LOGGING_AND_FAILURE_DESIGN.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.

## Current behavior and agreed follow-up

See [the detailed guide](../../../../_Docs/guides/WINPE_BOOTSTRAP.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.
