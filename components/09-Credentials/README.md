# Credentials

LiteDeploy does not keep credential-handling code in this repository. Those components were built separately and are used at this stage of the pipeline: after workflow selection, during WinPE handoff, and again under SYSTEM in FullOS.

| Role | Repository | What it does |
| --- | --- | --- |
| Server vault | [DeployVault](https://github.com/cmartinezone/DeployVault) | Encrypted credential store on the deployment share. LiteDeploy resolves only the IDs declared by the selected workflow. |
| Cross-reboot transfer | [WinPECT](https://github.com/cmartinezone/WinPECT) | Hardware-bound transfer of in-memory `PSCredential` objects from WinPE onto the installed OS, then SYSTEM DPAPI import. |

Vault files (`localvault.bin`, `localseed.bin`) stay on the share. They are never copied into this repo or onto the target OS.

Integration rules for the LiteDeploy engine are in [EndToEndDeploymentGuide.md](EndToEndDeploymentGuide.md) and [the deployment plan](../../docs/architecture/LITEDEPLOY_DEPLOYMENT_PLAN.md).
