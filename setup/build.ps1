# build.ps1 - builds HomeVpnKit-Setup.exe with the C# compiler that ships with Windows (.NET Framework 4.x),
# no SDK needed. Output: dist\HomeVpnKit-Setup.exe and dist\HomeVpnKit-Setup-Silent.exe (same file, the
# silent mode is picked by the file name).
#   powershell -NoProfile -ExecutionPolicy Bypass -File setup\build.ps1
#   -NoElevation   test build that does not ask for administrator rights (the wizard can be looked at,
#                  the installation itself fails) - never publish it
param([switch]$NoElevation)
$ErrorActionPreference = 'Stop'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'csc.exe (.NET Framework 4.x) not found' }

$root = Split-Path $PSScriptRoot -Parent
$out  = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$exe = Join-Path $out $(if ($NoElevation) { 'HomeVpnKit-Setup-noelevation.exe' } else { 'HomeVpnKit-Setup.exe' })

# embedded resource name = file name the installer unpacks (all flat, install.ps1 accepts that)
$files = @('install.ps1', 'uninstall.ps1', 'vpn\Connect-Vpn.ps1', 'vpn\Disconnect-Vpn.ps1', 'vpn\Resume-Vpn.ps1')
$res = foreach ($f in $files) {
    $p = Join-Path $root $f
    if (-not (Test-Path $p)) { throw "file not found: $p" }
    '/resource:"{0}",{1}' -f $p, (Split-Path $f -Leaf)
}
$manifest = Join-Path $PSScriptRoot 'app.manifest'
if ($NoElevation) {
    $manifest = Join-Path $out 'app.asinvoker.manifest'
    (Get-Content (Join-Path $PSScriptRoot 'app.manifest') -Raw) -replace 'requireAdministrator', 'asInvoker' | Set-Content $manifest -Encoding UTF8
}
& $csc /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 "/win32manifest:$manifest" `
    /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Management.dll `
    /reference:System.Web.Extensions.dll /reference:Microsoft.CSharp.dll `
    "/out:$exe" @res (Join-Path $PSScriptRoot 'Setup.cs')
if ($LASTEXITCODE -ne 0) { throw "compile error (code $LASTEXITCODE)" }
if ($NoElevation) { Remove-Item $manifest -Force; (Get-Item $exe).FullName; return }
# the silent installer is the same file: the mode is chosen by its own name
$silent = Join-Path $out 'HomeVpnKit-Setup-Silent.exe'
Copy-Item $exe $silent -Force
foreach ($f in $exe, $silent) { '{0}  {1} bytes  sha256 {2}' -f $f, (Get-Item $f).Length, (Get-FileHash $f -Algorithm SHA256).Hash.ToLower() }
