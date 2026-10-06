@echo off
rem PowerShell 7 module path must not leak into Windows PowerShell 5.1
set "PSModulePath="
rem home-vpn-kit: double-click to install or update. Asks for administrator rights once.
rem Extra arguments go to install.ps1, for example:  Install.cmd -Check
set "HVK_DIR=%~dp0"
set "HVK_USER=%USERDOMAIN%\%USERNAME%"
set "HVK_ARGS=%*"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$d = $env:HVK_DIR.TrimEnd('\'); $a = '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"' + $d + '\install.ps1\" -ForUser \"' + $env:HVK_USER + '\" -SourceDir \"' + $d + '\" ' + $env:HVK_ARGS; try { Start-Process powershell.exe -Verb RunAs -ArgumentList $a -ErrorAction Stop } catch { Write-Host 'Administrator rights are required - cancelled.' -ForegroundColor Red; pause }"
