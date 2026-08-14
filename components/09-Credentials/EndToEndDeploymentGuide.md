# End-to-End Zero-Plaintext OS Deployment Architecture

This document describes how LiteDeploy combines **DeployVault** (server-side network vault) and **WinPECT** (client-side pre-installation bootstrap transfer) for a zero-plaintext credential handoff.

Those components live in their own repositories:

- [DeployVault](https://github.com/cmartinezone/DeployVault)
- [WinPECT](https://github.com/cmartinezone/WinPECT) (WinPECredentialTransfer)

This folder in LiteDeploy Core only documents how the engine will call them.

---

## System Architecture & Data Flow

```text
  ┌────────────────────────────────────────────────────────────────────────┐
  │                 Central Deployment Server (DeploymentShare$)           │
  │  - DeployVault.ps1 + localseed.bin + localvault.bin                    │
  │  - Encrypted credential vault at rest (AES-256-CBC + HMAC-SHA256)      │
  │  - Restricted NTFS ACL permissions for deployment reader identities    │
  └───────────────────────────────────┬────────────────────────────────────┘
                                      │
                                      │ 1. Technician authenticates to DeploymentShare$ in WinPE
                                      │ 2. Selects OS Workflow
                                      ▼
  ┌────────────────────────────────────────────────────────────────────────┐
  │                      Target Machine: WinPE Phase                       │
  │  - Dot-sources \\Server\DeploymentShare$\DeployVault.ps1              │
  │  - Fetches workflow credential into RAM via Get-VaultCredential        │
  │  - Passes PSCredential directly to WinPECredentialTransfer (New-WPCT)  │
  │  - Encrypts payload on target C: drive & injects secret into offline   │
  │    SOFTWARE registry hive                                              │
  └───────────────────────────────────┬────────────────────────────────────┘
                                      │
                                      │ 3. Reboot Target Machine into Full OS
                                      ▼
  ┌────────────────────────────────────────────────────────────────────────┐
  │                  Target Machine: Full OS (Specialize/OOBE)             │
  │  - Import-WPCTTransfer reads bootstrap key from local registry         │
  │  - Decrypts package & exports DPAPI PSCredential XML files             │
  │  - Executes Domain Join / Software Install cleanly                      │
  │  - Deletes temporary transfer package & registry key                   │
  └────────────────────────────────────────────────────────────────────────┘
```

---

## Key Security Advantages

1. **Zero Plaintext at Rest on Network Share**: Credentials in `\\Server\DeploymentShare$\Vault\localvault.bin` are encrypted with AES-256-CBC and HMAC-SHA256 tag verification.
2. **Zero Plaintext in Unattended Answer Files**: No passwords are ever written to `Unattend.xml`, `.ini`, `.json`, or task sequence environment log files.
3. **Hardware-Bound Bootstrap Package**: **WinPECredentialTransfer** binds the client package to target machine SMBIOS UUID / BIOS serial attributes.
4. **Self-Destructing Temporary Transfer Artifacts**: After the Full OS boots and imports the credentials via DPAPI, the local transfer package (`CredentialTransfer.bin`) and registry keys are automatically deleted.

---

## Component Roles & Responsibilities

| Component | Location | Role & Responsibility |
| :--- | :--- | :--- |
| **[DeployVault](https://github.com/cmartinezone/DeployVault)** | Network Server (`DeploymentShare$`) | Serves as the central, persistent encrypted repository for workflow secrets (Domain Join Accounts, LAPS Seeds, Service Accounts). |
| **[WinPECT](https://github.com/cmartinezone/WinPECT)** | Target Client (WinPE Phase) | Takes secrets fetched from DeployVault, splits the decryption secret, and packages them safely onto the target disk and offline registry hive across the reboot window. |
| **Full OS Importer** | Target Client (Full OS Phase) | Reads the registry bootstrap secret, decrypts the package, exports DPAPI CLIXML files, and completes OS specialization tasks. |

---

## Complete WinPE Integration Script Example

The following PowerShell script runs inside WinPE to authenticate to the deployment share, retrieve workflow secrets from DeployVault, and hand them off to WinPECredentialTransfer:

```powershell
# ==============================================================================
# Script: LiteDeploy-WinPE-Workflow.ps1
# Executed inside WinPE during MDT / MECM Task Sequence
# ==============================================================================

# 1. Connect & Authenticate to Network Deployment Share
$sharePath = "\\Server\DeploymentShare$"
Write-Host "[1/4] Connecting to Deployment Share..." -ForegroundColor Cyan

if (-not (Test-Path -Path $sharePath)) {
    $shareCred = Get-Credential -Message "Enter credentials to access $sharePath"
    New-PSDrive -Name "DS" -PSProvider FileSystem -Root $sharePath -Credential $shareCred -ErrorAction Stop | Out-Null
    $sharePath = "DS:\"
}

# 2. Dot-Source Engine Modules from the Server Deployment Share
. (Join-Path $sharePath "Tools\DeployVault\DeployVault.ps1")
. (Join-Path $sharePath "Tools\WinPECredentialTransfer\WinPECredentialTransfer.ps1")

# 3. Select Workflow & Retrieve Secrets from DeployVault
Write-Host "[2/4] Loading Workflow Credentials from DeployVault..." -ForegroundColor Cyan

# Example: Selection based on technician wizard UI
$selectedWorkflowId = "DomainJoin-Corp"

$serverVault = Join-Path $sharePath "Vault\localvault.bin"
$serverSeed  = Join-Path $sharePath "Vault\localseed.bin"

# Fetch credential into RAM
$domainJoinCred = Get-VaultCredential `
    -VaultPath $serverVault `
    -SeedPath $serverSeed `
    -CredentialId $selectedWorkflowId

# 4. Hand off Credential to WinPECredentialTransfer
Write-Host "[3/4] Packaging Secret for Target OS via WinPECredentialTransfer..." -ForegroundColor Cyan

$secretMap = @{
    "DomainJoin" = $domainJoinCred
}

# Create encrypted transfer package on target disk & offline SOFTWARE hive
New-WPCTTransferFromObjects `
    -WindowsPath "C:\Windows" `
    -SecretFilePath "C:\Deployment\CredentialTransfer.bin" `
    -RegistrySubKey "Company\CredentialTransfer" `
    -SecretMap $secretMap `
    -RequiredSecretIds @("DomainJoin")

# 5. Clear Sensitive In-Memory Variables
$domainJoinCred = $null
$shareCred = $null
[GC]::Collect()

Write-Host "[4/4] SUCCESS: Credentials securely staged for Full OS first-boot!" -ForegroundColor Green
```

---

## Operational Best Practices

1. **NTFS ACL Lockdown**: Restrict permissions on `\\Server\DeploymentShare$\Vault` so only authorized deployment technician AD groups have Read access.
2. **Safe Logging Verification**: Ensure PowerShell transcription is disabled in WinPE and Full OS deployment images.
3. **Identity-Scoped DPAPI**: Import credentials under the exact identity (`SYSTEM` or local Administrator) that performs post-installation task sequence steps.
