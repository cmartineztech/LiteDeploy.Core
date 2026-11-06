# UI.HostShell

Console window positioning, style, theme, and progress presentation for Windows PowerShell.
Engine loads this component once using Environment's named `HostShell` path.
Importing it only defines functions; window changes happen through explicit calls.

These functions use Windows console APIs. Their visible effects require testing in the
actual WinPE console host. WPF screen layout remains with each screen component.

<!-- component-contract -->
## Usage and contract

Control classic console presentation and console progress.

**Source:** [LiteDeploy.UI.HostShell.ps1](LiteDeploy.UI.HostShell.ps1).

### Requirements and environment

Windows console and kernel32/user32 for window operations; no XAML. Terminal/noninteractive hosts can differ from classic WinPE console.

### What runs and changes

Import only defines functions. Set calls change presentation; Write progress writes console output. Engine explicitly minimizes/restores.

### Results and failures

Presentation effects do not signal deployment success. Unsupported hosts/missing handles limit effects. Engine catches its own minimize/restore failures.

### Script parameters

Defaults are source expressions, not resolved paths. Constraints are declared attributes; runtime requirements above also apply. Metadata (or its alias) returns identity without the normal action.

| Parameter | Type | Default | Constraints / aliases |
| --- | --- | --- | --- |
| Metadata | SwitchParameter | <code>$false</code> |  |

### Example

From the repository root in Windows PowerShell 5.1 (STA for UI/Engine). This has the effects described above; sample content must exist.

~~~powershell
. '.\Engine\Scripts\Runtime\020-Environment\LiteDeploy.Environment.ps1' -Mode Development
$component = '.\Engine\Scripts\Runtime\110-UI\HostShell\LiteDeploy.UI.HostShell.ps1'
. $component
Write-LiteDeployHostShellProgress -Percent 25
~~~

### Set-LiteDeployHostShellWindow

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [ValidateSet("None", "Minimize", "Restore", "Maximize", "Hide")][string]$Action = "None",
        [ValidateSet("None", "Top", "TopLeft", "TopRight", "Center", "Bottom", "BottomLeft", "BottomRight")][string]$Position = "None",
        [ValidateSet("None", "On", "Off")][string]$AlwaysOnTop = "None",
        [ValidateRange(0, 100)][int]$WidthPercent = 0,
        [ValidateRange(0, 100)][int]$HeightPercent = 0,
        [ValidateRange(300, 4000)][int]$Width = 1000,
        [ValidateRange(200, 3000)][int]$Height = 700,
        [AllowEmptyString()][string]$Title,
        [AllowEmptyString()][AllowNull()][string]$Prompt,
        [switch]$HideScrollBars
    )
~~~

### Set-LiteDeployHostShellPreset

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param([Parameter(Mandatory)][ValidateSet("Main", "Full", "Logs", "Picker")][string]$Name)
~~~

### Write-LiteDeployHostShellProgress

Call after dot-sourcing the component. Parameter declarations:

~~~powershell
param(
        [Parameter(Mandatory)][ValidateRange(0, 100)][int]$Percent,
        [ValidateRange(10, 100)][int]$Width = 40,
        [ConsoleColor]$CompletedColor = [ConsoleColor]::Green,
        [ConsoleColor]$RemainingColor = [ConsoleColor]::DarkGray,
        [ConsoleColor]$TextColor = [ConsoleColor]::Gray
    )
~~~
