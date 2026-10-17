# Deployment Share Root Template

Folder skeleton for a deployment share. Numbered sources stay under `Engine\Scripts\`. This tree keeps `Config`, `Content`, `WorkFlows`, catalogs, and empty `Engine` folders. `Admin.Build` writes the flat Runtime, Admin, and Tools files onto the live share (`C:\DeploymentShare`), not into these folders.

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
│   ├── Scripts\
│   │   ├── Runtime\                 # empty here; live share gets flat LiteDeploy.*.ps1 + UI\
│   │   └── Admin\                   # empty here; live share gets flat LiteDeploy.Admin.*.ps1 + UI\
│   └── Tools\
│       └── WinPECT\                 # empty here; source is repo Engine\Tools\WinPECT\
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
.\Engine\Scripts\Admin\000-Build\LiteDeploy.Admin.Build.ps1 `
  -DeploymentShare "C:\DeploymentShare"
```

| Source | Destination |
| --- | --- |
| `Engine\Scripts\Runtime\###-*\` | `Engine\Scripts\Runtime\` (+ `UI\`) |
| `Engine\Scripts\Admin\###-*\` | `Engine\Scripts\Admin\` (+ `UI\`) |
| `LiteDeploy.Engine.ps1` | also as `LiteDeploy.DeploymentEngine.ps1` (compat) |
| repo `Engine\Tools\` | `Engine\Tools\` (WinPECT, …) |

### BootInitializer vs Boot

| Bootstrap in WinPE | Engine file it launches |
| --- | --- |
| Current `LiteDeploy.Boot.ps1` | Prefers `LiteDeploy.Engine.ps1`; falls back to `DeploymentEngine.ps1` |
| Legacy BootInitializer | Typically `LiteDeploy.DeploymentEngine.ps1` |

Both names must stay **byte-identical** on the share.

## Related docs

- [Root README — folder structure](../README.md#folder-structure)
- [WinPE bootstrap](../_Docs/guides/WINPE_BOOTSTRAP.md)
- [Credentials / WinPECT](../_Docs/integrations/Credentials/README.md)
- [Architecture diagrams](../_Docs/architecture/LITEDEPLOY_DEPLOYMENT_DIAGRAM.md)
- [Tools README](../Engine/Tools/README.md)
- [Docs map](../_Docs/README.md)
