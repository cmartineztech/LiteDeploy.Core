# Deployment Share Root Template

Folder skeleton for a deployment share. Numbered sources stay under `Engine\Runtime\` and `Engine\Admin\`. This tree keeps `Config`, `Content`, `WorkFlows`, catalogs, and empty `Engine` folders. `Admin.Build` writes the flat Runtime, Admin, and Tools files onto the live share (`C:\DeploymentShare`), not into these folders.

## Layout

```text
DeploymentShare\
├── Config\
│   └── BootConfig.json
├── Content\
│   ├── BootMedia\
│   │   ├── ISO\
│   │   └── WIM\
│   ├── Drivers\
│   ├── OperatingSystems\
│   ├── Packages\
│   │   ├── Apps\
│   │   └── System\
│   ├── Temp\
│   └── Unattend\
├── Engine\
│   ├── Runtime\                 # empty here; live share gets flat LiteDeploy.*.ps1 + UI\
│   ├── Admin\                   # empty here; live share gets flat LiteDeploy.Admin.*.ps1 + UI\
│   └── Tools\
│       └── WinPECT\             # empty here; source is repo Engine\Tools\WinPECT\
├── WorkFlows\
└── WorkLogs\
    ├── Admin\
    └── Deployments\
```

| Mode | How this root is used |
| --- | --- |
| **Network** | Share UNC mapped as `Z:\` (`Deployment.Type = Network`) |
| **Media** | Same tree under `<drive>:\~LiteDeploy` (`Deployment.Type = Media`) |

## Publish

```powershell
.\Engine\Admin\000-Build\LiteDeploy.Admin.Build.ps1 `
  -DeploymentShare "C:\DeploymentShare"
```

| Source | Destination |
| --- | --- |
| `Engine\Runtime\###-*\` | `Engine\Runtime\` (+ `UI\`) |
| `Engine\Admin\###-*\` | `Engine\Admin\` (+ `UI\`) |
| repo `Engine\Tools\` | `Engine\Tools\` (WinPECT, …) |

### WinPE Bootstrap & Engine Launch

| Bootstrap in WinPE | Engine file it launches |
| --- | --- |
| `LiteDeploy.PE.Boot.ps1` | `LiteDeploy.PE.Engine.ps1` |
| First-Boot OS Resume | `LiteDeploy.OS.Engine.ps1` |
