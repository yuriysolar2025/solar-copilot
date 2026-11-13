import Foundation

/// Конфиг приложения. БЕЗ хардкод-секретов — всё из UserDefaults/дефолтов
/// (product-ready guardrail: мультипользователь = настройка, не рерайт).
struct AppConfig {
    var whisperURL: URL
    var chunkSeconds: Double
    var language: String
    var recordingsDir: URL

    // Phase 2 — «мозг» (подсказки + сводка). Всё подменяемо через настройки/UserDefaults.
    var assistantEnabled: Bool
    var suggestionIntervalSec: Double
    var llmProviderMode: LLMProviderMode
    var claudeBinPath: String
    var codexBinPath: String
    var copilotResourcesDir: URL      // persona.md / checklist.json / listen_mode.md
    var suggestModel: String
    var summaryModel: String
    var classifyModel: String
    var codexModel: String

    // Phase 3/4/5 — единый голосовой хаб (замена Hammerspoon).
    var ffmpegPath: String            // запись memo + резолв avfoundation-устройств
    var dictationDir: URL             // папка «Диктовка/» для memo (launchd→Telegram)
    var callInputDevicePrefs: [String] // приоритет устройства копилота/memo (обе стороны)
    var dictatePipelinePath: String   // ~/bin/dictate-pipeline для Right-Cmd диктовки
    var callOutputDevice: String      // Multi-Output для звонка (output-toggle)
    var normalOutputDevice: String    // обычный output (AirPods)
    var sendToAssistant: Bool         // копию записи копилота → Диктовка/ → ассистент (Telegram)

    // Layout — переключатель раскладки (замена Punto Switcher).
    var layoutSwitchEnabled: Bool     // ловить хоткей и конвертировать раскладку
    var layoutSwitchKeycode: Int      // хоткей (дефолт 58 = левый Option)
    var layoutAutoEnabled: Bool       // Phase 2 — автомат (по умолчанию выкл)

    // Public-раздача (Фаза 8). publicMode=true → апп у друга: личные фичи Юрия
    // (Telegram-роутинг) выкл по умолчанию, мастер первого запуска проверяет
    // зависимости. Автодетект: машина Юрия (есть persona.md) = personal.
    var publicMode: Bool

    // «Зрение» по экрану — копилот видит демо/код/таблицы клиента наряду с транскриптом.
    var screenVisionEnabled: Bool        // авто-захват по ходу + кнопка «глянь сейчас»
    var screenCaptureIntervalSec: Double // как часто авто-снимок (реже подсказок)

    // Десктоп-компаньон (Альтрон-тамагочи) — глаз на рабочем столе, видит экран+здоровье.
    var companionEnabled: Bool           // opt-in (ambient-скриншоты вне звонка) — дефолт OFF
    var companionIntervalSec: Double     // как часто компаньон смотрит/реагирует

    // Осведомлённость ассистента — тихий наблюдатель экрана → @spb_claude_bot общий контекст.
    var awarenessEnabled: Bool           // opt-in (видит экран фоном) — дефолт OFF
    var awarenessIntervalSec: Double     // как часто распознавать работу (дефолт 300)
    var activityServerHost: String       // куда слать журнал (root@host) — только на машине Юрия
    var activityRemotePath: String       // путь журнала активности на сервере

    static let defaultWhisperURL = URL(string: "http://127.0.0.1:8127/inference")!

