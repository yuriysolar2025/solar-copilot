import AVFoundation
import Foundation
import Speech

final class NativeRealtimeTransport {
    var onEvent: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 24_000, channels: 1, interleaved: true)!
    private var socket: URLSessionWebSocketTask?
    private var stopped = false
    private var microphoneStarted = false
    private var microphoneMuted = false
    private let bargeInDetector = RealtimeBargeInDetector()
    private var outputAttached = false
    private var initialText: String?
    private let playbackLock = NSLock()
    private var pendingAudioBuffers = 0
    private var responseDone = false
    private var responseActive = false
    private let playback = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 24_000, channels: 1, interleaved: false)!

    init() {
        bargeInDetector.onBargeIn = { [weak self] phrase in
            self?.interruptForBargeIn(recognizedPhrase: phrase)
        }
    }

    func start(secret: String, model: String, initialText: String? = nil) throws {
        stopped = false
        self.initialText = initialText
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(model)") else {
            throw NSError(domain: "GPTLive", code: 20)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        receiveNext()
    }

    func stop() {
        stopped = true
        playbackLock.withLock { microphoneMuted = false }
        player.stop()
        if microphoneStarted { engine.inputNode.removeTap(onBus: 0) }
        if engine.isRunning { engine.stop() }
        converter = nil
        microphoneStarted = false
        bargeInDetector.stop()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    /// Не отправляем звук динамиков обратно в Realtime, пока Альтрон говорит.
    /// AVAudioEngine без отдельного output graph не даёт надёжного acoustic echo
    /// cancellation, поэтому этот gate предотвращает self-interruption и циклы.
    func setMicrophoneMuted(_ muted: Bool) {
        playbackLock.withLock { microphoneMuted = muted }
    }

    func sendToolResult(callID: String, output: String) {
        send([
            "type": "conversation.item.create",
            "item": ["type": "function_call_output", "call_id": callID, "output": output],
        ])
        send(["type": "response.create"])
    }

    func sendUserText(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        interruptPlayback()
        let shouldCancel = playbackLock.withLock {
            let active = responseActive
            responseActive = false
            responseDone = false
            return active
        }
        // OpenAI treats response.cancel with no active response as an error.
        // The first wake-word command is sent immediately after session.created,
        // when there is nothing to cancel yet.
        if shouldCancel { send(["type": "response.cancel"]) }
        send([
            "type": "conversation.item.create",
            "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]],
        ])
        send(["type": "response.create"])
    }

    private func startOutput() throws {
        guard !outputAttached else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playback)
        engine.prepare()
        try engine.start()
        outputAttached = true
    }

    private func sendInitialTextIfNeeded() {
        guard let text = initialText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        initialText = nil
        sendUserText(text)
    }

    private func startMicrophone() throws {
        guard !microphoneStarted else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0,
              let converter = AVAudioConverter(from: format, to: target) else {
            throw NSError(domain: "GPTLive", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "микрофон не отдаёт аудиопоток"])
        }
        self.converter = converter
        if !outputAttached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playback)
            outputAttached = true
        }
        input.installTap(onBus: 0, bufferSize: 2400, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        microphoneStarted = true
    }

    private func playAudioDelta(_ encoded: String) {
        guard !stopped, let data = Data(base64Encoded: encoded), !data.isEmpty else { return }
        let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playback, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<Int(frames) {
                channel[index] = Float(Int16(littleEndian: samples[index])) / 32_768.0
            }
        }
        playbackLock.lock()
        pendingAudioBuffers += 1
        playbackLock.unlock()
        player.scheduleBuffer(buffer) { [weak self] in self?.audioBufferFinished() }
        if !player.isPlaying { player.play() }
    }

    private func audioBufferFinished() {
        playbackLock.lock()
        pendingAudioBuffers = max(0, pendingAudioBuffers - 1)
        let finished = responseDone && pendingAudioBuffers == 0
        playbackLock.unlock()
        if finished { emitPlaybackDone() }
    }

    private func markResponseDone() {
        playbackLock.lock()
        responseDone = true
        let finished = pendingAudioBuffers == 0
        playbackLock.unlock()
        if finished { emitPlaybackDone() }
    }

    private func emitPlaybackDone() {
        playbackLock.withLock { microphoneMuted = false }
        bargeInDetector.stop()
        DispatchQueue.main.async { [weak self] in self?.onEvent?(["type": "local.playback_done"]) }
    }

    private func interruptPlayback() {
        guard player.isPlaying else { return }
        player.stop() // also clears already-buffered reply audio
    }

    private func interruptForBargeIn(recognizedPhrase: String) {
        bargeInDetector.stop()
        let shouldCancel = playbackLock.withLock {
            let active = responseActive
            responseActive = false
            responseDone = false
            pendingAudioBuffers = 0
            microphoneMuted = false
            return active
        }
        player.stop()
        if shouldCancel { send(["type": "response.cancel"]) }
        AudioRecorder.log("GPT Live barge-in confirmed; playback interrupted")
        DispatchQueue.main.async { [weak self] in self?.onEvent?(["type": "local.barge_in"]) }
        if let command = AltronBargeInPolicy.commandAfterWakeName(recognizedPhrase) {
            // The local recognizer consumed this part while server upload was
            // muted. Submit it once as text; sendUserText sees responseActive=false,
            // so it does not issue a second cancel and creates exactly one turn.
            AudioRecorder.log("GPT Live barge-in forwarding wake command")
            sendUserText(command)
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        let muted = playbackLock.withLock { microphoneMuted }
        guard !stopped else { return }
        if muted {
            bargeInDetector.append(buffer)
            return
        }
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil,
              let channels = output.int16ChannelData, output.frameLength > 0 else { return }
        let bytes = Data(bytes: channels[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
        send(["type": "input_audio_buffer.append", "audio": bytes.base64EncodedString()])
    }

    private func send(_ object: [String: Any]) {
        guard !stopped, let socket,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return }
        Task {
            do { try await socket.send(.string(string)) }
            catch { self.fail(error.localizedDescription) }
        }
    }

    private func receiveNext() {
        guard !stopped, let socket else { return }
        Task {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let value): data = Data(value.utf8)
                case .data(let value): data = value
                @unknown default: data = Data()
                }
                if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let type = body["type"] as? String
                    if body["type"] as? String == "session.created" {
                        do {
                            try self.startMicrophone()
                            self.sendInitialTextIfNeeded()
                        } catch {
                            self.fail(error.localizedDescription)
                            return
                        }
                    }
                    if type == "response.output_audio.delta", let delta = body["delta"] as? String {
                        self.playAudioDelta(delta)
                    }
                    if type == "response.created" {
                        self.playbackLock.withLock {
                            self.responseActive = true
                            self.responseDone = false
                            self.microphoneMuted = true
                        }
                        self.bargeInDetector.start()
                    }
                    if type == "response.done" {
                        self.playbackLock.withLock { self.responseActive = false }
                        self.markResponseDone()
                    }
                    if type == "input_audio_buffer.speech_started" {
                        self.interruptPlayback()
                    }
                    // A response may finish between our local cancel decision and
                    // the server receiving response.cancel. This benign race must
                    // not tear down the whole voice session.
                    let error = body["error"] as? [String: Any]
                    let errorMessage = (error?["message"] as? String ?? "").lowercased()
                    let benignCancelRace = type == "error"
                        && errorMessage.contains("cancellation failed")
                        && errorMessage.contains("no active response")
                    if !benignCancelRace {
                        DispatchQueue.main.async { self.onEvent?(body) }
                    }
                }
                self.receiveNext()
            } catch {
                if !self.stopped { self.fail(error.localizedDescription) }
            }
        }
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        stopped = true
        DispatchQueue.main.async { self.onFailure?(message) }
    }
}

