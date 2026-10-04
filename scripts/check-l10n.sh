#!/bin/zsh
# Проверяет, что у каждой строки интерфейса Mac есть английский перевод.
# Ключи собирает сам компилятор (-emit-localized-strings): Text("…"), tr("…"), String(localized:) и т. п.
# Нет перевода — список ключей и код 1. Новую строку добавляйте в Localization/en.lproj/Localizable.strings.
# Использование: scripts/check-l10n.sh
set -euo pipefail

HERE="${0:A:h}"
ROOT="${HERE:h}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# Та же оговорка про SDK 27 без Xcode, что в build-app.sh.
DEFAULT_SDK="$(xcrun --show-sdk-version 2>/dev/null || echo 0)"
if [[ -z "${SDKROOT:-}" && "${DEFAULT_SDK%%.*}" -ge 27 ]] \
   && ! find "$(xcode-select -p)" -path '*host/plugins/*SwiftUIMacros*' -print -quit 2>/dev/null | grep -q .; then
  OLDER_SDK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)"
  [[ -n "$OLDER_SDK" ]] && export SDKROOT="$OLDER_SDK"
fi

# Отдельная папка сборки: только полная пересборка выдаёт строки всех файлов.
swift build --package-path "$ROOT" --product Offload --build-path "$OUT/build" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT/strings" >/dev/null

python3 - "$OUT/strings" "$ROOT/Localization/en.lproj/Localizable.strings" <<'PY'
import glob, json, re, subprocess, sys
strings_dir, table = sys.argv[1], sys.argv[2]
keys = set()
for f in glob.glob(f'{strings_dir}/*.stringsdata'):
    for entries in json.load(open(f))['tables'].values():
        keys.update(e['key'] for e in entries)
# Переводятся только строки с русскими буквами или кавычками «»; остальное (форматы, имена) — как есть.
keys = {k for k in keys if re.search('[А-Яа-яЁё«»]', k)}
translated = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', table]))
missing = sorted(keys - translated.keys())
spec = re.compile(r'%(?:\d+\$)?(?:lld|ld|lf|d|@|f|%)')
norm = lambda s: sorted(re.sub(r'\d+\$', '', m) for m in spec.findall(s))
broken = sorted(k for k in keys & translated.keys() if norm(k) != norm(translated[k]))
for k in missing:
    print(f'нет перевода: {k}')
for k in broken:
    print(f'форматы не совпадают: {k} → {translated[k]}')
print(f'строк интерфейса: {len(keys)}, без перевода: {len(missing)}, с ошибкой формата: {len(broken)}')
sys.exit(1 if missing or broken else 0)
PY
