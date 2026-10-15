# LiteDeploy Component Templates & Standardization

This directory (`_Templates\`) provides master blueprints and inventory tooling for authoring,
versioning, and managing **LiteDeploy** PowerShell components with **embedded metadata**.
It is **not** published to the deployment share.

---

## Files in this directory

| File | Type | Purpose |
| :--- | :--- | :--- |
| **[`LiteDeploy.Component.Template.ps1`](LiteDeploy.Component.Template.ps1)** | PowerShell Template | Master single-file template implementing the LiteDeploy component contract, embedded metadata, semantic versioning, StrictMode 2.0, and Logs integration. |
| **[`Get-LiteDeployComponentInventory.ps1`](Get-LiteDeployComponentInventory.ps1)** | PowerShell Utility | Scanner that queries `-Metadata` across `Engine\Scripts` and returns a consolidated inventory. |

---

## Embedded metadata specification

Every LiteDeploy component is **self-contained** in a single `.ps1` file. There are no separate
manifest sidecars to maintain.

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
        Dependencies         = @("Logs")                   # Sibling component IDs required
        Description          = "Component purpose and behavior description."
    }
}

if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}
```

### Region 2: Logging Integration

Provides unified logging routing. Calls `Write-LiteDeployLog` when Logs is loaded in the
session, or falls back to standardized console output.

### Region 3: Core Implementation

Contains private helper functions and the primary `Invoke-ComponentPayload` business logic.

### Region 4: Execution & Standalone Invocation

Protects standalone execution with structured `try/catch` error capture while allowing
dot-sourcing without unwanted auto-execution.

---

## Scanning component inventory

From the repository root:

```powershell
.\_Templates\Get-LiteDeployComponentInventory.ps1 | Format-Table -AutoSize
```

The scanner skips `Test-*`, `*.Template.*`, and `*InteractiveProbe*` (interactive-only script
without a `-Metadata` fast-exit). Architecture tests under `_Tests\` are outside
`Engine\Scripts` and are not scanned.

**Current baseline (2026-10-15):** 28 components with metadata (Admin 11 + Runtime 17).

Related: [architecture smoke tests](../_Tests/README.md), [component guide](../_Docs/COMPONENT_GUIDE.md).
