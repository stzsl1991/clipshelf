import AppKit
import ServiceManagement
import UniformTypeIdentifiers

final class SettingsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let preferences: Preferences
    let store: HistoryStore
    var onShortcut: ((Shortcut) throws -> Void)?
    var onPermission: (() -> Void)?
    var onChange: (() -> Void)?
    let control = NSButton(checkboxWithTitle: "⌃ Control", target: nil, action: nil)
    let option = NSButton(checkboxWithTitle: "⌥ Option", target: nil, action: nil)
    let command = NSButton(checkboxWithTitle: "⌘ Command", target: nil, action: nil)
    let shift = NSButton(checkboxWithTitle: "⇧ Shift", target: nil, action: nil)
    let key = NSPopUpButton()
    let days = NSPopUpButton()
    let count = NSPopUpButton()
    let login = NSButton(checkboxWithTitle: "登录 Mac 后自动启动拾贴", target: nil, action: nil)
    let table = NSTableView()
    let note = label("", size: 12, color: .secondaryLabelColor)
    var excluded: [String] = []
    init(preferences: Preferences, store: HistoryStore) {
        self.preferences = preferences; self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 760), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "拾贴设置"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; build()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func build() {
        guard let root = window?.contentView else { return }
        let title = label("按你的习惯使用拾贴", size: 23, weight: .bold)
        let subtitle = label("内容加密保存在这台 Mac，离线可用。", size: 13, color: .secondaryLabelColor)
        key.addItems(withTitles: Shortcut.codes.keys.sorted()); key.selectItem(withTitle: preferences.shortcut.key)
        let shortcut = preferences.shortcut
        control.state = shortcut.control ? .on : .off; option.state = shortcut.option ? .on : .off
        command.state = shortcut.command ? .on : .off; shift.state = shortcut.shift ? .on : .off
        let shortcutRow = stack([control, option, command, shift, key, actionButton("应用", target: self, action: #selector(saveShortcut))], spacing: 8)
        days.addItems(withTitles: ["1 天", "7 天", "30 天", "90 天"]); days.selectItem(at: [1,7,30,90].firstIndex(of: preferences.maxDays) ?? 2)
        count.addItems(withTitles: ["100 条", "500 条", "1,000 条", "5,000 条"]); count.selectItem(at: [100,500,1000,5000].firstIndex(of: preferences.maxCount) ?? 2)
        days.target = self; days.action = #selector(saveLimits); count.target = self; count.action = #selector(saveLimits)
        let retention = stack([label("保留"), days, label("最多"), count], spacing: 10)
        let capacity = label("达到期限或数量上限时清理旧记录。收藏不过期。\n总容量上限 500 MB，单条上限 32 MB。", size: 12, color: .secondaryLabelColor)
        capacity.maximumNumberOfLines = 2
        login.target = self; login.action = #selector(toggleLogin)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("apps")); column.width = 560
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 28; table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("不记录的应用列表")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.heightAnchor.constraint(equalToConstant: 118), scroll.widthAnchor.constraint(equalToConstant: 592)])
        let appsButtons = stack([actionButton("添加应用…", target: self, action: #selector(addApp)), actionButton("移除所选", target: self, action: #selector(removeApp))])
        let privacy = label("敏感标记的内容不记录；普通文本中的密码无法保证全部识别。\n来源按复制时的前台应用判断。锁定屏幕期间暂停记录。", size: 12, color: .secondaryLabelColor); privacy.maximumNumberOfLines = 2
        let buttons = stack([actionButton("辅助功能授权…", target: self, action: #selector(permission)), actionButton("清空历史…", target: self, action: #selector(clearHistory)), actionButton("清空全部…", target: self, action: #selector(clearEverything))], spacing: 12)
        note.maximumNumberOfLines = 2; note.lineBreakMode = .byWordWrapping
        let columnStack = stack([title, subtitle, separator(), label("全局快捷键", size: 14, weight: .semibold), shortcutRow, separator(), label("历史与启动", size: 14, weight: .semibold), retention, capacity, login, separator(), label("不记录这些应用", size: 14, weight: .semibold), scroll, appsButtons, privacy, separator(), buttons, note], vertical: true, spacing: 12)
        columnStack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(columnStack)
        NSLayoutConstraint.activate([columnStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 25), columnStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 29), columnStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -29)])
    }
    private func separator() -> NSView {
        let line = NSBox(); line.boxType = .separator; line.translatesAutoresizingMaskIntoConstraints = false; line.widthAnchor.constraint(equalToConstant: 592).isActive = true; return line
    }
    func present() {
        excluded = preferences.excluded; table.reloadData()
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        note.stringValue = "普通 ⌘V 仍粘贴最新内容。历史面板中按 Esc 可取消。"
        window?.center(); showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    @objc private func saveShortcut() {
        let value = Shortcut(key: key.titleOfSelectedItem ?? "V", control: control.state == .on, option: option.state == .on, command: command.state == .on, shift: shift.state == .on)
        do { if value != preferences.shortcut { try onShortcut?(value); preferences.shortcut = value }; note.stringValue = "已设置：\(value.display)"; onChange?() }
        catch { note.stringValue = error.localizedDescription }
    }
    @objc private func saveLimits() {
        let previous = store.limits
        store.limits = HistoryLimits(count: [100,500,1000,5000][count.indexOfSelectedItem], days: [1,7,30,90][days.indexOfSelectedItem])
        do {
            try store.prune(); preferences.maxCount = store.limits.count; preferences.maxDays = store.limits.days
            note.stringValue = "保存规则已更新。"; onChange?()
        } catch { store.limits = previous; note.stringValue = error.localizedDescription }
    }
    @objc private func toggleLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            let state = SMAppService.mainApp.status
            login.state = state == .enabled ? .on : .off
            if state == .requiresApproval {
                note.stringValue = "请在系统「登录项」中允许拾贴启动。"; SMAppService.openSystemSettingsLoginItems()
            } else { note.stringValue = state == .enabled ? "已启用登录时启动。" : "已关闭登录时启动。" }
        } catch { login.state = SMAppService.mainApp.status == .enabled ? .on : .off; note.stringValue = "设置失败：\(error.localizedDescription)" }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { excluded.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = excluded[row]
        let knownNames = ["com.apple.Passwords":"密码", "com.apple.keychainaccess":"钥匙串访问", "com.1password.1password":"1Password", "com.agilebits.onepassword7":"1Password 7", "com.agilebits.onepassword-osx":"1Password（旧版）", "com.bitwarden.desktop":"Bitwarden", "com.lastpass.LastPass":"LastPass", "com.keepassium.KeePassium":"KeePassium"]
        let appName = knownNames[id] ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent
        let view = label("  \(appName ?? "已排除的应用")", size: 12); view.toolTip = id; return view
    }
    @objc private func addApp() {
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.application]; picker.allowsMultipleSelection = true
        picker.directoryURL = URL(fileURLWithPath: "/Applications"); picker.prompt = "不记录此应用"
        guard let window = window else { return }
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self = self else { return }
            for url in picker.urls { if let id = Bundle(url: url)?.bundleIdentifier, !self.excluded.contains(id) { self.excluded.append(id) } }
            self.preferences.excluded = self.excluded; self.table.reloadData(); self.note.stringValue = "已更新排除应用。"
        }
    }
    @objc private func removeApp() {
        guard table.selectedRow >= 0, table.selectedRow < excluded.count else { return }
        excluded.remove(at: table.selectedRow); preferences.excluded = excluded; table.reloadData(); note.stringValue = "已移除所选应用。"
    }
    @objc private func permission() { onPermission?() }
    @objc private func clearHistory() { clear(all: false) }
    @objc private func clearEverything() { clear(all: true) }
    private func clear(all: Bool) {
        guard let window = window else { return }
        let alert = NSAlert(); alert.messageText = all ? "清空全部历史和收藏？" : "清空历史，保留收藏？"
        alert.informativeText = "删除后无法恢复，关联的图片数据也会一并清理。"; alert.alertStyle = .warning
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清空")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertSecondButtonReturn, let self = self else { return }
            do { try self.store.clear(includingPinned: all); self.note.stringValue = "已清空。"; self.onChange?() } catch { self.note.stringValue = error.localizedDescription }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
}
