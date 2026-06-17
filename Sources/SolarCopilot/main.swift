import AppKit

// Точка входа executable. Главный поток = main actor; делегат и весь UI на нём.
// Agent-приложение (LSUIElement): живёт в меню-баре, без иконки в Dock.
// app.run() блокирует навсегда → стек-фрейм держит delegate живым (NSApp.delegate — weak).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
