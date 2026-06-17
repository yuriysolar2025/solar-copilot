import Foundation

/// Централизованные строки UI (product-ready guardrail: готовность к локализации RU/EN).
enum L {
    private static func t(_ key: String, _ fallback: String) -> String {
        let v = NSLocalizedString(key, comment: "")
        return v == key ? fallback : v
    }
    static var appName: String { t("app.name", "Solar Copilot") }
    static var start: String { t("menu.start", "▶︎ Старт записи") }
    static var stop: String { t("menu.stop", "⏹ Стоп") }
    static var showTranscript: String { t("menu.transcript", "Показать транскрипт") }
    static var chooseFolder: String { t("menu.chooseFolder", "Папка записей…") }
    static var openFolder: String { t("menu.openFolder", "Открыть папку записей") }
    static var history: String { t("menu.history", "История сессий") }
    static var quit: String { t("menu.quit", "Выход") }
    static var transcriptTitle: String { t("window.transcript", "Транскрипт") }
    static var assistantTitle: String { t("window.assistant", "🤖 Ассистент") }
    static var assistantPlaceholder: String { t("placeholder.assistant", "Подсказки появятся по ходу разговора, сводка — на «Стоп».") }
    static var preparingSummary: String { t("status.summary", "⏳ Готовлю сводку…") }
    static var contextMenu: String { t("menu.context", "Контекст / заметка…") }
    static var memoStart: String { t("menu.memoStart", "🎙 Диктофон — запись в файл (⌘F5)") }
    static var memoStop: String { t("menu.memoStop", "⏹ Диктофон — стоп (⌘F5)") }
    static var callOutputToggle: String { t("menu.callOutput", "📞 Звук звонка вкл/выкл (обе стороны)") }
    static var dictationEnable: String { t("menu.dictationEnable", "⌨︎ Диктовка (правый Cmd) — включить доступ…") }
    static var dictationOn: String { t("menu.dictationOn", "⌨︎ Диктовка (правый Cmd) ✓") }
    static var contextTitle: String { t("dialog.contextTitle", "Контекст звонка / заметка") }
    static var contextInfo: String { t("dialog.contextInfo", "Первая фраза — контекст (с кем, тема, цель). Дальше — заметки по ходу. «я веду» / «я слушаю» — сменить режим.") }
    static var micDenied: String { t("error.mic", "Нет доступа к микрофону.\nСистемные настройки → Конфиденциальность → Микрофон → включить Solar Copilot.") }
    static var listening: String { t("placeholder.listening", "Слушаю… первый фрагмент появится через несколько секунд.") }
    static func savedTo(_ path: String) -> String { "💾 Запись сохранена: \(path)" }
}
