# ComputerSetup mapping

ComputerSetup belongs to BootConfig. Engine passes the configuration to Image and the
selection screen. State retains the configuration under BootObject.Config when supplied by
Boot; it does not turn UI policy settings into unattend elements.

| Property | Consumer and effect |
| --- | --- |
| PromptForComputerName | WorkflowSelection shows/hides the name input; Image includes the selected nonblank name only when enabled |
| ComputerNamePrefix | WorkflowSelection prefills an empty name input; null means no prefix |
| MaxComputerNameLength | WorkflowSelection caps input/validation at 1–15 characters; values above 15 are capped |
| PromptForComputerDescription | WorkflowSelection shows/hides the description input; Image includes the description command only when enabled and the selected text is nonblank |
| DriveSelection | True uses the disk number selected in WorkflowSelection. False always targets Disk 0, independent of disk enumeration order. Missing Disk 0 stops selection rather than choosing a different disk |
| ImageEngine | Image validates the selected imaging sequence (`setup.exe` or `dism.exe`). Workflows can override this baseline via `computerSetup.ImageEngine`. Engine checks before disk changes |
| SkipSetupHardwareRequirements | **Setup.exe only.** When `true`, Image applies WinPE `LabConfig` / `MoSetup` registry bypasses immediately before launching Setup. Ignored for `dism.exe`. See Image README |
| Language | Image fills SetupUILanguage, UILanguage, SystemLocale and UserLocale template placeholders |
| KeyboardLocale | Image fills InputLocale placeholders |
| TimeZone | Image fills TimeZone/Timezone template placeholders |
| RegisteredOrganization | Image fills RegisteredOrganization only for nonblank text; persisted state omits null/empty/whitespace values |
| RegisteredOwner | Image fills RegisteredOwner only for nonblank text; persisted state omits null/empty/whitespace values |
| JoinWorkGroup | Image fills JoinWorkGroup/JoinWorkgroup template placeholders only for nonblank text; persisted state omits null/empty/whitespace values |
| JoinDomain | Image fills JoinDomain template placeholders only for nonblank text; persisted state omits null/empty/whitespace values |
| MachineObjectOU | Image fills MachineObjectOU template placeholders only for nonblank text; persisted state omits null/empty/whitespace values |
| ProductKey (optional) | Image adds a format-validated installation key to windowsPE Setup/UserData; see Image README |

State serialization omits only blank RegisteredOrganization/RegisteredOwner/JoinWorkGroup/JoinDomain/MachineObjectOU fields under this
rule. It preserves populated strings, false booleans, numeric settings and a null
ComputerNamePrefix. It does not modify the caller's BootConfig object. Existing credential
filtering still applies. This policy is applied to dictionary and JSON-object property bags.

## Startup vs ComputerSetup (hardware-related flags)

| Section | Property | Owner | Effect |
| --- | --- | --- | --- |
| `Startup` | `SkipHardwarePreCheck` | UI.HardwarePrecheck / Engine | When `true`, skips the Phase 1 readiness UI (inventory may still be gathered) |
| `ComputerSetup` | `SkipSetupHardwareRequirements` | Image | When `true` and engine is `setup.exe`, writes WinPE LabConfig/MoSetup bypasses before Setup launches |

`Startup.SkipHardwareRequirments` was removed. Do not regenerate it.

## Workflow-Level ComputerSetup Overrides

Workflows defined under `DeploymentShare\WorkFlows\*.json` support an optional `"computerSetup"` object.
When specified on a workflow, non-empty properties override the baseline `BootConfig.json` values during execution:

- **Precedence**: `Workflow.computerSetup.<Property>` $\rightarrow$ `BootConfig.ComputerSetup.<Property>` $\rightarrow$ Built-in default.
- **Example**: `Domain Join Workflow.json` defines `"computerSetup": { "ImageEngine": "dism.exe" }`, directing the deployment engine to apply the image with DISM instead of Setup.exe.
- **Example**: `"computerSetup": { "ImageEngine": "Setup.exe", "SkipSetupHardwareRequirements": true }` enables Setup hardware-requirement bypasses for that workflow only.
- **Empty Object**: Setting `"computerSetup": {}` preserves global `BootConfig.json` settings without overrides.

