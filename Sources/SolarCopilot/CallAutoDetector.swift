import Foundation
import CoreAudio

/// Автозапись звонков: следит, какое приложение держит микрофон (CoreAudio process
/// objects, macOS 14.2+). Звонковое приложение (Zoom/Telegram/FaceTime/браузер…)
/// держит вход дольше порога → `onCallStarted`; отпустило дольше паузы → `onCallEnded`.
/// Сам копилот (своя запись/диктовка) в расчёт не идёт.
@MainActor
final class CallAutoDetector {
    /// Приложения звонков: префикс bundle ID → (имя для UI, сколько секунд держать вход до старта).
    /// Браузеры с длинным порогом — микрофон там бывает и не для созвона (голосовые, диктовка).
    private static let callApps: [(prefix: String, name: String, minSeconds: Double)] = [
        ("us.zoom.xos", "Zoom", 4),
        ("com.tdesktop.Telegram", "Telegram", 4),
        ("ru.keepcoder.Telegram", "Telegram", 4),
        ("com.apple.avconferenced", "FaceTime", 4),
        ("net.whatsapp.WhatsApp", "WhatsApp", 4),
        ("com.microsoft.teams", "Teams", 4),
        ("com.tinyspeck.slackmacgap", "Slack", 4),
        ("com.hnc.Discord", "Discord", 4),
        ("com.google.Chrome", "браузер", 15),
        ("com.apple.WebKit.GPU", "браузер", 15),
        ("company.thebrowser.Browser", "браузер", 15),
        ("com.microsoft.edgemac", "браузер", 15),
        ("ru.yandex.desktop.yandex-browser", "браузер", 15),
    ]
    /// Сколько микрофон должен быть свободен, чтобы считать звонок законченным.
    private let endGraceSeconds: Double = 15

    var onCallStarted: ((String) -> Void)?
    var onCallEnded: (() -> Void)?

    private var timer: Timer?
    private var activeSince: [String: Date] = [:]   // имя приложения → с какого момента держит вход
    private var inCall = false
    private var idleSince: Date?

    static var supported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    func start() {
        guard timer == nil, Self.supported else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        activeSince.removeAll()
        inCall = false
        idleSince = nil
    }

    private func tick() {
        let now = Date()
        let using = Self.callAppsUsingMic()
        activeSince = activeSince.filter { using.contains($0.key) }
        for name in using where activeSince[name] == nil { activeSince[name] = now }

        if inCall {
            if using.isEmpty {
                if idleSince == nil { idleSince = now }
                if now.timeIntervalSince(idleSince!) >= endGraceSeconds {
                    inCall = false
                    idleSince = nil
                    AudioRecorder.log("CALL-AUTO end (mic released \(Int(endGraceSeconds))s)")
                    onCallEnded?()
                }
            } else {
                idleSince = nil
            }
            return
        }

        for app in Self.callApps {
            guard let since = activeSince[app.name], now.timeIntervalSince(since) >= app.minSeconds else { continue }
            inCall = true
            idleSince = nil
            AudioRecorder.log("CALL-AUTO start: \(app.name)")
            onCallStarted?(app.name)
            return
        }
    }

    /// Имена звонковых приложений, у которых сейчас идёт звонок: и ввод с микрофона,
    /// и вывод звука одновременно. Голосовое в Telegram/WhatsApp держит только вход
    /// (вывод выключен) — его звонком не считаем (07.11: голосовые улетали Альтрону).
    /// Вход и выход могут жить в разных процессах одного приложения (Chrome helper),
    /// поэтому собираем по имени приложения.
    private static func callAppsUsingMic() -> Set<String> {
        guard #available(macOS 14.2, *) else { return [] }
        var inputs = Set<String>(), outputs = Set<String>()
        for id in processObjects() {
            guard let bid = bundleID(id),
                  let app = callApps.first(where: { bid.hasPrefix($0.prefix) }) else { continue }
            if uint32(id, kAudioProcessPropertyIsRunningInput) == 1 { inputs.insert(app.name) }
            if uint32(id, kAudioProcessPropertyIsRunningOutput) == 1 { outputs.insert(app.name) }
        }
        return inputs.intersection(outputs)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    @available(macOS 14.2, *)
    private static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    @available(macOS 14.2, *)
    private static func bundleID(_ id: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }
}
