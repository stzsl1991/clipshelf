import AppKit

struct CardSelection {
    private(set) var ids: [UUID] = []
    private(set) var selectedID: UUID?
    var index: Int? { selectedID.flatMap { ids.firstIndex(of: $0) } }
    mutating func replace(_ values: [UUID], preserving: Bool) {
        let previous = selectedID
        ids = values
        selectedID = preserving && previous.map({ values.contains($0) }) == true ? previous : values.first
    }
    mutating func select(_ id: UUID) { if ids.contains(id) { selectedID = id } }
    mutating func move(_ delta: Int) {
        guard !ids.isEmpty else { return }
        selectedID = ids[min(ids.count - 1, max(0, (index ?? 0) + delta))]
    }
}
enum CardGeometry {
    static let size = NSSize(width: 288, height: 208)
    static func contentWidth(count: Int) -> CGFloat { max(0, CGFloat(count) * (size.width + 12) - 12 + 8) }
    static func reveal(index: Int, current: CGFloat, viewport: CGFloat, count: Int) -> CGFloat {
        let leading = CGFloat(index) * (size.width + 12)
        let desired = leading < current ? leading : max(current, leading + size.width - viewport)
        return min(max(0, contentWidth(count: count) - viewport), max(0, desired))
    }
    static func frame(in visible: NSRect) -> NSRect {
        let width = max(1, min(1800, visible.width - 32))
        let height = min(296, max(1, visible.height - 24))
        return NSRect(x: visible.midX - width / 2, y: visible.minY + 12, width: width, height: height)
    }
}
