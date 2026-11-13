import Foundation

/// Последовательная очередь live-транскрипции.
/// whisper-server на личном Mac обслуживается как single-flight: длинный запрос
/// больше не порождает параллельный хвост, который сам усиливает таймауты.
actor TranscriptionPipeline {
    struct Chunk {
        let sequence: Int
        let wav: Data
    }

    private let provider: TranscriptionProvider
    private let recoveryDir: URL
    private let maxPending: Int
    private let maxAttempts: Int
    private let retryDelayNanos: UInt64
    private var pending: [Chunk] = []
    private var draining = false
    private var nextSequence = 1

    private let onTranscript: @MainActor (Int, String) -> Void
    private let onError: @MainActor (Int, String) -> Void
    private let onRecovered: @MainActor () -> Void

    init(provider: TranscriptionProvider,
         recoveryDir: URL,
         maxPending: Int = 30,
         maxAttempts: Int = 2,
         retryDelayNanos: UInt64 = 750_000_000,
         onTranscript: @escaping @MainActor (Int, String) -> Void,
         onError: @escaping @MainActor (Int, String) -> Void,
         onRecovered: @escaping @MainActor () -> Void) {
        self.provider = provider
        self.recoveryDir = recoveryDir
        self.maxPending = max(1, maxPending)
        self.maxAttempts = max(1, maxAttempts)
        self.retryDelayNanos = retryDelayNanos
        self.onTranscript = onTranscript
        self.onError = onError
        self.onRecovered = onRecovered
    }

    @discardableResult
    func enqueue(_ wav: Data) -> Int {
        let sequence = nextSequence
        nextSequence += 1
        guard pending.count < maxPending else {
            AudioRecorder.log("STT chunk=\(sequence) dropped from live queue: pending=\(pending.count), final audio remains source for recovery")
            Task { @MainActor in
                onError(sequence, "очередь распознавания переполнена; фрагмент будет восстановлен из итогового аудио")
            }
            return sequence
        }
        pending.append(Chunk(sequence: sequence, wav: wav))
        AudioRecorder.log("STT chunk=\(sequence) enqueued pending=\(pending.count)")
        if !draining {
            draining = true
            Task { await drain() }
        }
        return sequence
    }

    private func drain() async {
        while !pending.isEmpty {
            let chunk = pending.removeFirst()
            let queuedBehind = pending.count
            var lastError: Error?
            var succeeded = false

            for attempt in 1...maxAttempts {
                let started = Date()
                do {
                    AudioRecorder.log("STT chunk=\(chunk.sequence) attempt=\(attempt) started queuedBehind=\(queuedBehind)")
                    let text = try await provider.transcribe(wav: chunk.wav)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let elapsed = Date().timeIntervalSince(started)
                    AudioRecorder.log(String(format: "STT chunk=%d attempt=%d success duration=%.2fs", chunk.sequence, attempt, elapsed))
                    if !text.isEmpty { await onTranscript(chunk.sequence, text) }
                    if attempt > 1 { await onRecovered() }
                    succeeded = true
                    break
                } catch {
                    lastError = error
                    let elapsed = Date().timeIntervalSince(started)
                    AudioRecorder.log(String(format: "STT chunk=%d attempt=%d failed duration=%.2fs error=%@", chunk.sequence, attempt, elapsed, error.localizedDescription))
                    if attempt < maxAttempts {
                        try? await Task.sleep(nanoseconds: retryDelayNanos)
                    }
                }
            }

            if !succeeded {
                persistForRecovery(chunk)
                await onError(chunk.sequence, lastError?.localizedDescription ?? "неизвестная ошибка")
            }
        }
        draining = false
    }

    private func persistForRecovery(_ chunk: Chunk) {
        do {
            try FileManager.default.createDirectory(at: recoveryDir, withIntermediateDirectories: true)
            let url = recoveryDir.appendingPathComponent(String(format: "chunk-%06d.wav", chunk.sequence))
            try chunk.wav.write(to: url, options: .atomic)
            AudioRecorder.log("STT chunk=\(chunk.sequence) persisted for recovery: \(url.path)")
        } catch {
            AudioRecorder.log("STT chunk=\(chunk.sequence) recovery persist failed: \(error.localizedDescription)")
        }
    }
}
