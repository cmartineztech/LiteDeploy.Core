# LiteDeploy Component Templates & Standardization

This directory provides master blueprints, manifests, and inventory tooling for authoring, versioning, and managing **LiteDeploy** PowerShell components.

---

## 📦 Files in this Directory

| File | Type | Purpose |
| :--- | :--- | :--- |
| **[`LiteDeploy.Component.Template.ps1`](LiteDeploy.Component.Template.ps1)** | PowerShell Template | Master script template implementing the LiteDeploy component contract, semantic versioning, strict-mode guards, and LogWriter integration. |
| **[`LiteDeploy.Component.Manifest.json`](LiteDeploy.Component.Manifest.json)** | JSON Schema Template | Standard component descriptor containing metadata, dependencies, exported functions, and version information. |
| **[`Get-LiteDeployComponentInventory.ps1`](Get-LiteDeployComponentInventory.ps1)** | PowerShell Utility | Automated scanner that discovers, queries, and reports version information for all repository components. |

---

## 🏷️ Standard Component Specification

Every LiteDeploy component script should follow these four standardized regions:

### Region 1: Metadata & Version Control
Exposes a `Get-LiteDeployComponentMetadata` function and supports the `-Metadata` switch to allow fast version discovery without executing payload logic:

```powershell
function Get-LiteDeployComponentMetadata {
    return [PSCustomObject]@{
        ComponentId          = "SampleComponent"           # Unique identifier: alphanumeric, no spaces
        Name                 = "LiteDeploy Sample"         # Friendly display name
        Version              = "1.0.0"                     # Semantic versioning (MAJOR.MINOR.PATCH)
        Category             = "Runtime"                   # "Admin" or "Runtime"
        TargetEnvironment    = "WinPE"                     # "WinPE", "FullOS", "Host", or "Universal"
        MinPowerShellVersion = "5.1"                       # Minimum supported PowerShell version
        Author               = "LiteDeploy Team"           # Maintainer / Author
        Dependencies         = @("LogWriter")              # Sibling component IDs required
        Description          = "Component purpose and behavior description."
    }
}

if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}
```

### Region 2: Logging Integration
Provides unified logging routing. Calls `Write-LiteDeployLog` when `LiteDeploy.LogWriter.ps1` is loaded in the session, or falls back to standardized console output.

### Region 3: Core Implementation
Contains private helper functions and the primary `Invoke-ComponentPayload` business logic.

### Region 4: Execution & Standalone Invocation
Protects standalone execution with structured `try/catch` error capture while allowing dot-sourcing without unwanted auto-execution.

---

## 🔍 Scanning Component Inventory

You can list all repository components and their detected versions by executing:

```powershell
.\Templates\Get-LiteDeployComponentInventory.ps1 | Format-Table -AutoSize
```
