import AppKit
import ApplicationServices
import CryptoKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: HistoryStore!
    var monitor: ClipboardMonitor!
    var history: HistoryWindow!
    var settings: SettingsWindow!
    var preferences: Preferences!
    let shortcut = GlobalShortcut()
    var statusItem: NSStatusItem!
    var workspaceObserver: NSObjectProtocol?
    var refreshTimer: Timer?
    var pruneTimer: Timer?
    var pasteToken = UUID()
    var lastExternalApp: NSRunningApplication?
    let isPreview = CommandLine.arguments.contains("--preview")
    var previewDirectory: URL?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if !isPreview, NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.shulin.ClipShelf").filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }).count > 0 {
            NSApp.terminate(nil); return
        }
        do {
            preferences = Preferences(defaults: isPreview ? UserDefaults(suiteName: "com.shulin.ClipShelf.Preview")! : .standard)
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
            settings = SettingsWindow(preferences: preferences, store: store)
            configureCallbacks(); buildStatusItem()
            if !isPreview {
                do { try shortcut.register(preferences.shortcut) } catch { history.report(error.localizedDescription) }
                monitor.start()
            } else { try seedPreview() }
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let self = self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self.lastExternalApp = app
                if self.history.window?.isVisible == true { self.cancel(restoreFocus: false) }
            }
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in if self?.history.window?.isVisible == true { self?.history.refreshStatus() } }
            pruneTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in do { try self?.store.prune() } catch { self?.history.report(error.localizedDescription) } }
            showHistory()
        } catch {
            let alert = NSAlert(); alert.messageText = "拾贴未能启动"; alert.informativeText = "\(error.localizedDescription)\n原有历史不会被覆盖。"; alert.addButton(withTitle: "退出"); alert.runModal(); NSApp.terminate(nil)
        }
    }
    private func configureCallbacks() {
        shortcut.action = { [weak self] in self?.toggleHistory() }
        store.onChange = { [weak self] in self?.history?.refresh() }
        monitor.onStatus = { [weak self] in self?.history.refreshStatus(); self?.updateStatusIcon() }
        monitor.onError = { [weak self] in self?.history.report($0) }
        history.onSettings = { [weak self] in self?.showSettings() }
        history.onPause = { [weak self] in self?.togglePause() }
        history.onPermission = { [weak self] in self?.requestPermission() }
        history.onCancel = { [weak self] in self?.cancel(restoreFocus: true) }
        history.onAction = { [weak self] entry, plain, copy in self?.perform(entry, plain: plain, copyOnly: copy) }
        settings.onShortcut = { [weak self] value in try self?.shortcut.register(value) }
        settings.onChange = { [weak self] in self?.history.refresh() }
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
            for (title, selector) in [("打开剪贴板历史", #selector(showHistory)), (monitor.paused ? "继续记录" : "暂停记录", #selector(togglePause)), ("设置…", #selector(showSettings)), ("退出拾贴", #selector(quit))] {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
            }
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else { toggleHistory() }
    }
    func toggleHistory() { if history.window?.isVisible == true { cancel(restoreFocus: true) } else { showHistory() } }
    @objc func showHistory() {
        pasteToken = UUID()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let target = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalApp : frontmost
        let destination = isPreview ? nil : target.flatMap { !$0.isTerminated ? PasteDestination(app: $0) : nil }
        settings?.window?.orderOut(nil)
        history.present(destination: destination)
    }
    @objc func showSettings() { pasteToken = UUID(); history.window?.orderOut(nil); history.destination = nil; settings.present() }
    @objc func togglePause() { monitor.paused.toggle(); history.refreshStatus(); updateStatusIcon() }
    @objc func quit() { NSApp.terminate(nil) }
    func cancel(restoreFocus: Bool) {
        pasteToken = UUID(); let target = history.destination
        history.window?.orderOut(nil); history.destination = nil
        if restoreFocus { target?.app.activate(options: [.activateIgnoringOtherApps]) }
    }
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func perform(_ entry: ClipEntry, plain: Bool, copyOnly: Bool) {
        history.clearReport()
        if isPreview { history.report("这是示例预览。请打开 /Applications 中的拾贴使用真实历史。"); return }
        let payload: ClipPayload
        do { payload = try store.payload(for: entry) } catch { history.report("读取失败：\(error.localizedDescription)"); return }
        // A deliberate selection always copies first. Accessibility only gates
        // the optional synthetic paste, never the user's ability to copy.
        do { try monitor.restore(payload, plainText: plain) }
        catch { history.report(error.localizedDescription); recordPaste("copy_failed"); return }
        recordPaste("copied", target: history.destination)
        if copyOnly {
            cancel(restoreFocus: true)
            return
        }
        guard AXIsProcessTrusted() else {
            history.report("已复制。当前版本的辅助功能授权尚未生效，可切回原应用按 ⌘V。")
            recordPaste("copied_permission_not_effective", target: history.destination); return
        }
        guard let target = history.destination, !target.app.isTerminated else {
            history.report("已复制。请先在目标输入框中唤起历史，或切回目标应用按 ⌘V。")
            recordPaste("copied_no_destination"); return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
            history.report("已复制。前台应用已变化，为避免粘贴错位置，请手动 ⌘V。")
            recordPaste("copied_foreground_changed", target: target); return
        }
        let token = UUID(); pasteToken = token
        history.window?.orderOut(nil); history.destination = nil
        guard target.app.activate(options: [.activateIgnoringOtherApps]) else {
            pasteFailed("已复制，但无法切回原应用。请手动 ⌘V。", stage: "activation_failed", target: target); return
        }
        waitForTarget(target, token: token, attempts: 0)
    }
    private func waitForTarget(_ target: PasteDestination, token: UUID, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self = self, self.pasteToken == token else { return }
            guard !target.app.isTerminated else { self.pasteFailed("已复制，原应用已关闭。", stage: "target_closed", target: target); return }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard front == target.app.processIdentifier || front == ProcessInfo.processInfo.processIdentifier else {
                self.pasteFailed("已复制。你已切换应用，自动粘贴已取消。", stage: "target_changed", target: target); return
            }
            let held = CGEventSource.flagsState(.combinedSessionState).intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
            if front != target.app.processIdentifier || !held.isEmpty {
                if attempts < 24 { self.waitForTarget(target, token: token, attempts: attempts + 1) }
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
        recordPaste(stage, target: target); history.report(message)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front == target.app.processIdentifier || front == ProcessInfo.processInfo.processIdentifier {
            history.destination = target; history.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        }
        statusItem.button?.toolTip = "拾贴 · \(message)"
    }
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
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if history?.window?.isVisible == true { history.window?.makeKeyAndOrderFront(nil) }
        else if settings?.window?.isVisible == true { settings.window?.makeKeyAndOrderFront(nil) }
        else { showHistory() }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let directory = previewDirectory { try? FileManager.default.removeItem(at: directory) }
        if let observer = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
