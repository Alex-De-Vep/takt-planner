import AppKit
import SwiftUI

/// Передаёт реальный фокус нативному списку, не меняя выбранную строку.
@MainActor
final class TaskListNativeFocus {
    weak var table: NSTableView?
    let transitions = TaskListTransitions()

    /// Создание открывает редактор. Пустой список не должен успеть показать первую строку
    /// как клавиатурно активную до присоединения NSTextView к окну.
    static func prepareForTaskCreation(in window: NSWindow?) -> NSTableView? {
        guard let window, let table = window.firstResponder as? NSTableView,
              window.makeFirstResponder(nil) else { return nil }
        return table
    }

    @discardableResult func takeFocus() -> Bool {
        guard let table, let window = table.window else { return false }
        return window.makeFirstResponder(table)
    }
}

/// Открытая задача остаётся выбранной и при уходе клавиатурного фокуса из списка.
/// Восстанавливаем штатный выбор NSTableView, а не рисуем независимую подсветку строки.
struct TaskRowSelectionSync: NSViewRepresentable {
    let taskID: UUID
    @Binding var selectedID: UUID?
    let revision: Int
    var isEligible: () -> Bool = { true }
    var nativeFocus: TaskListNativeFocus? = nil

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.taskID = taskID
        view.selectedID = $selectedID
        view.isEligible = isEligible
        view.nativeFocus = nativeFocus
        view.scheduleReconciliation()
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: NSView {
        var taskID: UUID?
        var selectedID: Binding<UUID?> = .constant(nil)
        var isEligible: () -> Bool = { true }
        var nativeFocus: TaskListNativeFocus?
        private weak var table: NSTableView?
        private var observer: NSObjectProtocol?
        private var generation = 0
        private var isDetached = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleReconciliation() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleReconciliation() }

        func scheduleReconciliation() {
            guard !isDetached else { return }
            generation += 1
            let generation = self.generation
            // Даём завершиться текущему клику и обновлению SwiftUI: выбор другой задачи имеет приоритет.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.reconcileSelection()
            }
        }

        func reconcileSelection() {
            guard !isDetached, window != nil else { stopObserving(); return }
            var ancestor = superview
            while let candidate = ancestor, !(candidate is NSTableView) { ancestor = candidate.superview }
            guard let current = ancestor as? NSTableView else { stopObserving(); return }
            nativeFocus?.table = current
            nativeFocus?.transitions.attach(current)
            observe(current)
            // После удаления открытой карточки AppKit может временно выделить соседнюю строку.
            // Пустой выбор приложения имеет приоритет и должен быть пустым также в нативном списке.
            if selectedID.wrappedValue == nil {
                if !current.selectedRowIndexes.isEmpty { current.deselectAll(nil) }
                return
            }
            guard let taskID, selectedID.wrappedValue == taskID, isEligible() else { return }
            let index = current.row(for: self)
            guard index >= 0, index < current.numberOfRows else { return }
            let expected = IndexSet(integer: index)
            if current.selectedRowIndexes != expected {
                current.selectRowIndexes(expected, byExtendingSelection: false)
            }
            // Сохраняем нативное оформление фокуса: при вводе строка остаётся серой, а не исчезает.
            if let row = current.rowView(atRow: index, makeIfNecessary: false) {
                row.isSelected = true
                row.needsDisplay = true
            }
        }

        private func observe(_ current: NSTableView) {
            guard table !== current else { return }
            stopObserving()
            table = current
            observer = NotificationCenter.default.addObserver(forName: NSTableView.selectionDidChangeNotification,
                                                               object: current, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReconciliation() }
            }
        }

        private func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            table = nil
        }

        func detach() {
            isDetached = true
            generation += 1
            stopObserving()
            selectedID = .constant(nil)
            isEligible = { false }
            nativeFocus = nil
        }
    }
}
