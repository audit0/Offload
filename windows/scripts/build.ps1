# Сборка Offload для Windows: один Offload.exe, которому не нужна установленная .NET.
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
& dotnet @arguments
if ($LASTEXITCODE -ne 0) { throw "dotnet publish завершился с кодом $LASTEXITCODE" }
$exe = Join-Path $out 'Offload.exe'
if (-not (Test-Path $exe)) { throw 'Offload.exe не собрался' }
Write-Host "✅ $exe ($([math]::Round((Get-Item $exe).Length / 1MB)) МБ)"
