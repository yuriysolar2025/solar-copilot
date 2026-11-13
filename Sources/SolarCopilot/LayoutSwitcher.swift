import AppKit
import Carbon

/// Переключатель раскладки (замена Punto Switcher / Caramba), Phase «layout».
/// Конвертирует последнее слово или выделение из неверной раскладки в верную
/// (ЙЦУКЕН↔QWERTY) и переключает системную раскладку через TIS.
///
/// Триггерится из `LayoutSwitchController` по чистому тапу левого Option.
/// Использует те же примитивы, что диктовка: посылка клавиш через CGEvent +
/// работа с NSPasteboard. Новых TCC-разрешений не требует (Accessibility уже выдан
/// для диктовки). Вся работа — на main (буфер/CG/TIS).
@MainActor
final class LayoutSwitcher {

    /// Идёт конвертация — `LayoutSwitchController` должен глушить свои события,
    /// чтобы синтетические Cmd+C/Cmd+V/стрелки не зациклили детект тапа.
    private(set) var isBusy = false

    var onStatus: ((String) -> Void)?

    // ─── Диагностика ───
    static let logPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/solar-copilot-layout.log")

    static func logf(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        if let h = try? FileHandle(forWritingTo: logPath) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: logPath)
        }
    }

    // MARK: - Публичный экшн

    /// Главный ручной экшн: взять выделение (если есть) или последнее слово,
    /// сконвертировать раскладку, переключить системную раскладку, вставить обратно.
    func fixSelectionOrLastWord() {
        guard !isBusy else { return }
        isBusy = true
        Self.logf("fix: старт")

        let pb = NSPasteboard.general
        let savedItems = Self.snapshot(pb)

        // 1) Положить sentinel, запомнить changeCount, скопировать текущее выделение.
        let sentinel = "\u{2063}SOLAR_LAYOUT\u{2063}"
        pb.clearContents()
        pb.setString(sentinel, forType: .string)
        let ccBefore = pb.changeCount
        Self.postCmd(virtualKey: CGKeyCode(kVK_ANSI_C))   // Cmd+C

        // 2) Через паузу проверить: было ли выделение (буфер изменился = да).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self = self else { return }
            let copied = pb.string(forType: .string)
            let hadSelection = (pb.changeCount != ccBefore) && copied != nil && copied != sentinel

            if hadSelection, let sel = copied, !sel.isEmpty {
                Self.logf("fix: выделение = \"\(sel.prefix(40))\"")
                self.convertAndPaste(sel, restore: savedItems, reselect: false)
            } else {
                // 3) Выделения нет → выделить слово слева (Option+Shift+Left) и скопировать.
                Self.logf("fix: выделения нет → выделяю последнее слово")
                pb.clearContents()
                pb.setString(sentinel, forType: .string)
                let cc2 = pb.changeCount
                Self.postChord(virtualKey: CGKeyCode(kVK_LeftArrow), flags: [.maskAlternate, .maskShift])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    Self.postCmd(virtualKey: CGKeyCode(kVK_ANSI_C))   // Cmd+C
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                        let word = pb.string(forType: .string)
                        let gotWord = (pb.changeCount != cc2) && word != nil && word != sentinel
                        if gotWord, let w = word, !w.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Self.logf("fix: слово = \"\(w.prefix(40))\"")
                            // слово уже выделено (Option+Shift+Left) → Cmd+V заменит его
                            self.convertAndPaste(w, restore: savedItems, reselect: false)
                        } else {
                            Self.logf("fix: нечего конвертировать → откат буфера")
                            Self.restore(pb, savedItems)
                            self.finish()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Конвертация + вставка

    private func convertAndPaste(_ text: String, restore saved: [NSPasteboardItem], reselect: Bool) {
        let (converted, toRussian) = Self.convert(text)
        guard converted != text else {
            Self.logf("fix: текст без конвертируемых символов → ничего не делаю")
            Self.restore(NSPasteboard.general, saved)
            finish()
            return
        }
        // Переключить системную раскладку под дальнейший ввод.
        Self.selectLayout(russian: toRussian)

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(converted, forType: .string)
        Self.postCmd(virtualKey: CGKeyCode(kVK_ANSI_V))   // Cmd+V — заменяет выделение
        Self.logf("fix: вставлено \"\(converted.prefix(40))\" (→\(toRussian ? "RU" : "EN"))")

        // Восстановить буфер пользователя позже, чтобы Cmd+V успел отработать.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            Self.restore(pb, saved)
            self?.finish()
        }
    }

    private func finish() {
        // Небольшая задержка, чтобы tap не поймал хвост синтетических событий.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.isBusy = false
        }
    }

    // MARK: - Таблица раскладок (US ANSI ↔ Russian PC «ЙЦУКЕН»)

    /// en-символ → ru-символ (по позиции клавиши). Буквы — строгая биекция.
    private static let enToRu: [Character: Character] = {
        let pairs: [(String, String)] = [
            ("`","ё"), ("q","й"), ("w","ц"), ("e","у"), ("r","к"), ("t","е"),
            ("y","н"), ("u","г"), ("i","ш"), ("o","щ"), ("p","з"), ("[","х"), ("]","ъ"),
            ("a","ф"), ("s","ы"), ("d","в"), ("f","а"), ("g","п"), ("h","р"),
            ("j","о"), ("k","л"), ("l","д"), (";","ж"), ("'","э"),
            ("z","я"), ("x","ч"), ("c","с"), ("v","м"), ("b","и"), ("n","т"),
            ("m","ь"), (",","б"), (".","ю"), ("/","."),
            // Shift-ряд
            ("~","Ё"), ("Q","Й"), ("W","Ц"), ("E","У"), ("R","К"), ("T","Е"),
            ("Y","Н"), ("U","Г"), ("I","Ш"), ("O","Щ"), ("P","З"), ("{","Х"), ("}","Ъ"),
            ("A","Ф"), ("S","Ы"), ("D","В"), ("F","А"), ("G","П"), ("H","Р"),
            ("J","О"), ("K","Л"), ("L","Д"), (":","Ж"), ("\"","Э"),
            ("Z","Я"), ("X","Ч"), ("C","С"), ("V","М"), ("B","И"), ("N","Т"),
            ("M","Ь"), ("<","Б"), (">","Ю"), ("?",",")
        ]
        var m: [Character: Character] = [:]
        for (e, r) in pairs { m[Character(e)] = Character(r) }
        return m
    }()

    /// ru-символ → en-символ (инверсия). Для коллизий (`.` есть и как `/`-русское,
    /// и встречается с обеих сторон) первый записанный выигрывает — буквы не страдают.
    private static let ruToEn: [Character: Character] = {
        var m: [Character: Character] = [:]
        for (e, r) in enToRu where m[r] == nil { m[r] = e }
        return m
    }()

    /// Определяет направление по наличию кириллицы и конвертирует.
    /// Возврат: (сконвертированный текст, нужна ли РУССКАЯ системная раскладка дальше).
    static func convert(_ text: String) -> (String, Bool) {
        let hasCyrillic = text.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
        if hasCyrillic {
            // набрано кириллицей → человек хотел латиницу
            let out = String(text.map { ruToEn[$0] ?? $0 })
            return (out, false)
        } else {
            // набрано латиницей → человек хотел кириллицу
            let out = String(text.map { enToRu[$0] ?? $0 })
            return (out, true)
        }
    }

    // MARK: - Системная раскладка (TIS)

    /// Выбирает включённую клавиатурную раскладку нужного языка (ru/en).
    static func selectLayout(russian: Bool) {
        let want = russian ? "ru" : "en"
        guard let cf = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return }
        let n = CFArrayGetCount(cf)
        for i in 0..<n {
            let raw = CFArrayGetValueAtIndex(cf, i)!
            let src = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
            guard category(src) == (kTISCategoryKeyboardInputSource as String) else { continue }
            guard boolProp(src, kTISPropertyInputSourceIsSelectCapable) else { continue }
            guard let lang = languages(src).first else { continue }
            if lang.hasPrefix(want) {
                TISSelectInputSource(src)
                Self.logf("layout: → \(stringProp(src, kTISPropertyInputSourceID) ?? lang)")
                return
            }
        }
        Self.logf("layout: не нашёл раскладку для \(want)")
    }

    private static func category(_ src: TISInputSource) -> String? {
        stringProp(src, kTISPropertyInputSourceCategory)
    }

    private static func stringProp(_ src: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private static func boolProp(_ src: TISInputSource, _ key: CFString) -> Bool {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
    }

    private static func languages(_ src: TISInputSource) -> [String] {
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { return [] }
        let arr = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue()
        return (arr as? [String]) ?? []
    }

    // MARK: - Посылка клавиш + буфер

    private static func postCmd(virtualKey: CGKeyCode) {
        postChord(virtualKey: virtualKey, flags: .maskCommand)
    }

    /// Шлёт keyDown+keyUp с модификаторами на cghidEventTap (как `paste()` в диктовке).
    static func postChord(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    /// Снимок буфера (все типы) для восстановления после конвертации.
    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        var copy: [NSPasteboardItem] = []
        for item in pb.pasteboardItems ?? [] {
            let dup = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    dup.setData(data, forType: type)
                }
            }
            copy.append(dup)
        }
        return copy
    }

    private static func restore(_ pb: NSPasteboard, _ items: [NSPasteboardItem]) {
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
