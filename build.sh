#!/bin/zsh -f
# Сборка SolarCopilot.app из SPM-бинаря + установка в /Applications.
# Полный Xcode не нужен, только Swift toolchain.
#   ./build.sh                установить в /Applications (машина разработчика)
#   ./build.sh --release-zip  не трогать /Applications, собрать dist/SolarCopilot-<версия>-<арка>.zip
set -e
cd "$(dirname "$0")"
MODE="${1:-install}"

# Universal (arm64 + x86_64) — чтобы апп работал и на Intel-маках друзей.
# ВАЖНО: multi-arch SPM-сборка требует ПОЛНОГО Xcode (xcbuild). С одними Command Line
# Tools падает «xcbuild ... does not exist» → fallback на нативную арку (arm64 на Apple
# Silicon). Для Intel-друга: поставить полный Xcode и пересобрать, либо отдать native arm64
# (Apple Silicon-друзьям достаточно).
ARCHFLAGS="--arch arm64 --arch x86_64"
echo "→ swift build -c release $ARCHFLAGS (universal)"
if swift build -c release $ARCHFLAGS 2>/dev/null; then
  BIN="$(swift build -c release $ARCHFLAGS --show-bin-path)/SolarCopilot"
  echo "✓ universal arm64+x86_64"
else
  echo "⚠️ universal не собрался — нативная арка"
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/SolarCopilot"
fi

APP="SolarCopilot.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SolarCopilot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Дефолтные шаблоны копилота (persona/checklist/listen_mode/hint_examples) — чтобы
# у друга подсказки работали без личных файлов Юрия. Пользователь может переопределить
# своими в Application Support → SolarCopilot.
cp -R Resources/copilot-templates "$APP/Contents/Resources/" 2>/dev/null || true

# iCloud вешает расширенные атрибуты (Finder info / resource forks) на файлы в
# облачной папке И ВОЗВРАЩАЕТ их между `xattr -cr` и `codesign` (фоновый sync) →
# codesign падает «resource fork ... not allowed». Надёжно: подписываем НЕ на месте,
# а в /tmp (вне iCloud) — там атрибуты не возвращаются. (Прежний `xattr -cr` на
# месте в облачной папке не держал.)
STAGE_DIR="/tmp/SolarCopilot-stage"; STAGE="$STAGE_DIR/SolarCopilot.app"   # имя бандла в архиве должно остаться SolarCopilot.app
rm -rf "$STAGE_DIR"; mkdir -p "$STAGE_DIR"
cp -R "$APP" "$STAGE"
xattr -cr "$STAGE"
find "$STAGE" -name '._*' -delete 2>/dev/null || true

# Стабильная self-signed подпись (если есть в keychain) — тогда TCC-гранты
# (Мониторинг ввода/Универсальный доступ/Микрофон) переживают пересборки, т.к.
# designated requirement привязан к сертификату, а не к меняющемуся cdhash.
# Фоллбэк на ad-hoc, если сертификата нет (другой Mac).
IDENTITY="Solar Copilot Code Sign"
ENTITLEMENTS="$(pwd)/Resources/SolarCopilot.entitlements"
if security find-identity 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$STAGE"
  echo "✓ подписано стабильным сертификатом: $IDENTITY"
else
  codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign - "$STAGE"
  echo "✓ ad-hoc подпись (стабильного сертификата нет)"
fi
codesign --verify --deep --strict "$STAGE" && echo "✓ подпись валидна"

if [ "$MODE" = "--release-zip" ]; then
  VER="$(/usr/bin/plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
  ARCH="$(lipo -archs "$STAGE/Contents/MacOS/SolarCopilot" | tr ' ' '-')"
  mkdir -p dist
  ZIP="$(pwd)/dist/SolarCopilot-$VER-$ARCH.zip"
  rm -f "$ZIP"
  # ditto сохраняет подпись и права; архив без ресурсных вилок iCloud (стейдж в /tmp)
  COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$STAGE" "$ZIP"   # без ._-файлов и ресурсных вилок
  rm -rf "$STAGE_DIR" "$APP"
  shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
  echo "✓ Релиз: $ZIP"
  exit 0
fi

# Установка в /Applications из /tmp-стейджа — чтобы запускать как обычное приложение
DEST="/Applications/SolarCopilot.app"
pkill -f "SolarCopilot.app/Contents/MacOS/SolarCopilot" 2>/dev/null || true
sleep 0.5
rm -rf "$DEST"
cp -R "$STAGE" "$DEST"
rm -rf "$STAGE_DIR"

echo "✓ Установлено: $DEST"
echo "  Запуск: open -a 'Solar Copilot'  (или Spotlight/Launchpad)"
