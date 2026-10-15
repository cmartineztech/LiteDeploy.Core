# WinPECT (LiteDeploy trim)

Vendored runtime from [cmartinezone/WinPECT](https://github.com/cmartinezone/WinPECT) (MIT).

**Source:** repo `Tools\WinPECT\`  
**Published:** `DeploymentShare\Tools\WinPECT\` via Admin.Build

## Kept files

| File | Role |
| --- | --- |
| `WinPECredentialTransfer.ps1` | Upstream crypto/registry engine |
| `LiteDeploy.WinPECT.ps1` | LiteDeploy paths + export/import helpers |
| `LICENSE` | MIT |
| `SOURCE.md` | This note |

Upstream CLI wrappers, `docs\`, and `Tests\` are not published. Engine calls the engine through `LiteDeploy.WinPECT.ps1`.

When updating upstream, replace `WinPECredentialTransfer.ps1` (+ `LICENSE` if needed) here, keep `LiteDeploy.WinPECT.ps1`, then run Admin.Build `-DeploymentShare`.
