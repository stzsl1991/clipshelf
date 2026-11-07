import AppKit
import ImageIO

private final class CardView: NSView {
    var onSelect: (() -> Void)?
    var onActivate: (() -> Void)?
    var context: (() -> NSMenu)?
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
    override func mouseDown(with event: NSEvent) {
        onSelect?()
        if event.clickCount == 2 { onActivate?() }
    }
    override func menu(for event: NSEvent) -> NSMenu? { onSelect?(); return context?() }
}
private final class CardScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // Trackpad horizontal gestures stay native (including momentum). A
        // vertical mouse wheel also browses the horizontal queue.
        if abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY), event.scrollingDeltaX != 0 {
            super.scrollWheel(with: event); return
        }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 22)
        let maxX = max(0, (documentView?.bounds.width ?? 0) - contentView.bounds.width)
        contentView.scroll(to: NSPoint(x: min(maxX, max(0, contentView.bounds.minX - delta)), y: 0))
        reflectScrolledClipView(contentView)
    }
}
private final class CardItem: NSCollectionViewItem {
    let source = label("", size: 11, weight: .medium)
    let number = label("", size: 10, color: .secondaryLabelColor)
    let body = NSTextField(wrappingLabelWithString: "")
    let image = NSImageView()
    let type = label("", size: 10, color: .secondaryLabelColor)
    let age = label("", size: 10, color: .secondaryLabelColor)
    let pin = NSImageView()
    let icon = NSImageView()
    var card: CardView { view as! CardView }
    override func loadView() {
        view = CardView(frame: NSRect(origin: .zero, size: CardGeometry.size))
        view.wantsLayer = true; view.layer?.cornerRadius = 13; view.layer?.masksToBounds = true
        let header = NSView(); header.wantsLayer = true; header.layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.07).cgColor
        header.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(header)
        icon.contentTintColor = .systemTeal; pin.image = symbol("star.fill", size: 10); pin.contentTintColor = .systemOrange
        let heading = stack([icon, source, NSView(), pin, number], spacing: 7)
        heading.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(heading)
        body.font = .systemFont(ofSize: 14); body.textColor = .labelColor
        body.maximumNumberOfLines = 7; body.lineBreakMode = .byWordWrapping; body.preferredMaxLayoutWidth = 260
        body.cell?.wraps = true; body.cell?.isScrollable = false
        body.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        body.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(body)
        image.imageScaling = .scaleProportionallyUpOrDown; image.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(image)
        let footer = stack([type, NSView(), age], spacing: 4); footer.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(footer)
        source.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor), header.leadingAnchor.constraint(equalTo: view.leadingAnchor), header.trailingAnchor.constraint(equalTo: view.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 32),
            heading.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12), heading.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12), heading.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14), icon.heightAnchor.constraint(equalToConstant: 14), pin.widthAnchor.constraint(equalToConstant: 12),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14), body.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14), body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), body.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -9),
            image.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), image.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), image.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 9), image.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -9),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14), footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14), footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12), footer.heightAnchor.constraint(equalToConstant: 14)
        ])
        updateSelection()
    }
    override var isSelected: Bool { didSet { if isViewLoaded { updateSelection() } } }
    private func updateSelection() {
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        view.layer?.borderWidth = isSelected ? 2.5 : 1
        view.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.withAlphaComponent(0.4).cgColor
    }
    func configure(_ entry: ClipEntry, index: Int, thumbnail: NSImage?) {
        _ = view
        source.stringValue = entry.sourceName; number.stringValue = "\(index + 1)"
        icon.image = symbol(entry.kind.symbol, size: 12); pin.isHidden = !entry.pinned
        let formatter = RelativeDateTimeFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.unitsStyle = .short
        age.stringValue = formatter.localizedString(for: entry.copiedAt, relativeTo: Date())
        type.stringValue = entry.kind == .image ? "图片 · \(entry.imageWidth ?? 0) × \(entry.imageHeight ?? 0)" : entry.kind.label
        if entry.kind == .image {
            image.image = thumbnail; image.isHidden = thumbnail == nil; body.isHidden = thumbnail != nil
            body.stringValue = "图片暂不可预览\n仍可双击复制并粘贴"
        } else {
            image.image = nil; image.isHidden = true; body.isHidden = false
            let text = entry.text ?? ""
            body.stringValue = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "空白文本 · \(text.count) 个字符" : String(text.prefix(2400))
            body.font = text.contains("\n    ") || text.contains("\t") ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 14)
        }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("第 \(index + 1) 张，\(entry.kind.label)，\(entry.sourceName)，\(entry.title)")
        view.setAccessibilityHelp("单击选中，双击粘贴，空格查看完整内容。")
    }
    override func prepareForReuse() {
        super.prepareForReuse(); image.image = nil; card.onSelect = nil; card.onActivate = nil; card.context = nil
    }
}

