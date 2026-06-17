import AppKit
import Carbon.HIToolbox

/// Глобальный системный хоткей через Carbon RegisterEventHotKey.
/// НЕ требует Accessibility (в отличие от CGEventTap) и консумит сочетание —
/// поэтому ⌘F5 не триггерит VoiceOver. Используется для memo-диктофона (Phase 3).
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onFire: () -> Void
    private let id: UInt32

    private static var registry: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1

    /// keyCode — Carbon virtual key (например kVK_F5 = 96). modifiers — cmdKey/optionKey/…
    init?(keyCode: UInt32, modifiers: UInt32, onFire: @escaping () -> Void) {
        self.onFire = onFire
        self.id = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            GlobalHotKey.registry[hk.id]?.onFire()
            return noErr
        }, 1, &eventType, nil, &handler)

        let hotID = EventHotKeyID(signature: OSType(0x534c5243 /* 'SLRC' */), id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        GlobalHotKey.registry[id] = self
    }

    deinit {
        if let ref = ref { UnregisterEventHotKey(ref) }
        if let handler = handler { RemoveEventHandler(handler) }
        GlobalHotKey.registry[id] = nil
    }
}
