import AppKit

/// Область захвата шире видимой линии и не участвует в отрисовке или раскладке колонок.
enum WorkspaceDividerInteraction {
    static let hitWidth: CGFloat = 16

    static func hitRect(at x: CGFloat, in bounds: NSRect) -> NSRect {
        NSRect(x: x - hitWidth / 2, y: bounds.minY, width: hitWidth, height: bounds.height)
    }
}
