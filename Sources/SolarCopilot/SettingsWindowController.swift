import AppKit

/// Окно настроек: папка записей, Whisper URL, длина чанка, язык, подсказки ассистента,
/// интервал, отправка записей в ассистента. Пишет в UserDefaults (без хардкод-секретов).
/// Применяется со следующей записи (config перечитывается на «Старт»).
final class SettingsWindowController {
    private var window: NSWindow?
    private var pathField: NSTextField?
    private var whisperField: NSTextField?
    private var chunkField: NSTextField?
    private var langField: NSTextField?
    private var intervalField: NSTextField?
    private var assistantCheck: NSButton?
    private var sendCheck: NSButton?

    func show() {
        if window == nil { build() }
        loadValues()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 360),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "\(L.appName) — Настройки"
        w.isReleasedWhenClosed = false
        let v = w.contentView!

        func label(_ text: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 16, y: y, width: 150, height: 20)
            l.alignment = .right
            v.addSubview(l)
        }

        label("Папка записей:", 308)
        let pf = NSTextField(frame: NSRect(x: 176, y: 306, width: 190, height: 24))
        pf.isEditable = false
        pf.lineBreakMode = .byTruncatingMiddle
        v.addSubview(pf); pathField = pf
        let choose = NSButton(frame: NSRect(x: 372, y: 304, width: 82, height: 28))
        choose.title = "Выбрать…"; choose.bezelStyle = .rounded
        choose.target = self; choose.action = #selector(chooseFolder)
        v.addSubview(choose)

        label("Whisper URL:", 268)
        let wf = NSTextField(frame: NSRect(x: 176, y: 266, width: 278, height: 24))
        v.addSubview(wf); whisperField = wf

        label("Длина чанка (сек):", 228)
        let cf = NSTextField(frame: NSRect(x: 176, y: 226, width: 80, height: 24))
        v.addSubview(cf); chunkField = cf

        label("Язык (ru/en):", 188)
        let lf = NSTextField(frame: NSRect(x: 176, y: 186, width: 80, height: 24))
        v.addSubview(lf); langField = lf

        label("Интервал подсказок (сек):", 148)
        let intf = NSTextField(frame: NSRect(x: 176, y: 146, width: 80, height: 24))
        v.addSubview(intf); intervalField = intf

        let chk = NSButton(checkboxWithTitle: "Подсказки ассистента (Opus/Sonnet) + сводка на «Стоп»",
                           target: self, action: nil)
        chk.frame = NSRect(x: 176, y: 110, width: 290, height: 22)
        v.addSubview(chk); assistantCheck = chk

        let sc = NSButton(checkboxWithTitle: "Отправлять записи в ассистента (Telegram)",
                          target: self, action: nil)
        sc.frame = NSRect(x: 176, y: 82, width: 290, height: 22)
        v.addSubview(sc); sendCheck = sc

        let save = NSButton(frame: NSRect(x: 350, y: 18, width: 104, height: 32))
        save.title = "Сохранить"; save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        save.target = self; save.action = #selector(saveSettings)
        v.addSubview(save)

        let cancel = NSButton(frame: NSRect(x: 252, y: 18, width: 90, height: 32))
        cancel.title = "Отмена"; cancel.bezelStyle = .rounded
        cancel.target = self; cancel.action = #selector(closeWin)
        v.addSubview(cancel)

        self.window = w
    }

    private func loadValues() {
        let c = AppConfig.load()
        pathField?.stringValue = c.recordingsDir.path
        whisperField?.stringValue = c.whisperURL.absoluteString
        chunkField?.stringValue = String(Int(c.chunkSeconds))
        langField?.stringValue = c.language
        intervalField?.stringValue = String(Int(c.suggestionIntervalSec))
        assistantCheck?.state = c.assistantEnabled ? .on : .off
        sendCheck?.state = c.sendToAssistant ? .on : .off
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK, let url = panel.url {
            pathField?.stringValue = url.path
        }
    }

    @objc private func saveSettings() {
        let d = UserDefaults.standard
        if let p = pathField?.stringValue, !p.isEmpty { d.set(p, forKey: "recordingsDir") }
        if let u = whisperField?.stringValue, !u.isEmpty { d.set(u, forKey: "whisperURL") }
        if let cs = chunkField?.stringValue, let n = Double(cs), n > 0 { d.set(n, forKey: "chunkSeconds") }
        if let lg = langField?.stringValue, !lg.isEmpty { d.set(lg, forKey: "language") }
        if let iv = intervalField?.stringValue, let n = Double(iv), n > 0 { d.set(n, forKey: "suggestionIntervalSec") }
        d.set(assistantCheck?.state == .on, forKey: "assistantEnabled")
        d.set(sendCheck?.state == .on, forKey: "sendToAssistant")
        closeWin()
    }

    @objc private func closeWin() { window?.close() }
}
