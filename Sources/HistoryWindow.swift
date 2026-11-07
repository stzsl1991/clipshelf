import AppKit
import ApplicationServices

func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let view = NSTextField(labelWithString: text); view.font = .systemFont(ofSize: size, weight: weight); view.textColor = color
    view.lineBreakMode = .byTruncatingTail; return view
}
func symbol(_ name: String, size: CGFloat = 18) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .medium))
}
func actionButton(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
    let button = NSButton(title: title, target: target, action: action); button.bezelStyle = .rounded; return button
}
func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 8) -> NSStackView {
    let view = NSStackView(views: views); view.orientation = vertical ? .vertical : .horizontal; view.spacing = spacing
    view.alignment = vertical ? .leading : .centerY; return view
}
func anchor(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
    child.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(child)
    NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset), child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset), child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset), child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)])
}
final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
final class ClipCell: NSTableCellView {
    let icon = NSImageView()
    let headline = label("", size: 13, weight: .medium)
    let detail = label("", size: 11, color: .secondaryLabelColor)
    let pin = NSImageView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyDown; icon.contentTintColor = .systemTeal
        pin.image = symbol("pin.fill", size: 10); pin.contentTintColor = .secondaryLabelColor
        let words = stack([headline, detail], vertical: true, spacing: 5)
        let row = stack([icon, words, pin], spacing: 12)
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), row.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 24), icon.heightAnchor.constraint(equalToConstant: 28), pin.widthAnchor.constraint(equalToConstant: 12)])
        headline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ entry: ClipEntry) {
        icon.image = symbol(entry.kind.symbol)
        headline.stringValue = entry.title
        let date = RelativeDateTimeFormatter(); date.locale = Locale(identifier: "zh_CN"); date.unitsStyle = .short
        detail.stringValue = "\(entry.sourceName) · \(date.localizedString(for: entry.copiedAt, relativeTo: Date()))"
        pin.isHidden = !entry.pinned
        setAccessibilityLabel("\(entry.title)，\(entry.kind.label)，\(detail.stringValue)")
    }
}
final class HistoryWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    let store: HistoryStore
    let monitor: ClipboardMonitor
    let preferences: Preferences
    let search = NSSearchField()
    let filter = NSSegmentedControl(labels: ["全部", "文本", "图片", "收藏"], trackingMode: .selectOne, target: nil, action: nil)
    let table = NSTableView()
    let previewText = NSTextView()
    let textScroll = NSScrollView()
    let imageView = NSImageView()
    let empty = label("复制一点内容，从这里找回来", size: 18, weight: .medium)
    let emptyHint = label("照常 ⌘C 复制，再用快捷键查看历史", size: 12, color: .secondaryLabelColor)
    let previewTitle = label("内容预览", size: 19, weight: .semibold)
    let metadata = label("", size: 11, color: .secondaryLabelColor)
    let status = label("", size: 11, color: .secondaryLabelColor)
    let countLabel = label("", size: 11, color: .secondaryLabelColor)
    let targetLabel = label("", size: 11, color: .secondaryLabelColor)
    let permissionLabel = label("", size: 12, color: .secondaryLabelColor)
    let permissionButton = NSButton()
    let pinButton = NSButton()
    let enlargeButton = NSButton()
    let pauseButton = NSButton()
    let pasteButton = NSButton()
    let plainButton = NSButton()
    let copyButton = NSButton()
    var onSettings: (() -> Void)?
    var onPause: (() -> Void)?
    var onPermission: (() -> Void)?
    var onAction: ((ClipEntry, Bool, Bool) -> Void)?
    var onCancel: (() -> Void)?
    var values: [ClipEntry] = []
    var destination: PasteDestination?
    var selected: ClipEntry? { table.selectedRow >= 0 && table.selectedRow < values.count ? values[table.selectedRow] : nil }
    private var keyMonitor: Any?
    private var imagePanel: NSPanel?
    private var currentImage: NSImage?
    private var persistentMessage: String?
    private let previewArea = NSView()

    init(store: HistoryStore, monitor: ClipboardMonitor, preferences: Preferences) {
        self.store = store; self.monitor = monitor; self.preferences = preferences
        let panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 990, height: 660), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "拾贴 · 剪贴板历史"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false; panel.minSize = NSSize(width: 880, height: 570)
        panel.level = .floating; panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel); panel.delegate = self; build()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }; return self.handleKey(event)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    private func build() {
        guard let root = window?.contentView else { return }
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let brandIcon = NSImageView(image: symbol("square.on.square", size: 25)!)
        brandIcon.contentTintColor = .systemTeal
        let brand = stack([label("拾贴", size: 23, weight: .bold), label("每一次复制，都找得到", size: 12, color: .secondaryLabelColor)], spacing: 12)
        let spacer = NSView()
        pauseButton.title = "暂停记录"; pauseButton.bezelStyle = .rounded; pauseButton.target = self; pauseButton.action = #selector(togglePause)
        let settings = actionButton("设置", target: self, action: #selector(settingsClick))
        let header = stack([brandIcon, brand, spacer, pauseButton, settings], spacing: 14)
        header.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(header)
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28), header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), header.topAnchor.constraint(equalTo: root.topAnchor, constant: 35), header.heightAnchor.constraint(equalToConstant: 38), brandIcon.widthAnchor.constraint(equalToConstant: 30)])
        search.placeholderString = "搜索文字、名称或来源应用"; search.delegate = self; search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("搜索剪贴板历史"); search.controlSize = .large
        filter.selectedSegment = 0; filter.target = self; filter.action = #selector(filterChanged)
        let tools = stack([search, filter], spacing: 16); tools.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(tools)
        NSLayoutConstraint.activate([tools.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), tools.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), tools.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 22), search.widthAnchor.constraint(greaterThanOrEqualToConstant: 380)])

        let sidebar = NSView(); sidebar.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(sidebar)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 66; table.intercellSpacing = NSSize(width: 0, height: 3)
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(doubleClick)
        table.style = .fullWidth; table.backgroundColor = .clear; table.allowsEmptySelection = false
        table.setAccessibilityLabel("复制历史列表")
        let menu = NSMenu()
        for (title, selector) in [("收藏 / 取消收藏", #selector(pinClick)), ("重命名…", #selector(renameClick)), ("删除这条记录", #selector(deleteClick))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        table.menu = menu
        let listScroll = NSScrollView(); listScroll.documentView = table; listScroll.hasVerticalScroller = true; listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(listScroll)
        countLabel.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(countLabel)
        NSLayoutConstraint.activate([countLabel.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12), countLabel.topAnchor.constraint(equalTo: sidebar.topAnchor), listScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor), listScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor), listScroll.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 10), listScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)])

        let preview = NSView(); preview.translatesAutoresizingMaskIntoConstraints = false; preview.wantsLayer = true; preview.layer?.cornerRadius = 14
        preview.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor; preview.layer?.borderWidth = 1; preview.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        root.addSubview(preview)
        pinButton.image = symbol("star"); pinButton.bezelStyle = .texturedRounded; pinButton.target = self; pinButton.action = #selector(pinClick); pinButton.toolTip = "收藏 / 取消收藏"
        pinButton.setAccessibilityLabel("收藏或取消收藏")
        let rename = actionButton("命名", target: self, action: #selector(renameClick))
        let remove = actionButton("删除", target: self, action: #selector(deleteClick))
        let previewHeader = stack([previewTitle, NSView(), pinButton, rename, remove], spacing: 8)
        previewHeader.translatesAutoresizingMaskIntoConstraints = false; preview.addSubview(previewHeader)
        metadata.translatesAutoresizingMaskIntoConstraints = false; preview.addSubview(metadata)
        previewArea.translatesAutoresizingMaskIntoConstraints = false; preview.addSubview(previewArea)
        previewText.isEditable = false; previewText.isSelectable = true; previewText.isRichText = false
        previewText.font = .monospacedSystemFont(ofSize: 14, weight: .regular); previewText.textColor = .labelColor
        previewText.drawsBackground = false; previewText.textContainerInset = NSSize(width: 4, height: 8)
        previewText.autoresizingMask = [.width]; previewText.isVerticallyResizable = true; previewText.isHorizontallyResizable = false
        previewText.textContainer?.widthTracksTextView = true
        previewText.setAccessibilityLabel("完整文本预览")
        textScroll.documentView = previewText; textScroll.hasVerticalScroller = true; textScroll.drawsBackground = false
        anchor(textScroll, in: previewArea)
        imageView.imageScaling = .scaleProportionallyDown; anchor(imageView, in: previewArea, inset: 10)
        let emptyBox = stack([empty, emptyHint], vertical: true, spacing: 12); emptyBox.alignment = .centerX
        emptyBox.translatesAutoresizingMaskIntoConstraints = false; previewArea.addSubview(emptyBox)
        emptyBox.identifier = NSUserInterfaceItemIdentifier("empty")
        NSLayoutConstraint.activate([emptyBox.centerXAnchor.constraint(equalTo: previewArea.centerXAnchor), emptyBox.centerYAnchor.constraint(equalTo: previewArea.centerYAnchor), emptyBox.widthAnchor.constraint(lessThanOrEqualTo: previewArea.widthAnchor, constant: -20)])
        enlargeButton.title = "放大图片"; enlargeButton.bezelStyle = .rounded; enlargeButton.target = self; enlargeButton.action = #selector(enlargeClick)
        enlargeButton.translatesAutoresizingMaskIntoConstraints = false; preview.addSubview(enlargeButton)
        NSLayoutConstraint.activate([previewHeader.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 20), previewHeader.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -18), previewHeader.topAnchor.constraint(equalTo: preview.topAnchor, constant: 18), previewTitle.widthAnchor.constraint(lessThanOrEqualToConstant: 280), metadata.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 20), metadata.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -20), metadata.topAnchor.constraint(equalTo: previewHeader.bottomAnchor, constant: 10), previewArea.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 16), previewArea.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -16), previewArea.topAnchor.constraint(equalTo: metadata.bottomAnchor, constant: 12), previewArea.bottomAnchor.constraint(equalTo: preview.bottomAnchor, constant: -48), enlargeButton.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -18), enlargeButton.bottomAnchor.constraint(equalTo: preview.bottomAnchor, constant: -12)])

        let footer = NSView(); footer.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(footer)
        copyButton.title = "仅复制 ⌘↩"; copyButton.bezelStyle = .rounded; copyButton.target = self; copyButton.action = #selector(copyClick)
        plainButton.title = "纯文本 ⇧↩"; plainButton.bezelStyle = .rounded; plainButton.target = self; plainButton.action = #selector(plainClick)
        pasteButton.title = "粘贴 ↩"; pasteButton.bezelStyle = .rounded; pasteButton.target = self; pasteButton.action = #selector(pasteClick); pasteButton.bezelColor = .systemTeal
        let actions = stack([copyButton, plainButton, pasteButton], spacing: 8); actions.translatesAutoresizingMaskIntoConstraints = false; footer.addSubview(actions)
        let footerWords = stack([targetLabel, status], vertical: true, spacing: 7); footerWords.translatesAutoresizingMaskIntoConstraints = false; footer.addSubview(footerWords)
        NSLayoutConstraint.activate([actions.trailingAnchor.constraint(equalTo: footer.trailingAnchor), actions.centerYAnchor.constraint(equalTo: footer.centerYAnchor), footerWords.leadingAnchor.constraint(equalTo: footer.leadingAnchor), footerWords.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12), footerWords.centerYAnchor.constraint(equalTo: footer.centerYAnchor)])
        permissionButton.title = "开启辅助功能…"; permissionButton.bezelStyle = .rounded; permissionButton.target = self; permissionButton.action = #selector(permissionClick)
        permissionLabel.maximumNumberOfLines = 2; permissionLabel.lineBreakMode = .byWordWrapping
        let permission = stack([permissionLabel, NSView(), permissionButton], spacing: 8); permission.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(permission)
        NSLayoutConstraint.activate([sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), sidebar.widthAnchor.constraint(equalToConstant: 335), sidebar.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 22), sidebar.bottomAnchor.constraint(equalTo: permission.topAnchor, constant: -14), preview.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 14), preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), preview.topAnchor.constraint(equalTo: sidebar.topAnchor), preview.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor), permission.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28), permission.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), permission.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6), permission.heightAnchor.constraint(equalToConstant: 30), footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16), footer.heightAnchor.constraint(equalToConstant: 48)])
        refresh()
    }
    func present(destination: PasteDestination?) {
        self.destination = destination; persistentMessage = nil; search.stringValue = ""; filter.selectedSegment = 0
        refresh(preserveSelection: false)
        window?.center(); showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(search)
    }
    func refresh(preserveSelection: Bool = true) {
        let old = preserveSelection ? selected?.id : nil
        values = store.filtered(query: search.stringValue, filter: filter.selectedSegment)
        table.reloadData()
        if !values.isEmpty {
            let row = old.flatMap { id in values.firstIndex(where: { $0.id == id }) } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        countLabel.stringValue = "\(values.count) 条\(filter.selectedSegment == 3 ? "收藏" : "历史")  ·  最新复制在前"
        updatePreview(); refreshStatus()
    }
    func refreshStatus() {
        pauseButton.title = monitor.paused ? "继续记录" : "暂停记录"
        status.stringValue = persistentMessage ?? (monitor.paused ? "● 已暂停 · 历史仍可使用" : "● \(monitor.status) · \(preferences.shortcut.display) 唤出")
        status.textColor = persistentMessage != nil || monitor.paused ? .systemOrange : .secondaryLabelColor
        targetLabel.stringValue = destination.map { "粘贴到：\($0.app.localizedName ?? "原应用")" } ?? "未指定目标，可使用「仅复制」"
        let trusted = AXIsProcessTrusted()
        permissionLabel.stringValue = persistentMessage ?? (trusted ? "本机加密保存 · 不联网    ↑↓ 选择 · Esc 关闭" : "自动粘贴需要辅助功能授权，未授权时可使用「仅复制」")
        permissionLabel.textColor = persistentMessage != nil ? .systemOrange : .secondaryLabelColor
        permissionButton.isHidden = trusted
        pasteButton.isEnabled = selected != nil
        plainButton.isEnabled = selected?.text != nil
    }
    private func updatePreview() {
        guard let entry = selected else {
            previewTitle.stringValue = "内容预览"; metadata.stringValue = ""
            textScroll.isHidden = true; imageView.isHidden = true; enlargeButton.isHidden = true
            previewArea.subviews.last?.isHidden = false
            empty.stringValue = search.stringValue.isEmpty ? "复制一点内容，从这里找回来" : "没有找到匹配的内容"
            emptyHint.stringValue = search.stringValue.isEmpty ? "照常 ⌘C 复制，再用快捷键查看历史" : "试试更短的关键词，或切换内容类型"
            pinButton.isEnabled = false; copyButton.isEnabled = false; pasteButton.isEnabled = false; plainButton.isEnabled = false
            return
        }
        previewArea.subviews.last?.isHidden = true
        previewTitle.stringValue = entry.name?.isEmpty == false ? entry.name! : entry.kind.label
        let format = DateFormatter(); format.locale = Locale(identifier: "zh_CN"); format.dateFormat = "MM-dd HH:mm:ss"
        metadata.stringValue = "\(entry.sourceName)（来源参考） · \(format.string(from: entry.copiedAt)) · \(ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file))"
        metadata.toolTip = "来源根据复制时的前台应用判断，后台复制或通用剪贴板的来源可能不同。"
        pinButton.isEnabled = true; pinButton.image = symbol(entry.pinned ? "star.fill" : "star"); pinButton.contentTintColor = entry.pinned ? .systemOrange : .secondaryLabelColor
        copyButton.isEnabled = true; currentImage = nil
        if entry.kind == .image {
            do { currentImage = try store.payload(for: entry).imageData.flatMap { NSImage(data: $0) } }
            catch { report(error.localizedDescription) }
            imageView.image = currentImage; imageView.isHidden = false; textScroll.isHidden = true; enlargeButton.isHidden = currentImage == nil
        } else {
            previewText.string = entry.text ?? ""; previewText.scrollToBeginningOfDocument(nil)
            imageView.isHidden = true; textScroll.isHidden = false; enlargeButton.isHidden = true
        }
        refreshStatus()
    }
    func report(_ text: String) { persistentMessage = text; status.stringValue = text; status.textColor = .systemOrange; status.toolTip = text }
    func clearReport() { persistentMessage = nil; refreshStatus() }
    func numberOfRows(in tableView: NSTableView) -> Int { values.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("clip")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? ClipCell ?? ClipCell()
        cell.identifier = id; cell.configure(values[row]); return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updatePreview() }
    func controlTextDidChange(_ obj: Notification) { refresh(preserveSelection: false) }
    @objc private func filterChanged() { refresh(preserveSelection: false) }
    @objc private func settingsClick() { onSettings?() }
    @objc private func togglePause() { onPause?() }
    @objc private func permissionClick() { onPermission?() }
    @objc private func copyClick() { if let entry = selected { onAction?(entry, false, true) } }
    @objc private func pasteClick() { if let entry = selected { onAction?(entry, false, false) } }
    @objc private func plainClick() { if let entry = selected { onAction?(entry, true, false) } }
    @objc private func doubleClick() { if table.clickedRow >= 0 { pasteClick() } }
    private func selectContextRow() {
        if table.clickedRow >= 0 { table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false) }
    }
    @objc private func pinClick(_ sender: Any?) {
        if sender is NSMenuItem { selectContextRow() }
        if let entry = selected { do { try store.pin(entry.id); refresh() } catch { report(error.localizedDescription) } }
    }
    @objc private func renameClick(_ sender: Any?) {
        if sender is NSMenuItem { selectContextRow() }
        guard let entry = selected, let window = window else { return }
        let alert = NSAlert(); alert.messageText = "给这条内容起个名字"; alert.informativeText = "命名后可以通过这个名字搜索。留空可恢复默认名称。"
        let field = NSTextField(string: entry.name ?? ""); field.frame = NSRect(x: 0, y: 0, width: 300, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn, let self = self else { return }
            do { try self.store.rename(entry.id, name: field.stringValue); self.refresh() } catch { self.report(error.localizedDescription) }
        }
        alert.window.initialFirstResponder = field
    }
    @objc private func deleteClick(_ sender: Any?) {
        if sender is NSMenuItem { selectContextRow() }
        if let entry = selected { do { try store.delete(entry.id); refresh() } catch { report(error.localizedDescription) } }
    }
    @objc private func enlargeClick() {
        guard let image = currentImage else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "拾贴 · 图片预览"; panel.isReleasedWhenClosed = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let view = NSImageView(frame: NSRect(origin: .zero, size: image.size)); view.image = image; view.imageScaling = .scaleNone
        scroll.documentView = view; panel.contentView = scroll; panel.center(); panel.makeKeyAndOrderFront(nil); imagePanel = panel
    }
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window?.attachedSheet == nil else { return event }
        if let editor = window?.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { onCancel?(); return nil }
        if event.keyCode == 125 || event.keyCode == 126 {
            guard !values.isEmpty else { return nil }
            let row = min(values.count - 1, max(0, table.selectedRow + (event.keyCode == 125 ? 1 : -1)))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row); return nil
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if flags.contains(.command) { copyClick() } else if flags.contains(.shift) { plainClick() } else { pasteClick() }; return nil
        }
        if flags.contains(.command) && event.charactersIgnoringModifiers == "f" { window?.makeFirstResponder(search); return nil }
        if flags.contains(.command) && event.charactersIgnoringModifiers == "," { settingsClick(); return nil }
        return event
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { onCancel?(); return false }
    deinit { if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) } }
}
