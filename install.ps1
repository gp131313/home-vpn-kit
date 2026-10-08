# install.ps1 - home-vpn-kit installer. Start it with Install.cmd (it asks for administrator rights once).
# Idempotent: run it again to update, to change settings or to re-enter the password.
#
#   Install.cmd                                  - interactive
#   Install.cmd -Check                           - only show what is installed and what would change
#   Install.cmd -ResetPassword                   - ask for the VPN password again
#   Install.cmd -InstallDir D:\vpn               - install the VPN scripts somewhere else
#   Install.cmd -SkipTray                        - without the tray indicator
#
# HomeVpnKit-Setup.exe (setup\Setup.cs) runs this script too, without questions:
#   -NoPrompt       take the settings from the parameters / config.json, never ask
#   -PasswordStdin  read the VPN password as one line from stdin (never on the command line)
#   -HomeNetworks   may be one comma-separated string; a lone comma means "no home networks"
#
# Windows PowerShell 5.1 compatible. Saved as UTF-8 with BOM (Russian text).

[CmdletBinding()]
param(
    [string]$ForUser,
    [string]$SourceDir,
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'HomeVpnKit'),
    [string]$Server,
    [string]$User,
    [string]$ProbeHost,
    [int]$ProbePort = -1,
    [string[]]$HomeNetworks,
    [switch]$ResetPassword,
    [switch]$SkipTray,
    [switch]$Check,
    [switch]$NoPrompt,
    [switch]$PasswordStdin
)

