#!/bin/zsh
# Собирает Offload из исходников и устанавливает в /Applications — для разработки.
set -euo pipefail

HERE="${0:A:h}"
ROOT="${HERE:h}"
DEST="${OFFLOAD_DEST:-/Applications}"
BUNDLE_ID="io.github.audit0.offload"

"$HERE/build-app.sh"

if pgrep -xq Offload; then
  echo "→ закрываю запущенный Offload"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -xq Offload || break; sleep 0.25; done
fi

echo "→ устанавливаю в $DEST"
rm -rf "$DEST/Offload.app"
ditto "$ROOT/dist/Offload.app" "$DEST/Offload.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/Offload.app" >/dev/null 2>&1 || true
codesign --verify --strict "$DEST/Offload.app"
echo "✅ Установлено: $DEST/Offload.app"
