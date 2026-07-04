$ErrorActionPreference = 'Stop'
$installDir = "$env:ProgramFiles\BearBrowser"

Get-Process -Name 'BearBrowser','firefox' -ErrorAction SilentlyContinue | Stop-Process -Force

# Remove registry entries
Remove-Item -Path 'HKLM:\SOFTWARE\Classes\BearBrowser.*' -Recurse -ErrorAction SilentlyContinue
Remove-Item -Path 'HKLM:\SOFTWARE\Clients\StartMenuInternet\BearBrowser' -Recurse -ErrorAction SilentlyContinue

# Remove Start Menu shortcut
Remove-Item -Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\BearBrowser.lnk" -ErrorAction SilentlyContinue

if (Test-Path $installDir) {
  Remove-Item -Recurse -Force $installDir
}
Write-Host "BearBrowser uninstalled. Profile preserved at $env:APPDATA\BearBrowser"
