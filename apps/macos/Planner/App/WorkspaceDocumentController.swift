import AppKit
import SwiftUI

/// Сплошная бумага занимает также пространство под плавающим календарём.
/// Только редактор ограничен safe area: при открытии панели фон не получает прямоугольного шва.
@MainActor
final class WorkspaceDocumentController: NSViewController {
    private let contentHost = NSHostingController(rootView: AnyView(EmptyView()))

    override func loadView() {
        // Системное расширение фона участвует в композиции стекла, включая его внешнюю тень.
        // Обычная непрозрачная подложка под колонками оставляла стык у полноэкранной шапки календаря.
        let extensionView = NSBackgroundExtensionView()
        view = extensionView
        let surface = WorkspaceDocumentSurface()
        surface.wantsLayer = true
        extensionView.contentView = surface
        addChild(contentHost)
        let content = contentHost.view
        content.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            content.topAnchor.constraint(equalTo: surface.topAnchor),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
    }

    func updateContent(_ content: AnyView) { contentHost.rootView = content }
}

private final class WorkspaceDocumentSurface: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
