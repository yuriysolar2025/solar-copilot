import AppKit

/// NSVisualEffectView с трекингом мыши (hover) и перетаскиванием окна (performDrag).
final class HoverPanelView: NSVisualEffectView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    // Перетаскивание панели за фон (кнопки-сабвью перехватывают свои клики сами).
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// Плавающая панель: в покое — маленькая точка (зелёная/красная), при наведении
/// разворачивается ОТ ЦЕНТРА в полную панель (Старт/Стоп + таймер + транскрипт).
/// Правый клик → меню (Настройки, Транскрипт, Выход). Всегда поверх окон, перетаскивается.
final class FloatingControlWindowController {
    private var panel: NSPanel?
    private var effect: HoverPanelView?
    private var controls: NSView?
    private var dot: NSView?
    private var recBtn: NSButton?
    private var label: NSTextField?
    private var startedAt: Date?
    private var timer: Timer?
    private var recording = false
    private var expanded = false
    private var collapseWork: DispatchWorkItem?

    private let collapsedSize = NSSize(width: 28, height: 28)
    private let expandedSize = NSSize(width: 176, height: 56)

    var onToggle: (() -> Void)?
    var onShowTranscript: (() -> Void)?
    var onSettings: (() -> Void)?
    var onContext: (() -> Void)?
    var onMemo: (() -> Void)?
    var onQuit: (() -> Void)?
    private var memoOn = false

    func show() {
        if panel == nil { build() }
        panel?.orderFrontRegardless()
    }

    private func build() {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: collapsedSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false

        let eff = HoverPanelView(frame: NSRect(origin: .zero, size: collapsedSize))
        eff.material = .hudWindow
        eff.blendingMode = .behindWindow
        eff.state = .active
        eff.wantsLayer = true
        eff.layer?.cornerRadius = collapsedSize.width / 2
        eff.layer?.masksToBounds = true
        eff.onHover = { [weak self] inside in self?.hover(inside) }
        eff.menu = contextMenu()

        let d = NSView(frame: NSRect(x: (collapsedSize.width - 14) / 2,
                                     y: (collapsedSize.height - 14) / 2, width: 14, height: 14))
        d.wantsLayer = true
        d.layer?.backgroundColor = NSColor.systemGreen.cgColor
        d.layer?.cornerRadius = 7
        eff.addSubview(d)
        self.dot = d

        let c = NSView(frame: NSRect(origin: .zero, size: expandedSize))
        c.isHidden = true

        let rec = NSButton(frame: NSRect(x: 10, y: 8, width: 40, height: 40))
        rec.isBordered = false
        rec.imagePosition = .imageOnly
        rec.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "Старт")
        rec.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        rec.contentTintColor = .systemGreen
        rec.target = self
        rec.action = #selector(toggle)
        c.addSubview(rec)
        self.recBtn = rec

        let lbl = NSTextField(labelWithString: "Старт")
        lbl.frame = NSRect(x: 56, y: 18, width: 78, height: 20)
        lbl.font = .systemFont(ofSize: 14, weight: .medium)
        lbl.textColor = .labelColor
        lbl.backgroundColor = .clear
        lbl.isBezeled = false
        c.addSubview(lbl)
        self.label = lbl

        let tr = NSButton(frame: NSRect(x: 138, y: 13, width: 30, height: 30))
        tr.isBordered = false
        tr.imagePosition = .imageOnly
        tr.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "Транскрипт")
        tr.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        tr.contentTintColor = .secondaryLabelColor
        tr.target = self
        tr.action = #selector(showTranscript)
        c.addSubview(tr)

        eff.addSubview(c)
        self.controls = c

        p.contentView = eff
        self.effect = eff
        self.panel = p

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - collapsedSize.width / 2, y: f.minY + 60))
        }
    }

    private func contextMenu() -> NSMenu {
        let m = NSMenu()
        func item(_ title: String, _ sel: Selector) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            m.addItem(it)
        }
        item(L.showTranscript, #selector(showTranscript))
        item("Настройки…", #selector(ctxSettings))
        m.addItem(.separator())
        item(L.quit, #selector(ctxQuit))
        return m
    }

    /// Дебаунс: наведение — разворот сразу; уход — сворачивание через 0.25с.
    private func hover(_ inside: Bool) {
        collapseWork?.cancel()
        if inside {
            setExpanded(true)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func setExpanded(_ on: Bool) {
        guard expanded != on, let p = panel, let eff = effect else { return }
        expanded = on
        // Разворот ОТ ЦЕНТРА (фиксируем центр) — курсор в середине, без анимации.
        let cur = p.frame
        let center = NSPoint(x: cur.midX, y: cur.midY)
        let size = on ? expandedSize : collapsedSize
        let origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        eff.layer?.cornerRadius = on ? 18 : collapsedSize.width / 2
        controls?.isHidden = !on
        dot?.isHidden = on
        p.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    @objc private func toggle() { onToggle?() }
    @objc private func showTranscript() { onShowTranscript?() }
    @objc private func ctxSettings() { onSettings?() }
    @objc private func ctxContext() { onContext?() }
    @objc private func ctxMemo() { onMemo?() }
    @objc private func ctxQuit() { onQuit?() }

    /// Memo-запись (⌘F5) идёт независимо от копилота — подсветим точку оранжевым.
    func setMemo(_ on: Bool) {
        memoOn = on
        effect?.menu = contextMenu()   // обновить заголовок пункта меню
        if !recording {
            dot?.layer?.backgroundColor = (on ? NSColor.systemOrange : NSColor.systemGreen).cgColor
        }
    }

    func setRecording(_ on: Bool) {
        recording = on
        recBtn?.image = NSImage(systemSymbolName: on ? "stop.circle.fill" : "mic.circle.fill",
                                accessibilityDescription: on ? "Стоп" : "Старт")
        recBtn?.contentTintColor = on ? .systemRed : .systemGreen
        dot?.layer?.backgroundColor = (on ? NSColor.systemRed : NSColor.systemGreen).cgColor
        if on {
            startedAt = Date()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            tick()
            pulseDot(true)
        } else {
            timer?.invalidate(); timer = nil
            label?.stringValue = "Старт"
            pulseDot(false)
        }
    }

    private func tick() {
        guard let s = startedAt else { return }
        let e = Int(Date().timeIntervalSince(s))
        label?.stringValue = String(format: "🔴 %02d:%02d", e / 60, e % 60)
    }

    private func pulseDot(_ on: Bool) {
        guard let layer = dot?.layer else { return }
        layer.removeAnimation(forKey: "pulse")
        guard on else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0
        a.toValue = 0.3
        a.duration = 0.8
        a.autoreverses = true
        a.repeatCount = .infinity
        layer.add(a, forKey: "pulse")
    }
}
