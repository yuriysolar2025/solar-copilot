import AppKit

private struct DictationHistoryEntry {
    let timestamp: String
    let mode: String
    let text: String
}

/// Отдельное окно всей истории Right Cmd: список слева, полный текст справа.
/// Источник — append-only `~/Library/Logs/dictate-history.md`.
@MainActor
final class DictationHistoryWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var window: NSWindow?
    private var tableView: NSTableView?
    private var detailView: NSTextView?
    private var countLabel: NSTextField?
    private var searchField: NSSearchField?
    private var allEntries: [DictationHistoryEntry] = []
    private var visibleEntries: [DictationHistoryEntry] = []

    private var historyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/dictate-history.md")
    }

    func show() {
        if window == nil { build() }
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "История расшифровок"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 640, height: 420)

        let root = NSView(frame: w.contentView?.bounds ?? .zero)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.autoresizingMask = [.width, .height]

        let header = NSVisualEffectView()
        header.material = .headerView
        header.blendingMode = .withinWindow
        header.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "История расшифровок")
        title.font = .systemFont(ofSize: 18, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let count = NSTextField(labelWithString: "")
        count.font = .systemFont(ofSize: 11, weight: .medium)
        count.textColor = .secondaryLabelColor
        count.translatesAutoresizingMaskIntoConstraints = false

        let search = NSSearchField()
        search.placeholderString = "Поиск по истории"
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false

        let copy = NSButton(title: "Копировать", target: self, action: #selector(copySelected))
        copy.bezelStyle = .rounded
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Копировать")
        copy.imagePosition = .imageLeading
        copy.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(title)
        header.addSubview(count)
        header.addSubview(search)
        header.addSubview(copy)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 64
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history")))

        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.documentView = table
        listScroll.drawsBackground = true
        listScroll.backgroundColor = .controlBackgroundColor

        let detailScroll = NSScrollView()
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detailScroll.drawsBackground = false

        let detail = NSTextView()
        detail.isEditable = false
        detail.isSelectable = true
        detail.isRichText = false
        detail.drawsBackground = false
        detail.font = .systemFont(ofSize: 15)
        detail.textColor = .labelColor
        detail.textContainerInset = NSSize(width: 22, height: 20)
        detail.isVerticallyResizable = true
        detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true
        detailScroll.documentView = detail

        split.addArrangedSubview(listScroll)
        split.addArrangedSubview(detailScroll)

        root.addSubview(header)
        root.addSubview(split)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 88),

            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            title.topAnchor.constraint(equalTo: header.topAnchor, constant: 31),
            count.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            count.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),

            copy.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -18),
            copy.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: 8),
            search.trailingAnchor.constraint(equalTo: copy.leadingAnchor, constant: -10),
            search.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: 8),
            search.widthAnchor.constraint(equalToConstant: 220),

            split.topAnchor.constraint(equalTo: header.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        w.contentView = root
        w.center()
        window = w
        tableView = table
        detailView = detail
        countLabel = count
        searchField = search
        DispatchQueue.main.async { split.setPosition(270, ofDividerAt: 0) }
    }

    private func reload() {
        let source = (try? String(contentsOf: historyURL, encoding: .utf8)) ?? ""
        allEntries = Self.parse(source).reversed()
        applyFilter(searchField?.stringValue ?? "")
    }

    private static func parse(_ source: String) -> [DictationHistoryEntry] {
        source.components(separatedBy: "\n## ").compactMap { rawBlock in
            var block = rawBlock
            if block.hasPrefix("## ") { block.removeFirst(3) }
            guard let firstNewline = block.firstIndex(of: "\n") else { return nil }
            let header = String(block[..<firstNewline]).trimmingCharacters(in: .whitespaces)
            let body = String(block[block.index(after: firstNewline)...])
            guard let rawMarker = body.range(of: "\n\n**raw:**") else { return nil }
            let clean = String(body[..<rawMarker.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            let mode: String
            let timestamp: String
            if let left = header.lastIndex(of: "["), header.hasSuffix("]") {
                timestamp = String(header[..<left]).trimmingCharacters(in: .whitespaces)
                mode = String(header[header.index(after: left)..<header.index(before: header.endIndex)])
            } else {
                timestamp = header
                mode = "raw"
            }
            return DictationHistoryEntry(timestamp: timestamp, mode: mode, text: clean)
        }
    }

    private func applyFilter(_ query: String) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleEntries = needle.isEmpty
            ? allEntries
            : allEntries.filter { $0.text.localizedCaseInsensitiveContains(needle) || $0.timestamp.contains(needle) }
        countLabel?.stringValue = "\(visibleEntries.count) из \(allEntries.count)"
        tableView?.reloadData()
        if visibleEntries.isEmpty {
            detailView?.string = needle.isEmpty ? "История пока пуста." : "Ничего не найдено."
        } else {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            showEntry(at: 0)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField?.stringValue ?? "")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleEntries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleEntries.indices.contains(row) else { return nil }
        let entry = visibleEntries[row]
        let id = NSUserInterfaceItemIdentifier("DictationHistoryCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            v.identifier = id
            let title = NSTextField(labelWithString: "")
            title.identifier = NSUserInterfaceItemIdentifier("date")
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            title.textColor = .secondaryLabelColor
            let preview = NSTextField(labelWithString: "")
            preview.identifier = NSUserInterfaceItemIdentifier("preview")
            preview.font = .systemFont(ofSize: 13)
            preview.lineBreakMode = .byTruncatingTail
            preview.maximumNumberOfLines = 2
            v.addSubview(title)
            v.addSubview(preview)
            return v
        }()
        let date = cell.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "date" }
        let preview = cell.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "preview" }
        date?.stringValue = entry.timestamp
        preview?.stringValue = entry.text.replacingOccurrences(of: "\n", with: " ")
        date?.frame = NSRect(x: 12, y: 39, width: max(0, tableView.bounds.width - 24), height: 16)
        preview?.frame = NSRect(x: 12, y: 7, width: max(0, tableView.bounds.width - 24), height: 32)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showEntry(at: tableView?.selectedRow ?? -1)
    }

    private func showEntry(at index: Int) {
        guard visibleEntries.indices.contains(index) else { return }
        let entry = visibleEntries[index]
        detailView?.string = "\(entry.timestamp)\n\n\(entry.text)"
        detailView?.scrollToBeginningOfDocument(nil)
    }

    @objc private func copySelected() {
        guard let row = tableView?.selectedRow, visibleEntries.indices.contains(row) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(visibleEntries[row].text, forType: .string)
    }
}
