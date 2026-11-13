import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Захват микрофона через AVAudioEngine, ресемпл в 16kHz mono Int16.
/// Одной сессией ДЕЛАЕТ ОБА: (1) пишет аудио в ЛОКАЛЬНЫЙ wav (/tmp), на «Стоп»
/// конвертит в `audio.m4a` и кладёт в `sessionDir`; (2) шлёт чанки в whisper.
///
/// Надёжность (фикс 2026-06-19 «копилот постоянно отваливается»):
/// - Подписка на `AVAudioEngineConfigurationChange` + watchdog ПЕРЕЗАПУСКАЮТ движок,
///   когда меняется аудиомаршрут (воткнул наушники / созвон захватил микрофон /
///   сменился дефолтный вход). Без этого AVAudioEngine штатно встаёт и не оживает —
///   запись молча умирает, а апп думает что пишет.
/// - Рабочий wav пишется в /tmp, НЕ в iCloud: iCloud Drive лочит файл на фоновой
///   синхронизации и дропает сэмплы (огрызок аудио + галлюцинация whisper, баг 02.06).
/// - Файловый лог `~/Library/Logs/solar-copilot.log` — апп не пишет в unified log,
///   при отвале раньше не было ни одного следа.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 16000, channels: 1, interleaved: true)!
    private var sampleBuffer = [Int16]()
    private let lock = NSLock()
    private let chunkSamples: Int
    private let chunkSeconds: Double
    private let provider: TranscriptionProvider
    private let sessionDir: URL              // финальный архив (может быть в iCloud)
    private let workWavURL: URL              // рабочий wav — ВСЕГДА локально (/tmp)
    private let inputDevicePrefs: [String]   // Phase 4: RecordCall = обе стороны звонка
    private var running = false

    private let ioQueue = DispatchQueue(label: "com.solar.copilot.wavio")
    private var fileWriter: WAVFileWriter?

    // Надёжность движка
    private var configObserver: NSObjectProtocol?
    private var watchdog: Timer?
    private var bufferTotal = 0              // под lock: сколько буферов всего пришло
    private var watchdogPrev = 0            // снимок bufferTotal на прошлом тике
    private var restarting = false

    var onTranscript: ((Int, String) -> Void)?
    /// Фатальная ошибка захвата/файла: запись действительно не может продолжаться.
    var onError: ((String) -> Void)?
    /// Мягкая ошибка распознавания: локальная аудиозапись НЕ останавливается.
    var onTranscriptionError: ((Int, String) -> Void)?
    /// Следующий успешный чанк после деградации — UI может снять предупреждение.
    var onTranscriptionRecovered: (() -> Void)?
    /// Мягкое уведомление (переподключение устройства) — НЕ останавливает запись.
    var onNotice: ((String) -> Void)?
    /// URL итогового аудио (m4a) по завершении, на main.
    var onSaved: ((URL) -> Void)?

    private lazy var transcriptionPipeline = TranscriptionPipeline(
        provider: provider,
        recoveryDir: sessionDir.appendingPathComponent("failed-chunks", isDirectory: true),
        onTranscript: { [weak self] sequence, clean in
            guard let self = self else { return }
            self.onTranscript?(sequence, clean)
            self.onTranscriptionRecovered?()
            Self.log("STT chunk=\(sequence) committed in audio order")
        },
        onError: { [weak self] sequence, message in
            guard let self = self else { return }
            Self.log("STT chunk=\(sequence) unavailable after retries: \(message)")
            self.onTranscriptionError?(sequence, "Whisper: \(message)")
        },
        onRecovered: { [weak self] in
            self?.onTranscriptionRecovered?()
        }
    )

    init(chunkSeconds: Double, provider: TranscriptionProvider, sessionDir: URL,
         inputDevicePrefs: [String] = []) {
        self.chunkSeconds = chunkSeconds
        self.chunkSamples = max(1, Int(chunkSeconds * 16000))
        self.provider = provider
        self.sessionDir = sessionDir
        self.inputDevicePrefs = inputDevicePrefs
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("SolarCopilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        self.workWavURL = work.appendingPathComponent(sessionDir.lastPathComponent + ".wav")
    }

    // MARK: - Лог (файл — апп не пишет в unified log, при отвале были слепы)

    static let logURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/solar-copilot.log")
    private static let logQueue = DispatchQueue(label: "com.solar.copilot.log")
    static func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(f.string(from: Date()))] \(s)\n"
        logQueue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: logURL) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
        }
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
            Self.log("✗ старт: формат входа 0 — микрофон недоступен")
            return
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        fileWriter = WAVFileWriter(url: workWavURL, sampleRate: 16000)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
            running = true
            installConfigObserver()
            startWatchdog()
            Self.log("✓ запись началась, вход \(Int(inputFormat.sampleRate))Hz, wav=\(workWavURL.lastPathComponent)")
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
                    do {
                        engine.prepare(); try engine.start(); running = true
                        installConfigObserver(); startWatchdog()
                        Self.log("✓ запись началась (ретрай на системном mic), вход \(Int(fmt.sampleRate))Hz")
                        return
                    } catch { /* проваливаемся в общий onError ниже */ }
                }
            }
            onError?("Не удалось запустить аудио: \(error.localizedDescription)")
            Self.log("✗ старт не удался: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard running else { return }
        running = false
        removeConfigObserver()
        watchdog?.invalidate(); watchdog = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        flush(final: true)
        // writer/onSaved/пути захватываем СТРОГО (не через self) — иначе при немедленном
        // освобождении recorder в AppDelegate финализация/конвертация не выполнится.
        let writer = fileWriter
        fileWriter = nil
        let saved = onSaved
        let sessionDir = self.sessionDir
        let workWav = self.workWavURL
        ioQueue.async {
            guard let writer = writer else { return }
            writer.finalize()
            try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            let localM4A = workWav.deletingPathExtension().appendingPathExtension("m4a")
            let finalURL: URL
            if AudioRecorder.convertToM4A(wav: workWav, m4a: localM4A) {
                let dest = sessionDir.appendingPathComponent("audio.m4a")
                try? FileManager.default.removeItem(at: dest)
                do {
                    // Один файл целиком (не непрерывная запись) — iCloud это проглатывает.
                    try FileManager.default.copyItem(at: localM4A, to: dest)
                    try? FileManager.default.removeItem(at: localM4A)
                    try? FileManager.default.removeItem(at: workWav)
                    finalURL = dest
                } catch {
                    Self.log("⚠️ копия m4a в архив не удалась (\(error.localizedDescription)) — оставил локально")
                    finalURL = localM4A
                }
            } else {
                // Не сконвертили — кладём wav в архив, чтобы не потерять запись.
                let dest = sessionDir.appendingPathComponent("audio.wav")
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.copyItem(at: workWav, to: dest)) != nil {
                    try? FileManager.default.removeItem(at: workWav)
                    finalURL = dest
                } else {
                    finalURL = workWav
                }
                Self.log("⚠️ конвертация в m4a не удалась, сохранил wav")
            }
            Self.log("✓ запись сохранена: \(finalURL.path)")
            DispatchQueue.main.async { saved?(finalURL) }
        }
    }

    // MARK: - Перезапуск движка при смене аудиоустройства

    /// AVAudioEngine штатно ОСТАНАВЛИВАЕТСЯ при смене аудиоконфигурации (новое устройство,
    /// смена sample rate, захват микрофона созвоном). Без перезапуска запись «отваливается».
    private func installConfigObserver() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.handleConfigChange() }
    }

    private func removeConfigObserver() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
    }

    private func handleConfigChange() {
        guard running, !restarting else { return }
        Self.log("⚠️ AVAudioEngineConfigurationChange — аудиомаршрут сменился, перезапуск движка")
        onNotice?("🔄 Сменилось аудиоустройство — переподключаю запись")
        restartEngine()
    }

    /// Снять старый tap, перечитать формат входа (он мог измениться!), пересоздать
    /// converter под новый формат, поставить tap, запустить движок.
    private func restartEngine() {
        guard running, !restarting else { return }
        restarting = true
        defer { restarting = false }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else {
            Self.log("restart: формат входа 0 — устройство ещё не готово, ретрай через 1.5с")
            scheduleRestartRetry()
            return
        }
        converter = AVAudioConverter(from: fmt, to: targetFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
            lock.lock(); watchdogPrev = bufferTotal; lock.unlock()   // не дать watchdog сработать сразу
            Self.log("✓ движок перезапущен, вход \(Int(fmt.sampleRate))Hz")
        } catch {
            Self.log("✗ перезапуск не удался: \(error.localizedDescription) — ретрай через 1.5с")
            scheduleRestartRetry()
        }
    }

    private func scheduleRestartRetry() {
        guard running else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.running, !self.engine.isRunning else { return }
            self.restartEngine()
        }
    }

    // MARK: - Watchdog (страховка, если config-change нотификация не пришла)

    private func startWatchdog() {
        watchdog?.invalidate()
        lock.lock(); watchdogPrev = bufferTotal; lock.unlock()
        let interval = max(6.0, chunkSeconds * 0.5)
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
        watchdog = t
    }

    private func watchdogTick() {
        guard running, !restarting else { return }
        lock.lock(); let total = bufferTotal; let prev = watchdogPrev; watchdogPrev = bufferTotal; lock.unlock()
        if total == prev {
            // ни одного аудио-буфера за интервал при активной записи → движок завис/встал
            Self.log("watchdog: 0 новых буферов (engine.isRunning=\(engine.isRunning)) — перезапуск движка")
            onNotice?("🔄 Запись подвисла — переподключаю микрофон")
            restartEngine()
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

        // (2) накопление для whisper + счётчик буферов для watchdog
        lock.lock()
        bufferTotal += 1
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
        let pipeline = transcriptionPipeline
        Task { await pipeline.enqueue(wav) }
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
