 . "$PSScriptRoot\LiteDeploy-HostShell.ps1"
 Set-HostShellWindow -Action Minimize
# Initialize WinPE networking, Plug and Play, and unattended settings.
wpeinit.exe

# Activate the High performance power plan.
powercfg.exe /setactive '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

#Run PreCheck script in a new PowerShell process to avoid issues with the current session.
Start-Process -FilePath "powershell.exe" -ArgumentList "-NoExit -NoLogo -ExecutionPolicy Bypass -File `"$PSScriptRoot\LiteDeploy-PreCheck.ps1`"" -WindowStyle Hidden