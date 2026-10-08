# Connect-Vpn.ps1 - home-vpn-kit watchdog (runs from the scheduled task "VPN Watchdog (OpenConnect)"
# every 2 minutes while the user is logged on, with highest privileges).
#
# What it does, in order:
#   1. file DISABLED next to this script  -> do nothing (manual "Disconnect VPN")
#   2. connected to a home network        -> stop the tunnel if it runs, do nothing else
#   3. OpenConnect-GUI is running          -> do nothing (the user drives the GUI)
#   4. tunnel is healthy                   -> do nothing
#   5. server name does not resolve        -> no internet, do nothing
#   6. otherwise start openconnect and stay attached while it runs; stop it if the
#      tunnel stays broken for GraceMinutes, if DISABLED appears or if we get home.
# Settings: config.json next to this script. Password: cred.dat (DPAPI, this user only).
# Windows PowerShell 5.1 compatible, ASCII only.

$ErrorActionPreference = 'Continue'
$dir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgFile = Join-Path $dir 'config.json'
$credFil = Join-Path $dir 'cred.dat'
$caFile  = Join-Path $dir 'ca-bundle.pem'
$logFile = Join-Path $dir 'watchdog.log'
$flag    = Join-Path $dir 'DISABLED'
$state   = Join-Path $dir 'watchdog.state'

function Write-Log([string]$Message) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Message
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

# log a message only when it differs from the previous "quiet" state (avoid a line every 2 minutes)
function Write-StateLog([string]$Key, [string]$Message) {
    $prev = ''
    if (Test-Path $state) { $prev = (Get-Content $state -Raw -ErrorAction SilentlyContinue) }
    if ($prev -ne $Key) {
        Write-Log $Message
        Set-Content -Path $state -Value $Key -Encoding ASCII -NoNewline
    }
}
function Clear-StateLog { Remove-Item $state -Force -ErrorAction SilentlyContinue }

# --- log rotation (keep ~1 MB) ------------------------------------------
if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 1MB)) {
    Move-Item $logFile ($logFile + '.1') -Force -ErrorAction SilentlyContinue
}

# --- config -------------------------------------------------------------
if (-not (Test-Path $cfgFile)) { Write-Log 'ABORT: config.json missing - run Install.cmd'; exit 1 }
$cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
$Server    = [string]$cfg.Server
$VpnUser   = [string]$cfg.User
$Probe     = [string]$cfg.ProbeHost
$ProbePort = [int]$cfg.ProbePort
$Grace     = [int]$cfg.GraceMinutes; if ($Grace -le 0) { $Grace = 6 }
$HomeNets  = @($cfg.HomeNetworks | Where-Object { $_ })
$OcDir     = [string]$cfg.OpenConnectDir; if (-not $OcDir) { $OcDir = 'C:\Program Files\OpenConnect-GUI' }
$Exe       = Join-Path $OcDir 'openconnect.exe'
$Script    = Join-Path $OcDir 'vpnc-script-win.js'

# --- checks -------------------------------------------------------------
function Test-Probe {
    if ($ProbePort -le 0) {
        $p = New-Object System.Net.NetworkInformation.Ping
        try { return ($p.Send($Probe, 1500).Status -eq 'Success') } catch { return $false }
    }
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($Probe, $ProbePort, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(2000)) { return $false }
        $c.EndConnect($ar); return $true
    } catch { return $false } finally { $c.Close() }
}

function Test-TunnelAdapter {
    $ad = @(Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceDescription -match 'OpenConnect' -and $_.Status -eq 'Up' })
    return ($ad.Count -gt 0)
}

function Test-Tunnel { return ((Test-TunnelAdapter) -and (Test-Probe)) }

# name of the home network we are on, or '' (the tunnel's own profile is ignored)
function Get-HomeNetwork {
    if ($HomeNets.Count -eq 0) { return '' }
    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
    foreach ($p in $profiles) {
        if ($p.InterfaceAlias -match 'OpenConnect') { continue }
        $ad = Get-NetAdapter -InterfaceIndex $p.InterfaceIndex -ErrorAction SilentlyContinue
        if ($ad -and $ad.InterfaceDescription -match 'OpenConnect') { continue }
        if ($HomeNets -contains $p.Name) { return [string]$p.Name }
    }
    return ''
}

