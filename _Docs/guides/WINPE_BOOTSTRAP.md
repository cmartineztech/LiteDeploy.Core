# WinPE bootstrap placement

Reviewed 2026-10-14 against Admin.Build, Boot, Environment, and BootInitializer compat. These paths describe current code. They do not certify end-to-end deployment. See [project status](../architecture/LITEDEPLOY_PROJECT_STATUS.md) for release gaps. Doc map: [`_Docs/README.md`](../README.md).

## Files inside boot.wim

At boot, the image normally becomes X:. Keep the default ~LiteDeploy layout:

```text
X:\~LiteDeploy\
  Boot\LiteDeploy.Boot.ps1
  Runtime\LiteDeploy.Environment.ps1
  Runtime\LiteDeploy.Logs.ps1
  Runtime\LiteDeploy.Hardware.ps1
  Config\BootConfig.json
```

| Repository source under Engine/Scripts/Runtime | Destination beneath mounted image root |
| --- | --- |
| 000-Boot/LiteDeploy.Boot.ps1 | ~LiteDeploy/Boot/LiteDeploy.Boot.ps1 |
| 020-Environment/LiteDeploy.Environment.ps1 | ~LiteDeploy/Runtime/LiteDeploy.Environment.ps1 |
| 010-Logs/LiteDeploy.Logs.ps1 | ~LiteDeploy/Runtime/LiteDeploy.Logs.ps1 |
| 030-Hardware/LiteDeploy.Hardware.ps1 | ~LiteDeploy/Runtime/LiteDeploy.Hardware.ps1 |

Numbered folders organize development only. Do not copy Admin.Drivers as a bootstrap dependency. Boot loads Environment once; Environment maps the remaining bootstrap files. Production is the default mode. A custom bootstrap location requires an explicit EnvironmentPath and matching startup configuration.

## Stage an already-mounted image

Run from the repository root in Windows PowerShell 5.1. Replace the example mount path with the verified mount directory:

```powershell
& '.\Engine\Scripts\Admin\000-Build\LiteDeploy.Admin.Build.ps1' `
    -WinPEStagingPath 'C:\WinPE_Build\Mount'
```

Admin.Build copies the four scripts. It does not copy BootConfig.json, edit startnet.cmd, mount/commit a WIM, or rebuild an ISO. Avoid -Clean unless intentionally replacing the destination: its cleanup also removes JSON files in the bootstrap tree.

Place the existing bootstrap configuration at C:\WinPE_Build\Mount\~LiteDeploy\Config\BootConfig.json. Configure Deployment.Type and, for Network, Deployment.NetworkPath. Do not put a share password in JSON.

Add the launch command to Windows\System32\startnet.cmd inside the mounted image, preserving other required startup commands:

```bat
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%SystemDrive%\~LiteDeploy\Boot\LiteDeploy.Boot.ps1"
```

Current Boot invokes wpeinit itself. Review any existing startup initialization to avoid unnecessary repetition. WIM commit and media creation belong to the separate boot-image build process.

## Deployment source

Publish the full runtime **and Tools** to the live share the VM mounts:

```powershell
.\Engine\Scripts\Admin\000-Build\LiteDeploy.Admin.Build.ps1 -DeploymentShare 'C:\DeploymentShare'
```

Network Boot maps the source to **Z:** and resolves Engine at:

| File | Role |
| --- | --- |
| `Z:\Engine\Scripts\Runtime\LiteDeploy.Engine.ps1` | Canonical Engine (current Boot) |
| `Z:\Engine\Scripts\Runtime\LiteDeploy.DeploymentEngine.ps1` | **Byte-identical** alias for legacy BootInitializer |

Admin.Build always overwrites the alias from `LiteDeploy.Engine.ps1`. Do not keep a separate older DeploymentEngine on the share. Environment `Resolve-LiteDeployEnginePath` prefers Engine, then falls back to the alias.

Also published: `Engine\Tools\WinPECT\` (from repo `Engine\Tools\`) and Runtime UI under `Runtime\UI\`. Keep Config, Content, and WorkFlows at the deployment root. Boot attempts to load `Z:\Config\BootConfig.json` after connecting.

For Media deployment, the source root is `<media drive>:\~LiteDeploy` (or configured LocalRootName), with Engine\Scripts\Runtime, Tools, Config, Content, and WorkFlows beneath it. Bootstrap stays inside WinPE.

## Requirements and limits

Use Windows PowerShell 5.1, STA for UI, and the agreed Windows 11 24H2-or-newer Setup baseline. WinPE needs appropriate WMI, NetFX, Scripting, PowerShell, StorageWMI components and storage/network drivers. Check the ADK package dependencies and matching image architecture.

Microsoft lists WPF as unsupported in WinPE-NetFX. Current LiteDeploy UI is WPF: adding optional components alone does not establish support. Validate the actual customized image or provide a supported UI before claiming general WinPE compatibility. [Microsoft component reference](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-add-packages--optional-components-reference?view=windows-11).

Boot does not assign deployment IDs. Engine uses provisional local precheck state, assigns the ID immediately before WorkflowSelection, and creates the share log folder only after Passed=true and target validation. After imaging, WinPE handoff stages Runtime/Tools and WinPECT credentials (no SetupComplete). Image stages `HKLM\...\Run\LiteDeployFullOS` in unattend specialize when the workflow has actions; FullOS starts at interactive logon (not `auditUser`), may re-arm Run for later reboots, and kills `sysprep.exe` while leaving stock Setup CmdLine intact (see [Credentials](../integrations/Credentials/README.md)).
