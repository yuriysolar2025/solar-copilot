import Foundation

struct TranscriptChunksDocument: Codable {
    var chunks: [Int: String]
}

enum SessionLifecycleState: String, Codable {
    case starting, recording, sttDegraded = "stt_degraded"
    case finalizing, completed, interrupted, recovered
}

struct SessionManifest: Codable {
    var state: SessionLifecycleState
    var startedAt: Date
    var updatedAt: Date
    var audioPath: String?
    var note: String?
}

enum SessionRecovery {
    static let chunksFilename = "transcript-chunks.json"
    static let manifestFilename = "session.json"

    static func writeManifest(_ manifest: SessionManifest, in sessionDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: sessionDir.appendingPathComponent(manifestFilename), options: .atomic)
    }

    static func readManifest(in sessionDir: URL) -> SessionManifest? {
        let url = sessionDir.appendingPathComponent(manifestFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionManifest.self, from: data)
    }

    static func writeChunks(_ chunks: [Int: String], in sessionDir: URL) throws {
        let data = try JSONEncoder().encode(TranscriptChunksDocument(chunks: chunks))
        try data.write(to: sessionDir.appendingPathComponent(chunksFilename), options: .atomic)
    }

    static func readChunks(in sessionDir: URL) -> [Int: String] {
        let url = sessionDir.appendingPathComponent(chunksFilename)
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(TranscriptChunksDocument.self, from: data) else { return [:] }
        return doc.chunks
    }

    static func failedChunkFiles(in sessionDir: URL) -> [(sequence: Int, url: URL)] {
        let dir = sessionDir.appendingPathComponent("failed-chunks", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("chunk-"), let seq = Int(name.dropFirst("chunk-".count)) else { return nil }
            return (seq, url)
        }.sorted { $0.sequence < $1.sequence }
    }

    static func renderTranscript(_ chunks: [Int: String]) -> String {
        chunks.keys.sorted().compactMap { chunks[$0] }.joined(separator: "\n")
    }

    /// Повторно распознаёт durable failed-chunks. Успешный текст атомарно заменяет
    /// placeholder в chunk-документе и transcript.txt; WAV удаляется только после записи.
    static func recoverFailedChunks(
        in sessionDir: URL,
        provider: TranscriptionProvider,
        acceptText: @escaping @Sendable (String) -> Bool = { !$0.isEmpty },
        onRecovered: @escaping @Sendable (Int, String) async -> Void = { _, _ in }
    ) async -> Int {
        let failed = failedChunkFiles(in: sessionDir)
        guard !failed.isEmpty else { return 0 }
        var chunks = readChunks(in: sessionDir)
        var recovered = 0
        for item in failed {
            do {
                let wav = try Data(contentsOf: item.url)
                let text = try await provider.transcribe(wav: wav)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let recoveredText = acceptText(text)
                    ? text
                    : "[Фрагмент \(item.sequence): речь не обнаружена при повторном распознавании]"
                chunks[item.sequence] = recoveredText
                try writeChunks(chunks, in: sessionDir)
                let transcript = renderTranscript(chunks)
                try transcript.data(using: .utf8)?.write(
                    to: sessionDir.appendingPathComponent("transcript.txt"), options: .atomic
                )
                await onRecovered(item.sequence, recoveredText)
                try FileManager.default.removeItem(at: item.url)
                recovered += 1
                AudioRecorder.log("STT recovery chunk=\(item.sequence) success session=\(sessionDir.lastPathComponent)")
            } catch {
                AudioRecorder.log("STT recovery chunk=\(item.sequence) deferred: \(error.localizedDescription)")
            }
        }
        return recovered
    }
}
