import AppKit
import Observation

/// Только состояние текущего жеста: идентификаторы и папка, без сохранения в библиотеку.
@MainActor @Observable
final class TaskDragState {
    struct Context: Equatable {
        let token = UUID()
        let payload: TaskDragPayload
        let sourceFolder: TaskFilter
        let sourceViewID: UUID
    }
    enum Feedback: Equatable { case none, destination, sameFolder }

    private(set) var context: Context?
    @ObservationIgnored private let monitorInput: Bool
    @ObservationIgnored private var inputMonitor: Any?
    @ObservationIgnored private var releaseTimer: Timer?

    init(monitorInput: Bool = true) { self.monitorInput = monitorInput }

    func begin(payload: TaskDragPayload, sourceFolder: TaskFilter, sourceViewID: UUID) {
        finish()
        let context = Context(payload: payload, sourceFolder: sourceFolder, sourceViewID: sourceViewID)
        withImmediateNavigationUpdate { self.context = context }
        if monitorInput { observeEnd(token: context.token) }
    }

    func feedback(for folder: TaskFilter) -> Feedback {
        guard let context, folder.acceptsTaskDrop else { return .none }
        if folder.isPrimaryFolder, folder == context.sourceFolder { return .sameFolder }
        return .destination
    }

    func finish(token: UUID? = nil, sourceViewID: UUID? = nil) {
        if let token, context?.token != token { return }
        if let sourceViewID, context?.sourceViewID != sourceViewID { return }
        releaseTimer?.invalidate()
        releaseTimer = nil
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        withImmediateNavigationUpdate { context = nil }
    }

    func mouseButtonsChanged(_ buttons: Int, token: UUID) {
        if buttons & 1 == 0 { finish(token: token) }
    }

    private func observeEnd(token: UUID) {
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .leftMouseDown || (event.type == .keyDown && event.keyCode == 53) {
                    // Новый клик означает конец прежнего жеста, даже если отпускание произошло вне приложения.
                    self?.finish(token: token)
                } else if event.type == .leftMouseUp {
                    // Сначала AppKit доставляет drop; завершение не должно опережать обработчик назначения.
                    DispatchQueue.main.async { [weak self] in self?.finish(token: token) }
                }
            }
            return event
        }
        // Во время нативного drag отпускание вне приложения не всегда попадает в локальный монитор.
        // Опрос действует только на время жеста, не запрашивает разрешений и работает в tracking mode.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseButtonsChanged(NSEvent.pressedMouseButtons, token: token) }
        }
        releaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
