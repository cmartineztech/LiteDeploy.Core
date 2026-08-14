# LiteDeploy Catalog and Workflow Specification

Status: **Proposed version 1 contract.** The existing ImportOSMedia catalog is authoritative; workflow and package catalogs are planned.

This specification keeps operating-system media, workflows, actions, and packages independent. It allows one workflow to run against multiple compatible Windows editions and allows one package to be reused by multiple workflows.

Related documents:

- [LITEDEPLOY_DEPLOYMENT_PLAN.md](LITEDEPLOY_DEPLOYMENT_PLAN.md)
- [LITEDEPLOY_DEPLOYMENT_DIAGRAM.md](LITEDEPLOY_DEPLOYMENT_DIAGRAM.md)
- [LITEDEPLOY_PROJECT_STATUS.md](LITEDEPLOY_PROJECT_STATUS.md)
- [ImportOSMedia/README.md](../../ImportOSMedia/README.md)

## 1. Catalog relationship model

```text
DeploymentProfile (optional UI convenience)
    ├── osId
    ├── editionId
    └── workflowId

osId
    └── Content/OperatingSystems/catalog.json
            ├── setupPath
            ├── imagePath
            ├── mediaRoot
            └── editions[]
                    └── editionId + imageIndex

workflowId
    └── Workflows/<workflowId>.json
            ├── requiredCredentialIds[]
            └── actions[]
                    └── packageId

packageId
    └── Packages/<packageId>/package.json
            ├── source and command
            ├── detection
            ├── compatibility
            └── exit/reboot behavior
```

## 2. Identifier rules

All identifiers are immutable after publishing.

| Identifier | Scope | Example |
| --- | --- | --- |
| `osId` | Globally unique OS-media payload | `win11-26h2-es-es-26300.8772-x64` |
| `editionId` | Unique within its parent `osId` | `win11-26h2-windows-11-pro-26300.8772-x64` |
| `workflowId` | Globally unique workflow | `standard-workstation` |
| `actionId` | Unique within its workflow and stable across revisions | `install-office` |
| `packageId` | Globally unique package | `microsoft-office` |
| `profileId` | Globally unique presentation profile | `win11-pro-standard` |
| `credentialId` | Globally unique secret reference | `DomainJoin` |

Identifier format:

```text
^[A-Za-z0-9][A-Za-z0-9._-]*$
```

Selections must always persist both `osId` and `editionId`. An edition is resolved only within its parent OS entry because different language payloads can contain equivalent edition IDs.

Display names may change without breaking references. IDs must not contain a password, username, machine-specific value, or deployment-source path.

## 3. Repository layout

```text
<DeploymentRoot>\
  Content\
    OperatingSystems\
      catalog.json
      schemas\
        os-catalog.schema.json
      <media-folder>\
        os.json
        setup.exe
        sources\install.wim
    Packages\
      catalog.json
      schemas\
        package.schema.json
        package-catalog.schema.json
      <package-id>\
        package.json
        payload\...
    Drivers\...
  Workflows\
    catalog.json
    schemas\
      workflow.schema.json
      workflow-catalog.schema.json
      deployment-profile.schema.json
    <workflow-id>.json
  Engine\Scripts\...
```

Forward-slash paths stored in JSON are repository-relative. Runtime code resolves them against the validated deployment root and normalizes them with `Join-Path`. Catalog paths must not escape the deployment root through `..`, rooted paths, or alternate data streams.

## 4. Operating-system catalog

`ImportOSMedia/LiteDeploy.ImportOSMedia.ps1` already creates:

```text
Content/OperatingSystems/<media-folder>/os.json
Content/OperatingSystems/catalog.json
```

Its current central catalog fields are the version 1 source contract:

```json
{
  "$schema": "./schemas/os-catalog.schema.json",
  "operatingSystems": [
    {
      "osId": "win11-26h2-es-es-26300.8772-x64",
      "fullName": "Windows 11 26H2",
      "osName": "Windows 11 26H2 (26300.8772)",
      "version": "26H2",
      "buildVersion": "10.0.26300.8772",
      "defaultLanguage": "es-ES",
      "supportedLanguages": ["es-es"],
      "importedDate": "2026-08-10",
      "arch": "x64",
      "isCustomImage": false,
      "enabled": true,
      "mediaRoot": "Content/OperatingSystems/win11_26H2_26300_8772_eses",
      "setupPath": "Content/OperatingSystems/win11_26H2_26300_8772_eses/setup.exe",
      "imagePath": "Content/OperatingSystems/win11_26H2_26300_8772_eses/sources/install.wim",
      "editions": [
        {
          "editionId": "win11-26h2-windows-11-pro-26300.8772-x64",
          "editionName": "Windows 11 Pro",
          "skuCode": "Professional",
          "imageIndex": 6,
          "enabled": true,
          "buildVersion": "10.0.26300.8772",
          "arch": "x64",
          "defaultLanguage": "es-ES",
          "supportedLanguages": ["es-es"]
        }
      ]
    }
  ]
}
```

