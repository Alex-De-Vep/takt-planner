import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let plannerTask = UTType(exportedAs: "local.planner.task", conformingTo: .data)
}

/// Передаём только идентификаторы, без содержимого задачи и ссылок на изменяемую модель.
struct TaskDragPayload: Codable, Equatable, Sendable {
    let taskID: UUID
    let scopeID: UUID

    func taskID(in scopeID: UUID) -> UUID? { self.scopeID == scopeID ? taskID : nil }

    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plannerTask.identifier,
                                            visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func decode(_ data: Data) -> Self? {
        guard data.count <= 1024 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// Обычная папка принимает перенос, «Сегодня» добавляет отметку, «Все задачи» не является назначением.
struct TaskFolderDropDelegate: DropDelegate {
    let destination: TaskFilter
    @Binding var targeted: Bool
    let receive: (TaskDragPayload, TaskFilter) -> Void
    let taskDrag: TaskDragState

    func validateDrop(info: DropInfo) -> Bool {
        destination.acceptsTaskDrop && info.hasItemsConforming(to: [.plannerTask])
    }
    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { withImmediateNavigationUpdate { targeted = true } }
    }
    func dropExited(info: DropInfo) { withImmediateNavigationUpdate { targeted = false } }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: !destination.acceptsTaskDrop ? .forbidden : destination == .today ? .copy : .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        withImmediateNavigationUpdate { targeted = false }
        guard validateDrop(info: info), let provider = info.itemProviders(for: [.plannerTask]).first else { return false }
        if let token = taskDrag.context?.token {
            // Жест источника завершается раньше снятия блокировки выбора его строки.
            DispatchQueue.main.async { taskDrag.finish(token: token) }
        }
        // Загрузку запускаем в обработчике drop; сам результат получаем позже на главном акторе.
        provider.loadDataRepresentation(forTypeIdentifier: UTType.plannerTask.identifier) { data, _ in
            guard let data, let payload = TaskDragPayload.decode(data) else { return }
            Task { @MainActor in receive(payload, destination) }
        }
        return true
    }
}
