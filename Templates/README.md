# LiteDeploy Component Templates & Standardization

This directory provides master blueprints and inventory tooling for authoring, versioning, and managing **LiteDeploy** PowerShell components with **100% embedded metadata**.

---

## 📦 Files in this Directory

| File | Type | Purpose |
| :--- | :--- | :--- |
| **[`LiteDeploy.Component.Template.ps1`](LiteDeploy.Component.Template.ps1)** | PowerShell Template | Master single-file template implementing the LiteDeploy component contract, embedded metadata, semantic versioning, strict-mode guards, and LogWriter integration. |
| **[`Get-LiteDeployComponentInventory.ps1`](Get-LiteDeployComponentInventory.ps1)** | PowerShell Utility | Automated scanner that queries embedded metadata and outputs a consolidated inventory of all repository components. |

---

## 🏷️ Embedded Metadata Specification

Every LiteDeploy component is **100% self-contained** in a single `.ps1` file. There are no separate manifest sidecars to maintain.

Components implement the following 4 standardized regions:

### Region 1: Metadata & Version Control
Exposes `Get-LiteDeployComponentMetadata` and handles the `-Metadata` fast-exit parameter switch:

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

You can discover and inspect all component versions across the entire repository with a single command:

```powershell
.\Templates\Get-LiteDeployComponentInventory.ps1 | Format-Table -AutoSize
```
