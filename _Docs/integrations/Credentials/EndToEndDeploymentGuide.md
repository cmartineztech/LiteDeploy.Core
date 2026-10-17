> **Status (2026-10-17):** WinPECT source is repo `Engine\Tools\WinPECT\` (trimmed); Admin.Build publishes it to the live share. Engine WinPE handoff stages Runtime/Tools and calls `Export-LiteDeployWinPECTCredentials` when credentials are in memory. FullOS first entry is **HKLM Run** (`LiteDeployFullOS`), staged in unattend **specialize** when workflow actions > 0 (not `auditUser`). On direct execution, before resume, FullOS sets the HKCU console handoff so consoles started afterward use Windows Terminal. Domain Join (no Audit) may stage temporary `EnableLUA=0` + restore on cleanup. FullOS may re-arm Run for mid-deploy reboots, kills `sysprep.exe` (leaves stock Setup CmdLine), and starts the Interactive Probe in a second window. Legacy BootInitializer launches `LiteDeploy.DeploymentEngine.ps1` (byte-identical Engine alias). DeployVault → `$global:LiteDeploySecretMap` and Packages orchestration remain open.

# End-to-End Zero-Plaintext OS Deployment Architecture

How LiteDeploy combines **DeployVault** (server-side network vault) and **WinPECT** (client-side WinPE → FullOS bootstrap transfer).

| Component | Upstream | On the LiteDeploy share |
| --- | --- | --- |
| DeployVault | [DeployVault](https://github.com/cmartinezone/DeployVault) | `Vault\` (+ `Tools\DeployVault\` when published) |
| WinPECT | [WinPECT](https://github.com/cmartinezone/WinPECT) | `Engine\Tools\WinPECT\` (`WinPECredentialTransfer.ps1` + `LiteDeploy.WinPECT.ps1`) |

---

## System Architecture & Data Flow

```text
  ┌────────────────────────────────────────────────────────────────────────┐
  │                 Central Deployment Server (DeploymentShare$)           │
  │  - DeployVault + localseed.bin + localvault.bin (planned fetch)        │
  │  - Engine\Tools\WinPECT\ (LiteDeploy wrapper + crypto engine)          │
  │  - Engine\Scripts\Runtime\ (flat publish via Admin.Build)              │
  └───────────────────────────────────┬────────────────────────────────────┘
                                      │
                                      │ 1. Boot mounts Z:; BootObject.Credential in RAM
                                      │ 2. Engine WinPE: image + stage Runtime/Tools
                                      │ 3. Export-LiteDeployWinPECTCredentials (in-memory secrets)
                                      ▼
  ┌────────────────────────────────────────────────────────────────────────┐
  │                      Target Machine: WinPE Phase                       │
  │  - SecretMap / ShareCredential → Content\Credentials\CredentialTransfer.bin │
  │  - Bootstrap secret → offline SOFTWARE\LiteDeploy\CredentialTransfer   │
  │  - Stage Engine\Tools\WinPECT (no SetupComplete.cmd)                   │
  └───────────────────────────────────┬────────────────────────────────────┘
                                      │
                                      │ 4. Reboot → specialize arms HKLM Run (if actions > 0) → interactive logon
                                      ▼
  ┌────────────────────────────────────────────────────────────────────────┐
  │  Full OS: HKLM Run → LiteDeploy.FullOS.ps1 (Session 1)                 │
  │  - HKCU console handoff (consoles started afterward)                 │
  │  - Kill sysprep.exe; leave stock Setup\CmdLine intact                  │
  │  - Read-WPCTCredentialTransfer in RAM → PSCredential                   │
  │  - Network: New-SmbMapping reconnects Z: (EnableLinkedConnections)     │
  │  - Mirror WorkLogs → Z:\WorkLogs\Deployments\<UID>                     │
  │  - Re-arm HKLM\...\Run\LiteDeployFullOS for package reboots            │
  │  - Start Interactive Probe in a second PowerShell window               │
  └────────────────────────────────────────────────────────────────────────┘