    /// По умолчанию — Application Support (не вызывает лишний TCC-промпт, в отличие
    /// от ~/Documents). Юрий может сменить через «Папка записей…».
    static var defaultRecordingsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SolarCopilot/recordings", isDirectory: true)
    }

    static var defaultClaudeBin: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
    }

    static var defaultCodexBin: String {
        // Codex CLI ships inside ChatGPT.app on current desktop builds.
        // Legacy Codex.app remains supported by CodexCLIProvider discovery.
        "/Applications/ChatGPT.app/Contents/Resources/codex"
    }

    /// persona.md / checklist.json / listen_mode.md живут в copilot/ (iCloud) — там же,
    /// что и MVP. Настраиваемо (product-ready: на другом Mac путь иной).
    static var defaultResourcesDir: URL {
        let dev = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Solar OS/copilot", isDirectory: true)
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        // Публичная сборка: личные файлы (persona.md и т.п.) лежат в Application Support.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SolarCopilot", isDirectory: true)
    }

    /// Папка «Диктовка/» — memo-файлы кладём сюда, launchd роутит в Telegram.
    static var defaultDictationDir: URL {
        let dev = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Solar OS/Диктовка", isDirectory: true)
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        return defaultRecordingsDir.deletingLastPathComponent().appendingPathComponent("dictation", isDirectory: true)
    }

    static var defaultDictatePipeline: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("bin/dictate-pipeline").path
    }

    /// ПУСТО = копилот пишет с системного входа по умолчанию (надёжно ловит голос).
    /// RecordCall (aggregate «обе стороны») через AVAudioEngine давал ТИШИНУ (−91dB,
    /// баг 12.06) — both-sides сделаем отдельно (ffmpeg-капча как в MVP), не AVAudioEngine.
    static let defaultCallInputPrefs: [String] = []

    /// Машина разработчика (Юрия) определяется по наличию его `persona.md` в
    /// дефолтном iCloud-пути. У друга его нет → publicMode. Переопределяемо ключом
    /// `publicMode` в UserDefaults.
    static var isDeveloperMachine: Bool {
        FileManager.default.fileExists(atPath: defaultResourcesDir.appendingPathComponent("persona.md").path)
    }

    static func load() -> AppConfig {
        let d = UserDefaults.standard
        let urlStr = d.string(forKey: "whisperURL") ?? defaultWhisperURL.absoluteString
        let url = URL(string: urlStr) ?? defaultWhisperURL
        let chunk = d.double(forKey: "chunkSeconds")
        let lang = d.string(forKey: "language") ?? "ru"
        let recDir: URL
        if let p = d.string(forKey: "recordingsDir"), !p.isEmpty {
            recDir = URL(fileURLWithPath: p, isDirectory: true)
        } else {
            recDir = defaultRecordingsDir
        }
        let assistant = d.object(forKey: "assistantEnabled") as? Bool ?? true
        let interval = d.double(forKey: "suggestionIntervalSec")
        let providerRaw = d.string(forKey: "llmProviderMode") ?? LLMProviderMode.codex.rawValue
        let providerMode = LLMProviderMode(rawValue: providerRaw) ?? .auto
        let bin = d.string(forKey: "claudeBinPath").flatMap { $0.isEmpty ? nil : $0 } ?? defaultClaudeBin
        let codexBin = d.string(forKey: "codexBinPath").flatMap { $0.isEmpty ? nil : $0 } ?? defaultCodexBin
        let resDir: URL
        if let rp = d.string(forKey: "copilotResourcesDir"), !rp.isEmpty {
            resDir = URL(fileURLWithPath: rp, isDirectory: true)
        } else {
            resDir = defaultResourcesDir
        }
        let dev = isDeveloperMachine
        let binResolved = Dependencies.resolveClaude(preferred: bin) ?? bin
        let codexResolved = Dependencies.resolveCodex(preferred: codexBin) ?? codexBin
        let ffmpegPref = d.string(forKey: "ffmpegPath").flatMap { $0.isEmpty ? nil : $0 } ?? "/opt/homebrew/bin/ffmpeg"
        let ffmpegResolved = Dependencies.resolveFfmpeg(preferred: ffmpegPref) ?? ffmpegPref
        return AppConfig(
            whisperURL: url,
            chunkSeconds: chunk > 0 ? chunk : 20,
            language: lang.isEmpty ? "ru" : lang,
            recordingsDir: recDir,
            assistantEnabled: assistant,
            suggestionIntervalSec: interval > 0 ? interval : 45,
            llmProviderMode: providerMode,
            claudeBinPath: binResolved,
            codexBinPath: codexResolved,
            copilotResourcesDir: resDir,
            suggestModel: d.string(forKey: "suggestModel") ?? "claude-sonnet-4-6",
            summaryModel: d.string(forKey: "summaryModel") ?? "claude-opus-4-8",
            classifyModel: d.string(forKey: "classifyModel") ?? "claude-haiku-4-5-20251001",
            codexModel: d.string(forKey: "codexModel") ?? "",
            ffmpegPath: ffmpegResolved,
            dictationDir: (d.string(forKey: "dictationDir")).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultDictationDir,
            callInputDevicePrefs: defaultCallInputPrefs,
            dictatePipelinePath: d.string(forKey: "dictatePipelinePath").flatMap { $0.isEmpty ? nil : $0 } ?? defaultDictatePipeline,
            callOutputDevice: d.string(forKey: "callOutputDevice") ?? "Звонок (AirPods+BH)",
            normalOutputDevice: d.string(forKey: "normalOutputDevice") ?? "Solar AirPods",
            sendToAssistant: d.object(forKey: "sendToAssistant") as? Bool ?? dev,
            layoutSwitchEnabled: d.object(forKey: "layoutSwitchEnabled") as? Bool ?? true,
            layoutSwitchKeycode: (d.object(forKey: "layoutSwitchKeycode") as? Int).flatMap { $0 > 0 ? $0 : nil } ?? 58,
            layoutAutoEnabled: d.object(forKey: "layoutAutoEnabled") as? Bool ?? false,
            publicMode: d.object(forKey: "publicMode") as? Bool ?? !dev,
            screenVisionEnabled: d.object(forKey: "screenVisionEnabled") as? Bool ?? true,
            screenCaptureIntervalSec: { let v = d.double(forKey: "screenCaptureIntervalSec"); return v > 0 ? v : 60 }(),
            companionEnabled: d.object(forKey: "companionEnabled") as? Bool ?? false,
            companionIntervalSec: { let v = d.double(forKey: "companionIntervalSec"); return v > 0 ? v : 180 }(),
            awarenessEnabled: d.object(forKey: "awarenessEnabled") as? Bool ?? false,
            awarenessIntervalSec: { let v = d.double(forKey: "awarenessIntervalSec"); return v > 0 ? v : 300 }(),
            // Хост журнала активности задаёт владелец через defaults (activityServerHost); у всех остальных пусто.
            activityServerHost: d.string(forKey: "activityServerHost") ?? "",   // пусто = журнал активности никуда не шлём
            activityRemotePath: d.string(forKey: "activityRemotePath") ?? "/opt/assistant_activity"
        )
    }
}
