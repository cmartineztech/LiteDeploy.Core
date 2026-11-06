@echo off
set "LD_ROOT=%SystemDrive%\~LiteDeploy"
set "LD_FULLOS=%LD_ROOT%\Engine\Scripts\Runtime\LiteDeploy.FullOS.ps1"
set "LD_ENGINE=%LD_ROOT%\Engine\Scripts\Runtime\LiteDeploy.Engine.ps1"
set "LD_LOG=%LD_ROOT%\WorkLogs\SetupComplete.log"

if not exist "%LD_ROOT%\WorkLogs" mkdir "%LD_ROOT%\WorkLogs" >nul 2>&1

echo [%DATE% %TIME%] SetupComplete starting >> "%LD_LOG%"

set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PWSH%" set "PWSH=powershell.exe"

if exist "%LD_FULLOS%" goto :RUN_FULLOS
if exist "%LD_ENGINE%" goto :RUN_ENGINE

echo [%DATE% %TIME%] ERROR: missing %LD_FULLOS% and %LD_ENGINE% >> "%LD_LOG%"
exit /b 1

:RUN_FULLOS
echo [%DATE% %TIME%] Launching FullOS engine: %LD_FULLOS% >> "%LD_LOG%"
"%PWSH%" -NoProfile -STA -ExecutionPolicy Bypass -File "%LD_FULLOS%" -LocalRootName "~LiteDeploy" -OsDriveLetter "%SystemDrive%" >> "%LD_LOG%" 2>&1
set "RC=%ERRORLEVEL%"
echo [%DATE% %TIME%] SetupComplete finished FullOS rc=%RC% >> "%LD_LOG%"
exit /b %RC%

:RUN_ENGINE
echo [%DATE% %TIME%] Launching Engine fallback: %LD_ENGINE% >> "%LD_LOG%"
"%PWSH%" -NoProfile -STA -ExecutionPolicy Bypass -File "%LD_ENGINE%" -ResumeFullOS -LocalRootName "~LiteDeploy" -OsDriveLetter "%SystemDrive%" >> "%LD_LOG%" 2>&1
set "RC=%ERRORLEVEL%"
echo [%DATE% %TIME%] SetupComplete finished Engine compat rc=%RC% >> "%LD_LOG%"
exit /b %RC%
