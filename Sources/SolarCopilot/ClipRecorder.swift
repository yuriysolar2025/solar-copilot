import Foundation
import AVFoundation

/// Лёгкий рекордер короткого клипа для диктовки (Phase 5): системный mic →
/// 16kHz mono Int16 → wav в /tmp. Старт синхронный на main (так AVAudioEngine
/// надёжно отдаёт буферы; конфигурация движка с фонового потока их теряет —
/// проверено: фоновый старт давал пустые wav). На Bluetooth первый холодный старт
/// `engine.start()` может занять ~1-2с (HFP) — звук Tink звучит, КОГДА движок реально
/// готов = сигнал «говори». Тап-vs-удержание считается по таймстампу события клавиши,
/// поэтому эта задержка не ломает детект (см. DictationController).
final class ClipRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16000, channels: 1, interleaved: true)!
    private let ioQueue = DispatchQueue(label: "com.solar.copilot.clipio")
    private var writer: WAVFileWriter?
    private(set) var url: URL?
    private var running = false

    var isRecording: Bool { running }

    /// true если запись стартовала. Синхронно на вызывающем потоке (main).
    @discardableResult
    func start() -> Bool {
        guard !running else { return false }
        let input = engine.inputNode
        let inFmt = input.inputFormat(forBus: 0)
        guard inFmt.sampleRate > 0 else { return false }
        converter = AVAudioConverter(from: inFmt, to: target)

        let u = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictate-\(Int(Date().timeIntervalSince1970 * 1000)).wav")
        url = u
        writer = WAVFileWriter(url: u, sampleRate: 16000)

        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buf, _ in
            self?.process(buf)
        }
        do {
            engine.prepare()
            try engine.start()
            running = true
            return true
        } catch {
            input.removeTap(onBus: 0)
            writer = nil; url = nil
            return false
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true; inStatus.pointee = .haveData; return buffer
        }
        if status == .error || err != nil { return }
        guard let ch = out.int16ChannelData, out.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        let writer = self.writer
        ioQueue.async { writer?.append(samples) }
    }

    /// Стоп → финализирует wav, возвращает URL (или nil если ничего не записалось).
    func stop(completion: @escaping (URL?) -> Void) {
        guard running else { completion(nil); return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        let w = writer; writer = nil
        let u = url; url = nil
        ioQueue.async {
            w?.finalize()
            let attrs = try? FileManager.default.attributesOfItem(atPath: u?.path ?? "")
            let size = (attrs?[.size] as? Int) ?? 0
            DispatchQueue.main.async {
                completion(size > 1024 ? u : nil)
            }
        }
    }
}
