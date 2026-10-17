# LiteDeploy Tools

Source of truth for optional share tools. **Admin.Build** publishes this folder to the live share `Engine\Tools\` (e.g. `C:\DeploymentShare\Engine\Tools\`) and MediaRoot `Engine\Tools\`. Keep each tool in its own subfolder; do not edit only the share copy.

| Tool | Path | Purpose |
| --- | --- | --- |
| [WinPECT](https://github.com/cmartinezone/WinPECT) | `Engine\Tools\WinPECT\` | Secure WinPE → full Windows credential handoff (encrypted package + offline registry bootstrap → in-memory unseal in FullOS). |

## WinPECT files (trimmed)

| File | Role |
| --- | --- |
| `WinPECredentialTransfer.ps1` | Upstream crypto / offline SOFTWARE hive engine |
| `LiteDeploy.WinPECT.ps1` | LiteDeploy defaults: `Export-` / `Import-LiteDeployWinPECTCredentials` |
| `LICENSE` / `SOURCE.md` | MIT attribution |

Upstream CLI wrappers (`New-WPCTTransfer.ps1` / `Import-WPCTTransfer.ps1`), `docs\`, and `Tests\` are not published here. Engine calls the engine functions through the LiteDeploy wrapper.

## What gets staged onto the OS volume (before reboot)

WinPE handoff copies **Runtime + Tools only** — never `Engine\Scripts\Admin`:

```text
W:\~LiteDeploy\
  Engine\Scripts\Runtime\     # Environment, Logs, State, Hardware, Packages, Engine, FullOS, …
  Engine\Tools\WinPECT\
  Content\Credentials\        # CredentialTransfer.bin (encrypted package; unsealed directly in RAM)
  WorkLogs\
  DeploymentState.json
```

SetupComplete.cmd is **not** staged. There is **no** `auditUser` FullOS launch. Image stages `HKLM\...\Run\LiteDeployFullOS` in unattend **specialize** when the workflow has actions; FullOS starts at the first interactive logon. Domain Join (no Audit marker) may also stage temporary `EnableLUA=0`.

## FullOS entry

```powershell
# Specialize (unattend): reg add HKLM\...\Run\LiteDeployFullOS (REG_EXPAND_SZ) when actions > 0
# Domain Join: Orders 3–4 EnableLUA=0 + UacBypassed when no <!--AuditMode-->
# First / later interactive logons: that Run value launches FullOS
& 'C:\~LiteDeploy\Engine\Scripts\Runtime\LiteDeploy.FullOS.ps1' `
    -LocalRootName '~LiteDeploy' `
    -OsDriveLetter $env:SystemDrive
```

Engine FullOS (driven by `DeploymentState.json`):

1. Interactive logon (Audit Admin on Standard, or Domain Join AutoLogon `user`) — Session 1
2. **HKLM Run** launches FullOS (value staged in specialize; FullOS may re-arm for mid-deploy reboots)
3. On load, sets `HKCU\Console\%%Startup` `DelegationConsole` and `DelegationTerminal` so consoles started afterward hand off to Windows Terminal. The current window stays as launched. A registry failure does not stop resume
4. Kills `sysprep.exe` process; leaves stock Setup `CmdLine` (sysprep) intact
5. Loads Runtime components; reads state for UID, `FullOSShare`, `CredentialHandoff`
6. Imports WinPECT secrets in-memory via `Read-WPCTCredentialTransfer`
7. **Network:** reconnects **Z:** via native PowerShell `New-SmbMapping`; `EnableLinkedConnections = 1`
8. Mirrors logs to `Z:\WorkLogs\Deployments\<UID>\`
9. Re-arms `HKLM\...\Run\LiteDeployFullOS` so mid-deploy reboots relaunch FullOS at logon
10. Starts Interactive Probe in a second independent PowerShell window
11. Scheduled-task registration is gated off (`$script:LiteDeployFullOSRegisterTasks = $false`)

Call `Clear-LiteDeployFullOSRunKey` when the deployment finishes successfully so FullOS stops auto-launching at logon and **restores `EnableLUA=1`** if `UacBypassed` was set. Only a legacy LiteDeploy Setup `CmdLine` hijack is cleared (stock sysprep is never wiped).

Media deployments skip share reconnect and share mirroring.

More detail: [_Docs/integrations/Credentials](../../_Docs/integrations/Credentials/README.md) and [deployment diagrams](../../_Docs/architecture/LITEDEPLOY_DEPLOYMENT_DIAGRAM.md).
