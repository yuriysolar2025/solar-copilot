import Foundation

/// LLM через локальный `claude -p --model <model>` (как MVP `daemon.py`).
/// Бинарь резолвится: cfg.claudeBinPath → ~/.local/bin → homebrew → /usr/local.
/// Промпт идёт в stdin, ответ читается из stdout (stderr отделён — туда уходит
/// шум хуков вложенной сессии, его в ответ не пускаем).
struct ClaudeCLIProvider: LLMProvider {
    let binPath: String

    func complete(prompt: String, model: String, timeout: TimeInterval) async throws -> String {
        try await run(prompt: prompt, extraArgs: [], model: model, timeout: timeout)
    }

    /// Vision: даём claude доступ к папкам со скринами + разрешаем Read, путь(и)
    /// кадра вписываем в промпт — модель открывает их и «видит» экран. На подписке.
    func complete(prompt: String, imagePaths: [String], model: String, timeout: TimeInterval) async throws -> String {
        let paths = imagePaths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return try await complete(prompt: prompt, model: model, timeout: timeout) }
        var extra = ["--allowedTools", "Read"]
        for d in Set(paths.map { ($0 as NSString).deletingLastPathComponent }) { extra += ["--add-dir", d] }
        let withPaths = prompt + "\n\nСКРИНШОТ ЭКРАНА (открой через Read и посмотри, что показывают):\n"
            + paths.joined(separator: "\n")
        return try await run(prompt: withPaths, extraArgs: extra, model: model, timeout: timeout)
    }

    private func run(prompt: String, extraArgs: [String], model: String, timeout: TimeInterval) async throws -> String {
        guard let bin = ClaudeCLIProvider.resolveBin(preferred: binPath) else {
            throw NSError(domain: "ClaudeCLI", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "claude CLI не найден — укажи путь в настройках"])
        }
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["-p", "--model", model] + extraArgs
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
                if !ClaudeCLIProvider.looksLikeProviderFailure(text),
                   proc.terminationStatus == 0 || !text.isEmpty {
                    cont.resume(returning: text)
                } else {
                    let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let err = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let message = [err, text].filter { !$0.isEmpty }.joined(separator: "\n")
                    cont.resume(throwing: NSError(domain: "ClaudeCLI", code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "claude exit \(proc.terminationStatus)" : message]))
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

    static func looksLikeProviderFailure(_ text: String) -> Bool {
        let low = text.lowercased()
        return low.contains("usage limit")
            || low.contains("sonnet limit")
            || low.contains("claude limit")
            || low.contains("you have reached")
            || low.contains("reached your limit")
            || low.contains("monthly spend limit")
            || low.contains("spend limit")
            || low.contains("rate limit")
            || low.contains("limit reached")
            || low.contains("too many requests")
            || low.contains("try again later")
            || low.contains("429")
            || low.contains("authenticate")
            || low.contains("api error")
            || low.contains("401 ")
            || low.contains("invalid api key")
            || low.contains("organization has disabled")
    }
}
