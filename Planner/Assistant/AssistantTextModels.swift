import Foundation

/// Снимок не зависит от живой SwiftData-модели и остаётся у исходной задачи при переключении окна.
struct AssistantTextSnapshot: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Equatable, Identifiable {
        var id: UUID
        var title: String
        var isCompleted: Bool
    }
    var id: UUID
    var title: String
    var description: String
    var checklist: [Item]
}

/// Модель предлагает только текст. Идентификаторы, сроки и состояния принадлежат приложению.
struct AssistantTextChange: Codable, Sendable, Equatable {
    var title: String?
    var description: String?
    var checklist: [String]?
}

struct AssistantTextEdit: Codable, Identifiable, Equatable {
    enum Target: String, Codable { case savedTask, proposal }
    enum Status: String, Codable { case pending, applying, applied, accepted, cancelled }
    struct Addition: Codable, Identifiable, Equatable {
        var id = UUID()
        var title: String
        var included = true
    }
    var id = UUID()
    var target: Target
    var before: AssistantTextSnapshot
    var change = AssistantTextChange()
    var includeTitle = true
    var includeDescription = true
    var includeChecklist = true
    var additions: [Addition] = []
    var status: Status = .pending
    var error: String?
    var lastRequest: String? = nil
    // Выбранные значения фиксируются до save: восстановление не повторяет добавление пунктов.
    var committed: AssistantTextSnapshot?
    var hasChanges: Bool {
        (change.title != nil && change.title != before.title) ||
        (change.description != nil && change.description != before.description) || !additions.isEmpty || (target == .proposal && change.checklist != nil)
    }
    var hasSelection: Bool {
        (includeTitle && change.title != nil && change.title != before.title) ||
        (includeDescription && change.description != nil && change.description != before.description) || (includeChecklist && checklistChanged)
    }
    var checklistChanged: Bool {
        if target == .proposal { return change.checklist != nil && additions.filter(\.included).map(\.title) != before.checklist.map(\.title) }
        return additions.contains(where: \.included)
    }
    var selected: AssistantTextSnapshot {
        var value = before
        if includeTitle, let title = change.title { value.title = title }
        if includeDescription, let description = change.description { value.description = description }
        if includeChecklist {
            let proposed = additions.filter(\.included).map { AssistantTextSnapshot.Item(id: $0.id, title: $0.title, isCompleted: false) }
            if target == .proposal, change.checklist != nil { value.checklist = proposed }
            else { value.checklist += proposed }
        }
        return value
    }
    mutating func propose(_ proposal: AssistantTextChange) throws {
        guard (proposal.title?.count ?? 0) <= 500, (proposal.description?.count ?? 0) <= 12000,
              (proposal.checklist?.count ?? 0) <= 30,
              proposal.checklist?.allSatisfy({ $0.count <= 500 }) != false else {
            throw AssistantFailure(message: "Предложение слишком большое. Разделите его на несколько запросов.")
        }
        if let title = proposal.title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AssistantFailure(message: "Введите название.")
        }
        change.title = proposal.title ?? change.title
        change.description = proposal.description ?? change.description
        if let checklist = proposal.checklist {
            var seen = Set(target == .savedTask ? before.checklist.map { Self.normalized($0.title) } : [])
            additions = checklist.compactMap { title in
                let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, seen.insert(Self.normalized(title)).inserted else { return nil }
                // При уточнении сохраняем UUID и пользовательский выбор неизменившихся пунктов.
                return additions.first { Self.normalized($0.title) == Self.normalized(title) } ?? Addition(title: title)
            }
            change.checklist = additions.map(\.title)
        }
        error = nil
    }
    static func normalized(_ value: String) -> String {
        value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static let conflict = "Задача изменилась после подготовки предложения. Обновите предложение по текущему тексту."
}
