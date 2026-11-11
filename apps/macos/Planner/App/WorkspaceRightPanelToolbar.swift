import AppKit

/// Конечные места панелей: каждая настоящая кнопка сохраняет свою принадлежность и значок.
struct RightPanelToolbarRoles: Equatable {
    let outer: RightPanel
    let trailing: RightPanel

    init(active: RightPanel?) {
        outer = active == .assistant ? .calendar : .assistant
        trailing = active == .assistant ? .assistant : .calendar
    }
}

/// Шаблонный значок рисуется системными векторными символами в масштабе текущего экрана.
@MainActor
enum WorkspaceAIChatSymbol {
    static func image() -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular, scale: .medium)
            .applying(.init(paletteColors: [.black]))
        let bubble = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        let sparkle = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // Очистка относится только к значку: стекло или фон под ним не стираются.
            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            defer { context.endTransparencyLayer(); context.restoreGState() }
            bubble?.draw(in: NSRect(x: 1, y: 1, width: 17, height: 17))
            // Просвет отделяет искру от контура облачка, не добавляя непрозрачного фона.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: 10, y: 9, width: 10, height: 11)).fill()
            NSGraphicsContext.restoreGraphicsState()
            sparkle?.draw(in: NSRect(x: 11, y: 10, width: 8, height: 9))
            return true
        }
        image.isTemplate = true
        image.cacheMode = .never
        image.accessibilityDescription = nil
        return image
    }
}
