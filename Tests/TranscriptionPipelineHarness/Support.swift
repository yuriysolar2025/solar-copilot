import Foundation

protocol TranscriptionProvider: Sendable {
    func transcribe(wav: Data) async throws -> String
}

enum AudioRecorder {
    static func log(_ message: String) { print(message) }
}

actor ProbeProvider: TranscriptionProvider {
    private var active = 0
    private var peak = 0
    private var calls = 0
    private let failFirst: Bool

    init(failFirst: Bool = false) { self.failFirst = failFirst }

    func transcribe(wav: Data) async throws -> String {
        active += 1
        peak = max(peak, active)
        calls += 1
        let call = calls
        try? await Task.sleep(nanoseconds: 40_000_000)
        active -= 1
        if failFirst && call == 1 { throw URLError(.timedOut) }
        return String(data: wav, encoding: .utf8) ?? ""
    }

    func stats() -> (peak: Int, calls: Int) { (peak, calls) }
}

struct AlwaysFailProvider: TranscriptionProvider {
    func transcribe(wav: Data) async throws -> String { throw URLError(.cannotConnectToHost) }
}

actor HourStressProvider: TranscriptionProvider {
    private var attempts: [Int: Int] = [:]
    private var active = 0
    private var peak = 0

    func transcribe(wav: Data) async throws -> String {
        let raw = String(data: wav, encoding: .utf8) ?? ""
        let seq = Int(raw.replacingOccurrences(of: "chunk-", with: "")) ?? 0
        active += 1; peak = max(peak, active)
        attempts[seq, default: 0] += 1
        let attempt = attempts[seq] ?? 1
        try? await Task.sleep(nanoseconds: 1_000_000)
        active -= 1
        if seq.isMultiple(of: 53) { throw URLError(.cannotConnectToHost) }
        if seq.isMultiple(of: 37) && attempt == 1 { throw URLError(.timedOut) }
        return raw
    }

    func peakConcurrency() -> Int { peak }
}

@MainActor
final class ResultBox {
    var values: [(Int, String)] = []
    var errors: [(Int, String)] = []
}
