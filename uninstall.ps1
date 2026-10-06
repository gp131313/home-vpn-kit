# uninstall.ps1 - removes what home-vpn-kit installed. Start it with Uninstall.cmd, from
# "Settings -> Apps -> Home VPN Kit" (-Gui) or silently (-Quiet).
# OpenConnect-GUI and .NET Desktop Runtime stay installed (remove them in "Apps" if not needed).
# Windows PowerShell 5.1 compatible. Saved as UTF-8 with BOM (Russian text).

[CmdletBinding()]
param(
    [string]$InstallDir,
    [switch]$KeepTray,
    [switch]$Gui,     # ask and report with message boxes (Settings -> Apps)
    [switch]$Quiet    # no questions, no windows
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
$ErrorActionPreference = 'Continue'
$Title = 'Home VPN Kit'
$TaskWatchdog = 'VPN Watchdog (OpenConnect)'
$TaskOff = 'VPN Disconnect'; $TaskOn = 'VPN Connect'
$AppsKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\HomeVpnKit'
$TrayDir = Join-Path $env:LOCALAPPDATA 'Programs\TrayPingMonitor'
$TrayExe = Join-Path $TrayDir 'TrayPingMonitor.exe'
# language of the message boxes follows Windows: Russian or English
$Ru = ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'ru')
function T([string]$ru, [string]$en) { if ($Ru) { $ru } else { $en } }
function Box([string]$m, [string]$icon = 'Information') {
    if ($Quiet) { return }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($m, $Title, 'OK', $icon)
}

$me  = [Security.Principal.WindowsIdentity]::GetCurrent()
$adm = (New-Object Security.Principal.WindowsPrincipal($me)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $adm) {
    if ($Gui -or $Quiet) {
        # "Apps" may start us without elevation: ask for it once and continue there
        $a = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $MyInvocation.MyCommand.Path + '" ' +
             $(if ($Gui) { '-Gui ' } else { '-Quiet ' }) + $(if ($KeepTray) { '-KeepTray ' } else { '' }) +
             $(if ($InstallDir) { '-InstallDir "' + $InstallDir + '"' } else { '' })
        try { Start-Process powershell.exe -Verb RunAs -ArgumentList $a -ErrorAction Stop } catch { exit 1 }
        exit 0
    }
    Write-Host 'Нужны права администратора - запустите Uninstall.cmd' -ForegroundColor Red; return
}

if (-not $InstallDir) {
    $t = Get-ScheduledTask -TaskName $TaskWatchdog -ErrorAction SilentlyContinue
    if ($t) { $m = [regex]::Match(($t.Actions[0].Arguments + ''), '-File\s+"?([^"]+\.ps1)'); if ($m.Success) { $InstallDir = Split-Path -Parent $m.Groups[1].Value } }
}
if (-not $InstallDir) { $InstallDir = (Get-ItemProperty -Path $AppsKey -ErrorAction SilentlyContinue).InstallLocation }
if (-not $InstallDir) { $InstallDir = Join-Path $env:ProgramFiles 'HomeVpnKit' }

if ($Gui) {
    Add-Type -AssemblyName System.Windows.Forms
    $q = (T ("Удалить " + $Title + "?`n`nТуннель VPN будет остановлен; задачи Планировщика, скрипты, сохранённый пароль" +
             $(if (-not $KeepTray) { ' и индикатор в трее' } else { '' }) + " будут удалены.`nOpenConnect-GUI останется установленным.") `
            ("Uninstall " + $Title + "?`n`nThe VPN tunnel will be stopped; the scheduled tasks, scripts, saved password" +
             $(if (-not $KeepTray) { ' and the tray indicator' } else { '' }) + " will be removed.`nOpenConnect-GUI stays installed."))
    if ([System.Windows.Forms.MessageBox]::Show($q, $Title, 'YesNo', 'Question') -ne 'Yes') { exit 0 }
} elseif (-not $Quiet) {
    Write-Host ('Будет удалено: задачи ' + $TaskWatchdog + ', ' + $TaskOff + ', ' + $TaskOn +
                '; папка ' + $InstallDir + ' (с сохранённым паролем)' +
                $(if (-not $KeepTray) { '; индикатор ' + $TrayDir } else { '' })) -ForegroundColor Yellow
    Write-Host 'Туннель VPN будет остановлен.' -ForegroundColor Yellow
    if ((Read-Host 'Введите YES для удаления') -cne 'YES') { Write-Host 'Отменено.'; return }
}

foreach ($n in $TaskWatchdog, $TaskOff, $TaskOn) { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue }
Get-Process openconnect -ErrorAction SilentlyContinue | Stop-Process -Force

if (-not $KeepTray -and (Test-Path $TrayExe)) {
    & $TrayExe --keepalive off | Out-Null
    Get-Process TrayPingMonitor -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'TrayPingMonitor' -ErrorAction SilentlyContinue
    Start-Sleep 2
    Remove-Item $TrayDir -Recurse -Force
}
Remove-Item -Path $AppsKey -Recurse -Force -ErrorAction SilentlyContinue

if (Test-Path (Join-Path $InstallDir 'Connect-Vpn.ps1')) {
    # this script may live inside the folder: delete it after we exit
    Start-Process cmd.exe -ArgumentList '/c', ('timeout /t 2 /nobreak >nul & rmdir /s /q "{0}"' -f $InstallDir) -WindowStyle Hidden
} else {
    Write-Host ('Папка ' + $InstallDir + ' не похожа на папку комплекта (нет Connect-Vpn.ps1) - не удаляю.') -ForegroundColor Yellow
}

if ($Gui) { Box (T ($Title + ' удалён. OpenConnect-GUI и .NET остались установленными.') ($Title + ' has been uninstalled. OpenConnect-GUI and .NET stay installed.')) }
else { Write-Host 'Удалено. OpenConnect-GUI и .NET остались установленными.' -ForegroundColor Green }
