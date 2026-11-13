import AppKit
import ApplicationServices
import IOKit.hid

/// Диктовка по правому Cmd (Phase 5, замена `dictation.lua`).
/// • Удержание правого Cmd — push-to-talk (пишем пока зажат).
/// • Короткий тап — toggle (тап старт / тап стоп). Граница 0.4с.
/// Пайплайн: ClipRecorder (mic→wav) → `~/bin/dictate-pipeline` (whisper) →
/// вставка текста в активное окно через Cmd+V. Все события — на main run loop.
///
/// Нужны два TCC-разрешения: **Input Monitoring** (CGEventTap слушает клавиши)
/// и **Accessibility** (постинг Cmd+V). Если не выданы — start() вернёт false.
final class DictationController {
    private let cfg: AppConfig
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var clip: ClipRecorder?
    private var watchdog: Timer?

    private enum Mode { case idle, recordingNormal, recordingToggle, stopping, ignoreRelease }
    private var mode: Mode = .idle
    private var pressEventTS: CGEventTimestamp = 0
    private var rightCmdHeld = false

    private let tapThreshold = 0.4
    private let rightCmdKeycode: Int64 = 54

    var onStatus: ((String) -> Void)?
    /// Старт/стоп записи диктовки наружу (AppDelegate → глаз компаньона: красный + «Диктуй»).
    var onRecording: ((Bool) -> Void)?

    init(cfg: AppConfig) { self.cfg = cfg }

    var isActive: Bool { tap != nil }

    // ─── Диагностика ───
    static let logPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/solar-copilot-dictation.log")

