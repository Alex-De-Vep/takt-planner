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
        let container = NSView()
        view = container
        let extensionView = WorkspaceDocumentBackdrop()
        extensionView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(extensionView)
        let surface = WorkspaceDocumentSurface()
        surface.wantsLayer = true
        extensionView.contentView = surface
        addChild(contentHost)
        let content = contentHost.view
        content.translatesAutoresizingMaskIntoConstraints = false
        // Расширение фона создаёт системный контейнер, который перехватывает клики.
        // Оставляем фон отдельным слоем, а редактор размещаем поверх него.
        container.addSubview(content)
        NSLayoutConstraint.activate([
            extensionView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            extensionView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            extensionView.topAnchor.constraint(equalTo: container.topAnchor),
            extensionView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            content.topAnchor.constraint(equalTo: surface.topAnchor),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
    }

    func updateContent(_ content: AnyView) { contentHost.rootView = content }
}

private final class WorkspaceDocumentBackdrop: NSBackgroundExtensionView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
