import Foundation
import CoreGraphics

/// Захват кадра экрана для «зрения» копилота. Снимок главного дисплея →
/// уменьшенный jpg в /tmp (не iCloud — там лочится синком). Кадр потом уходит
/// в Claude vision вместе с транскриптом (см. CopilotBrain.makeSuggestion).
enum ScreenCapturer {
    private static var dir: URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("SolarCopilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Снять главный дисплей, уменьшить до 1280px по большей стороне. Возвращает
    /// путь к jpg или nil (нет доступа / ошибка). Каждый вызов перезаписывает файл.
    static func capture() -> URL? {
        let url = dir.appendingPathComponent("screen.jpg")
        try? FileManager.default.removeItem(at: url)

        let cap = Process()
        cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -x без звука, -t jpg, -m только главный дисплей (один файл, не плодим по экранам)
        cap.arguments = ["-x", "-t", "jpg", "-m", url.path]
        do { try cap.run(); cap.waitUntilExit() } catch {
            AudioRecorder.log("screen: screencapture не запустился: \(error.localizedDescription)")
            return nil
        }
        guard cap.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            AudioRecorder.log("screen: захват не удался (rc=\(cap.terminationStatus)) — нет доступа к записи экрана?")
            return nil
        }

        // Уменьшить (меньше токенов в vision-вызове). Не критично если sips упадёт.
        let sips = Process()
        sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        sips.arguments = ["-Z", "1280", url.path]
        try? sips.run(); sips.waitUntilExit()
        return url
    }

    /// Есть ли доступ к записи экрана (без системного промпта).
    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Запросить доступ — один раз покажет системный промпт «Запись экрана».
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }
}
