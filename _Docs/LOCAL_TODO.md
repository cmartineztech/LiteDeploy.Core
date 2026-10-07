# Local todo

Working list. Not part of the product docs.

## Done

- [x] Revise and clean up `010-BootInitializer`.
- [x] Promote `LiteDeploy.BootInitializer.Draft.ps1` to `LiteDeploy.BootInitializer.ps1`.
- [x] Commit that promotion on `dev` (`b6dccbf`).

## Next component

Use the `BootObject` that BootInitializer already passes. Do not guess the deployment mode, drive letter, config, credential, or share path. Read them from the object:

- `DeploymentType`
- `DriveLetter`
- `Config` and `ConfigPath`
- `LocalRootName`
- `Credential`
- `NetworkPath`

The next component to do this in is `020-DeploymentEngine`. It still searches several folders for sibling scripts and for the remote log directory.

## Review, refactor, and clean up

Review each remaining component against the BootInitializer cleanup: one script, current paths, no leftover names, and BootObject properties instead of rediscovering boot facts.

- [ ] `000-LogWriter`
- [x] `000-Hardware`
- [ ] `000-HostShell`
- [ ] `000-Progress`
- [ ] `020-DeploymentEngine`
- [x] `030-HardwarePreCheck`
- [ ] `040-WorkflowSelection` — enrich confirm return: last `BootConfig` + structured `Drivers` metadata
- [ ] `050-DiskPreparation`
- [ ] `080-OSInstallation`

Reserved / remaining:

- [x] `060-DriverStaging` — LocalCatalog detection + online helpers (extract/inject/download still TODO)
- [ ] `070-AnswerFileGenerator`
- [ ] `090-CredentialTransfer`
- [ ] `100-DeploymentCleanup`
