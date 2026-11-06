# LiteDeploy Image Component

`LiteDeploy.Image.ps1` orchestrates the application of Windows operating system images during WinPE deployment using either `setup.exe` (traditional Windows Setup) or `dism.exe` (direct WIM/ESD apply + BCD bootloader setup + offline driver servicing).

---

## 1. Unattended Answer File Resolution & Error Policy

### Workflow Mode vs. Direct OS Catalog Mode

| Deployment Mode | Unattended Requirement | Path Resolution & Missing File Policy |
| :--- | :--- | :--- |
| **Workflow Mode** | **Strict / Mandatory**<br>The workflow must declare an `unattendPath` (e.g. `Content/Unattend/DomainJoin.xml` or `DomainJoin.xml`). | **Halts with Targeted Error**:<br>Resolves the explicit path using the **Environment component** (`Resolve-LiteDeployContentPath`) against the active deployment root. Does **not** guess or probe fallback directories. If missing, throws a targeted error stating the exact expected location. |
| **OS Catalog Mode** (Direct Imaging) | **Optional**<br>Searches standard default catalog templates (`Content\Unattend\Standard.xml`, `Content\Unattend\Unattend.xml`). | **Proceeds Without Error**:<br>If no default unattended template exists, logs an informational notice and applies the image without an answer file (omits `/Unattend` for `setup.exe`, skips Panther staging for `dism.exe`). |

### Targeted Workflow Error Reporting

When an unattended template specified by a workflow is missing, the error specifically points to the single intended path location derived from the workflow JSON:

```text
[ERROR] Unattended template 'Content/Unattend/DomainJoin.xml' specified by workflow 'Domain Join' (domain-join) was not found at 'Z:\Content\Unattend\DomainJoin.xml'.
```

No multi-directory guessing or fallback lists are output for workflow deployments.

---

## 2. Environment Component Integration

Path resolution across the Image component adheres strictly to the **Environment component contract** ([LiteDeploy.Environment.ps1](../020-Environment/LiteDeploy.Environment.ps1)):

1. **Deployment Root Resolution (`Get-LiteDeployImageDeploymentRoot`)**:
   - Queries `$BootCtx.DeploymentRoot`
   - Evaluates Media mode: `$BootCtx.MediaDriveLetter` + `$BootCtx.LocalRootName`
   - Evaluates Network mode: `$BootCtx.DriveLetter` or `$BootCtx.NetworkPath`
   - Queries `$global:LiteDeployPathSettings.ComponentRoot` (Environment settings)
   - Zero hardcoded drive letters (`Z:`, `C:\DeploymentShare`) and no path guessing.

2. **Content Path Resolution (`Resolve-LiteDeployImageContentPath`)**:
   - Delegates directly to `Resolve-LiteDeployContentPath -Path $cleanPath -DeploymentRoot $deploymentRoot`.
   - Absolute paths and UNC paths are preserved as-is. Catalog- and share-relative paths are joined cleanly to the deployment root.

**Engine pipeline:** DeploymentRoot comes from BootObject / Environment. Do not rely on the
standalone fallback that walks `$PSScriptRoot` toward a sibling `DeploymentShare` — that
exists only for authoring convenience when Environment/BootObject are absent.

---

## 3. Imaging Engine Selection & Precedence

`BootConfig.ComputerSetup.ImageEngine` (or the workflow override `computerSetup.ImageEngine`) selects the imaging engine.

### Precedence Hierarchy

$$\text{Workflow: } \texttt{computerSetup.ImageEngine} \;\longrightarrow\; \text{BootConfig: } \texttt{ComputerSetup.ImageEngine} \;\longrightarrow\; \text{Default: } \texttt{setup.exe}$$

- **OS Catalog Deployments**: Direct OS installations honor `BootConfig.ComputerSetup.ImageEngine` from `BootConfig.json` (e.g. `"ImageEngine": "dism.exe"` or `"setup.exe"`).
- **Matching**: Case-insensitive and trimmed (supports `setup.exe`, `setup`, `dism.exe`, `dism`).
- **Validation**: `-ValidateEngineOnly` returns the canonical engine name (`setup.exe` or `dism.exe`) without media access, process execution, or file modification.

---

## 4. Supported Engines

### `dism.exe` (Direct Image Apply & Offline Servicing)
1. **Apply Image**: Applies target `install.wim` / `install.esd` / `install.swm` via:
   ```cmd
   dism.exe /Apply-Image /ImageFile:"..." /Index:<Index> /ApplyDir:W:\
   ```
2. **Bootloader Setup**: Configures BCD bootloader on system partition:
   ```cmd
   bcdboot.exe W:\Windows /s S: /f UEFI
   ```
3. **Driver Injection**: Injects staged drivers offline:
   ```cmd
   dism.exe /Image:W:\ /Add-Driver /Driver:"..." /Recurse
   ```
4. **Answer File Staging**: Stages the generated answer file directly into the offline Panther directory (`W:\Windows\Panther\unattend.xml`). On first boot, Windows Setup automatically discovers and processes the `specialize` and `oobeSystem` passes.