```

```mermaid
sequenceDiagram
    participant WinPE as WinPE Engine Phase 5
    participant Disk as OS volume ~LiteDeploy
    participant Reg as Offline SOFTWARE hive
    participant Admin as LiteDeploy.FullOS.ps1
    participant Probe as InteractiveProbe window

    Note over WinPE: In-memory PSCredential (DeploymentShare / SecretMap)
    WinPE->>Disk: Export-LiteDeployWinPECTCredentials → Content\Credentials\CredentialTransfer.bin
    WinPE->>Reg: Bootstrap under LiteDeploy\CredentialTransfer
    WinPE->>Disk: Stage Runtime + Engine\Tools\WinPECT
    WinPE->>Admin: Reboot into Windows Setup

    Note over Admin: specialize (actions>0): Run + optional DJ EnableLUA=0 → logon → HKLM Run FullOS
    Admin->>Admin: HKCU console handoff for later windows
    Admin->>Admin: Kill sysprep.exe process
    Admin->>Reg: Read bootstrap key from LiteDeploy\CredentialTransfer
    Admin->>Disk: Decrypt package in RAM → PSCredential
    Admin->>Admin: New-SmbMapping Z: (EnableLinkedConnections)
    Admin->>Admin: Re-arm HKLM Run LiteDeployFullOS
    Admin->>Probe: Start-Process second window probe
    Admin->>Admin: Mirror logs; packages planned; clear Run + restore UAC on finish
```

---

## Key Security Advantages

1. **Zero plaintext on the share vault** (when DeployVault is used): AES-256-CBC + HMAC at rest.
2. **Zero plaintext in unattend / state / logs**: passwords never written to answer files or DeploymentState.
3. **Hardware-bound transfer package**: WinPECT binds to SMBIOS UUID / BIOS serial when available.
4. **Self-destructing transfer artifacts**: `.bin` + registry bootstrap removed after successful import when that path is used.

---

## Component Roles

| Component | Location | Role |
| :--- | :--- | :--- |
| **DeployVault** | Share `Vault\` | Persistent encrypted secrets (Domain Join, etc.). Fetch into `$global:LiteDeploySecretMap` (wiring pending). |
| **WinPECT** (`Engine\Tools\WinPECT\`) | Staged on OS volume | Packages in-memory secrets in WinPE; FullOS unseals in RAM. |
| **Engine WinPE handoff** | `Complete-LiteDeployWinPEHandoff` | Stages Runtime/Tools; calls `Export-LiteDeployWinPECTCredentials`. |
| **FullOS** | `LiteDeploy.FullOS.ps1` | HKLM Run first entry (specialize-staged); HKCU console handoff on load; re-arm for resume; Z: reconnect; probe window. |

Paths (LiteDeploy defaults):

- Package / CLIXML: `<OsDrive>\~LiteDeploy\Content\Credentials\`
- Registry: `LiteDeploy\CredentialTransfer`

---

## Engine-owned handoff (preferred)

Normal deployments do **not** call WinPECT manually. After Image succeeds:

1. `Sync-LiteDeployFullOSPayloadToOsVolume` — Runtime + Tools (no Admin; no SetupComplete)
2. `Complete-LiteDeployWinPECredentialHandoff` — export when secrets are in memory
3. Reboot

FullOS:

```text
specialize: reg add HKLM Run LiteDeployFullOS (when actions > 0)
  → interactive logon (Audit Admin or AutoLogon)
  → LiteDeploy.FullOS.ps1
      → kill sysprep.exe
      → re-arm HKLM Run LiteDeployFullOS
      → Start-LiteDeployFullOSInteractiveProbe (second window)
```

Secrets are consumed via `Get-LiteDeployFullOSSecret` / `Read-WPCTCredentialTransfer` in memory (interactive admin context).

---

## Manual WinPE example (outside Engine)

```powershell
. (Join-Path $sharePath 'Engine\Tools\WinPECT\LiteDeploy.WinPECT.ps1')

$global:LiteDeploySecretMap = @{
    DomainJoin = (Get-VaultCredential -VaultPath $serverVault -SeedPath $serverSeed -CredentialId 'DomainJoin')
}

Export-LiteDeployWinPECTCredentials `
    -OsDriveLetter 'W:' `
    -LocalRootName '~LiteDeploy' `
    -SecretMap $global:LiteDeploySecretMap `
    -ShareCredential $shareCred `
    -RequiredSecretIds @('DomainJoin') `
    -AllowOverwrite
```

---

## Operational Best Practices

1. Restrict NTFS on `\\Server\DeploymentShare$\Vault` to deployment reader groups.
2. Keep transcription off in WinPE / FullOS images used for imaging.
3. Import and consume share credentials in memory as the interactive admin (Session 1 via HKLM Run); native `New-SmbMapping` drives operate with `EnableLinkedConnections = 1` without writing DPAPI XML files to disk.

See also [Credentials README](README.md) and [deployment diagrams](../../architecture/LITEDEPLOY_DEPLOYMENT_DIAGRAM.md).
