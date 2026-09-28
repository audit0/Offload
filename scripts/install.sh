#!/bin/zsh
# Установка OffLoadAI одной командой:
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

  [[ "$(uname -s)" == Darwin ]] || fail "OffLoadAI работает только на macOS."
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

  print "→ скачиваю OffLoadAI ($version) из $repo"
  # Релизы до переименования выложены как Offload.zip с Offload.app внутри — их тоже можно поставить.
  local name=OffLoadAI
  if ! fetch "$base/$name.zip" "$tmp/$name.zip" 2>/dev/null; then
    name=Offload
    fetch "$base/$name.zip" "$tmp/$name.zip"
  fi
  fetch "$base/$name.zip.sha256" "$tmp/$name.zip.sha256"

  print "→ сверяю SHA-256"
  local expected actual
  expected="$(awk 'NR==1 {print $1}' "$tmp/$name.zip.sha256")"
  actual="$(shasum -a 256 "$tmp/$name.zip" | awk '{print $1}')"
  [[ "$expected" =~ '^[0-9a-f]{64}$' && "$expected" == "$actual" ]] || fail "Контрольная сумма не совпала — установка отменена."

  # Сумма лежит в том же релизе и от подмены релиза не защищает. Подтверждение сборки (attestation)
  # подписано Sigstore и говорит, что архив собран workflow release.yml этого репозитория.
  # Проверить его может gh — если он установлен и вход выполнен.
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    print "→ проверяю подтверждение сборки (gh attestation verify)"
    if gh attestation verify "$tmp/$name.zip" --repo "$repo" \
         --signer-workflow "$repo/.github/workflows/release.yml" >/dev/null 2>&1; then
      print "  сборка подтверждена: собрана GitHub Actions из $repo"
    elif [[ "${OFFLOAD_ALLOW_UNATTESTED:-0}" == 1 ]]; then
      print -u2 -- "⚠️  Подтверждения сборки нет — продолжаю, потому что задано OFFLOAD_ALLOW_UNATTESTED=1."
    else
      fail "Архив не подтверждён как сборка $repo. Релизы до v0.3.1 подтверждений не имеют: для них задайте OFFLOAD_ALLOW_UNATTESTED=1."
    fi
  else
    print "  (подтверждение сборки не проверено: нет gh или не выполнен вход; проверить вручную — gh attestation verify $name.zip --repo $repo)"
  fi

  ditto -x -k "$tmp/$name.zip" "$tmp/unpacked"
  local app="$tmp/unpacked/$name.app"
  [[ -d "$app" ]] || fail "В архиве нет $name.app."
  # Подпись ad-hoc: подтверждает только, что файлы приложения не изменены после подписи, но не кто его собрал.
  codesign --verify --strict "$app" 2>/dev/null || fail "Подпись приложения повреждена."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$bundle_id" ]] \
    || fail "Неожиданный идентификатор приложения — установка отменена."

  local dest="/Applications"
  [[ -w "$dest" ]] || dest="$HOME/Applications"
  mkdir -p "$dest"

  # До переименования программа звалась Offload: закрываем и её (идентификатор приложения тот же).
  # Во время копирования OffLoadAI сначала спрашивает, прервать ли его, — ждём ответа. Не закрылся —
  # установка останавливается: подменить программу под работающей значит оставить человека в старой версии.
  running() { pgrep -xq -U "$UID" 'OffLoadAI|Offload'; }
  if running; then
    print "→ закрываю запущенный OffLoadAI"
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
    local waited
    for waited in {1..240}; do
      running || break
      if (( waited == 12 )); then print "  OffLoadAI ещё открыт: если он спрашивает, прервать ли копирование, ответьте в его окне"; fi
      sleep 0.25
    done
    if running; then
      fail "OffLoadAI не закрылся, установка отменена, программа не тронута. Дождитесь конца копирования или закройте OffLoadAI сами и запустите установку снова."
    fi
  fi

  # Новая версия сначала копируется рядом и встаёт на место прежней переименованием: если установку
  # прервать, остаётся прежняя программа, а не пустое место.
  print "→ устанавливаю в $dest"
  local target="$dest/OffLoadAI.app" staged="$dest/.OffLoadAI.app.new-$$" previous="$dest/.OffLoadAI.app.old-$$"
  trap "rm -rf ${(q)tmp} ${(q)staged}" EXIT
  rm -rf "$staged" "$previous"
  if ! ditto "$app" "$staged" || ! codesign --verify --strict "$staged" 2>/dev/null; then
    rm -rf "$staged"
    fail "Не удалось скопировать новую версию в $dest, прежняя осталась на месте."
  fi
  if [[ -e "$target" || -L "$target" ]] && ! mv "$target" "$previous"; then
    rm -rf "$staged"
    fail "Не удалось заменить $target, прежняя версия осталась на месте."
  fi
  if ! mv "$staged" "$target"; then
    if [[ -e "$previous" ]] && ! mv "$previous" "$target"; then
      fail "Не удалось поставить новую версию. Прежняя лежит в $previous — переименуйте её в OffLoadAI.app."
    fi
    fail "Не удалось поставить новую версию, прежняя осталась на месте."
  fi
  rm -rf "$previous" || print -u2 -- "⚠️  Не удалось удалить прежнюю версию $previous — удалите её вручную."
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target" >/dev/null 2>&1 || true

  # Прежняя копия под старым именем: удаляем, только если это наше приложение. Настройки, ключ Pro,
  # журнал и база решений остаются на месте — новая версия читает их сама.
  local old
  for old in /Applications/Offload.app "$HOME/Applications/Offload.app"; do
    [[ -d "$old" ]] || continue
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$old/Contents/Info.plist" 2>/dev/null)" == "$bundle_id" ]] || continue
    print "→ убираю прежнюю версию под старым именем: $old"
    rm -rf "$old" || print -u2 -- "⚠️  Не удалось удалить $old — удалите его вручную."
  done

  print "✅ Установлено: $dest/OffLoadAI.app"
  [[ "${OFFLOAD_NO_OPEN:-0}" == 1 ]] || open "$dest/OffLoadAI.app"
}

main "$@"
