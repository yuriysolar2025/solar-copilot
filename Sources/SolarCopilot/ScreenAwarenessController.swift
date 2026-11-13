import AppKit

/// Тихий наблюдатель рабочего стола. Периодически смотрит на экран, распознаёт
/// КРАТКО «над каким проектом Юрий работает и что сделано», пишет в локальный журнал
/// и шлёт на сервер — чтобы @spb_claude_bot держал это в общем контексте.
/// БЕЗ пузырей (тихий режим). Во время звонка на паузе (копилот сам ведёт транскрипт).
/// Приватность: пропускает чувствительные приложения (пароли/банк); opt-in.
@MainActor
final class ScreenAwarenessController {
    private let llm: LLMProvider
    private let cfg: AppConfig

    private var timer: Timer?
    private var enabled = false
    private var recording = false
    private var busy = false
    private var lastNote = ""
    private var lastLogAt = Date.distantPast
    private let heartbeatSec: TimeInterval = 900   // переотмечать то же занятие раз в ~15 мин (для тайм-трекинга)

    /// Чувствительные приложения — не наблюдаем (видно пароли/деньги).
    private let sensitiveBundleIDs: Set<String> = [
        "com.1password.1password", "com.1password.6", "com.agilebits.onepassword7",
        "com.apple.keychainaccess", "com.lastpass.LastPass", "in.sinew.Walletx",
    ]

    init(llm: LLMProvider, cfg: AppConfig) {
        self.llm = llm
        self.cfg = cfg
    }

    // MARK: - Управление

    func setEnabled(_ on: Bool) {
        enabled = on
        if on && !recording { start() } else { stop() }
    }

    /// Во время записи звонка наблюдатель молчит — копилот и так ведёт транскрипт.
    func setRecording(_ on: Bool) {
        recording = on
        if on { stop() } else if enabled { start() }
    }

    private func start() {
        timer?.invalidate()
        let iv = max(120.0, cfg.awarenessIntervalSec)
        timer = Timer.scheduledTimer(withTimeInterval: iv, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // первый замер чуть погодя после старта
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.tick() }
        AudioRecorder.log("awareness: включён (интервал \(Int(iv))с)")
    }

    private func stop() { timer?.invalidate(); timer = nil }

    // MARK: - Цикл наблюдения

    private func tick() {
        guard enabled, !busy, !recording else { return }
        // Юрия нет за маком (ночь/спящий дисплей/залочено/долгий простой) → не жжём vision.
        if SystemIdle.awayFromMac() {
            AudioRecorder.log("awareness: пропуск — экран спит/залочен/нет активности")
            return
        }
        // приватность: пропуск чувствительных приложений
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           sensitiveBundleIDs.contains(front) {
            AudioRecorder.log("awareness: пропуск — чувствительное приложение (\(front))")
            return
        }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            let shot = await bg { ScreenCapturer.capture()?.path }
            guard enabled, !recording, let shot = shot else { return }
            guard let note = await distill(screenshot: shot) else { return }
            record(note)
        }
    }

    private func distill(screenshot: String) async -> String? {
        let prev = lastNote.isEmpty ? "пока нет" : lastNote
        let prompt = """
        Ты — фоновый наблюдатель экрана Юрия. По скриншоту определи КРАТКО и фактически, чем он
        сейчас РЕАЛЬНО занят — что бы это ни было: работа (какой проект/код/задача) ИЛИ отдых
        (аниме, сериал, фильм, YouTube, игра, чтение, соцсети). Если на экране есть название
        тайтла/видео/сайта — укажи его.

        Прошлая запись (если сейчас по сути то же самое — верни РОВНО слово: same):
        \(prev)

        Ответь ОДНОЙ строкой, без преамбулы и markdown, в формате:
        ЯРЛЫК: <короткий устойчивый ключ занятия, 2-4 слова — ОДИНАКОВЫЙ, пока занимаешься тем же, даже если детали меняются: напр. «Solar Copilot», «The Last of Us», «Денис/Atomy», «Полушин окошки»> | ЗАНЯТ: <одной фразой что делает> | ЭКРАН: <приложение/сайт/тайтл> | ДЕТАЛИ: <работа — прогресс/блокер; видео — серия/эпизод; иначе ->

        Только если экран пустой, заблокирован или совсем не разобрать — верни РОВНО слово: skip.
        Не выдумывай — только то, что реально видно (включая названия аниме/сериалов/видео).
        """
        do {
            // Фоновый экстрактор «что на экране» — Haiku (classifyModel) хватает, а лимит
            // бережёт сильно vs Sonnet (крутится раз в 5 мин весь день).
            return try await llm.complete(prompt: prompt, imagePaths: [screenshot],
                                          model: cfg.classifyModel, timeout: 90)
        } catch {
            AudioRecorder.log("awareness distill error: \(error.localizedDescription)")
            return nil
        }
    }

    private func record(_ raw: String) {
        let note = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = note.lowercased()
        // «same» — занятие не изменилось: периодически переотмечаем (heartbeat), чтобы
        // агрегатор времени видел, что активность продолжается, и отличал её от перерыва.
        if low == "same" {
            if !lastNote.isEmpty, Date().timeIntervalSince(lastLogAt) >= heartbeatSec {
                emit(lastNote)
            }
            return
        }
        // отсев пустого / skip / ошибок аутентификации claude
        guard !note.isEmpty, low != "skip", note.count < 600,
              !low.contains("authenticate"), !low.contains("api error"),
              !low.contains("organization has disabled"), !low.contains("invalid api key") else {
            return
        }
        lastNote = note
        emit(note)
    }

    private func emit(_ note: String) {
        lastLogAt = Date()
        let line = "\(Self.stamp()) \(note)"
        appendLocal(line)
        ship(line)
        AudioRecorder.log("awareness: \(note.prefix(160))")
    }

    // MARK: - Журнал (локально + сервер)

    private func appendLocal(_ line: String) {
        let dir = Self.activityDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("\(Self.today()).md")
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: f)
        }
    }

    /// Шлём строку на сервер (только машина Юрия). base64 — чтобы не возиться с
    /// кавычками/переводами строк в ssh-команде. Идёт в фоне, ошибки только в лог.
    private func ship(_ line: String) {
        guard !cfg.publicMode else { return }          // у друга не шлём
        let host = cfg.activityServerHost
        let remote = cfg.activityRemotePath
        guard !host.isEmpty, !remote.isEmpty else { return }
        let b64 = Data((line + "\n").utf8).base64EncodedString()
        let remoteFile = "\(remote)/\(Self.today()).md"
        let cmd = "mkdir -p '\(remote)' && printf %s '\(b64)' | base64 -d >> '\(remoteFile)'"
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-o", "ConnectTimeout=10", "-o", "BatchMode=yes", host, cmd]
            p.standardOutput = FileHandle.nullDevice
            let errPipe = Pipe()
            p.standardError = errPipe
            do {
                try p.run(); p.waitUntilExit()
                if p.terminationStatus != 0 {
                    let e = String(data: (try? errPipe.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
                    AudioRecorder.log("awareness ship rc=\(p.terminationStatus): \(e.prefix(160))")
                }
            } catch {
                AudioRecorder.log("awareness ship не запустился: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Утилиты

    static var activityDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SolarCopilot/activity", isDirectory: true)
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let stampFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static func today() -> String { dayFmt.string(from: Date()) }
    static func stamp() -> String { stampFmt.string(from: Date()) }

    private nonisolated func bg<T: Sendable>(_ work: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .utility).async { c.resume(returning: work()) }
        }
    }
}