# Started from PowerShell 7 (Install.cmd from a pwsh window, irm | iex in pwsh), Windows PowerShell 5.1
# inherits the PS7 module path and cannot autoload its own modules
# (ConvertFrom-SecureString: CouldNotAutoloadMatchingModule). Rebuild the 5.1 path before anything else.
if ($PSVersionTable.PSEdition -ne 'Core') {
    $env:PSModulePath = (@(
        [IO.Path]::Combine([Environment]::GetFolderPath('MyDocuments'), 'WindowsPowerShell\Modules'),
        [IO.Path]::Combine($env:ProgramFiles, 'WindowsPowerShell\Modules'),
        [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
    ) | Where-Object { $_ }) -join ';'
}
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
# for the exe installer: one clean error line on stderr instead of PowerShell's trace; in a console - as before
trap { if ($NoPrompt) { [Console]::Error.WriteLine($_.Exception.Message); exit 1 } else { break } }
if (-not $SourceDir) { $SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
# the exe installer reads our output through a pipe: make it UTF-8 so the Russian text survives
if ($NoPrompt) { try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { } }
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$KitVersion   = '1.1.0'
$AppsKey      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\HomeVpnKit'
$AppsName     = 'Home VPN Kit'
$TaskWatchdog = 'VPN Watchdog (OpenConnect)'
$TaskOff      = 'VPN Disconnect'
$TaskOn       = 'VPN Connect'
$LegacyTasks  = @('VPN-CLI-Watchdog', 'OpenConnect-Watchdog', 'OpenConnect-AutoConnect')

# OpenConnect-GUI 1.6.2 (ships openconnect.exe 9.12, vpnc-script-win.js, wintun.dll).
# SHA256 computed 30.09.2026; SHA512 matches the Chocolatey package openconnect-gui 1.6.2.
$OcUrl    = 'https://www.infradead.org/openconnect-gui/download/openconnect-gui-1.6.2-win64.exe'
$OcSha256 = 'de08d8968e40e219932d01025521f879178ec99246802db488c0fdac9fcef11a'
$OcDir    = Join-Path $env:ProgramFiles 'OpenConnect-GUI'

$TrayRepo = 'gp131313/TrayPingMonitor-VPN'
$TrayDir  = Join-Path $env:LOCALAPPDATA 'Programs\TrayPingMonitor'
$TrayExe  = Join-Path $TrayDir 'TrayPingMonitor.exe'
$TrayCfg  = Join-Path $env:APPDATA 'TrayPingMonitor\settings.json'
$TrayTask = 'TrayPingMonitor keepalive'

$DownDir  = Join-Path $env:LOCALAPPDATA 'HomeVpnKit\download'

# ---------------------------------------------------------------- helpers
function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Step([string]$t) { Write-Host ''; Write-Host ('== ' + $t) -ForegroundColor Cyan }
function Ok([string]$t)   { Say ('   ok: ' + $t) 'Green' }
function Plan([string]$t) { Say ('   ' + ($(if ($Check) { 'будет: ' } else { '' })) + $t) 'Yellow' }
function Fail([string]$t) { throw $t }

function Get-Download([string]$Url, [string]$Name) {
    New-Item -ItemType Directory -Force $DownDir | Out-Null
    $out = Join-Path $DownDir $Name
    foreach ($try in 1..3) {
        try { Invoke-WebRequest $Url -OutFile $out -UseBasicParsing -TimeoutSec 600; return $out }
        catch { Say ('   повтор загрузки (' + $try + '): ' + $_.Exception.Message) 'DarkYellow'; Start-Sleep 3 }
    }
    Fail ('не удалось скачать ' + $Url)
}

function Test-Hash([string]$File, [string]$Expected, [string]$Algo = 'SHA256') {
    $h = (Get-FileHash $File -Algorithm $Algo).Hash.ToLower()
    if ($h -ne $Expected.ToLower()) { Fail ('контрольная сумма не совпала: ' + (Split-Path $File -Leaf)) }
}

function Read-Value([string]$Prompt, [string]$Default) {
    $p = $Prompt; if ($Default) { $p += ' [' + $Default + ']' }
    $v = Read-Host $p
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}

function Test-Cred([string]$File) {
    try { $s = Get-Content $File -ErrorAction Stop | ConvertTo-SecureString; return ($s.Length -gt 0) } catch { return $false }
}

function Test-DesktopRuntime10 {
    $d = Join-Path $env:ProgramFiles 'dotnet\shared\Microsoft.WindowsDesktop.App'
    if (-not (Test-Path $d)) { return $false }
    return [bool](@(Get-ChildItem $d -Directory | Where-Object { $_.Name -match '^10\.' }).Count)
}

# keeps the three newest copies: <file>.bak_yyyyMMdd_HHmmss
function Backup-File([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    Copy-Item $Path ($Path + '.bak_' + $Stamp) -Force
    Get-ChildItem ($Path + '.bak_*') -ErrorAction SilentlyContinue | Sort-Object Name -Descending |
        Select-Object -Skip 3 | Remove-Item -Force -ErrorAction SilentlyContinue
}

# Asks openconnect itself whether it accepts the server certificate. --authenticate --non-inter stops at the
# username prompt: no login is sent. With $CaFile - only that file is trusted (--no-system-trust), without it -
# the Windows store. Returns State ok (TLS accepted), cert (certificate rejected) or net (could not tell).
function Test-OcTrust([string]$Exe, [string]$Srv, [string]$CaFile) {
    New-Item -ItemType Directory -Force $DownDir | Out-Null
    $o = Join-Path $DownDir 'oc-test.out'; $e = Join-Path $DownDir 'oc-test.err'
    $a = '--protocol=anyconnect --authenticate --non-inter'
    if ($CaFile) { $a += ' --no-system-trust --cafile="' + $CaFile + '"' }
    $a += ' ' + $Srv
    $p = Start-Process $Exe -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
    if (-not $p.WaitForExit(30000)) { try { $p.Kill() } catch { } }
    $txt = (@(Get-Content $o, $e -ErrorAction SilentlyContinue) -join "`n")
    Remove-Item $o, $e -Force -ErrorAction SilentlyContinue
    if ($txt -match 'Connected to HTTPS on') { return @{ State = 'ok'; Detail = '' } }
    if ($txt -match 'verify failed|failed verification|--servercert') {
        $m = [regex]::Match($txt, 'Reason: ([^\r\n]+)')
        return @{ State = 'cert'; Detail = $(if ($m.Success) { $m.Groups[1].Value.Trim() } else { 'certificate rejected' }) }
    }
    $last = @($txt -split "`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1
    return @{ State = 'net'; Detail = $(if ($last) { [string]$last } else { 'no output' }) }
}

# ---------------------------------------------------------------- start
Say ('home-vpn-kit ' + $KitVersion + $(if ($Check) { '  (режим проверки, ничего не меняется)' } else { '' })) 'White'

$me  = [Security.Principal.WindowsIdentity]::GetCurrent()
$adm = (New-Object Security.Principal.WindowsPrincipal($me)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $adm -and -not $Check) { Fail 'нужны права администратора - запустите Install.cmd' }
if ($ForUser -and (($ForUser.Split('\')[-1]) -ne ($me.Name.Split('\')[-1]))) {
    Fail ('установщик запущен из учётки ' + $ForUser + ', а права администратора получены от ' + $me.Name +
          '. Пароль VPN и индикатор привязываются к учётке, поэтому войдите в Windows под учёткой-администратором, ' +
          'для которой ставите VPN, и запустите Install.cmd ещё раз.')
}
Say ('учётка: ' + $me.Name + ', компьютер: ' + $env:COMPUTERNAME)

# ---------------------------------------------------------------- settings
Step 'Настройки'
$cfgNew = Join-Path $InstallDir 'config.json'
$cfg = $null
foreach ($f in @($cfgNew, (Join-Path $SourceDir 'config.json'))) {
    if (-not $cfg -and (Test-Path $f)) { $cfg = Get-Content $f -Raw | ConvertFrom-Json; Say ('   взяты из ' + $f) }
}
if (-not $cfg) { $cfg = New-Object psobject }
function CfgGet([string]$n, $def) { if ($cfg.PSObject.Properties[$n] -and $cfg.$n) { return $cfg.$n } return $def }

$ask = -not $Check -and -not $NoPrompt
$Server    = $(if ($Server)    { $Server }    else { CfgGet 'Server' '' })
$User      = $(if ($User)      { $User }      else { CfgGet 'User' '' })
$ProbeHost = $(if ($ProbeHost) { $ProbeHost } else { CfgGet 'ProbeHost' '192.168.1.1' })
if ($ProbePort -lt 0) { $ProbePort = [int](CfgGet 'ProbePort' 443) }
if (-not $HomeNetworks) { $HomeNetworks = @(CfgGet 'HomeNetworks' @()) }
# "-HomeNetworks a,b" from the exe installer arrives as one string
$HomeNetworks = @($HomeNetworks | ForEach-Object { [string]$_ -split '\s*,\s*' } | Where-Object { $_ })

if ($ask) {
    $Server = Read-Value 'Адрес VPN-сервера (например vpn.example.com)' $Server
    $User   = Read-Value 'Логин VPN' $User
    $ProbeHost = Read-Value 'Адрес в домашней сети для проверки (обычно роутер)' $ProbeHost
    $nets = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch 'OpenConnect' } | ForEach-Object { $_.Name })
    if ($nets.Count) { Say ('   сейчас подключены сети: ' + ($nets -join ', ')) }
    $hn = Read-Value 'Домашние сети, где VPN не нужен (через запятую, пусто - нет)' ($HomeNetworks -join ', ')
    $HomeNetworks = @($(if ($hn) { $hn -split '\s*,\s*' | Where-Object { $_ } } else { @() }))
}
if (-not $Server -or -not $User) { if ($Check) { Say '   сервер/логин ещё не заданы' 'Yellow' } else { Fail 'не заданы сервер или логин' } }
Say ('   сервер: ' + $Server + ', логин: ' + $User + ', проверка: ' + $ProbeHost + ':' + $ProbePort + ', дома: ' + ($HomeNetworks -join ', '))

# ---------------------------------------------------------------- OpenConnect
Step 'OpenConnect'
if ((Test-Path (Join-Path $OcDir 'openconnect.exe')) -and (Test-Path (Join-Path $OcDir 'vpnc-script-win.js'))) {
    Ok ('уже установлен: ' + $OcDir)
} else {
    Plan 'скачать и установить OpenConnect-GUI 1.6.2 (с openconnect.exe 9.12)'
    if (-not $Check) {
        $f = Get-Download $OcUrl 'openconnect-gui-1.6.2-win64.exe'
        Test-Hash $f $OcSha256
        $sig = Get-AuthenticodeSignature $f
        Say ('   подпись: ' + $sig.Status + ' ' + $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }))
        $p = Start-Process $f -ArgumentList '/S' -Wait -PassThru
        if ($p.ExitCode -ne 0) { Fail ('установщик OpenConnect-GUI вернул ' + $p.ExitCode) }
        Start-Sleep 2
        Get-Process openconnect-gui -ErrorAction SilentlyContinue | Stop-Process -Force
        if (-not (Test-Path (Join-Path $OcDir 'openconnect.exe'))) { Fail ('после установки нет ' + $OcDir + '\openconnect.exe') }
        Ok 'установлен'
    }
}

# ---------------------------------------------------------------- scripts
Step ('Скрипты VPN -> ' + $InstallDir)
$oldDir = $null
foreach ($tn in @($TaskWatchdog) + $LegacyTasks) {
    $oldTask = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    if (-not $oldTask) { continue }
    $m = [regex]::Match(($oldTask.Actions[0].Arguments + ''), '-File\s+"?([^"]+\.ps1)')
    if (-not $m.Success) { continue }
    $d = Split-Path -Parent $m.Groups[1].Value
    if (-not $oldDir) { $oldDir = $d }
    if (Test-Path (Join-Path $d 'cred.dat')) { $oldDir = $d; break }
}
if ($oldDir) { Say ('   найдена прежняя установка: ' + $oldDir) }
Plan 'скопировать Connect-Vpn.ps1, Disconnect-Vpn.ps1, Resume-Vpn.ps1, записать config.json'
# the zip keeps the scripts in vpn\, the exe installer unpacks everything flat
$vpnSrc = $(if (Test-Path (Join-Path $SourceDir 'vpn\Connect-Vpn.ps1')) { Join-Path $SourceDir 'vpn' } else { $SourceDir })
$setupDir = Join-Path $InstallDir 'setup'
if (-not $Check) {
    New-Item -ItemType Directory -Force $InstallDir | Out-Null
    foreach ($s in 'Connect-Vpn.ps1', 'Disconnect-Vpn.ps1', 'Resume-Vpn.ps1') {
        $dst = Join-Path $InstallDir $s
        Backup-File $dst
        Copy-Item (Join-Path $vpnSrc $s) $dst -Force
    }
    # keep the uninstaller next to the scripts: "Apps" points at it
    New-Item -ItemType Directory -Force $setupDir | Out-Null
    if ([IO.Path]::GetFullPath($SourceDir).TrimEnd('\') -ne [IO.Path]::GetFullPath($setupDir).TrimEnd('\')) {
        Copy-Item (Join-Path $SourceDir 'uninstall.ps1') (Join-Path $setupDir 'uninstall.ps1') -Force
    }
    Backup-File $cfgNew
    [ordered]@{
        Server = $Server; User = $User; ProbeHost = $ProbeHost; ProbePort = $ProbePort
        HomeNetworks = @($HomeNetworks); GraceMinutes = 6; OpenConnectDir = $OcDir
    } | ConvertTo-Json | Set-Content -Path $cfgNew -Encoding UTF8
    Ok 'скрипты и config.json на месте'
}

# ---------------------------------------------------------------- password
Step 'Пароль VPN (хранится зашифрованным DPAPI, расшифровать может только эта учётка на этом компьютере)'
$cred = Join-Path $InstallDir 'cred.dat'
if (-not (Test-Path $cred) -and $oldDir -and ($oldDir -ne $InstallDir) -and (Test-Path (Join-Path $oldDir 'cred.dat')) -and (Test-Cred (Join-Path $oldDir 'cred.dat'))) {
    Plan ('перенести пароль из ' + $oldDir)
    if (-not $Check) { Copy-Item (Join-Path $oldDir 'cred.dat') $cred -Force }
}
$stdinPw = $null
if ($PasswordStdin -and -not $Check) {
    # one line from the exe installer; an empty line means "keep the saved password"
    $line = [Console]::In.ReadLine()
    if ($line) { $stdinPw = New-Object System.Security.SecureString; foreach ($ch in $line.ToCharArray()) { $stdinPw.AppendChar($ch) }; $line = $null }
}
if ($stdinPw) {
    Plan 'сохранить пароль VPN, полученный от установщика'
    ConvertFrom-SecureString -SecureString $stdinPw | Set-Content -Path $cred -Encoding ASCII
    if (-not (Test-Cred $cred)) { Fail 'не удалось проверить сохранённый пароль' }
    Ok 'пароль сохранён'
} elseif ((Test-Path $cred) -and (Test-Cred $cred) -and -not $ResetPassword) {
    Ok 'пароль уже сохранён (ввести заново: Install.cmd -ResetPassword)'
} elseif ($NoPrompt) {
    if (-not $Check) { Fail 'пароль VPN не задан и не сохранён ранее' }
} else {
    Plan 'запросить пароль VPN'
    if (-not $Check) {
        while ($true) {
            $a = Read-Host 'Пароль VPN' -AsSecureString
            $b = Read-Host 'Ещё раз'     -AsSecureString
            $pa = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($a))
            $pb = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($b))
            $same = ($pa -ceq $pb) -and $pa.Length -gt 0
            $pa = $null; $pb = $null
            if ($same) { break }
            Say '   пароли пустые или не совпали, ещё раз' 'Yellow'
        }
        ConvertFrom-SecureString -SecureString $a | Set-Content -Path $cred -Encoding ASCII
        if (-not (Test-Cred $cred)) { Fail 'не удалось проверить сохранённый пароль' }
        Ok 'пароль сохранён'
    }
}

# ---------------------------------------------------------------- CA
Step ('Сертификаты сервера ' + $Server)
Plan 'выгрузить цепочку CA в ca-bundle.pem и проверить её самим openconnect'
if (-not $Check) {
    $ca    = Join-Path $InstallDir 'ca-bundle.pem'
    $ocExe = Join-Path $OcDir 'openconnect.exe'
    $fresh = Join-Path $DownDir 'ca-fresh.pem'
    Remove-Item $fresh -Force -ErrorAction SilentlyContinue
    $winOk = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($Server, 443)
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, { param($a, $b, $c, $d) $true })
        $ssl.AuthenticateAsClient($Server)
        $leaf = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        $ssl.Dispose(); $tcp.Close()
        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $chain.ChainPolicy.RevocationMode = 'NoCheck'
        $winOk = $chain.Build($leaf)
        $sb = New-Object System.Text.StringBuilder
        foreach ($el in $chain.ChainElements) {
            $c = $el.Certificate
            if ($c.Thumbprint -eq $leaf.Thumbprint) { continue }
            [void]$sb.AppendLine('# ' + $c.Subject)
            [void]$sb.AppendLine('-----BEGIN CERTIFICATE-----')
            [void]$sb.AppendLine([Convert]::ToBase64String($c.RawData, 'InsertLineBreaks'))
            [void]$sb.AppendLine('-----END CERTIFICATE-----')
        }
        $root = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate.Subject
        Say ('   сертификат ' + $leaf.Subject + ', действует до ' + $leaf.NotAfter.ToString('dd.MM.yyyy') + '; корень цепочки: ' + $root)
        if ($sb.Length -gt 0) { New-Item -ItemType Directory -Force $DownDir | Out-Null; Set-Content -Path $fresh -Value $sb.ToString() -Encoding ASCII }
    } catch { Say ('   не удалось получить цепочку: ' + $_.Exception.Message) 'Yellow' }

    # What openconnect accepts decides, not what Windows shows: an antivirus that inspects TLS (Kaspersky and
    # others) may swap the chain for PowerShell but not for openconnect. Candidates: the chain just received,
    # a ca-bundle.pem put next to Install.cmd (e.g. from another computer), the current one.
    $cands = @(@($fresh, (Join-Path $SourceDir 'ca-bundle.pem'), $ca) | Where-Object { Test-Path $_ } | Select-Object -Unique)
    $chosen = $null; $net = $false
    foreach ($f in $cands) {
        $r = Test-OcTrust $ocExe $Server $f
        if ($r.State -eq 'ok') { $chosen = $f; break }
        if ($r.State -eq 'net') { $net = $true; Say ('   openconnect не смог проверить сервер: ' + $r.Detail) 'Yellow'; break }
        if ($f -eq $fresh) {
            Say ('   openconnect не принимает цепочку, которую получил установщик (' + $r.Detail + ')') 'Yellow'
            if ($winOk) { Say '   Windows ей доверяет, а openconnect нет: похоже, антивирус подменяет сертификаты. Такую цепочку не сохраняю.' 'Yellow' }
        } else { Say ('   не подходит ' + $f + ' (' + $r.Detail + ')') 'Yellow' }
    }
    if ($chosen) {
        if ($chosen -ne $ca) {
            if (-not (Test-Path $ca) -or ((Get-FileHash $ca).Hash -ne (Get-FileHash $chosen).Hash)) { Backup-File $ca; Copy-Item $chosen $ca -Force }
        }
        Ok ('openconnect принимает сертификат сервера (' + $(if ($chosen -eq $fresh) { 'цепочка с сервера' } elseif ($chosen -eq $ca) { 'прежний ca-bundle.pem' } else { $chosen }) + ')')
    } elseif ($net) {
        if (Test-Path $ca) { Say '   оставлен прежний ca-bundle.pem, openconnect его не проверил' 'Yellow' }
        elseif ((Test-Path $fresh) -and $winOk) { Copy-Item $fresh $ca -Force; Say '   сохранена цепочка, которую видит Windows; openconnect её не проверил' 'Yellow' }
        else { Fail ('нет цепочки сертификатов для ' + $Server + ', и openconnect не может его проверить') }
    } else {
        $r = Test-OcTrust $ocExe $Server $null
        if ($r.State -eq 'ok') {
            Backup-File $ca; Remove-Item $ca -Force -ErrorAction SilentlyContinue
            Ok 'openconnect доверяет серверу по хранилищу Windows - ca-bundle.pem не нужен'
        } else {
            Fail ('openconnect не доверяет сертификату ' + $Server + ' (' + $r.Detail + '). Если стоит антивирус с проверкой ' +
                  'защищённых соединений: возьмите ca-bundle.pem из папки установки на компьютере, где VPN работает, ' +
                  'положите рядом с Install.cmd и запустите установщик ещё раз.')
        }
    }
    Remove-Item $fresh -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- ACL
Step 'Защита папки'
Plan 'запись в папку - только администраторам: скрипты выполняются с повышенными правами'
if (-not $Check) {
    $sidAdm = '*S-1-5-32-544'; $sidSys = '*S-1-5-18'; $sidUsr = '*S-1-5-32-545'
    function Icacls([string[]]$a) { & icacls.exe @a | Out-Null; if ($LASTEXITCODE -ne 0) { Fail ('icacls ' + ($a -join ' ')) } }
    Icacls @($InstallDir, '/inheritance:r')
    Icacls @($InstallDir, '/grant:r', ($sidAdm + ':(OI)(CI)F'), ($sidSys + ':(OI)(CI)F'), ($sidUsr + ':(OI)(CI)RX'))
    & icacls.exe $InstallDir /remove:g '*S-1-5-11' | Out-Null
    Icacls @((Join-Path $InstallDir '*'), '/reset', '/T', '/C')
    Icacls @($InstallDir, '/setowner', $sidAdm, '/T', '/C')
    Icacls @($cred, '/inheritance:r')
    Icacls @($cred, '/grant:r', ($sidAdm + ':F'), ($sidSys + ':F'), ('*' + $me.User.Value + ':R'))
    # a folder owned by the user lets him re-grant himself "delete subfolders" and swap ours
    $parent = Split-Path -Parent $InstallDir
    if ((Get-Acl $parent).Owner -eq $me.Name) { Icacls @($parent, '/setowner', $sidAdm); Say ('   владелец ' + $parent + ' -> Администраторы') }
    Ok 'запись - только Администраторы и SYSTEM'
}

# ---------------------------------------------------------------- tasks
Step 'Задачи Планировщика'
foreach ($t in $LegacyTasks) {
    $lt = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    if ($lt -and $lt.State -ne 'Disabled') { Plan ('отключить старую задачу ' + $t); if (-not $Check) { Disable-ScheduledTask -TaskName $t | Out-Null } }
}
Plan ($TaskWatchdog + ': каждые 2 мин; ' + $TaskOff + ', ' + $TaskOn + ': по запросу')
if (-not $Check) {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    function New-Act([string]$script) {
        New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') `
            -Argument ('--headless "' + $ps + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $InstallDir $script) + '"')
    }
    $principal = New-ScheduledTaskPrincipal -UserId $me.Name -LogonType Interactive -RunLevel Highest
    # one time trigger only: it repeats while the user is logged on, also after reboots. An AtLogOn trigger
    # would only add a second start, and its own repetition is reset by any later edit of the task.
    $every = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
    $setW = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable `
                -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DontStopOnIdleEnd
    $setS = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
                -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskWatchdog -Action (New-Act 'Connect-Vpn.ps1') -Trigger $every -Principal $principal -Settings $setW `
        -Description 'home-vpn-kit: keeps the OpenConnect tunnel up' -Force | Out-Null
    Register-ScheduledTask -TaskName $TaskOff -Action (New-Act 'Disconnect-Vpn.ps1') -Principal $principal -Settings $setS `
        -Description 'home-vpn-kit: tray menu Disconnect VPN' -Force | Out-Null
    Register-ScheduledTask -TaskName $TaskOn -Action (New-Act 'Resume-Vpn.ps1') -Principal $principal -Settings $setS `
        -Description 'home-vpn-kit: tray menu Connect VPN' -Force | Out-Null
    foreach ($t in $TaskWatchdog, $TaskOff, $TaskOn) {
        if (-not (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue)) { Fail ('задача не создалась: ' + $t) }
    }
    Ok 'задачи зарегистрированы'
}

