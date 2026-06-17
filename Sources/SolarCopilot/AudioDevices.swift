import Foundation
import CoreAudio

/// Резолв аудиоустройств. Phase 3 — avfoundation-индексы для ffmpeg (memo-диктофон).
/// Phase 4 — CoreAudio: вход для AVAudioEngine (RecordCall = обе стороны) + output-toggle.
enum AudioDevices {
    /// `ffmpeg -f avfoundation -list_devices` → [(index, name)] из audio-секции.
    static func avfoundationInputs(ffmpeg: String) -> [(index: Int, name: String)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-f", "avfoundation", "-list_devices", "true", "-i", ""]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        do { try p.run() } catch { return [] }
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""

        var result: [(Int, String)] = []
        var inAudio = false
        let re = try? NSRegularExpression(pattern: #"\]\s+\[(\d+)\]\s+(.+)$"#)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.contains("AVFoundation audio devices") { inAudio = true; continue }
            if line.contains("AVFoundation video devices") { inAudio = false; continue }
            guard inAudio, let re = re else { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let m = re.firstMatch(in: line, range: range),
                  let idxR = Range(m.range(at: 1), in: line),
                  let nameR = Range(m.range(at: 2), in: line),
                  let idx = Int(line[idxR]) else { continue }
            result.append((idx, String(line[nameR]).trimmingCharacters(in: .whitespaces)))
        }
        return result
    }

    /// avfoundation-индекс по приоритету имён (как resolve_mic_index в daemon.py).
    /// Возвращает (":N", имя) или nil.
    static func avfoundationIndex(ffmpeg: String, preferring names: [String]) -> (arg: String, name: String)? {
        let devs = avfoundationInputs(ffmpeg: ffmpeg)
        for needle in names {
            for d in devs where d.name.lowercased().contains(needle.lowercased()) {
                return (":\(d.index)", d.name)
            }
        }
        return nil
    }

    // ─────────── CoreAudio (Phase 4) ───────────

    private static var systemObject: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func deviceName(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let st = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        return st == noErr ? (name as String) : ""
    }

    /// Есть ли у устройства каналы в заданном scope (Input/Output).
    private static func hasChannels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.contains { $0.mNumberChannels > 0 }
    }

    /// Входное устройство по приоритету имён (RecordCall → … → mic).
    static func inputDeviceID(preferring names: [String]) -> (id: AudioDeviceID, name: String)? {
        let named = allDeviceIDs().map { ($0, deviceName($0)) }.filter { hasChannels($0.0, scope: kAudioDevicePropertyScopeInput) }
        for needle in names {
            for (id, name) in named where name.lowercased().contains(needle.lowercased()) { return (id, name) }
        }
        return nil
    }

    static func outputDeviceID(named name: String) -> (id: AudioDeviceID, name: String)? {
        for id in allDeviceIDs() {
            let n = deviceName(id)
            if n.lowercased().contains(name.lowercased()), hasChannels(id, scope: kAudioDevicePropertyScopeOutput) {
                return (id, n)
            }
        }
        return nil
    }

    static func defaultInputID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func defaultOutputName() -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id) == noErr else { return "" }
        return deviceName(id)
    }

    @discardableResult
    static func setDefaultOutput(id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = id
        return AudioObjectSetPropertyData(systemObject, &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &dev) == noErr
    }

    /// AirPods для возврата с call-устройства: точное имя, иначе любой output
    /// с «AirPods» без «BH»/«Звонок» (порт output_toggle.lua findAirPods).
    static func airpodsOutputID(preferredName: String) -> (id: AudioDeviceID, name: String)? {
        if let exact = outputDeviceID(named: preferredName) { return exact }
        for id in allDeviceIDs() {
            let n = deviceName(id)
            let low = n.lowercased()
            if low.contains("airpods"), !low.contains("bh"), !low.contains("звонок"),
               hasChannels(id, scope: kAudioDevicePropertyScopeOutput) {
                return (id, n)
            }
        }
        return nil
    }
}
