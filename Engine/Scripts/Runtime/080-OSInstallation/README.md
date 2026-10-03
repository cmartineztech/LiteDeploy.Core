# LiteDeploy OS Installation (`LiteDeploy.OSInstallation.ps1`)

**Component ID**: `OSInstallation`  
**Category**: `Runtime`  
**Target Environment**: `WinPE` (PowerShell 5.1+)  
**Version**: `1.0.0`  
**Author**: LiteDeploy Team  
**Dependencies**: `LogWriter`  
**Primary Engine**: `Setup.exe` (`/NoReboot`)

---

## 🌟 Overview

`LiteDeploy.OSInstallation.ps1` orchestrates the Windows Setup engine (`setup.exe`) to lay down and stage the operating system onto bare-metal formatted storage partitions in Windows PE.

Key operational characteristics:
- **Mandatory `/NoReboot` Execution**: Always passes `/NoReboot` to `setup.exe` so Windows Setup completes its initial staging without performing an uncontrolled reboot. This preserves control for LiteDeploy to stage offline handoff scripts (`SetupComplete.cmd`), credentials (via `WinPECT`), and state before issuing a controlled reboot.
- **Diagnostic Command Prompt Support**: Always passes `/DiagnosticPrompt enable` to `setup.exe` to allow Shift+F10 console access during setup operations for runtime troubleshooting and diagnostics.
- **Direct `/ImageIndex <index>` Command-Line Support**: Directly passes `/ImageIndex <index>` to `setup.exe` from the technician's selection in `WorkflowSelection` (or explicit `-ImageIndex` parameter), guaranteeing that the setup binary targets the exact selected image index.
- **Automated Unattended Generation**: If `-UnattendPath` is not specified, automatically generates `X:\unattended.xml` by performing string key substitution on an XML template (`Autopilot.xml`) using runtime properties from `BootConfig.json`, `WorkflowSelection`, and `DiskPreparation`.
- **String Key Substitution Mapping**:
  - `<!--DiskID-->` → `<DiskID>$diskId</DiskID>` (from Disk selection / DiskPreparation result)
  - `<!--PartitionID-->` → `<PartitionID>$partitionId</PartitionID>` (from DiskPreparation partition structure)
  - `<!--UILanguage-->`, `<!--SystemLocale-->`, `<!--UserLocale-->` → `<Tag>$Language</Tag>` (from `BootConfig.json`)
  - `<!--InputLocale-->` → `<InputLocale>$KeyboardLocale</InputLocale>` (from `BootConfig.json`)
  - `<!--ComputerName-->` → `<ComputerName>$ComputerName</ComputerName>` (from WorkflowSelection)
  - `<!--Timezone-->` → `<TimeZone>$TimeZone</TimeZone>` (from `BootConfig.json`)
  - `<!--RegisteredOwner-->` → `<RegisteredOwner>$RegisteredOwner</RegisteredOwner>` (from `BootConfig.json`)
  - `<!--RegisteredOrganization-->` → `<RegisteredOrganization>$RegisteredOrganization</RegisteredOrganization>` (from `BootConfig.json`)
  - `<!--ComputerDescription-->` → `LanmanServer srvcomment` registry command (from WorkflowSelection)
- **Flexible Path Resolution**: Resolves `setup.exe` directly via `-SetupPath` or automatically derives it from an OS image/folder path via `-ImagePath`.
- **Exit Code Verification**: Validates success codes (`0` or `3010`) and intercepts Setup failures, preventing blind restarts on error.
- **Target Artifact Validation**: Verifies that `$Destination\Windows` or `$Destination\$Windows.~BT` exists post-installation.
- **Component Standard v1.0**: Conforms to standard metadata, strict error handling, and structured `PSCustomObject` output.

---

## 📋 Parameter Reference

| Parameter | Type | Required? | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| **`-SetupPath`** | `[string]` | Optional* | `""` | Full or relative path to `setup.exe`. |
| **`-ImagePath`** | `[string]` | Optional* | `""` | Path to OS media folder or `install.wim` (used to resolve `setup.exe`). |
| **`-ImageIndex`** | `[int]` | Optional | `0` (Auto) | WIM/ESD image index to install. If 0, resolved from `WorkflowSelection` or defaults to 1. |
| **`-UnattendPath`** | `[string]` | Optional | `""` | Explicit path to an existing answer file. If omitted, one is auto-generated. |
| **`-TemplateUnattendPath`** | `[string]` | Optional | Auto | Path to template XML (e.g. `Content\Unattend\Autopilot.xml`). |
| **`-GeneratedUnattendPath`** | `[string]` | Optional | `'X:\unattended.xml'` | Destination path for the generated answer file. |
| **`-Destination`** | `[string]` | Optional | `'W:\'` | Target partition drive letter where Windows is installed. |
| **`-WorkflowSelection`** | `[psobject]` | Optional | `$null` | Technician selections from `WorkflowSelection` (ComputerName, TargetDiskIndex, WorkflowTag, etc.). |
| **`-DiskResult`** | `[psobject]` | Optional | `$null` | Target disk formatting results from `DiskPreparation` (DiskNumber, OSPartitionNumber). |
| **`-BootConfig`** | `[psobject]` | Optional | `$null` | Configuration object loaded from `BootConfig.json` (`ComputerSetup` properties). |
| **`-AdditionalArguments`** | `[string[]]` | Optional | `@()` | Additional arguments to pass directly to `setup.exe`. |
| **`-BootObject`** | `[psobject]` | Optional | `$null` | LiteDeploy runtime context object passed from `BootInitializer` or `DeploymentEngine`. |
| **`-Metadata`** | `[switch]` | Optional | (Active) | Outputs component metadata object without executing `setup.exe`. |

*\*Note: Either `-SetupPath` or `-ImagePath` must resolve to a valid `setup.exe`.*

---

## 📤 Return Object Contract

```powershell
[PSCustomObject]@{
    Success         = $true                             # Execution success flag
    Engine          = "Setup.exe"                       # Active imaging engine
    SetupPath       = "Z:\Content\OS\setup.exe"         # Resolved setup binary path
    ImageIndex      = 6                                 # Selected image index installed
    UnattendPath    = "X:\unattended.xml"               # Resolved answer file path (or $null)
    Destination     = "W:\"                             # Target OS volume root path
    ExitCode        = 0                                 # Process exit code (0 or 3010)
    DurationSeconds = 245                               # Elapsed execution time in seconds
    CompletedTime   = "2026-10-02T04:30:15.123Z"        # ISO-8601 UTC timestamp
}
```

---

## 🚀 Usage Examples

### 1. Launch Setup with Unattended Answer File
```powershell
.\LiteDeploy.OSInstallation.ps1 `
    -SetupPath "Z:\Content\OperatingSystems\win11_25H2\setup.exe" `
    -UnattendPath "Z:\Content\Unattend\Unattend.xml" `
    -Destination "W:\"
```

### 2. Launch Setup via Image Root Path
```powershell
.\LiteDeploy.OSInstallation.ps1 `
    -ImagePath "Z:\Content\OperatingSystems\win11_25H2" `
    -Destination "W:\"
```

### 3. Inspect Component Metadata (Inventory)
```powershell
.\LiteDeploy.OSInstallation.ps1 -Metadata
```
