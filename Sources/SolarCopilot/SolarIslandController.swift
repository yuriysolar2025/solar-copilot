import AppKit
import CoreGraphics
import Foundation
import Network

enum SolarIslandState: String, Codable {
    case idle
    case listening
    case thinking
    case insight
    case actionRequired = "action_required"
    case done
    case error

    var title: String {
        switch self {
        case .idle: return "Альтрон"
        case .listening: return "Слушаю"
        case .thinking: return "Думаю"
        case .insight: return "Есть инсайт"
        case .actionRequired: return "Ждёт действие"
        case .done: return "Готово"
        case .error: return "Ошибка"
        }
    }

    var tint: NSColor {
        switch self {
        case .idle: return NSColor(calibratedRed: 0.22, green: 0.78, blue: 0.92, alpha: 1)
        case .listening: return NSColor(calibratedRed: 0.98, green: 0.23, blue: 0.27, alpha: 1)
        case .thinking: return NSColor(calibratedRed: 0.55, green: 0.48, blue: 1.0, alpha: 1)
        case .insight: return NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.22, alpha: 1)
        case .actionRequired: return NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.16, alpha: 1)
        case .done: return NSColor(calibratedRed: 0.22, green: 0.86, blue: 0.46, alpha: 1)
        case .error: return NSColor(calibratedRed: 1.0, green: 0.18, blue: 0.22, alpha: 1)
        }
    }
}

struct SolarIslandAction: Codable {
    var id: String
    var label: String
}

struct SolarIslandEvent: Codable {
    var source: String?
    var type: String?
    var state: SolarIslandState?
    var title: String?
    var body: String?
    var actions: [SolarIslandAction]?
    var ttlSec: Double?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case source, type, state, title, body, actions
        case ttlSec = "ttl_sec"
        case createdAt = "created_at"
    }
}

@MainActor
final class SolarIslandController {
    private let port: UInt16 = 8765
    private var listener: NWListener?
    private var panel: NSPanel?
    private var root: SolarIslandView?
    private var expanded = false
    private var manualDragging = false
    private var recordingActive = false
    private var dictatingActive = false
    private var voiceAssistantActive = false
    private var currentState: SolarIslandState = .idle
    private var events: [SolarIslandEvent] = []
    private var hideWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var quietMode: Bool {
        UserDefaults.standard.object(forKey: "solarIslandQuietMode") as? Bool ?? false
    }
    private var cameraOffsetX: Double {
        UserDefaults.standard.object(forKey: "solarIslandCameraOffsetX") as? Double ?? -9
    }
    private var topInset: Double {
        UserDefaults.standard.object(forKey: "solarIslandTopInset") as? Double ?? 0
    }

    var onAction: ((String) -> Void)?
    var onDrop: ((SolarIslandEvent) -> Void)?
    var onShowTranscript: (() -> Void)?

    private var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("SolarCopilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var eventLogURL: URL { appSupportDir.appendingPathComponent("island-events.jsonl") }

    func show() {
        if panel == nil { buildPanel() }
        panel?.orderFrontRegardless()
        startHTTP()
        render()
    }

    func hide() {
        panel?.orderOut(nil)
        stopHTTP()
    }

    func setQuietMode(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "solarIslandQuietMode")
        render()
    }

    func resetPosition() {
        let size = expanded ? expandedSize : collapsedSize
        positionPanel(size: size, mode: .notchAnchor)
    }

    func setRecording(_ on: Bool) {
        recordingActive = on
        accept(SolarIslandEvent(
            source: "copilot",
            type: "state",
            state: on ? .listening : .done,
            title: on ? "Слушаю звонок" : "Разбор готов",
            body: on ? "Copilot пишет звук и собирает транскрипт." : "Запись остановлена. Сводка появится в транскрипте.",
            actions: nil,
            ttlSec: on ? nil : 8,
            createdAt: nil
        ))
    }

    func setDictating(_ on: Bool) {
        dictatingActive = on
        render()
    }

