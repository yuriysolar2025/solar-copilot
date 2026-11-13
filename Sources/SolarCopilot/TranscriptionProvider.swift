import Foundation

/// Бэкенд транскрипции за протоколом (product-ready guardrail: whisper-server
/// сейчас, позже можно встроенный whisper.cpp или облако — без рерайта).
protocol TranscriptionProvider: Sendable {
    func transcribe(wav: Data) async throws -> String
}

/// Шлёт WAV в локальный whisper.cpp server (тот же endpoint, что и MVP daemon.py).
struct WhisperServerProvider: TranscriptionProvider {
    let url: URL
    let language: String

    func transcribe(wav: Data) async throws -> String {
        let boundary = "----CopilotBoundary"
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n")
        field("temperature", "0.0")
        field("language", language)
        field("response_format", "text")
        append("--\(boundary)--\r\n")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 60

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "Whisper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "whisper-server недоступен или вернул ошибку"])
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
