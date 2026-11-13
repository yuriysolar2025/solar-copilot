import AppKit
import AVFoundation
import Foundation
import Speech

/// Low-power, on-device Russian speech recognizer that only waits for "Альтрон".
/// It is stopped before GPT Realtime takes ownership of the microphone.
@MainActor
final class WakeWordDetector {
    enum DetectorError: LocalizedError {
        case microphoneDenied
        case speechDenied
        case russianRecognizerUnavailable
        case onDeviceRecognitionUnavailable
        case invalidAudioInput

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "разреши микрофон для Solar Copilot"
            case .speechDenied:
                return "разреши распознавание речи для Solar Copilot"
            case .russianRecognizerUnavailable:
                return "русское распознавание речи сейчас недоступно"
            case .onDeviceRecognitionUnavailable:
                return "локальное русское распознавание не поддерживается на этом Mac"
            case .invalidAudioInput:
                return "микрофон не отдаёт аудиопоток"
            }
        }
    }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru_RU"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartWork: DispatchWorkItem?
    private var pipelineGeneration = 0
    private var tapInstalled = false
    private var desired = false
    private var starting = false
    private var lastWakeAt = Date.distantPast
    private var activationSound: NSSound?
    private var wakePhrase = ""
    private var wakeDetected = false
    private var phraseFinishWork: DispatchWorkItem?
    private var conversationMode = false

    var onWake: ((String) -> Void)?
    /// Fired as soon as the wake word is recognized, while the user is still
    /// saying the command. This lets Realtime connect in parallel with speech.
    var onActivation: (() -> Void)?
    var onStatus: ((String) -> Void)?
    private(set) var isListening = false

    func start() {
        guard !desired else { return }
        desired = true
        Task { @MainActor in
            do {
                try await ensurePermissions()
                try beginRecognition()
            } catch {
                desired = false
                stopPipeline()
                onStatus?("«Альтрон»: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        desired = false
        stopPipeline()
    }

    func setConversationMode(_ enabled: Bool) {
        conversationMode = enabled
        guard enabled, desired else { return }
        stopPipeline(keepDesired: true)
        let generation = pipelineGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.desired, self.pipelineGeneration == generation else { return }
            do { try self.beginRecognition() }
            catch {
                self.desired = false
                self.onStatus?("«Альтрон»: \(error.localizedDescription)")
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func ensurePermissions() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let allowed = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            if !allowed { throw DetectorError.microphoneDenied }
        default:
            throw DetectorError.microphoneDenied
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            if status != .authorized { throw DetectorError.speechDenied }
        default:
            throw DetectorError.speechDenied
        }
    }

    private func beginRecognition() throws {
        guard desired, !starting, !isListening else { return }
        starting = true
        defer { starting = false }

        guard let recognizer, recognizer.isAvailable else {
            throw DetectorError.russianRecognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw DetectorError.onDeviceRecognitionUnavailable
        }

        stopPipeline(keepDesired: true)
        let generation = pipelineGeneration
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DetectorError.invalidAudioInput
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        self.request = request

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        isListening = true
        onStatus?(conversationMode ? "Слушаю продолжение…" : "Жду слово «Альтрон»")

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.desired, self.pipelineGeneration == generation else { return }
                if let text = result?.bestTranscription.formattedString {
                    if !self.wakeDetected,
                       (self.conversationMode || Self.matchesWakeWord(text)),
                       Date().timeIntervalSince(self.lastWakeAt) > 2.0 {
                        self.wakeDetected = true
                        self.lastWakeAt = Date()
                        if !self.conversationMode {
                            let sound = NSSound(named: NSSound.Name("Glass"))
                            sound?.volume = 0.7
                            self.activationSound = sound
                            sound?.play()
                            self.onActivation?()
                        }
                    }
                    if self.wakeDetected {
                        self.wakePhrase = text
                        self.schedulePhraseFinish(after: result?.isFinal == true ? 0.05 : 0.45)
                        return
                    }
                }
                if error != nil || result?.isFinal == true {
                    self.scheduleRestart(expectedGeneration: generation)
                }
            }
        }

        // Apple's recognition tasks are finite. Rotate before the limit so the
        // passive detector remains alive for hours without accumulating tasks.
        let work = DispatchWorkItem { [weak self] in
            self?.scheduleRestart(expectedGeneration: generation)
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
    }

    private func schedulePhraseFinish(after delay: TimeInterval) {
        phraseFinishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishWakePhrase() }
        phraseFinishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func finishWakePhrase() {
        guard wakeDetected else { return }
        let command = conversationMode ? wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines) : Self.commandAfterWakeWord(wakePhrase)
        conversationMode = false
        wakeDetected = false
        wakePhrase = ""
        // После активации микрофон целиком переходит Realtime. Если Юрий
        // произнёс только имя, следующую фразу услышит серверный VAD; если имя
        // и команда были одной фразой, готовый текст уйдёт через onWake.
        stopPipeline()
        onWake?(command)
    }

    private func scheduleRestart(expectedGeneration: Int) {
        guard desired, pipelineGeneration == expectedGeneration else { return }
        stopPipeline(keepDesired: true)
        let generation = pipelineGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.desired, self.pipelineGeneration == generation else { return }
            do { try self.beginRecognition() }
            catch {
                self.desired = false
                self.onStatus?("«Альтрон»: \(error.localizedDescription)")
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func stopPipeline(keepDesired: Bool = false) {
        pipelineGeneration &+= 1
        phraseFinishWork?.cancel()
        phraseFinishWork = nil
        restartWork?.cancel()
        restartWork = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        // Полностью освобождаем CoreAudio после пассивного распознавания.
        // Иначе WebRTC может ждать тот же input device бесконечно.
        engine.reset()
        isListening = false
        if !keepDesired { desired = false }
    }

    static func matchesWakeWord(_ text: String) -> Bool {
        let folded = text
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .unicodeScalars
            .filter { CharacterSet.letters.contains($0) }
        return String(String.UnicodeScalarView(folded)).contains("альтрон")
    }

    static func commandAfterWakeWord(_ text: String) -> String {
        guard let range = text.range(of: "альтрон", options: [.caseInsensitive, .diacriticInsensitive]) else { return "" }
        return String(text[range.upperBound...])
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
