import AppKit
import SwiftUI

/// Содержимое календаря сохраняется при переходе между системной колонкой и накладной панелью.
@MainActor
final class CalendarSidebarController: NSViewController {
    private let contentHost = NSHostingController(rootView: AnyView(EmptyView()))
    private let glass = NSGlassEffectView()
    var usesOverlayChrome = false {
        didSet {
            guard oldValue != usesOverlayChrome, isViewLoaded else { return }
            configureChrome()
        }
    }

    override func loadView() {
        let root = CalendarSidebarSurface()
        // При анимации накладной панели её непрозрачный фон ограничен собственной областью.
        // Иначе AppKit может передать расширенный dirtyRect и закрасить соседние колонки.
        root.wantsLayer = true
        root.clipsToBounds = true
        view = root
        addChild(contentHost)
        glass.style = .regular
        // В накладном режиме воспроизводим отступ и внутренние углы панели папок; рамку рисует системное стекло.
        glass.cornerRadius = 20
        root.addSubview(glass)
        root.layoutContent = { [weak self] in self?.layoutContent() }
        configureChrome()
    }

    func updateContent(_ content: AnyView) { contentHost.rootView = content }

    private func configureChrome() {
        guard let root = view as? CalendarSidebarSurface else { return }
        root.drawsBackdrop = usesOverlayChrome
        if usesOverlayChrome {
            contentHost.view.removeFromSuperview()
            glass.contentView = contentHost.view
            glass.isHidden = false
        } else {
            // NSSplitViewItem.sidebar уже содержит стекло: второй слой здесь не нужен.
            glass.contentView = nil
            glass.isHidden = true
            root.addSubview(contentHost.view)
        }
        layoutContent()
    }

    private func layoutContent() {
        if usesOverlayChrome {
            // При первом присоединении контроллер ещё может иметь нулевые размеры.
            let inset = CalendarPanelLayout.outerInset
            glass.frame = NSRect(x: inset, y: inset, width: max(0, view.bounds.width - 2 * inset),
                                 height: max(0, view.bounds.height - 2 * inset))
            contentHost.view.frame = glass.bounds
        } else { contentHost.view.frame = view.bounds }
    }
}

private final class CalendarSidebarSurface: NSView {
    var layoutContent: (() -> Void)?
    var drawsBackdrop = false { didSet { needsDisplay = true } }
    override var isOpaque: Bool { drawsBackdrop }
    override func draw(_ dirtyRect: NSRect) {
        guard drawsBackdrop else { return }
        // В накладном режиме отступы вокруг стекла также совпадают с фоном задачи.
        NSColor.textBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() { super.layout(); layoutContent?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
