# Admin.Images

**ComponentId:** `Admin.Images`  
**Dev:** `Admin/020-Images`  
**Published:** `Engine\Scripts\Admin\LiteDeploy.Admin.Images.ps1`

OS media import / catalog helpers. GUI lives under `Admin/090-UI` → `LiteDeploy.Admin.UI.Images.ps1`.

<!-- component-contract -->
## Usage and contract

Import media, create os.json, rebuild OS catalog.

**Source:** [LiteDeploy.Admin.Images.ps1](LiteDeploy.Admin.Images.ps1).

### Requirements and environment

Full Windows, existing DeploymentShare, readable ISO/media, image tooling and space. Use7Zip requires SevenZipPath. Specify name/editions for noninteractive use.

### What runs and changes

Copies media/writes metadata. Mounts/unmounts ISO. RebuildCatalog regenerates catalog. Not a helper-only import. CustomWimPath can replace install image.

### Results and failures

PassThru returns metadata. Invalid media/inspection throws. Finally dismounts ISO, but partial content may remain. Import does not execute Setup.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| DeploymentShare | String | <code>(not supplied)</code> | [Parameter(Mandatory = $true, ParameterSetName = 'Import', HelpMessage = "Path to the root LiteDeploy deployment share directory.")] [Parameter(Mandatory = $true, ParameterSetName = 'Rebuild', HelpMessage = "Path to the root LiteDeploy deployment share directory.")] [ValidateScript({ Test-Path $_ -PathType Container })] |
| SourcePath | String | <code>(not supplied)</code> | [Parameter(Mandatory = $true, ParameterSetName = 'Import', HelpMessage = "Path to an ISO file, Drive Letter (e.g., E: or E:\), or unpacked directory.")] |
| Use7Zip | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false, ParameterSetName = 'Import', HelpMessage = "Use 7-Zip registry parsing for automated OS name/version extraction.")] |
| SevenZipPath | String | <code>"C:\Program Files\7-Zip\7z.exe"</code> | [Parameter(Mandatory = $false, ParameterSetName = 'Import', HelpMessage = "Path to 7z.exe binary.")] |
| CustomWimPath | String | <code>(not supplied)</code> | [Parameter(Mandatory = $false, ParameterSetName = 'Import', HelpMessage = "Optional path to a custom .wim or .esd file to replace default install.wim.")] |
| SelectedIndices | Int32[] | <code>(not supplied)</code> | [Parameter(Mandatory = $false, ParameterSetName = 'Import', HelpMessage = "Specific WIM image indices to enable (e.g. 1, 6). Bypasses Out-GridView prompt if specified.")] |
| SelectAllEditions | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false, ParameterSetName = 'Import', HelpMessage = "Select all editions automatically without interactive Out-GridView prompt.")] |
| OSName | String | <code>(not supplied)</code> | [Parameter(Mandatory = $false, ParameterSetName = 'Import', HelpMessage = "Override or supply OS Name directly (bypasses Read-Host prompt in DISM mode).")] |
| PassThru | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $false, ParameterSetName = 'Import', HelpMessage = "Return the generated local OS object output to pipeline.")] [Parameter(Mandatory = $false, ParameterSetName = 'Rebuild', HelpMessage = "Return the generated local OS object output to pipeline.")] |
| RebuildCatalog | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $true, ParameterSetName = 'Rebuild', HelpMessage = "Rebuild central catalog.json from local os.json files.")] |
| Metadata | SwitchParameter | <code>$false</code> | [Parameter(Mandatory = $true, ParameterSetName = 'Metadata', HelpMessage = "Return component metadata.")] |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
$component = '.\Engine\Scripts\Admin\020-Images\LiteDeploy.Admin.Images.ps1'
& $component -DeploymentShare 'C:\LiteDeploy-Staging' -SourcePath 'D:\' -OSName 'Windows Example' -SelectAllEditions -PassThru
~~~
