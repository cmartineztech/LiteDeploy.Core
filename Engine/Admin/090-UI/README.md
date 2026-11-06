# Admin UI

See the individual [Drivers guide](Drivers/README.md) and [Images guide](Images/README.md)
for requirements, parameters, changes made by each action, and current backend limitations.

**Dev:** `Admin/090-UI\...`  
**Published:** `Engine\Scripts\Admin\UI\LiteDeploy.Admin.UI.*.ps1`

Admin graphical tools. Folder numbers are repo organization only; publish is flat under `Engine\Scripts\Admin\UI\`.

| UI | ComponentId | File |
| :--- | :--- | :--- |
| OS Media / Catalog | `Admin.UI.Images` | `Images\LiteDeploy.Admin.UI.Images.ps1` |
| Driver packs / Fleet | `Admin.UI.Drivers` | `Drivers\LiteDeploy.Admin.UI.Drivers.ps1` |

## Driver Pack Manager

```powershell
.\LiteDeploy.Admin.UI.Drivers.ps1 -DefaultDeploymentShare C:\DeploymentShare
```

- **Download & Catalog** — Init, Get Catalog, Check Updates, Download Fleet  
- **Managed Computer Models** — `ComputerModels.csv` edit / add custom / delete  
- **Local Catalog** — `LocalCatalog.json` packs; **Sync CSV to Local Catalog**  
- Share must contain `Config\BootConfig.json` or actions stay disabled  
- Extract defaults **off** unless “Extract after download” is checked
