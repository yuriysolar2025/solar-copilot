import Foundation

@main
struct TranscriptionPipelineHarness {
    static func main() async {
        let orderedProvider = ProbeProvider()
        let ordered = await MainActor.run { ResultBox() }
        let pipeline = TranscriptionPipeline(
            provider: orderedProvider,
            recoveryDir: FileManager.default.temporaryDirectory.appendingPathComponent("solar-copilot-harness-ordered"),
            onTranscript: { sequence, text in ordered.values.append((sequence, text)) },
            onError: { sequence, message in ordered.errors.append((sequence, message)) },
            onRecovered: {}
        )
        await pipeline.enqueue(Data("one".utf8))
        await pipeline.enqueue(Data("two".utf8))
        await pipeline.enqueue(Data("three".utf8))
        try? await Task.sleep(nanoseconds: 500_000_000)

        let orderedValues = await MainActor.run { ordered.values }
        let orderedErrors = await MainActor.run { ordered.errors }
        let orderedStats = await orderedProvider.stats()
        precondition(orderedValues.map { $0.0 } == [1, 2, 3], "chunks committed out of order")
        precondition(orderedValues.map { $0.1 } == ["one", "two", "three"], "wrong transcript data")
        precondition(orderedErrors.isEmpty, "unexpected transcription error")
        precondition(orderedStats.peak == 1, "requests overlapped")

        let retryProvider = ProbeProvider(failFirst: true)
        let retried = await MainActor.run { ResultBox() }
        let retryPipeline = TranscriptionPipeline(
            provider: retryProvider,
            recoveryDir: FileManager.default.temporaryDirectory.appendingPathComponent("solar-copilot-harness-retry"),
            onTranscript: { sequence, text in retried.values.append((sequence, text)) },
            onError: { sequence, message in retried.errors.append((sequence, message)) },
            onRecovered: {}
        )
        await retryPipeline.enqueue(Data("recovered".utf8))
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        let retryValues = await MainActor.run { retried.values }
        let retryErrors = await MainActor.run { retried.errors }
        let retryStats = await retryProvider.stats()
        precondition(retryValues.map { $0.1 } == ["recovered"], "retry did not recover chunk")
        precondition(retryErrors.isEmpty, "retry surfaced a terminal error")
        precondition(retryStats.calls == 2, "expected exactly one retry")

        let recoveryDir = FileManager.default.temporaryDirectory.appendingPathComponent("solar-copilot-harness-failed-\(UUID().uuidString)")
        let failedBox = await MainActor.run { ResultBox() }
        let failingPipeline = TranscriptionPipeline(
            provider: AlwaysFailProvider(),
            recoveryDir: recoveryDir,
            maxAttempts: 2,
            onTranscript: { _, _ in preconditionFailure("always-fail provider produced text") },
            onError: { sequence, message in failedBox.errors.append((sequence, message)) },
            onRecovered: {}
        )
        await failingPipeline.enqueue(Data("failed-audio".utf8))
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let failedFiles = SessionRecovery.failedChunkFiles(in: recoveryDir.deletingLastPathComponent())
            .filter { $0.url.deletingLastPathComponent() == recoveryDir }
        // Pipeline gets the failed-chunks directory directly; verify the durable file itself.
        let persisted = recoveryDir.appendingPathComponent("chunk-000001.wav")
        precondition(FileManager.default.fileExists(atPath: persisted.path), "failed chunk was not persisted")
        let failedErrors = await MainActor.run { failedBox.errors }
        precondition(failedErrors.count == 1, "terminal failure callback count is wrong")

        let documentSession = FileManager.default.temporaryDirectory.appendingPathComponent("solar-copilot-harness-document-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: documentSession, withIntermediateDirectories: true)
        try! SessionRecovery.writeChunks([2: "two", 1: "one"], in: documentSession)
        let restored = SessionRecovery.readChunks(in: documentSession)
        precondition(SessionRecovery.renderTranscript(restored) == "one\ntwo", "chunk document did not preserve audio order")

        let recoverSession = FileManager.default.temporaryDirectory.appendingPathComponent("solar-copilot-harness-recover-\(UUID().uuidString)")
        let recoverFailedDir = recoverSession.appendingPathComponent("failed-chunks")
        try! FileManager.default.createDirectory(at: recoverFailedDir, withIntermediateDirectories: true)
        try! Data("recovered text".utf8).write(to: recoverFailedDir.appendingPathComponent("chunk-000002.wav"))
        try! SessionRecovery.writeChunks([1: "one", 2: "[missing]", 3: "three"], in: recoverSession)
        let recoveredCount = await SessionRecovery.recoverFailedChunks(in: recoverSession, provider: ProbeProvider())
        precondition(recoveredCount == 1, "failed chunk was not recovered")
        precondition(SessionRecovery.renderTranscript(SessionRecovery.readChunks(in: recoverSession)) == "one\nrecovered text\nthree", "recovered text did not replace placeholder in order")
        precondition(SessionRecovery.failedChunkFiles(in: recoverSession).isEmpty, "recovered WAV was not removed")

        // 180 x 20 секунд = один час звонка. В live-проходе каждый 37-й чанк
        // получает transient timeout, каждый 53-й — terminal failure и durable recovery.
        let hourSession = FileManager.default.temporaryDirectory.appendingPathComponent("solar-copilot-hour-stress-\(UUID().uuidString)")
        let hourFailedDir = hourSession.appendingPathComponent("failed-chunks")
        let hourProvider = HourStressProvider()
        let hourBox = await MainActor.run { ResultBox() }
        let hourPipeline = TranscriptionPipeline(
            provider: hourProvider,
            recoveryDir: hourFailedDir,
            maxPending: 30,
            maxAttempts: 2,
            retryDelayNanos: 5_000_000,
            onTranscript: { sequence, text in hourBox.values.append((sequence, text)) },
            onError: { sequence, message in hourBox.errors.append((sequence, message)) },
            onRecovered: {}
        )
        for sequence in 1...180 {
            await hourPipeline.enqueue(Data("chunk-\(sequence)".utf8))
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let hourValues = await MainActor.run { hourBox.values }
        let hourErrors = await MainActor.run { hourBox.errors }
        precondition(hourValues.count == 177, "hour live pass lost unexpected chunks: \(hourValues.count)")
        precondition(hourErrors.map { $0.0 } == [53, 106, 159], "wrong terminal-failure set")
        let hourPeak = await hourProvider.peakConcurrency()
        precondition(hourPeak == 1, "hour run overlapped Whisper requests")
        var hourDocument = Dictionary(uniqueKeysWithValues: hourValues)
        for (sequence, _) in hourErrors { hourDocument[sequence] = "[missing]" }
        try! SessionRecovery.writeChunks(hourDocument, in: hourSession)
        let hourRecovered = await SessionRecovery.recoverFailedChunks(in: hourSession, provider: ProbeProvider())
        let finalHour = SessionRecovery.readChunks(in: hourSession)
        precondition(hourRecovered == 3, "hour recovery count mismatch")
        precondition(finalHour.count == 180, "hour transcript is incomplete")
        precondition(finalHour.keys.sorted() == Array(1...180), "hour transcript order/sequence has gaps")
        precondition(SessionRecovery.failedChunkFiles(in: hourSession).isEmpty, "hour recovery left failed WAVs")

        let manifestSession = FileManager.default.temporaryDirectory.appendingPathComponent("solar-copilot-manifest-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: manifestSession, withIntermediateDirectories: true)
        let manifest = SessionManifest(state: .recording, startedAt: Date(timeIntervalSince1970: 100), updatedAt: Date(), audioPath: nil, note: nil)
        try! SessionRecovery.writeManifest(manifest, in: manifestSession)
        precondition(SessionRecovery.readManifest(in: manifestSession)?.state == .recording, "manifest roundtrip failed")

        let orphan = manifestSession.appendingPathComponent("orphan.wav")
        var orphanData = WAVFileWriter.header(dataSize: 0, sampleRate: 16000)
        orphanData.append(Data(repeating: 0, count: 32_000))
        try! orphanData.write(to: orphan)
        precondition(WAVFileWriter.repairHeader(at: orphan), "orphan WAV repair failed")
        let repaired = try! Data(contentsOf: orphan)
        let riffSize = repaired[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        let pcmSize = repaired[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        precondition(riffSize == 32_036 && pcmSize == 32_000, "orphan WAV sizes are wrong")
        _ = failedFiles // keeps the public scanner compiled in the harness
        print("PASS: queue, retry, durable recovery, simulated hour, manifest and orphan WAV repair")
    }
}
