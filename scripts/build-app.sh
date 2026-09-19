#!/bin/zsh
# Собирает Offload.app: swift build, пакет .app, иконка, ad-hoc подпись с hardened runtime.
# Использование: scripts/build-app.sh [версия]   (по умолчанию — из файла VERSION)
# OFFLOAD_UNIVERSAL=1 — universal binary arm64 + x86_64 (нужен Xcode, например на GitHub Actions).
set -euo pipefail

HERE="${0:A:h}"
ROOT="${HERE:h}"
VERSION="${1:-$(<"$ROOT/VERSION")}"
BUNDLE_ID="io.github.audit0.offload"
DIST="$ROOT/dist"
APP="$DIST/Offload.app"
ASSETS="$ROOT/.build/app-assets"

[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$' ]] || { print -u2 "⚠️  Некорректная версия: $VERSION"; exit 1; }

rm -rf "$APP" "$ASSETS"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ASSETS/AppIcon.iconset"

ARCH_FLAGS=()
if [[ "${OFFLOAD_UNIVERSAL:-0}" == 1 ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
  echo "→ компилирую universal (arm64 + x86_64)"
else
  echo "→ компилирую ($(uname -m))"
fi
# Начиная с SDK macOS 27 обёртки SwiftUI (@State и др.) — макросы, а их плагин SwiftUIMacros
# поставляется только с Xcode. Если стоят одни Command Line Tools, собираем против SDK 26 из их состава.
DEFAULT_SDK="$(xcrun --show-sdk-version 2>/dev/null || echo 0)"
if [[ -z "${SDKROOT:-}" && "${DEFAULT_SDK%%.*}" -ge 27 ]] \
   && ! find "$(xcode-select -p)" -path '*host/plugins/*SwiftUIMacros*' -print -quit 2>/dev/null | grep -q .; then
  OLDER_SDK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)"
  if [[ -n "$OLDER_SDK" ]]; then
    export SDKROOT="$OLDER_SDK"
    echo "→ SDK $DEFAULT_SDK без плагина макросов SwiftUI, собираю против $(basename "$OLDER_SDK")"
  else
    print -u2 "⚠️  SDK $DEFAULT_SDK требует Xcode для сборки SwiftUI (плагин SwiftUIMacros есть только в нём)."
    exit 1
  fi
fi
swift build --package-path "$ROOT" -c release --product Offload "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build --package-path "$ROOT" -c release "${ARCH_FLAGS[@]}" --show-bin-path)"
cp "$BIN_DIR/Offload" "$APP/Contents/MacOS/Offload"

echo "→ рисую иконку"
swiftc -O -o "$ASSETS/make-icon" "$HERE/icon.swift"
"$ASSETS/make-icon" "$ASSETS/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ASSETS/icon-1024.png" --out "$ASSETS/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$ASSETS/icon-1024.png" --out "$ASSETS/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ASSETS/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Offload</string>
  <key>CFBundleDisplayName</key><string>Offload</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Offload</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 audit0 · MIT</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Offload показывает, что занимает место в папке «Документы», и переносит выбранное на внешний диск.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Offload показывает, что занимает место на рабочем столе, и переносит выбранное на внешний диск.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Offload показывает, что занимает место в «Загрузках», и переносит выбранное на внешний диск.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Offload переносит данные и делает бэкап на внешний диск.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Offload может переносить данные на сетевой диск.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "→ подписываю (ad-hoc, hardened runtime)"
codesign --force --options runtime --sign - "$APP" >/dev/null
codesign --verify --strict "$APP"
echo "✅ Собрано: $APP ($VERSION)"