The deployment runtime must additionally verify that:

- The selected OS and edition are enabled.
- `setupPath` and `imagePath` resolve inside the deployment root.
- The referenced files exist.
- The image index exists in the referenced WIM or ESD.
- The media architecture matches WinPE and the target requirements.
- Setup supports the requested command-line switches.
- Optional published hashes match before deployment.

Planned catalog additions should remain backward-compatible:

```json
{
  "schemaVersion": 1,
  "contentHash": {
    "algorithm": "SHA256",
    "image": "<hex-value>",
    "setup": "<hex-value>"
  }
}
```

## 5. Workflow definition

A workflow defines an ordered deployment policy. It does not contain a WIM path, Setup path, or image index.

```json
{
  "$schema": "./schemas/workflow.schema.json",
  "schemaVersion": 1,
  "workflowId": "standard-workstation",
  "name": "Standard Workstation",
  "description": "Standard managed workstation configuration",
  "enabled": true,
  "revision": 1,
  "requiredCredentialIds": [
    "DeploymentShare",
    "DomainJoin"
  ],
  "compatibility": {
    "architectures": ["x64"],
    "minimumBuild": 26100,
    "skuCodes": ["Enterprise", "Professional"]
  },
  "actions": [
    {
      "actionId": "configure-base-os",
      "name": "Configure base operating system",
      "type": "Package",
      "packageId": "configure-base-os",
      "phase": "FullOS",
      "executionContext": "System",
      "continueOnError": false,
      "retry": {
        "maximumAttempts": 2,
        "delaySeconds": 30
      }
    },
    {
      "actionId": "install-office",
      "name": "Install Microsoft Office",
      "type": "Package",
      "packageId": "microsoft-office",
      "phase": "FullOS",
      "executionContext": "System",
      "dependsOn": ["configure-base-os"],
      "continueOnError": false
    }
  ]
}
```

### Supported execution phases

| Phase | Description |
| --- | --- |
| `WinPE` | Before Windows Setup starts. Use only for actions designed for WinPE. |
| `OfflineOS` | After Setup returns with `/NoReboot`, operating on the offline Windows volume. |
| `FullOS` | Installed Windows, normally under the SYSTEM engine task. |
| `UserLogon` | Requires an interactive user session. Must not block the SYSTEM engine indefinitely. |

### Supported execution identities

| Context | Use |
| --- | --- |
| `System` | Machine-level packages, configuration, domain join, and credential-dependent actions. |
| `InteractiveUser` | Per-user MSIX, user profile changes, and visible user actions. |
| `CredentialId` | Exceptional run-as operations using an explicitly declared credential reference. |

The engine must reject an action whose phase and execution context are incompatible.

## 6. Action contract

Every action requires:

- Stable `actionId`
- Friendly name
- Action type
- Execution phase
- Execution context
- Timeout
- Success behavior
- Detection or completion evidence
- Retry policy
- Dependency list
- Required credential IDs, when applicable

Optional action conditions:

```json
{
  "conditions": {
    "architectures": ["x64"],
    "minimumBuild": 26100,
    "maximumBuild": null,
    "skuCodes": ["Enterprise", "Professional"],
    "manufacturers": ["Lenovo"],
    "models": ["21KC004AUS"],
    "requiresNetwork": true
  }
}
```

Conditions return one of three results:

- `Applicable` — execute the action.
- `NotApplicable` — record the action as skipped successfully.
- `Indeterminate` — stop unless the workflow explicitly permits a safe skip.

## 7. Package definition

Packages describe how content is detected and executed. Workflows reference packages by ID and do not duplicate installer commands.

