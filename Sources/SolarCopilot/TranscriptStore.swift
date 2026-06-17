import Foundation

/// Модель транскрипта текущей сессии. onChange дёргается на main для обновления окна.
final class TranscriptStore {
    private(set) var lines: [String] = []
    var onChange: (() -> Void)?

    func append(_ text: String) {
        lines.append(text)
        onChange?()
    }

    func clear() {
        lines.removeAll()
        onChange?()
    }

    /// Для окна (с плейсхолдером, когда пусто).
    var fullText: String {
        lines.isEmpty ? L.listening : lines.joined(separator: "\n")
    }

    /// Для записи в файл (только реальные строки, без плейсхолдера).
    var plainText: String {
        lines.joined(separator: "\n")
    }
}
