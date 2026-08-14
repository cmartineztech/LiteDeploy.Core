# Deployment Engine

WinPE orchestration entry point invoked by BootInitializer after the deployment source is mapped.

**Script:** `LiteDeploy.DeploymentEngine.ps1`  
**Plan:** [LITEDEPLOY_DEPLOYMENT_PLAN.md](../../docs/architecture/LITEDEPLOY_DEPLOYMENT_PLAN.md) Phase A–C  
**Status:** Test-branch scaffold — Phase A orchestration only

## Role

```text
BootInitializer
    → LiteDeploy.DeploymentEngine.ps1 -BootObject $bootObj
        → LiteDeploy.PreCheck.ps1          (structured result)
        → LiteDeploy.SelectWorkFlow.ps1    (structured selection)
        → Initialize DeploymentSelection.json + DeploymentState.json
        → (not yet) Setup /NoReboot, WinPECT handoff, controlled reboot
```

PreCheck and SelectWorkflow **return** to the engine. They do not launch each other.

## Parameters

| Parameter | Purpose |
| --- | --- |
| `-BootObject` | In-memory boot payload from BootInitializer (includes share `PSCredential`). |
| `-Resume` | Planned FullOS resume; returns `NotImplemented` on this branch. |
| `-StatePath` | Planned path for resume state. |

## Production layout

Promote as a sibling under the share:

```text
Engine\Scripts\
  LiteDeploy.BootInitilizer.ps1
  LiteDeploy.DeploymentEngine.ps1
  LiteDeploy.PreCheck.ps1
  LiteDeploy.SelectWorkFlow.ps1
  LiteDeploy.Progress.ps1
```

## Safety

- Credentials stay on `BootObject` in the parent process; never written to state JSON.
- This stub does **not** wipe disks, run Setup, or reboot.
- Cancelled PreCheck or SelectWorkflow stops the engine with no destructive work.
