import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Хоткей переключателя раскладки: **чистый тап левого Option** (keycode 58).
/// «Чистый» = нажал-отпустил без других клавиш между и быстрее порога — иначе это
/// Option+буква (спецсимвол €/диакритика), не триггер. По триггеру зовёт
/// `LayoutSwitcher.fixSelectionOrLastWord()`.
///
/// Свой listen-only CGEventTap (не трогаем отлаженный `DictationController`).
/// TCC те же, что у диктовки: Input Monitoring (tap) уже выдан. Маска включает
/// keyDown — чтобы знать, была ли между press/release Option другая клавиша.
@MainActor
final class LayoutSwitchController {
    private let cfg: AppConfig
    private let switcher = LayoutSwitcher()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var optionDownAt: CFTimeInterval = 0
    private var optionHeld = false
    private var otherKeyWhileOption = false

    /// Верхний порог «тапа»: дольше — считаем намеренным удержанием, не триггер.
    private let tapThreshold = 0.7

    // ── Автомат (Phase 2): накопление текущего слова для авто-детекта раскладки ──
    private var wordBuffer = ""
    private var autoBusy = false   // глушит собственные синтетические backspace/type
    /// Приложения, где автомат вреден (терминалы/IDE — там команды, пароли, код).
    private static let appBlacklist = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty",
        "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.sublimetext",
        "com.jetbrains", "org.gnu.Emacs", "com.github.atom", "md.obsidian",
        "com.googlecode.iterm2", "co.zeit.hyper",
    ]

    var onStatus: ((String) -> Void)? {
        didSet { switcher.onStatus = onStatus }
    }

    init(cfg: AppConfig) { self.cfg = cfg }

    var isActive: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        // flagsChanged (модификаторы) + keyDown (засечь другую клавишу при зажатом Option).
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
                 | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon = refcon {
                let me = Unmanaged<LayoutSwitchController>.fromOpaque(refcon).takeUnretainedValue()
                me.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: mask,
                                        callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            LayoutSwitcher.logf("start: tapCreate=NIL — нет Input Monitoring (или deny-кэш, нужен перезапуск).")
            return false
        }
        tap = t
        LayoutSwitcher.logf("start: tap СОЗДАН ✅ (левый Option, keycode \(cfg.layoutSwitchKeycode))")
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
        optionHeld = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }
        // Во время конвертации игнорируем собственные синтетические события.
        if switcher.isBusy { return }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyDown {
            if optionHeld { otherKeyWhileOption = true }   // Option+что-то = не триггер
            if cfg.layoutAutoEnabled, !autoBusy { feedAuto(event) }
            return
        }

        // flagsChanged — только наш хоткей-keycode (левый Option по умолчанию)
        guard keycode == Int64(cfg.layoutSwitchKeycode) else { return }
        let optionNow = event.flags.contains(.maskAlternate)

        if optionNow && !optionHeld {
            optionHeld = true
            otherKeyWhileOption = false
            optionDownAt = CACurrentMediaTime()
        } else if !optionNow && optionHeld {
            optionHeld = false
            let dur = CACurrentMediaTime() - optionDownAt
            if !otherKeyWhileOption && dur < tapThreshold {
                LayoutSwitcher.logf("trigger: чистый тап левого Option (\(String(format: "%.2f", dur))с)")
                switcher.fixSelectionOrLastWord()
            }
        }
    }

    // MARK: - Автомат раскладки (Phase 2)

    /// Накапливает текущее слово из keyDown; на разделителе анализирует и при
    /// необходимости автозаменяет раскладку. listen-only: слово уже на экране,
    /// замена идёт постфактум (как Punto) — стереть и впечатать правильное.
    private func feedAuto(_ event: CGEvent) {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        // Cmd/Ctrl-комбо = хоткей/навигация → курсор/контекст сменился, сброс слова.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { wordBuffer = ""; return }
        // Навигация / Enter / Tab / Esc → слово завершено перемещением, БЕЗ замены.
        if Self.resetKeys.contains(keycode) { wordBuffer = ""; return }
        if keycode == 51 { if !wordBuffer.isEmpty { wordBuffer.removeLast() }; return }  // backspace

        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length > 0, let ch = String(utf16CodeUnits: chars, count: length).first else { return }

        if ch.isLetter {
            wordBuffer.append(ch)
            if wordBuffer.count > 40 { wordBuffer = "" }   // слишком длинно — не слово
        } else {
            let word = wordBuffer
            wordBuffer = ""
            if word.count >= 3 { maybeAutoReplace(word, separator: String(ch)) }
        }
    }

    /// Стрелки, Home/End/PageUp/Down, Return, Tab, Esc — сбрасывают слово без замены.
    private static let resetKeys: Set<Int64> = [123, 124, 125, 126, 115, 116, 117, 119, 36, 48, 53, 76]

    private func maybeAutoReplace(_ word: String, separator: String) {
        if IsSecureEventInputEnabled() { return }        // поле пароля
        if isBlacklistedApp() { return }                 // терминал/IDE
        if let (converted, toRussian) = AutoLayoutEngine.analyze(word) {
            autoBusy = true
            LayoutSwitcher.logf("auto: \"\(word)\" → \"\(converted)\" (\(toRussian ? "RU" : "EN"))")
            sendBackspaces(word.count + separator.count)     // стереть слово + разделитель
            LayoutSwitcher.selectLayout(russian: toRussian)  // переключить системную раскладку
            typeText(converted + separator)                  // впечатать правильное + разделитель
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in self?.autoBusy = false }
            return
        }

        // Автоисправление опечаток (перестановка букв) отключено 04.11.2026 по решению
        // Юрия: правило ломало слова вне словаря («пунто»→«путно»).
        // `AutoLayoutEngine.correctedRussianTypo` оставлен для возможного возврата.
    }

    private func isBlacklistedApp() -> Bool {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Self.appBlacklist.contains { bid == $0 || bid.hasPrefix($0) }
    }

    private func sendBackspaces(_ n: Int) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<max(0, n) {
            CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    /// Впечатать строку напрямую через unicode-payload (не трогая буфер обмена).
    private func typeText(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        var u = Array(text.utf16)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
            down.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
            up.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
            up.post(tap: .cghidEventTap)
        }
    }
}
