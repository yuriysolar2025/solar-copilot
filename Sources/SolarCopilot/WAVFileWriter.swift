import Foundation

/// Стриминговая запись WAV (PCM16 mono) на диск по мере поступления сэмплов.
/// Заголовок пишется с нулевыми размерами и патчится реальными в finalize().
final class WAVFileWriter {
    let url: URL
    private let handle: FileHandle
    private var dataBytes: Int = 0

    init?(url: URL, sampleRate: Int) {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = h
        try? h.write(contentsOf: WAVFileWriter.header(dataSize: 0, sampleRate: sampleRate))
    }

    func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        let d = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try? handle.write(contentsOf: d)
        dataBytes += d.count
    }

    func finalize() {
        let riff = UInt32(36 + dataBytes).littleEndian
        let dataSz = UInt32(dataBytes).littleEndian
        try? handle.seek(toOffset: 4)
        try? handle.write(contentsOf: withUnsafeBytes(of: riff) { Data($0) })
        try? handle.seek(toOffset: 40)
        try? handle.write(contentsOf: withUnsafeBytes(of: dataSz) { Data($0) })
        try? handle.close()
    }

    /// Чинит placeholder-заголовок orphan WAV после crash по фактическому размеру файла.
    static func repairHeader(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.intValue >= 44,
              let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        let dataBytes = size.intValue - 44
        var riff = UInt32(36 + dataBytes).littleEndian
        var dataSz = UInt32(dataBytes).littleEndian
        do {
            try handle.seek(toOffset: 4)
            try withUnsafeBytes(of: &riff) { try handle.write(contentsOf: Data($0)) }
            try handle.seek(toOffset: 40)
            try withUnsafeBytes(of: &dataSz) { try handle.write(contentsOf: Data($0)) }
            return true
        } catch { return false }
    }

    static func header(dataSize: Int, sampleRate: Int) -> Data {
        var d = Data()
        let byteRate = sampleRate * 2
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + dataSize)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(dataSize))
        return d
    }
}
