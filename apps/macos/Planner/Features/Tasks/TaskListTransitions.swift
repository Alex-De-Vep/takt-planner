import AppKit
import QuartzCore

/// List в AppKit может применить новый набор строк сразу, даже внутри withAnimation.
/// Анимируем только отображение готовой геометрии; данными и выделением по-прежнему владеет List.
@MainActor
final class TaskListTransitions {
    private struct Row {
        let frame: CGRect
        let image: CGImage?
        let opacity: Float
    }
    private struct Change {
        let previous: [UUID: Row]
        let ids: [UUID]
    }
    private weak var table: NSTableView?
    private var ids: [UUID] = []
    private var scope: AnyHashable?
    private var settled: [UUID: Row] = [:]
    private var pending: Change?
    private var scheduled = false
    private var boundsObserver: NSObjectProtocol?
    private var ghosts: [CALayer] = []
    private var cover: CALayer?

    static func prepare(in host: NSView) {
        var prepared = Set<ObjectIdentifier>()
        func visit(_ view: NSView) {
            if let probe = view as? TaskRowSelectionSync.Probe, let transitions = probe.nativeFocus?.transitions,
               prepared.insert(ObjectIdentifier(transitions)).inserted { transitions.prepare() }
            for child in view.subviews { visit(child) }
        }
        visit(host)
    }

    private func prepare() {
        guard cover == nil, let table, !table.visibleRect.isEmpty else { return }
        // Удерживаем прежний кадр до завершения нативного diff: конечная геометрия не мелькает перед переходом.
        settled = capture(visibleRows(), images: true, presentation: true)
        let cover = CALayer()
        cover.frame = table.bounds
        table.effectiveAppearance.performAsCurrentDrawingAppearance {
            cover.backgroundColor = PlannerStyle.workspaceBackground.cgColor
        }
        cover.zPosition = 100
        // Кадр составляем из текущих presentation-положений: повторный клик не прыгает в конец прошлого движения.
        for previous in settled.values {
            guard let image = previous.image else { continue }
            let layer = CALayer()
            layer.frame = previous.frame
            layer.contents = image
            layer.opacity = previous.opacity
            layer.contentsScale = table.window?.backingScaleFactor ?? 2
            cover.addSublayer(layer)
        }
        table.wantsLayer = true
        table.layer?.addSublayer(cover)
        self.cover = cover
    }

    func attach(_ table: NSTableView) {
        if self.table !== table {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            self.table = table
            let clip = table.enclosingScrollView?.contentView
            clip?.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
        }
        schedule()
    }

