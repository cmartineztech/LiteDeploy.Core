# Architecture checks

`Test-LiteDeployArchitectureV2.ps1` checks PowerShell parsing, metadata, imports, named paths,
source/published Engine validation, and selected failure conditions. It uses inert screens
and mocked deployment operations. It does not run Setup, format disks, or install packages.

This folder lives at the **repository root** (`_Tests\`). It is **not** published by Admin.Build.

Run in Windows PowerShell 5.1 STA from the repository root:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass `
  -File '.\_Tests\Test-LiteDeployArchitectureV2.ps1' `
  -TestRoot 'C:\LiteDeploy-TestFixtures'
```

With a published Runtime layout (absolute path required):

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass `
  -File '.\_Tests\Test-LiteDeployArchitectureV2.ps1' `
  -PublishedRuntimeRoot 'C:\DeploymentShare\Engine\Scripts\Runtime' `
  -TestRoot 'C:\LiteDeploy-TestFixtures'
```

| Parameter | Use |
| --- | --- |
| RepoRoot | Optional checkout root; inferred as parent of `_Tests` when omitted |
| PublishedRuntimeRoot | Optional flat Runtime folder to check alongside source (must be absolute) |
| TestRoot | Scratch directory; defaults to a unique folder beneath the temp directory |

The suite creates/replaces configuration, mock-screen, and log fixtures under TestRoot and
performs read-only hardware/storage queries. Use a dedicated directory. Imported components
may initialize session state or local logging. Exit 0 means these checks passed; exit 1 means
one or more failed. The console reports counts and individual failures.

**Current baseline (2026-10-15):** 155 / 155 with DeploymentShare published Runtime.

Actual WinPE boot, WPF rendering, share credentials, disk deployment and reboot/resume are
not covered. See the [maintenance guide](../_Docs/guides/MAINTENANCE.md) for the release checks.
