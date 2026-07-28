$ErrorActionPreference = 'Stop'

# BearBrowser Chocolatey installer.
#
# Installs the REAL BearBrowser Windows build (the LibreWolf-mirror Firefox 150
# fork with BearNet + BearTrap) from the project's GitHub release. There is no
# "bootstrap from stock Firefox" fallback — if the real build cannot be fetched
# and verified, the install fails loudly. We never install something that isn't
# BearBrowser and call it BearBrowser.

$packageName = 'bearbrowser'
$version     = '150.0.1'
$installDir  = "$env:ProgramFiles\BearBrowser"
$url64       = "https://github.com/SourceOS-Linux/BearBrowser/releases/download/v$version/BearBrowser-$version-win64.zip"

# sha256 of BearBrowser-150.0.1-win64.zip from the v150.0.1 release.
$checksum64  = '01cad9eb2d3a6f828bc3e5ef37e3b9a8a162fa15da66663301aa4fcfb4dd5644'

New-Item -ItemType Directory -Force -Path $installDir | Out-Null

Install-ChocolateyZipPackage -PackageName $packageName `
  -Url64bit      $url64 `
  -UnzipLocation $installDir `
  -Checksum64    $checksum64 `
  -ChecksumType64 'sha256'

# The zip unpacks to a 'bearbrowser' dir; locate the real executable.
$exe = Get-ChildItem -Path $installDir -Recurse -Filter 'bearbrowser.exe' -ErrorAction SilentlyContinue |
         Select-Object -First 1
if (-not $exe) {
  $exe = Get-ChildItem -Path $installDir -Recurse -Filter 'firefox.exe' -ErrorAction SilentlyContinue |
           Select-Object -First 1
}
if (-not $exe) {
  throw "BearBrowser executable not found under $installDir after unzip — install aborted."
}

# Expose a Start Menu shortcut to the real executable.
Install-ChocolateyShortcut `
  -ShortcutFilePath "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\BearBrowser.lnk" `
  -TargetPath $exe.FullName `
  -Description 'BearBrowser — sovereign privacy browser'

Write-Host ""
Write-Host "BearBrowser $version installed: $($exe.FullName)" -ForegroundColor Green
Write-Host "BearNet (network monitor) and BearTrap (honeypot) are built in." -ForegroundColor Green
Write-Host "Note: this build is unsigned — SmartScreen may warn on first run." -ForegroundColor Yellow