/// Recognizes the wake name or short, explicit interruption phrases from the
/// existing mic tap. Assistant audio may be transcribed too, but ordinary output
/// is ignored so the half-duplex echo guard cannot interrupt itself.
private final class RealtimeBargeInDetector {
    var onBargeIn: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru_RU"))
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var triggered = false
    private var loggedFirstPartial = false
    private var lifecycle = AltronBargeInLifecycle()

    func start() {
        let token = resetForStart()
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            startRecognition(generation: token)
        case .notDetermined:
            AudioRecorder.log("GPT Live barge-in requesting Speech Recognition permission")
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                guard let self else { return }
                if status == .authorized {
                    self.startRecognition(generation: token)
                } else {
                    AudioRecorder.log("GPT Live barge-in unavailable: Speech Recognition status=\(status.rawValue)")
                }
            }
        case .denied, .restricted:
            AudioRecorder.log("GPT Live barge-in unavailable: Speech Recognition status=\(SFSpeechRecognizer.authorizationStatus().rawValue)")
        @unknown default:
            AudioRecorder.log("GPT Live barge-in unavailable: unknown Speech Recognition status")
        }
    }

    private func resetForStart() -> Int {
        let old = lock.withLock { () -> (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?, Int) in
            let token = lifecycle.advance()
            let value = (request, task, token)
            request = nil
            task = nil
            triggered = false
            loggedFirstPartial = false
            return value
        }
        old.0?.endAudio()
        old.1?.cancel()
        return old.2
    }

    private func startRecognition(generation token: Int) {
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            AudioRecorder.log("GPT Live barge-in unavailable: ru-RU on-device recognizer not ready")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .confirmation
        request.contextualStrings = ["Альтрон", "Альтрон стоп", "Альтрон хватит", "Альтрон подожди"]
        let accepted = lock.withLock { () -> Bool in
            guard lifecycle.isCurrent(token) else { return false }
            self.request = request
            self.triggered = false
            return true
        }
        guard accepted else { return }
        AudioRecorder.log("GPT Live barge-in recognizer started")
        let recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let error {
                let current = self.lock.withLock { self.lifecycle.isCurrent(token) }
                if current { AudioRecorder.log("GPT Live barge-in recognizer error: \(error.localizedDescription)") }
                return
            }
            guard let text = result?.bestTranscription.formattedString else { return }
            let shouldLogFirst = self.lock.withLock { () -> Bool in
                guard self.lifecycle.isCurrent(token), !self.loggedFirstPartial else { return false }
                self.loggedFirstPartial = true
                return true
            }
            if shouldLogFirst {
                let count = text.split(whereSeparator: { $0.isWhitespace }).count
                AudioRecorder.log("GPT Live barge-in first partial received; words=\(count)")
            }
            guard let interruption = AltronBargeInPolicy.interruptionPhrase(from: text) else { return }
            let fire = self.lock.withLock {
                guard self.lifecycle.isCurrent(token), !self.triggered else { return false }
                self.triggered = true
                return true
            }
            if fire {
                AudioRecorder.log("GPT Live barge-in phrase confirmed: \(interruption)")
                self.onBargeIn?(interruption)
            }
        }
        let keepTask = lock.withLock { () -> Bool in
            guard lifecycle.isCurrent(token) else { return false }
            task = recognitionTask
            return true
        }
        if !keepTask { recognitionTask.cancel() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let current = lock.withLock { request }
        current?.append(buffer)
    }

    func stop() {
        let old = lock.withLock { () -> (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) in
            _ = lifecycle.advance()
            let value = (request, task)
            request = nil
            task = nil
            return value
        }
        old.0?.endAudio()
        old.1?.cancel()
    }
}

