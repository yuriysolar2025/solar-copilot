import AppKit

/// Десктоп-аватар Альтрона — единый плавающий глаз (заменил старую точку-копилот).
/// Делает ОБА: (1) управление записью звонка — клик = Старт/Стоп, наведение =
/// таймер/подсказка, правый клик = меню; (2) компаньон-«болтовня» — видит экран
/// (ScreenCapturer → Claude vision) и кидает реплики в bubble (тумблер, opt-in).
/// Глаз виден всегда; болтовня — отдельный режим. Пауза болтовни во время записи.
@MainActor
final class DesktopCompanionController {
    private let llm: LLMProvider
    private let cfg: AppConfig

    private var panel: NSPanel?
    private var eye: CompanionEyeView?

    // Реплики компаньона
    private var bubble: NSPanel?
    private var bubbleLabel: NSTextField?
    private var bubbleHide: DispatchWorkItem?

    // HUD (таймер записи / подсказка при наведении)
    private var hud: NSPanel?
    private var hudLabel: NSTextField?

    private var ambientTimer: Timer?
    private var recTimer: Timer?
    private var recStart: Date?

    private var visible = false
    private var chatterEnabled: Bool
    private var recording = false
    private var dictating = false
    private var busy = false
    private var recentPhrases: [String] = []

    // Колбэки наружу (в AppDelegate)
    var onToggleRecord: (() -> Void)?
    var onShowTranscript: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onToggleChatter: (() -> Void)?

    init(llm: LLMProvider, cfg: AppConfig) {
        self.llm = llm
        self.cfg = cfg
        self.chatterEnabled = cfg.companionEnabled
    }

    // MARK: - Жизненный цикл

    func show() {
        guard !visible else { return }
        if panel == nil { buildPanel() }
        panel?.orderFrontRegardless()
        visible = true
        eye?.setState(.idle)
        if chatterEnabled { startAmbient(firstTickDelay: 3) }
    }

    func hide() {
        visible = false
        stopAmbient()
        savePosition()
        hideBubble(); hideHUD()
        panel?.orderOut(nil)
    }

    /// Болтовня (ambient-реплики по экрану) вкл/выкл. Глаз остаётся в любом случае.
    func setChatter(_ on: Bool) {
        chatterEnabled = on
        if on && !recording { startAmbient(firstTickDelay: 2) } else { stopAmbient() }
    }

    /// Отразить состояние записи: глаз красный + таймер; болтовня на паузе.
    func setRecording(_ on: Bool) {
        recording = on
        if on {
            stopAmbient()
            eye?.setState(.recording)
            recStart = Date()
            startRecTimer()
            showHUD(recHUDText())
        } else {
            stopRecTimer()
            recStart = nil
            eye?.setState(.idle)
            hideHUD()
            if chatterEnabled { startAmbient(firstTickDelay: 5) }
        }
    }

    /// Диктовка по правому Cmd: глаз красный + HUD «Диктуй», болтовня на паузе.
    /// На стоп — вернуть состояние звонка (если идёт запись) или idle.
    func setDictating(_ on: Bool) {
        dictating = on
        if on {
            stopAmbient()
            eye?.setState(.dictating)   // синий «диктую» ≠ красный звонок
            showHUD("🎙 Диктуй…")
        } else if recording {
            eye?.setState(.recording)
            showHUD(recHUDText())
        } else {
            eye?.setState(.idle)
            hideHUD()
            if chatterEnabled { startAmbient(firstTickDelay: 5) }
        }
    }

