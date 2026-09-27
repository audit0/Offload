# Упаковывает собранный Offload.exe в Offload-Windows-<arch>.zip с контрольной суммой — для релиза на GitHub.
#   powershell -ExecutionPolicy Bypass -File windows\scripts\make-release.ps1 [-Runtime win-x64]
param([ValidateSet('win-x64', 'win-arm64')] [string] $Runtime = 'win-x64')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
$exe = Join-Path $dist "$Runtime\Offload.exe"
if (-not (Test-Path $exe)) { throw "Сначала соберите: windows\scripts\build.ps1 -Runtime $Runtime" }
$arch = $Runtime.Substring(4)
$zip = Join-Path $dist "Offload-Windows-$arch.zip"
Remove-Item -Force $zip, "$zip.sha256" -ErrorAction SilentlyContinue
Compress-Archive -Path $exe -DestinationPath $zip -CompressionLevel Optimal
# Формат как у shasum: «сумма  имя», чтобы сверять одинаково на Mac и в Windows.
$hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$zip.sha256", "$hash  $(Split-Path -Leaf $zip)`n")
Get-Item $zip, "$zip.sha256" | Format-Table Name, Length
Write-Host "✅ Готово к релизу: $zip"
