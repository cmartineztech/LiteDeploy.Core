@echo off
REM ==============================================================================
REM LiteDeploy v2.0.0 - WinPE Bootstrap Entry Point
REM File: Windows\System32\startnet.cmd inside boot.wim
REM ==============================================================================

REM Resolve Boot script location on WinPE RAM disk (X:)
set "BOOT_SCRIPT=X:\~LiteDeploy\Engine\Runtime\LiteDeploy.PE.Boot.ps1"
if not exist "%BOOT_SCRIPT%" set "BOOT_SCRIPT=X:\~LiteDeploy\Boot\LiteDeploy.PE.Boot.ps1"

echo [LiteDeploy] Starting LiteDeploy WinPE Boot Engine...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -NoExit -File "%BOOT_SCRIPT%"
