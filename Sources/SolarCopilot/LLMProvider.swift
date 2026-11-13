import Foundation

/// Абстракция LLM-вызова (product-ready guardrail). Транспорт выбирается
/// настройкой: Claude CLI, Codex CLI или auto-fallback Codex→Claude.
/// За протоколом — только транспорт; все промпты/персона/режимы живут
/// в `CopilotBrain` и от провайдера не зависят.
protocol LLMProvider {
    /// Один prompt → текст ответа. `model` — legacy id модели; Codex может игнорировать.
    func complete(prompt: String, model: String, timeout: TimeInterval) async throws -> String

    /// С изображениями (vision — «зрение» по экрану). Дефолт игнорирует картинки
    /// и делегирует в текстовый вызов, чтобы провайдеры без vision не ломались.
    func complete(prompt: String, imagePaths: [String], model: String, timeout: TimeInterval) async throws -> String
}

extension LLMProvider {
    func complete(prompt: String, imagePaths: [String], model: String, timeout: TimeInterval) async throws -> String {
        try await complete(prompt: prompt, model: model, timeout: timeout)
    }
}

enum LLMProviderMode: String {
    case auto
    case claude
    case codex

    var title: String {
        switch self {
        case .auto: return "Авто: Codex → Claude"
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

enum LLMProviders {
    static func make(config: AppConfig) -> LLMProvider {
        let claude = ClaudeCLIProvider(binPath: config.claudeBinPath)
        let codex = CodexCLIProvider(binPath: config.codexBinPath, model: config.codexModel)
        switch config.llmProviderMode {
        case .claude:
            return claude
        case .codex:
            return codex
        case .auto:
            return FallbackLLMProvider(primary: codex, fallback: claude)
        }
    }
}

struct FallbackLLMProvider: LLMProvider {
    let primary: LLMProvider
    let fallback: LLMProvider

    func complete(prompt: String, model: String, timeout: TimeInterval) async throws -> String {
        do {
            return try await primary.complete(prompt: prompt, model: model, timeout: timeout)
        } catch {
            return try await fallback.complete(prompt: prompt, model: model, timeout: timeout)
        }
    }

    func complete(prompt: String, imagePaths: [String], model: String, timeout: TimeInterval) async throws -> String {
        do {
            return try await primary.complete(prompt: prompt, imagePaths: imagePaths, model: model, timeout: timeout)
        } catch {
            return try await fallback.complete(prompt: prompt, imagePaths: imagePaths, model: model, timeout: timeout)
        }
    }
}
