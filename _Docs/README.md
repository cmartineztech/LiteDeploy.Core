# LiteDeploy documentation map

**Updated:** 2026-10-15

Canonical project docs live here. Component contracts stay next to source under `Engine/Scripts/**/README.md`. `DeploymentShare/**` copies of Tools READMEs are **publish mirrors** of `Engine/Tools/` (keep in sync via Admin.Build — do not edit only the share copy).

Repo tooling (not published to the share):

| Path | Role |
| :--- | :--- |
| [`_Templates/`](../_Templates/README.md) | Component blueprint + `-Metadata` inventory scanner |
| [`_Tests/`](../_Tests/README.md) | Architecture smoke suite (`Test-LiteDeployArchitectureV2.ps1`) |

## Live baseline (do not contradict)

- FullOS entry / resume: **`HKLM\...\Run\LiteDeployFullOS`** (specialize-staged when `WorkflowTag.Actions` > 0; FullOS may re-arm)
- Not used for this path: `SetupComplete.cmd`, `auditUser`, LiteDeploy_* scheduled tasks (gated off)
- Standard = Audit Admin; Domain Join = AutoLogon + temporary `EnableLUA=0` when no `<!--AuditMode-->`; Intune Ready with 0 actions = OOBE only
- Unattend Specialize `RunSynchronous`: Order 1 ComputerDescription (always), Order 2 FullOS Run (actions > 0), Orders 3–4 UAC bypass (DomainJoin / non-Audit + actions > 0)
- MDT reference: Startup / `RunOnce` / `LTIBootstrap` — not Task Scheduler
- Boot modes today: **Network** (SMB UNC) and **Media** (USB). Azure Blob / cloud-pull = future, not implemented
- DeployVault = **future optional tool** (share vault → SecretMap); not incorporated — see [planning IDEAS §12](planning/IDEAS_FOR_IMPLEMENTATION.md#12-future-tool-integration-deployvault-credentialvault--not-incorporated-yet)
- JSONNormalizer / schema merge vs `PSObject.Properties` probing = **future analysis only** — see [planning IDEAS §13](planning/IDEAS_FOR_IMPLEMENTATION.md#13-future-analysis-json-schema-merge-jsonnormalizer-vs-defensive-property-probing)
- Package orchestrator = **planned, not built** — see [PACKAGE_ORCHESTRATOR_PLAN.md](planning/PACKAGE_ORCHESTRATOR_PLAN.md)

## Directory layout

| Path | Contents |
| :--- | :--- |
| [`COMPONENT_GUIDE.md`](COMPONENT_GUIDE.md) | Index of every component README + tests/templates |
| [`LOCAL_TODO.md`](LOCAL_TODO.md) | Active local roadmap / session checklist |
| [`architecture/`](architecture/) | Specs, status, E2E mermaid + overview image |
| [`guides/`](guides/) | Operator / engineer how-tos (WinPE, Engine, drivers, logging, maintenance, ComputerSetup) |
| [`integrations/Credentials/`](integrations/Credentials/) | WinPECT credential handoff |
| [`planning/`](planning/) | Ideas, package orchestrator plan, refactor notes — **not** the live FullOS path until implemented |

## Start here

1. [Project status](architecture/LITEDEPLOY_PROJECT_STATUS.md)
2. [E2E imaging diagram](architecture/LITEDEPLOY_DEPLOYMENT_DIAGRAM.md) (image + mermaid)
3. [Component guide](COMPONENT_GUIDE.md)
4. [WinPE bootstrap](guides/WINPE_BOOTSTRAP.md)
5. [Credentials / FullOS](integrations/Credentials/README.md)
6. [LOCAL_TODO](LOCAL_TODO.md) for next work
7. [Architecture smoke tests](../_Tests/README.md) / [Component templates](../_Templates/README.md)

## What is *not* a duplicate

| Pair | Why both exist |
| :--- | :--- |
| `Engine/Tools/README.md` ↔ `DeploymentShare/Engine/Tools/README.md` | Source vs published share template |
| `Engine/Tools/WinPECT/SOURCE.md` ↔ share copy | Same publish mirror |
| Per-folder `Engine/Scripts/**/README.md` | Component contracts; linked from `COMPONENT_GUIDE.md` |
| `planning/IDEAS_*` vs live guides | Future designs vs implemented baseline |

Do **not** keep a second copy of architecture/guides outside `_Docs/`.
Do **not** keep editable flat `Engine/Scripts/Runtime|Admin/*.ps1` mirrors beside numbered folders (gitignore); publish only via Admin.Build.
