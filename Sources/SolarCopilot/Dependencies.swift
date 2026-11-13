import Foundation

/// Автодетект внешних зависимостей копилота: `claude` (LLM по подписке через
/// Claude/Codex CLI), `ffmpeg` (memo-запись + резолв устройств), whisper-server.
/// Current Codex Desktop distribution is bundled with ChatGPT.app; legacy
/// Codex.app remains supported by CodexCLIProvider.resolveBin.
/// (транскрипция). Для public-раздачи у друга нет окружения Юрия — мастер первого
/// запуска (`AppDelegate.checkReadiness`) показывает, чего не хватает и как доставить.
///
/// Здесь только ДЕТЕКТ. Авто-докачка whisper/ffmpeg — следующий заход
/// (см. `tasks/⬜ solar-copilot-club-product/`).
enum Dependencies {

    struct Report {
        var claudePath: String?      // LLM через Claude Code CLI
        var codexPath: String?       // LLM через Codex CLI
        var ffmpegPath: String?      // ОПЦИОНАЛЬНО: только memo-диктофон (копилот пишет
                                     // через AVAudioEngine, конвертит через afconvert)
        var whisperOK: Bool          // транскрипция — критично
        var providerMode: LLMProviderMode
        /// Копилот рабочий: нужен выбранный LLM + whisper. ffmpeg не входит.
        var allReady: Bool {
            switch providerMode {
            case .claude: return claudePath != nil && whisperOK
            case .codex: return codexPath != nil && whisperOK
            case .auto: return (claudePath != nil || codexPath != nil) && whisperOK
            }
        }
    }

    // MARK: - claude (LLM по подписке через Claude Code CLI)

    /// preferred → типичные пути (через `ClaudeCLIProvider.resolveBin`) → `which`.
    static func resolveClaude(preferred: String) -> String? {
        ClaudeCLIProvider.resolveBin(preferred: preferred) ?? which("claude")
    }

    static func resolveCodex(preferred: String) -> String? {
        CodexCLIProvider.resolveBin(preferred: preferred) ?? which("codex")
    }

    // MARK: - ffmpeg

    static func resolveFfmpeg(preferred: String) -> String? {
        let fm = FileManager.default
        let candidates = [preferred, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for c in candidates where !c.isEmpty && fm.isExecutableFile(atPath: c) { return c }
        return which("ffmpeg")
    }

    // MARK: - whisper (health-check)

    /// Любой HTTP-ответ корня сервера = whisper жив (на `/` он обычно 404, на
    /// `/inference` ждёт POST — нам важен только факт, что порт слушает).
    static func whisperReachable(_ url: URL, timeout: TimeInterval = 3) async -> Bool {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        comps.path = "/"
        comps.query = nil
        guard let root = comps.url else { return false }
        var req = URLRequest(url: root)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse) != nil
        } catch {
            return false
        }
    }

    // MARK: - сводный отчёт

    static func check(config: AppConfig) async -> Report {
        let claude = resolveClaude(preferred: config.claudeBinPath)
        let codex = resolveCodex(preferred: config.codexBinPath)
        let ffmpeg = resolveFfmpeg(preferred: config.ffmpegPath)
        let whisper = await whisperReachable(config.whisperURL)
        return Report(claudePath: claude, codexPath: codex, ffmpegPath: ffmpeg,
                      whisperOK: whisper, providerMode: config.llmProviderMode)
    }

    // MARK: - which (расширенный PATH — GUI-апп из launchd получает урезанный)

    static func which(_ tool: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [tool]
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path = path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        return nil
    }
}