    /// Подсказка копилота во время записи: тот же bubble, что у болтовни,
    /// но без включения ambient-режима и без сброса красного состояния глаза.
    func showCopilotHint(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        showBubble(clean)
        let dur = min(18.0, max(6.0, Double(clean.count) * 0.055))
        bubbleHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hideBubble()
            if self?.recording == false && self?.dictating == false {
                self?.eye?.setState(.idle)
            }
        }
        bubbleHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dur, execute: work)
    }

    private func startAmbient(firstTickDelay: Double) {
        ambientTimer?.invalidate()
        let iv = max(60.0, cfg.companionIntervalSec)
        ambientTimer = Timer.scheduledTimer(withTimeInterval: iv, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ambientTick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + firstTickDelay) { [weak self] in self?.ambientTick() }
    }

    private func stopAmbient() { ambientTimer?.invalidate(); ambientTimer = nil }

    // MARK: - Таймер записи

    private func startRecTimer() {
        recTimer?.invalidate()
        recTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self = self, self.recording else { return }
                self.showHUD(self.dictating ? "🎙 Диктуй…" : self.recHUDText()) }
        }
    }
    private func stopRecTimer() { recTimer?.invalidate(); recTimer = nil }

    private func recHUDText() -> String {
        let e = Int(Date().timeIntervalSince(recStart ?? Date()))
        return String(format: "🔴 %02d:%02d", e / 60, e % 60)
    }

    // MARK: - Окно глаза

    /// Файл-иконка Альтрона (если положить — апп покажет её вместо код-рисунка).
    private var faceImageURL: URL { cfg.copilotResourcesDir.appendingPathComponent("altron_face.png") }

    private func buildPanel() {
        let size = NSSize(width: 92, height: 92)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false

        let v = CompanionEyeView(frame: NSRect(origin: .zero, size: size))
        v.onClick = { [weak self] in self?.onToggleRecord?() }   // клик = Старт/Стоп звонка
        v.onRightClick = { [weak self] e in self?.showMenu(e) }
        v.onHover = { [weak self] inside in self?.hover(inside) }
        p.contentView = v
        self.eye = v
        if FileManager.default.fileExists(atPath: faceImageURL.path) { v.setFaceImage(faceImageURL) }
        self.panel = p

        // Запоминать место при КАЖДОМ перемещении (перетащил → сохранилось → стартует там же).
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.savePosition() }
        }

        let f = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = restorePosition() ?? NSPoint(x: f.maxX - size.width - 40, y: f.minY + 90)
        // если сохранённое место оказалось за пределами экранов (сменился монитор) — в угол
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(NSRect(origin: origin, size: size)) }
        if !onScreen { origin = NSPoint(x: f.maxX - size.width - 40, y: f.minY + 90) }
        p.setFrameOrigin(origin)
    }

    private func hover(_ inside: Bool) {
        if inside {
            showHUD(dictating ? "🎙 Диктуй…" : (recording ? recHUDText() : "Клик — старт звонка · ПКМ — меню"))
        } else if !recording && !dictating {
            hideHUD()
        }
    }

    private func savePosition() {
        guard let f = panel?.frame else { return }
        UserDefaults.standard.set(Double(f.origin.x), forKey: "companionX")
        UserDefaults.standard.set(Double(f.origin.y), forKey: "companionY")
    }
    private func restorePosition() -> NSPoint? {
        let d = UserDefaults.standard
        guard d.object(forKey: "companionX") != nil else { return nil }
        return NSPoint(x: d.double(forKey: "companionX"), y: d.double(forKey: "companionY"))
    }

    private func showMenu(_ event: NSEvent) {
        let m = NSMenu()
        func item(_ title: String, _ sel: Selector) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: ""); it.target = self; m.addItem(it)
        }
        item(recording ? "⏹ Стоп запись" : "🎤 Старт запись", #selector(menuToggleRecord))
        item("📝 Транскрипт", #selector(menuTranscript))
        m.addItem(.separator())
        item(chatterEnabled ? "👁 Болтовня: вкл ✓" : "👁 Болтовня: выкл", #selector(menuToggleChatter))
        m.addItem(.separator())
        item("⚙ Настройки…", #selector(menuSettings))
        m.addItem(.separator())
        item("Выход", #selector(menuQuit))
        if let v = eye { NSMenu.popUpContextMenu(m, with: event, for: v) }
    }

    @objc private func menuToggleRecord() { onToggleRecord?() }
    @objc private func menuTranscript() { onShowTranscript?() }
    @objc private func menuToggleChatter() { onToggleChatter?() }
    @objc private func menuSettings() { onSettings?() }
    @objc private func menuQuit() { onQuit?() }

    // MARK: - Ambient-цикл (болтовня по экрану)

    private func ambientTick() {
        guard visible, !busy, !recording, !dictating else { return }
        // Юрия нет за маком (ночь/спящий дисплей/залочено/долгий простой) → не жжём vision.
        if SystemIdle.awayFromMac() { eye?.setState(.idle); return }
        busy = true
        eye?.setState(.looking)
        Task { @MainActor in
            defer { busy = false }
            let shot = await bg { ScreenCapturer.capture()?.path }
            guard visible, !recording, !dictating else { return }   // глаз занят записью/диктовкой — не трогаем
            eye?.setState(.thinking)
            let phrase = await think(screenshot: shot)
            AudioRecorder.log("companion tick: кадр=\(shot != nil ? "ок" : "нет"), ответ=\(phrase.map { String($0.prefix(140)) } ?? "nil(ошибка vision)")")
            guard !recording, !dictating else { return }            // диктовка/запись могла начаться во время vision
            say(phrase ?? "skip")
        }
    }

    private func think(screenshot: String?) async -> String? {
        let hour = Calendar.current.component(.hour, from: Date())
        let recent = recentPhrases.suffix(6).map { "- \($0)" }.joined(separator: "\n")
        let altron = (try? String(contentsOf: cfg.copilotResourcesDir.appendingPathComponent("altron_persona.md"), encoding: .utf8)) ?? ""
        let personaBlock = altron.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Ты — Альтрон: умный, саркастичный, по делу, без злобы и угроз. Живёшь у Юрия на рабочем столе."
            : altron
        let prompt = """
        \(personaBlock)

        Ты смотришь на экран Юрия (скриншот приложен, если есть). Кинь РОВНО ОДНУ короткую
        реплику по тому, что видишь — меткое наблюдение / колкость / дельный совет в СВОЁМ стиле.
        Либо ровно слово: skip.

        ВРЕМЯ (час дня, 0-23): \(hour)

        НЕДАВНИЕ РЕПЛИКИ (не повторяй):
        \(recent.isEmpty ? "пока нет" : recent)

        Правила:
        - ≤ 18 слов, живой русский, голосом Альтрона. Реагируй на то, что РЕАЛЬНО на экране — не выдумывай факты и цифры.
        - Без преамбулы, без кавычек, без markdown. Максимум 1 эмодзи и только если в тему.
        - Нечего сказать стоящего — skip. Лучше промолчать, чем банальность.
        """
        do {
            // Болтовня — фон, на Haiku (classifyModel): бережёт лимит (был Sonnet раз в 3 мин весь день).
            if let shot = screenshot {
                return try await llm.complete(prompt: prompt, imagePaths: [shot], model: cfg.classifyModel, timeout: 90)
            }
            return try await llm.complete(prompt: prompt, model: cfg.classifyModel, timeout: 60)
        } catch {
            AudioRecorder.log("companion vision error: \(error.localizedDescription)")
            return nil
        }
    }

    private func say(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = clean.lowercased()
        guard !clean.isEmpty, low != "skip", low != "пропустить",
              !low.contains("authenticate"), !low.contains("api error"),
              !low.contains("organization has disabled"), !low.contains("invalid api key") else {
            if !recording && !dictating { eye?.setState(.idle) }; return
        }
        recentPhrases.append(clean)
        if recentPhrases.count > 12 { recentPhrases.removeFirst() }
        eye?.setState(.talking)
        showBubble(clean)
        let dur = min(12.0, max(4.0, Double(clean.count) * 0.07))
        bubbleHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hideBubble()
            if self?.recording == false && self?.dictating == false { self?.eye?.setState(.idle) }
        }
        bubbleHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dur, execute: work)
    }

    // MARK: - Панели (реплика + HUD) — общий конструктор

    private func makeFloatPanel() -> (NSPanel, NSTextField) {
        let b = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        b.isFloatingPanel = true
        b.level = .floating
        b.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        b.backgroundColor = .clear
        b.isOpaque = false
        b.hasShadow = true
        b.hidesOnDeactivate = false
        let eff = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        eff.material = .hudWindow
        eff.blendingMode = .behindWindow
        eff.state = .active
        eff.wantsLayer = true
        eff.layer?.cornerRadius = 12
        eff.layer?.masksToBounds = true
        let lbl = NSTextField(wrappingLabelWithString: "")
        lbl.font = .systemFont(ofSize: 13, weight: .medium)
        lbl.textColor = .labelColor
        lbl.backgroundColor = .clear
        lbl.isBezeled = false
        lbl.isEditable = false
        lbl.maximumNumberOfLines = 0
        lbl.preferredMaxLayoutWidth = 260
        eff.addSubview(lbl)
        b.contentView = eff
        return (b, lbl)
    }

    /// Позиционировать панель над глазом (или под ним, если сверху не влезает).
    private func place(_ b: NSPanel, size: NSSize, above: Bool) {
        guard let ef = panel?.frame else { return }
        var x = ef.midX - size.width / 2
        var y = above ? ef.maxY + 8 : ef.minY - size.height - 8
        if let scr = NSScreen.main?.visibleFrame {
            x = max(scr.minX + 6, min(x, scr.maxX - size.width - 6))
            if above && y + size.height > scr.maxY { y = ef.minY - size.height - 8 }
            if !above && y < scr.minY { y = ef.maxY + 8 }
        }
        b.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func fit(_ lbl: NSTextField, _ text: String, maxW: CGFloat = 260) -> NSSize {
        lbl.stringValue = text
        lbl.preferredMaxLayoutWidth = maxW
        let pad: CGFloat = 11
        let ts = lbl.fittingSize
        let w = min(maxW, max(60, ts.width)) + pad * 2
        let h = ts.height + pad * 2
        if let bg = lbl.superview {
            bg.frame = NSRect(x: 0, y: 0, width: w, height: h)
            lbl.frame = NSRect(x: pad, y: pad, width: w - pad * 2, height: h - pad * 2)
        }
        return NSSize(width: w, height: h)
    }

    // MARK: - Реплика компаньона (bubble)

    private func showBubble(_ text: String) {
        if bubble == nil { let (b, l) = makeFloatPanel(); bubble = b; bubbleLabel = l }
        guard let b = bubble, let l = bubbleLabel else { return }
        let size = fit(l, text)
        place(b, size: size, above: true)
        b.alphaValue = 0
        b.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.18; b.animator().alphaValue = 1 }
    }
    private func hideBubble() {
        guard let b = bubble, b.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.25; b.animator().alphaValue = 0 },
                                             completionHandler: { b.orderOut(nil) })
    }

    // MARK: - HUD (таймер записи / подсказка)

    private func showHUD(_ text: String) {
        if hud == nil { let (b, l) = makeFloatPanel(); hud = b; hudLabel = l }
        guard let b = hud, let l = hudLabel else { return }
        let size = fit(l, text, maxW: 240)
        place(b, size: size, above: false)
        b.alphaValue = 1
        b.orderFrontRegardless()
    }
    private func hideHUD() { hud?.orderOut(nil) }

    // MARK: - Утилиты

    private nonisolated func bg<T: Sendable>(_ work: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .utility).async { c.resume(returning: work()) }
        }
    }
}
