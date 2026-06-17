import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Захват микрофона через AVAudioEngine, ресемпл в 16kHz mono Int16.
/// Одной сессией ДЕЛАЕТ ОБА: (1) пишет аудио, на «Стоп» конвертит в `audio.m4a`
/// (AAC — открывается на Mac везде, ~10× меньше WAV), (2) шлёт чанки в whisper.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 16000, channels: 1, interleaved: true)!
    private var sampleBuffer = [Int16]()
    private let lock = NSLock()
    private let chunkSamples: Int
    private let provider: TranscriptionProvider
    private let sessionDir: URL
    private let inputDevicePrefs: [String]   // Phase 4: RecordCall = обе стороны звонка
    private var running = false

    private let ioQueue = DispatchQueue(label: "com.solar.copilot.wavio")
    private var fileWriter: WAVFileWriter?

    var onTranscript: ((String) -> Void)?
    var onError: ((String) -> Void)?
    /// URL итогового аудио (m4a) по завершении, на main.
    var onSaved: ((URL) -> Void)?

    init(chunkSeconds: Double, provider: TranscriptionProvider, sessionDir: URL,
         inputDevicePrefs: [String] = []) {
        self.chunkSamples = max(1, Int(chunkSeconds * 16000))
        self.provider = provider
        self.sessionDir = sessionDir
        self.inputDevicePrefs = inputDevicePrefs
    }

    private var deviceOverridden = false

    /// Назначаем входное устройство движку ДО чтения формата. RecordCall (mic +
    /// BlackHole) → слышно обе стороны звонка. Не вышло — тихо остаёмся на дефолте.
    private func applyInputDevice(_ input: AVAudioInputNode) {
        guard !inputDevicePrefs.isEmpty,
              let dev = AudioDevices.inputDeviceID(preferring: inputDevicePrefs),
              let unit = input.audioUnit else { return }
        var id = dev.id
        let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        deviceOverridden = (st == noErr)
    }

    /// Откат на системный вход по умолчанию (если RecordCall дал кривой формат).
    private func resetInputDevice(_ input: AVAudioInputNode) {
        guard deviceOverridden, let def = AudioDevices.defaultInputID(), let unit = input.audioUnit else { return }
        var id = def
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        deviceOverridden = false
    }

    func requestPermissionAndStart() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted { self.start() } else { self.onError?(L.micDenied) }
            }
        }
    }

    private func start() {
        guard !running else { return }
        let input = engine.inputNode
        applyInputDevice(input)
        var inputFormat = input.inputFormat(forBus: 0)
        if inputFormat.sampleRate <= 0 && deviceOverridden {
            // RecordCall не дал валидный формат → откат на системный mic (как было до Phase 4)
            resetInputDevice(input)
            inputFormat = input.inputFormat(forBus: 0)
        }
        guard inputFormat.sampleRate > 0 else {
            onError?("Микрофон недоступен (нулевой формат входа).")
            return
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let wavURL = sessionDir.appendingPathComponent("audio.wav")
        fileWriter = WAVFileWriter(url: wavURL, sampleRate: 16000)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
            running = true
        } catch {
            // Если падали с переопределённым устройством (RecordCall) — один чистый
            // ретрай на системном mic: снимаем tap, сбрасываем девайс, переинициализируем.
            if deviceOverridden {
                input.removeTap(onBus: 0)
                resetInputDevice(input)
                let fmt = input.inputFormat(forBus: 0)
                if fmt.sampleRate > 0 {
                    converter = AVAudioConverter(from: fmt, to: targetFormat)
                    input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buffer, _ in
                        self?.process(buffer)
                    }
                    do { engine.prepare(); try engine.start(); running = true; return }
                    catch { /* проваливаемся в общий onError ниже */ }
                }
            }
            onError?("Не удалось запустить аудио: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        flush(final: true)
        // writer и onSaved захватываем СТРОГО (не через self) — иначе при немедленном
        // освобождении recorder в AppDelegate финализация/конвертация не выполнится
        // (был баг: заголовок WAV оставался с нулевым размером → файл «не открывается»).
        let writer = fileWriter
        fileWriter = nil
        let saved = onSaved
        ioQueue.async {
            guard let writer = writer else { return }
            writer.finalize()
            let wavURL = writer.url
            let m4aURL = wavURL.deletingPathExtension().appendingPathExtension("m4a")
            let okM4A = AudioRecorder.convertToM4A(wav: wavURL, m4a: m4aURL)
            let finalURL = okM4A ? m4aURL : wavURL
            if okM4A { try? FileManager.default.removeItem(at: wavURL) }
            DispatchQueue.main.async { saved?(finalURL) }
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var err: NSError?
        var fed = false
        let status = converter.convert(to: out, error: &err) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true
            inStatus.pointee = .haveData
            return buffer
        }
        if status == .error || err != nil { return }
        guard let ch = out.int16ChannelData, out.frameLength > 0 else { return }
        let n = Int(out.frameLength)
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))

        // (1) в файл — строгая ссылка на writer (не self), чтобы не терять последние сэмплы
        let writer = fileWriter
        ioQueue.async { writer?.append(samples) }

        // (2) накопление для whisper
        lock.lock()
        sampleBuffer.append(contentsOf: samples)
        let ready = sampleBuffer.count >= chunkSamples
        lock.unlock()
        if ready { flush(final: false) }
    }

    private func flush(final: Bool) {
        lock.lock()
        if sampleBuffer.isEmpty || (!final && sampleBuffer.count < chunkSamples) {
            lock.unlock(); return
        }
        let chunk = sampleBuffer
        sampleBuffer.removeAll(keepingCapacity: true)
        lock.unlock()

        let wav = AudioRecorder.wavData(samples: chunk, sampleRate: 16000)
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let text = try await self.provider.transcribe(wav: wav)
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    await MainActor.run { self.onTranscript?(clean) }
                }
            } catch {
                await MainActor.run { self.onError?("Whisper: \(error.localizedDescription)") }
            }
        }
    }

    /// Конвертация WAV → M4A (AAC) встроенным macOS `afconvert`.
    static func convertToM4A(wav: URL, m4a: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "m4af", "-d", "aac", wav.path, m4a.path]
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: m4a.path)
        } catch {
            return false
        }
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }

    /// Минимальный WAV (PCM 16-bit, mono) из Int16-сэмплов для одного whisper-чанка.
    static func wavData(samples: [Int16], sampleRate: Int) -> Data {
        var data = WAVFileWriter.header(dataSize: samples.count * 2, sampleRate: sampleRate)
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }
}
