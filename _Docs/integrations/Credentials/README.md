# Credentials

LiteDeploy keeps credential *integration* documentation here. Runtime transfer tooling lives in repo `Engine\Tools\` and is published by Admin.Build to the live share (`C:\DeploymentShare\Engine\Tools\`, etc.).

| Role | Location | What it does |
| --- | --- | --- |
| Server vault | [DeployVault](https://github.com/cmartinezone/DeployVault) | Encrypted credential store on the share (`Vault\`). **Future tool only** — not wired yet; see [IDEAS §12](../../planning/IDEAS_FOR_IMPLEMENTATION.md#12-future-tool-integration-deployvault-credentialvault--not-incorporated-yet). Target: RAM → `$global:LiteDeploySecretMap` for domain/local account create and run-as-X (no plaintext unattend). |
| Cross-reboot transfer | [WinPECT](https://github.com/cmartinezone/WinPECT) at `Engine\Tools\WinPECT\` | WinPE → OS handoff → In-Memory secret decryption (`Read-WPCTCredentialTransfer`), zero plaintext or DPAPI `.xml` files written to disk. |

## Paths

| Artifact | Path |
| --- | --- |
| Transfer package | `<OsDrive>\~LiteDeploy\Content\Credentials\CredentialTransfer.bin` (in-memory decryption; zero disk exposure) |
| Fallback CLIXML | `<OsDrive>\~LiteDeploy\Content\Credentials\*.xml` (legacy/fallback DPAPI support if present) |
| Registry bootstrap | `HKLM\SOFTWARE\LiteDeploy\CredentialTransfer` (offline SOFTWARE hive in WinPE / HKLM in FullOS) |
| Staged tools | `<OsDrive>\~LiteDeploy\Engine\Tools\WinPECT\` |

## Engine\Tools\WinPECT (trimmed runtime)

| File | Role |
| --- | --- |
| `WinPECredentialTransfer.ps1` | Upstream crypto / offline hive engine (supports `Read-WPCTCredentialTransfer`) |
| `LiteDeploy.WinPECT.ps1` | LiteDeploy paths + `Export-` / `Import-LiteDeployWinPECTCredentials` |
| `LICENSE` / `SOURCE.md` | Attribution |

Upstream CLI wrappers, `docs\`, and `Tests\` are not published on the share.

## FullOS Entry and Share Connection

| Mode | Entry | Role |
| --- | --- | --- |
| **WINPE** | `-BootObject` | Image OS; stage Runtime/Tools; WinPECT export when secrets are in memory |
| **FULLOS (first)** | `HKLM\...\Run\LiteDeployFullOS` | Interactive logon after specialize staged the Run value (when workflow actions > 0) |
| **FULLOS (reboot)** | Same Run value | Mid-deploy reboot survival (FullOS may re-arm; clears on finish) |

Specialize stages Run with a short `cmd /c reg add … /t REG_EXPAND_SZ` Path (same pattern as computer description). Nested-quoted PowerShell inside `reg add /d` breaks Setup specialize parse — avoid it. There is **no** `auditUser` FullOS launch.

### What WinPECT transfers

In-memory `PSCredential` only:

- **`DeploymentShare`** from `BootObject.Credential` / `$global:LiteDeployCredential`
- Entries in `$global:LiteDeploySecretMap` (e.g. `DomainJoin` from DeployVault)

No plaintext in unattend, state JSON, or logs. Secrets reside in RAM only.

### FullOS sequence (state-driven)

```mermaid
flowchart TD
    Gate{"actions.Count > 0?"}
    Gate -->|No| OOBE["Skip FullOS Run → OOBE"]
    Gate -->|Yes| Spec["specialize: Order 2 HKLM Run<br/>+ DJ Orders 3–4 EnableLUA=0 + LD-UID"]
    Spec --> Logon["Interactive logon<br/>Audit Admin or LD-UID AutoLogon"]
    Logon --> Run["HKLM Run → LiteDeploy.OS.Engine.ps1"]
    Run --> Power["Set-LiteDeployFullOSHighPerformance<br/>(0 sleep/timeouts AC/DC)"]
    Power --> Shield["Enable-LiteDeployFullOSShielding<br/>(DisableGPO=1, CAD/Lock off, Count=999)"]
    Shield --> Console["HKCU console handoff"]
    Console --> Kill["Kill sysprep.exe process"]
    Kill --> State["Load DeploymentState.json"]
    State --> Read["Read-WPCTCredentialTransfer in RAM"]
    Read --> Net{"DeploymentType = Network?"}
    Net -- Yes --> Z["New-SmbMapping Z: + EnableLinkedConnections"]
    Z --> Mirror["Mirror WorkLogs → Z:\\WorkLogs\\Deployments\\<UID>"]
    Net -- No --> Local["Logs stay on OS volume only"]
    Mirror --> Arm["Re-arm HKLM Run LiteDeployFullOS"]
    Local --> Arm
    Arm --> Probe["Start Interactive Probe second window"]
    Probe -.->|reboot 3010| Hook["Pre-Reboot Hook: Set-LiteDeployFullOSAutoLogon<br/>(re-inject password, domain='.')"]
    Hook --> Reboot["Reboot → AutoLogon → Run relaunches FullOS"]
    Reboot --> Run
    Probe --> Done["Teardown: Disable-LiteDeployFullOSShielding (gpupdate)<br/>+ Clear Run + restore UAC + delete LD-UID"]
```

Interactive model: **Session 1** (Standard = Audit + built-in Administrator; Domain Join = AutoLogon ephemeral local `LD-<UID>` + temporary UAC bypass + Environment Shielding) with `EnableLinkedConnections = 1` for Explorer-visible `Z:`. Universal High Performance power scheme and FullOS Environment Shielding protect execution. On load, FullOS writes the HKCU console handoff so later consoles use Windows Terminal. Pre-Reboot Hook (`Set-LiteDeployFullOSAutoLogon`) re-injects credentials with `DefaultDomainName = '.'` before intermediate restarts to guarantee AutoLogon survival. First arm of Run = unattend specialize; FullOS re-arms for mid-deploy reboots; stock Setup sysprep left intact; probe = independent second window; keep HKLM Run as primary resume. Note: SYSTEM Session 0 daemon has been retired from the roadmap; all FullOS execution is interactive desktop (Session 1).

See [EndToEndDeploymentGuide.md](EndToEndDeploymentGuide.md), [Tools README](../../../Engine/Tools/README.md), and [deployment diagrams](../../architecture/LITEDEPLOY_DEPLOYMENT_DIAGRAM.md).
