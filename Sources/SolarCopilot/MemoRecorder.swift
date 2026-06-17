import Foundation

/// Memo-режим (замена `macrec.lua` / ⌘F5): запись с aggregate RecordCall
/// (mic + BlackHole = обе стороны звонка) напрямую в m4a в папку `Диктовка/`
/// с именем «DD месяца YYYY г., HH:MM.m4a». Существующий launchd
/// `dictation-transcribe` подхватывает файл → whisper → Telegram-роутинг.
/// Никакого live-транскрипта/мозга — это диктофон «в файл», не копилот.
final class MemoRecorder {
    private let ffmpeg: String
    private var task: Process?
    private(set) var outputURL: URL?

    /// Готовая запись (m4a) — на main.
    var onSaved: ((URL) -> Void)?
    var onError: ((String) -> Void)?

    private static let months = [
        "января", "февраля", "марта", "апреля", "мая", "июня",
        "июля", "августа", "сентября", "октября", "ноября", "декабря",
    ]

    init(ffmpeg: String) { self.ffmpeg = ffmpeg }

    var isRecording: Bool { task?.isRunning == true }

    /// Имя файла как у macrec/Shortcut — launchd-watcher распознаёт формат.
    static func memoFilename(_ date: Date) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.day, .month, .year, .hour, .minute], from: date)
        let month = months[(c.month ?? 1) - 1]
        return String(format: "%d %@ %d г., %02d:%02d.m4a",
                      c.day ?? 1, month, c.year ?? 2026, c.hour ?? 0, c.minute ?? 0)
    }

    /// Старт. dictationDir — папка `Диктовка/`, deviceArg — ":N" из AudioDevices.
    func start(dictationDir: URL, deviceArg: String, at date: Date) {
        guard task == nil else { return }
        try? FileManager.default.createDirectory(at: dictationDir, withIntermediateDirectories: true)
        let url = dictationDir.appendingPathComponent(MemoRecorder.memoFilename(date))
        outputURL = url

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = [
            "-y", "-hide_banner", "-loglevel", "error",
            "-f", "avfoundation", "-i", deviceArg,
            "-ac", "1", "-ar", "16000",
            "-c:a", "aac", "-b:a", "64k",
            url.path,
        ]
        let err = Pipe()
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            DispatchQueue.main.async {
                self.task = nil
                if size > 1024 {
                    self.onSaved?(url)
                } else {
                    try? FileManager.default.removeItem(at: url)
                    let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    self.onError?("Запись пуста (ffmpeg): \(e.suffix(200))")
                }
            }
        }
        do {
            try p.run()
            task = p
        } catch {
            onError?("Не удалось запустить ffmpeg: \(error.localizedDescription)")
        }
    }

    /// Стоп: SIGINT (ffmpeg корректно закрывает m4a) + SIGKILL-фоллбэк через 1.5с,
    /// т.к. avfoundation иногда залипает в blocking syscall (как в macrec.lua).
    func stop() {
        guard let p = task else { return }
        let pid = p.processIdentifier
        p.interrupt()   // SIGINT
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
        }
    }
}
