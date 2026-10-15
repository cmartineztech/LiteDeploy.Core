# UI Theme

**Dev:** `110-UI/Theme/LiteDeploy.UI.Theme.xaml`  
**Published:** `Engine\Scripts\Runtime\UI\LiteDeploy.UI.Theme.xaml`

Shared XAML token dictionary. Controllers may merge or inline palette tokens (`{{varName}}`) before `XamlReader.Load`. Runtime theme mode (`Light`|`Dark`) comes from `BootConfig.Ui.Theme`, not from this file alone.

## Inputs and requirements

This is a WPF ResourceDictionary, not an executable PowerShell component. Its consumer must
replace palette placeholders such as headerBg, headerFg, borderColor, surfaceBg, fgColor,
and buttonHoverBg before loading it into WPF. Unresolved color tokens can cause XAML errors.
Full Windows needs WPF; actual WinPE compatibility must be checked in the boot image.

## Effects, output, and current use

Loading produces style resources, not a deployment result. It does not write files or change
deployment state. The screens currently keep local palettes/markup; merging this shared
dictionary is not fully wired. Engine does not require this file at startup. Editing it alone
does not guarantee any screen changes. Change and verify the resource actually used by the screen.

## Inspect the asset

From the repository root, this reads XML without opening UI or resolving WPF colors:

```powershell
$themePath = '.\Engine\Scripts\Runtime\110-UI\Theme\LiteDeploy.UI.Theme.xaml'
[xml]$themeXml = Get-Content -LiteralPath $themePath -Raw
$themeXml.DocumentElement.LocalName # ResourceDictionary
```

XML parsing checks syntax only. Actual resource loading must be tested after token replacement.
