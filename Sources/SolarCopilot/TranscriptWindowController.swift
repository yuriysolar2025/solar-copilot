import AppKit

/// Окно сессии: сверху — фид ассистента (подсказки 💡 + финальная сводка),
/// снизу — живой транскрипт. Нативно заменяет Telegram-топики из MVP.
final class TranscriptWindowController {
    private var window: NSWindow?
    private var assistantView: NSTextView?
    private var transcriptView: NSTextView?

    func show(transcript: TranscriptStore, assistant: TranscriptStore) {
        if window == nil { build() }
        refresh(transcript: transcript, assistant: assistant)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 580),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        w.title = L.appName
        w.isReleasedWhenClosed = false

        let split = NSSplitView(frame: w.contentView!.bounds)
        split.isVertical = false
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]

        let (aPane, aView) = Self.pane(title: L.assistantTitle)
        let (tPane, tView) = Self.pane(title: L.transcriptTitle)
        split.addArrangedSubview(aPane)
        split.addArrangedSubview(tPane)

        w.contentView = split
        w.center()
        self.window = w
        self.assistantView = aView
        self.transcriptView = tView
        DispatchQueue.main.async { split.setPosition(230, ofDividerAt: 0) }
    }

    /// Панель = заголовок + прокручиваемый текст.
    private static func pane(title: String) -> (NSView, NSTextView) {
        let container = NSView()
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let tv = NSTextView()
        tv.isEditable = false
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 13)
        tv.textContainerInset = NSSize(width: 10, height: 8)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv

        container.addSubview(label)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return (container, tv)
    }

    func refresh(transcript: TranscriptStore, assistant: TranscriptStore) {
        if let av = assistantView {
            av.string = assistant.lines.isEmpty ? L.assistantPlaceholder : assistant.plainText
            av.scrollToEndOfDocument(nil)
        }
        if let tv = transcriptView {
            tv.string = transcript.fullText
            tv.scrollToEndOfDocument(nil)
        }
    }
}