    static func logf(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        if let h = try? FileHandle(forWritingTo: logPath) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: logPath)
        }
    }

    static func permissionReport() -> String {
        "Мониторинг ввода: \(inputMonitoringTrusted() ? "✅ выдан" : "❌ НЕТ")\n"
        + "Универсальный доступ: \(accessibilityTrusted() ? "✅ выдан" : "❌ НЕТ")"
    }

    static func accessibilityTrusted() -> Bool { AXIsProcessTrusted() }

    static func inputMonitoringTrusted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Системные промпты на оба доступа: Мониторинг ввода (IOHID) + Универсальный доступ (AX).
    static func requestPermissions() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Стартует CGEventTap. false → нет Input Monitoring (tapCreate вернул nil).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon = refcon {
                let me = Unmanaged<DictationController>.fromOpaque(refcon).takeUnretainedValue()
                me.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: mask,
                                        callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Self.logf("start: tapCreate=NIL — нет Input Monitoring (или deny-кэш, нужен перезапуск). \(Self.permissionReport())")
            return false
        }
        tap = t
        Self.logf("start: tap СОЗДАН ✅. \(Self.permissionReport())")
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        startWatchdog()
        return true
    }

    /// macOS вырубает CGEventTap по таймауту, если колбэк подвисает (синхронный
    /// engine.start() ~1-2с на старте записи блокирует main). Re-enable в самом колбэке
    /// не всегда срабатывает (отключённый tap может не доставить событие). Сторож раз в
    /// 2с проверяет и оживляет tap → правый Cmd не «умирает» после нескольких диктовок.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, let t = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: t) {
                CGEvent.tapEnable(tap: t, enable: true)
                Self.logf("watchdog: tap был отключён → re-enabled")
            }
        }
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        runLoopSource = nil
        tap = nil
        clip?.stop { _ in }
        clip = nil
        mode = .idle
    }

    // MARK: - Eventtap

    private func handle(type: CGEventType, event: CGEvent) {
        // Система может выключить tap по таймауту — реактивируем.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }
        guard event.getIntegerValueField(.keyboardEventKeycode) == rightCmdKeycode else { return }
        let cmdNow = event.flags.contains(.maskCommand)
        let ts = event.timestamp
        if cmdNow && !rightCmdHeld { rightCmdHeld = true; Self.logf("rightCmd PRESS"); onPress(ts) }
        else if !cmdNow && rightCmdHeld { rightCmdHeld = false; Self.logf("rightCmd RELEASE mode=\(mode)"); onRelease(ts) }
    }

    private func onPress(_ ts: CGEventTimestamp) {
        switch mode {
        case .idle:
            pressEventTS = ts; startRecording(); mode = .recordingNormal
        case .recordingToggle:
            mode = .stopping; stopAndProcess(); mode = .ignoreRelease
        default:
            break
        }
    }

    private func onRelease(_ ts: CGEventTimestamp) {
        switch mode {
        case .recordingNormal:
            // длительность по таймстампам СОБЫТИЙ (не по часам обработчика): синхронный
            // старт движка может на ~2с заблокировать main и задержать обработку release —
            // иначе быстрый тап прочитался бы как удержание. CGEvent.timestamp — в НАНОсекундах.
            let dur = Double(ts &- pressEventTS) / 1_000_000_000.0
            if dur < tapThreshold {
                mode = .recordingToggle            // тап → продолжаем писать, ждём второй тап
            } else {
                stopAndProcess()                   // hold → стоп + пайплайн
            }
        case .ignoreRelease:
            mode = .idle
        default:
            break
        }
    }

    // MARK: - Запись + пайплайн

    private func startRecording() {
        let c = ClipRecorder()
        onRecording?(true)            // глаз красный — намерение (до возможного прогрева движка)
        if c.start() {
            clip = c
            playSound("Tink")         // звучит, когда движок реально готов = сигнал «говори»
            Self.logf("recording STARTED")
        } else {
            clip = nil
            mode = .idle
            onRecording?(false)
            Self.logf("recording FAILED — микрофон недоступен")
            onStatus?("🎙 Диктовка: микрофон недоступен")
        }
    }

    private func stopAndProcess() {
        guard let c = clip else { mode = .idle; return }
        clip = nil
        mode = .stopping
        playSound("Blow")
        onRecording?(false)              // глаз компаньона → обычный (или таймер звонка, если идёт)
        c.stop { [weak self] url in
            guard let self = self else { return }
            guard let url = url else { self.mode = .idle; Self.logf("stop: wav пуст/коротко → пропуск"); return }
            Self.logf("stop: wav=\(url.lastPathComponent), запускаю pipeline")
            self.runPipeline(url) { text in
                self.mode = .idle
                Self.logf("pipeline result: \(text == nil ? "nil" : "\"\(text!.prefix(60))\" (\(text!.count) chars)")")
                if let text = text, !text.isEmpty { self.paste(text) }
            }
        }
    }

    /// wav → текст. У Юрия есть личный `~/bin/dictate-pipeline` (whisper + polish) —
    /// используем его. У друга его НЕТ → встроенный путь: тот же whisper-server :8127,
    /// что и копилот (через `WhisperServerProvider`) + фильтр галлюцинаций. Так диктовка
    /// работает у друга без внешнего скрипта.
    private func runPipeline(_ wav: URL, _ done: @escaping (String?) -> Void) {
        if FileManager.default.isExecutableFile(atPath: cfg.dictatePipelinePath) {
            runExternalPipeline(wav, done)
        } else {
            runBuiltinPipeline(wav, done)
        }
    }

    /// Личный путь Юрия — `~/bin/dictate-pipeline <wav>` → текст на stdout.
    private func runExternalPipeline(_ wav: URL, _ done: @escaping (String?) -> Void) {
        let bin = cfg.dictatePipelinePath
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = [wav.path]
            var env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            env["PATH"] = "\(home)/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            p.environment = env
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            do { try p.run() } catch {
                DispatchQueue.main.async { done(nil) }; return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { done(text) }
        }
    }

    /// Встроенный путь (для друга): wav → whisper-server :8127 → фильтр галлюцинаций.
    private func runBuiltinPipeline(_ wav: URL, _ done: @escaping (String?) -> Void) {
        guard let data = try? Data(contentsOf: wav) else { done(nil); return }
        let provider = WhisperServerProvider(url: cfg.whisperURL, language: cfg.language)
        Task {
            do {
                let text = try await provider.transcribe(wav: data)
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let result = (clean.isEmpty || TextFilter.isHallucination(clean)) ? nil : clean
                await MainActor.run { done(result) }
            } catch {
                Self.logf("builtin pipeline: whisper ошибка — \(error.localizedDescription)")
                await MainActor.run { done(nil) }
            }
        }
    }

    /// Вставка в активное окно: сначала сохраняем расшифровку на диск, затем кладём
    /// её в буфер и шлём Cmd+V. Буфер намеренно НЕ восстанавливаем: некоторые
    /// приложения читают pasteboard асинхронно и при прежнем restore через 0.35с
    /// вставляли старый текст. Последняя диктовка остаётся в clipboard как fallback.
    private func paste(_ text: String) {
        saveLastTranscription(text)

        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(text, forType: .string), pb.string(forType: .string) == text else {
            Self.logf("paste: не удалось записать расшифровку в clipboard; текст сохранён в last-dictation.txt")
            onStatus?("🎙 Диктовка сохранена, но буфер обмена недоступен")
            return
        }

        Self.logf("paste: AX=\(Self.accessibilityTrusted() ? "выдан" : "НЕТ"), clipboard verified, шлю Cmd+V (\(text.count) chars); clipboard оставлен с расшифровкой")
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9   // kVK_ANSI_V
        if let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cghidEventTap)
        }
    }

    /// Durable fallback для случаев, когда фокус окна сменился или приложение не
    /// приняло синтетический Cmd+V. Файл всегда содержит последнюю успешную диктовку.
    private func saveLastTranscription(_ text: String) {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SolarCopilot", isDirectory: true)
        let url = dir.appendingPathComponent("last-dictation.txt")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            Self.logf("saved fallback: \(url.path) (\(text.count) chars)")
        } catch {
            Self.logf("saved fallback FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Feedback

    private func playSound(_ name: String) { NSSound(named: NSSound.Name(name))?.play() }
}
