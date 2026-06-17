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

    private enum Mode { case idle, recordingNormal, recordingToggle, stopping, ignoreRelease }
    private var mode: Mode = .idle
    private var pressTime: CFTimeInterval = 0
    private var rightCmdHeld = false

    private let tapThreshold = 0.4
    private let rightCmdKeycode: Int64 = 54

    var onStatus: ((String) -> Void)?

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
        return true
    }

    func stop() {
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
        if cmdNow && !rightCmdHeld { rightCmdHeld = true; Self.logf("rightCmd PRESS"); onPress() }
        else if !cmdNow && rightCmdHeld { rightCmdHeld = false; Self.logf("rightCmd RELEASE mode=\(mode)"); onRelease() }
    }

    private func onPress() {
        let now = CACurrentMediaTime()
        switch mode {
        case .idle:
            startRecording(); pressTime = now; mode = .recordingNormal
        case .recordingToggle:
            mode = .stopping; stopAndProcess(); mode = .ignoreRelease
        default:
            break
        }
    }

    private func onRelease() {
        switch mode {
        case .recordingNormal:
            let dur = CACurrentMediaTime() - pressTime
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
        if c.start() {
            clip = c
            playSound("Tink")
            showIndicator()
            Self.logf("recording STARTED")
        } else {
            clip = nil
            mode = .idle
            Self.logf("recording FAILED — микрофон недоступен")
            onStatus?("🎙 Диктовка: микрофон недоступен")
        }
    }

    private func stopAndProcess() {
        guard let c = clip else { mode = .idle; return }
        clip = nil
        mode = .stopping
        playSound("Blow")
        hideIndicator()
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

    /// `dictate-pipeline <wav>` → текст на stdout (whisper + фильтр галлюцинаций внутри).
    private func runPipeline(_ wav: URL, _ done: @escaping (String?) -> Void) {
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

    /// Вставка в активное окно: кладём в буфер, шлём Cmd+V, восстанавливаем буфер.
    private func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        Self.logf("paste: AX=\(Self.accessibilityTrusted() ? "выдан" : "НЕТ"), шлю Cmd+V (\(text.count) chars)")
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
        if let saved = saved {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }
    }

    // MARK: - Feedback

    private func playSound(_ name: String) { NSSound(named: NSSound.Name(name))?.play() }

    private let tnGroup = "solar-dictation"
    private var tnBin: String { "/opt/homebrew/bin/terminal-notifier" }

    /// Системное NC-уведомление пробивает fullscreen (как в dictation.lua).
    private func showIndicator() {
        runTN(["-remove", tnGroup])
        runTN(["-title", "🎙 Диктовка", "-message", "Идёт запись (Right Cmd → стоп)",
               "-group", tnGroup, "-ignoreDnD", "-sound", ""])
    }
    private func hideIndicator() { runTN(["-remove", tnGroup]) }

    private func runTN(_ args: [String]) {
        guard FileManager.default.isExecutableFile(atPath: tnBin) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tnBin)
        p.arguments = args
        try? p.run()
    }
}
