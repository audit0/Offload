#!/bin/zsh
# Собирает OffLoadAI из исходников и устанавливает в /Applications — для разработки.
set -euo pipefail

HERE="${0:A:h}"
ROOT="${HERE:h}"
DEST="${OFFLOAD_DEST:-/Applications}"
BUNDLE_ID="io.github.audit0.offload"

"$HERE/build-app.sh"

# До переименования программа звалась Offload: закрываем и её (идентификатор приложения тот же).
if pgrep -xq 'OffLoadAI|Offload'; then
  echo "→ закрываю запущенный OffLoadAI"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -xq 'OffLoadAI|Offload' || break; sleep 0.25; done
fi

echo "→ устанавливаю в $DEST"
rm -rf "$DEST/OffLoadAI.app"
ditto "$ROOT/dist/OffLoadAI.app" "$DEST/OffLoadAI.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/OffLoadAI.app" >/dev/null 2>&1 || true
codesign --verify --strict "$DEST/OffLoadAI.app"

# Прежняя копия под старым именем — только если это наше приложение; настройки и данные остаются.
OLD="$DEST/Offload.app"
if [[ -d "$OLD" && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OLD/Contents/Info.plist" 2>/dev/null)" == "$BUNDLE_ID" ]]; then
  echo "→ убираю прежнюю версию под старым именем: $OLD"
  rm -rf "$OLD"
fi
echo "✅ Установлено: $DEST/OffLoadAI.app"
