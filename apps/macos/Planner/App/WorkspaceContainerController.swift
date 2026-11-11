import AppKit
import SwiftUI

enum CalendarPanelLayout {
    static let minimumWidth: CGFloat = 320
    static let maximumWidth: CGFloat = 1200
    static let defaultWidth: CGFloat = 340
    // Внешний зазор справа одинаков у отдельной колонки и накладной панели.
    static let outerInset: CGFloat = 8

    static func minimumMainWidth(sidebarVisible: Bool, fullScreen: Bool, preferredHeadingWidth: CGFloat = 80) -> CGFloat {
        WorkspaceHeaderLayout(sidebarVisible: sidebarVisible, fullScreen: fullScreen,
                              calendarPlacement: .closed, preferredHeadingWidth: preferredHeadingWidth).minimumMainWidth
    }
    static func isColumn(width: CGFloat, sidebarVisible: Bool, fullScreen: Bool = false) -> Bool {
        width >= minimumMainWidth(sidebarVisible: sidebarVisible, fullScreen: fullScreen) + minimumWidth + outerInset
    }
    static func panelWidth(_ preferred: CGFloat) -> CGFloat { min(maximumWidth, max(minimumWidth, preferred)) }
    static func overlayWidth(_ preferred: CGFloat, windowWidth: CGFloat) -> CGFloat {
        min(panelWidth(preferred), max(0, windowWidth - 2 * outerInset))
    }
}

/// В широком окне календарь — нативная боковая панель той же split view, что и папки.
/// В узком окне тот же контроллер переходит в накладную панель без увеличения окна.
@MainActor
final class WorkspaceContainerController: NSViewController {
    let workspace = WorkspaceSplitController()
    private let calendarHost = CalendarSidebarController()
    private let divider = CalendarResizeHandle()
    private let headerBackdrop = WorkspaceHeaderBackdrop()
    private var visible = false
    private var panel: RightPanel?
    private var preferredWidth = CalendarPanelLayout.defaultWidth
    private var minimumPanelWidth = CalendarPanelLayout.minimumWidth
    private var maximumPanelWidth = CalendarPanelLayout.maximumWidth
    private var sidebarVisible = true
    private var widthChanged: ((Double) -> Void)?
    private var visibilityChanged: ((Bool) -> Void)?
    private enum Placement { case closed, column, overlay }
    private var placement: Placement = .closed
    private var arranging = false
    private var appliedWidth = CalendarPanelLayout.defaultWidth
    private var appliedMinimumWidth = CalendarPanelLayout.minimumWidth
    private var appliedMaximumWidth = CalendarPanelLayout.maximumWidth
    private var animationGeneration = 0
    private var animatingOverlay = false
    private var columnLayoutScheduled = false
    private var isDismantled = false

    override func loadView() {
        let root = WorkspaceContainerView()
        root.wantsLayer = true
        view = root
        addChild(workspace); addChild(calendarHost)
        root.addSubview(workspace.view)
        root.addSubview(calendarHost.view)
        root.addSubview(divider)
        // Шапка находится выше обеих панелей, включая накладной календарь. Toolbar остаётся нативным.
        // В оконном режиме геометрия подложки не заходит на стекло открытых панелей.
        root.addSubview(headerBackdrop)
        calendarHost.view.isHidden = true
        divider.isHidden = true
        root.layoutContent = { [weak self] in self?.layoutColumns() }
        workspace.columnFramesChanged = { [weak self] in self?.updateBackgrounds() }
        workspace.headerConfigurationChanged = { [weak self] in self?.scheduleColumnLayout() }
        workspace.sidebarVisibilityWillChange = { [weak self] visible in
            guard let self else { return }
            self.sidebarVisible = visible
            self.layoutColumns()
        }
        divider.resize = { [weak self] delta in
            guard let self else { return }
            // Начинаем с видимой ширины: после сужения окна сохранённое предпочтение может быть больше панели.
            self.preferredWidth = min(self.maximumPanelWidth, max(self.minimumPanelWidth, self.calendarHost.view.frame.width - delta))
            self.layoutColumns()
            self.widthChanged?(self.preferredWidth)
        }
        workspace.calendarWidthChanged = { [weak self] width in
            guard let self else { return }
            self.preferredWidth = width
            self.appliedWidth = width
            DispatchQueue.main.async { [weak self] in self?.widthChanged?(width) }
        }
        workspace.calendarVisibilityChanged = { [weak self] visible in self?.visibilityChanged?(visible) }
    }