# ---------------------------------------------------------------- "Apps" entry
Step 'Запись в «Параметры -> Приложения»'
Plan ($AppsName + ' ' + $KitVersion + ': удаление штатным способом')
if (-not $Check) {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $un = '"' + $ps + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $setupDir 'uninstall.ps1') + '"'
    New-Item -Path $AppsKey -Force | Out-Null
    Set-ItemProperty -Path $AppsKey -Name DisplayName -Value $AppsName
    Set-ItemProperty -Path $AppsKey -Name DisplayVersion -Value $KitVersion
    Set-ItemProperty -Path $AppsKey -Name Publisher -Value 'gp131313'
    Set-ItemProperty -Path $AppsKey -Name URLInfoAbout -Value 'https://github.com/gp131313/home-vpn-kit'
    Set-ItemProperty -Path $AppsKey -Name InstallLocation -Value $InstallDir
    Set-ItemProperty -Path $AppsKey -Name UninstallString -Value ($un + ' -Gui')
    Set-ItemProperty -Path $AppsKey -Name QuietUninstallString -Value ($un + ' -Quiet')
    Set-ItemProperty -Path $AppsKey -Name NoModify -Value 1 -Type DWord
    Set-ItemProperty -Path $AppsKey -Name NoRepair -Value 1 -Type DWord
    Set-ItemProperty -Path $AppsKey -Name EstimatedSize -Value 256 -Type DWord   # KB: scripts + indicator
    Ok ('в «Приложениях»: ' + $AppsName)
}