    func setVoiceAssistant(_ on: Bool, status: String? = nil) {
        voiceAssistantActive = on
        accept(SolarIslandEvent(
            source: "gpt-live",
            type: "state",
            state: on ? .listening : .idle,
            title: on ? "Альтрон слушает" : "Голосовой режим выключен",
            body: status,
            actions: nil,
            ttlSec: on ? nil : 5,
            createdAt: nil
        ))
    }

    func showInsight(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        accept(SolarIslandEvent(
            source: "copilot",
            type: "insight",
            state: .insight,
            title: "Есть подсказка",
            body: clean,
            actions: nil,
            ttlSec: 18,
            createdAt: nil
        ))
    }

    func setError(_ text: String) {
        accept(SolarIslandEvent(
            source: "copilot",
            type: "error",
            state: .error,
            title: "Ошибка",
            body: text,
            actions: nil,
            ttlSec: nil,
            createdAt: nil
        ))
    }

    /// Временная деградация вторичного компонента (например, Whisper).
    /// Не меняет recordingActive и сама исчезает; запись продолжает идти.
    func showWarning(_ text: String, ttl: Double = 10) {
        accept(SolarIslandEvent(
            source: "copilot",
            type: "warning",
            state: .actionRequired,
            title: "Транскрипция задерживается",
            body: text,
            actions: nil,
            ttlSec: ttl,
            createdAt: nil
        ))
    }

    func clearWarning() {
        guard recordingActive else { return }
        setRecording(true)
    }

    private func buildPanel() {
        let size = collapsedSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        p.isFloatingPanel = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false

        let v = SolarIslandView(frame: NSRect(origin: .zero, size: size))
        v.onClick = { [weak self] in self?.onShowTranscript?() }
        v.onHover = { [weak self] inside in self?.setHoverExpanded(inside) }
        v.onDragStarted = { [weak self] in self?.startManualDrag() }
        v.onDragFinished = { [weak self] in self?.saveManualPosition() }
        v.onAction = { [weak self] id in self?.handleAction(id) }
        v.onDropText = { [weak self] text in self?.handleDropText(text) }
        v.onDropFiles = { [weak self] files in self?.handleDropFiles(files) }
        p.contentView = v
        panel = p
        root = v
        positionPanel(size: size, mode: .notchAnchor)
    }

    private var collapsedSize: NSSize { NSSize(width: 112, height: 30) }
    private var expandedSize: NSSize { NSSize(width: 376, height: 168) }

    private enum PositionMode {
        case notchAnchor
    }

    private func positionPanel(size: NSSize, mode: PositionMode) {
        guard let p = panel else { return }
        let fullFrame = anchorScreenFrame()
        let origin = NSPoint(x: fullFrame.midX - size.width / 2 + cameraOffsetX, y: fullFrame.maxY - size.height - topInset)
        let clamped = clamp(origin: origin, size: size, allowMenuBar: true)
        applyPanelFrame(NSRect(origin: clamped, size: size))
        let actual = p.frame
        AudioRecorder.log("solar island frame: desired=\(Int(clamped.x)),\(Int(clamped.y)) \(Int(size.width))x\(Int(size.height)); actual=\(Int(actual.minX)),\(Int(actual.minY)) \(Int(actual.width))x\(Int(actual.height)); screen=\(Int(fullFrame.minX)),\(Int(fullFrame.minY)) \(Int(fullFrame.width))x\(Int(fullFrame.height)); cameraOffsetX=\(Int(cameraOffsetX)); topInset=\(Int(topInset))")
    }

    private func applyPanelFrame(_ frame: NSRect) {
        guard let p = panel else { return }
        p.minSize = frame.size
        p.maxSize = frame.size
        p.contentMinSize = frame.size
        p.contentMaxSize = frame.size
        p.setFrame(frame, display: true, animate: false)
        p.orderFrontRegardless()
        p.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        root?.frame = NSRect(origin: .zero, size: frame.size)
        root?.needsLayout = true
        root?.layoutSubtreeIfNeeded()
        p.invalidateShadow()
    }

