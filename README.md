# Solar Copilot

Голосовой помощник для Mac, который живёт в меню-баре и закрывает три вещи:

- **Копилот на созвонах.** Пишет звонок, показывает живую расшифровку, по ходу подсказывает готовые реплики (не «спроси про бюджет», а что сказать прямо сейчас), в конце выдаёт сводку: договорённости, обещания, следующие шаги.
- **Диктовка голосом.** Зажал правый Cmd, сказал, отпустил, текст вставился в активное окно. Работает в любом приложении.
- **Переключатель раскладки.** Набрал `ghbdtn` вместо «привет», тапнул левый Option, слово исправлено и раскладка переключена. Замена Punto Switcher.

Расшифровка идёт локально на вашем Mac (whisper.cpp), звук никуда не отправляется.
Подсказки и сводки делает Claude по **вашей** подписке Claude Pro или Max через Claude Code. Серверов и регистрации нет.

## Что нужно

- Mac на Apple Silicon (M1 и новее), macOS 13+.
- Подписка Claude Pro или Max и установленный Claude Code (`claude login`).
- whisper.cpp: `brew install whisper-cpp`. Модель распознавания (~1,6 ГБ) приложение скачает само.

## Установка за 10 минут

Пошагово в [INSTALL.md](INSTALL.md). Коротко:

1. Скачайте `SolarCopilot-<версия>.zip` из [Releases](../../releases), распакуйте, перенесите `SolarCopilot.app` в «Программы».
2. Приложение подписано без сертификата Apple, поэтому один раз снимите карантин:
   ```bash
   xattr -dr com.apple.quarantine /Applications/SolarCopilot.app
   ```
3. Запустите. В меню-баре появится 🎙. Откройте «⚙ Готовность копилота…», оно покажет, чего не хватает: Claude Code, whisper, модель, разрешения.

## Как пользоваться

- **Созвон:** кнопка на плавающей панели или «Старт» в меню. Транскрипт и подсказки в окне, по «Стоп» сводка. Записи лежат в `~/Library/Application Support/SolarCopilot/recordings`.
- **Диктовка:** правый Cmd. При первом разе приложение попросит «Мониторинг ввода» и «Универсальный доступ».
- **Раскладка:** левый Option. Работает сразу после установки, без Claude и whisper.

Чтобы подсказки звучали вашим голосом и под ваш продукт, положите свои `persona.md`, `checklist.json` и `hint_examples.md` в `~/Library/Application Support/SolarCopilot/`. Образцы лежат в `Resources/copilot-templates/`.

## Настройки

Окно «Настройки…» в меню или через `defaults`:

```bash
defaults write com.solar.copilot language "ru"
defaults write com.solar.copilot chunkSeconds 20
defaults write com.solar.copilot suggestionIntervalSec 45
defaults write com.solar.copilot llmProviderMode claude     # claude | codex | auto
```

Логи: `~/Library/Logs/solar-copilot*.log`.

## Сборка из исходников

Нужен только Swift toolchain из Command Line Tools (`xcode-select --install`):

```bash
./build.sh --release-zip     # dist/SolarCopilot-<версия>-arm64.zip
./build.sh                   # собрать и поставить в /Applications
```

Подробнее об архитектуре в [DEVELOPMENT.md](DEVELOPMENT.md).

## Лицензия

MIT.
