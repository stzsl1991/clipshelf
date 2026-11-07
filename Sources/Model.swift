import AppKit
import CryptoKit
import Security

enum ClipKind: String, Codable { case text, link, image
    var label: String { self == .image ? "图片" : (self == .link ? "链接" : "文本") }
    var symbol: String { self == .image ? "photo" : (self == .link ? "link" : "text.alignleft") }
}
struct Representation: Codable, Equatable { let type: String; let data: Data }
struct ClipItem: Codable, Equatable { let representations: [Representation] }
struct ClipPayload: Codable, Equatable {
    let items: [ClipItem]
    var byteCount: Int { items.flatMap { $0.representations }.reduce(0) { $0 + $1.data.count } }
    var fingerprint: String {
        var hash = SHA256()
        for item in items {
            hash.update(data: Data("ITEM\u{0}".utf8))
            for rep in item.representations.sorted(by: { $0.type < $1.type }) {
                hash.update(data: Data("\(rep.type.utf8.count):\(rep.type):\(rep.data.count):".utf8))
                hash.update(data: rep.data)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    var plainText: String? {
        let values = items.compactMap { item -> String? in
            for type in [NSPasteboard.PasteboardType.string.rawValue, NSPasteboard.PasteboardType.URL.rawValue] {
                if let rep = item.representations.first(where: { $0.type == type }), let s = String(data: rep.data, encoding: .utf8) { return s }
            }
            if let rtf = item.representations.first(where: { $0.type == NSPasteboard.PasteboardType.rtf.rawValue }),
               let attributed = try? NSAttributedString(data: rtf.data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) { return attributed.string }
            return nil
        }
        return values.isEmpty ? nil : values.joined(separator: "\n")
    }
    var imageData: Data? {
        let reps = items.flatMap { $0.representations }
        for type in [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue, "public.jpeg"] {
            if let rep = reps.first(where: { $0.type == type }) { return rep.data }
        }
        return nil
    }
    var kind: ClipKind {
        if imageData != nil { return .image }
        if let text = plainText?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: text), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""), !text.contains("\n") { return .link }
        return .text
    }
}
struct ClipEntry: Codable, Equatable {
    let id: UUID
    let fingerprint: String
    let kind: ClipKind
    let text: String?
    let sourceName: String
    let sourceBundleID: String?
    var copiedAt: Date
    var pinned: Bool
    var name: String?
    let bytes: Int
    let imageWidth: Int?
    let imageHeight: Int?
    var title: String {
        if let name = name, !name.isEmpty { return name }
        if kind == .image { return "图片 · \(imageWidth ?? 0) × \(imageHeight ?? 0)" }
        let compact = (text ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return compact.isEmpty ? "空白文本" : String(compact.prefix(120))
    }
}
struct HistoryLimits { var count = 1000; var days = 30; var bytes = 500 * 1024 * 1024; var itemBytes = 32 * 1024 * 1024 }
enum ShelfError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
enum LocalKey {
    static func loadOrCreate() throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.shulin.ClipShelf", kSecAttrAccount as String: "history-key-v1"]
        var read = query; read[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw ShelfError.message("无法访问历史加密密钥（\(status)）。原有历史未被覆盖。") }
        let key = SymmetricKey(size: .bits256)
        var add = query
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw ShelfError.message("无法保存历史加密密钥（\(added)）。") }
        return key
    }
}
final class HistoryStore {
    private(set) var entries: [ClipEntry] = []
    let directory: URL
    private let key: SymmetricKey
    var limits: HistoryLimits
    var onChange: (() -> Void)?
    private let fm = FileManager.default
    private var manifest: URL { directory.appendingPathComponent("index.sealed") }
    init(directory: URL, key: SymmetricKey, limits: HistoryLimits = HistoryLimits()) throws {
        self.directory = directory; self.key = key; self.limits = limits
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fm.fileExists(atPath: manifest.path) {
            entries = try JSONDecoder().decode([ClipEntry].self, from: decrypt(Data(contentsOf: manifest)))
            guard entries.allSatisfy({ fm.fileExists(atPath: payloadURL($0.id).path) }) else {
                throw ShelfError.message("本地历史数据不完整。已停止记录，避免覆盖原有历史。")
            }
        }
        try prune()
        let retained = Set(entries.map { $0.id.uuidString + ".sealed" }).union(["index.sealed"])
        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where !retained.contains(file.lastPathComponent) && file.pathExtension == "sealed" {
            try? fm.removeItem(at: file)
        }
    }
    private func encrypt(_ data: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw ShelfError.message("无法加密历史。") }
        return combined
    }
    private func decrypt(_ data: Data) throws -> Data { try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key) }
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func payloadURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".sealed") }
    func payload(for entry: ClipEntry) throws -> ClipPayload {
        try PropertyListDecoder().decode(ClipPayload.self, from: decrypt(Data(contentsOf: payloadURL(entry.id))))
    }
    private func commit(_ next: [ClipEntry]) throws {
        try write(encrypt(JSONEncoder().encode(next)), to: manifest)
        let ids = Set(next.map { $0.id })
        let removed = entries.filter { !ids.contains($0.id) }
        entries = next
        for entry in removed { try? fm.removeItem(at: payloadURL(entry.id)) }
        onChange?()
    }
    private func trimmed(_ values: [ClipEntry], now: Date) -> [ClipEntry] {
        let cutoff = now.addingTimeInterval(-Double(limits.days) * 86400)
        var next = values.filter { $0.pinned || $0.copiedAt >= cutoff }.sorted { $0.copiedAt > $1.copiedAt }
        while next.count > limits.count || next.reduce(0, { $0 + $1.bytes }) > limits.bytes {
            guard let index = next.lastIndex(where: { !$0.pinned }) else { break }
            next.remove(at: index)
        }
        return next
    }
    @discardableResult func insert(_ payload: ClipPayload, source: String, bundleID: String?, now: Date = Date()) throws -> UUID {
        guard payload.byteCount > 0, payload.byteCount <= limits.itemBytes else { throw ShelfError.message("这条内容超过单条容量上限（32 MB），未记录。") }
        let digest = payload.fingerprint
        if let index = entries.firstIndex(where: { $0.fingerprint == digest }) {
            var next = entries; next[index].copiedAt = now
            let id = next[index].id
            try commit(trimmed(next, now: now)); return id
        }
        let data = payload.imageData
        let rep = data.flatMap { NSBitmapImageRep(data: $0) }
        let entry = ClipEntry(id: UUID(), fingerprint: digest, kind: payload.kind, text: payload.plainText,
            sourceName: source, sourceBundleID: bundleID, copiedAt: now, pinned: false, name: nil,
            bytes: payload.byteCount, imageWidth: rep?.pixelsWide, imageHeight: rep?.pixelsHigh)
        let next = trimmed([entry] + entries, now: now)
        guard next.contains(where: { $0.id == entry.id }) else { throw ShelfError.message("历史容量已被收藏占满，请先清理收藏。") }
        try write(encrypt(PropertyListEncoder().encode(payload)), to: payloadURL(entry.id))
        do { try commit(next) } catch { try? fm.removeItem(at: payloadURL(entry.id)); throw error }
        return entry.id
    }
    func prune(now: Date = Date()) throws {
        let next = trimmed(entries, now: now)
        if next != entries { try commit(next) }
    }
    func pin(_ id: UUID) throws {
        var next = entries
        guard let i = next.firstIndex(where: { $0.id == id }) else { return }
        next[i].pinned.toggle(); try commit(next)
    }
    func rename(_ id: UUID, name: String) throws {
        var next = entries
        guard let i = next.firstIndex(where: { $0.id == id }) else { return }
        next[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines); try commit(next)
    }
    func delete(_ id: UUID) throws { try commit(entries.filter { $0.id != id }) }
    func clear(includingPinned: Bool) throws { try commit(includingPinned ? [] : entries.filter { $0.pinned }) }
    func filtered(query: String, filter: Int) -> [ClipEntry] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return entries.filter { entry in
            if filter == 1 && entry.kind == .image { return false }
            if filter == 2 && entry.kind != .image { return false }
            if filter == 3 && !entry.pinned { return false }
            let haystack = [entry.name ?? "", entry.text ?? "", entry.sourceName, entry.kind.label].joined(separator: "\n")
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }.sorted { $0.copiedAt > $1.copiedAt }
    }
}
