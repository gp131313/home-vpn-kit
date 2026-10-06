# Disconnect-Vpn.ps1 - manual VPN off switch (task "VPN Disconnect", tray menu "Disconnect VPN").
# Sets the DISABLED flag (the watchdog then does nothing) and stops openconnect.
# Runs with highest privileges: openconnect is elevated, a normal process cannot stop it.

$dir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $dir 'watchdog.log'
$flag    = Join-Path $dir 'DISABLED'

function Write-Log([string]$Message) {
    Add-Content -Path $logFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Message) -Encoding UTF8
}

Set-Content -Path $flag -Value ('Disabled at ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding ASCII
Write-Log 'Manual DISCONNECT: watchdog paused (DISABLED flag set)'
Get-Process -Name 'openconnect' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Log ('Stopping openconnect PID ' + $_.Id)
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
