import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

let accepted = [
    "стоп",
    "Альтрон, стоп",
    "стоп пожалуйста",
    "Альтрон хватит пожалуйста",
    "Альтрон открой браузер",
    "Альтрон расскажи короче",
    "ну всё, хватит".replacingOccurrences(of: "ну ", with: ""),
    "тихо уже",
]
for phrase in accepted {
    expect(AltronBargeInPolicy.shouldInterrupt(phrase), "must accept '\(phrase)'")
}

let rejected = [
    "я расскажу тебе об этом",
    "это не стоп сигнал",
    "подожди пока я объясню длинную историю дальше",
    "пожалуйста",
    "",
]
for phrase in rejected {
    expect(!AltronBargeInPolicy.shouldInterrupt(phrase), "must reject '\(phrase)'")
}

let cumulative: [(String, String?)] = [
    ("Paperclip распределяет задачи между агентами и затем Альтрон скажи короче", "альтрон скажи короче"),
    ("Сейчас я продолжу подробный рассказ хватит пожалуйста", "хватит пожалуйста"),
    ("Длинная фраза ассистента без команды пользователя", nil),
    ("Это не стоп сигнал и рассказ продолжается", nil),
]
for (phrase, expected) in cumulative {
    expect(AltronBargeInPolicy.interruptionPhrase(from: phrase) == expected,
           "cumulative extraction mismatch for '\(phrase)'")
}

var lifecycle = AltronBargeInLifecycle()
let first = lifecycle.advance()
expect(lifecycle.isCurrent(first), "first playback token must be current")
let second = lifecycle.advance()
expect(!lifecycle.isCurrent(first), "stale permission callback must be rejected")
expect(lifecycle.isCurrent(second), "new playback token must be current")
_ = lifecycle.advance()
expect(!lifecycle.isCurrent(second), "stop must invalidate active recognition callback")

let extracted: [(String, String?)] = [
    ("Альтрон, расскажи короче", "расскажи короче"),
    ("  альтрон — открой браузер  ", "открой браузер"),
    ("Альтрон", nil),
    ("стоп", nil),
    ("мы обсуждаем Альтрон", nil),
]
for (phrase, expected) in extracted {
    expect(AltronBargeInPolicy.commandAfterWakeName(phrase) == expected,
           "command extraction mismatch for '\(phrase)'")
}

print("PASS policy=\(accepted.count + rejected.count) lifecycle=4 extraction=\(extracted.count) cumulative=\(cumulative.count)")
