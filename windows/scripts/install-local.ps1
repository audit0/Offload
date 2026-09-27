# Собрать из исходников и установить в %LOCALAPPDATA%\Programs\Offload (для разработки).
#   powershell -ExecutionPolicy Bypass -File windows\scripts\install-local.ps1
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'build.ps1')
$root = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $env:LOCALAPPDATA 'Programs\Offload'
Get-Process Offload -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$dest*" } | Stop-Process
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $root 'dist\win-x64\Offload.exe') $dest -Force
Write-Host "✅ Установлено: $dest\Offload.exe"
Start-Process (Join-Path $dest 'Offload.exe')
