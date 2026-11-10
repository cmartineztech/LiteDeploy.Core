# LiteDeploy UI.Progress (Native Host)

## Role

WPF progress UI with internal markup and no external LiteDeploy helper imports. It still requires Windows WPF assemblies; validate compatibility in the actual WinPE image. **Engine launches it as a separate STA process** so Disk/Image keep running.

## Launch (Engine)

```text
powershell.exe -STA -File LiteDeploy.UI.Progress.ps1
  -StatePath <SystemDrive>\~LiteDeploy\DeploymentState.json
  -WinPE          # when Engine is in WinPE
  -Theme <Light|Dark>   # BootConfig.Ui.Theme
  -TopMost On
```

## State feed

1. RAM memory-map published by State: `Local\LiteDeploy.DeploymentState`
2. File fallback: `DeploymentState.json` (full Engine schema or legacy camelCase)

## Failure behavior

| Status | UI | Auto-close |
| :--- | :--- | :--- |
| Running / phase names | Blue | No |
| Failed / Cancelled | Red | No (stays for technician) |
| Completed / OSImageApplied | Green | Yes (~2s) unless `-KeepOpen` |

## Theme

Follows `-Theme` from Engine. Do not assume Dark in WinPE; config drives Light/Dark across Precheck → Workflow → Progress.
