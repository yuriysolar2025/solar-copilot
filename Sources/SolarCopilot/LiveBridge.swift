import Foundation

/// Фиксированный «мост» для внешних читателей (ассистент Claude/Альтрон): всегда
/// один и тот же путь к текущему транскрипту и статусу — независимо от того, куда
/// настроена папка записей. Простой способ «подключиться к копилоту»:
///   ~/Library/Application Support/SolarCopilot/live.txt   — текущий транскрипт
///   ~/Library/Application Support/SolarCopilot/live.json  — {recording, session_dir, started_at, updated_at}
enum LiveBridge {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let d = base.appendingPathComponent("SolarCopilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var txtURL: URL { dir.appendingPathComponent("live.txt") }
    static var jsonURL: URL { dir.appendingPathComponent("live.json") }

    static func update(transcript: String, recording: Bool, sessionDir: URL?, startedAt: Date?) {
        try? transcript.data(using: .utf8)?.write(to: txtURL)
        let iso = ISO8601DateFormatter()
        var obj: [String: Any] = [
            "recording": recording,
            "updated_at": iso.string(from: Date()),
        ]
        if let s = sessionDir { obj["session_dir"] = s.path }
        if let st = startedAt { obj["started_at"] = iso.string(from: st) }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: jsonURL)
        }
    }
}
