import AppKit
import Carbon.HIToolbox

/// Меню-бар + плавающая панель + настройки + жизненный цикл. Одна сессия = папка
/// <recordingsDir>/<дата_время>/ с audio.m4a + transcript.txt (+ summary.md на «Стоп»).
/// Phase 2: «мозг» (CopilotBrain) даёт подсказки по ходу и финальную сводку в окне.
/// Плюс фиксированный live-мост (LiveBridge) для подключения ассистента Claude.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let store = TranscriptStore()           // чистый транскрипт → transcript.txt
    private let assistant = TranscriptStore()        // фид ассистента (подсказки + сводка)
    private var recorder: AudioRecorder?
    private var brain: CopilotBrain?
    private let windowController = TranscriptWindowController()
    private let floating = FloatingControlWindowController()
    private let settings = SettingsWindowController()
    private var recording = false
    private var config = AppConfig.load()
    private var currentSessionDir: URL?
    private var sessionStartedAt: Date?

    // Phase 3 — memo-диктофон (замена ⌘F5), независим от копилота
    private var memo: MemoRecorder?
    private var memoHotKey: GlobalHotKey?
    private var memoActive = false

    // Phase 5 — диктовка по правому Cmd (замена dictation.lua)
    private var dictation: DictationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let refresh: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.windowController.refresh(transcript: self.store, assistant: self.assistant)
        }
        store.onChange = refresh
        assistant.onChange = refresh
        floating.onToggle = { [weak self] in self?.toggleRecording() }
        floating.onShowTranscript = { [weak self] in self?.showTranscript() }
        floating.onSettings = { [weak self] in self?.openSettings() }
        floating.onQuit = { [weak self] in self?.quitApp() }
        updateStatusIcon()
        rebuildMenu()
        floating.show()
        startDictation(prompting: false)
        LiveBridge.update(transcript: "", recording: false, sessionDir: nil, startedAt: nil)
    }

    private var dictationRetryTimer: Timer?
    private var dictationRetryUntil: Date?

    /// Старт диктовки по правому Cmd. На запуске prompting=false (без навязчивого
    /// диалога); по клику в меню prompting=true — просим оба TCC-доступа (Мониторинг
    /// ввода + Универсальный доступ) и запускаем авто-повтор активации.
    private func startDictation(prompting: Bool) {
        if dictation == nil {
            let d = DictationController(cfg: AppConfig.load())
            d.onStatus = { [weak self] msg in self?.assistant.append(msg) }
            dictation = d
        }
        if dictation?.start() == true {
            dictationRetryTimer?.invalidate(); dictationRetryTimer = nil
            if prompting { alert("Диктовка включена. Правый Cmd — диктуй в активное окно (удержание = пока зажат, тап = вкл/выкл).") }
            rebuildMenu()
            return
        }
        if prompting {
            DictationController.requestPermissions()       // системные промпты IOHID + AX
            openPrivacyPane("Privacy_ListenEvent")          // Мониторинг ввода
            alert("Дай Solar Copilot доступ в Системные настройки → Конфиденциальность:\n• Мониторинг ввода\n• Универсальный доступ\n\nКак выдашь — диктовка включится сама (повтор активации идёт 2 минуты).")
            dictationRetryUntil = Date().addingTimeInterval(120)
            dictationRetryTimer?.invalidate()
            dictationRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                Task { @MainActor in self?.retryDictation(t) }
            }
        }
        rebuildMenu()
    }

    private func retryDictation(_ t: Timer) {
        if dictation?.start() == true {
            t.invalidate(); dictationRetryTimer = nil
            assistant.append("⌨︎ Диктовка включена (доступ выдан). Правый Cmd готов.")
            rebuildMenu()
        } else if (dictationRetryUntil ?? .distantPast) < Date() {
            t.invalidate(); dictationRetryTimer = nil
        }
    }

    @objc private func enableDictation() { startDictation(prompting: true) }

    /// Диагностика диктовки: показывает статус доступов + tap, лечит deny-кэш перезапуском.
    @objc private func diagnoseDictation() {
        _ = dictation?.start()   // попытка активации (если доступ только что выдан)
        let active = dictation?.isActive == true
        let im = DictationController.inputMonitoringTrusted()
        let ax = DictationController.accessibilityTrusted()
        let a = NSAlert()
        a.messageText = "Диктовка — диагностика"
        a.informativeText = """
        Tap активен: \(active ? "✅ да — правый Cmd работает" : "❌ нет")
        Мониторинг ввода: \(im ? "✅ выдан" : "❌ НЕТ")
        Универсальный доступ: \(ax ? "✅ выдан" : "❌ НЕТ")

        Лог: ~/Library/Logs/solar-copilot-dictation.log
        """
        if active {
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Открыть лог")
            if a.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(DictationController.logPath) }
            return
        }
        if !im || !ax {
            a.informativeText += "\n\nВключи Solar Copilot в обоих списках Конфиденциальности, потом «Перезапустить»."
            a.addButton(withTitle: "Открыть настройки")
            a.addButton(withTitle: "Перезапустить апп")
            a.addButton(withTitle: "Отмена")
            let r = a.runModal()
            if r == .alertFirstButtonReturn {
                DictationController.requestPermissions()
                openPrivacyPane("Privacy_ListenEvent")
            } else if r == .alertSecondButtonReturn { relaunchApp() }
            return
        }
        // доступы есть, но tap мёртв → deny-кэш, лечится только рестартом процесса
        a.informativeText += "\n\nДоступы выданы, но процесс закэшировал отказ — нужен перезапуск аппа."
        a.addButton(withTitle: "Перезапустить апп")
        a.addButton(withTitle: "Отмена")
        if a.runModal() == .alertFirstButtonReturn { relaunchApp() }
    }

    /// Перезапуск: открыть свежий инстанс через 1с и завершить текущий.
    private func relaunchApp() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateStatusIcon() {
        if recording { statusItem.button?.title = memoActive ? "🔴🎙" : "🔴" }
        else { statusItem.button?.title = memoActive ? "🎙●" : "🎙" }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: recording ? L.stop : L.start,
                                action: #selector(toggleRecording), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let show = NSMenuItem(title: L.showTranscript, action: #selector(showTranscript), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let hist = NSMenuItem(title: L.history, action: nil, keyEquivalent: "")
        hist.submenu = historyMenu()
        menu.addItem(hist)

        menu.addItem(.separator())

        // Диктовка по правому Cmd — один пункт: включает доступ / диагностика / перезапуск.
        let dictActive = dictation?.isActive == true
        let dictItem = NSMenuItem(title: dictActive ? "⌨︎ Диктовка (правый Cmd) ✓" : "⌨︎ Диктовка (правый Cmd)…",
                                  action: #selector(diagnoseDictation), keyEquivalent: "")
        dictItem.target = self
        menu.addItem(dictItem)

        let prefs = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let openDir = NSMenuItem(title: L.openFolder, action: #selector(openRecordingsFolder), keyEquivalent: "")
        openDir.target = self
        menu.addItem(openDir)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L.quit, action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        config = AppConfig.load()
        store.clear()
        assistant.clear()

        let sessionDir = config.recordingsDir.appendingPathComponent(AudioRecorder.timestamp(), isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        currentSessionDir = sessionDir
        sessionStartedAt = Date()

        // «Мозг» — опционален (product-ready: Telegram/LLM не обязательны).
        if config.assistantEnabled {
            let llm = ClaudeCLIProvider(binPath: config.claudeBinPath)
            let b = CopilotBrain(llm: llm, cfg: config)
            b.onAssistant = { [weak self] line in self?.assistant.append(line) }
            b.onStatus = { [weak self] line in self?.assistant.append(line) }
            brain = b
            b.start()
        } else {
            brain = nil
        }

        let provider = WhisperServerProvider(url: config.whisperURL, language: config.language)
        let rec = AudioRecorder(chunkSeconds: config.chunkSeconds, provider: provider, sessionDir: sessionDir,
                                inputDevicePrefs: config.callInputDevicePrefs)
        rec.onTranscript = { [weak self] text in
            guard let self = self, !TextFilter.isHallucination(text) else { return }
            self.store.append(text)
            self.brain?.appendTranscript(text)
            self.syncFiles()
        }
        rec.onError = { [weak self] msg in self?.handleRecorderError(msg) }
        rec.onSaved = { [weak self] audioURL in
            guard let self = self else { return }
            self.syncFiles()
            self.store.append(L.savedTo(audioURL.deletingLastPathComponent().path))
            self.routeToAssistant(audioURL)
        }
        recorder = rec
        recording = true
        updateStatusIcon()
        rebuildMenu()
        floating.setRecording(true)
        syncFiles()
        rec.requestPermissionAndStart()
    }

    private func stopRecording() {
        recorder?.stop()
        recorder = nil
        brain?.stop()
        recording = false
        updateStatusIcon()
        rebuildMenu()
        floating.setRecording(false)
        syncFiles()
        generateSummary()
    }

    /// Копия записи копилота → Диктовка/ → launchd-watcher транскрибирует и шлёт
    /// ассистенту в Telegram (work→@spb_claude_bot / family→@altron_analyst_bot).
    /// «Всё, что записал — уходит в ассистента» (по умолчанию вкл).
    private func routeToAssistant(_ audioURL: URL) {
        guard config.sendToAssistant else { return }
        let dir = config.dictationDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(MemoRecorder.memoFilename(sessionStartedAt ?? Date()))
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: audioURL, to: dest)
            assistant.append("📨 Запись отправлена ассистенту в Telegram (\(dest.lastPathComponent))")
        } catch {
            assistant.append("⚠️ Не скопировать запись в Диктовка/: \(error.localizedDescription)")
        }
    }

    // MARK: - Memo-диктофон (Phase 3, замена ⌘F5)

    @objc private func toggleMemo() { memoActive ? stopMemo() : startMemo() }

    private func startMemo() {
        let cfg = AppConfig.load()
        guard let dev = AudioDevices.avfoundationIndex(ffmpeg: cfg.ffmpegPath,
                                                       preferring: cfg.callInputDevicePrefs) else {
            alert("Не нашёл аудиоустройство для записи (ffmpeg). Проверь RecordCall/микрофон.")
            return
        }
        let m = MemoRecorder(ffmpeg: cfg.ffmpegPath)
        m.onSaved = { [weak self] url in self?.finishMemo(saved: url, error: nil) }
        m.onError = { [weak self] msg in self?.finishMemo(saved: nil, error: msg) }
        memo = m
        memoActive = true
        updateStatusIcon(); rebuildMenu(); floating.setMemo(true)
        playSound("Tink")
        m.start(dictationDir: cfg.dictationDir, deviceArg: dev.arg, at: Date())
    }

    private func stopMemo() {
        memo?.stop()   // onSaved/onError завершат состояние и сбросят флаги
    }

    private func finishMemo(saved: URL?, error: String?) {
        memo = nil
        memoActive = false
        updateStatusIcon(); rebuildMenu(); floating.setMemo(false)
        if let url = saved {
            playSound("Pop")
            assistant.append("🎙 Диктофон → \(url.lastPathComponent). Транскрипт уйдёт в Telegram автоматически.")
        } else if let e = error {
            alert(e)
        }
    }

    private func playSound(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }

    /// Output-toggle (порт output_toggle.lua): системный звук на Multi-Output
    /// «Звонок (AirPods+BH)» (слышно в AirPods + копия в BlackHole для записи
    /// обеих сторон) ↔ обратно на чистые AirPods.
    @objc private func toggleCallOutput() {
        let cfg = AppConfig.load()
        let current = AudioDevices.defaultOutputName()
        if current.lowercased().contains(cfg.callOutputDevice.lowercased()) {
            if let air = AudioDevices.airpodsOutputID(preferredName: cfg.normalOutputDevice) {
                AudioDevices.setDefaultOutput(id: air.id)
                playSound("Pop")
                assistant.append("🎧 Звук → \(air.name)")
            } else {
                alert("AirPods не найдены среди output-устройств.")
            }
        } else {
            if let call = AudioDevices.outputDeviceID(named: cfg.callOutputDevice) {
                AudioDevices.setDefaultOutput(id: call.id)
                playSound("Tink")
                assistant.append("📞 Звук → \(call.name) (обе стороны пишутся через RecordCall)")
            } else {
                alert("Multi-Output «\(cfg.callOutputDevice)» не найден. Создай его в Audio MIDI Setup.")
            }
        }
    }

    /// На «Стоп» — финальная сводка от «мозга» (Opus) в фид ассистента + summary.md.
    private func generateSummary() {
        guard let b = brain else { return }
        brain = nil
        let full = store.plainText
        guard !full.isEmpty else { return }
        let dir = currentSessionDir
        assistant.append(L.preparingSummary)
        Task { @MainActor in
            let summary = await b.finalSummary(fullTranscript: full)
            self.assistant.append("──────────\n\(summary)")
            if let dir = dir {
                try? summary.data(using: .utf8)?.write(to: dir.appendingPathComponent("summary.md"))
            }
            self.windowController.show(transcript: self.store, assistant: self.assistant)
        }
    }

    /// Пишет транскрипт в <sessionDir>/transcript.txt и в фиксированный live-мост.
    private func syncFiles() {
        if let dir = currentSessionDir {
            let text = store.plainText
            if !text.isEmpty {
                try? text.data(using: .utf8)?.write(to: dir.appendingPathComponent("transcript.txt"))
            }
        }
        LiveBridge.update(transcript: store.plainText, recording: recording,
                          sessionDir: currentSessionDir, startedAt: sessionStartedAt)
    }

    private func handleRecorderError(_ message: String) {
        stopRecording()
        alert(message)
    }

    @objc private func showTranscript() {
        windowController.show(transcript: store, assistant: assistant)
    }

    /// Контекст звонка / заметка по ходу (заменяет TG-инпут MVP). Первая фраза —
    /// контекст + детект режима, дальше — заметки. «я веду» / «я слушаю» — режим.
    @objc private func openContextDialog() {
        guard let b = brain, recording else {
            alert("Сначала начни запись — тогда контекст и заметки уйдут в подсказки.")
            return
        }
        let a = NSAlert()
        a.messageText = L.contextTitle
        a.informativeText = L.contextInfo
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Отмена")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        a.accessoryView = field
        a.window.initialFirstResponder = field
        if a.runModal() == .alertFirstButtonReturn {
            b.provideInput(field.stringValue)
        }
    }

    @objc private func openSettings() {
        settings.show()
    }

    /// Подменю «История сессий»: последние 15 папок записей, 📝 = есть сводка.
    private func historyMenu() -> NSMenu {
        let m = NSMenu()
        let dir = AppConfig.load().recordingsDir
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles])) ?? []
        let folders = items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .prefix(15)
        if folders.isEmpty {
            let it = NSMenuItem(title: "пока пусто", action: nil, keyEquivalent: "")
            it.isEnabled = false
            m.addItem(it)
            return m
        }
        for f in folders {
            let hasSummary = fm.fileExists(atPath: f.appendingPathComponent("summary.md").path)
            let it = NSMenuItem(title: f.lastPathComponent + (hasSummary ? "  📝" : ""),
                                action: #selector(openHistoryItem(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = f
            m.addItem(it)
        }
        return m
    }

    @objc private func openHistoryItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let summary = url.appendingPathComponent("summary.md")
        NSWorkspace.shared.open(fm_exists(summary) ? summary : url)
    }

    private func fm_exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @objc private func openRecordingsFolder() {
        let dir = AppConfig.load().recordingsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func quitApp() {
        recorder?.stop()
        NSApp.terminate(nil)
    }

    private func alert(_ message: String) {
        let a = NSAlert()
        a.messageText = L.appName
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
