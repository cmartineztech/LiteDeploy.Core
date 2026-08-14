# LiteDeploy Log Writer Module Documentation

**Script File**: `components\03-LogWriter\LiteDeploy.LogWriter.ps1`  
**Documentation File**: `components\03-LogWriter\README.md`  
**Target Environment**: Windows PE (WinPE 5.1 / 10 / 11) & Windows Host  
**PowerShell Version**: PowerShell 5.1+ (`Set-StrictMode -Version 2.0`)  

---

## 1. Overview & Purpose

`LiteDeploy.LogWriter.ps1` is an independent, reusable logging engine module for **LiteDeploy Core**.

It provides standardized dual logging across all LiteDeploy components (`05-BootInitializer`, `06-PreCheck`, `07-SelectWorkflow`, `08-Progress`):
1. **Real-Time Console Output**: Writes color-coded visual feedback directly to the console screen.
2. **Microsoft CMTrace XML Logging**: Appends timestamped XML log entries to `$env:SystemDrive\~LiteDeploy\WorkLogs\LiteDeploy.Execution.log` (compatible with `CMTrace.exe`).
3. **Structured NDJSON Logging**: Appends single-line JSON log objects to `$env:SystemDrive\~LiteDeploy\WorkLogs\LiteDeploy.Execution.json` (compatible with Splunk, Azure, and cloud log analytics).

---

## 2. Architecture & File Structure

```text
LiteDeploy Core\
└── components\
    └── 03-LogWriter\
        ├── LiteDeploy.LogWriter.ps1
        └── README.md
```

---

## 3. Function Reference

### `Write-LiteDeployLog`
Primary logging function. Outputs colored text live to the console while writing both Microsoft CMTrace-compatible XML logs and NDJSON logs to files.

```powershell
Write-LiteDeployLog -Message "Partitioning Disk 0 (GPT)..." -Level "INFO" -Component "FormatDisk"
```

#### Parameters

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| **`-Message`** | String | Mandatory | Clean message text to log. |
| **`-Level`** | ValidateSet | `"INFO"` | Severity level (`INFO`, `SUCCESS`, `INIT`, `WARNING`, `RETRY`, `ERROR`). |
| **`-Component`** | String | `"LiteDeploy"` | Subsystem component tag (`BootInitilizer`, `PreCheck`, `SelectWorkflow`, `Progress`, `FormatDisk`). |
| **`-ForegroundColor`** | ConsoleColor | Dynamic | Custom console color override. If omitted, color is dynamically assigned based on `-Level`. |
| **`-LogFileName`** | String | `"LiteDeploy.Execution.log"` | Master log file name (automatically mirrors to `.json`). |
| **`-LogPath`** | String | `$env:SystemDrive\~LiteDeploy\WorkLogs` | Target directory override. |
| **`-NoConsole`** | Switch | `$false` | When specified, suppresses console screen output and writes only to the file targets. |

---

### `Get-LiteDeployLogPath`
Resolves and verifies the target log directory path, creating `%SystemDrive%\~LiteDeploy\WorkLogs` automatically if it does not exist.

```powershell
$logFilePath = Get-LiteDeployLogPath -FileName "LiteDeploy.Execution.log"
# Returns "X:\~LiteDeploy\WorkLogs\LiteDeploy.Execution.log"
```

---

### `Clear-LiteDeployLog`
Purges or resets existing log files (`.log` and `.json`).

```powershell
Clear-LiteDeployLog -LogFileName "LiteDeploy.Execution.log"
```

---

## 4. Usage Patterns for Other Components

Other LiteDeploy modules (`06-PreCheck`, `07-SelectWorkflow`, `08-Progress`) can consume `LiteDeploy.LogWriter.ps1` in two simple ways:

### Pattern A: Dot-Sourcing the Module (Recommended)

```powershell
# Dot-source the LogWriter module at component startup
. "$PSScriptRoot\..\03-LogWriter\LiteDeploy.LogWriter.ps1"

# Call Write-LiteDeployLog with component tag
Write-LiteDeployLog -Message "Evaluating TPM 2.0 State..." -Level "CHECK" -Component "PreCheck"
Write-LiteDeployLog -Message "TPM 2.0 Enabled & Active" -Level "SUCCESS" -Component "PreCheck"
```

### Pattern B: Direct Script Invocation

```powershell
& "$PSScriptRoot\..\03-LogWriter\LiteDeploy.LogWriter.ps1" -Message "Applying WIM Image..." -Level "INFO" -Component "Progress"
```

---

## 5. Dual Log Schema Verification

### CMTrace Schema (`LiteDeploy.Execution.log`)
Entries appended to `LiteDeploy.Execution.log` match official Microsoft CMTrace schema:

```xml
<![LOG[Evaluating TPM 2.0 State...]LOG]!><time="02:38:00.123+000" date="08-11-2026" component="PreCheck" context="" type="1" thread="1" file="LiteDeploy.PreCheck.ps1">
<![LOG[TPM 2.0 Enabled & Active]LOG]!><time="02:38:01.456+000" date="08-11-2026" component="PreCheck" context="" type="1" thread="1" file="LiteDeploy.PreCheck.ps1">
```

When opened in **`CMTrace.exe`**:
* `type="1"` (INFO, SUCCESS, INIT) -> **Normal White**
* `type="2"` (WARNING, RETRY) -> **Bright Yellow**
* `type="3"` (ERROR) -> **Bright Red**

### NDJSON Schema (`LiteDeploy.Execution.json`)
Entries appended to `LiteDeploy.Execution.json` match single-line compressed NDJSON schema:

```json
{"timestamp":"2026-08-11T02:38:00.123Z","level":"CHECK","type":1,"component":"PreCheck","message":"Evaluating TPM 2.0 State...","file":"LiteDeploy.PreCheck.ps1"}
{"timestamp":"2026-08-11T02:38:01.456Z","level":"SUCCESS","type":1,"component":"PreCheck","message":"TPM 2.0 Enabled & Active","file":"LiteDeploy.PreCheck.ps1"}
```