/// Rejects delayed authorization/recognition callbacks from an older response.
/// Without this gate an approval callback can recreate a detector after playback
/// already ended, making the next assistant reply interrupt itself.
struct AltronBargeInLifecycle {
    private(set) var generation = 0

    mutating func advance() -> Int {
        generation += 1
        return generation
    }

    func isCurrent(_ token: Int) -> Bool {
        token == generation
    }
}

/// Pure interruption policy kept separate from Speech/AVFoundation lifecycle so
/// the accepted phrases and echo-safety boundary have deterministic tests.
enum AltronBargeInPolicy {
    private static func words(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "[^а-я ]", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// Speech returns one cumulative transcription that often begins with the
    /// assistant audio from the speakers. Inspect the latest trigger suffix,
    /// rather than rejecting the entire result merely because it has >5 words.
    static func interruptionPhrase(from text: String) -> String? {
        let words = words(in: text)
        guard !words.isEmpty else { return nil }

        if let wake = words.lastIndex(of: "альтрон") {
            let suffix = Array(words[wake...])
            if suffix.count <= 12 { return suffix.joined(separator: " ") }
        }

        let commands: Set<String> = ["стоп", "подожди", "погоди", "замолчи", "хватит", "тихо"]
        let allowed: Set<String> = commands.union(["пожалуйста", "все", "уже", "давай"])
        let suffix = Array(words.suffix(5))
        for start in suffix.indices {
            let candidate = Array(suffix[start...])
            if candidate.contains(where: commands.contains), candidate.allSatisfy(allowed.contains) {
                return candidate.joined(separator: " ")
            }
        }
        return nil
    }

    static func shouldInterrupt(_ text: String) -> Bool {
        interruptionPhrase(from: text) != nil
    }

    /// Returns only the command that was swallowed by the muted upload window.
    /// A bare wake name and pure stop phrases return nil: they only reopen mic.
    static func commandAfterWakeName(_ text: String) -> String? {
        let pattern = #"(?i)^\s*альтрон\s*[,.:;!?\-–—]*\s*(.*?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges == 2,
              let commandRange = Range(match.range(at: 1), in: text) else { return nil }
        let command = text[commandRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }
}