### `setup.exe` (Traditional Windows Setup)
1. **Execution**: Launches `setup.exe` with arguments:
   ```cmd
   setup.exe /NoReboot /DiagnosticPrompt enable /ImageIndex <Index> /InstallFrom "<ImagePath>" [/InstallDrivers "<DriverPath>"]
   ```
2. **Answer File**: Appends `/Unattend:"X:\unattended.xml"` only when an answer file is present.
3. **Optional hardware bypass**: See section 4.1 when `SkipSetupHardwareRequirements` is `true`.

---

## 4.1 SkipSetupHardwareRequirements (Setup.exe only)

`BootConfig.ComputerSetup.SkipSetupHardwareRequirements` (workflow `computerSetup` override wins) controls whether Image writes WinPE registry bypasses **immediately before** launching `setup.exe`.

| Value | Behavior |
| :--- | :--- |
| `false` / omitted | No registry changes |
| `true` | Call `Set-LiteDeploySetupHardwareRequirementBypass`, then launch Setup |

**Does not apply to `dism.exe`.** Microsoft documents `/Compat IgnoreWarning` and `/DynamicUpdate` as **not applicable** when Setup is started from WinPE; this flag uses the WinPE registry path instead.

### Registry writes (WinPE hive only)

```powershell
# HKLM:\SYSTEM\Setup\LabConfig  (DWORD = 1)
BypassTPMCheck
BypassSecureBootCheck
BypassCPUCheck
BypassRAMCheck
BypassStorageCheck
BypassDiskCheck

# HKLM:\SYSTEM\Setup\MoSetup  (DWORD = 1)
AllowUpgradesWithUnsupportedTPMOrCPU
```

These keys exist only for the running WinPE session. They are not persisted into the installed OS image.

### Helpers

| Function | Role |
| :--- | :--- |
| `Test-LiteDeploySkipSetupHardwareRequirements` | Reads workflow `computerSetup` then BootConfig `ComputerSetup` |
| `Set-LiteDeploySetupHardwareRequirementBypass` | Creates LabConfig / MoSetup keys and sets the DWORD values above |

Example BootConfig fragment:

```json
"ComputerSetup": {
  "ImageEngine": "Setup.exe",
  "SkipSetupHardwareRequirements": false
}
```

---

## 5. Answer File Property Substitution & Provenance

When generating an answer file from an XML template, `New-LiteDeployUnattendXml` performs automated key substitutions and metadata injection:

### Workflow Provenance Header Comment
The generated XML file includes an audit header identifying the source workflow, template, and timestamp:
```xml
<!-- Generated by LiteDeploy Engine | Workflow: Standard Workflow (standard-deploy) | Template: Standard.xml | Date: 2026-10-08 20:03:00 -->
```

### Template Archetypes & Policies
- **`Standard.xml`** (`<ProtectYourPC>1</ProtectYourPC>`): Workgroup workstation. Has `<!--AuditMode-->` (filled when workflow `actions.Count > 0`) so first interactive session is built-in Administrator in Audit Mode.
- **`IntuneReady.xml`**: MDM-oriented OOBE. Same placeholders as Standard, but the stock Intune workflow has **zero actions**, so Image clears FullOS Run and Audit reseal (plain OOBE).
- **`DomainJoin.xml`** (`<ProtectYourPC>3</ProtectYourPC>`): Local test admin + AutoLogon (`user`); **no** `<!--AuditMode-->`. FullOS Run (when actions > 0) starts at AutoLogon; temporary UAC bypass via `<!--DisableUacForFullOS-->`.

### Specialize RunSynchronous (`Microsoft-Windows-Deployment`)
Templates use placeholders filled by `New-LiteDeployUnattendXml`:

| Order | Placeholder | When filled |
| :--- | :--- | :--- |
| **1** | `<!--ComputerDescription-->` | **Always** — `cmd /c reg add …\LanmanServer\Parameters /v srvcomment` (blank → `No Description`) |
| **2** | `<!--LiteDeployFullOSRun-->` | When workflow **actions > 0** — arms `HKLM\...\Run\LiteDeployFullOS` with short `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File %SystemDrive%\~LiteDeploy\...\LiteDeploy.FullOS.ps1` (`REG_EXPAND_SZ`) |
| **3–4** | `<!--DisableUacForFullOS-->` | When **actions > 0** and template has **no** `<!--AuditMode-->` (Domain Join) — `EnableLUA=0` + `UacBypassed=1`; FullOS restores `EnableLUA=1` on cleanup |

Action count comes from `WorkflowSelection` / `WorkflowTag.Actions` (Tag must carry `Actions` from workflow JSON). Nested-quoted PowerShell inside `reg add /d` breaks specialize parse — keep Paths as simple as Order 1. Intune Ready with **0 actions** clears FullOS Run and Audit placeholders (OOBE only).

