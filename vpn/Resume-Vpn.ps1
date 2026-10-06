# Resume-Vpn.ps1 - manual VPN on switch (task "VPN Connect", tray menu "Connect VPN").
# Removes the DISABLED flag and starts the watchdog task right away.

$dir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile  = Join-Path $dir 'watchdog.log'
$flag     = Join-Path $dir 'DISABLED'
$watchdog = 'VPN Watchdog (OpenConnect)'

function Write-Log([string]$Message) {
    Add-Content -Path $logFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Message) -Encoding UTF8
}

Remove-Item -Path $flag -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $dir 'watchdog.state') -Force -ErrorAction SilentlyContinue
Write-Log 'Manual CONNECT: watchdog resumed (DISABLED flag removed)'
try { Start-ScheduledTask -TaskName $watchdog -ErrorAction Stop }
catch { Write-Log ('Could not start task ' + $watchdog + ': ' + $_.Exception.Message + ' - it will run on its next trigger') }
