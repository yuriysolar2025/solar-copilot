import Foundation

/// LLM через локальный `codex exec`. Используется как основной провайдер
/// или как запасной, когда Claude CLI упёрся в лимит подписки.
struct CodexCLIProvider: LLMProvider {
    let binPath: String
    let model: String

    func complete(prompt: String, model: String, timeout: TimeInterval) async throws -> String {
        try await run(prompt: prompt, imagePaths: [], timeout: timeout)
    }

    func complete(prompt: String, imagePaths: [String], model: String, timeout: TimeInterval) async throws -> String {
        try await run(prompt: prompt, imagePaths: imagePaths, timeout: timeout)
    }

    private func run(prompt: String, imagePaths: [String], timeout: TimeInterval) async throws -> String {
        guard let bin = CodexCLIProvider.resolveBin(preferred: binPath) else {
            throw NSError(domain: "CodexCLI", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "codex CLI не найден — установи Codex.app или укажи путь"])
        }
        let codexHome = try CodexCLIProvider.prepareIsolatedHome()

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("solar-copilot-codex-\(UUID().uuidString).txt")

        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            var args = [
                "exec",
                "--ephemeral",
                "--skip-git-repo-check",
                "--ignore-user-config",
                "--ignore-rules",
                "--sandbox", "read-only",
                "--cd", "/tmp",
                "--color", "never",
                "-o", outputURL.path,
            ]
            let selectedModel = self.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !selectedModel.isEmpty {
                args += ["--model", selectedModel]
            }
            for path in imagePaths where FileManager.default.fileExists(atPath: path) {
                args += ["--image", path]
            }
            args.append("-")
            p.arguments = args

            var env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let paths = [
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin",
                "/Applications/ChatGPT.app/Contents/Resources",
                "/Applications/Codex.app/Contents/Resources/codex-cli/bin",
                "/Applications/Codex.app/Contents/Resources",
                "\(home)/.local/bin",
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
            ]
            let existing = env["PATH"].map { [$0] } ?? []
            env["PATH"] = (paths + existing).joined(separator: ":")
            env["TERM"] = "xterm-256color"
            env["NO_COLOR"] = "1"
            // Background summaries do not need the interactive Codex thread index.
            // A private CODEX_HOME prevents concurrent desktop state reconciliation
            // warnings while auth remains linked to the user's local Codex login.
            env["CODEX_HOME"] = codexHome
            p.environment = env

            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = errPipe

            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

            p.terminationHandler = { proc in
                killer.cancel()
                let fileText = (try? String(contentsOf: outputURL, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? FileManager.default.removeItem(at: outputURL)

                let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stdout = String(data: outData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let text = fileText.isEmpty ? stdout : fileText

                if proc.terminationStatus == 0, !text.isEmpty {
                    cont.resume(returning: text)
                } else {
                    let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let err = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let message = [err, stdout].filter { !$0.isEmpty }.joined(separator: "\n")
                    cont.resume(throwing: NSError(domain: "CodexCLI", code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "codex exit \(proc.terminationStatus)" : message]))
                }
            }

            do {
                try p.run()
                inPipe.fileHandleForWriting.write(prompt.data(using: .utf8) ?? Data())
                try? inPipe.fileHandleForWriting.close()
            } catch {
                killer.cancel()
                try? FileManager.default.removeItem(at: outputURL)
                cont.resume(throwing: error)
            }
        }
    }

    static func resolveBin(preferred: String) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            preferred,
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            // С обновления ChatGPT.app 06.11.2026 codex лежит в codex-cli/bin.
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        for c in candidates where !c.isEmpty && fm.isExecutableFile(atPath: c) { return c }
        return nil
    }

    private static func prepareIsolatedHome() throws -> String {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory,
                                 in: .userDomainMask,
                                 appropriateFor: nil,
                                 create: true)
        let root = support
            .appendingPathComponent("SolarCopilot", isDirectory: true)
            .appendingPathComponent("CodexHome", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        let sharedAuth = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        let isolatedAuth = root.appendingPathComponent("auth.json")
        if fm.fileExists(atPath: sharedAuth.path),
           !fm.fileExists(atPath: isolatedAuth.path) {
            try fm.createSymbolicLink(at: isolatedAuth, withDestinationURL: sharedAuth)
        }
        return root.path
    }
}