    private func saveManualPosition() {
        guard let p = panel else { return }
        let fullFrame = anchorScreenFrame()
        let frame = p.frame
        guard frame.height >= expandedSize.height - 4 else {
            manualDragging = false
            AudioRecorder.log("solar island manual position ignored: collapsed frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
            return
        }
        let offsetX = frame.midX - fullFrame.midX
        let inset = max(0, fullFrame.maxY - frame.maxY)
        UserDefaults.standard.set(offsetX, forKey: "solarIslandCameraOffsetX")
        UserDefaults.standard.set(inset, forKey: "solarIslandTopInset")
        manualDragging = false
        AudioRecorder.log("solar island manual position saved: frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)); cameraOffsetX=\(Int(offsetX)); topInset=\(Int(inset))")
        appendEvent(SolarIslandEvent(
            source: "island",
            type: "position",
            state: currentState,
            title: "Позиция сохранена",
            body: "frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)); cameraOffsetX=\(Int(offsetX)); topInset=\(Int(inset))",
            actions: nil,
            ttlSec: nil,
            createdAt: ISO8601DateFormatter().string(from: Date())
        ))
    }

    private func startManualDrag() {
        manualDragging = true
        collapseWork?.cancel()
    }

    private func anchorScreenFrame() -> NSRect {
        let mainID = CGMainDisplayID()
        if let screen = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == mainID
        }) {
            return screen.frame
        }
        if let screen = NSScreen.main {
            return screen.frame
        }
        return NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func clamp(origin: NSPoint, size: NSSize, allowMenuBar: Bool) -> NSPoint {
        let f = anchorScreenFrame()
        return NSPoint(
            x: min(max(origin.x, f.minX + 8), f.maxX - size.width - 8),
            y: min(max(origin.y, f.minY + 8), f.maxY - size.height - (allowMenuBar ? 1 : 8))
        )
    }

