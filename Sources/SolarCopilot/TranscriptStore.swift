import Foundation

/// Модель транскрипта текущей сессии. onChange дёргается на main для обновления окна.
final class TranscriptStore {
    private(set) var lines: [String] = []
    private var sequencedLines: [Int: String] = [:]
    var onChange: (() -> Void)?
    var sequencedSnapshot: [Int: String] { sequencedLines }

    func append(_ text: String) {
        lines.append(text)
        onChange?()
    }

    /// Live-транскрипт коммитится по позиции в аудио, а не по времени HTTP-ответа.
    /// Повторная запись того же sequence заменяет placeholder восстановленным текстом.
    func set(sequence: Int, text: String) {
        sequencedLines[sequence] = text
        onChange?()
    }

    func clear() {
        lines.removeAll()
        sequencedLines.removeAll()
        onChange?()
    }

    /// Для окна (с плейсхолдером, когда пусто).
    var fullText: String {
        plainText.isEmpty ? L.listening : plainText
    }

    /// Для записи в файл (только реальные строки, без плейсхолдера).
    var plainText: String {
        (sequencedLines.keys.sorted().compactMap { sequencedLines[$0] } + lines)
            .joined(separator: "\n")
    }
}
