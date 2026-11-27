import Foundation
import Observation

struct FolderLabel: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let folderID: UUID
    var name: String
    var rgb: UInt32
}

enum FolderLabelTarget: Codable, Hashable, Sendable {
    case task(UUID)
    case note(UUID)
}

struct FolderLabelArchive: Codable, Equatable, Sendable {
    var labels: [UUID: FolderLabel] = [:]
    var assignments: [FolderLabelTarget: Set<UUID>] = [:]

    func keepingAssignments(for targets: Set<FolderLabelTarget>) -> Self {
        var copy = self
        copy.assignments = assignments.filter { targets.contains($0.key) }
        return copy
    }
}

enum FolderLabelError: LocalizedError {
    case emptyName, duplicateName, invalidColor, unavailable, unreadable

    var errorDescription: String? {
        switch self {
        case .emptyName: "Введите название ярлыка."
        case .duplicateName: "В этой папке уже есть ярлык с таким названием."
        case .invalidColor: "Выберите цвет ярлыка."
        case .unavailable: "Этот ярлык недоступен в текущей папке."
        case .unreadable: "Не удалось открыть локальные ярлыки."
        }
    }
}

@MainActor @Observable
final class FolderLabelStore {
    private(set) var archive = FolderLabelArchive()
    private(set) var unreadable = false
    private let url: URL?

    init(url: URL? = nil) {
        self.url = url
        guard let url else { return }
        do {
            archive = try JSONDecoder().decode(FolderLabelArchive.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A library starts without a labels file.
        } catch {
            unreadable = true
        }
    }

    func label(_ id: UUID?) -> FolderLabel? {
        id.flatMap { archive.labels[$0] }
    }

    func labels(in folderID: UUID) -> [FolderLabel] {
        sorted(archive.labels.values.filter { $0.folderID == folderID })
    }

    func labels(for target: FolderLabelTarget) -> [FolderLabel] {
        resolved(archive.assignments[target] ?? [])
    }

    func labels(for targets: [FolderLabelTarget], includingFrom folderID: UUID? = nil) -> [FolderLabel] {
        var ids = Set<UUID>()
        if let folderID {
            ids.formUnion(archive.labels.values.lazy.filter { $0.folderID == folderID }.map(\.id))
        }
        for target in targets { ids.formUnion(archive.assignments[target] ?? []) }
        return resolved(ids)
    }

    func targets(with labelID: UUID) -> Set<FolderLabelTarget> {
        Set(archive.assignments.compactMap { target, labels in labels.contains(labelID) ? target : nil })
    }

    func contains(_ labelID: UUID, on target: FolderLabelTarget) -> Bool {
        archive.assignments[target]?.contains(labelID) == true
    }

    func save(name: String, rgb: UInt32, in folderID: UUID, editing id: UUID? = nil,
              assigningTo target: FolderLabelTarget? = nil) throws {
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !title.isEmpty else { throw FolderLabelError.emptyName }
        guard rgb <= 0xFF_FF_FF else { throw FolderLabelError.invalidColor }
        if let id, archive.labels[id]?.folderID != folderID { throw FolderLabelError.unavailable }
        guard !archive.labels.values.contains(where: {
            $0.folderID == folderID && $0.id != id && $0.name.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { throw FolderLabelError.duplicateName }
        let label = FolderLabel(id: id ?? UUID(), folderID: folderID, name: title, rgb: rgb)
        var next = archive
        next.labels[label.id] = label
        if let target { next.assignments[target, default: []].insert(label.id) }
        try restore(next)
    }

    func toggle(_ labelID: UUID, on target: FolderLabelTarget, currentFolderID: UUID?) throws {
        guard let label = archive.labels[labelID] else { throw FolderLabelError.unavailable }
        var next = archive
        var assignments = next.assignments[target] ?? []
        if assignments.remove(labelID) == nil {
            guard label.folderID == currentFolderID else { throw FolderLabelError.unavailable }
            assignments.insert(labelID)
        }
        next.assignments[target] = assignments.isEmpty ? nil : assignments
        try restore(next)
    }

    func delete(_ labelID: UUID) throws {
        var next = archive
        next.labels.removeValue(forKey: labelID)
        for target in next.assignments.keys {
            next.assignments[target]?.remove(labelID)
            if next.assignments[target]?.isEmpty == true { next.assignments.removeValue(forKey: target) }
        }
        try restore(next)
    }

    func restore(_ next: FolderLabelArchive) throws {
        guard !unreadable else { throw FolderLabelError.unreadable }
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
        }
        archive = next
    }

    private func resolved(_ ids: Set<UUID>) -> [FolderLabel] {
        sorted(ids.compactMap { archive.labels[$0] })
    }

    private func sorted(_ labels: [FolderLabel]) -> [FolderLabel] {
        labels.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : order == .orderedAscending
        }
    }
}
