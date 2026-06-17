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
    var claudeBinPath: String
    var copilotResourcesDir: URL      // persona.md / checklist.json / listen_mode.md
    var suggestModel: String
    var summaryModel: String
    var classifyModel: String

    // Phase 3/4/5 — единый голосовой хаб (замена Hammerspoon).
    var ffmpegPath: String            // запись memo + резолв avfoundation-устройств
    var dictationDir: URL             // папка «Диктовка/» для memo (launchd→Telegram)
    var callInputDevicePrefs: [String] // приоритет устройства копилота/memo (обе стороны)
    var dictatePipelinePath: String   // ~/bin/dictate-pipeline для Right-Cmd диктовки
    var callOutputDevice: String      // Multi-Output для звонка (output-toggle)
    var normalOutputDevice: String    // обычный output (AirPods)
    var sendToAssistant: Bool         // копию записи копилота → Диктовка/ → ассистент (Telegram)

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

    /// persona.md / checklist.json / listen_mode.md живут в copilot/ (iCloud) — там же,
    /// что и MVP. Настраиваемо (product-ready: на другом Mac путь иной).
    static var defaultResourcesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Claude/copilot", isDirectory: true)
    }

    /// Папка «Диктовка/» — memo-файлы кладём сюда, launchd роутит в Telegram.
    static var defaultDictationDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Claude/Диктовка", isDirectory: true)
    }

    static var defaultDictatePipeline: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("bin/dictate-pipeline").path
    }

    /// ПУСТО = копилот пишет с системного входа по умолчанию (надёжно ловит голос).
    /// RecordCall (aggregate «обе стороны») через AVAudioEngine давал ТИШИНУ (−91dB,
    /// баг 12.06) — both-sides сделаем отдельно (ffmpeg-капча как в MVP), не AVAudioEngine.
    static let defaultCallInputPrefs: [String] = []

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
        let bin = d.string(forKey: "claudeBinPath").flatMap { $0.isEmpty ? nil : $0 } ?? defaultClaudeBin
        let resDir: URL
        if let rp = d.string(forKey: "copilotResourcesDir"), !rp.isEmpty {
            resDir = URL(fileURLWithPath: rp, isDirectory: true)
        } else {
            resDir = defaultResourcesDir
        }
        return AppConfig(
            whisperURL: url,
            chunkSeconds: chunk > 0 ? chunk : 20,
            language: lang.isEmpty ? "ru" : lang,
            recordingsDir: recDir,
            assistantEnabled: assistant,
            suggestionIntervalSec: interval > 0 ? interval : 45,
            claudeBinPath: bin,
            copilotResourcesDir: resDir,
            suggestModel: d.string(forKey: "suggestModel") ?? "claude-sonnet-4-6",
            summaryModel: d.string(forKey: "summaryModel") ?? "claude-opus-4-8",
            classifyModel: d.string(forKey: "classifyModel") ?? "claude-haiku-4-5-20251001",
            ffmpegPath: d.string(forKey: "ffmpegPath").flatMap { $0.isEmpty ? nil : $0 } ?? "/opt/homebrew/bin/ffmpeg",
            dictationDir: (d.string(forKey: "dictationDir")).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultDictationDir,
            callInputDevicePrefs: defaultCallInputPrefs,
            dictatePipelinePath: d.string(forKey: "dictatePipelinePath").flatMap { $0.isEmpty ? nil : $0 } ?? defaultDictatePipeline,
            callOutputDevice: d.string(forKey: "callOutputDevice") ?? "Звонок (AirPods+BH)",
            normalOutputDevice: d.string(forKey: "normalOutputDevice") ?? "Solar AirPods",
            sendToAssistant: d.object(forKey: "sendToAssistant") as? Bool ?? true
        )
    }
}
