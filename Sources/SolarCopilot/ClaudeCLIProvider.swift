import Foundation

/// LLM через локальный `claude -p --model <model>` (как MVP `daemon.py`).
/// Бинарь резолвится: cfg.claudeBinPath → ~/.local/bin → homebrew → /usr/local.
/// Промпт идёт в stdin, ответ читается из stdout (stderr отделён — туда уходит
/// шум хуков вложенной сессии, его в ответ не пускаем).
struct ClaudeCLIProvider: LLMProvider {
    let binPath: String

    func complete(prompt: String, model: String, timeout: TimeInterval) async throws -> String {
        guard let bin = ClaudeCLIProvider.resolveBin(preferred: binPath) else {
            throw NSError(domain: "ClaudeCLI", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "claude CLI не найден — укажи путь в настройках"])
        }
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["-p", "--model", model]
            // GUI-приложение из launchd получает урезанный PATH — claude может звать
            // node/хелперы. Пробрасываем нормальный PATH (HOME уже в окружении).
            var env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let paths = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            let existing = env["PATH"].map { [$0] } ?? []
            env["PATH"] = (paths + existing).joined(separator: ":")
            p.environment = env
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = errPipe

            // Watchdog: claude может зависнуть — рубим по таймауту.
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

            p.terminationHandler = { proc in
                killer.cancel()
                let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let text = String(data: outData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if proc.terminationStatus == 0 || !text.isEmpty {
                    cont.resume(returning: text)
                } else {
                    let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let err = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    cont.resume(throwing: NSError(domain: "ClaudeCLI", code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? "claude exit \(proc.terminationStatus)" : err]))
                }
            }

            do {
                try p.run()
                inPipe.fileHandleForWriting.write(prompt.data(using: .utf8) ?? Data())
                try? inPipe.fileHandleForWriting.close()
            } catch {
                killer.cancel()
                cont.resume(throwing: error)
            }
        }
    }

    /// Первый исполняемый кандидат: явный путь → ~/.local → homebrew → /usr/local.
    static func resolveBin(preferred: String) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            preferred,
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for c in candidates where !c.isEmpty && fm.isExecutableFile(atPath: c) { return c }
        return nil
    }
}
