import Foundation

/// Общие правила шапки: геометрия списка, оформление панелей и границы основного фона.
struct WorkspaceHeaderLayout: Equatable {
    enum CalendarPlacement: Equatable { case closed, column, overlay }

    let sidebarVisible: Bool
    let fullScreen: Bool
    let calendarPlacement: CalendarPlacement
    var preferredHeadingWidth: CGFloat = 80

    var unified: Bool { !sidebarVisible || fullScreen }

    // При скрытых папках место над списком занимают также кнопки окна и открытия панели.
    var minimumTaskWidth: CGFloat {
        if fullScreen && sidebarVisible {
            // В широкой шапке резервируем полное название, обычный поиск и отступы секции toolbar.
            return min(420, max(340, ceil(preferredHeadingWidth) + Self.standardSearchWidth + Self.headingSearchSpacing + 36))
        }
        return sidebarVisible ? 260 : (fullScreen ? 320 : 400)
    }
    var minimumMainWidth: CGFloat { (sidebarVisible ? 220 : 0) + minimumTaskWidth + 320 + 3 }

    static let minimumHeadingWidth: CGFloat = 80
    static let minimumSearchWidth: CGFloat = 100
    static let standardSearchWidth: CGFloat = 180
    static let headingSearchSpacing: CGFloat = 20

    func contentWidths(available: CGFloat) -> (heading: CGFloat, search: CGFloat) {
        let budget = max(Self.minimumHeadingWidth + Self.minimumSearchWidth, available - Self.headingSearchSpacing)
        if fullScreen && sidebarVisible {
            // Не делим место пополам: сначала учитываем реальную ширину названия и счётчика.
            let heading = max(Self.minimumHeadingWidth, ceil(preferredHeadingWidth))
            let search = min(Self.standardSearchWidth, max(Self.minimumSearchWidth, budget - heading))
            return (budget - search, search)
        }
        let search = min(180, max(Self.minimumSearchWidth, floor(budget * 0.5)))
        return (budget - search, search)
    }

    struct Regions: Equatable {
        var background: CGRect = .zero
        var separator: CGRect = .zero
    }

    func regions(bounds: CGRect, headerBottom: CGFloat, sidebarTrailing: CGFloat,
                 calendarLeading: CGFloat, scale: CGFloat) -> Regions {
        // Полноэкранная шапка принадлежит отдельному системному toolbar. Не перекрываем её своим слоем.
        guard !fullScreen, unified, !bounds.isEmpty, headerBottom < bounds.maxY else { return Regions() }
        // В оконном режиме подложка объединяет шапку только при скрытых папках.
        let left = sidebarVisible ? max(bounds.minX, sidebarTrailing) : bounds.minX
        let right = calendarPlacement == .closed ? bounds.maxX : min(bounds.maxX, max(bounds.minX, calendarLeading))
        let scale = max(1, scale)
        let bottom = min(bounds.maxY, max(bounds.minY, (headerBottom * scale).rounded() / scale))
        guard right > left else { return Regions() }
        return Regions(
            background: CGRect(x: left, y: bottom, width: right - left, height: bounds.maxY - bottom),
            separator: CGRect(x: left, y: bottom, width: right - left, height: 1 / scale))
    }
}