```json
{
  "$schema": "../schemas/package.schema.json",
  "schemaVersion": 1,
  "packageId": "microsoft-office",
  "name": "Microsoft Office",
  "version": "2026.01",
  "enabled": true,
  "packageType": "Exe",
  "source": "Content/Packages/microsoft-office/payload",
  "install": {
    "file": "setup.exe",
    "arguments": "/configure configuration.xml",
    "timeoutMinutes": 90,
    "successExitCodes": [0, 3010],
    "rebootExitCodes": [3010]
  },
  "detection": {
    "type": "Registry",
    "path": "HKLM:\\SOFTWARE\\Microsoft\\Office\\ClickToRun\\Configuration",
    "valueName": "VersionToReport",
    "operator": "VersionGreaterThanOrEqual",
    "expectedValue": "16.0"
  },
  "compatibility": {
    "architectures": ["x64"],
    "minimumBuild": 26100
  },
  "integrity": {
    "algorithm": "SHA256",
    "manifestPath": "Content/Packages/microsoft-office/package.hashes.json"
  }
}
```

### Initial package handlers

| `packageType` | Engine behavior |
| --- | --- |
| `Msi` | Run `msiexec.exe`; normalize MSI success and reboot codes. |
| `Exe` | Run the declared executable with explicitly supplied silent arguments. |
| `Msix` | Support provisioned-machine or interactive-user installation as declared. |
| `PowerShell` | Run an approved `.ps1` using Windows PowerShell 5.1 initially. |
| `Cmd` | Run an approved `.cmd` or `.bat` through `cmd.exe /c`. |

Future handlers may include `WindowsFeature`, `Registry`, `Driver`, `Firmware`, and `Autopilot`.

An executable package without documented silent arguments, detection, timeout, and exit-code rules is invalid for unattended deployment.

## 8. Detection contract

Supported detection types should include:

- `MsiProductCode`
- `Registry`
- `File`
- `FileVersion`
- `AppxPackage`
- `ProvisionedAppxPackage`
- `PowerShell`

Detection runs before execution and again after a successful installer exit. An action is complete only when its post-execution detection succeeds, unless its action type has another explicit durable completion rule.

Script-based detection must return a Boolean or a typed detection result. Console text alone must not determine success.

## 9. Reboot behavior

Packages report one of:

- `NoReboot`
- `RebootRequired`
- `RebootInitiatedUnexpectedly`
- `Failed`

Installers and scripts must not reboot the machine directly. They return a defined reboot exit code, after which the engine:

1. Completes and atomically persists the action state.
2. Records the next action.
3. Changes deployment state to `RebootRequested`.
4. Requests the reboot.
5. Resumes through `EngineResume`.

## 10. Credential references

Workflows and actions contain credential IDs only:

```json
{
  "requiredCredentialIds": ["DomainJoin"],
  "runAsCredentialId": "ApplicationInstall"
}
```

The engine validates that each requested ID:

- Was declared by the selected workflow.
- Was successfully transferred through WPCT.
- Imports as a `PSCredential` under the executing SYSTEM identity.
- Is permitted for the requesting action type.

Credentials, usernames, passwords, secure strings, vault seeds, and vault payloads are prohibited in workflow, package, selection, and state JSON.

## 11. Optional deployment profiles

Profiles provide combined choices for the technician UI while retaining separation internally:

```json
{
  "$schema": "./schemas/deployment-profile.schema.json",
  "schemaVersion": 1,
  "profileId": "win11-pro-standard",
  "name": "Windows 11 Professional - Standard",
  "enabled": true,
  "osId": "win11-26h2-es-es-26300.8772-x64",
  "editionId": "win11-26h2-windows-11-pro-26300.8772-x64",
  "workflowId": "standard-workstation"
}
```

Profiles are presentation and policy objects. The deployment engine persists and validates the resolved IDs rather than trusting display text.

## 12. Validation order

Before the UI enables Start Deployment:

1. Parse every JSON document strictly.
2. Validate each document against its versioned schema.
3. Reject duplicate IDs within their defined scope.
4. Resolve every profile OS, edition, workflow, action, package, dependency, and credential reference.
5. Detect dependency cycles.
6. Validate action phase and execution-context combinations.
7. Confirm required package handlers exist.
8. Confirm referenced files remain inside the deployment root.
9. Confirm enabled OS media and package payloads exist.
10. Evaluate compatibility against the selected OS and hardware.

The deployment engine repeats safety-critical validation immediately before disk modification and immediately before each action.

## 13. Versioning policy

- Every schema includes `schemaVersion`.
- Readers reject unsupported major schema versions.
- Optional fields may be added without changing existing semantics.
- Published IDs are never reused for different content.
- Updating package payload or behavior increments its version.
- Updating workflow ordering or policy increments its revision.
- Deployment state records the resolved workflow revision and package versions so a resumed deployment cannot silently change definitions.

