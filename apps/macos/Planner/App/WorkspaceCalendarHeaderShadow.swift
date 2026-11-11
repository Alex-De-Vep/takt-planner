import AppKit

/// В полноэкранной шапке AppKit обрезает внешнюю тень правой панели границей секции toolbar.
/// Этот узкий прозрачный слой продолжает только недостающую часть тени в сторону документа.
@MainActor
final class WorkspaceCalendarHeaderShadow: NSView {
    static let reach: CGFloat = 32
    var panelFrame: NSRect = .zero { didSet { if oldValue != panelFrame { needsDisplay = true } } }
    var baselineFrame: NSRect = .zero { didSet { if oldValue != baselineFrame { needsDisplay = true } } }

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
        // Стекло должно целиком находиться справа от полосы тени. Промежуточную геометрию не рисуем.
        guard !panelFrame.isEmpty, panelFrame.minX >= Self.reach else { return }
        NSGraphicsContext.saveGraphicsState()
        // Продолжаем тень только слева от нативной секции, не затемняя её второй раз.
        NSRect(x: bounds.minX, y: bounds.minY, width: Self.reach, height: bounds.height)
            .intersection(dirtyRect).clip()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.shadowColor.withAlphaComponent(0.12)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = .zero
        shadow.set()
        // Сама фигура лежит за пределами слоя: фон и стекло остаются полностью системными.
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(roundedRect: panelFrame, xRadius: 20, yRadius: 20).fill()
        NSGraphicsContext.restoreGraphicsState()

        // На стыке секций AppKit накладывает нижние линии друг на друга.
        // Одна общая линия поверх бумаги сохраняет разделение без короткого тёмного отрезка.
        let baseline = baselineFrame.intersection(bounds).intersection(dirtyRect)
        if !baseline.isEmpty {
            NSColor.textBackgroundColor.setFill()
            baseline.fill()
            NSColor.separatorColor.setFill()
            baseline.fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
