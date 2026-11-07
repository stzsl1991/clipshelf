import AppKit

final class ProbeText: NSTextView {
    var onPaste: (() -> Void)?
    override func paste(_ sender: Any?) { super.paste(sender); onPaste?() }
}
final class ProbeDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    let text = ProbeText()
    var window: NSWindow!
    let result = NSTextField(labelWithString: "等待粘贴")
    var original: [[(NSPasteboard.PasteboardType, Data)]] = []
    var pasteCount = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        original = (NSPasteboard.general.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 720,height: 530), styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
        window.title = "拾贴验收 · 独立粘贴目标"; window.isReleasedWhenClosed = false
        let root = NSView(); window.contentView = root
        let title = NSTextField(labelWithString: "独立应用的粘贴验收"); title.font = .boldSystemFont(ofSize: 21)
        let hint = NSTextField(labelWithString: "复制测试内容后，点输入区，再按 ⌃⌥V 选择历史并粘贴。")
        let buttons = NSStackView(); buttons.spacing = 8
        for (name, selector) in [("复制 A", #selector(copyA)),("复制 B",#selector(copyB)),("复制 C",#selector(copyC)),("富文本",#selector(copyRich)),("图片",#selector(copyImage)),("清空输入",#selector(clear))] {
            let button = NSButton(title: name,target: self,action: selector); button.bezelStyle = .rounded; buttons.addArrangedSubview(button)
        }
        let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        text.isRichText = true; text.importsGraphics = true; text.isEditable = true; text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("验收粘贴输入区"); text.font = .systemFont(ofSize: 16); text.delegate = self; text.onPaste = { [weak self] in self?.didPaste() }
        let finish = NSButton(title: "结束验收并恢复原剪贴板",target: self,action: #selector(quit)); finish.bezelStyle = .rounded
        let column = NSStackView(views: [title,hint,buttons,scroll,result,finish]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 16
        column.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(column)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: root.leadingAnchor,constant: 24),column.trailingAnchor.constraint(equalTo: root.trailingAnchor,constant: -24),column.topAnchor.constraint(equalTo: root.topAnchor,constant: 24),column.bottomAnchor.constraint(equalTo: root.bottomAnchor,constant: -24),scroll.widthAnchor.constraint(equalTo: column.widthAnchor),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250)])
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item); let sub = NSMenu(); item.submenu = sub
        let quit = NSMenuItem(title: "退出验收",action: #selector(quit),keyEquivalent: "q"); quit.target = self; sub.addItem(quit)
        let edit = NSMenu(title: "编辑"); let editItem = NSMenuItem(title: "编辑",action:nil,keyEquivalent:""); editItem.submenu = edit; menu.addItem(editItem)
        for (title,selector,key) in [("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] { edit.addItem(NSMenuItem(title:title,action:selector,keyEquivalent:key)) }
        NSApp.mainMenu = menu
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); window.makeFirstResponder(text)
    }
    func focus() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(text) }
    func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value,forType: .string); focus() }
    @objc func copyA() { copy("拾贴验收 A · 中文 🧩\n    保留四个空格\n第二行") }
    @objc func copyB() { copy("拾贴验收 B · 第二条") }
    @objc func copyC() { copy("拾贴验收 C · 第三条") }
    @objc func copyRich() {
        let value = NSAttributedString(string: "拾贴验收 · 粗体红色", attributes: [.font:NSFont.boldSystemFont(ofSize: 22), .foregroundColor:NSColor.systemRed])
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([value]); focus()
    }
    @objc func copyImage() {
        let image = NSImage(size: NSSize(width: 480,height: 260)); image.lockFocus()
        NSColor.systemTeal.setFill(); NSBezierPath(roundedRect: NSRect(x:0,y:0,width:480,height:260),xRadius:24,yRadius:24).fill()
        let value = "拾贴 · 图片验收" as NSString; value.draw(at: NSPoint(x:70,y:110),withAttributes:[.font:NSFont.boldSystemFont(ofSize:32),.foregroundColor:NSColor.white]); image.unlockFocus()
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]); focus()
    }
    @objc func clear() { text.string = ""; text.setSelectedRange(NSRange(location:0,length:0)); focus() }
    func didPaste() {
        pasteCount += 1
        let image = text.attributedString().containsAttachments
        var bold = false
        if text.textStorage!.length > 0, let font = text.textStorage?.attribute(.font,at:0,effectiveRange:nil) as? NSFont { bold = NSFontManager.shared.traits(of:font).contains(.boldFontMask) }
        result.stringValue = "已收到 \(pasteCount) 次粘贴 · 图片：\(image ? "是" : "否") · 粗体：\(bold ? "是" : "否")"
        let record: [String:Any] = ["pasteCount":pasteCount,"text":text.string,"hasImage":image,"isBold":bold]
        if let data = try? JSONSerialization.data(withJSONObject:record,options:.prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/clipshelf-probe-result.json"),options:.atomic)
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        let items = original.map { values -> NSPasteboardItem in let item = NSPasteboardItem(); for (type,data) in values { item.setData(data,forType:type) }; return item }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(items)
    }
}
let app = NSApplication.shared
let delegate = ProbeDelegate(); app.delegate = delegate; app.run()
