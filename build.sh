#!/bin/zsh -f
# Сборка SolarCopilot.app из SPM-бинаря + установка в /Applications.
# Полный Xcode не нужен, только Swift toolchain.
set -e
cd "$(dirname "$0")"

echo "→ swift build -c release"
swift build -c release

APP="SolarCopilot.app"
BIN="$(swift build -c release --show-bin-path)/SolarCopilot"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SolarCopilot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Стабильная self-signed подпись (если есть в keychain) — тогда TCC-гранты
# (Мониторинг ввода/Универсальный доступ/Микрофон) переживают пересборки, т.к.
# designated requirement привязан к сертификату, а не к меняющемуся cdhash.
# Фоллбэк на ad-hoc, если сертификата нет (другой Mac).
IDENTITY="Solar Copilot Code Sign"
if security find-identity 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
  echo "✓ подписано стабильным сертификатом: $IDENTITY"
else
  codesign --force --deep --sign - "$APP"
  echo "✓ ad-hoc подпись (стабильного сертификата нет)"
fi

# Установка в /Applications — чтобы запускать как обычное приложение
DEST="/Applications/SolarCopilot.app"
pkill -f "SolarCopilot.app/Contents/MacOS/SolarCopilot" 2>/dev/null || true
sleep 0.5
rm -rf "$DEST"
cp -R "$APP" "$DEST"

echo "✓ Установлено: $DEST"
echo "  Запуск: open -a 'Solar Copilot'  (или Spotlight/Launchpad)"
