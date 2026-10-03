# LiteDeploy Log Writer

**ComponentId**: `LogWriter`  
**Version**: `1.0.0`  
**Script File**: `Engine\Scripts\Runtime\000-LogWriter\LiteDeploy.LogWriter.ps1`  
**Target Environment**: WinPE and FullOS (PowerShell 5.1+, `Set-StrictMode -Version 2.0`)

`LiteDeploy.LogWriter.ps1` is the shared logger for LiteDeploy runtime components. It writes a colored console line and appends one CMTrace XML entry. It does not write JSON.

`DeploymentEngine` dot-sources this script. Later components call `Write-LiteDeployLog`. `BootInitializer` writes the same CMTrace file with its own function until the engine loads LogWriter.

---

## 1. Where the script is placed

The numbered `000-LogWriter` folder exists only in this repository. `SyncComponents` copies the `.ps1` file by name.

**Repository**

```text
Engine\Scripts\Runtime\000-LogWriter\LiteDeploy.LogWriter.ps1
```

**Network boot.** The file is on the deployment share and on the mapped drive:

```text
DeploymentShare\Engine\Scripts\Runtime\LiteDeploy.LogWriter.ps1
Z:\Engine\Scripts\Runtime\LiteDeploy.LogWriter.ps1
```

**Media boot.** Offline USB or ISO keeps the tree under `~LiteDeploy`. No share is mapped. The drive letter is the volume where `BootConfig.json` was found:

```text
E:\~LiteDeploy\Engine\Scripts\Runtime\LiteDeploy.LogWriter.ps1
```

`E:` is an example. The letter follows that volume.

---

## 2. Where the log is written

Every mode appends to the local CMTrace file:

```text
%SystemDrive%\~LiteDeploy\WorkLogs\LiteDeploy.Execution.log
```

In WinPE that is `X:\~LiteDeploy\WorkLogs\LiteDeploy.Execution.log`. The directory is created if it is missing. Blank messages are not written.

After `DeploymentEngine` creates the deployment log folder, each new line is also appended there. The engine uses the first folder it can create:

| Order | Path |
| :--- | :--- |
| Network, preferred | `Z:\~LiteDeploy\WorkLogs\Deployments\<DeploymentUid>\LiteDeploy.Execution.log` |
| Network, fallback | `Z:\WorkLogs\Deployments\<DeploymentUid>\LiteDeploy.Execution.log` |
| Media | `E:\~LiteDeploy\WorkLogs\Deployments\<DeploymentUid>\LiteDeploy.Execution.log` |

`Clear-LiteDeployLog` deletes only the local file. It does not delete the remote copy.

---

## 3. How to load it

**Dot-source** when the caller needs `Write-LiteDeployLog` for the rest of the session. This does not write a log line.

```powershell
# Repository
. "$PSScriptRoot\..\000-LogWriter\LiteDeploy.LogWriter.ps1"

# Network boot
. "Z:\Engine\Scripts\Runtime\LiteDeploy.LogWriter.ps1"

# Media boot
. "E:\~LiteDeploy\Engine\Scripts\Runtime\LiteDeploy.LogWriter.ps1"

Write-LiteDeployLog -Message "Evaluating TPM 2.0 State..." -Level "CHECK" -Component "HardwarePreCheck"
```

**Call** it for one entry. The functions are not left in the caller.

```powershell
& "Z:\Engine\Scripts\Runtime\LiteDeploy.LogWriter.ps1" -Message "Applying the image..." -Level "INFO" -Component "OSInstallation"
```

**Metadata** returns the component record and does not write a log line.

```powershell
& ".\LiteDeploy.LogWriter.ps1" -Metadata
```

---

## 4. `Write-LiteDeployLog`

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `-Message` | String | Mandatory | Text to log. |
| `-Level` | String | `INFO` | `INFO`, `SUCCESS`, `INIT`, `CHECK`, `WARNING`, `RETRY`, `ERROR`. |
| `-Component` | String | `LiteDeploy` | Component id written to the CMTrace `component` attribute. |
| `-ForegroundColor` | ConsoleColor | `White` | Console color. The default `White` selects the color from `-Level`. |
| `-LogFileName` | String | `LiteDeploy.Execution.log` | CMTrace file name. |
| `-LogPath` | String | `%SystemDrive%\~LiteDeploy\WorkLogs` | Directory override. |
| `-NoConsole` | Switch | Off | Write the file only. |

Console colors are not stored in the log file:

| Level | Console | CMTrace `type` | CMTrace highlight |
| :--- | :--- | :--- | :--- |
| `INFO` | White | `1` | Normal text |
| `SUCCESS` | Green | `1` | Normal text |
| `INIT` | Dark gray | `1` | Normal text |
| `CHECK` | Cyan | `1` | Normal text |
| `WARNING` | Yellow | `2` | Yellow |
| `RETRY` | Dark yellow | `2` | Yellow |
| `ERROR` | Red | `3` | Red |

CMTrace has three severities. `SUCCESS`, `INIT`, and `CHECK` stay informational (`type="1"`). `RETRY` is recorded as a warning (`type="2"`).

A message that already starts with `[`, `=`, or `-` is printed as-is. Other messages are printed as ` [LEVEL  ] [Component] message`.

---

## 5. CMTrace line

```xml
<![LOG[Evaluating TPM 2.0 State...]LOG]!><time="02:38:00.123+000" date="08-11-2026" component="HardwarePreCheck" context="" type="1" thread="1" file="LiteDeploy.HardwarePreCheck.ps1">
```

| Attribute | Value |
| :--- | :--- |
| `time` | Local time `HH:mm:ss.fff` plus `+000`. |
| `date` | `MM-dd-yyyy`. |
| `component` | The `-Component` argument. |
| `type` | `1` informational, `2` warning, `3` error. |
| `thread` | Always `1`. |
| `file` | Calling script name when PowerShell reports one; otherwise `LiteDeploy.LogWriter.ps1`. |

---

## 6. Other functions

`Get-LiteDeployLogPath` returns the full path and creates the directory when needed.

```powershell
Get-LiteDeployLogPath -FileName "LiteDeploy.Execution.log"
# X:\~LiteDeploy\WorkLogs\LiteDeploy.Execution.log
```

`Clear-LiteDeployLog` deletes that local file.

```powershell
Clear-LiteDeployLog -LogFileName "LiteDeploy.Execution.log"
```
