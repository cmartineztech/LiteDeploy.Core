# Operation and maintenance

LiteDeploy Core is the development repository. Edit `Engine\Scripts`; use Admin.Build
to create deployment files. Keep numbered source folders and flat published folders
separate. Do not maintain a second edited copy on the deployment share.

Start with [Understand and control Engine](ENGINE_READING_GUIDE.md) for the variables,
path map, explicit imports, component contracts, and `-ValidateOnly` examples.

## Compatibility and current limits

Use Windows PowerShell 5.1 (`powershell.exe`) as the compatibility baseline. Use `-STA`
for Engine and UI. PowerShell 7 is not the validation baseline for this project.

| Area | WinPE | Full Windows |
| --- | --- | --- |
| Shared helpers | Intended runtime; check optional components | Local import checks covered by smoke tests |
| Precheck, selection, progress | Requires a boot image with working UI dependencies | WPF requires an interactive STA session |
| Disk and OS installation | Current Engine path; validate on disposable VM | Engine is not a post-reboot package runner |
| Package helpers | Only WinPE-compatible payloads can run | Helpers exist; automatic post-reboot phase unfinished |
| Resume | State/logs copied to OS volume | No completed automatic resume orchestration |

The current Engine reports `Completed` after OS installation. It does not mean drivers,
applications, or post-reboot steps completed. Driver application and the FullOS package
phase remain release gaps.

For WinPE, include the optional components needed by the code: WinPE-WMI, WinPE-NetFX,
WinPE-Scripting, WinPE-PowerShell, and WinPE-StorageWMI. Include suitable storage/network
drivers and validate share access on target hardware.

Microsoft lists WPF as unsupported in WinPE-NetFX. LiteDeploy currently uses WPF, so
standard optional components alone do not establish UI compatibility. Validate your
customized boot image or provide a supported UI approach before claiming general WinPE
compatibility. See the [Microsoft WinPE component reference](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-add-packages--optional-components-reference?view=windows-11).

## Safe local checks

From the repository root:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass `
  -File '.\_Tests\Test-LiteDeployArchitectureV2.ps1'
```

The suite lives under `_Tests\` (not under `Engine\Scripts`). It creates small
configuration/screen fixtures, parses maintained scripts, checks metadata, loads shared
helpers, performs read-only disk inventory, verifies explicit paths, and exercises pipeline
stop conditions with inert screens and mocked file/process actions. It does not format disks,
run Windows Setup, connect a deployment share, or install packages. Exit code 0 means these
checks passed; it does not certify an end-to-end deployment or actual WinPE behavior.

Component metadata inventory (also repo-only tooling under `_Templates\`):

```powershell
.\_Templates\Get-LiteDeployComponentInventory.ps1 | Format-Table -AutoSize
```

To inspect the detected environment:

```powershell
. '.\Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
Get-LiteDeployEnvironment
```

## Build and check a published layout

Use a dedicated staging directory:

```powershell
.\Engine\Scripts\Admin\000-Build\LiteDeploy.Admin.Build.ps1 `
  -DeploymentShare 'C:\LiteDeploy-Staging'

powershell.exe -NoProfile -STA -ExecutionPolicy Bypass `
  -File '.\_Tests\Test-LiteDeployArchitectureV2.ps1' `
  -PublishedRuntimeRoot 'C:\LiteDeploy-Staging\Engine\Scripts\Runtime'
```

Admin.Build copies runtime scripts to `Engine\Scripts\Runtime`, UI assets to its `UI`
subfolder, and admin tools to `Engine\Scripts\Admin`. Optional `-Clean` removes existing
files from target script directories before copying; use it only for intentionally
replaceable targets. Publishing does not rebuild boot.wim.

## Keep changes simple

- Keep orchestration in Engine, domain work in its component, and display code in UI.
- Use explicit parameters, returned objects, and actionable errors. Fail required imports
  before deployment begins instead of hiding them behind fallback implementations.
- Load helper functions once at script scope. Dot-sourced parameters share that scope:
  preserve caller inputs such as BootObject. Execute Disk/Image only at their phases.
- Preserve standalone read-only defaults for Disk and Image. An Engine run is not a
  harmless smoke test: it supplies destructive switches after workflow selection.
- Keep PowerShell 5.1 syntax and existing credential handling. Never add secrets to
  command lines or logs. Add dependencies only for demonstrated needs.
- Update component documentation and meaningful regression checks with behavior changes.
  Aim below 1,000 lines for non-UI components. Extract a clear responsibility when helpful;
  keep justified UI or complex cohesive components together and document exceptions.

## Before release

1. Pass the smoke suite under Windows PowerShell 5.1 for source and published layouts.
2. Boot the real WinPE image in a disposable VM. Check networking, authenticated share
   access, storage cmdlets, every screen, and the selected theme.
3. Deploy to a disposable disk. Exercise cancellation, failure, and success. Confirm
   logs/state survive reboot without containing credentials.
4. Test full Windows helpers separately. Record unfinished drivers, packages, and resume
   behavior rather than treating OS-installation success as complete deployment.

WinPEBuilder creates boot media separately. Keep its bootstrap payload synchronized
with the published runtime and record the boot-image version used for testing.

## Current behavior and agreed follow-up

See [the detailed guide](WINPE_BOOTSTRAP.md) for current behavior, agreed changes, failure handling and remaining implementation gaps. Proposed behavior is explicitly marked; this documentation update does not implement it.
