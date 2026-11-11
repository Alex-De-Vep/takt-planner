import AppKit

/// Сквозное выделение рисуется отдельно от редактируемого диапазона каждого поля.
@MainActor
final class TaskTextSelection {
    private struct Fragment: Equatable {
        let editor: TaskTextView
        let range: NSRange
    }

    private static let dragEvents: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
    private static let modifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
    private static let scrollInterval: TimeInterval = 0.05
    private weak var owner: TaskTextView?
    private var fragments: [Fragment] = []

    func trackDrag(from source: TaskTextView, event: NSEvent, store: TaskEditorStore) -> Bool {
        guard event.clickCount == 1, event.modifierFlags.intersection(Self.modifiers).isEmpty,
              !source.hasMarkedText(), let window = source.window, window.firstResponder === source else { return false }

        let anchor = source.insertionIndex(at: event.locationInWindow)
        // Перетаскивание уже выделенного в поле текста остаётся системным.
        guard !NSLocationInRange(anchor, source.selectedRange()) else { return false }
        let editors = store.attachedEditors(for: source, in: window)
            .sorted { $0.frameInWindow.midY > $1.frameInWindow.midY }
        guard editors.count > 1, let sourceIndex = editors.firstIndex(of: source),
              // Обычный клик обрабатывает NSTextView вместе с оставленным в очереди mouseUp.
              window.nextEvent(matching: Self.dragEvents, until: .distantFuture, inMode: .eventTracking, dequeue: false)?.type == .leftMouseDragged else { return false }

        var lastEvent: NSEvent?
        var lastScroll: TimeInterval = 0
        window.trackEvents(matching: Self.dragEvents, timeout: Self.scrollInterval, mode: .eventTracking) { nextEvent, stop in
            guard window.firstResponder === source, editors.allSatisfy({ $0.window === window }) else {
                self.clear()
                stop.pointee = true
                return
            }
            if let nextEvent { lastEvent = nextEvent }
            guard let lastEvent else { return }
            let dragging = lastEvent.type == .leftMouseDragged
            let now = ProcessInfo.processInfo.systemUptime
            if dragging, now - lastScroll >= Self.scrollInterval {
                self.scroll(at: lastEvent.locationInWindow, in: source.enclosingScrollView)
                lastScroll = now
            }
            self.update(editors: editors, sourceIndex: sourceIndex, anchor: anchor,
                        point: lastEvent.locationInWindow, dragging: dragging)
            stop.pointee = ObjCBool(!dragging)
        }
        return true
    }

    private func scroll(at point: NSPoint, in scrollView: NSScrollView?) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        let cursor = clip.convert(point, from: nil)
        let bounds = clip.bounds
        guard cursor.x >= bounds.minX, cursor.x <= bounds.maxX else { return }
        let edge: CGFloat = 24
        let distance = min(cursor.y - bounds.minY, bounds.maxY - cursor.y)
        guard distance < edge else { return }
        let speed = min(edge, edge - distance)
        let offset = cursor.y < bounds.midY ? -speed : speed
        let origin = clip.constrainBoundsRect(bounds.offsetBy(dx: 0, dy: offset)).origin
        guard origin != bounds.origin else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func update(editors: [TaskTextView], sourceIndex: Int, anchor: Int, point: NSPoint, dragging: Bool) {
        let targetIndex = editors.lastIndex { $0.frameInWindow.maxY >= point.y } ?? 0
        let source = editors[sourceIndex]
        let target = editors[targetIndex]
        let end = target.insertionIndex(at: point)
        let start = min(anchor, source.textLength)
        if targetIndex == sourceIndex {
            let range = NSRange(location: min(start, end), length: abs(end - start))
            source.setSelectedRange(range, affinity: end < start ? .upstream : .downstream, stillSelecting: dragging)
            return
        }

        if owner !== source {
            source.setSelectedRange(NSRange(location: start, length: 0), affinity: .downstream, stillSelecting: false)
        }
        let forward = sourceIndex < targetIndex
        let first = min(sourceIndex, targetIndex)
        let last = max(sourceIndex, targetIndex)
        let selected = (first...last).compactMap { index -> Fragment? in
            let editor = editors[index]
            let lower = index == first ? (forward ? start : end) : 0
            let upper = index == last ? (forward ? end : start) : editor.textLength
            guard upper > lower else { return nil }
            return Fragment(editor: editor, range: NSRange(location: lower, length: upper - lower))
        }
        guard owner !== source || fragments != selected else { return }
        clear()
        guard !selected.isEmpty else { return }
        owner = source
        fragments = selected
        for fragment in fragments {
            fragment.editor.layoutManager?.addTemporaryAttributes([
                .backgroundColor: NSColor.selectedTextBackgroundColor,
                .foregroundColor: NSColor.selectedTextColor
            ], forCharacterRange: fragment.range)
        }
    }

    func canCopy(from editor: TaskTextView) -> Bool { owner === editor }

    func text(for editor: TaskTextView) -> String? {
        guard canCopy(from: editor),
              fragments.allSatisfy({ NSMaxRange($0.range) <= $0.editor.textLength }) else { return nil }
        return fragments.map { ($0.editor.string as NSString).substring(with: $0.range) }.joined(separator: "\n")
    }

    func clear(including editor: TaskTextView) {
        if owner === editor || fragments.contains(where: { $0.editor === editor }) { clear() }
    }

    private func clear() {
        for fragment in fragments {
            let layout = fragment.editor.layoutManager
            let range = NSIntersectionRange(fragment.range, NSRange(location: 0, length: fragment.editor.textLength))
            guard range.length > 0 else { continue }
            layout?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            layout?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        }
        fragments = []
        owner = nil
    }
}

private extension TaskTextView {
    var textLength: Int { (string as NSString).length }
    var frameInWindow: NSRect { convert(bounds, to: nil) }

    func insertionIndex(at point: NSPoint) -> Int {
        let local = convert(point, from: nil)
        if local.y < bounds.minY { return 0 }
        if local.y >= bounds.maxY { return textLength }
        return min(characterIndexForInsertion(at: local), textLength)
    }
}
