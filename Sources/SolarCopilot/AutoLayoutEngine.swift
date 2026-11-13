import AppKit

/// Движок автоматического определения «слово набрано не в той раскладке» (Phase 2,
/// автомат как в Punto). Ядро — системный `NSSpellChecker` (ru+en), без встроенных
/// словарей. Консервативен: срабатывает только когда слово НЕВАЛИДНО в своей раскладке
/// И его конверсия ВАЛИДНА в другой — плюс набор защит от ложных срабатываний
/// (пароли, код, аббревиатуры).
@MainActor
enum AutoLayoutEngine {
    private static let checker = NSSpellChecker.shared

    /// Доступны ли обе проверки (ru spell нужно включить в системе при наличии раскладки).
    static var available: Bool {
        let langs = checker.availableLanguages
        return langs.contains { $0.hasPrefix("ru") } && langs.contains { $0.hasPrefix("en") }
    }

    static func valid(_ word: String, _ lang: String) -> Bool {
        let r = checker.checkSpelling(of: word, startingAt: 0, language: lang, wrap: false,
                                      inSpellDocumentWithTag: 0, wordCount: nil)
        return r.location == NSNotFound
    }

    /// nil = не трогать. Иначе (конвертированное слово, нужна ли РУССКАЯ раскладка дальше).
    static func analyze(_ word: String) -> (String, Bool)? {
        // ── Защиты от ложных срабатываний ──
        guard word.count >= 3, word.count <= 40 else { return nil }      // короткие = аббревиатуры
        if word.contains(where: { $0.isNumber }) { return nil }          // пароли/коды/номера
        if word.contains(where: { $0 == "_" || $0 == "-" || $0 == "." || $0 == "/" || $0 == "@" }) { return nil } // идентификаторы/пути/почта
        if hasInnerUppercase(word) { return nil }                        // camelCase = код

        let hasCyr = word.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
        let hasLat = word.unicodeScalars.contains { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }
        if hasCyr == hasLat { return nil }                               // смешанное или без букв — пропуск

        if hasCyr {
            // набрано кириллицей: валидно по-русски → не трогать; иначе пробуем латиницу
            if valid(word, "ru") { return nil }
            let (conv, _) = LayoutSwitcher.convert(word)                 // ru→en
            if conv != word, conv.allSatisfy({ $0.isLetter }), valid(conv, "en") { return (conv, false) }  // «юсь»→«.cm» не слово
        } else {
            // набрано латиницей: валидно по-английски → не трогать; иначе пробуем кириллицу
            if valid(word, "en") { return nil }
            let (conv, _) = LayoutSwitcher.convert(word)                 // en→ru
            if conv != word, valid(conv, "ru") { return (conv, true) }
        }
        return nil
    }

    /// Консервативная коррекция русской опечатки в уже верной раскладке.
    /// Пока безопасно исправляем только одну перестановку соседних букв: системный
    /// русский словарь иногда считает нормальное слово ошибкой и для обычной замены
    /// букв может предложить другой смысл (например, «правит» → «правил»).
    static func correctedRussianTypo(_ word: String) -> String? {
        guard word.count >= 4, word.count <= 32 else { return nil }
        guard word == word.lowercased() else { return nil } // имена/заголовки не трогаем
        guard word.unicodeScalars.allSatisfy({ $0.value >= 0x0400 && $0.value <= 0x04FF }) else { return nil }
        guard !valid(word, "ru") else { return nil }

        let range = NSRange(word.startIndex..<word.endIndex, in: word)
        guard let guesses = checker.guesses(forWordRange: range, in: word, language: "ru", inSpellDocumentWithTag: 0) else {
            return nil
        }
        return guesses.first { candidate in
            candidate == candidate.lowercased()
                && candidate.unicodeScalars.allSatisfy({ $0.value >= 0x0400 && $0.value <= 0x04FF })
                && isSingleAdjacentTransposition(word, candidate)
        }
    }

    private static func isSingleAdjacentTransposition(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs)
        let b = Array(rhs)
        guard a.count == b.count, a.count >= 2 else { return false }
        let mismatches = a.indices.filter { a[$0] != b[$0] }
        guard mismatches.count == 2,
              mismatches[1] == mismatches[0] + 1 else { return false }
        let first = mismatches[0]
        let second = mismatches[1]
        return a[first] == b[second] && a[second] == b[first]
    }

    /// Заглавная буква НЕ в начале (camelCase/PascalCase середина) → опознаём код.
    private static func hasInnerUppercase(_ word: String) -> Bool {
        let chars = Array(word)
        guard chars.count > 1 else { return false }
        for i in 1..<chars.count where chars[i].isUppercase { return true }
        return false
    }
}
