#!/bin/zsh
# Установка Offload одной командой:
#   curl -fsSL https://raw.githubusercontent.com/audit0/Offload/main/scripts/install.sh | zsh
#
# Скачивает релиз с GitHub по HTTPS, сверяет SHA-256, подпись и идентификатор приложения,
# ставит в /Applications (или ~/Applications, если нет прав на запись) и запускает. Без sudo.
# Весь код внутри функции main: если загрузка скрипта оборвётся на середине, ничего не выполнится.
set -euo pipefail

main() {
  local repo="${OFFLOAD_REPO:-audit0/Offload}"
  local version="${OFFLOAD_VERSION:-latest}"
  local bundle_id="io.github.audit0.offload"

  fail() { print -u2 -- "⚠️  $1"; exit 1; }

  [[ "$(uname -s)" == Darwin ]] || fail "Offload работает только на macOS."
  local major="${$(sw_vers -productVersion)%%.*}"
  (( major >= 14 )) || fail "Нужна macOS 14 или новее."
  [[ "$repo" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]] || fail "Некорректный OFFLOAD_REPO: $repo"

  local base
  if [[ "$version" == latest ]]; then
    base="https://github.com/$repo/releases/latest/download"
  else
    [[ "$version" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "Некорректный OFFLOAD_VERSION: $version"
    base="https://github.com/$repo/releases/download/$version"
  fi

  local tmp
  tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" EXIT

  fetch() { curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 3 --output "$2" "$1"; }

  print "→ скачиваю Offload ($version) из $repo"
  fetch "$base/Offload.zip" "$tmp/Offload.zip"
  fetch "$base/Offload.zip.sha256" "$tmp/Offload.zip.sha256"

  print "→ сверяю SHA-256"
  local expected actual
  expected="$(awk 'NR==1 {print $1}' "$tmp/Offload.zip.sha256")"
  actual="$(shasum -a 256 "$tmp/Offload.zip" | awk '{print $1}')"
  [[ "$expected" =~ '^[0-9a-f]{64}$' && "$expected" == "$actual" ]] || fail "Контрольная сумма не совпала — установка отменена."

  # Сумма лежит в том же релизе и от подмены релиза не защищает. Подтверждение сборки (attestation)
  # подписано Sigstore и говорит, что архив собран workflow release.yml этого репозитория.
  # Проверить его может gh — если он установлен и вход выполнен.
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    print "→ проверяю подтверждение сборки (gh attestation verify)"
    if gh attestation verify "$tmp/Offload.zip" --repo "$repo" \
         --signer-workflow "$repo/.github/workflows/release.yml" >/dev/null 2>&1; then
      print "  сборка подтверждена: собрана GitHub Actions из $repo"
    elif [[ "${OFFLOAD_ALLOW_UNATTESTED:-0}" == 1 ]]; then
      print -u2 -- "⚠️  Подтверждения сборки нет — продолжаю, потому что задано OFFLOAD_ALLOW_UNATTESTED=1."
    else
      fail "Архив не подтверждён как сборка $repo. Релизы до v0.3.1 подтверждений не имеют: для них задайте OFFLOAD_ALLOW_UNATTESTED=1."
    fi
  else
    print "  (подтверждение сборки не проверено: нет gh или не выполнен вход; проверить вручную — gh attestation verify Offload.zip --repo $repo)"
  fi

  ditto -x -k "$tmp/Offload.zip" "$tmp/unpacked"
  local app="$tmp/unpacked/Offload.app"
  [[ -d "$app" ]] || fail "В архиве нет Offload.app."
  # Подпись ad-hoc: подтверждает только, что файлы приложения не изменены после подписи, но не кто его собрал.
  codesign --verify --strict "$app" 2>/dev/null || fail "Подпись приложения повреждена."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$bundle_id" ]] \
    || fail "Неожиданный идентификатор приложения — установка отменена."

  local dest="/Applications"
  [[ -w "$dest" ]] || dest="$HOME/Applications"
  mkdir -p "$dest"

  if pgrep -xq Offload; then
    print "→ закрываю запущенный Offload"
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
    for _ in {1..20}; do pgrep -xq Offload || break; sleep 0.25; done
  fi

  print "→ устанавливаю в $dest"
  rm -rf "$dest/Offload.app"
  ditto "$app" "$dest/Offload.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest/Offload.app" >/dev/null 2>&1 || true

  print "✅ Установлено: $dest/Offload.app"
  [[ "${OFFLOAD_NO_OPEN:-0}" == 1 ]] || open "$dest/Offload.app"
}

main "$@"
