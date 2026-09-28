#!/bin/zsh
# Собирает OffLoadAI из исходников и устанавливает в /Applications — для разработки.
set -euo pipefail

HERE="${0:A:h}"
ROOT="${HERE:h}"
DEST="${OFFLOAD_DEST:-/Applications}"
BUNDLE_ID="io.github.audit0.offload"

fail() { print -u2 -- "⚠️  $1"; exit 1; }

"$HERE/build-app.sh"

# До переименования программа звалась Offload: закрываем и её (идентификатор приложения тот же).
# Во время копирования OffLoadAI сначала спрашивает, прервать ли его, — ждём ответа. Не закрылся —
# установка останавливается: подменить программу под работающей значит оставить человека в старой версии.
running() { pgrep -xq -U "$UID" 'OffLoadAI|Offload'; }
if running; then
  echo "→ закрываю запущенный OffLoadAI"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for waited in {1..240}; do
    running || break
    if (( waited == 12 )); then echo "  OffLoadAI ещё открыт: если он спрашивает, прервать ли копирование, ответьте в его окне"; fi
    sleep 0.25
  done
  if running; then
    fail "OffLoadAI не закрылся, установка отменена, программа не тронута. Дождитесь конца копирования или закройте OffLoadAI сами и запустите установку снова."
  fi
fi

# Новая версия сначала копируется рядом и встаёт на место прежней переименованием: если установку
# прервать, остаётся прежняя программа, а не пустое место.
echo "→ устанавливаю в $DEST"
TARGET="$DEST/OffLoadAI.app" STAGED="$DEST/.OffLoadAI.app.new-$$" PREVIOUS="$DEST/.OffLoadAI.app.old-$$"
trap "rm -rf ${(q)STAGED}" EXIT
rm -rf "$STAGED" "$PREVIOUS"
if ! ditto "$ROOT/dist/OffLoadAI.app" "$STAGED" || ! codesign --verify --strict "$STAGED"; then
  rm -rf "$STAGED"
  fail "Не удалось скопировать новую версию в $DEST, прежняя осталась на месте."
fi
if [[ -e "$TARGET" || -L "$TARGET" ]] && ! mv "$TARGET" "$PREVIOUS"; then
  rm -rf "$STAGED"
  fail "Не удалось заменить $TARGET, прежняя версия осталась на месте."
fi
if ! mv "$STAGED" "$TARGET"; then
  if [[ -e "$PREVIOUS" ]] && ! mv "$PREVIOUS" "$TARGET"; then
    fail "Не удалось поставить новую версию. Прежняя лежит в $PREVIOUS — переименуйте её в OffLoadAI.app."
  fi
  fail "Не удалось поставить новую версию, прежняя осталась на месте."
fi
rm -rf "$PREVIOUS" || echo "⚠️  Не удалось удалить прежнюю версию $PREVIOUS — удалите её вручную." >&2
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" >/dev/null 2>&1 || true

# Прежняя копия под старым именем — только если это наше приложение; настройки и данные остаются.
OLD="$DEST/Offload.app"
if [[ -d "$OLD" && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OLD/Contents/Info.plist" 2>/dev/null)" == "$BUNDLE_ID" ]]; then
  echo "→ убираю прежнюю версию под старым именем: $OLD"
  rm -rf "$OLD"
fi
echo "✅ Установлено: $DEST/OffLoadAI.app"
