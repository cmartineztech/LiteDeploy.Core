# WinPE bootstrap placement

Reviewed 2026-11-06 against Admin.Build, LiteDeploy.PE.Boot, LiteDeploy.PE.Engine, and LiteDeploy.OS.Engine. These paths describe current code. They do not certify end-to-end deployment. See [project status](../architecture/LITEDEPLOY_PROJECT_STATUS.md) for release gaps. Doc map: [`_Docs/README.md`](../README.md).

## Files inside boot.wim

At boot, the WinPE RAM disk permanently mounts as **X:**. Because `LiteDeploy.PE.Boot.ps1` is completely self-contained and zero-dependency (`Dependencies = @("None")`), it is the **only** script required inside `boot.wim`, located directly in `Engine\Runtime\`:

```text
X:\~LiteDeploy\
  Engine\Runtime\LiteDeploy.PE.Boot.ps1
  Config\BootConfig.json
```

| Repository source under Engine/Runtime | Destination beneath mounted image root |
| --- | --- |
| 000-Boot/LiteDeploy.PE.Boot.ps1 | ~LiteDeploy/Engine/Runtime/LiteDeploy.PE.Boot.ps1 |

`LiteDeploy.PE.Boot.ps1` does not require any helper scripts inside `boot.wim`. It contains embedded CMTrace-compliant logging (`Write-LiteDeployLog`), network hardware checking (`Test-LiteDeployNetworkHardware`), DHCP / link-up waiting, SMB port 445 connectivity probing, CredUI credentials prompt, and persistent share mounting (`Z:`).

All modular runtime components (`LiteDeploy.Session.ps1`, `LiteDeploy.Environment.ps1`, `LiteDeploy.Hardware.ps1`, `LiteDeploy.PE.Engine.ps1`, UI packages, and tools) reside exclusively on the deployment share (`Z:\Engine\Runtime\`) and are invoked directly from the share once mounted. Production is the default mode.

## Stage an already-mounted image

Run from the repository root in Windows PowerShell 5.1. Replace the example mount path with the verified mount directory:

```powershell
& '.\Engine\Admin\000-Build\LiteDeploy.Admin.Build.ps1' `
    -WinPEStagingPath 'C:\WinPE_Build\Mount'
```

Admin.Build copies `LiteDeploy.PE.Boot.ps1` into `~LiteDeploy\Engine\Runtime\`. It does not copy BootConfig.json, edit startnet.cmd, mount/commit a WIM, or rebuild an ISO. Avoid `-Clean` unless intentionally replacing the destination: its cleanup also removes JSON files in the bootstrap tree.

Place the bootstrap configuration at `C:\WinPE_Build\Mount\~LiteDeploy\Config\BootConfig.json`. Configure `Deployment.Type` and, for Network, `Deployment.NetworkPath`. Do not put a share password in JSON.

Add the launch command to `Windows\System32\startnet.cmd` inside the mounted image (a ready-to-use template is maintained in the repository at `DeploymentShare\Content\BootMedia\startnet.cmd`):

```cmd
@echo off
set "BOOT_SCRIPT=X:\~LiteDeploy\Engine\Runtime\LiteDeploy.PE.Boot.ps1"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -NoExit -File "%BOOT_SCRIPT%"
```

> [!NOTE]
> `LiteDeploy.PE.Boot.ps1` runs `wpeinit.exe`, sets the High Performance power scheme via `powercfg.exe`, and initializes network hardware internally. Do not add a duplicate `wpeinit` invocation to `startnet.cmd`.

## Deployment source

Publish the full runtime **and Tools** to the live share the VM mounts:

```powershell
.\Engine\Admin\000-Build\LiteDeploy.Admin.Build.ps1 -DeploymentShare 'C:\DeploymentShare'
```

Network Boot maps the source to **Z:** and hands off execution to the canonical WinPE Engine:

| File | Role |
| --- | --- |
| `Z:\Engine\Runtime\LiteDeploy.PE.Engine.ps1` | Canonical WinPE Orchestrator (invoked by `LiteDeploy.PE.Boot.ps1`) |
| `Z:\Engine\Runtime\LiteDeploy.OS.Engine.ps1` | FullOS Orchestrator (invoked after reboot into the installed OS) |

No backward compatibility aliases (e.g. `LiteDeploy.DeploymentEngine.ps1`) are generated or maintained. All scripts use strict, domain-prefixed naming.

Also published: `Engine\Tools\WinPECT\` (from repo `Engine\Tools\`) and Runtime UI under `Runtime\UI\`. Keep Config, Content, and WorkFlows at the deployment root. Boot attempts to load `Z:\Config\BootConfig.json` after connecting.

For Media deployment, the source root is `<media drive>:\~LiteDeploy` (or configured LocalRootName), with Engine\Runtime, Tools, Config, Content, and WorkFlows beneath it. Bootstrap stays inside WinPE.

## Requirements and limits

Use Windows PowerShell 5.1, STA for UI, and the agreed Windows 11 24H2-or-newer Setup baseline. WinPE needs appropriate WMI, NetFX, Scripting, PowerShell, StorageWMI components and storage/network drivers. Check the ADK package dependencies and matching image architecture.

Microsoft lists WPF as unsupported in WinPE-NetFX because standard WinPE lacks 3D hardware graphics acceleration drivers. Under default hardware-accelerated rendering, WPF attempts Direct3D device creation, which fails with `E_OUTOFMEMORY` translated into `System.OutOfMemoryException` upon window display (`$window.ShowDialog()`).

To solve this deterministically, LiteDeploy mandates **Software-Only WPF Rendering** across all WinPE UI components (`HardwarePrecheck`, `WorkflowSelection`, `Progress`, and preemptively in `LiteDeploy.PE.Engine.ps1`). Assemblies must be imported first (`Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase`), followed immediately by:
```powershell
[System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly
```
This forces WPF (`wpfgfx`) to render entirely via CPU rasterization, guaranteeing flawless dialog execution in WinPE. [Microsoft component reference](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-add-packages--optional-components-reference?view=windows-11).

Boot does not assign deployment IDs. Engine uses provisional local precheck state, assigns the ID immediately before WorkflowSelection, and creates the share log folder only after Passed=true and target validation. After imaging, WinPE handoff stages Runtime/Tools and WinPECT credentials (no SetupComplete). Image stages `HKLM\...\Run\LiteDeployFullOS` in unattend specialize when the workflow has actions; FullOS starts at interactive logon (not `auditUser`), may re-arm Run for later reboots, and kills `sysprep.exe` while leaving stock Setup CmdLine intact (see [Credentials](../integrations/Credentials/README.md)).
