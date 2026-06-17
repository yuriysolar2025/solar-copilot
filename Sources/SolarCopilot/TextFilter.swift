import Foundation

/// Фильтр галлюцинаций whisper-large на тишине/неречевом контенте.
/// Порт из `copilot/daemon.py` (is_hallucination). Применяется к каждому
/// транскрипт-чанку ДО добавления в окно/файл/мозг.
enum TextFilter {
    private static let exact: Set<String> = [
        "спасибо.", "спасибо", "продолжение следует...", "субтитры подогнал",
        "subtitles by", "thank you for watching", "ну вот и всё",
        "[музыка]", "[смех]", "[аплодисменты]",
        "*смех*", "*аплодисменты*", "*музыка*", "*неразборчиво*",
        "апплодисменты.", "аплодисменты.", "смех.", "музыка.", "продолжаем.",
        "...", "…",
    ]
    private static let substrings = [
        "dimatorzok", "подпишись на канал", "ставьте лайк",
        "субтитры сделал", "субтитры создал", "редактор субтитров",
        "корректор субтитров", "перевод субтитров",
    ]

    static func isHallucination(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count < 3 { return true }
        if exact.contains(t) { return true }
        return substrings.contains { t.contains($0) }
    }
}
