import AppKit
import CryptoKit

var checks = 0
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    checks += 1
    if try !condition() { throw ShelfError.message("FAIL: \(message)") }
}
func text(_ value: String, html: String? = nil) -> ClipPayload {
    var reps = [Representation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(value.utf8))]
    if let html = html { reps.append(Representation(type: NSPasteboard.PasteboardType.html.rawValue, data: Data(html.utf8))) }
    return ClipPayload(items: [ClipItem(representations: reps)])
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
let key = SymmetricKey(size: .bits256)
let now = Date()
do {
    let store = try HistoryStore(directory: root.appendingPathComponent("main"), key: key)
    let original = "中文 🧩\n    let value = \"保留缩进\"\n\treturn value\n"
    let a = try store.insert(text(original), source: "测试应用", bundleID: "test.app", now: now)
    let b = try store.insert(text("B"), source: "测试应用", bundleID: nil, now: now.addingTimeInterval(1))
    _ = try store.insert(text("C"), source: "测试应用", bundleID: nil, now: now.addingTimeInterval(2))
    try expect(store.entries.count == 3, "连续复制保留三条")
    try expect(store.entries.first?.text == "C", "最新复制在前")
    try expect(try store.payload(for: store.entries.last!) == text(original), "Unicode 和缩进完整恢复")
    _ = try store.insert(text(original), source: "测试应用", bundleID: nil, now: now.addingTimeInterval(3))
    try expect(store.entries.count == 3 && store.entries.first?.id == a, "相同内容去重并更新位置")
    let rich = try store.insert(text(original, html: "<b>中文 🧩</b>"), source: "测试应用", bundleID: nil, now: now.addingTimeInterval(4))
    try expect(store.entries.count == 4 && rich != a, "富文本格式不被误去重")
    try store.pin(a); try store.rename(a, name: "常用代码")
    try expect(store.filtered(query: "常用代码", filter: 3).map { $0.id } == [a], "收藏和名称搜索")
    try expect(store.filtered(query: "中文 缩进", filter: 1).count == 2, "中文多关键词过滤")
    let link = text("https://example.com/中文")
    try expect(link.kind == .link && text("hello https://example.com").kind == .text, "链接分类")
    let reopened = try HistoryStore(directory: store.directory, key: key)
    try expect(reopened.entries.count == 4 && reopened.entries.first?.id == rich, "重启恢复历史顺序")
    try expect(reopened.entries.first(where: { $0.id == a })?.name == "常用代码", "重启恢复收藏名称")
    let sealed = try Data(contentsOf: store.directory.appendingPathComponent("index.sealed"))
    try expect(sealed.range(of: Data("常用代码".utf8)) == nil && sealed.range(of: Data(original.utf8)) == nil, "磁盘索引不暴露文本")
    let encryptedPayload = try Data(contentsOf: store.directory.appendingPathComponent(a.uuidString + ".sealed"))
    try expect(encryptedPayload.range(of: Data(original.utf8)) == nil, "磁盘载荷加密")
    do { _ = try HistoryStore(directory: store.directory, key: SymmetricKey(size: .bits256)); throw ShelfError.message("FAIL: 错误密钥被接受") }
    catch is CryptoKitError { checks += 1 }
    try store.delete(b)
    try expect(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(b.uuidString + ".sealed").path), "删除同步清理载荷")
    try store.clear(includingPinned: false)
    try expect(store.entries.count == 1 && store.entries[0].id == a, "清空普通历史保留收藏")
    try store.prune(now: now.addingTimeInterval(40 * 86400))
    try expect(store.entries.count == 1, "收藏不随时间过期")
    try store.pin(a); try store.prune(now: now.addingTimeInterval(40 * 86400))
    try expect(store.entries.isEmpty, "取消收藏后过期清理")

    let limited = try HistoryStore(directory: root.appendingPathComponent("limited"), key: key, limits: HistoryLimits(count: 2, days: 30, bytes: 100, itemBytes: 40))
    let pinned = try limited.insert(text("keep"), source: "test", bundleID: nil, now: now); try limited.pin(pinned)
    _ = try limited.insert(text("old"), source: "test", bundleID: nil, now: now.addingTimeInterval(1))
    _ = try limited.insert(text("new"), source: "test", bundleID: nil, now: now.addingTimeInterval(2))
    try expect(limited.entries.count == 2 && limited.entries.contains(where: { $0.id == pinned }) && !limited.entries.contains(where: { $0.text == "old" }), "数量限额优先淘汰普通旧记录")
    do { _ = try limited.insert(text(String(repeating: "x", count: 41)), source: "test", bundleID: nil); throw ShelfError.message("FAIL: 超大记录被接受") }
    catch ShelfError.message(let message) { try expect(!message.hasPrefix("FAIL"), "单条容量限制") }
    let bytes = try HistoryStore(directory: root.appendingPathComponent("bytes"), key: key, limits: HistoryLimits(count: 10, days: 30, bytes: 6, itemBytes: 6))
    let fixed = try bytes.insert(text("123456"), source: "test", bundleID: nil, now: now); try bytes.pin(fixed)
    do { _ = try bytes.insert(text("x"), source: "test", bundleID: nil, now: now.addingTimeInterval(1)); throw ShelfError.message("FAIL: 收藏容量被覆盖") }
    catch ShelfError.message(let message) { try expect(!message.hasPrefix("FAIL") && bytes.entries.count == 1, "收藏占满时拒绝新内容") }

    let pb = NSPasteboard(name: .init("com.shulin.ClipShelf.tests.\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }
    let prefs = Preferences(defaults: UserDefaults(suiteName: "com.shulin.ClipShelf.Tests.\(UUID().uuidString)")!)
    let captureStore = try HistoryStore(directory: root.appendingPathComponent("capture"), key: key)
    let monitor = ClipboardMonitor(store: captureStore, preferences: prefs, pasteboard: pb)
    pb.clearContents(); pb.setString(original, forType: .string); monitor.tick(source: nil)
    try expect(captureStore.entries.first?.text == original, "真实 NSPasteboard 记录文本")
    let before = captureStore.entries.count
    monitor.paused = true; pb.clearContents(); pb.setString("paused", forType: .string); monitor.tick(source: nil)
    monitor.paused = false; monitor.tick(source: nil)
    try expect(captureStore.entries.count == before, "暂停内容在恢复时不补录")
    let hidden = NSPasteboardItem(); hidden.setString("secret-test", forType: .string); hidden.setString("1", forType: .init("org.nspasteboard.ConcealedType"))
    pb.clearContents(); pb.writeObjects([hidden]); monitor.tick(source: nil)
    try expect(captureStore.entries.count == before, "敏感标记过滤")
    let file = NSPasteboardItem(); file.setString("file:///tmp/only-a-test", forType: .fileURL); file.setString("/tmp/only-a-test", forType: .string)
    pb.clearContents(); pb.writeObjects([file]); monitor.tick(source: nil)
    try expect(captureStore.entries.count == before, "文件引用不会误存为文本")
    try monitor.restore(text(original, html: "<b>test</b>"), plainText: false)
    try expect(pb.string(forType: .string) == original && pb.string(forType: .html) == "<b>test</b>", "原格式回写")
    monitor.tick(source: nil)
    try expect(captureStore.entries.count == before, "自身回写不重复记录")
    try monitor.restore(text(original, html: "<b>test</b>"), plainText: true)
    try expect(pb.string(forType: .string) == original && pb.data(forType: .html) == nil, "纯文本去除富文本格式")
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let png = bitmap.representation(using: .png, properties: [:])!
    pb.clearContents(); pb.setData(png, forType: .png); monitor.tick(source: nil)
    try expect(captureStore.entries.first?.kind == .image && captureStore.entries.first?.imageWidth == 32, "图片记录与尺寸")
    let imagePayload = try captureStore.payload(for: captureStore.entries.first!)
    try monitor.restore(imagePayload, plainText: false)
    try expect(pb.data(forType: .png) == png, "图片无损回写")
    let permissions = try FileManager.default.attributesOfItem(atPath: captureStore.directory.path)[.posixPermissions] as? NSNumber
    try expect(permissions?.intValue == 0o700, "历史目录仅本用户可访问")
    monitor.sessionActive = false; pb.clearContents(); pb.setString("locked", forType: .string); monitor.tick(source: nil)
    try expect(!captureStore.entries.contains(where: { $0.text == "locked" }), "锁屏期间不记录")
    try captureStore.clear(includingPinned: true)
    try expect(try FileManager.default.contentsOfDirectory(atPath: captureStore.directory.path) == ["index.sealed"], "清空全部删除所有载荷")
    var cards = CardSelection()
    let c1 = UUID(), c2 = UUID(), c3 = UUID(), c4 = UUID()
    cards.replace([c1,c2,c3], preserving: false)
    try expect(cards.selectedID == c1, "打开卡片栏默认选最新内容")
    cards.move(1); try expect(cards.selectedID == c2, "右方向键选择更早内容")
    cards.replace([c4,c1,c2,c3], preserving: true)
    try expect(cards.selectedID == c2 && cards.index == 2, "新增复制不会抢走正在浏览的选择")
    cards.move(99); try expect(cards.selectedID == c3, "卡片尾部不越界")
    cards.move(-99); try expect(cards.selectedID == c4, "卡片头部不越界")
    cards.replace([c1,c3], preserving: false)
    try expect(cards.selectedID == c1, "搜索或切换类型后选择首个结果")
    cards.select(c3); cards.replace([c1], preserving: true)
    try expect(cards.selectedID == c1, "选中项删除后回到可用卡片")
    cards.replace([], preserving: false); cards.move(1)
    try expect(cards.selectedID == nil && cards.index == nil, "无结果时可安全使用方向键")
    let visible = NSRect(x: 0,y: 80,width: 1440,height: 795)
    let frame = CardGeometry.frame(in: visible)
    try expect(visible.contains(frame) && frame.minY == 92 && frame.height == 296, "卡片栏贴近可用屏幕底部且不遮挡 Dock")
    let leftDisplay = NSRect(x: -2560,y: -300,width: 2560,height: 1400)
    let secondary = CardGeometry.frame(in: leftDisplay)
    try expect(leftDisplay.contains(secondary) && secondary.width == 1800 && secondary.midX == leftDisplay.midX, "负坐标副屏正确居中且限制超宽")
    try expect(CardGeometry.reveal(index: 6, current: 0, viewport: 1200, count: 11) == 888, "键盘选择首屏外的卡片会将它滚入视野")
    try expect(CardGeometry.reveal(index: 0, current: 888, viewport: 1200, count: 11) == 0, "返回首项会恢复队列左端")
    try expect(CardGeometry.reveal(index: 2, current: 0, viewport: 1200, count: 3) == 0, "短队列不会产生空白滚动")
    print("PASS: \(checks) checks. Named test pasteboard only; system clipboard untouched.")
} catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
