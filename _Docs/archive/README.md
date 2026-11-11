# LiteDeploy Documentation Archive

This folder preserves historical planning documents, early architectural proposals, and past audit records. These documents are retained for **provenance, historical context, and architectural decision tracking**, but they **do not represent the live LiteDeploy Core architecture**.

For the active, authoritative architecture, refer to the documents in `_Docs/architecture/`, `_Docs/guides/`, and `_Docs/planning/`.

---

## Archived Documents & Their Active Equivalents

| Archived Document | Original Purpose / Date | Reason for Archiving | Active Authoritative Replacement |
| :--- | :--- | :--- | :--- |
| **`REFACTOR_PLAN.md`** | 8-phase v2 refactoring roadmap (Oct 2026). | **Completed.** All 8 migration phases were fully implemented and verified. | [`_Docs/LOCAL_TODO.md`](../LOCAL_TODO.md) & [`LITEDEPLOY_PROJECT_STATUS.md`](../architecture/LITEDEPLOY_PROJECT_STATUS.md) |
| **`PROJECT_SIMPLIFICATION_REVIEW.md`** | Codebase simplification audit (Oct 13, 2026). | **Completed.** Flat editable mirrors were eliminated, workflow logic deduplicated, and obsolete assets removed. | [`_Docs/architecture/LITEDEPLOY_PROJECT_STATUS.md`](../architecture/LITEDEPLOY_PROJECT_STATUS.md) |
| **`COMPONENT_RESPONSIBILITY_AUDIT.md`** | Component boundary analysis (Oct 8, 2026). | **Resolved.** Overlaps reported between Workflow and UI were resolved via canonical exports. | [`_Docs/COMPONENT_GUIDE.md`](../COMPONENT_GUIDE.md) & [`ENGINE_READING_GUIDE.md`](../guides/ENGINE_READING_GUIDE.md) |
| **`FAST_TRANSITION_NETWORK_SPECIFICATION.md`** | RAM caching & hardware reuse spec. | **Completed & Live.** Implemented in `LiteDeploy.Drivers.ps1` and `LiteDeploy.Workflow.ps1`. | [`_Docs/architecture/LITEDEPLOY_CATALOG_WORKFLOW_SPEC.md`](../architecture/LITEDEPLOY_CATALOG_WORKFLOW_SPEC.md) |
| **`LITEDEPLOY_DEPLOYMENT_PLAN.md`** | Early deployment sequence proposal. | **Superseded.** Replaced by live E2E diagrams and statecharts. | [`_Docs/architecture/LITEDEPLOY_DEPLOYMENT_DIAGRAM.md`](../architecture/LITEDEPLOY_DEPLOYMENT_DIAGRAM.md) |
| **`LITEDEPLOY_COMPONENT_REFACTOR_V2.md`** | Preliminary draft for v2 component organization. | **Superseded.** Absorbed into project status and component guides. | [`_Docs/COMPONENT_GUIDE.md`](../COMPONENT_GUIDE.md) & [`LITEDEPLOY_PROJECT_STATUS.md`](../architecture/LITEDEPLOY_PROJECT_STATUS.md) |
| **`COMPUTER_SETUP_MAPPING.md`** | ComputerSetup properties & answer file archetypes. | **Consolidated.** Merged as Section 14 in the Catalog & Workflow specification. | [`_Docs/architecture/LITEDEPLOY_CATALOG_WORKFLOW_SPEC.md`](../architecture/LITEDEPLOY_CATALOG_WORKFLOW_SPEC.md#14-computersetup-mapping-overrides--unattend-archetypes) |
