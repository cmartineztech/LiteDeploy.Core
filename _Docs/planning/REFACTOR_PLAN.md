# LiteDeploy Core refactor plan

Prepared October 13, 2026 from a second inspection of the current working tree.
Status: planned; application code has not been refactored.

**Currency (2026-10-15):** Flat editable Engine Script mirrors removed/gitignored; smoke suite
at `_Tests\` (**155 / 155** with published Runtime); templates/inventory at `_Templates\`.
Counts and divergent-copy notes below are historical to the plan date.

## Objective

Make execution easier to follow, give each behavior one owner, and eliminate implicit path discovery after bootstrap while preserving supported deployment behavior and public script entry points.

Keep the existing PowerShell 5.1 scripts, numbered source folders, and flat published layout. Prefer small functions within existing components. Introduce another file only when two real consumers need a cohesive helper and importing an existing component would cause unwanted side effects.

## Current baseline and corrections to the earlier review

- FullOS first launch is now `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\LiteDeployFullOS`, staged in unattend specialize when the workflow has actions (short `reg add` / `REG_EXPAND_SZ`; not `auditUser`). FullOS may re-arm the same Run key for mid-deploy reboot survival. SYSTEM deferral and cleanup of LiteDeploy-owned legacy startup settings are existing behavior to preserve.
- Scheduled tasks are legacy cleanup, not the current resume mechanism. SetupComplete is not staged by the current Engine handoff, although Build still discovers the legacy asset.
- FullOS package orchestration is still pending at `Runtime/100-Engine/LiteDeploy.FullOS.ps1:1008`. Loading package helpers and reconnecting after reboot are not an implemented automatic package loop.
- A fresh Windows PowerShell 5.1 architecture run returned **185 passed, 1 failed**. The numbered source FullOS script fails parsing at line 329. PowerShell 7 parsed it successfully, so verification must use the supported 5.1 host. Investigate file encoding and the non-ASCII punctuation on that line before broader work; the exact encoding cause has not yet been proven.
- Text comparison, ignoring line endings and surrounding whitespace, still finds 10 divergent copies. The current mismatch set includes the flat Engine FullOS copy; the prior published Engine mismatch is no longer in that set.
- Workflow is still absent from Engine's required component list. Selection can therefore load a published Workflow through its own fallback.
- Admin JSON validation and the unused Build Overwrite option remain visible in source. Their false-success/overwrite behavior was reproduced during the first review and should receive regression coverage before fixes.
- CodeGraph initialization previously failed, and its CLI still reports a missing installed module. This plan uses direct source inspection. Third-party reference code, downloaded payloads, and binaries are outside the refactor scope; experimental implementations are not merged into the product by this plan.

## Component ownership

| Component | Owns | Boundary |
| --- | --- | --- |
| Boot | Discover boot configuration/media; initialize WinPE networking; retries and technician prompts; build BootObject; launch Engine | After discovery, supply explicit context. Use Environment's share mapping mechanism. |
| Environment | Development/production file maps; normalized deployment/local paths; path validation; low-level TCP probe; SMB map/unmap; reusable process mechanics | No UI prompts, catalog parsing, deployment decisions, or unsolicited content creation. |
| Hardware | CPU, RAM, firmware, TPM, storage, NIC inventory and readiness facts | No catalog selection or SMB connection policy. A legacy network API may delegate to Environment during migration. |
| Workflow | Workflow/catalog parsing and validation; effective workflow settings; OS selection domain; selection result and JSON contract | No WPF controls, image installation, or package execution. |
| Drivers | Vendor/SKU/model matching; driver selection facts; integrity checks; archive extraction and staging | Consume explicit share/staging paths and hardware data. Image performs offline driver injection. |
| Disk | Target-disk eligibility and explicit wipe/partition/format operations | Preserve ConfirmDestroy. No implicit substitute disk, OS application, or workflow UI. |
| Image | Setup/DISM application; answer-file generation; offline servicing; boot files; first-boot command placement in answer files | Consume confirmed selection, disk results, configuration, and resolved content paths. No source-root discovery or resume lifecycle control. |
| Packages | Package parsing/validation, staging, detection where supported, execution, exit-code/timeout results | Execute one package/requested sequence; FullOS owns deployment continuation and reboot checkpoints when sequencing is implemented. |
| State | State contract, phases/statuses, safe serialization, persistent/RAM transport, display projection, checkpoint validation | No WPF rendering, workflow selection, package launching, or share mounting. |
| Logs | Log formatting/redaction, writing, and log/artifact mirroring | No second deployment-state schema or duplicate state transitions. |
| Engine | Visible WinPE phase order, dependency declarations, result gates, progress process lifecycle, payload/credential handoff coordination | Delegate domain work; pass paths/context; use State to record transitions. |
| FullOS | Interactive entry, legacy deferral/cleanup, Run entry lifecycle, one-time restart, credential retrieval, reconnect/mirror coordination, future package continuation | Use Environment for mapping mechanics and WinPECT for credential transfer. Keep current resume semantics during cleanup. |
| Runtime UI | Present domain facts, collect choices, render progress, manage control events and window behavior | No independent catalog parsing, root discovery, state schema, or deployment operation. |
| Admin.Config | Author/default/validate BootConfig | Runtime consumes configuration; do not add an Admin dependency to Runtime. Share pure config rules only where actually needed. |
| Admin.Content | Create share layout, accounts, SMB share and ACLs | These are intentional administrator actions, separate from runtime path resolution. |
| Admin.Images / Drivers / Packages / Workflows | Author/import their content and invoke domain validation | Domain rules have one implementation; UI presents authoring actions. |
| Admin.Validation | Aggregate validation results and format the summary | Do not maintain weaker parallel checks that treat corrupt input as valid. |
| Admin.Build | Discover canonical source; validate publish input; copy to explicit targets; generate compatibility artifacts and manifest | No application deployment, source editing, or silently ignored overwrite policy. |
| Admin.Utilities | Small helpers actually shared by Admin consumers | Avoid a general-purpose catch-all. Remove unused helpers only after reference/entry-point review. |
| WinPECT adapter | Credential transfer conventions and upstream integration | Engine/FullOS coordinate calls; do not duplicate encryption/secret serialization in those scripts. |

Calling another component is collaboration, not overlapping ownership. For example, Boot owns retry policy while Environment owns how a share is mapped. WinPE and FullOS can have different credential acquisition and retry policies while sharing that mapping mechanism.

## Path contract

**Boot discovers the source → Environment resolves the layout → Engine/FullOS pass explicit paths → components consume them.**

Use the existing RuntimePaths structure, extending it only for paths currently reconstructed by multiple consumers. Keep DeploymentRoot, RuntimeRoot, WorkingRoot, StatePath, LocalLogDirectory, and RequiredFiles. Add explicit tools, content, and offline staging paths as needed. Distinguish the script root from the deployment content root; deriving one by taking the parent of the other is not valid in both layouts.

Rules:

1. Boot may scan defined RAM/removable-media candidates before a source is selected. Document precedence and errors. Do not remove genuine boot-media discovery.
2. Once selected, a supplied root/config path is authoritative. Missing or invalid paths fail with component name and expected path.
3. Relative catalog paths resolve against the declared DeploymentRoot. Absolute supported content paths remain supported. Retain path traversal/containment checks where currently required.
4. Workflow, Packages, and Drivers no longer silently default to Z:. Standalone commands require ShareRoot or an explicit supplied context. Document this intentional tightening of standalone invocation.
5. Image no longer walks to a sibling DeploymentShare, derives the content root from ComponentRoot, or uses the current working directory as a fallback. A direct absolute image input can still work without a share root where no relative content is needed.
6. Selection loads Workflow through RequiredFiles. Delete its fallback to a published file. Include Workflow in Engine validation before UI opens.
7. FullOS's loader uses Environment's file map. Unknown component names fail instead of constructing LiteDeploy.<name>.ps1.
8. Move repeated Tools/WinPECT and offline-root joins into Environment. Old Tools layouts remain an explicit legacy option/migration adapter until callers are accounted for; do not probe both trees silently in ordinary execution.
9. Compute FullOS local root from explicit startup arguments and validated state before arming the Run entry. Retain the separate legacy SYSTEM deferral path, where state may not yet be available.
10. Avoid persistent WinPE drive letters in post-boot commands. Preserve the existing system-drive expansion and test custom LocalRootName with spaces and command quoting.

This changes fallback behavior deliberately while preserving deployment capabilities. Release notes and standalone examples must reflect the stricter inputs.

## Implementation sequence

### Stage 0 — Recover a reliable baseline

Repair the 5.1 FullOS parse failure in canonical source. Determine whether encoding or punctuation is responsible. Establish a consistent source encoding supported by 5.1; ASCII punctuation in executable strings reduces ambiguity, while localized text must retain a valid encoding.

Record current script entry points, switches, result objects, phase order, cancellation/failure behavior, credential exclusions, and FullOS restart/resume markers. Capture source hashes and current published artifacts before reconciling copies. Never overwrite or delete divergent copies until their unique changes are accounted for.

**Gate:** all maintained canonical scripts parse under 5.1; architecture checks pass; current source and published results are reported separately.

### Stage 1 — Make publishing deterministic

Use numbered folders as canonical source. Reconcile flat Engine copies and move generated output out of the editable source area, or clearly treat and ignore it as build output. Keep DeploymentShare configuration/content independent of script generation.

Admin.Build should reject destination filename collisions, honor Overwrite, list the exact payload, and emit a small file/hash manifest. Retain target-specific bootstrap/share/media maps. Do not add a package manager or build framework.

Treat DeploymentEngine as a generated compatibility artifact. Keep its existing semantics until boot-media callers are checked. Exclude SetupComplete from the normal current release payload after verifying legacy requirements; leave any supported legacy packaging explicit.

**Gate:** two scratch publishes from the same source produce the same payload/hashes; Overwrite=false preserves existing files; Overwrite=true replaces them; published artifacts parse under 5.1.

### Stage 2 — Enforce paths and dependencies

Update Environment's map and context paths, Engine's requirements, Selection's imports, Image root resolution, domain ShareRoot inputs, and FullOS loading. Use explicit file checks; do not add another resolver or global service registry.

**Gate:** source mode loads source Workflow; production mode loads published Workflow; a missing required file fails before UI/state writes/disk operations; execution from a different current directory behaves identically with explicit inputs; custom drive/share/media/local-root paths work. No implicit Z: or sibling-tree fallback remains in these consumers.

### Stage 3 — Give Workflow one domain implementation

Unify catalog reads, catalog labels, JSON checks, selection result creation, and persistence in Workflow. The current constructors differ, so migrate the UI's effective BootConfig/UID/paths/driver fields explicitly; do not simply delete the UI functions and rely on same-named domain functions.

Preserve BootConfig in memory and exclude it from persisted selection. Keep controls, validation presentation, and tree rendering in UI. Pass hardware inventory through existing parameters instead of querying it again without need. Reload only on an explicit refresh.

**Gate:** cancellation and success contracts remain stable; effective false/null settings survive; no secrets are persisted; selection validates an explicit disk; OS/architecture filtering and custom/OEM/in-box driver choices match the baseline.

### Stage 4 — Consolidate validators

Admin.Validation aggregates domain results. Workflow/Packages authoring validates the same rules used by runtime. Configuration validation must parse JSON and check required settings, not merely test file existence. Invalid workflow JSON must produce an error tied to its file instead of disappearing from results.

Use one small result shape for validation: Valid, Errors, Warnings, and relevant file identity. Adapt legacy Passed/IsValid interfaces at public boundaries until callers migrate; do not rewrite every deployment result into a universal schema.

**Gate:** malformed/missing/empty documents, invalid references, and invalid package commands fail appropriately; valid current fixtures continue to pass; optional missing content follows documented warning policy.

### Stage 5 — Make orchestration readable

Extract a few cohesive functions inside Engine: precheck, selection, disk phase, driver staging, image phase, and handoff. Keep calls in visible execution order. Each function receives the state/context it uses and returns its relevant result.

Move shared transition/failure recording into State using a small extension of its existing API. Preserve cancellation differences, timestamps, errors, mirror activation timing, and driver fallback policy. Never simplify a failure branch by allowing deployment to continue farther than before.

Similarly separate FullOS context loading, entry/resume setup, share reconnect, and final result assembly. Reduce global writes to compatibility boundaries and known State/Logs publication points. Import helpers at a clear entry scope; stop copying newly discovered functions globally as an implicit loader mechanism. Preserve external commands while changing internals.

**Gate:** mocked phase execution proves order and failure stops; no missing selection reaches Disk; import-only usage performs no deployment; repeated imports do not change unrelated caller variables or reuse stale paths.

### Stage 6 — Consolidate support mechanics and align comments

Use one TCP socket helper in Environment; callers keep distinct SMB/internet policies. Consolidate share mapping after comparing WinPE and FullOS options, retries, persistence, credential handling, and Explorer visibility. Do not assume these policies are identical.

State owns phase labels and a pure progress projection. Progress consumes that projection and renders it. Make loading read-only helpers inert so Progress does not reset active state, open writable maps, create directories, or start mirroring.

Share genuinely common WPF palette/resource generation between Admin screens. Keep native console hosting separate. A small UI resource helper is acceptable if needed by both screens; no universal UI framework.

Fix DISM's restarted stopwatch as a separate small correctness change. Review UTC formatting: strings ending in Z must represent actual UTC. Preserve state schema/read compatibility when correcting timestamps.

**Gate:** shared probes dispose sockets on timeout/error; progress correctly renders FullOS and terminal states; mapping options and credential exclusions remain covered; elapsed imaging time is measured across the operation.

### Stage 7 — Bound compatibility and documentation

Remove dead helpers only after checking internal references, public examples, generated launchers, and known external boot/release consumers. Engine's unused offline Setup CmdLine helper is a candidate; preserve cleanup of LiteDeploy-owned legacy keys and never clear stock sysprep settings.

Keep the temporary InteractiveProbe behavior until its replacement is implemented and validated, or make its launch an explicit diagnostic option with a documented default migration. Do not silently remove a currently used window/behavior as cosmetic cleanup.

Update component READMEs, README execution diagrams, metadata, and examples together. Label package orchestration as pending. Replace Engine comments/log messages saying FullOS arms Setup CmdLine with the current HKLM Run behavior. Keep earlier review documents as historical snapshots and point readers to this plan for the current baseline.

**Gate:** docs match the actual launch chain; public switches/results are preserved or deliberately documented; generated artifacts contain only intended runtime/tool payloads.

## Comment and naming standard

- Start each component with a short role, required inputs, returned results, execution environment, and side effects. Explain destructive-operation switches and import-only behavior.
- Comment why a surprising decision exists: WinPE compatibility, same-session double-entry prevention, credential filtering, drive-letter changes after reboot, legacy ownership checks, or an intentional driver fallback.
- At a phase boundary, state inputs, operation, success gate, and failure outcome. Do not narrate obvious assignments or add a banner to every small helper.
- Public functions get concise comment-based help with one realistic example. Private functions need a comment only when their behavior is not clear from their name/body.
- Use names describing the domain action. Keep established public names; avoid duplicate generic names such as Write-ComponentLog where imports can collide.
- Avoid historical narratives, commented-out code, stale promises, and fixed line-count targets. A TODO identifies concrete missing behavior and links to the issue/TODO document when available.

Example of a useful comment:

```powershell
# Persist the restart marker before requesting reboot. The next Administrator
# logon must resume through Run without scheduling the initial restart again.
```

## Validation and definition of done

After each stage, run the existing architecture suite under Windows PowerShell 5.1 against canonical source and a fresh scratch publish. Add focused contract regressions for changed behavior; avoid tests that merely assert function names or reproduce implementation text.

Before release, run a disposable VM matrix for Setup/DISM, network/media, cancellation, missing inputs, custom LocalRootName, custom/OEM/in-box drivers, credential handoff, Administrator first entry, the one-time restart, Run resume, SYSTEM deferral, missing credentials/share outages, and legacy-owned startup cleanup. Verify logs/state before and after reboot and credential exclusions throughout.

Completion means:

- One canonical editable implementation per component; generated outputs tied to source.
- Each domain operation, validator, state projection, and path rule has a documented owner.
- Boot is the only runtime source discovery boundary; downstream paths are explicit.
- Entry points/results and deployment safety gates are preserved or changes are documented.
- Orchestrators show phase order without embedded domain implementations.
- Comments explain constraints and match current behavior.
- Source/published 5.1 checks pass and VM validation confirms supported behavior.

Automatic FullOS package sequencing, a new SYSTEM execution model, replacing IPC transport, merging Bun experiments, and new UI features are separate feature work. They are not prerequisites for completing this cleanup.