function Stop-OpenConnect([string]$Why) {
    $procs = @(Get-Process -Name 'openconnect' -ErrorAction SilentlyContinue)
    foreach ($pr in $procs) {
        Write-Log ('Stopping openconnect PID ' + $pr.Id + ' (' + $Why + ')')
        Stop-Process -Id $pr.Id -Force -ErrorAction SilentlyContinue
    }
    return $procs.Count
}

# --- preflight ----------------------------------------------------------
$id  = [Security.Principal.WindowsIdentity]::GetCurrent()
$adm = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $adm)                  { Write-StateLog 'noadmin' 'ABORT: not elevated - openconnect cannot create the tunnel'; exit 1 }
if (-not (Test-Path $Exe))      { Write-StateLog 'noexe'   ('ABORT: openconnect.exe not found at ' + $Exe); exit 1 }
if (-not (Test-Path $credFil))  { Write-StateLog 'nocred'  'ABORT: cred.dat missing - run Install.cmd'; exit 1 }
# no ca-bundle.pem: the installer checked that openconnect trusts the server via the Windows store
$caArg = $(if (Test-Path $caFile) { ' --cafile="' + $caFile + '"' } else { '' })

# --- 1-5: reasons to do nothing -----------------------------------------
if (Test-Path $flag) { Write-StateLog 'disabled' 'Paused: DISABLED flag is set (manual Disconnect)'; exit 0 }

$homeNet = Get-HomeNetwork
if ($homeNet) {
    $n = Stop-OpenConnect ('home network ' + $homeNet)
    Write-StateLog ('home:' + $homeNet) ('At home (' + $homeNet + '): tunnel not needed')
    exit 0
}

if (Get-Process -Name 'openconnect-gui' -ErrorAction SilentlyContinue) {
    Write-StateLog 'gui' 'OpenConnect-GUI is running - leaving the tunnel to it'
    exit 0
}

if (Test-Tunnel) { Clear-StateLog; exit 0 }

try { [void][Net.Dns]::GetHostAddresses($Server) } catch {
    Write-StateLog 'nodns' ('No internet: cannot resolve ' + $Server + ' - waiting')
    exit 0
}

Clear-StateLog
Write-Log 'Tunnel DOWN - reconnecting'
[void](Stop-OpenConnect 'stale process')
Start-Sleep -Seconds 2

# --- 6: start openconnect -----------------------------------------------
$secure = Get-Content -Path $credFil | ConvertTo-SecureString
$bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
$plain  = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName  = $Exe
$psi.Arguments = '--protocol=anyconnect --user="' + $VpnUser + '" --passwd-on-stdin --non-inter' +
                 ' --reconnect-timeout=300' + $caArg + ' --script="' + $Script + '" ' + $Server
$psi.UseShellExecute        = $false
$psi.RedirectStandardInput  = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.CreateNoWindow         = $true

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
$sink = {
    if ($EventArgs.Data) {
        Add-Content -Path $Event.MessageData -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  oc| ' + $EventArgs.Data) -Encoding UTF8
    }
}
Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $sink -MessageData $logFile | Out-Null
Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived  -Action $sink -MessageData $logFile | Out-Null

[void]$proc.Start()
$proc.BeginOutputReadLine()
$proc.BeginErrorReadLine()
$proc.StandardInput.WriteLine($plain)
$proc.StandardInput.Close()
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
$plain = $null
Write-Log ('openconnect started, PID ' + $proc.Id)

$up = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 3
    if (Test-Tunnel) { $up = $true; break }
    if ($proc.HasExited) { break }
}
if ($up) { Write-Log 'Tunnel UP' } else { Write-Log 'Tunnel did NOT come up within 60s' }

# --- stay attached: one openconnect at a time, stop it when it is useless ---
$downSince = $null
while (-not $proc.HasExited) {
    Start-Sleep -Seconds 15
    if ($proc.HasExited) { break }
    if (Test-Path $flag) { [void](Stop-OpenConnect 'DISABLED flag'); break }
    $h = Get-HomeNetwork
    if ($h) { [void](Stop-OpenConnect ('home network ' + $h)); break }
    if (Test-Tunnel) { $downSince = $null; continue }
    if (-not $downSince) { $downSince = Get-Date; Write-Log 'Tunnel not answering - waiting' ; continue }
    if (((Get-Date) - $downSince).TotalMinutes -ge $Grace) {
        [void](Stop-OpenConnect ('no traffic for ' + $Grace + ' min'))
        break
    }
}
Start-Sleep -Seconds 1
if ($proc.HasExited) { Write-Log ('openconnect exited, code ' + $proc.ExitCode) }
