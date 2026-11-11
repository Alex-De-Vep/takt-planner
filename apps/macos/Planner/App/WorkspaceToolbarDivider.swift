import AppKit

/// Продолжение нативной границы списка в отдельном полноэкранном toolbar.
/// Линия не участвует в раскладке кнопок, не перехватывает мышь и не создаёт собственную тень.
@MainActor
final class WorkspaceToolbarDivider: NSView {
    // Используем цвет самой границы колонок, включая системную смену оформления.
    weak var sourceSplitView: NSSplitView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        (sourceSplitView?.dividerColor ?? .separatorColor).setFill()
        bounds.intersection(dirtyRect).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
