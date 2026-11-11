import AppKit
import QuartzCore

/// Траектория использует ту же кривую easeInEaseOut, что и нативная анимация боковой панели.
struct RightPanelButtonPath {
    let start: CGRect
    let end: CGRect

    static func progress(_ fraction: Double) -> Double {
        guard fraction > 0 else { return 0 }
        guard fraction < 1 else { return 1 }
        func cubic(_ t: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<20 {
            let t = (low + high) / 2
            if cubic(t, 0.42, 0.58) < fraction { low = t } else { high = t }
        }
        return cubic((low + high) / 2, 0, 1)
    }

    func frame(at fraction: Double) -> CGRect {
        let p = Self.progress(fraction)
        return CGRect(x: start.minX + (end.minX - start.minX) * p,
                      y: start.minY + (end.minY - start.minY) * p,
                      width: start.width + (end.width - start.width) * p,
                      height: start.height + (end.height - start.height) * p)
    }
}

/// AppKit меняет alignmentRectInsets у accessory-кнопки при смене формы рамки.
/// Здесь размер и центр заданы оболочкой: форма не должна сдвигать сам значок.
@MainActor
final class WorkspacePanelToggleButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
}

/// Постоянное пустое место toolbar задаёт только геометрию. Значок и действие принадлежат самой кнопке.
@MainActor
final class WorkspaceRightPanelSlot: NSView {
    private(set) var carrier: WorkspaceRightPanelButtonCarrier?
    var surface: WorkspaceToolbarButtonSurface? { carrier?.surface }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 36), heightAnchor.constraint(equalToConstant: 36)])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 36) }

    func assign(_ carrier: WorkspaceRightPanelButtonCarrier) { self.carrier = carrier }
    func park() {
        guard let carrier else { return }
        if carrier.superview !== self {
            carrier.removeFromSuperview()
            addSubview(carrier)
        }
        carrier.frame = bounds
        carrier.autoresizingMask = [.width, .height]
    }
    override func layout() {
        super.layout()
        // Во время движения носитель находится в общем слое, и layout слота его не переставляет.
        if carrier?.superview === self { carrier?.frame = bounds }
    }
}

/// Промежуточный носитель позволяет двигать настоящую кнопку, не вмешиваясь в её Auto Layout.
@MainActor
final class WorkspaceRightPanelButtonCarrier: NSView {
    let surface: WorkspaceToolbarButtonSurface
    init(_ surface: WorkspaceToolbarButtonSurface) {
        self.surface = surface
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        wantsLayer = true
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor), surface.topAnchor.constraint(equalTo: topAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
}

/// Прозрачный слой пропускает клики к остальной шапке; в нём находятся только две настоящие кнопки.
private final class RightPanelButtonCanvas: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// На время перестройки toolbar кнопки покидают слоты, сохраняя значки, target/action и доступность.
@MainActor
final class WorkspaceRightPanelButtonMotion {
    let outerSlot: WorkspaceRightPanelSlot
    let trailingSlot: WorkspaceRightPanelSlot
    let assistant: WorkspaceRightPanelButtonCarrier
    let calendar: WorkspaceRightPanelButtonCarrier
    private let canvas = RightPanelButtonCanvas()
    private var timer: Timer?
    private var paths: [RightPanel: RightPanelButtonPath] = [:]
    private var startedAt: CFTimeInterval = 0
    private var duration = PlannerMotion.Kind.panel.duration
    private var generation = 0
    private var pending = false
    private(set) var moving = false
    private var roles = RightPanelToolbarRoles(active: nil)
    private var open = false

    init(outer: WorkspaceRightPanelSlot, trailing: WorkspaceRightPanelSlot,
         assistant: WorkspaceToolbarButtonSurface, calendar: WorkspaceToolbarButtonSurface) {
        outerSlot = outer; trailingSlot = trailing
        self.assistant = WorkspaceRightPanelButtonCarrier(assistant)
        self.calendar = WorkspaceRightPanelButtonCarrier(calendar)
        canvas.autoresizingMask = [.width, .height]
        assignSlots(); park()
    }

    private func carrier(_ panel: RightPanel) -> WorkspaceRightPanelButtonCarrier { panel == .assistant ? assistant : calendar }
    private func slot(_ panel: RightPanel) -> WorkspaceRightPanelSlot { roles.outer == panel ? outerSlot : trailingSlot }
    private func assignSlots() { outerSlot.assign(carrier(roles.outer)); trailingSlot.assign(carrier(roles.trailing)) }