## Unattended Answer File Archetypes

LiteDeploy maintains 3 distinct answer file templates under `DeploymentShare\Content\Unattend\`:

1. **`IntuneReady.xml` (Cloud-Native / Entra ID / Microsoft Intune)**:
   - Sets `<ProtectYourPC>2</ProtectYourPC>` (installs critical and security updates only).
   - Suppresses setup and EULA friction (`HideEULAPage`, `HideOEMRegistrationScreen`), while keeping Wi-Fi setup available (`HideWirelessSetupInOOBE = false`).
   - Leaves modern OOBE active so the system lands directly on the Microsoft 365 / Entra sign-in screen.
   - Omits `Microsoft-Windows-UnattendedJoin` to allow cloud enrollment to manage device identity.

2. **`Standard.xml` (Workgroup / Local Account / Standalone)**:
   - Sets `<ProtectYourPC>1</ProtectYourPC>` (recommended settings with full Microsoft Defender & security enabled).
   - Injects optional `<!--JoinWorkGroup-->` under `Microsoft-Windows-UnattendedJoin` (defaults to `WORKGROUP` if omitted).
   - Suppresses online account screens (`HideOnlineAccountScreens = true`) while enabling local account creation (`HideLocalAccountScreen = false`) with `<!--UserAccounts-->` and `<!--AutoLogon-->` placeholders.

3. **`DomainJoin.xml` (Active Directory Domain Join)**:
   - Sets `<ProtectYourPC>3</ProtectYourPC>` (disables automatic initial updates during OOBE for domain staging).
   - Contains the full identity placeholder block (`<!--Credentials-->`, `<!--JoinDomain-->`, `<!--JoinWorkGroup-->`, `<!--MachineObjectOU-->`, `<!--OfflineDomainJoinBlob-->`).
   - Suppresses both online and local account screens (`HideLocalAccountScreen = true`) to hand off directly to the domain logon interface.

## Answer File Provenance and Application

- **Provenance Header Comment**: Every generated `unattend.xml` automatically receives an audit header:
  ```xml
  <!-- Generated by LiteDeploy Engine | Workflow: <Name> (<Id>) | Template: <TemplateFileName> | Date: yyyy-MM-dd HH:mm:ss -->
  ```
- **Dual Application Delivery**:
  - **Setup Engine (`setup.exe`)**: Passes the answer file via command-line argument `/Unattend:"X:\unattended.xml"`.
  - **DISM Engine (`dism.exe`)**: Stages the generated answer file directly into the offline target Panther directory `W:\Windows\Panther\unattend.xml`, where Windows Setup automatically detects and processes it during the `specialize` and `oobeSystem` passes on first boot.

## Known implementation gaps

ComputerDescription is interpolated into XML and cmd.exe text without appropriate handling; an ampersand can fail answer-file XML validation. ProductKey is format-checked for the answer file but currently survives State serialization. The former F5 disk-policy mismatch is fixed as described below. These are release blockers, not completed safeguards.

## Effective configuration after selection (implemented)

WorkflowSelection returns its current BootConfig object in memory, including F5 reloads. After Passed=true, Engine requires that object, adopts it for subsequent phases and BootObject.Config in deployment state, and revalidates ImageEngine before disk preparation. It does not reread the configuration file. Selection JSON and nested SelectionData omit the duplicate BootConfig; state retains its existing BootObject.Config serialization behavior.

DriveSelection=false resolves Disk 0 and requires the confirmed TargetDiskIndex to be 0. Otherwise Engine uses the confirmed nonnegative disk number. Missing returned configuration, invalid target, or a policy/confirmation mismatch stops before deployment-folder creation and disk preparation. The technician must reopen selection and confirm again; Engine never silently substitutes a different disk.

This resolves the previously reported F5/stale-policy target mismatch. Automated checks cover both policy-change directions, disagreement, missing configuration, cancellation and the in-memory/JSON result contract. Real WinPE imaging remains unverified. Other release blockers remain open.