    private func setHoverExpanded(_ on: Bool) {
        guard !manualDragging else { return }
        collapseWork?.cancel()
        if on {
            guard !expanded else { return }
            expanded = true
            resizeForExpandedState()
        } else {
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self = self, self.expanded else { return }
                    self.expanded = false
                    self.resizeForExpandedState()
                }
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
        }
    }

    private func resizeForExpandedState() {
        let size = expanded ? expandedSize : collapsedSize
        positionPanel(size: size, mode: .notchAnchor)
        render()
    }

    private func render() {
        root?.render(state: currentState,
                     events: events,
                     expanded: expanded,
                     quiet: quietMode,
                     recording: recordingActive,
                     dictating: dictatingActive,
                     voiceAssistant: voiceAssistantActive)
    }

    private func accept(_ raw: SolarIslandEvent) {
        var event = raw
        if event.state == nil { event.state = currentState }
        if event.createdAt == nil { event.createdAt = ISO8601DateFormatter().string(from: Date()) }
        if event.actions == nil { event.actions = defaultActions }
        currentState = event.state ?? currentState
        events.insert(event, at: 0)
        if events.count > 20 { events.removeLast(events.count - 20) }
        appendEvent(event)
        if quietMode, !expanded, currentState != .listening, currentState != .error {
            currentState = .idle
        }
        render()
        scheduleTTL(event.ttlSec)
    }

    private var defaultActions: [SolarIslandAction] {
        [
            SolarIslandAction(id: "voice", label: "Альтрон Live"),
            SolarIslandAction(id: "record", label: "Запись"),
            SolarIslandAction(id: "remember", label: "Запомни"),
            SolarIslandAction(id: "task", label: "Задача"),
            SolarIslandAction(id: "summary", label: "Суммари"),
            SolarIslandAction(id: "reply", label: "Ответить"),
            SolarIslandAction(id: "snooze", label: "Отложить")
        ]
    }

    private func scheduleTTL(_ ttl: Double?) {
        hideWork?.cancel()
        guard let ttl = ttl, ttl > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.currentState = .idle
                self?.render()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ttl, execute: work)
    }

    private func appendEvent(_ event: SolarIslandEvent) {
        guard let data = try? JSONEncoder().encode(event),
              let line = String(data: data, encoding: .utf8) else { return }
        if FileManager.default.fileExists(atPath: eventLogURL.path),
           let handle = try? FileHandle(forWritingTo: eventLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        } else {
            try? (line + "\n").data(using: .utf8)?.write(to: eventLogURL)
        }
    }

    private func handleAction(_ id: String) {
        let title: String
        switch id {
        case "voice", "record": onAction?(id); return
        case "remember": title = "Запомнить"
        case "task": title = "Создать задачу"
        case "summary": title = "Суммари"
        case "reply": title = "Ответить"
        case "snooze": title = "Отложить"
        case "open": onShowTranscript?(); return
        case "history": onAction?(id); return
        default: title = id
        }
        let event = SolarIslandEvent(source: "island", type: "action", state: .actionRequired,
                                     title: title, body: "Действие из Solar Island: \(id)",
                                     actions: defaultActions, ttlSec: 8, createdAt: nil)
        accept(event)
        onAction?(id)
    }

    private func handleDropText(_ text: String) {
        let event = SolarIslandEvent(source: "island", type: "drop", state: .actionRequired,
                                     title: "Получил текст", body: text,
                                     actions: defaultActions, ttlSec: 12, createdAt: nil)
        accept(event)
        onDrop?(event)
    }

    private func handleDropFiles(_ files: [String]) {
        let body = files.joined(separator: "\n")
        let event = SolarIslandEvent(source: "island", type: "drop", state: .actionRequired,
                                     title: "Получил файл", body: body,
                                     actions: defaultActions, ttlSec: 12, createdAt: nil)
        accept(event)
        onDrop?(event)
    }

    // MARK: - Local HTTP bridge

    private func startHTTP() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] conn in self?.handleConnection(conn) }
            l.start(queue: DispatchQueue(label: "solar-island-http"))
            listener = l
            AudioRecorder.log("solar island http listening on 127.0.0.1:\(port)")
        } catch {
            AudioRecorder.log("solar island http failed: \(error.localizedDescription)")
            setError("HTTP bridge не поднялся: \(error.localizedDescription)")
        }
    }

    private func stopHTTP() {
        listener?.cancel()
        listener = nil
    }

    nonisolated private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: DispatchQueue(label: "solar-island-conn"))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self = self else { conn.cancel(); return }
            let result = Self.httpResponse(for: data ?? Data())
            if let event = result.event {
                Task { @MainActor in self.accept(event) }
            }
            let response = result.data
            conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    nonisolated private static func httpHeader(status: String, body: String, contentType: String = "application/json") -> Data {
        let data = Data(body.utf8)
        let raw = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType); charset=utf-8\r
        Content-Length: \(data.count)\r
        Connection: close\r
        \r
        \(body)
        """
        return Data(raw.utf8)
    }

    nonisolated private static func httpResponse(for data: Data) -> (data: Data, event: SolarIslandEvent?) {
        guard let raw = String(data: data, encoding: .utf8) else {
            return (httpHeader(status: "400 Bad Request", body: #"{"ok":false,"error":"bad encoding"}"#), nil)
        }
        let headBody = raw.components(separatedBy: "\r\n\r\n")
        let head = headBody.first ?? ""
        let body = headBody.dropFirst().joined(separator: "\r\n\r\n")
        let first = head.split(separator: "\r\n").first.map(String.init) ?? ""

        if first.hasPrefix("GET /health ") {
            return (httpHeader(status: "200 OK", body: #"{"ok":true,"name":"Solar Island","port":8765}"#), nil)
        }
        if first.hasPrefix("POST /event ") {
            guard let bodyData = body.data(using: .utf8),
                  let event = try? JSONDecoder().decode(SolarIslandEvent.self, from: bodyData) else {
                return (httpHeader(status: "400 Bad Request", body: #"{"ok":false,"error":"invalid event json"}"#), nil)
            }
            return (httpHeader(status: "200 OK", body: #"{"ok":true}"#), event)
        }
        return (httpHeader(status: "404 Not Found", body: #"{"ok":false,"error":"not found"}"#), nil)
    }
}

@MainActor
final class SolarIslandView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDragStarted: (() -> Void)?
    var onDragFinished: (() -> Void)?
    var onAction: ((String) -> Void)?
    var onDropText: ((String) -> Void)?
    var onDropFiles: (([String]) -> Void)?

    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let leftIcon = NSTextField(labelWithString: "●")
    private let rightIcon = NSTextField(labelWithString: "↗")
    private let dot = NSView()
    private let stack = NSStackView()
    private let eventsLabel = NSTextField(labelWithString: "")
    private let actions = NSStackView()
    private var tracking: NSTrackingArea?
    private var dragged = false
    private var isExpanded = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
        registerForDraggedTypes([.fileURL, .string])

        configureIconLabel(leftIcon)
        configureIconLabel(rightIcon)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4

        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail

        subtitle.font = .systemFont(ofSize: 11, weight: .regular)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.72)
        subtitle.lineBreakMode = .byTruncatingTail

        stack.orientation = .vertical
        stack.spacing = 1
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)

        eventsLabel.font = .systemFont(ofSize: 12)
        eventsLabel.textColor = NSColor.white.withAlphaComponent(0.82)
        eventsLabel.lineBreakMode = .byWordWrapping
        eventsLabel.maximumNumberOfLines = 2

        actions.orientation = .vertical
        actions.spacing = 6
        actions.distribution = .fillEqually

        [leftIcon, rightIcon, dot, stack, eventsLabel, actions].forEach {
            addSubview($0)
        }
    }

    private func configureIconLabel(_ label: NSTextField) {
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.wantsLayer = true
        label.layer?.cornerRadius = 8
        label.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        if h <= 32 {
            leftIcon.frame = NSRect(x: 7, y: 4, width: 22, height: 22)
            rightIcon.frame = NSRect(x: max(7, w - 29), y: 4, width: 22, height: 22)
            dot.frame = NSRect(x: (w - 6) / 2, y: (h - 6) / 2, width: 6, height: 6)
            stack.frame = .zero
            eventsLabel.frame = .zero
            actions.frame = .zero
            return
        }

        leftIcon.frame = NSRect(x: 18, y: h - 31, width: 24, height: 22)
        rightIcon.frame = NSRect(x: w - 42, y: h - 31, width: 24, height: 22)
        dot.frame = NSRect(x: 52, y: h - 23, width: 8, height: 8)
        stack.frame = NSRect(x: 72, y: h - 57, width: max(0, w - 144), height: 40)
        eventsLabel.frame = NSRect(x: 18, y: 88, width: max(0, w - 36), height: 36)
        actions.frame = NSRect(x: 18, y: 14, width: max(0, w - 36), height: 64)
    }

    func render(state: SolarIslandState,
                events: [SolarIslandEvent],
                expanded: Bool,
                quiet: Bool,
                recording: Bool,
                dictating: Bool,
                voiceAssistant: Bool) {
        isExpanded = expanded
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.015, alpha: expanded ? 0.97 : 0.98).cgColor
        layer?.cornerRadius = expanded ? 20 : 15
        layer?.borderWidth = 1
        layer?.borderColor = state.tint.withAlphaComponent(expanded ? 0.42 : 0.16).cgColor
        let recordTint = (recording || dictating || voiceAssistant)
            ? NSColor(calibratedRed: 1.0, green: 0.12, blue: 0.16, alpha: 1)
            : state.tint
        leftIcon.layer?.backgroundColor = recordTint.withAlphaComponent((recording || dictating || voiceAssistant) ? 0.72 : (expanded ? 0.22 : 0.18)).cgColor
        rightIcon.layer?.backgroundColor = NSColor.white.withAlphaComponent(expanded ? 0.14 : 0.10).cgColor
        leftIcon.toolTip = voiceAssistant ? "Выключить Альтрон Live" : "Включить Альтрон Live"
        rightIcon.toolTip = "Открыть транскрипт"
        dot.layer?.backgroundColor = state.tint.cgColor
        dot.layer?.shadowColor = state.tint.cgColor
        dot.layer?.shadowOpacity = 0.85
        dot.layer?.shadowRadius = 8
        dot.layer?.shadowOffset = .zero

        let top = events.first
        title.stringValue = top?.title?.isEmpty == false ? top!.title! : state.title
        subtitle.stringValue = quiet ? "Тихий режим · Copilot" : "Copilot · \(state.title)"
        eventsLabel.stringValue = top?.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? top!.body!
            : "Пульт звонка: запись, открыть транскрипт, отметить важное или follow-up."

        leftIcon.isHidden = false
        rightIcon.isHidden = false
        dot.isHidden = !expanded
        stack.isHidden = !expanded
        eventsLabel.isHidden = !expanded
        actions.isHidden = !expanded
        needsLayout = true
        if !expanded { return }
        rebuildActions(top?.actions ?? defaultActions)
    }

    private var defaultActions: [SolarIslandAction] {
        [
            SolarIslandAction(id: "voice", label: "Альтрон Live"),
            SolarIslandAction(id: "record", label: "Запись"),
            SolarIslandAction(id: "open", label: "Открыть"),
            SolarIslandAction(id: "history", label: "История расшифровок"),
            SolarIslandAction(id: "remember", label: "Запомни"),
            SolarIslandAction(id: "task", label: "Задача"),
            SolarIslandAction(id: "summary", label: "Суммари"),
            SolarIslandAction(id: "reply", label: "Ответить"),
            SolarIslandAction(id: "snooze", label: "Отложить")
        ]
    }

    private func rebuildActions(_ items: [SolarIslandAction]) {
        actions.arrangedSubviews.forEach { v in actions.removeArrangedSubview(v); v.removeFromSuperview() }
        let items = Array(normalizedActionItems(items).prefix(5))
        let rows = [Array(items.prefix(2)), Array(items.dropFirst(2))]
        for rowItems in rows where !rowItems.isEmpty {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 7
            row.distribution = .fillEqually
            for item in rowItems {
                let b = NSButton(title: actionTitle(for: item.id), target: self, action: #selector(actionButton(_:)))
                b.bezelStyle = .regularSquare
                b.isBordered = false
                b.font = .systemFont(ofSize: 11, weight: .semibold)
                b.contentTintColor = .white
                b.identifier = NSUserInterfaceItemIdentifier(item.id)
                b.toolTip = item.label
                b.wantsLayer = true
                b.layer?.cornerRadius = 8
                b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.11).cgColor
                row.addArrangedSubview(b)
            }
            actions.addArrangedSubview(row)
        }
    }

    private func normalizedActionItems(_ items: [SolarIslandAction]) -> [SolarIslandAction] {
        let preferred = ["voice", "record", "open", "history", "remember", "task"]
        var byId: [String: SolarIslandAction] = [:]
        for item in defaultActions { byId[item.id] = item }
        for item in items { byId[item.id] = item }
        return preferred.compactMap { byId[$0] }
    }

    private func actionTitle(for id: String) -> String {
        switch id {
        case "voice": return "Альтрон Live"
        case "record": return "Запись"
        case "open": return "Текущий разговор"
        case "history": return "История диктовок"
        case "remember": return "Важно в сводку"
        case "task": return "Отметить задачу"
        case "summary": return "Суммари"
        case "reply": return "Ответить"
        case "snooze": return "Отложить"
        default: return id
        }
    }

    @objc private func actionButton(_ sender: NSButton) {
        onAction?(sender.identifier?.rawValue ?? sender.title)
    }

    override func mouseDown(with event: NSEvent) {
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        if !dragged {
            dragged = true
            onDragStarted?()
        }
        guard let window else { return }
        let origin = NSPoint(x: window.frame.origin.x + event.deltaX,
                             y: window.frame.origin.y - event.deltaY)
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged {
            if !isExpanded, leftIcon.frame.contains(convert(event.locationInWindow, from: nil)) {
                onAction?("voice")
            } else if !isExpanded, rightIcon.frame.contains(convert(event.locationInWindow, from: nil)) {
                onAction?("open")
            } else {
                onClick?()
            }
        } else {
            onDragFinished?()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            onDropFiles?(urls.map(\.path))
            return true
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            onDropText?(text)
            return true
        }
        return false
    }
}