final class CardPicker: NSWindowController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSPopoverDelegate {
    let store: HistoryStore
    let preferences: Preferences
    let search = NSSearchField()
    let filter = NSPopUpButton()
    let collection = NSCollectionView()
    private let scroll = CardScrollView()
    private let status = label("", size: 11, color: .secondaryLabelColor)
    private let count = label("", size: 11, color: .secondaryLabelColor)
    private let hint = label("← → 选择   ↩ 粘贴   空格展开   Esc 关闭", size: 11, color: .secondaryLabelColor)
    private let empty = label("复制一点内容，从这里找回来", size: 15, weight: .medium, color: .secondaryLabelColor)
    private let images = NSCache<NSUUID, NSImage>()
    private let popover = NSPopover()
    private var keyMonitor: Any?
    private var selection = CardSelection()
    private var message: String?
    private var isShowingDetail = false
    private var dismissing = false
    private(set) var values: [ClipEntry] = []
    var destination: PasteDestination?
    var selected: ClipEntry? { selection.index.flatMap { $0 < values.count ? values[$0] : nil } }
    var onAction: ((ClipEntry, Bool, Bool) -> Void)?
    var onCancel: ((Bool) -> Void)?

    init(store: HistoryStore, preferences: Preferences) {
        self.store = store; self.preferences = preferences
        let panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 296), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "拾贴 · 底部卡片"; panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel); panel.delegate = self; build()
        images.countLimit = 48; images.totalCostLimit = 32 * 1024 * 1024
        popover.behavior = .semitransient; popover.delegate = self
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }; return self.handleKey(event)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    private func build() {
        guard let root = window?.contentView else { return }
        let background = NSVisualEffectView(); background.material = .popover; background.blendingMode = .behindWindow; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 20; background.layer?.masksToBounds = true
        anchor(background, in: root)
        let brand = label("拾贴", size: 14, weight: .semibold)
        let icon = NSImageView(image: symbol("square.on.square", size: 15)!); icon.contentTintColor = .systemTeal
        search.placeholderString = "搜索复制的内容"; search.delegate = self; search.sendsSearchStringImmediately = true; search.controlSize = .small; search.focusRingType = .none
        search.setAccessibilityLabel("搜索卡片内容")
        filter.addItems(withTitles: ["全部", "文本", "图片", "收藏"]); filter.controlSize = .small; filter.target = self; filter.action = #selector(filterChanged)
        filter.setAccessibilityLabel("卡片类型")
        let close = NSButton(image: symbol("xmark", size: 12)!, target: self, action: #selector(closeClick)); close.bezelStyle = .inline; close.isBordered = false; close.toolTip = "关闭（Esc）"; close.setAccessibilityLabel("关闭卡片栏")
        let header = stack([icon, brand, search, filter, NSView(), count, close], spacing: 10)
        header.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(header)
        let layout = NSCollectionViewFlowLayout(); layout.scrollDirection = .horizontal
        layout.itemSize = CardGeometry.size; layout.minimumInteritemSpacing = 12; layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
        collection.collectionViewLayout = layout; collection.dataSource = self; collection.delegate = self
        collection.backgroundColors = [.clear]; collection.isSelectable = true; collection.allowsMultipleSelection = false
        collection.register(CardItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("card"))
        collection.setAccessibilityLabel("横向剪贴板卡片队列")
        scroll.documentView = collection; scroll.drawsBackground = false; scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .allowed; scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(scroll)
        empty.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(empty)
        let footer = stack([status, NSView(), hint], spacing: 12); footer.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(footer)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12), header.heightAnchor.constraint(equalToConstant: 28),
            search.widthAnchor.constraint(equalToConstant: 250), filter.widthAnchor.constraint(equalToConstant: 74), close.widthAnchor.constraint(equalToConstant: 20), icon.widthAnchor.constraint(equalToConstant: 18),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14), scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10), scroll.heightAnchor.constraint(equalToConstant: CardGeometry.size.height),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18), footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6), footer.heightAnchor.constraint(equalToConstant: 18)
        ])
    }
    func present(destination: PasteDestination?, animated: Bool = true) {
        self.destination = destination; dismissing = false; message = nil
        search.stringValue = ""; filter.selectItem(at: 0)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let frame = CardGeometry.frame(in: screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
        window?.setFrame(frame, display: false); refresh(preserveSelection: false)
        window?.alphaValue = 1; showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(search)
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window?.setFrame(frame.offsetBy(dx: 0, dy: -18), display: false); window?.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.window?.animator().setFrame(frame, display: true); self.window?.animator().alphaValue = 1
            }
        }
    }
    func hide() { dismissing = true; popover.close(); window?.orderOut(nil); destination = nil }
    func reopenForMessage(destination: PasteDestination) {
        self.destination = destination; dismissing = false; window?.alphaValue = 1
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); refreshStatus()
    }
    func refresh(preserveSelection: Bool = true) {
        guard isWindowLoaded else { return }
        let previous = selection.selectedID
        values = store.filtered(query: search.stringValue, filter: filter.indexOfSelectedItem)
        selection.replace(values.map { $0.id }, preserving: preserveSelection)
        window?.contentView?.layoutSubtreeIfNeeded()
        collection.setFrameSize(NSSize(width: max(scroll.contentSize.width, CardGeometry.contentWidth(count: values.count)), height: CardGeometry.size.height))
        collection.collectionViewLayout?.invalidateLayout()
        collection.reloadData(); collection.layoutSubtreeIfNeeded()
        syncSelection(scrollToSelection: !preserveSelection || previous != selection.selectedID)
        empty.isHidden = !values.isEmpty
        empty.stringValue = search.stringValue.isEmpty ? "照常 ⌘C 复制，再从这里找回来" : "没有找到匹配的内容，试试其他关键词"
        refreshStatus()
    }
    func refreshStatus() {
        count.stringValue = values.isEmpty ? "" : "\((selection.index ?? 0) + 1) / \(values.count)"
        status.stringValue = message ?? destination.map { "粘贴到：\($0.app.localizedName ?? "原应用")" } ?? "仅复制可用 · 在目标输入框中唤起可直接粘贴"
        status.textColor = message == nil ? .secondaryLabelColor : .systemOrange; status.toolTip = status.stringValue
        hint.stringValue = "向左滑看更早内容   ← → 选择   ↩ 粘贴   空格展开   Esc 关闭"
    }
    func report(_ text: String) { message = text; refreshStatus() }
    func clearReport() { message = nil; refreshStatus() }
    func layoutDescription() -> String {
        "cards=\(values.count) document=\(collection.frame) viewport=\(scroll.contentView.bounds) layout=\(collection.collectionViewLayout?.collectionViewContentSize ?? .zero)"
    }
    private func thumbnail(for entry: ClipEntry) -> NSImage? {
        if let cached = images.object(forKey: entry.id as NSUUID) { return cached }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 600]
        guard let data = try? store.payload(for: entry).imageData, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        images.setObject(image, forKey: entry.id as NSUUID, cost: cg.width * cg.height * 4); return image
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { values.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("card"), for: indexPath) as! CardItem
        let entry = values[indexPath.item]
        item.configure(entry, index: indexPath.item, thumbnail: entry.kind == .image ? thumbnail(for: entry) : nil)
        item.card.onSelect = { [weak self] in self?.select(entry.id) }
        item.card.onActivate = { [weak self] in self?.activate(plain: false, copyOnly: false) }
        item.card.context = { [weak self] in self?.contextMenu() ?? NSMenu() }
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if let path = indexPaths.first, path.item < values.count { selection.select(values[path.item].id); refreshStatus() }
    }
    private func select(_ id: UUID) { selection.select(id); syncSelection(scrollToSelection: false); refreshStatus() }
    private func syncSelection(scrollToSelection: Bool) {
        guard let index = selection.index else { collection.deselectAll(nil); return }
        let path = IndexPath(item: index, section: 0)
        collection.selectItems(at: [path], scrollPosition: [])
        if scrollToSelection {
            let offset = CardGeometry.reveal(index: index, current: scroll.contentView.bounds.minX, viewport: scroll.contentView.bounds.width, count: values.count)
            scroll.contentView.scroll(to: NSPoint(x: offset, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    private func move(_ delta: Int) { popover.close(); selection.move(delta); syncSelection(scrollToSelection: true); refreshStatus() }
    private func activate(plain: Bool, copyOnly: Bool) {
        guard let entry = selected else { return }; onAction?(entry, plain, copyOnly)
    }
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let expand = NSMenuItem(title: "查看完整内容", action: #selector(showDetail), keyEquivalent: ""); expand.target = self; menu.addItem(expand)
        menu.addItem(.separator())
        for (title, action) in [("粘贴", #selector(pasteClick)), ("仅复制", #selector(copyClick)), ("以纯文本粘贴", #selector(plainClick))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self
            item.isEnabled = selected != nil && (action != #selector(plainClick) || selected?.text != nil); menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, action) in [(selected?.pinned == true ? "取消收藏" : "收藏", #selector(pinClick)), ("删除这条记录", #selector(deleteClick))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc private func closeClick() { onCancel?(true) }
    @objc private func filterChanged() { refresh(preserveSelection: false) }
    @objc private func pasteClick() { activate(plain: false, copyOnly: false) }
    @objc private func copyClick() { activate(plain: false, copyOnly: true) }
    @objc private func plainClick() { activate(plain: true, copyOnly: false) }
    @objc private func pinClick() { if let entry = selected { do { try store.pin(entry.id) } catch { report(error.localizedDescription) } } }
    @objc private func deleteClick() { if let entry = selected { do { try store.delete(entry.id) } catch { report(error.localizedDescription) } } }
    func controlTextDidChange(_ notification: Notification) { popover.close(); refresh(preserveSelection: false) }
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window?.attachedSheet == nil else { return event }
        if let editor = window?.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { if popover.isShown { popover.close() } else { onCancel?(true) }; return nil }
        if flags.intersection([.command, .control, .option]).isEmpty {
            if event.keyCode == 123 { move(-1); return nil }
            if event.keyCode == 124 { move(1); return nil }
            if event.keyCode == 125 { window?.makeFirstResponder(collection); return nil }
            if event.keyCode == 49 && (search.stringValue.isEmpty || window?.firstResponder === collection) { showDetail(); return nil }
        }
        if event.keyCode == 36 || event.keyCode == 76 { activate(plain: flags.contains(.shift), copyOnly: flags.contains(.command)); return nil }
        if flags.contains(.command), event.charactersIgnoringModifiers == "f" { window?.makeFirstResponder(search); return nil }
        return event
    }
    @objc private func showDetail() {
        guard let entry = selected, let index = selection.index, let item = collection.item(at: IndexPath(item: index, section: 0)) else { return }
        if popover.isShown { popover.close(); return }
        let controller = NSViewController(); controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 360))
        let title = label(entry.name ?? entry.kind.label, size: 15, weight: .semibold)
        let content: NSView
        if entry.kind == .image {
            let image = NSImageView(); image.imageScaling = .scaleProportionallyDown
            image.image = (try? store.payload(for: entry).imageData).flatMap { NSImage(data: $0) }; content = image
        } else {
            let text = NSTextView(); text.string = entry.text ?? ""; text.isEditable = false; text.isSelectable = true; text.isRichText = false
            text.font = .monospacedSystemFont(ofSize: 14, weight: .regular); text.textContainerInset = NSSize(width: 8, height: 8); text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
            let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true; content = scroll
        }
        let buttons = stack([NSView(), actionButton("仅复制", target: self, action: #selector(copyClick)), actionButton("粘贴 ↩", target: self, action: #selector(pasteClick))])
        let column = stack([title, content, buttons], vertical: true, spacing: 10); column.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(column)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 16), column.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -16), column.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 16), column.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -16), content.widthAnchor.constraint(equalTo: column.widthAnchor), content.heightAnchor.constraint(greaterThanOrEqualToConstant: 240), buttons.widthAnchor.constraint(equalTo: column.widthAnchor)])
        popover.contentViewController = controller; isShowingDetail = true
        popover.show(relativeTo: item.view.bounds, of: item.view, preferredEdge: .maxY)
    }
    func popoverDidClose(_ notification: Notification) { isShowingDetail = false }
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.dismissing, self.window?.isVisible == true, self.window?.isKeyWindow == false, !self.isShowingDetail else { return }
            self.onCancel?(false)
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { onCancel?(true); return false }
    deinit { if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) } }
}