### Audit Mode Reseal (`<!--AuditMode-->`)
Filled only when the template has `<!--AuditMode-->` **and** workflow actions > 0. Standard gets Audit + Admin desktop; Intune with empty actions clears it; Domain Join has no placeholder (OOBE AutoLogon instead). There is **no** `auditUser` RunSynchronous — FullOS starts from the HKLM Run value at interactive logon.

### Dynamic Placeholders
- **Computer Name & Description**: Name from `WorkflowSelection` / `BootConfig`. Description always staged via Order 1 `reg add` (see above).
- **Disk & Partition**: `<!--DiskID-->` and `<!--PartitionID-->` mapped from `DiskResult` / target disk index.
- **Regional & Localization**: `Language`, `KeyboardLocale`, and `TimeZone` mapped to `<!--SetupUILanguage-->`, `<!--InputLocale-->`, and `<!--TimeZone-->`.
- **Domain & Workgroup**: `JoinWorkGroup`, `JoinDomain`, `MachineObjectOU`, `RegisteredOwner`, and `RegisteredOrganization` are XML-escaped and injected only when non-empty.
- **Optional ProductKey**: Validates 25-character product keys (`XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`) into `Microsoft-Windows-Setup/UserData/ProductKey/Key`. Malformed keys are skipped without exposing sensitive values to logs. When no key is configured, `<!--Key-->` may remain as a harmless windowsPE comment.

---

## 6. Component Contract & Usage

**Source File:** [LiteDeploy.Image.ps1](LiteDeploy.Image.ps1)  
**Published Path:** `DeploymentShare\Engine\Scripts\Runtime\LiteDeploy.Image.ps1`  
**Component ID:** `Image`  
**Dependencies:** `Logs`, `Workflow`, `Environment`  
**Target Environment:** WinPE (PowerShell 5.1+, StrictMode 2.0)

### Execution Modes

- **Inspect / Resolve Mode (Read-Only)**: Default when executed without `-ExecuteSetup`. Resolves paths, tests binaries, validates templates, and returns status object.
- **Deployment Mode**: Launched with `-ExecuteSetup` by `LiteDeploy.Engine.ps1` during Phase 4 of the deployment sequence.
- **Validation Mode**: Launched with `-ValidateEngineOnly` during engine pre-flight checks.

### Script parameters

| Parameter | Type | Default | Notes |
| --- | --- | --- | --- |
| SetupPath | String | `""` | Explicit `setup.exe` path |
| ImagePath | String | `""` | Explicit WIM/ESD path |
| ImageIndex | Int | `0` | Edition index for DISM apply |
| UnattendPath | String | `""` | Existing answer file (optional) |
| TemplateUnattendPath | String | `""` | Template for `New-LiteDeployUnattendXml` |
| GeneratedUnattendPath | String | `X:\unattended.xml` | Output answer file (Setup) |
| Destination | String | `W:\` | Offline OS root (DISM) |
| WorkflowSelection | PSObject | `$null` | Selection / workflow context |
| DiskResult | PSObject | `$null` | Disk phase result |
| BootConfig | PSObject | `$null` | Effective config |
| DriverPath | String | `""` | Staged drivers for Setup/DISM |
| AdditionalArguments | String[] | `@()` | Extra Setup/DISM args |
| BootObject | PSObject | `$null` | Boot context |
| ExecuteSetup | Switch | false | Perform imaging (destructive) |
| ValidateEngineOnly | Switch | false | Engine pre-flight ImageEngine check |
| Metadata | Switch | false | Return metadata only |

### Public API Functions

| Function | Description |
| :--- | :--- |
| `Resolve-LiteDeployImageEngine` | Resolves the effective imaging engine (`setup.exe` or `dism.exe`) from workflow or `BootConfig`. |
| `Test-LiteDeploySkipSetupHardwareRequirements` | Returns whether `ComputerSetup.SkipSetupHardwareRequirements` is enabled (workflow override first). |
| `Set-LiteDeploySetupHardwareRequirementBypass` | Writes WinPE LabConfig / MoSetup DWORD bypasses before Setup.exe. |
| `Resolve-SetupExecutable` | Locates `setup.exe` from explicit paths, OS media folder, or deployment share via Environment. |
| `Resolve-LiteDeployImageFile` | Locates `install.wim`/`install.esd` from media roots or direct paths via Environment. |
| `Resolve-UnattendTemplate` | Resolves workflow-specific or default unattended templates using Environment standards. |
| `New-LiteDeployUnattendXml` | Generates a customized answer file from a template with string substitution, header comment injection, and XML validation. |
| `Get-LiteDeployImageInfo` | Discovers image editions/indexes in a WIM/ESD file. |
| `Select-LiteDeployImage` | Resolves target image index based on workflow selection, edition name, or defaults. |
| `Invoke-SetupEngine` | Executes `setup.exe` with arguments and validates offline installation artifacts. |
| `Invoke-DismEngine` | Executes `dism.exe` apply, `bcdboot.exe`, offline driver injection, and Panther answer file staging. |
| `Test-LiteDeployImage` | Read-only validation of setup binaries, image files, and unattended answer files. |
| `Start-LiteDeployImage` | Entry point for executing the image phase. |
