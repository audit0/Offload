#!/bin/zsh
# Упаковывает dist/Offload.app в Offload.zip и Offload.dmg с контрольными суммами — для релиза на GitHub.
set -euo pipefail

HERE="${0:A:h}"
ROOT="${HERE:h}"
DIST="$ROOT/dist"
APP="$DIST/Offload.app"

[[ -d "$APP" ]] || { print -u2 "⚠️  Сначала соберите приложение: scripts/build-app.sh"; exit 1; }
codesign --verify --strict "$APP"
rm -f "$DIST/Offload.zip" "$DIST/Offload.dmg" "$DIST/Offload.zip.sha256" "$DIST/Offload.dmg.sha256"

echo "→ zip"
ditto -c -k --keepParent "$APP" "$DIST/Offload.zip"

echo "→ dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Offload.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Offload" -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet "$DIST/Offload.dmg"

echo "→ контрольные суммы"
( cd "$DIST" && for f in Offload.zip Offload.dmg; do shasum -a 256 "$f" > "$f.sha256"; done )
ls -lh "$DIST" | tail -n +2
echo "✅ Готово к релизу: $DIST"