    func update(active: RightPanel?, animate: Bool) {
        let next = RightPanelToolbarRoles(active: active)
        let changed = next != roles || open != (active != nil)
        guard changed else { return }
        generation += 1
        timer?.invalidate(); timer = nil
        let canAnimate = animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && prepareCanvas()
        roles = next; open = active != nil
        assignSlots()
        guard canAnimate else { park(); return }
        // Начало фиксируется до изменения геометрии NSSplitView, в одном проходе с открытием панели.
        startedAt = CACurrentMediaTime(); duration = PlannerMotion.Kind.panel.duration
        moving = true; pending = true
        let current = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, current == self.generation, self.moving else { return }
            self.canvas.window?.contentView?.layoutSubtreeIfNeeded()
            // Нативная шапка, особенно полноэкранная, получает конечные размеры после своего layout.
            DispatchQueue.main.async { [weak self] in
                guard let self, current == self.generation, self.moving else { return }
                self.beginFrames()
            }
        }
    }

    private func prepareCanvas() -> Bool {
        guard let window = outerSlot.window, trailingSlot.window === window,
              !outerSlot.isHiddenOrHasHiddenAncestor, !trailingSlot.isHiddenOrHasHiddenAncestor,
              !outerSlot.bounds.isEmpty, !trailingSlot.bounds.isEmpty,
              window.inLiveResize == false else { return false }
        var ancestor: NSView? = outerSlot.superview
        while let view = ancestor, !trailingSlot.isDescendant(of: view) { ancestor = view.superview }
        guard var parent = ancestor else { return false }
        // Группы NSToolbar пересоздаются при вставке границы, особенно в узком окне.
        // Общий слой принадлежит постоянному корню окна, а не временной группе двух кнопок.
        while let outer = parent.superview { parent = outer }
        if moving, canvas.window !== window { return false }
        var screenFrames: [RightPanel: CGRect] = [:]
        for panel in [RightPanel.assistant, .calendar] {
            let view = carrier(panel)
            guard let owner = view.window else { return false }
            screenFrames[panel] = owner.convertToScreen(view.convert(view.bounds, to: nil))
        }
        if canvas.superview !== parent {
            // При смене секций сохраняем экранные координаты, не паркуя кнопки в старых слотах.
            canvas.removeFromSuperview(); canvas.frame = parent.bounds
            parent.addSubview(canvas, positioned: .above, relativeTo: nil)
        }
        for panel in [RightPanel.assistant, .calendar] {
            let view = carrier(panel)
            guard let screenFrame = screenFrames[panel] else { continue }
            if view.superview !== canvas { view.removeFromSuperview(); canvas.addSubview(view) }
            view.autoresizingMask = []
            view.frame = canvas.convert(window.convertFromScreen(screenFrame), from: nil)
        }
        return true
    }

    private func beginFrames() {
        guard outerSlot.window != nil, trailingSlot.window === canvas.window else { park(); return }
        pending = false
        for panel in [RightPanel.assistant, .calendar] {
            let target = slot(panel).convert(slot(panel).bounds, to: canvas)
            paths[panel] = RightPanelButtonPath(start: carrier(panel).frame, end: target)
        }
        // Учитываем уже прошедший layout, сохраняя общий момент завершения движения панели и кнопок.
        // Поздний layout не сокращает видимое движение до одного кадра.
        duration = max(PlannerMotion.Kind.feedback.duration, PlannerMotion.Kind.panel.duration - (CACurrentMediaTime() - startedAt))
        startedAt = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            // Таймер зарегистрирован только в главном RunLoop; сам Timer не передаётся между акторами.
            MainActor.assumeIsolated { self.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    private func tick() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let window = canvas.window, outerSlot.window === window, trailingSlot.window === window,
              !window.inLiveResize else { cancel(); return }
        let fraction = min(1, max(0, (CACurrentMediaTime() - startedAt) / duration))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for panel in [RightPanel.assistant, .calendar] {
            guard let path = paths[panel] else { continue }
            // Якорь сам движется с NSSplitView. Убираем только исходное смещение кнопки
            // относительно него, вместо полёта к устаревшей координате начала раскрытия.
            let target = slot(panel).convert(slot(panel).bounds, to: canvas)
            let interpolated = path.frame(at: fraction)
            carrier(panel).frame = CGRect(x: target.minX + interpolated.minX - path.end.minX,
                y: target.minY + interpolated.minY - path.end.minY,
                width: target.width, height: target.height)
        }
        CATransaction.commit()
        if fraction >= 1 { park() }
    }

    func layoutChanged() {
        if moving {
            if outerSlot.window !== canvas.window || outerSlot.window?.inLiveResize == true { cancel() }
            return
        }
        if !pending { park() }
    }

    func cancel() {
        generation += 1
        park()
    }

    private func park() {
        timer?.invalidate(); timer = nil
        moving = false; pending = false; paths.removeAll()
        assignSlots()
        outerSlot.park(); trailingSlot.park()
        carrier(roles.outer).surface.presentation = .circle
        carrier(roles.trailing).surface.presentation = open ? .sidebar : .circle
        canvas.removeFromSuperview()
    }
}
