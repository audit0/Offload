# Сборка OffLoadAI для Windows: один OffLoadAI.exe, которому не нужна установленная .NET.
#   powershell -ExecutionPolicy Bypass -File windows\scripts\build.ps1 [-Runtime win-x64|win-arm64] [-Version 0.0.0]
param(
    [ValidateSet('win-x64', 'win-arm64')] [string] $Runtime = 'win-x64',
    [string] $Version = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "dist\$Runtime"
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
$arguments = @('publish', (Join-Path $root 'src\Offload\Offload.csproj'), '-c', 'Release', '-r', $Runtime, '--self-contained', 'true',
               '-p:PublishSingleFile=true', '-p:IncludeNativeLibrariesForSelfExtract=true', '-p:EnableCompressionInSingleFile=true',
               '-p:DebugType=none', '-o', $out, '-nologo')
if ($Version) { $arguments += "-p:Version=$Version" }
# День выхода версии: ключ OffLoadAI Pro открывает версии, вышедшие до конца его обновлений. Берётся из последнего
# коммита, а не из часов сборки: пересборка той же версии через год не должна её «состарить».
$releaseDate = $env:OFFLOAD_RELEASE_DATE
if (-not $releaseDate) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        # День — по UTC, как у сборки для Mac.
        $zone = $env:TZ; $env:TZ = 'UTC'
        $releaseDate = (& git -C $root log -1 --date=format-local:%Y-%m-%d --format=%cd 2>$null)
        $env:TZ = $zone
    }
}
if ($releaseDate -notmatch '^\d{4}-\d{2}-\d{2}$') { $releaseDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd') }
$arguments += "-p:OffloadReleaseDate=$releaseDate"
& dotnet @arguments
if ($LASTEXITCODE -ne 0) { throw "dotnet publish завершился с кодом $LASTEXITCODE" }
$exe = Join-Path $out 'OffLoadAI.exe'
if (-not (Test-Path $exe)) { throw 'OffLoadAI.exe не собрался' }
Write-Host "✅ $exe ($([math]::Round((Get-Item $exe).Length / 1MB)) МБ)"
