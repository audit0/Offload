# Установка Offload для Windows одной командой в PowerShell:
#   irm https://raw.githubusercontent.com/audit0/Offload/main/windows/scripts/install.ps1 | iex
#
# Скачивает релиз с GitHub по HTTPS, сверяет SHA-256, а если установлен gh — ещё и подтверждение сборки
# (что архив собран workflow этого репозитория). Ставит в %LOCALAPPDATA%\Programs\Offload, добавляет ярлык
# в меню «Пуск» и запускает. Права администратора не нужны.
# Весь код внутри функции: если загрузка сценария оборвётся на середине, ничего не выполнится.
function Install-Offload {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $repo = if ($env:OFFLOAD_REPO) { $env:OFFLOAD_REPO } else { 'audit0/Offload' }
    $version = if ($env:OFFLOAD_VERSION) { $env:OFFLOAD_VERSION } else { 'latest' }
    function Fail($text) { Write-Host "⚠️  $text" -ForegroundColor Yellow; throw $text }

    if ([Environment]::OSVersion.Version.Major -lt 10) { Fail 'Нужна Windows 10 или 11.' }
    if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { Fail "Некорректный OFFLOAD_REPO: $repo" }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    if ($version -eq 'latest') { $base = "https://github.com/$repo/releases/latest/download" }
    elseif ($version -match '^v\d+\.\d+\.\d+$') { $base = "https://github.com/$repo/releases/download/$version" }
    else { Fail "Некорректный OFFLOAD_VERSION: $version" }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("offload-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        $name = "Offload-Windows-$arch.zip"
        Write-Host "→ скачиваю Offload ($version, $arch) из $repo"
        Invoke-WebRequest -UseBasicParsing "$base/$name" -OutFile "$tmp\$name"
        Invoke-WebRequest -UseBasicParsing "$base/$name.sha256" -OutFile "$tmp\$name.sha256"

        Write-Host '→ сверяю SHA-256'
        $expected = ((Get-Content "$tmp\$name.sha256" -TotalCount 1) -split '\s+')[0].ToLowerInvariant()
        $actual = (Get-FileHash -Algorithm SHA256 "$tmp\$name").Hash.ToLowerInvariant()
        if ($expected -notmatch '^[0-9a-f]{64}$' -or $expected -ne $actual) { Fail 'Контрольная сумма не совпала — установка отменена.' }

        # Сумма лежит в том же релизе и от подмены релиза не защищает. Подтверждение сборки (attestation)
        # подписано Sigstore и говорит, что архив собран workflow release.yml этого репозитория.
        $gh = Get-Command gh -ErrorAction SilentlyContinue
        if ($gh -and (& gh auth status 2>$null; $LASTEXITCODE -eq 0)) {
            Write-Host '→ проверяю подтверждение сборки (gh attestation verify)'
            & gh attestation verify "$tmp\$name" --repo $repo --signer-workflow "$repo/.github/workflows/release.yml" *> $null
            if ($LASTEXITCODE -eq 0) { Write-Host "  сборка подтверждена: собрана GitHub Actions из $repo" }
            elseif ($env:OFFLOAD_ALLOW_UNATTESTED -eq '1') { Write-Host '⚠️  Подтверждения сборки нет — продолжаю, потому что задано OFFLOAD_ALLOW_UNATTESTED=1.' }
            else { Fail "Архив не подтверждён как сборка $repo." }
        }
        else { Write-Host "  (подтверждение сборки не проверено: нет gh или не выполнен вход; проверить вручную — gh attestation verify $name --repo $repo)" }

        Expand-Archive "$tmp\$name" -DestinationPath "$tmp\unpacked"
        $exe = "$tmp\unpacked\Offload.exe"
        if (-not (Test-Path $exe)) { Fail 'В архиве нет Offload.exe.' }
        $info = (Get-Item $exe).VersionInfo
        if ($info.ProductName -ne 'Offload') { Fail 'Неожиданная программа в архиве — установка отменена.' }

        $dest = Join-Path $env:LOCALAPPDATA 'Programs\Offload'
        Get-Process Offload -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$dest*" } | ForEach-Object {
            Write-Host '→ закрываю запущенный Offload'
            $_.CloseMainWindow() | Out-Null
            if (-not $_.WaitForExit(10000)) { Fail 'Offload не закрылся — закройте его и повторите.' }
        }
        Write-Host "→ устанавливаю в $dest"
        New-Item -ItemType Directory -Force $dest | Out-Null
        Copy-Item $exe (Join-Path $dest 'Offload.exe') -Force

        $shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Offload.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($shortcut)
        $link.TargetPath = Join-Path $dest 'Offload.exe'
        $link.WorkingDirectory = $dest
        $link.Description = 'Разгрузка диска без риска потерять данные'
        $link.Save()

        Write-Host "✅ Установлено: $dest\Offload.exe (ярлык — в меню «Пуск»)"
        if ($env:OFFLOAD_NO_OPEN -ne '1') { Start-Process (Join-Path $dest 'Offload.exe') }
    }
    finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
Install-Offload
