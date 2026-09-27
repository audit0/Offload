#!/bin/zsh
# Упаковывает dist/OffLoadAI.app в OffLoadAI.zip и OffLoadAI.dmg с контрольными суммами — для релиза на GitHub.
set -euo pipefail

HERE="${0:A:h}"
ROOT="${HERE:h}"
DIST="$ROOT/dist"
APP="$DIST/OffLoadAI.app"

[[ -d "$APP" ]] || { print -u2 "⚠️  Сначала соберите приложение: scripts/build-app.sh"; exit 1; }
codesign --verify --strict "$APP"
rm -f "$DIST/OffLoadAI.zip" "$DIST/OffLoadAI.dmg" "$DIST/OffLoadAI.zip.sha256" "$DIST/OffLoadAI.dmg.sha256"

echo "→ zip"
ditto -c -k --keepParent "$APP" "$DIST/OffLoadAI.zip"

echo "→ dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/OffLoadAI.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "OffLoadAI" -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet "$DIST/OffLoadAI.dmg"

echo "→ контрольные суммы"
( cd "$DIST" && for f in OffLoadAI.zip OffLoadAI.dmg; do shasum -a 256 "$f" > "$f.sha256"; done )
ls -lh "$DIST" | tail -n +2
echo "✅ Готово к релизу: $DIST"
