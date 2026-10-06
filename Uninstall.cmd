@echo off
rem PowerShell 7 module path must not leak into Windows PowerShell 5.1
set "PSModulePath="
rem home-vpn-kit: remove the VPN tasks, scripts and the tray indicator. Asks for administrator rights once.
set "HVK_DIR=%~dp0"
set "HVK_ARGS=%*"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$d = $env:HVK_DIR.TrimEnd('\'); $a = '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"' + $d + '\uninstall.ps1\" ' + $env:HVK_ARGS; try { Start-Process powershell.exe -Verb RunAs -ArgumentList $a -ErrorAction Stop } catch { Write-Host 'Administrator rights are required - cancelled.' -ForegroundColor Red; pause }"
