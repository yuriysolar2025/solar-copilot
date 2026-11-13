# Solar Copilot — нативное приложение (Phase 1)

Нативный macOS menubar-копилот. Замена хрупкому MVP (Hammerspoon + Terminal + tmux + Telegram-топики). План и фазы: [`Архитектура/tasks/⬜ copilot-native-app/`](../../Архитектура/tasks/⬜%20copilot-native-app/README.md).

## Что уже есть (Phase 1)

- Меню-бар (🎙/🔴) со Старт/Стоп, «Показать транскрипт», Выход.
- Нативный доступ к микрофону (AVAudioEngine, без Terminal-хака).
- Аудио → ресемпл в 16kHz mono → WAV → локальный whisper-server `:8127` (тот же бэкенд, что MVP).
- Живой транскрипт в нативном окне (вместо Telegram-топиков).

## Сборка и запуск

```sh
cd "copilot/native-app"
./build.sh          # swift build + упаковка в SolarCopilot.app + ad-hoc подпись
open SolarCopilot.app
```

Требования: Swift toolchain (Command Line Tools достаточно, полный Xcode не нужен), запущенный whisper-server на `127.0.0.1:8127` (как у MVP).

При первом запуске Старт → macOS спросит доступ к микрофону → разрешить (Системные настройки → Конфиденциальность → Микрофон).

## Настройки (без хардкод-секретов)

Через `defaults`:
```sh
defaults write com.solar.copilot whisperURL  "http://127.0.0.1:8127/inference"
defaults write com.solar.copilot chunkSeconds 20      # длина чанка, сек (20 дефолт; 30 = качество large-v3)
defaults write com.solar.copilot language     "ru"
```

## Архитектура (product-ready guardrails заложены)

- `TranscriptionProvider` (протокол) → `WhisperServerProvider` — бэкенд транскрипции подменяем.
- `LLMProvider` (протокол, Phase 2) — LLM за абстракцией: личный аккаунт → BYO-key / прокси без рерайта.
- `AppConfig` — всё из UserDefaults, ноль секретов в коде.
- `L` (Strings) — готовность к локализации RU/EN.
- Сборка как подписанный `.app` с первого дня.

## Дальше (фазы)

- **Phase 2:** Opus-подсказки по ходу + финальная сводка нативно (порт промптов/персоны из `daemon.py`).
- **Phase 3:** режим наушники+BlackHole, drive/listen авто-детект, выбор устройства.
- **Phase 4:** история сессий, настройки-UI, Developer ID + нотаризация + DMG.