    func update(calendar: AnyView, visible: Bool, width: Double, sidebarVisible: Bool, panel: RightPanel? = .calendar,
                minimumWidth: CGFloat = CalendarPanelLayout.minimumWidth, maximumWidth: CGFloat = CalendarPanelLayout.maximumWidth,
                widthChanged: @escaping (Double) -> Void, visibilityChanged: @escaping (Bool) -> Void) {
        _ = view
        calendarHost.updateContent(calendar)
        let switching = self.visible && visible && self.panel != panel
        let animate = (self.visible != visible || switching) && view.window != nil
        self.panel = panel
        self.visible = visible; minimumPanelWidth = minimumWidth; maximumPanelWidth = maximumWidth
        preferredWidth = min(maximumWidth, max(minimumWidth, width))
        self.sidebarVisible = sidebarVisible; self.widthChanged = widthChanged
        self.visibilityChanged = visibilityChanged
        if switching && animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // При смене календаря и чата меняется и ширина той же панели — без мгновенного setPosition.
            NSAnimationContext.runAnimationGroup { context in
                PlannerMotion.configure(context)
                context.allowsImplicitAnimation = true
                layoutColumns(animate: true)
            }
        } else { layoutColumns(animate: animate) }
    }

    private func scheduleColumnLayout() {
        guard !columnLayoutScheduled else { return }
        columnLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.columnLayoutScheduled = false
            self.layoutColumns()
        }
    }

    private func layoutColumns(animate: Bool = false) {
        guard !arranging, !isDismantled else { return }
        arranging = true
        defer { arranging = false; updateBackgrounds() }
        let bounds = view.bounds
        guard bounds.width > 0 else { return }
        let header = workspace.headerLayout
        // Состояние SwiftUI приходит чуть раньше фактического сворачивания панели AppKit.
        // На переходе учитываем обе ширины, чтобы новая минимальная ширина не увеличила окно.
        let minimumMain = max(header.minimumMainWidth,
            CalendarPanelLayout.minimumMainWidth(sidebarVisible: sidebarVisible, fullScreen: header.fullScreen,
                                                preferredHeadingWidth: header.preferredHeadingWidth))
        let column = visible && bounds.width >= minimumMain + minimumPanelWidth + CalendarPanelLayout.outerInset
        let width = column ? min(preferredWidth, bounds.width - CalendarPanelLayout.outerInset - minimumMain)
            : min(preferredWidth, max(0, bounds.width - 2 * CalendarPanelLayout.outerInset))

        // Перед уменьшением основной split view отсоединяем боковую панель, если её минимальная ширина уже не помещается.
        if visible && !column && calendarHost.parent === workspace {
            workspace.detachCalendarSidebar()
            calendarHost.view.removeFromSuperview()
            if calendarHost.parent != nil { calendarHost.removeFromParent() }
            addChild(calendarHost)
            view.addSubview(calendarHost.view, positioned: .below, relativeTo: divider)
        }
        // Сначала убираем не помещающийся календарь из split view, только потом расширяем список.
        if !visible && calendarHost.parent === workspace {
            workspace.collapseCalendarSidebar(animate: animate)
        }
        workspace.updateTaskColumnMinimumWidth(sidebarVisible: sidebarVisible)
        // Split view занимает всё окно: AppKit сохраняет связь боковых панелей с полноэкранной шапкой.
        if workspace.view.frame != bounds { workspace.view.frame = bounds }
        divider.isHidden = !visible || column

        if column {
            calendarHost.usesOverlayChrome = false
            animationGeneration += 1; animatingOverlay = false
            let needsAttachment = calendarHost.parent !== workspace
            if needsAttachment {
                calendarHost.view.removeFromSuperview()
                calendarHost.removeFromParent()
            }
            calendarHost.view.isHidden = false
            if needsAttachment || placement != .column || abs(appliedWidth - width) >= 1
                || appliedMinimumWidth != minimumPanelWidth || appliedMaximumWidth != maximumPanelWidth {
                workspace.attachCalendarSidebar(calendarHost, width: width, animate: animate, minimumWidth: minimumPanelWidth, maximumWidth: maximumPanelWidth)
                appliedWidth = width
                appliedMinimumWidth = minimumPanelWidth; appliedMaximumWidth = maximumPanelWidth
            }
            placement = .column
            workspace.setCalendarToolbar(column: true, visible: true)
        } else if visible {
            calendarHost.usesOverlayChrome = true
            appliedWidth = width
            let opening = placement != .overlay
            placement = .overlay
            if opening { workspace.beginCalendarHeaderTransition() }
            workspace.setCalendarToolbar(column: false, visible: true, overlayWidth: width)
            let frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
            if opening {
                calendarHost.view.frame = frame.offsetBy(dx: width, dy: 0)
                calendarHost.view.isHidden = false
                moveOverlay(to: frame, hide: false, animate: animate)
            } else if !animatingOverlay { calendarHost.view.frame = frame }
            if !animatingOverlay {
                divider.frame = WorkspaceDividerInteraction.hitRect(at: frame.minX, in: frame)
            }
        } else {
            let previous = placement
            placement = .closed
            // Нативная колонка уже закрывается выше: её шапка сохраняется до конца анимации.
            // Повторный collapse из layout перебивал начатый переход неанимированным обновлением.
            if calendarHost.parent !== workspace {
                workspace.setCalendarToolbar(column: false, visible: false)
            }
            if calendarHost.parent !== workspace, previous == .overlay {
                moveOverlay(to: NSRect(x: bounds.width, y: 0, width: width, height: bounds.height), hide: true, animate: animate)
            } else if calendarHost.parent !== workspace, !animatingOverlay { calendarHost.view.isHidden = true }
        }
    }

    private func updateBackgrounds() {
        guard !isDismantled, let root = view as? WorkspaceContainerView else { return }
        let column = workspace.documentColumnFrame(in: root)
        // Бумага задачи продолжается до края окна, включая подложку под стеклянным календарём.
        root.documentBackground = NSRect(x: column.minX, y: 0,
                                         width: max(0, root.bounds.maxX - column.minX), height: root.bounds.height)
        // Собственная подложка используется только для оконного режима со скрытыми папками.
        // В полном экране фон и разделитель принадлежат системному toolbar.
        let canvas = root
        if headerBackdrop.superview !== canvas {
            headerBackdrop.removeFromSuperview()
            canvas.addSubview(headerBackdrop, positioned: .above, relativeTo: nil)
        }
        headerBackdrop.frame = canvas.bounds
        let headerBounds = headerBackdrop.bounds
        let calendarLeading: CGFloat
        if visible && placement == .column {
            calendarLeading = workspace.dividerPosition(at: 2, in: headerBackdrop)
        } else if visible {
            calendarLeading = root.convert(NSPoint(x: max(0, root.bounds.maxX - appliedWidth), y: 0), to: headerBackdrop).x
        } else {
            calendarLeading = headerBounds.maxX
        }
        headerBackdrop.regions = workspace.headerLayout.regions(
            bounds: headerBounds, headerBottom: workspace.headerBottom(in: headerBackdrop),
            sidebarTrailing: workspace.taskColumnFrame(in: headerBackdrop).minX,
            calendarLeading: calendarLeading, scale: headerBackdrop.window?.backingScaleFactor ?? 2)
    }

    func detachWindow() {
        // После демонтажа отложенный layout не должен снова устанавливать подложку.
        isDismantled = true
        headerBackdrop.removeFromSuperview()
        workspace.detachWindow()
    }

    private func moveOverlay(to frame: NSRect, hide: Bool, animate: Bool) {
        animationGeneration += 1
        let generation = animationGeneration
        let dividerFrame = WorkspaceDividerInteraction.hitRect(at: frame.minX, in: frame)
        guard animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            calendarHost.view.frame = frame
            divider.frame = dividerFrame
            calendarHost.view.isHidden = hide
            animatingOverlay = false
            workspace.finishCalendarHeaderTransition(afterLayout: false)
            return
        }
        animatingOverlay = true
        // Ручка изменения ширины движется вместе с панелью, не появляясь сразу в конечной позиции.
        divider.frame = WorkspaceDividerInteraction.hitRect(at: calendarHost.view.frame.minX, in: frame)
        NSAnimationContext.runAnimationGroup { context in
            PlannerMotion.configure(context)
            calendarHost.view.animator().frame = frame
            divider.animator().frame = dividerFrame
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.animationGeneration else { return }
                self.animatingOverlay = false
                if hide && !self.visible { self.calendarHost.view.isHidden = true }
                self.workspace.finishCalendarHeaderTransition(afterLayout: true)
            }
        }
    }
}

private final class WorkspaceContainerView: NSView {
    var layoutContent: (() -> Void)?
    var documentBackground: NSRect = .zero {
        didSet { if oldValue != documentBackground { needsDisplay = true } }
    }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // Под папками остаётся фон списка, а задача, её шапка и подложка календаря используют одну бумагу.
        PlannerStyle.workspaceBackground.setFill()
        dirtyRect.fill()
        NSColor.textBackgroundColor.setFill()
        let paper = documentBackground.intersection(dirtyRect)
        if !paper.isEmpty { paper.fill() }
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func layout() { super.layout(); layoutContent?() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
}

/// Невидимая область захвата шириной 16 pt; видимая линия остаётся прежней толщины.
private final class CalendarResizeHandle: NSView {
    var resize: ((CGFloat) -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.midX, y: 0, width: 1, height: bounds.height).fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        var previous = event.locationInWindow.x
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            resize?(next.locationInWindow.x - previous)
            previous = next.locationInWindow.x
        }
    }
}
