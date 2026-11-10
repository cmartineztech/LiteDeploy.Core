# LiteDeploy FullOS Shielding & Teardown Matrix

## Executive Summary

During FullOS execution (Phase 5 & Phase 6), especially in **Domain Join** or **Non-Administrator** workflows (e.g., using the ephemeral service account `LD-<UID>`), Windows background mechanisms (Group Policy client, screen blanking, sleep timers, interactive legal notice banners, and UAC elevation prompts) can interrupt or terminate the automated deployment pipeline.

To ensure deterministic, zero-interruption execution without requiring interactive human intervention, LiteDeploy applies a controlled **Environment Shielding (Blindaje)** policy at the start of FullOS.

Every setting modified or suppressed is backed up in the registry under `HKLM:\SOFTWARE\LiteDeploy\FullOS\ShieldingBackup` so that upon completion, the **Teardown & Cleanup** sequence (`Disable-LiteDeployFullOSShielding` and `Clear-LiteDeployFullOSRunKey`) completely restores the system to a clean, secure enterprise state before end-user handoff.

---

## Shielding & Cleanup Matrix

| # | Component / Setting | Target Location / Command | Scope | Backup Location | Purpose During Deployment | Restored In Teardown / Cleanup |
|---|---|---|---|---|---|---|
| **1** | **High Performance Power Plan** | `powercfg.exe /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c` | **Universal** (all deployment types) | `HKLM:\SOFTWARE\LiteDeploy\FullOS\ShieldingBackup\OriginalPowerScheme` | Maximizes CPU throughput and disk IOPS during imaging and package installation. | Optional on completion: can reset to Balanced (`381b4222-f694-41f0-9685-ff5bb260df2e`) or let corporate GPO take over. |
| **2** | **Sleep / Hibernate / Standby / Display Timeouts** | `powercfg.exe /change monitor-timeout-ac 0`<br>`powercfg.exe /change disk-timeout-ac 0`<br>`powercfg.exe /change standby-timeout-ac 0`<br>`powercfg.exe /change hibernate-timeout-ac 0` (and DC) | **Universal** (all deployment types) | Default Windows power profiles | Prevents system suspension, standby, and display sleep mid-deployment. | Reset via `powercfg.exe /restoredefaultschemes` or corporate GPO upon handoff. |
| **3** | **Group Policy Background Processing (`DisableGPO`)** | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\System`<br>`DisableGPO = 1` (DWORD) | **Non-Admin / Domain Join / UAC Bypass** | `HKLM:\SOFTWARE\LiteDeploy\FullOS\ShieldingBackup\DisableGPO` | Freezes domain GPO refresh while running under `LD-<UID>`, preventing domain policies from prematurely resetting UAC, forcing Ctrl+Alt+Del, or killing AutoLogon. | **Mandatory**: `Remove-ItemProperty -Name DisableGPO`, followed by `gpupdate.exe /force` so domain policies apply cleanly on handoff. |
| **4** | **Interactive Legal Notice Caption** | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System`<br>`legalnoticecaption = ""` (String) | **Non-Admin / Domain Join** | `HKLM:\SOFTWARE\LiteDeploy\FullOS\ShieldingBackup\legalnoticecaption` | Prevents modal legal notice dialog from blocking unattended AutoLogon on reboot. | **Mandatory**: Restores backed up string from `ShieldingBackup` (if previously configured). |
| **5** | **Interactive Legal Notice Text** | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System`<br>`legalnoticetext = ""` (String) | **Non-Admin / Domain Join** | `HKLM:\SOFTWARE\LiteDeploy\FullOS\ShieldingBackup\legalnoticetext` | Prevents modal "Accept terms" prompt from blocking unattended AutoLogon on reboot. | **Mandatory**: Restores backed up string from `ShieldingBackup` (if previously configured). |
| **6** | **Ctrl+Alt+Del Requirement (`DisableCAD`)** | `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`<br>`DisableCAD = 1` (DWORD) | **Non-Admin / Domain Join** | `HKLM:\SOFTWARE\LiteDeploy\FullOS\ShieldingBackup\DisableCAD` | Suppresses Secure Attention Sequence requirement to permit seamless unattended logon. | **Mandatory**: Removes `DisableCAD` override or restores previous value; corporate GPO re-enforces if required. |
| **7** | **Lock Screen Suppression (`NoLockScreen`)** | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization`<br>`NoLockScreen = 1` (DWORD) | **Non-Admin / Domain Join** | `HKLM:\SOFTWARE\LiteDeploy\FullOS\ShieldingBackup\NoLockScreen` | Prevents lock screen engagement during unattended script / package runs. | **Mandatory**: Removes `NoLockScreen` property. |
| **8** | **Screen Saver (`ScreenSaveActive`)** | `HKCU:\Control Panel\Desktop`<br>`ScreenSaveActive = "0"` (String) | **Non-Admin / Domain Join** | - | Prevents interactive user session from blanking or locking. | Destroyed when ephemeral user profile `C:\Users\LD-<UID>` is purged during teardown. |
| **9** | **User Account Control (`EnableLUA`)** | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System`<br>`EnableLUA = 0` (DWORD) + `UacBypassed = 1` marker | **Domain Join Specialize (actions > 0)** | Staged in unattend specialize; marker in `HKLM:\SOFTWARE\LiteDeploy\FullOS` | Allows silent elevated execution under non-builtin Administrator account without interactive UAC consent prompts. | **Mandatory**: `Restore-LiteDeployFullOSUacBypass` sets `EnableLUA = 1` and clears `UacBypassed` marker (takes effect on reboot). |
| **10** | **AutoLogon Credentials & Count** | `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`<br>`AutoAdminLogon = "1"`, `AutoLogonCount = 999`<br>`DefaultDomainName = "."` | **Domain Join Specialize & FullOS** | - | Ensures mid-deploy reboots automatically log back into `LD-<UID>` or local `Administrator`. Windows wipes `DefaultPassword` after initial logon; Pre-Reboot Hook (`Set-LiteDeployFullOSAutoLogon`) re-injects password and forces `DefaultDomainName = "."` before 3010 restarts. | **Mandatory**: Set `AutoAdminLogon = "0"`, remove `AutoLogonCount`, remove `DefaultPassword` from Winlogon. |
| **11** | **HKLM Run Auto-Launch Key** | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run`<br>`LiteDeployFullOS` | **Specialize & FullOS re-arm** | - | Automatically triggers `LiteDeploy.OS.Engine.ps1` upon interactive logon. | **Mandatory**: Removed via `Clear-LiteDeployFullOSRunKey`. |
| **12** | **Ephemeral Service Account (`LD-<UID>`)** | Local user account in `Administrators` group | **Domain Join Specialize** | - | Provides isolated elevated execution token for Domain Join workflows. | **Mandatory**: Deleted via `Remove-LocalUser` or `net user /delete`; user profile purged via `Win32_UserProfile`. |

