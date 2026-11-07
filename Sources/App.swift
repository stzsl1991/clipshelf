import AppKit
import ApplicationServices
import CryptoKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: HistoryStore!
    var monitor: ClipboardMonitor!
    var history: HistoryWindow!
    var picker: CardPicker!
    var settings: SettingsWindow!
    var preferences: Preferences!
    let shortcut = GlobalShortcut()
    var statusItem: NSStatusItem!
    var workspaceObserver: NSObjectProtocol?
    var refreshTimer: Timer?
    var pruneTimer: Timer?
    var pasteToken = UUID()
    var lastExternalApp: NSRunningApplication?
    enum Surface { case cards, manager }
    var surface: Surface = .cards
    var destination: PasteDestination? { surface == .cards ? picker.destination : history.destination }
    let isPreview = CommandLine.arguments.contains("--preview") || Bundle.main.bundleIdentifier == "com.shulin.ClipShelf.Preview"
    var previewDirectory: URL?
    var previewTermination: DispatchSourceSignal?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if isPreview {
            signal(SIGTERM, SIG_IGN)
            previewTermination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            previewTermination?.setEventHandler { NSApp.terminate(nil) }; previewTermination?.resume()
        }
        if !isPreview, NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.shulin.ClipShelf").filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }).count > 0 {
            NSApp.terminate(nil); return
        }
        do {
            preferences = Preferences(defaults: isPreview ? UserDefaults(suiteName: "com.shulin.ClipShelf.PreviewData")! : .standard)
            let directory: URL
            let key: SymmetricKey
            if isPreview {
                directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-preview-\(UUID().uuidString)")
                previewDirectory = directory; key = SymmetricKey(size: .bits256)
            } else {
                directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("com.shulin.ClipShelf", isDirectory: true)
                key = try LocalKey.loadOrCreate()
            }
            store = try HistoryStore(directory: directory, key: key, limits: preferences.limits)
            let pasteboard = isPreview ? NSPasteboard(name: .init("com.shulin.ClipShelf.preview")) : .general
            monitor = ClipboardMonitor(store: store, preferences: preferences, pasteboard: pasteboard)
            history = HistoryWindow(store: store, monitor: monitor, preferences: preferences)
            picker = CardPicker(store: store, preferences: preferences)
            settings = SettingsWindow(preferences: preferences, store: store)
            configureCallbacks(); buildStatusItem()
            if !isPreview {
                do { try shortcut.register(preferences.shortcut) } catch { report(error.localizedDescription) }
                monitor.start()
            } else { try seedPreview() }
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let self = self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
                self.lastExternalApp = app
                if self.history.window?.isVisible == true || self.picker.window?.isVisible == true { self.cancel(restoreFocus: false) }
            }
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                if self?.history.window?.isVisible == true { self?.history.refreshStatus() }
                if self?.picker.window?.isVisible == true { self?.picker.refreshStatus() }
            }
            pruneTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in do { try self?.store.prune() } catch { self?.report(error.localizedDescription) } }
            showPicker()
            if isPreview && CommandLine.arguments.contains("--debug-layout") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { print(self.picker.layoutDescription()); fflush(stdout) }
            }
        } catch {
            let alert = NSAlert(); alert.messageText = "拾贴未能启动"; alert.informativeText = "\(error.localizedDescription)\n原有历史不会被覆盖。"; alert.addButton(withTitle: "退出"); alert.runModal(); NSApp.terminate(nil)
        }
    }
    private func configureCallbacks() {
        shortcut.action = { [weak self] in self?.togglePicker() }
        store.onChange = { [weak self] in
            if self?.history?.window?.isVisible == true { self?.history.refresh() }
            if self?.picker?.window?.isVisible == true { self?.picker.refresh() }
        }
        monitor.onStatus = { [weak self] in self?.history.refreshStatus(); self?.picker.refreshStatus(); self?.updateStatusIcon() }
        monitor.onError = { [weak self] in self?.report($0) }
        history.onSettings = { [weak self] in self?.showSettings() }
        history.onPause = { [weak self] in self?.togglePause() }
        history.onPermission = { [weak self] in self?.requestPermission() }
        history.onCancel = { [weak self] in self?.cancel(restoreFocus: true) }
        history.onAction = { [weak self] entry, plain, copy in self?.surface = .manager; self?.perform(entry, plain: plain, copyOnly: copy) }
        picker.onCancel = { [weak self] restore in self?.cancel(restoreFocus: restore) }
        picker.onAction = { [weak self] entry, plain, copy in self?.surface = .cards; self?.perform(entry, plain: plain, copyOnly: copy) }
        settings.onShortcut = { [weak self] value in try self?.shortcut.register(value) }
        settings.onChange = { [weak self] in self?.history.refresh(); self?.picker.refresh() }
        settings.onPermission = { [weak self] in self?.requestPermission() }
    }
    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp]); updateStatusIcon()
        let menu = NSMenu()
        let appMenu = NSMenuItem(); menu.addItem(appMenu); let appSub = NSMenu(); appMenu.submenu = appSub
        for (title, action, key) in [("拾贴设置…", #selector(showSettings), ","), ("退出拾贴", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; appSub.addItem(item)
        }
        NSApp.mainMenu = menu
        let edit = NSMenu(title: "编辑"); let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); editItem.submenu = edit; menu.addItem(editItem)
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
    }
    private func updateStatusIcon() {
        statusItem?.button?.image = symbol(monitor?.paused == true ? "pause.rectangle" : "square.on.square", size: 16)
        statusItem?.button?.image?.isTemplate = true
        statusItem?.button?.toolTip = "拾贴 · \(monitor?.paused == true ? "已暂停" : "正在记录") · \(preferences?.shortcut.display ?? "⌃⌥V")"
    }
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            for (title, selector) in [("浏览剪贴板卡片", #selector(showPicker)), ("管理历史…", #selector(showHistory)), (monitor.paused ? "继续记录" : "暂停记录", #selector(togglePause)), ("设置…", #selector(showSettings)), ("退出拾贴", #selector(quit))] {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
            }
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else { togglePicker() }
    }
    func togglePicker() { if picker.window?.isVisible == true { cancel(restoreFocus: true) } else { showPicker() } }
    private func captureDestination() -> PasteDestination? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let target = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? (destination?.app ?? lastExternalApp) : frontmost
        return isPreview ? nil : target.flatMap { !$0.isTerminated ? PasteDestination(app: $0) : nil }
    }
    @objc func showPicker() {
        let target = captureDestination(); pasteToken = UUID(); surface = .cards
        history.window?.orderOut(nil); history.destination = nil; settings?.window?.orderOut(nil)
        picker.present(destination: target)
    }
    @objc func showHistory() {
        let target = captureDestination(); pasteToken = UUID(); surface = .manager; picker.hide()
        settings?.window?.orderOut(nil)
        history.present(destination: target)
    }
    @objc func showSettings() { pasteToken = UUID(); picker.hide(); history.window?.orderOut(nil); history.destination = nil; settings.present() }
    @objc func togglePause() { monitor.paused.toggle(); history.refreshStatus(); picker.refreshStatus(); updateStatusIcon() }
    @objc func quit() { NSApp.terminate(nil) }
    func cancel(restoreFocus: Bool) {
        pasteToken = UUID(); let target = destination
        picker.hide(); history.window?.orderOut(nil); history.destination = nil
        if restoreFocus { target?.app.activate(options: [.activateIgnoringOtherApps]) }
    }
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func perform(_ entry: ClipEntry, plain: Bool, copyOnly: Bool) {
        if surface == .cards { picker.clearReport() } else { history.clearReport() }
        if isPreview { report("这是示例预览。请打开 /Applications 中的拾贴使用真实历史。"); return }
        let payload: ClipPayload
        do { payload = try store.payload(for: entry) } catch { report("读取失败：\(error.localizedDescription)"); return }
        // A deliberate selection always copies first. Accessibility only gates
        // the optional synthetic paste, never the user's ability to copy.
        do { try monitor.restore(payload, plainText: plain) }
        catch { report(error.localizedDescription); recordPaste("copy_failed"); return }
        recordPaste("copied", target: destination)
        if copyOnly {
            cancel(restoreFocus: true)
            return
        }
        guard AXIsProcessTrusted() else {
            report("已复制。当前版本的辅助功能授权尚未生效，可切回原应用按 ⌘V。")
            recordPaste("copied_permission_not_effective", target: destination); return
        }
        guard let target = destination, !target.app.isTerminated else {
            report("已复制。请先在目标输入框中唤起历史，或切回目标应用按 ⌘V。")
            recordPaste("copied_no_destination"); return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
            report("已复制。前台应用已变化，为避免粘贴错位置，请手动 ⌘V。")
            recordPaste("copied_foreground_changed", target: target); return
        }
        let token = UUID(); pasteToken = token
        picker.hide(); history.window?.orderOut(nil); history.destination = nil
        guard target.app.activate(options: [.activateIgnoringOtherApps]) else {
            pasteFailed("已复制，但无法切回原应用。请手动 ⌘V。", stage: "activation_failed", target: target); return
        }
        waitForTarget(target, token: token, clipboardChange: monitor.pasteboard.changeCount, attempts: 0)
    }
    private func waitForTarget(_ target: PasteDestination, token: UUID, clipboardChange: Int, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self = self, self.pasteToken == token else { return }
            guard self.monitor.pasteboard.changeCount == clipboardChange else {
                self.pasteFailed("剪贴板已被新的复制更新，自动粘贴已取消。", stage: "clipboard_changed", target: target); return
            }
            guard !target.app.isTerminated else { self.pasteFailed("已复制，原应用已关闭。", stage: "target_closed", target: target); return }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard front == target.app.processIdentifier || front == ProcessInfo.processInfo.processIdentifier else {
                self.pasteFailed("已复制。你已切换应用，自动粘贴已取消。", stage: "target_changed", target: target); return
            }
            let held = CGEventSource.flagsState(.combinedSessionState).intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
            if front != target.app.processIdentifier || !held.isEmpty {
                if attempts < 24 { self.waitForTarget(target, token: token, clipboardChange: clipboardChange, attempts: attempts + 1) }
                else { self.pasteFailed("已复制，但等待原应用或按键释放超时。请手动 ⌘V。", stage: "activation_timeout", target: target) }
                return
            }
            guard target.matchesCurrentFocus() else {
                self.pasteFailed("已复制。原输入位置已变化，自动粘贴已取消；可手动 ⌘V。", stage: "focus_changed", target: target); return
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app.processIdentifier, self.pasteToken == token else { return }
            guard let source = CGEventSource(stateID: .privateState), let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                self.pasteFailed("已复制，但无法发送粘贴按键。请手动 ⌘V。", stage: "event_creation_failed", target: target); return
            }
            down.flags = .maskCommand; up.flags = .maskCommand
            down.postToPid(target.app.processIdentifier); up.postToPid(target.app.processIdentifier)
            self.recordPaste("paste_request_sent", target: target)
        }
    }
    private func pasteFailed(_ message: String, stage: String, target: PasteDestination) {
        recordPaste(stage, target: target); report(message)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front == target.app.processIdentifier || front == ProcessInfo.processInfo.processIdentifier {
            if surface == .cards { picker.reopenForMessage(destination: target) }
            else { history.destination = target; history.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        }
        statusItem.button?.toolTip = "拾贴 · \(message)"
    }
    private func report(_ message: String) { if surface == .cards { picker?.report(message) } else { history?.report(message) } }
    private func recordPaste(_ stage: String, target: PasteDestination? = nil) {
        guard !isPreview else { return }
        let value: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "stage": stage,
            "accessibilityTrusted": AXIsProcessTrusted(), "targetApp": target?.app.bundleIdentifier ?? "none",
            "frontmostApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none",
            "hadFocusedElement": target?.focusedElement != nil]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        let path = store.directory.appendingPathComponent("last-paste-status.json")
        try? data.write(to: path, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    private func seedPreview() throws {
        let samples = [
            ("Safari", "https://developer.apple.com/documentation/appkit"),
            ("微信", "明天下午 3 点，我们一起把这个想法做出来。"),
            ("备忘录", "把灵感留住\n\n连续复制，不必来回切换。\n打开拾贴，找到你想要的那一条。"),
            ("IntelliJ IDEA", "def hello(name):\n    message = f\"你好，{name} 👋\"\n    return message\n\n# 换行、缩进和中文，完整保留。")]
        for (i, sample) in samples.enumerated() {
            let payload = ClipPayload(items: [ClipItem(representations: [Representation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(sample.1.utf8))])])
            let id = try store.insert(payload, source: sample.0, bundleID: nil, now: Date().addingTimeInterval(Double(i - 4) * 60))
            if i == 2 { try store.pin(id) }
        }
        let older = ["周末清单\n买水果\n带孩子去公园\n整理本周照片", "https://example.com/design-notes", "设计要点\n内容直接看见，操作尽量简单。\n向左滑动，就能找到更早复制的内容。", "会议备忘\n周五 14:30\n确认下周计划", "留住每一次灵感。", "常用地址\n上海市 · 示例路 18 号"]
        for (index, text) in older.enumerated() {
            let payload = ClipPayload(items: [ClipItem(representations: [Representation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))])])
            _ = try store.insert(payload, source: index % 2 == 0 ? "备忘录" : "Safari", bundleID: nil, now: Date().addingTimeInterval(-Double(index + 5) * 60))
        }
        let image = NSImage(size: NSSize(width: 800, height: 420)); image.lockFocus()
        NSColor(srgbRed: 0.08, green: 0.42, blue: 0.46, alpha: 1).setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 800, height: 420)).fill()
        NSColor.white.withAlphaComponent(0.12).setFill(); NSBezierPath(ovalIn: NSRect(x: 480, y: -160, width: 520, height: 520)).fill()
        ("把灵感，留在手边。" as NSString).draw(at: NSPoint(x: 64, y: 210), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 40), .foregroundColor: NSColor.white])
        ("拾贴  /  随时找回你复制过的内容" as NSString).draw(at: NSPoint(x: 68, y: 156), withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.white.withAlphaComponent(0.75)])
        image.unlockFocus()
        if let data = image.tiffRepresentation {
            let payload = ClipPayload(items: [ClipItem(representations: [Representation(type: NSPasteboard.PasteboardType.tiff.rawValue, data: data)])])
            _ = try store.insert(payload, source: "截图", bundleID: nil, now: Date().addingTimeInterval(-20))
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if picker?.window?.isVisible == true { picker.window?.makeKeyAndOrderFront(nil) }
        else if history?.window?.isVisible == true { history.window?.makeKeyAndOrderFront(nil) }
        else if settings?.window?.isVisible == true { settings.window?.makeKeyAndOrderFront(nil) }
        else { showPicker() }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let directory = previewDirectory { try? FileManager.default.removeItem(at: directory) }
        if let observer = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