# ---------------------------------------------------------------- tray indicator
if (-not $SkipTray) {
    Step 'Индикатор в трее (TrayPingMonitor-VPN)'
    if (Test-DesktopRuntime10) { Ok '.NET 10 Desktop Runtime есть' }
    else {
        Plan 'установить .NET 10 Desktop Runtime x64 (Microsoft)'
        if (-not $Check) {
            $idx = Invoke-RestMethod 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json' -UseBasicParsing
            $file = $idx.releases[0].windowsdesktop.files | Where-Object { $_.rid -eq 'win-x64' -and $_.name -like '*.exe' } | Select-Object -First 1
            $f = Get-Download $file.url 'windowsdesktop-runtime-win-x64.exe'
            Test-Hash $f $file.hash 'SHA512'
            $p = Start-Process $f -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
            if ($p.ExitCode -notin 0, 3010, 1641) { Fail ('установщик .NET вернул ' + $p.ExitCode) }
            Ok ('.NET ' + $idx.releases[0].'release-version' + ' установлен')
        }
    }

    $rel = Invoke-RestMethod ('https://api.github.com/repos/' + $TrayRepo + '/releases/latest') -UseBasicParsing
    $zipA = $rel.assets | Where-Object { $_.name -like '*win-x64.zip' } | Select-Object -First 1
    $sumA = $rel.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
    Plan ('TrayPingMonitor-VPN ' + $rel.tag_name + ' -> ' + $TrayDir)
    if (-not $Check) {
        $zip = Get-Download $zipA.browser_download_url $zipA.name
        $sums = Get-Download $sumA.browser_download_url 'tpm-SHA256SUMS.txt'
        $line = (Get-Content $sums | Where-Object { $_ -match [regex]::Escape($zipA.name) } | Select-Object -First 1)
        if (-not $line) { Fail 'в SHA256SUMS.txt нет строки для архива' }
        Test-Hash $zip ($line -split '\s+')[0]
        $x = Join-Path $DownDir 'tpm'; if (Test-Path $x) { Remove-Item $x -Recurse -Force }
        Expand-Archive $zip $x -Force
        $newExe = Join-Path $x 'TrayPingMonitor.exe'
        $same = (Test-Path $TrayExe) -and ((Get-FileHash $TrayExe).Hash -eq (Get-FileHash $newExe).Hash)
        if ($same) { Ok 'уже эта версия' } else {
            if (Get-ScheduledTask -TaskName $TrayTask -ErrorAction SilentlyContinue) { Disable-ScheduledTask -TaskName $TrayTask | Out-Null }
            Get-Process TrayPingMonitor -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep 2
            New-Item -ItemType Directory -Force $TrayDir | Out-Null
            Backup-File $TrayExe
            Copy-Item (Join-Path $x '*') $TrayDir -Force
            Ok 'файлы обновлены'
        }
        # settings: keep the user's own values, set host and the switch tasks
        New-Item -ItemType Directory -Force (Split-Path $TrayCfg) | Out-Null
        $s = [ordered]@{ Host = $ProbeHost; IntervalMs = 1000; LatencyThresholdMs = 150; RunAtStartup = $true; WindowSize = 20 }
        if (Test-Path $TrayCfg) {
            $old = Get-Content $TrayCfg -Raw | ConvertFrom-Json
            foreach ($n in 'IntervalMs', 'LatencyThresholdMs', 'WindowSize') { if ($old.$n) { $s[$n] = $old.$n } }
        }
        $s['VpnDisconnectTask'] = $TaskOff; $s['VpnConnectTask'] = $TaskOn
        ($s | ConvertTo-Json -Compress) | Set-Content -Path $TrayCfg -Encoding ASCII
        Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'TrayPingMonitor' -Value ('"' + $TrayExe + '"')
        $p = Start-Process $TrayExe -ArgumentList '--keepalive', 'on' -Wait -PassThru
        if ($p.ExitCode -ne 0) { Say '   не удалось включить автовосстановление (--keepalive on)' 'Yellow' }
        if (Get-ScheduledTask -TaskName $TrayTask -ErrorAction SilentlyContinue) {
            Enable-ScheduledTask -TaskName $TrayTask | Out-Null
            Start-ScheduledTask -TaskName $TrayTask   # starts it without admin rights, as the user
        }
        Ok ('индикатор: хост ' + $ProbeHost + ', пункт меню Disconnect/Connect VPN')
    }
}

# ---------------------------------------------------------------- first connection
if (-not $Check) {
    Step 'Проверка'
    Remove-Item (Join-Path $InstallDir 'DISABLED') -Force -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $TaskWatchdog
    $okNet = $false
    foreach ($i in 1..25) {
        Start-Sleep 3
        $c = New-Object System.Net.Sockets.TcpClient
        try { $ar = $c.BeginConnect($ProbeHost, [Math]::Max($ProbePort, 443), $null, $null); $okNet = $ar.AsyncWaitHandle.WaitOne(2000) -and $c.Connected } catch { } finally { $c.Close() }
        if ($okNet) { break }
    }
    if ($okNet) { Ok ('домашняя сеть доступна (' + $ProbeHost + ')') }
    else { Say ('   ' + $ProbeHost + ' пока не отвечает. Журнал: ' + (Join-Path $InstallDir 'watchdog.log')) 'Yellow' }
}

Write-Host ''
Say $(if ($Check) { 'Проверка закончена, ничего не изменено.' } else { 'Готово. Повторный запуск Install.cmd обновит установку.' }) 'Green'