---

## Execution Flow & Lifecycle

```
================================================================================
                           FullOS Lifecycle
================================================================================

1. SPECIALIZE PASS (Offline / Unattend)
   ├─ If actions > 0:
   │  ├─ Stage HKLM\...\Run\LiteDeployFullOS
   │  ├─ If DomainJoin:
   │  │  ├─ Set EnableLUA = 0 (temporary UAC bypass)
   │  │  ├─ Write marker HKLM:\SOFTWARE\LiteDeploy\FullOS\UacBypassed = 1
   │  │  └─ Inject ephemeral account LD-<UID> + AutoLogon (Count = 999)

2. FULLOS INITIALIZATION (Start-LiteDeployFullOSResume)
   ├─ [Universal] Set-LiteDeployFullOSHighPerformance
   │  ├─ powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c (High Performance)
   │  └─ powercfg /change [all timeouts] 0
   ├─ Kill Audit Mode sysprep GUI (if present)
   ├─ Evaluate Identity:
   │  └─ If Identity != Administrator OR UacBypassed == 1:
   │     └─ Enable-LiteDeployFullOSShielding
   │        ├─ Backup pre-existing legal notices / CAD / GPO to ShieldingBackup
   │        ├─ Set DisableGPO = 1 (freeze GPO processing)
   │        ├─ Blank legalnoticecaption and legalnoticetext
   │        ├─ Set DisableCAD = 1
   │        ├─ Set NoLockScreen = 1 & ScreenSaveActive = 0
   │        ├─ Set AutoAdminLogon = 1 & AutoLogonCount = 999
   │        └─ Set ShieldingActive = 1

3. PACKAGE ORCHESTRATION & MID-DEPLOY REBOOTS
   ├─ HKLM Run remains armed
   ├─ If a package requests intermediate restart (Exit Code 3010):
   │  ├─ Re-arm HKLM Run (Set-LiteDeployFullOSRunKey)
   │  ├─ Pre-Reboot Hook (Set-LiteDeployFullOSAutoLogon: restore DefaultPassword, AutoAdminLogon=1, AutoLogonCount=999, DefaultDomainName='.')
   │  └─ Controlled restart (shutdown.exe /r /t 5 /f)
   ├─ Shielding remains ACTIVE across reboots
   └─ Deployment finishes successfully

4. TEARDOWN & CLEANUP (Clear-LiteDeployFullOSRunKey)
   ├─ Remove HKLM Run\LiteDeployFullOS
   ├─ Restore-LiteDeployFullOSUacBypass
   │  ├─ Set EnableLUA = 1
   │  └─ Clear UacBypassed marker
   ├─ Disable-LiteDeployFullOSShielding
   │  ├─ Remove DisableGPO (unfreeze GPO)
   │  ├─ Remove NoLockScreen
   │  ├─ Restore legal notices from ShieldingBackup
   │  ├─ Remove ShieldingBackup and ShieldingActive markers
   │  ├─ Clear Winlogon AutoLogon credentials
   │  └─ Trigger gpupdate.exe /force (background)
   ├─ Delete ephemeral user LD-<UID> & profile
   └─ Final handoff / reboot into production user experience
================================================================================
```
