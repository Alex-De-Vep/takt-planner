import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let plannerTask = UTType(exportedAs: "local.planner.task", conformingTo: .data)
    static let plannerNote = UTType(exportedAs: "local.planner.note", conformingTo: .data)
}

/// Передаём ссылку внутри текущей библиотеки, без текста и вложений.
struct FolderDragPayload: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case task, note

        var type: UTType { self == .task ? .plannerTask : .plannerNote }

        func accepts(_ destination: TaskFilter) -> Bool {
            self == .task ? destination.acceptsTaskDrop : destination.acceptsNotes
        }
    }

    let kind: Kind
    let itemID: UUID
    let scopeID: UUID

    func itemID(in scopeID: UUID) -> UUID? { self.scopeID == scopeID ? itemID : nil }

    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: kind.type.identifier, visibility: .ownProcess) { completion in
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

/// У строки папки одна зарегистрированная цель. Правила назначения зависят от типа элемента.
struct FolderDropDelegate: DropDelegate {
    let destination: TaskFilter
    let scopeID: UUID
    let drag: FolderDragState
    let setTargeted: (Bool) -> Void
    let receive: (FolderDragPayload, TaskFilter) -> Void

    private func acceptedKind(_ info: DropInfo) -> FolderDragPayload.Kind? {
        if let payload = drag.context?.payload {
            guard payload.scopeID == scopeID, payload.kind.accepts(destination),
                  info.hasItemsConforming(to: [payload.kind.type]) else { return nil }
            return payload.kind
        }
        // Состояние мыши может сброситься первым. После загрузки снова проверяем библиотеку и тип.
        return FolderDragPayload.Kind.allCases.first {
            $0.accepts(destination) && info.hasItemsConforming(to: [$0.type])
        }
    }

    func validateDrop(info: DropInfo) -> Bool { acceptedKind(info) != nil }

    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { withImmediateNavigationUpdate { setTargeted(true) } }
    }

    func dropExited(info: DropInfo) {
        withImmediateNavigationUpdate { setTargeted(false) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let kind = acceptedKind(info) else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: kind == .task && destination == .today ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        withImmediateNavigationUpdate { setTargeted(false) }
        guard let kind = acceptedKind(info),
              let provider = info.itemProviders(for: [kind.type]).first else { return false }
        if let token = drag.context?.token {
            DispatchQueue.main.async { drag.finish(token: token) }
        }
        provider.loadDataRepresentation(forTypeIdentifier: kind.type.identifier) { data, _ in
            guard let data, let payload = FolderDragPayload.decode(data), payload.kind == kind,
                  payload.scopeID == scopeID else { return }
            Task { @MainActor in receive(payload, destination) }
        }
        return true
    }
}
