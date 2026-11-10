@echo off
set "LD_ROOT=%SystemDrive%\~LiteDeploy"
set "LD_OS_ENGINE=%LD_ROOT%\Engine\Runtime\LiteDeploy.OS.Engine.ps1"
set "LD_PE_ENGINE=%LD_ROOT%\Engine\Runtime\LiteDeploy.PE.Engine.ps1"
set "LD_LOG=%LD_ROOT%\WorkLogs\SetupComplete.log"

if not exist "%LD_ROOT%\WorkLogs" mkdir "%LD_ROOT%\WorkLogs" >nul 2>&1

echo [%DATE% %TIME%] SetupComplete starting >> "%LD_LOG%"

set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PWSH%" set "PWSH=powershell.exe"

if exist "%LD_OS_ENGINE%" goto :RUN_OS_ENGINE
if exist "%LD_PE_ENGINE%" goto :RUN_PE_ENGINE

echo [%DATE% %TIME%] ERROR: missing %LD_OS_ENGINE% and %LD_PE_ENGINE% >> "%LD_LOG%"
exit /b 1

:RUN_OS_ENGINE
echo [%DATE% %TIME%] Launching OS engine: %LD_OS_ENGINE% >> "%LD_LOG%"
"%PWSH%" -NoProfile -STA -ExecutionPolicy Bypass -File "%LD_OS_ENGINE%" -LocalRootName "~LiteDeploy" -OsDriveLetter "%SystemDrive%" >> "%LD_LOG%" 2>&1
set "RC=%ERRORLEVEL%"
echo [%DATE% %TIME%] SetupComplete finished OS engine rc=%RC% >> "%LD_LOG%"
exit /b %RC%

:RUN_PE_ENGINE
echo [%DATE% %TIME%] Launching PE Engine fallback: %LD_PE_ENGINE% >> "%LD_LOG%"
"%PWSH%" -NoProfile -STA -ExecutionPolicy Bypass -File "%LD_PE_ENGINE%" -ResumeFullOS -LocalRootName "~LiteDeploy" -OsDriveLetter "%SystemDrive%" >> "%LD_LOG%" 2>&1
set "RC=%ERRORLEVEL%"
echo [%DATE% %TIME%] SetupComplete finished PE Engine rc=%RC% >> "%LD_LOG%"
exit /b %RC%
