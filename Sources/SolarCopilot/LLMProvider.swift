import Foundation

/// Абстракция LLM-вызова (product-ready guardrail). Сейчас — личный Claude CLI
/// Юрия; для продажи подменяемо на HTTP-API / client-BYO-key / прокси Solar
/// с биллингом БЕЗ переписывания «мозга». За протоколом — только транспорт;
/// все промпты/персона/режимы живут в `CopilotBrain` и от провайдера не зависят.
protocol LLMProvider {
    /// Один prompt → текст ответа. `model` — id модели (claude-*). `timeout` в секундах.
    func complete(prompt: String, model: String, timeout: TimeInterval) async throws -> String
}