    func update(ids: [UUID], scope: AnyHashable, animated: Bool) {
        if !animated { pending = nil; removeAnimations() }
        if self.ids != ids || self.scope != scope {
            pending = animated && self.scope == scope ? Change(previous: settled, ids: ids) : nil
            if pending == nil { removeAnimations() }
            self.ids = ids
            self.scope = scope
        }
        schedule()
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        // Сначала List заканчивает diff и раскладывает нативные строки, затем добавляем переход.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.reconcile()
        }
    }

    private func visibleRows() -> [UUID: NSTableRowView] {
        guard let table else { return [:] }
        var result: [UUID: NSTableRowView] = [:]
        func taskID(in view: NSView) -> UUID? {
            if let probe = view as? TaskRowSelectionSync.Probe { return probe.taskID }
            for child in view.subviews { if let id = taskID(in: child) { return id } }
            return nil
        }
        let range = table.rows(in: table.visibleRect)
        guard range.location != NSNotFound else { return [:] }
        for index in range.location..<min(table.numberOfRows, NSMaxRange(range)) {
            if let row = table.rowView(atRow: index, makeIfNecessary: false), let id = taskID(in: row) {
                result[id] = row
            }
        }
        return result
    }

    private func reconcile() {
        guard let table, table.window != nil else { return }
        table.layoutSubtreeIfNeeded()
        let rows = visibleRows()
        // Во время diff могут ещё встречаться уходящие представления. Их не принимаем за новый набор.
        guard Set(rows.keys).isSubset(of: Set(ids)) else { return }
        if let change = pending {
            pending = nil
            animate(change, rows: rows, table: table)
        }
        // Пока List ещё показывает прежние строки, сохраняем предыдущий снимок.
        guard rows.count > 0 || ids.isEmpty else { return }
        settled = capture(rows)
        cover?.removeFromSuperlayer()
        cover = nil
    }

    private func capture(_ rows: [UUID: NSTableRowView], images: Bool = false, presentation: Bool = false) -> [UUID: Row] {
        rows.mapValues { row in
            let image: CGImage?
            if images, let bitmap = row.bitmapImageRepForCachingDisplay(in: row.bounds) {
                row.cacheDisplay(in: row.bounds, to: bitmap)
                image = bitmap.cgImage
            } else { image = nil }
            let current = presentation ? row.layer?.presentation() : nil
            return Row(frame: current?.frame ?? row.frame, image: image, opacity: current?.opacity ?? 1)
        }
    }

    private func animate(_ change: Change, rows: [UUID: NSTableRowView], table: NSTableView) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { removeAnimations(); return }
        // У первой строки нет соседей для сдвига. Она сразу видна с правильным выделением;
        // отложенное появление уже показанной строки давало бы ещё одно мерцание.
        guard !change.previous.isEmpty else { return }
        let duration = PlannerMotion.Kind.listChange.duration
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        let removal = change.previous.keys.contains { !change.ids.contains($0) }
        let pause = removal ? duration * 0.25 : 0
        let movement = duration * 0.75
        let start = CACurrentMediaTime()
        table.wantsLayer = true
        for (id, row) in rows {
            row.wantsLayer = true
            guard let layer = row.layer else { continue }
            if let previous = change.previous[id] {
                let delta = previous.frame.minY - row.frame.minY
                if abs(delta) > 0.5 {
                    let motion = CABasicAnimation(keyPath: "transform.translation.y")
                    motion.fromValue = delta
                    motion.toValue = 0
                    motion.duration = movement
                    motion.beginTime = start + pause
                    motion.fillMode = .backwards
                    motion.timingFunction = timing
                    layer.add(motion, forKey: "planner.row.position")
                }
            } else {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.beginTime = start + movement
                fade.fillMode = .backwards
                fade.duration = duration - movement
                fade.timingFunction = timing
                layer.add(fade, forKey: "planner.row.appearance")
            }
        }
        // Удалённая модель уже недоступна. Короткое исчезновение рисуется её последним растровым кадром.
        for (id, previous) in change.previous where !change.ids.contains(id) {
            guard let image = previous.image else { continue }
            let ghost = CALayer()
            ghost.frame = previous.frame
            ghost.contents = image
            ghost.contentsScale = table.window?.backingScaleFactor ?? 2
            ghost.zPosition = 10
            ghost.opacity = 0
            table.layer?.addSublayer(ghost)
            ghosts.append(ghost)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = previous.opacity
            fade.toValue = 0
            fade.duration = duration * 0.25
            fade.timingFunction = timing
            ghost.add(fade, forKey: "planner.row.removal")
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak ghost] in
                ghost?.removeFromSuperlayer()
                self?.ghosts.removeAll { $0 === ghost }
            }
        }
    }

    private func removeAnimations() {
        for row in visibleRows().values {
            row.layer?.removeAnimation(forKey: "planner.row.position")
            row.layer?.removeAnimation(forKey: "planner.row.appearance")
        }
        cover?.removeFromSuperlayer()
        cover = nil
        ghosts.forEach { $0.removeFromSuperlayer() }
        ghosts.removeAll()
    }

    func detach() {
        pending = nil
        removeAnimations()
        settled.removeAll()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        table = nil
    }
}
