import AppKit
import Carbon.HIToolbox

/// Меню-бар + плавающая панель + настройки + жизненный цикл. Одна сессия = папка
/// <recordingsDir>/<дата_время>/ с audio.m4a + transcript.txt (+ summary.md на «Стоп»).
/// Phase 2: «мозг» (CopilotBrain) даёт подсказки по ходу и финальную сводку в окне.
/// Плюс фиксированный live-мост (LiveBridge) для подключения ассистента Claude.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let recordingActivityLock = URL(fileURLWithPath: "/tmp/solar-copilot-recording.pid")
    private var statusItem: NSStatusItem?
    private let store = TranscriptStore()           // чистый транскрипт → transcript.txt
    private let assistant = TranscriptStore()        // фид ассистента (подсказки + сводка)
    private var recorder: AudioRecorder?
    private var brain: CopilotBrain?
    private let windowController = TranscriptWindowController()
    private let dictationHistoryWindow = DictationHistoryWindowController()
    private let settings = SettingsWindowController()
    private var recording = false
    private var transcriptionDegraded = false
    private var stressMode = false
    private var config = AppConfig.load()
    private var currentSessionDir: URL?
    private var sessionStartedAt: Date?
    private var callMarkers: [String] = []
    private var menuBarEnabled: Bool {
        UserDefaults.standard.object(forKey: "solarMenuBarEnabled") as? Bool ?? false
    }

    // Phase 3 — memo-диктофон (замена ⌘F5), независим от копилота
    private var memo: MemoRecorder?
    private var memoHotKey: GlobalHotKey?
    private var memoActive = false

    // Phase 5 — диктовка по правому Cmd (замена dictation.lua)
    private var dictation: DictationController?

    // Layout — переключатель раскладки по левому Option (замена Punto Switcher)
    private var layoutSwitch: LayoutSwitchController?

    // Legacy-десктоп-компаньон. Визуально заменён Solar Island; держим класс для отката.
    private var companion: DesktopCompanionController?

    // Осведомлённость ассистента — тихий наблюдатель экрана → @spb_claude_bot
    private var awareness: ScreenAwarenessController?

    // Solar Island — верхняя капсула статусов/действий Copilot.
    private var solarIsland: SolarIslandController?

    // Активный голосовой Альтрон: direct GPT Realtime + MiniMax Altron TTS.
    private var realtimeVoice: RealtimeVoiceAssistant?

    // Пассивный локальный детектор работает только внутри включённого Altron Live.
    // OFF — жёсткая граница: ни Realtime, ни wake-word не держат микрофон.
    private var wakeWordDetector: WakeWordDetector?
    private var altronLiveEnabled: Bool {
        UserDefaults.standard.object(forKey: "altronLiveEnabled") as? Bool ?? false
    }
    private var wakeWordEnabled: Bool {
        altronLiveEnabled
    }

    // Автозапись звонков: Zoom/Telegram/FaceTime/браузер взяли микрофон → старт копилота.
    private let callDetector = CallAutoDetector()
    private var autoRecording = false   // запись запущена детектором → он же её и остановит
    private var callAutoEnabled: Bool {
        UserDefaults.standard.object(forKey: "callAutoRecordEnabled") as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        stressMode = args.contains("--stress-record")
        if menuBarEnabled {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        let refresh: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.windowController.refresh(transcript: self.store, assistant: self.assistant)
        }
        store.onChange = refresh
        assistant.onChange = refresh
        updateStatusIcon()
        rebuildMenu()
        startDictation(prompting: false)
        startLayoutSwitch()
        ensureWhisperRunning()
        recoverOrphanedRecordings()
        LiveBridge.update(transcript: "", recording: false, sessionDir: nil, startedAt: nil)
        maybeShowReadinessOnFirstRun()
        schedulePendingChunkRecovery()
        if UserDefaults.standard.object(forKey: "solarIslandEnabled") as? Bool ?? true {
            ensureSolarIsland()?.show()
        }
        if args.contains("--voice-live") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.toggleRealtimeVoice()
            }
        }
        if altronLiveEnabled && !args.contains("--voice-live") {
            ensureRealtimeVoice().prewarm()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.startWakeWordDetector()
            }
        }
        if args.contains("--show-dictation-history") {
            DispatchQueue.main.async { [weak self] in self?.showDictationHistory() }
        }
        ensureAwareness()           // тихий наблюдатель экрана (если включён)
        startCallDetector()
        if stressMode {
            let seconds = stressDuration(from: args)
            AudioRecorder.log("STRESS start requested duration=\(Int(seconds))s")
            startRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self = self, self.recording else { return }
                AudioRecorder.log("STRESS duration reached — stopping")
                self.stopRecording()
            }
        }
    }

    /// Старт переключателя раскладки (левый Option). Делит TCC с диктовкой
    /// (Input Monitoring + Accessibility) — отдельного промпта не нужно. Если доступ
    /// ещё не выдан, tap не создастся; перезапустится из retryDictation, когда доступ
    /// появится. Управляется флагом config.layoutSwitchEnabled.
    private func startLayoutSwitch() {
        guard AppConfig.load().layoutSwitchEnabled else {
            layoutSwitch?.stop(); layoutSwitch = nil; rebuildMenu(); return
        }
        if layoutSwitch == nil {
            let l = LayoutSwitchController(cfg: AppConfig.load())
            l.onStatus = { [weak self] msg in self?.assistant.append(msg) }
            layoutSwitch = l
        }
        _ = layoutSwitch?.start()
        rebuildMenu()
    }

    /// Вкл/выкл переключателя раскладки из меню.
    @objc private func toggleLayoutSwitch() {
        let d = UserDefaults.standard
        let now = AppConfig.load().layoutSwitchEnabled
        d.set(!now, forKey: "layoutSwitchEnabled")
        if now {
            layoutSwitch?.stop(); layoutSwitch = nil
            assistant.append("⌨︎ Переключатель раскладки выключен")
        } else {
            startLayoutSwitch()
            let ok = layoutSwitch?.isActive == true
            assistant.append(ok
                ? "⌨︎ Переключатель раскладки включён. Левый Option — конвертирует слово/выделение."
                : "⌨︎ Раскладка: нужен доступ «Мониторинг ввода» (тот же, что у диктовки). Включи диктовку — заработает.")
        }
        rebuildMenu()
    }

    /// Вкл/выкл автомат раскладки (Phase 2). Пересоздаёт контроллер, чтобы он
    /// перечитал флаг из конфига. По умолчанию выкл (opt-in — может ложно срабатывать).
    @objc private func toggleLayoutAuto() {
        let d = UserDefaults.standard
        let now = AppConfig.load().layoutAutoEnabled
        d.set(!now, forKey: "layoutAutoEnabled")
        layoutSwitch?.stop(); layoutSwitch = nil
        startLayoutSwitch()
        if !now {
            assistant.append(AutoLayoutEngine.available
                ? "⌨︎ Автомат раскладки включён — слова в неверной раскладке исправляются на лету. В терминале/IDE и полях паролей не вмешивается."
                : "⚠️ Автомат включён, но в системе нет проверки орфографии RU. System Settings → Клавиатура → Текст → добавь русский, иначе автомат не сработает.")
        } else {
            assistant.append("⌨︎ Автомат раскладки выключен. Ручной режим (левый Option) работает как прежде.")
        }
        rebuildMenu()
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
            d.onRecording = { [weak self] on in
                self?.companion?.setDictating(on)
                self?.solarIsland?.setDictating(on)
            }
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
            startLayoutSwitch()   // тот же доступ — поднимаем и переключатель раскладки
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
        guard let statusItem else { return }
        if recording { statusItem.button?.title = memoActive ? "🔴🎙" : "🔴" }
        else { statusItem.button?.title = memoActive ? "🎙●" : "🎙" }
    }

    // MARK: - Готовность копилота (мастер первого запуска / диагностика зависимостей)

    /// Проверяет claude (подсказки/сводка по подписке) / ffmpeg / whisper и показывает,
    /// чего не хватает другу для работы копилота. Переключатель раскладки от этого
    /// не зависит — он автономен.
    @objc private func checkReadiness() {
        let cfg = AppConfig.load()
        Task { @MainActor in
            let r = await Dependencies.check(config: cfg)
            self.showReadinessAlert(r)
        }
    }

    private func showReadinessAlert(_ r: Dependencies.Report) {
        func mark(_ ok: Bool) -> String { ok ? "✅" : "❌" }

        // whisper детальнее: сервер слушает / установлен но не поднят / нет модели / нет бинаря
        let serverBin = WhisperManager.resolveServerBin()
        let modelOK = WhisperManager.shared.modelInstalled()
        let whisperLine: String
        if r.whisperOK { whisperLine = "✅ whisper — расшифровка речи (сервер слушает)" }
        else if serverBin != nil && modelOK { whisperLine = "⚠️ whisper установлен, но не запущен — апп поднимет сам" }
        else if serverBin != nil { whisperLine = "❌ whisper — нет модели (скачать ~1.6 ГБ)" }
        else { whisperLine = "❌ whisper — нет whisper-server (brew install whisper-cpp)" }

        let lines = [
            "\(mark(r.claudePath != nil)) Claude Code — LLM через Claude"
                + (r.claudePath.map { "\n     \($0)" } ?? ""),
            "\(mark(r.codexPath != nil)) Codex — запасной/основной LLM"
                + (r.codexPath.map { "\n     \($0)" } ?? ""),
            whisperLine,
            "\(r.ffmpegPath != nil ? "✅" : "◻️") ffmpeg — опционально (только диктофон-в-файл; запись копилота от него не зависит)",
        ]
        var todo: [String] = []
        if r.claudePath == nil && r.providerMode != .codex {
            todo.append("• Claude Code: поставь с claude.ai/code, затем в Терминале выполни `claude login` своей подпиской Claude.")
        }
        if r.codexPath == nil && r.providerMode != .claude {
            todo.append("• Codex: установи/открой Codex.app и войди в аккаунт.")
        }
        if !r.whisperOK {
            if serverBin == nil { todo.append("• whisper-server: `brew install whisper-cpp` (нужен Homebrew — brew.sh).") }
            else if !modelOK { todo.append("• Модель whisper не скачана — нажми «Скачать модель» (~1.6 ГБ, один раз).") }
        }

        let a = NSAlert()
        a.messageText = r.allReady ? "Копилот готов к работе ✅" : "Готовность копилота"
        var info = lines.joined(separator: "\n")
        if !todo.isEmpty { info += "\n\n── Чего не хватает ──\n" + todo.joined(separator: "\n") }
        info += "\n\nℹ️ Переключатель раскладки (левый Option) работает независимо от этого списка."
        a.informativeText = info

        let needModel = serverBin != nil && !modelOK && !r.whisperOK && !WhisperManager.shared.downloading
        if needModel { a.addButton(withTitle: "Скачать модель (~1.6 ГБ)") }
        a.addButton(withTitle: "Проверить снова")
        a.addButton(withTitle: "OK")
        let resp = a.runModal()
        if needModel {
            if resp == .alertFirstButtonReturn { downloadWhisperModel() }
            else if resp == .alertSecondButtonReturn { checkReadiness() }
        } else if resp == .alertFirstButtonReturn {
            checkReadiness()
        }
    }

    private var lastWhisperPct = -1

    /// Докачка whisper-модели с прогрессом в иконке меню-бара; по готовности — старт
    /// whisper-server. Бинарь whisper-server должен быть (brew install whisper-cpp).
    @objc private func downloadWhisperModel() {
        guard WhisperManager.resolveServerBin() != nil else {
            alert("Сначала установи whisper-server: `brew install whisper-cpp` (нужен Homebrew — brew.sh).")
            return
        }
        guard !WhisperManager.shared.downloading else { alert("Загрузка модели уже идёт."); return }
        assistant.append("⬇️ Качаю модель whisper (~1.6 ГБ). Можно продолжать — уведомлю по готовности.")
        lastWhisperPct = -1
        WhisperManager.shared.downloadModel(progress: { [weak self] p in
            guard let self = self else { return }
            let pct = Int(p * 100)
            if pct != self.lastWhisperPct, pct % 5 == 0 {
                self.lastWhisperPct = pct
                self.statusItem?.button?.title = "⬇️\(pct)%"
            }
        }, done: { [weak self] result in
            guard let self = self else { return }
            self.updateStatusIcon()
            switch result {
            case .success:
                let ok = WhisperManager.shared.startServer(config: AppConfig.load())
                self.alert(ok ? "✅ whisper готов — расшифровка работает."
                              : "Модель скачана, но whisper-server не запустился. Проверь `brew install whisper-cpp`.")
            case .failure(let e):
                self.alert("Не удалось скачать модель: \(e.localizedDescription)")
            }
        })
    }

    /// На машине друга (public): если whisper-порт молчит, поднять свой whisper-server
    /// (когда бинарь+модель есть). На машине Юрия не трогаем — его launchd уже слушает.
    private func ensureWhisperRunning() {
        let cfg = AppConfig.load()
        guard cfg.publicMode else { return }
        Task { @MainActor in
            if await Dependencies.whisperReachable(cfg.whisperURL) { return }
            if WhisperManager.resolveServerBin() != nil, WhisperManager.shared.modelInstalled() {
                WhisperManager.shared.startServer(config: cfg)
            }
        }
    }

    /// На первом запуске в public-режиме (у друга), если что-то не готово — показать
    /// мастер один раз (флаг didShowReadiness).
    private func maybeShowReadinessOnFirstRun() {
        guard AppConfig.load().publicMode else { return }
        let d = UserDefaults.standard
        guard !d.bool(forKey: "didShowReadiness") else { return }
        d.set(true, forKey: "didShowReadiness")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.checkReadiness()
        }
    }

    // MARK: - Десктоп-компаньон

    @discardableResult
    private func ensureCompanion() -> DesktopCompanionController? {
        if let c = companion { return c }
        let cfg = AppConfig.load()
        let c = DesktopCompanionController(llm: LLMProviders.make(config: cfg), cfg: cfg)
        c.onToggleRecord = { [weak self] in self?.toggleRecording() }
        c.onShowTranscript = { [weak self] in self?.showTranscript() }
        c.onSettings = { [weak self] in self?.openSettings() }
        c.onQuit = { [weak self] in self?.quitApp() }
        c.onToggleChatter = { [weak self] in self?.toggleChatter() }
        companion = c
        return c
    }

    @discardableResult
    private func ensureSolarIsland() -> SolarIslandController? {
        if let island = solarIsland { return island }
        let island = SolarIslandController()
        island.onShowTranscript = { [weak self] in self?.showTranscript() }
        island.onAction = { [weak self] id in
            if id == "voice" {
                self?.toggleRealtimeVoice()
                return
            }
            if id == "record" {
                self?.toggleRecording()
                return
            }
            if id == "open" {
                self?.showTranscript()
                return
            }
            if id == "history" {
                self?.showDictationHistory()
                return
            }
            if id == "remember" {
                self?.markCallMoment(kind: "важно")
                return
            }
            if id == "task" {
                self?.markCallMoment(kind: "задача/follow-up")
                return
            }
            self?.assistant.append("🏝 Solar Island action: \(id)")
            if id == "summary" { self?.showTranscript() }
        }
        island.onDrop = { [weak self] event in
            let title = event.title ?? "drop"
            let body = String((event.body ?? "").prefix(260))
            self?.assistant.append("🏝 Solar Island получил вход: \(title)\(body.isEmpty ? "" : " — \(body)")")
        }
        solarIsland = island
        return island
    }

    private func ensureRealtimeVoice() -> RealtimeVoiceAssistant {
        if let realtimeVoice { return realtimeVoice }
        let voice = RealtimeVoiceAssistant()
        voice.onState = { [weak self] state, text in
            guard let self else { return }
            self.solarIsland?.setVoiceAssistant(self.altronLiveEnabled, status: text)
            self.assistant.append("🎙 \(text)")
            if !state.isActive, self.altronLiveEnabled {
                self.wakeWordDetector?.setConversationMode(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.startWakeWordDetector()
                }
            }
            self.rebuildMenu()
        }
        // Пока Realtime-сессия активна, продолжения слушает её собственный VAD.
        // Второй Apple Speech listener конкурировал за тот же микрофон.
        voice.onConversationReady = nil
        voice.onTranscript = { [weak self] text in self?.assistant.append(text) }
        realtimeVoice = voice
        return voice
    }

    @objc private func toggleRealtimeVoice() {
        let voice = ensureRealtimeVoice()
        if altronLiveEnabled {
            UserDefaults.standard.set(false, forKey: "altronLiveEnabled")
            wakeWordDetector?.stop()
            voice.stop()
            solarIsland?.setVoiceAssistant(false, status: "Альтрон Live выключен")
            assistant.append("🎙 Альтрон Live выключен — микрофон остановлен")
        } else {
            UserDefaults.standard.set(true, forKey: "altronLiveEnabled")
            wakeWordDetector?.stop()
            voice.prewarm()
            solarIsland?.setVoiceAssistant(true, status: "Жду слово «Альтрон»")
            startWakeWordDetector()
            assistant.append("🎙 Альтрон Live включён — жду слово «Альтрон»")
        }
        rebuildMenu()
    }

    private func ensureWakeWordDetector() -> WakeWordDetector {
        if let wakeWordDetector { return wakeWordDetector }
        let detector = WakeWordDetector()
        detector.onActivation = { [weak self] in
            // Token preparation is safe while Apple Speech still owns input;
            // native microphone capture starts only from onWake after stopPipeline.
            self?.ensureRealtimeVoice().prewarm()
        }
        detector.onWake = { [weak self] command in
            guard let self else { return }
            self.assistant.append(command.isEmpty ? "🎙 Альтрон: имя услышано" : "🎙 Альтрон: \(command)")
            let voice = self.ensureRealtimeVoice()
            if command.isEmpty {
                voice.start()
            } else if voice.state.isActive {
                voice.submit(command: command)
            } else {
                voice.start(command: command)
            }
        }
        detector.onStatus = { [weak self] text in
            guard let self else { return }
            if self.realtimeVoice?.state.isActive != true {
                self.solarIsland?.setVoiceAssistant(self.altronLiveEnabled, status: text)
            }
            self.assistant.append("🎙 \(text)")
            self.rebuildMenu()
        }
        wakeWordDetector = detector
        return detector
    }

    private func startWakeWordDetector() {
        guard altronLiveEnabled, realtimeVoice?.state.isActive != true else { return }
        ensureWakeWordDetector().start()
    }

    @objc private func toggleWakeWordDetector() {
        toggleRealtimeVoice()
    }

    @objc private func toggleSolarIsland() {
        let on = !(UserDefaults.standard.object(forKey: "solarIslandEnabled") as? Bool ?? true)
        UserDefaults.standard.set(on, forKey: "solarIslandEnabled")
        if on {
            ensureSolarIsland()?.show()
            assistant.append("🏝 Solar Island включён — верхняя капсула и локальный bridge :8765.")
        } else {
            solarIsland?.hide()
            assistant.append("🏝 Solar Island выключен.")
        }
        rebuildMenu()
    }

    @objc private func toggleSolarIslandQuietMode() {
        let on = !(UserDefaults.standard.object(forKey: "solarIslandQuietMode") as? Bool ?? false)
        UserDefaults.standard.set(on, forKey: "solarIslandQuietMode")
        ensureSolarIsland()?.setQuietMode(on)
        assistant.append(on
            ? "🏝 Solar Island: тихий режим включён — события логируются, но капсула не прыгает на каждый инсайт."
            : "🏝 Solar Island: тихий режим выключен — капсула снова показывает события.")
        rebuildMenu()
    }

    /// Выдать доступ «Запись экрана»: системный промпт (добавит апп в список) +
    /// открыть нужную панель Конфиденциальности. После выдачи нужен перезапуск.
    @objc private func requestScreenAccess() {
        let had = ScreenCapturer.hasPermission()
        ScreenCapturer.requestPermission()                 // CGRequestScreenCaptureAccess — промпт + апп в списке
        openPrivacyPane("Privacy_ScreenCapture")           // Системные настройки → Запись экрана
        let a = NSAlert()
        a.messageText = "Доступ к записи экрана"
        a.informativeText = had
            ? "Доступ уже выдан ✅. Если зрение/болтовня всё равно не видят экран — перезапусти апп."
            : "Включи «Solar Copilot» в списке: Системные настройки → Конфиденциальность и безопасность → Запись экрана.\n\nПосле включения апп нужно перезапустить."
        a.addButton(withTitle: "Перезапустить апп")
        a.addButton(withTitle: "Позже")
        if a.runModal() == .alertFirstButtonReturn { relaunchApp() }
    }

    /// Вкл/выкл legacy-болтовни компаньона. UI-голова больше не поднимается автоматически.
    @objc private func toggleChatter() {
        let on = !AppConfig.load().companionEnabled
        UserDefaults.standard.set(on, forKey: "companionEnabled")
        companion?.setChatter(on)
        if !on { companion?.hide() }
        assistant.append(on
            ? "👁 Болтовня включена в настройках, но отдельная голова не поднимается: основной интерфейс теперь Solar Island."
            : "👁 Болтовня выключена.")
        rebuildMenu()
    }

    @discardableResult
    private func ensureAwareness() -> ScreenAwarenessController? {
        if awareness == nil {
            let cfg = AppConfig.load()
            let a = ScreenAwarenessController(llm: LLMProviders.make(config: cfg), cfg: cfg)
            awareness = a
            a.setEnabled(cfg.awarenessEnabled)
        }
        return awareness
    }

    /// Вкл/выкл «осведомлённости ассистента» — тихий наблюдатель экрана кормит @spb_claude_bot.
    @objc private func toggleAwareness() {
        let on = !AppConfig.load().awarenessEnabled
        UserDefaults.standard.set(on, forKey: "awarenessEnabled")
        ensureAwareness()?.setEnabled(on)
        assistant.append(on
            ? "🧠 Осведомлённость включена — Альтрон тихо видит, над чем ты работаешь, и держит это в общем контексте ассистента в Telegram. Чувствительные приложения (пароли/банк) пропускает."
            : "🧠 Осведомлённость выключена — наблюдение за экраном остановлено.")
        rebuildMenu()
    }

    // MARK: - Зрение по экрану

    /// Кнопка «глянь на экран сейчас» — мгновенный кадр + подсказка по нему.
    @objc private func lookAtScreenNow() {
        guard let b = brain, recording else {
            alert("Сначала начни запись — тогда копилот сможет посмотреть на экран и подсказать.")
            return
        }
        b.captureNow()
    }

    /// Вкл/выкл зрение по экрану — применяется к текущей сессии на лету.
    @objc private func toggleScreenVision() {
        let now = AppConfig.load().screenVisionEnabled
        UserDefaults.standard.set(!now, forKey: "screenVisionEnabled")
        brain?.setScreenVision(enabled: !now)
        assistant.append(!now
            ? "👁 Зрение по экрану включено — копилот будет видеть демо/код/таблицы клиента."
            : "👁 Зрение по экрану выключено.")
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        let toggle = NSMenuItem(title: recording ? L.stop : L.start,
                                action: #selector(toggleRecording), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let show = NSMenuItem(title: L.showTranscript, action: #selector(showTranscript), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let callItem = NSMenuItem(title: callAutoEnabled ? "📞 Автозапись звонков ✓" : "📞 Автозапись звонков — выкл",
                                  action: #selector(toggleCallAuto), keyEquivalent: "")
        callItem.target = self
        callItem.isEnabled = CallAutoDetector.supported
        menu.addItem(callItem)

        let hist = NSMenuItem(title: L.history, action: nil, keyEquivalent: "")
        hist.submenu = historyMenu()
        menu.addItem(hist)

        menu.addItem(.separator())

        let publicMode = AppConfig.load().publicMode
        if !publicMode {   // личный голосовой ассистент Юрия: нужен свой сервер ключей
            let voiceItem = NSMenuItem(title: altronLiveEnabled ? "🎙 Альтрон Live ✓" : "🎙 Альтрон Live",
                                       action: #selector(toggleRealtimeVoice), keyEquivalent: "")
            voiceItem.target = self
            menu.addItem(voiceItem)
        }

        // Диктовка по правому Cmd — один пункт: включает доступ / диагностика / перезапуск.
        let dictActive = dictation?.isActive == true
        let dictItem = NSMenuItem(title: dictActive ? "⌨︎ Диктовка (правый Cmd) ✓" : "⌨︎ Диктовка (правый Cmd)…",
                                  action: #selector(diagnoseDictation), keyEquivalent: "")
        dictItem.target = self
        menu.addItem(dictItem)

        // Переключатель раскладки (левый Option) — вкл/выкл.
        let layoutOn = AppConfig.load().layoutSwitchEnabled
        let layoutActive = layoutSwitch?.isActive == true
        let layoutTitle = layoutOn
            ? (layoutActive ? "⌨︎ Раскладка (левый Option) ✓" : "⌨︎ Раскладка (левый Option) — нужен доступ")
            : "⌨︎ Раскладка (левый Option) — выкл"
        let layoutItem = NSMenuItem(title: layoutTitle, action: #selector(toggleLayoutSwitch), keyEquivalent: "")
        layoutItem.target = self
        menu.addItem(layoutItem)

        // Автомат раскладки (Phase 2) — подпункт, виден когда раскладка включена.
        if layoutOn {
            let autoOn = AppConfig.load().layoutAutoEnabled
            let autoItem = NSMenuItem(title: autoOn ? "      ⮑ Автомат: вкл ✓" : "      ⮑ Автомат: выкл (исправлять на лету)",
                                      action: #selector(toggleLayoutAuto), keyEquivalent: "")
            autoItem.target = self
            menu.addItem(autoItem)
        }

        menu.addItem(.separator())

        // Зрение по экрану — копилот видит демо/код/таблицы клиента на звонке (гибрид).
        let lookItem = NSMenuItem(title: "👁 Глянь на экран сейчас", action: #selector(lookAtScreenNow), keyEquivalent: "")
        lookItem.target = self
        menu.addItem(lookItem)
        let visionOn = AppConfig.load().screenVisionEnabled
        let visionItem = NSMenuItem(title: visionOn ? "👁 Видеть экран по ходу ✓" : "👁 Видеть экран по ходу — выкл",
                                    action: #selector(toggleScreenVision), keyEquivalent: "")
        visionItem.target = self
        menu.addItem(visionItem)

        if !publicMode {   // шлёт журнал экрана на сервер владельца; у других пользователей нет смысла
            let awarenessOn = AppConfig.load().awarenessEnabled
            let awarenessItem = NSMenuItem(title: awarenessOn ? "🧠 Осведомлённость ассистента ✓" : "🧠 Осведомлённость ассистента — выкл",
                                           action: #selector(toggleAwareness), keyEquivalent: "")
            awarenessItem.target = self
            menu.addItem(awarenessItem)
        }

        let islandOn = UserDefaults.standard.object(forKey: "solarIslandEnabled") as? Bool ?? true
        let islandItem = NSMenuItem(title: islandOn ? "🏝 Solar Island ✓" : "🏝 Solar Island — выкл",
                                    action: #selector(toggleSolarIsland), keyEquivalent: "")
        islandItem.target = self
        menu.addItem(islandItem)
        if islandOn {
            let quietOn = UserDefaults.standard.object(forKey: "solarIslandQuietMode") as? Bool ?? false
            let quietItem = NSMenuItem(title: quietOn ? "      ⮑ Тихий режим ✓" : "      ⮑ Тихий режим — выкл",
                                       action: #selector(toggleSolarIslandQuietMode), keyEquivalent: "")
            quietItem.target = self
            menu.addItem(quietItem)
        }

        let screenAccessItem = NSMenuItem(title: "👁 Доступ к записи экрана…", action: #selector(requestScreenAccess), keyEquivalent: "")
        screenAccessItem.target = self
        menu.addItem(screenAccessItem)

        let readyItem = NSMenuItem(title: "⚙ Готовность копилота…", action: #selector(checkReadiness), keyEquivalent: "")
        readyItem.target = self
        menu.addItem(readyItem)

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

    private func startCallDetector() {
        callDetector.onCallStarted = { [weak self] app in
            guard let self = self, self.callAutoEnabled, !self.recording, !self.stressMode else { return }
            self.startRecording()
            self.autoRecording = true
            let line = "📞 Звонок (\(app)) — включил транскрипт"
            self.assistant.append(line)
            self.ensureSolarIsland()?.showInsight(line)
        }
        callDetector.onCallEnded = { [weak self] in
            guard let self = self, self.autoRecording, self.recording else { return }
            self.stopRecording()
            self.assistant.append("📞 Звонок закончился — запись остановлена")
        }
        if callAutoEnabled { callDetector.start() }
    }

    @objc private func toggleCallAuto() {
        let on = !callAutoEnabled
        UserDefaults.standard.set(on, forKey: "callAutoRecordEnabled")
        on ? callDetector.start() : callDetector.stop()
        rebuildMenu()
    }

    private func startRecording() {
        config = AppConfig.load()
        transcriptionDegraded = false
        store.clear()
        assistant.clear()
        callMarkers.removeAll()

        let sessionDir = config.recordingsDir.appendingPathComponent(AudioRecorder.timestamp(), isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        currentSessionDir = sessionDir
        sessionStartedAt = Date()
        updateSessionManifest(.starting)

        // «Мозг» — опционален (product-ready: Telegram/LLM не обязательны).
        if config.assistantEnabled && !stressMode {
            let llm = LLMProviders.make(config: config)
            let b = CopilotBrain(llm: llm, cfg: config)
            b.onAssistant = { [weak self] line in
                self?.assistant.append(line)
                self?.ensureSolarIsland()?.showInsight(line)
            }
            b.onStatus = { [weak self] line in self?.assistant.append(line) }
            brain = b
            b.start()
        } else {
            brain = nil
        }

        let provider = WhisperServerProvider(url: config.whisperURL, language: config.language)
        let rec = AudioRecorder(chunkSeconds: config.chunkSeconds, provider: provider, sessionDir: sessionDir,
                                inputDevicePrefs: config.callInputDevicePrefs)
        rec.onTranscript = { [weak self] sequence, text in
            guard let self = self, !TextFilter.isHallucination(text) else { return }
            self.store.set(sequence: sequence, text: text)
            self.brain?.appendTranscript(text)
            self.syncFiles()
        }
        rec.onError = { [weak self] msg in self?.handleRecorderError(msg) }
        rec.onTranscriptionError = { [weak self] sequence, msg in self?.handleTranscriptionError(sequence: sequence, msg) }
        rec.onTranscriptionRecovered = { [weak self] in self?.handleTranscriptionRecovered() }
        rec.onNotice = { [weak self] msg in self?.assistant.append(msg) }   // переподключение — не стопает запись
        rec.onSaved = { [weak self] audioURL in
            guard let self = self else { return }
            self.syncFiles()
            self.assistant.append(L.savedTo(audioURL.deletingLastPathComponent().path))
            self.routeToAssistant(audioURL)
            self.recoverFailedChunks(
                in: audioURL.deletingLastPathComponent(),
                updateCurrentStore: true,
                completion: self.stressMode ? {
                    AudioRecorder.log("STRESS recovery finished — exiting app")
                    NSApp.terminate(nil)
                } : nil
            )
            self.updateSessionManifest(.completed, audioPath: audioURL.path)
            if self.stressMode { AudioRecorder.log("STRESS saved — waiting for recovery: \(audioURL.path)") }
        }
        recorder = rec
        recording = true
        writeRecordingActivityLock()
        updateSessionManifest(.recording)
        updateStatusIcon()
        rebuildMenu()
        companion?.setRecording(true)   // глаз краснеет + таймер; болтовня на паузе
        solarIsland?.setRecording(true)
        awareness?.setRecording(true)   // наблюдатель на паузе во время звонка (копилот ведёт транскрипт)
        syncFiles()
        rec.requestPermissionAndStart()
    }

    private func stopRecording() {
        autoRecording = false
        updateSessionManifest(.finalizing)
        recorder?.stop()
        recorder = nil
        brain?.stop()
        recording = false
        clearRecordingActivityLock()
        transcriptionDegraded = false
        companion?.setRecording(false)   // глаз idle; болтовня снова, если включена
        solarIsland?.setRecording(false)
        awareness?.setRecording(false)
        updateStatusIcon()
        rebuildMenu()
        syncFiles()
        generateSummary()
    }

    /// Копия записи копилота → Диктовка/ → launchd-watcher транскрибирует и шлёт
    /// ассистенту в Telegram (work→@spb_claude_bot / family→@altron_analyst_bot).
    /// «Всё, что записал — уходит в ассистента» (по умолчанию вкл).
    private func routeToAssistant(_ audioURL: URL) {
        guard config.sendToAssistant, !stressMode else { return }
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
        updateStatusIcon(); rebuildMenu()
        playSound("Tink")
        m.start(dictationDir: cfg.dictationDir, deviceArg: dev.arg, at: Date())
    }

    private func stopMemo() {
        memo?.stop()   // onSaved/onError завершат состояние и сбросят флаги
    }

    private func finishMemo(saved: URL?, error: String?) {
        memo = nil
        memoActive = false
        updateStatusIcon(); rebuildMenu()
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
        let fullForSummary = callMarkers.isEmpty
            ? full
            : full + "\n\n[МАРКЕРЫ ЗВОНКА]\n" + callMarkers.joined(separator: "\n")
        let dir = currentSessionDir
        assistant.append(L.preparingSummary)
        Task { @MainActor in
            let summary = await b.finalSummary(fullTranscript: fullForSummary)
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
            try? SessionRecovery.writeChunks(store.sequencedSnapshot, in: dir)
            writeCallMarkers(in: dir)
        }
        LiveBridge.update(transcript: store.plainText, recording: recording,
                          sessionDir: currentSessionDir, startedAt: sessionStartedAt)
    }

    private func markCallMoment(kind: String) {
        guard recording else {
            assistant.append("🏝 \(kind): запись не идёт. Открыл последний транскрипт вместо пустой магии.")
            showTranscript()
            return
        }
        let elapsed = Int(Date().timeIntervalSince(sessionStartedAt ?? Date()))
        let stamp = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        let excerpt = recentTranscriptExcerpt()
        let body = excerpt.isEmpty ? "маркер без текста — транскрипт ещё не прилетел" : excerpt
        let line = "- [\(stamp)] \(kind): \(body)"
        callMarkers.append(line)
        if let dir = currentSessionDir { writeCallMarkers(in: dir) }
        assistant.append("📌 \(kind) [\(stamp)] — \(body)")
        solarIsland?.showInsight("\(kind) [\(stamp)] сохранено")
    }

    private func recentTranscriptExcerpt() -> String {
        let text = store.plainText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let maxLen = 420
        if text.count <= maxLen { return text }
        return "…" + String(text.suffix(maxLen))
    }

    private func writeCallMarkers(in dir: URL) {
        guard !callMarkers.isEmpty else { return }
        let text = "# Маркеры звонка\n\n" + callMarkers.joined(separator: "\n") + "\n"
        try? text.data(using: .utf8)?.write(to: dir.appendingPathComponent("call_markers.md"))
    }

    private func handleRecorderError(_ message: String) {
        solarIsland?.setError(message)
        stopRecording()
        alert(message)
    }

    private func handleTranscriptionError(sequence: Int, _ message: String) {
        transcriptionDegraded = true
        updateSessionManifest(.sttDegraded, note: message)
        store.set(sequence: sequence, text: "[Фрагмент \(sequence) пока не распознан — восстановление из аудио ожидается]")
        syncFiles()
        AudioRecorder.log("STT degraded — audio capture continues: \(message)")
        assistant.append("⚠️ \(message). Аудиозапись продолжается; этот фрагмент восстановим из итогового файла.")
        solarIsland?.showWarning("Whisper не ответил вовремя. Звук продолжает записываться.")
    }

    private func handleTranscriptionRecovered() {
        guard transcriptionDegraded else { return }
        transcriptionDegraded = false
        updateSessionManifest(.recording)
        AudioRecorder.log("STT recovered — next chunk transcribed")
        assistant.append("✅ Транскрипция восстановилась, запись продолжалась без остановки.")
        solarIsland?.clearWarning()
    }

    private func schedulePendingChunkRecovery() {
        let root = config.recordingsDir
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let sessions = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            for session in sessions where !SessionRecovery.failedChunkFiles(in: session).isEmpty {
                self.recoverFailedChunks(in: session, updateCurrentStore: session == self.currentSessionDir)
            }
        }
    }

    private func recoverFailedChunks(in sessionDir: URL,
                                     updateCurrentStore: Bool,
                                     completion: (() -> Void)? = nil) {
        let failed = SessionRecovery.failedChunkFiles(in: sessionDir)
        guard !failed.isEmpty else { completion?(); return }
        let provider = WhisperServerProvider(url: config.whisperURL, language: config.language)
        AudioRecorder.log("STT recovery started session=\(sessionDir.lastPathComponent) chunks=\(failed.count)")
        Task { @MainActor in
            let recovered = await SessionRecovery.recoverFailedChunks(
                in: sessionDir,
                provider: provider,
                acceptText: { !TextFilter.isHallucination($0) },
                onRecovered: { sequence, text in
                    if updateCurrentStore {
                        await MainActor.run { self.store.set(sequence: sequence, text: text) }
                    }
                }
            )
            if recovered > 0 {
                self.assistant.append("✅ Восстановлено фрагментов транскрипта: \(recovered).")
                self.syncFiles()
            }
            completion?()
        }
    }

    @objc private func showTranscript() {
        windowController.show(transcript: store, assistant: assistant)
    }

    @objc private func showDictationHistory() {
        dictationHistoryWindow.show()
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
        wakeWordDetector?.stop()
        realtimeVoice?.stop()
        clearRecordingActivityLock()
        recorder?.stop()
        WhisperManager.shared.stopServer()
        NSApp.terminate(nil)
    }

    private func writeRecordingActivityLock() {
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        try? pid.data(using: .utf8)?.write(to: recordingActivityLock, options: .atomic)
    }

    private func clearRecordingActivityLock() {
        try? FileManager.default.removeItem(at: recordingActivityLock)
    }

    private func stressDuration(from arguments: [String]) -> TimeInterval {
        guard let i = arguments.firstIndex(of: "--stress-seconds"),
              arguments.indices.contains(i + 1),
              let value = Double(arguments[i + 1]), value >= 10 else { return 3600 }
        return value
    }

    private func updateSessionManifest(_ state: SessionLifecycleState,
                                       audioPath: String? = nil,
                                       note: String? = nil) {
        guard let dir = currentSessionDir, let started = sessionStartedAt else { return }
        let previous = SessionRecovery.readManifest(in: dir)
        let manifest = SessionManifest(
            state: state,
            startedAt: previous?.startedAt ?? started,
            updatedAt: Date(),
            audioPath: audioPath ?? previous?.audioPath,
            note: note
        )
        do { try SessionRecovery.writeManifest(manifest, in: dir) }
        catch { AudioRecorder.log("session manifest write failed: \(error.localizedDescription)") }
    }

    private func recoverOrphanedRecordings() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SolarCopilot", isDirectory: true)
        let wavs = ((try? FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension.lowercased() == "wav" }
        for wav in wavs {
            let sessionDir = config.recordingsDir.appendingPathComponent(
                wav.deletingPathExtension().lastPathComponent, isDirectory: true
            )
            let final = sessionDir.appendingPathComponent("audio.m4a")
            if FileManager.default.fileExists(atPath: final.path) { continue }
            guard WAVFileWriter.repairHeader(at: wav) else { continue }
            let localM4A = wav.deletingPathExtension().appendingPathExtension("recovered.m4a")
            guard AudioRecorder.convertToM4A(wav: wav, m4a: localM4A) else { continue }
            do {
                try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: final)
                try FileManager.default.copyItem(at: localM4A, to: final)
                let started = SessionRecovery.readManifest(in: sessionDir)?.startedAt ?? Date()
                try SessionRecovery.writeManifest(SessionManifest(
                    state: .recovered,
                    startedAt: started,
                    updatedAt: Date(),
                    audioPath: final.path,
                    note: "Recovered orphan WAV after unclean exit"
                ), in: sessionDir)
                try? FileManager.default.removeItem(at: localM4A)
                try? FileManager.default.removeItem(at: wav)
                AudioRecorder.log("orphan WAV recovered: \(final.path)")
            } catch {
                AudioRecorder.log("orphan WAV recovery copy failed: \(error.localizedDescription)")
            }
        }
    }

    private func alert(_ message: String) {
        let a = NSAlert()
        a.messageText = L.appName
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
