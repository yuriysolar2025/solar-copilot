import Foundation
import CryptoKit

/// Локальный whisper для public-раздачи: докачивает ggml-модель с HuggingFace и
/// поднимает `whisper-server` на :8127, если он ещё не слушает.
///
/// **Разделение труда:**
/// - **Модель** качает САМ апп (главное удобство — другу не искать гигабайты).
///   Дефолт — `large-v3-turbo` (баланс качество/размер/скорость для realtime-копилота).
/// - **Бинарь** `whisper-server` — системный (`brew install whisper-cpp` или путь
///   whisper.cpp). Так brew сам решает dylib/Metal/арку (arm64|x86_64) — без возни
///   со встраиванием 6 dylib и Metal-шейдеров в бандл. Если не найден — мастер
///   готовности просит `brew install whisper-cpp`.
///
/// На машине Юрия (personal) НЕ вмешивается: его launchd-whisper уже слушает :8127,
/// `whisperReachable` = true → апп свой сервер не поднимает.
@MainActor
final class WhisperManager {
    static let shared = WhisperManager()
    private init() {}

    private var server: Process?
    private(set) var downloading = false

    var onStatus: ((String) -> Void)?

    // MARK: - Модель

    struct ModelSpec {
        let name: String
        let url: URL
        let approxBytes: Int64
        let sha256: String?   // если задан — верифицируем; иначе size-guard
    }

    /// turbo: ~1.6 ГБ, почти качество large-v3, кратно быстрее — оптимум для копилота.
    static let defaultModel = ModelSpec(
        name: "ggml-large-v3-turbo.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
        approxBytes: 1_624_555_275,
        sha256: nil
    )

    static var modelsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SolarCopilot/models", isDirectory: true)
    }

    var modelPath: URL { Self.modelsDir.appendingPathComponent(Self.defaultModel.name) }

    func modelInstalled() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelPath.path) else { return false }
        // size-guard: не обрезанный файл (≥95% ожидаемого)
        let size = ((try? fm.attributesOfItem(atPath: modelPath.path))?[.size] as? Int64) ?? 0
        return size >= Int64(Double(Self.defaultModel.approxBytes) * 0.95)
    }

    // MARK: - Бинарь whisper-server

    static func resolveServerBin() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/whisper-server",
            "/usr/local/bin/whisper-server",
            "\(home)/whisper.cpp/build/bin/whisper-server",
        ]
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        return Dependencies.which("whisper-server")
    }

    // MARK: - Докачка модели

    /// Качает модель в `<modelsDir>/<name>.part`, верифицирует, переименовывает.
    /// progress: 0…1 на main. done: на main.
    func downloadModel(progress: @escaping (Double) -> Void,
                       done: @escaping (Result<URL, Error>) -> Void) {
        guard !downloading else { return }
        downloading = true
        WhisperLog.f("download: старт \(Self.defaultModel.name) (~\(Self.defaultModel.approxBytes / 1_048_576) МБ)")
        try? FileManager.default.createDirectory(at: Self.modelsDir, withIntermediateDirectories: true)

        let dest = modelPath
        let spec = Self.defaultModel
        let delegate = DownloadDelegate(
            expectedBytes: spec.approxBytes,
            onProgress: { p in DispatchQueue.main.async { progress(p) } },
            onFinish: { [weak self] tempURL, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.downloading = false
                    if let error = error { done(.failure(error)); return }
                    guard let tempURL = tempURL else {
                        done(.failure(Self.err("нет файла после загрузки"))); return
                    }
                    do {
                        // sha256-верификация (если задан)
                        if let want = spec.sha256 {
                            let got = try Self.sha256(of: tempURL)
                            guard got.caseInsensitiveCompare(want) == .orderedSame else {
                                try? FileManager.default.removeItem(at: tempURL)
                                done(.failure(Self.err("sha256 не совпал — файл повреждён"))); return
                            }
                        }
                        if FileManager.default.fileExists(atPath: dest.path) {
                            try FileManager.default.removeItem(at: dest)
                        }
                        try FileManager.default.moveItem(at: tempURL, to: dest)
                        WhisperLog.f("download: готово → \(dest.path)")
                        done(.success(dest))
                    } catch {
                        done(.failure(error))
                    }
                }
            })
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        session.downloadTask(with: spec.url).resume()
    }

    // MARK: - Запуск / стоп whisper-server

    var isServerRunning: Bool { server?.isRunning == true }

    /// Поднимает whisper-server с докачанной моделью. false — нет бинаря/модели.
    @discardableResult
    func startServer(config: AppConfig) -> Bool {
        guard server == nil else { return true }
        guard let bin = Self.resolveServerBin() else {
            WhisperLog.f("start: whisper-server не найден (brew install whisper-cpp)")
            return false
        }
        guard modelInstalled() else {
            WhisperLog.f("start: модели нет — нужна докачка")
            return false
        }
        let port = (config.whisperURL as NSURL).port?.intValue ?? 8127
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-m", modelPath.path, "-l", config.language,
                       "--port", "\(port)", "--host", "127.0.0.1", "-nt"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        if let logFH = WhisperLog.handle() { p.standardOutput = logFH; p.standardError = logFH }
        do {
            try p.run()
            server = p
            WhisperLog.f("start: whisper-server поднят на :\(port) (\(bin))")
            return true
        } catch {
            WhisperLog.f("start: ошибка запуска — \(error.localizedDescription)")
            return false
        }
    }

    func stopServer() {
        guard let p = server else { return }
        p.terminate()
        server = nil
        WhisperLog.f("stop: whisper-server остановлен")
    }

    // MARK: - utils

    private static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = h.readData(ofLength: 4 * 1_048_576)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func err(_ msg: String) -> NSError {
        NSError(domain: "WhisperManager", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

// MARK: - URLSession download delegate (прогресс)

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let expectedBytes: Int64
    let onProgress: (Double) -> Void
    let onFinish: (URL?, Error?) -> Void
    private var finished = false

    init(expectedBytes: Int64, onProgress: @escaping (Double) -> Void,
         onFinish: @escaping (URL?, Error?) -> Void) {
        self.expectedBytes = expectedBytes
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        if total > 0 { onProgress(min(1.0, Double(totalBytesWritten) / Double(total))) }
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // location удалится после возврата — переносим в стабильный temp.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("solarcopilot-model-\(t.taskIdentifier).part")
        try? FileManager.default.removeItem(at: tmp)
        do {
            try FileManager.default.moveItem(at: location, to: tmp)
            finished = true
            onFinish(tmp, nil)
        } catch {
            onFinish(nil, error)
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error, !finished { onFinish(nil, error) }
    }
}

// MARK: - Лог

enum WhisperLog {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/solar-copilot-whisper.log")

    static func f(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        if let h = try? FileHandle(forWritingTo: path) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: path)
        }
    }

    static func handle() -> FileHandle? {
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: path)
        h?.seekToEndOfFile()
        return h
    }
}
