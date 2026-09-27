# Собрать из исходников и установить в %LOCALAPPDATA%\Programs\OffLoadAI (для разработки).
#   powershell -ExecutionPolicy Bypass -File windows\scripts\install-local.ps1
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'build.ps1')
$root = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $env:LOCALAPPDATA 'Programs\OffLoadAI'
Get-Process OffLoadAI -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$dest*" } | Stop-Process
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $root 'dist\win-x64\OffLoadAI.exe') $dest -Force
Write-Host "✅ Установлено: $dest\OffLoadAI.exe"
Start-Process (Join-Path $dest 'OffLoadAI.exe')
