import AppKit

/// Фон и разделители шапки рисуются поверх колонок, но под нативными кнопками toolbar.
@MainActor
final class WorkspaceHeaderBackdrop: NSView {
    var regions = WorkspaceHeaderLayout.Regions() {
        didSet { if oldValue != regions { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Собственный слой сохраняет порядок наложения рядом с NSHostingView и системным стеклом.
        wantsLayer = true
        autoresizingMask = [.width, .height]
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        let background = regions.background.intersection(dirtyRect)
        if !background.isEmpty { background.fill() }
        NSColor.separatorColor.setFill()
        let separator = regions.separator.intersection(dirtyRect)
        if !separator.isEmpty { separator.fill() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
