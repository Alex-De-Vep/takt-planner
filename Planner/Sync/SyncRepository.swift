import Foundation
import SwiftData

private typealias Checkpoint = PlannerSchemaV6.SyncCheckpoint
private typealias Replica = PlannerSchemaV6.SyncReplica
private typealias QueueItem = PlannerSchemaV6.SyncQueueItem

/// Проекция для API не содержит локальных календарных связей и настроек.
@MainActor
struct SyncLocalEntity {
    let id: String
    let kind: SyncEntityKind
    let fields: [String: SyncValue]

    init?(_ model: any PersistentModel) {
        switch model {
        case let folder as TaskFolder:
            id = folder.id.syncID
            kind = .folder
            fields = ["name": .text(folder.name), "sortOrder": .integer(Int64(folder.sortOrder))]
        case let task as PlannerTask:
            id = task.id.syncID
            kind = .task
            let placement: SyncValue
            if let folder = task.folder {
                placement = .object(["kind": .text("folder"), "folderId": .text(folder.id.syncID)])
            } else {
                placement = .object(["kind": .text(task.systemFolderKind)])
            }
            let deadline: SyncValue
            if let value = task.deadline {
                var properties: [String: SyncValue] = [
                    "includesTime": .bool(value.includesTime), "timeZoneId": .text(value.timeZoneID)
                ]
                if value.includesTime {
                    properties["instant"] = .text(SyncWire.date(value.date))
                } else {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(identifier: value.timeZoneID) ?? .gmt
                    properties["date"] = .text(LocalDay.key(for: value.date, calendar: calendar))
                }
                deadline = .object(properties)
            } else { deadline = .null }
            let planning: SyncValue
            if let value = task.planningKind, let anchor = task.planningAnchor {
                planning = .object(["kind": .text(value), "anchor": .text(SyncWire.date(anchor))])
            } else { planning = .null }
            fields = [
                "title": .text(task.title), "description": .text(task.descriptionText),
                "createdAt": .text(SyncWire.date(task.createdAt)),
                "completedAt": .optional(task.completedAt.map(SyncWire.date)), "focusDay": .optional(task.focusDay),
                "placement": placement, "deadline": deadline, "planning": planning
            ]
        case let item as TaskChecklistItem:
            guard let task = item.task else { return nil }
            id = item.id.syncID
            kind = .checklistItem
            fields = [
                "taskId": .text(task.id.syncID), "title": .text(item.title),
                "isCompleted": .bool(item.isCompleted), "sortOrder": .integer(Int64(item.sortOrder))
            ]
        default: return nil
        }
    }
}

@MainActor
final class SyncRepository {
    let context: ModelContext
    let libraryID: String
    let deviceID: String
    private let checkpoint: Checkpoint
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    var serverClockOffset: TimeInterval = 0
    var didApplyTasks: ((Set<UUID>) -> Void)?

    init(context: ModelContext, libraryID: String, deviceID: String) throws {
        self.context = context
        self.libraryID = libraryID
        self.deviceID = deviceID
        context.autosaveEnabled = false
        if let existing = try context.fetch(FetchDescriptor<Checkpoint>()).first {
            guard existing.libraryID == libraryID else { throw SyncProblem.accountMismatch }
            checkpoint = existing
        } else {
            let row = Checkpoint(libraryID: libraryID)
            context.insert(row)
            try context.save()
            checkpoint = row
        }
    }

    var cursor: String? { checkpoint.cursor }

    func counts() throws -> (pending: Int, failed: Int) {
        let rows = try queue()
        return (rows.count, rows.filter { $0.failure != nil }.count)
    }

    func pendingOperations() throws -> [SyncMutation] {
        try queue().filter { $0.failure == nil }.map { try mutation($0) }
    }

    private func queue() throws -> [QueueItem] {
        try context.fetch(FetchDescriptor<QueueItem>(sortBy: [SortDescriptor(\.sequence)]))
    }

    private func mutation(_ row: QueueItem) throws -> SyncMutation {
        try decoder.decode(SyncMutation.self, from: row.payload)
    }

    private func replica(_ id: String) throws -> Replica? {
        try context.fetch(FetchDescriptor<Replica>(predicate: #Predicate { $0.entityID == id })).first
    }

    private func authoritative(_ id: String) throws -> SyncEntity? {
        guard let row = try replica(id) else { return nil }
        return try decoder.decode(SyncEntity.self, from: row.payload)
    }

    private func project(id: String, kind: SyncEntityKind, pending: [SyncMutation]) throws -> SyncEntity {
        var result = try authoritative(id) ?? SyncEntity(id: id, type: kind, fields: [:], versions: [:], deleted: false, revision: "0")
        for edit in pending where edit.entityId == id && !result.deleted {
            if edit.kind == .delete { result.deleted = true; continue }
            for (key, change) in edit.changes ?? [:] {
                if let version = result.versions[key], version >= change.version { continue }
                result.fields[key] = change.value
                result.versions[key] = change.version
            }
        }
        if let folder = result.fields["placement"]?.fields?["folderId"]?.string,
           pending.contains(where: { $0.entityId == folder && $0.kind == .delete }) {
            result.fields["placement"] = .object(["kind": .text("inbox")])
        }
        return result
    }

    /// Вызывается перед тем же save(), который фиксирует пользовательскую правку.
    func captureLocalChanges() throws -> Bool {
        context.processPendingChanges()
        let deleted = context.deletedModelsArray
        let candidates = context.insertedModelsArray + context.changedModelsArray
        var deletedIDs = Set<String>()
        var didQueue = false
        var pending = try queue().map { try mutation($0) }
        for model in deleted {
            let identity: (String, SyncEntityKind)?
            switch model {
            case let task as PlannerTask: identity = (task.id.syncID, .task)
            case let folder as TaskFolder: identity = (folder.id.syncID, .folder)
            case let item as TaskChecklistItem: identity = (item.id.syncID, .checklistItem)
            default: identity = nil
            }
            guard let (id, kind) = identity, deletedIDs.insert(id).inserted else { continue }
            let edit = makeMutation(id: id, type: kind, kind: .delete, fields: [:])
            try enqueue(edit)
            pending.append(edit)
            didQueue = true
        }

        var captured = Set<String>()
        let localEntities = candidates.compactMap(SyncLocalEntity.init).sorted { $0.kind.order < $1.kind.order }
        for local in localEntities where !deletedIDs.contains(local.id) && captured.insert(local.id).inserted {
            let previous = try project(id: local.id, kind: local.kind, pending: pending)
            if previous.deleted { continue }
            let kind: SyncMutation.Kind = previous.fields.isEmpty ? .create : .update
            let fields = local.fields.filter { key, value in
                kind == .create || (key != "createdAt" && key != "taskId" && previous.fields[key] != value)
            }
            guard !fields.isEmpty else { continue }
            let edit = makeMutation(id: local.id, type: local.kind, kind: kind, fields: fields)
            try enqueue(edit)
            pending.append(edit)
            didQueue = true
        }
        return didQueue
    }

    private func enqueue(_ edit: SyncMutation) throws {
        checkpoint.sequence += 1
        context.insert(QueueItem(operationID: edit.operationId, entityID: edit.entityId,
                                 sequence: checkpoint.sequence, payload: try encoder.encode(edit)))
    }

    private func makeMutation(id: String, type: SyncEntityKind, kind: SyncMutation.Kind,
                              fields: [String: SyncValue]) -> SyncMutation {
        let operation = UUID().syncID
        let now = Int64(Date().addingTimeInterval(serverClockOffset).timeIntervalSince1970 * 1000)
        if now > checkpoint.physicalMillis {
            checkpoint.physicalMillis = now
            checkpoint.logicalCounter = 0
        } else {
            checkpoint.logicalCounter += 1
        }
        let stamp = SyncStamp(physicalMillis: checkpoint.physicalMillis, logicalCounter: checkpoint.logicalCounter,
                              deviceId: deviceID, operationId: operation)
        return SyncMutation(operationId: operation, libraryId: libraryID, deviceId: deviceID, entityId: id,
                            entityType: type, kind: kind, changes: kind == .delete ? nil : fields.mapValues {
                                SyncField(value: $0, version: stamp)
                            }, deleteVersion: kind == .delete ? stamp : nil)
    }

    /// Создаём операции импорта один раз. Состояние этапа сохраняется отдельно от активной библиотеки.
    func importOperations(from source: ModelContext) throws -> [SyncMutation] {
        defer { context.rollback() }
        return try Self.localEntities(source).map {
            makeMutation(id: $0.id, type: $0.kind, kind: .create, fields: $0.fields)
        }
    }

    static func localEntities(_ source: ModelContext) throws -> [SyncLocalEntity] {
        let folders = try source.fetch(FetchDescriptor<TaskFolder>()).compactMap { SyncLocalEntity($0) }
        let tasks = try source.fetch(FetchDescriptor<PlannerTask>()).compactMap { SyncLocalEntity($0) }
        let items = try source.fetch(FetchDescriptor<TaskChecklistItem>()).compactMap { SyncLocalEntity($0) }
        return folders + tasks + items
    }

    /// Объединяем списки по UUID. Существующие задачи и удалённые записи аккаунта имеют приоритет.
    func mergeLocal(from source: ModelContext) throws {
        var available = Set(try Self.localEntities(context).map(\.id))
        var known = available.union(try context.fetch(FetchDescriptor<Replica>()).map(\.entityID))
        known.formUnion(try queue().map(\.entityID))
        do {
            for local in try Self.localEntities(source) where known.insert(local.id).inserted {
                var fields = local.fields
                if let parent = fields["taskId"]?.string, !available.contains(parent) { continue }
                if let folder = fields["placement"]?.fields?["folderId"]?.string, !available.contains(folder) {
                    fields["placement"] = .object(["kind": .text("inbox")])
                }
                let edit = makeMutation(id: local.id, type: local.kind, kind: .create, fields: fields)
                try enqueue(edit)
                let entity = SyncEntity(id: local.id, type: local.kind, fields: fields,
                                        versions: edit.changes?.mapValues(\.version) ?? [:], deleted: false, revision: "0")
                _ = try materialize(entity)
                available.insert(local.id)
            }
            var knownLinks = Set(try context.fetch(FetchDescriptor<TaskEventLink>()).map(\.id))
            for link in try source.fetch(FetchDescriptor<TaskEventLink>()) where knownLinks.insert(link.id).inserted {
                guard let id = link.task?.id, let target = try task(id), !target.isDeleted else { continue }
                let event = CalendarEvent(identifier: link.eventIdentifier, externalIdentifier: link.externalIdentifier,
                                          calendarID: "", title: link.lastTitle, start: link.lastStart, end: link.lastStart)
                let copy = TaskEventLink(task: target, event: event)
                copy.id = link.id
                context.insert(copy)
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func accept(_ response: SyncMutationResults, sent: [SyncMutation]) throws {
        let ids = response.results.compactMap(\.operationId)
        guard ids.count == sent.count, Set(ids) == Set(sent.map(\.operationId)) else {
            throw SyncProblem.invalidResponse
        }
        let rows = try queue()
        var received: [SyncEntity] = []
        do {
            for result in response.results {
                guard let id = result.operationId, let row = rows.first(where: { $0.operationID == id }) else {
                    throw SyncProblem.invalidResponse
                }
                switch result.status {
                case .applied, .deleted:
                    guard let entity = result.entity, entity.id == row.entityID else { throw SyncProblem.invalidResponse }
                    received.append(entity)
                    context.delete(row)
                case .rejected:
                    // Непринятые правки остаются на диске и видны в статусе обмена.
                    row.failure = result.error?.code ?? "rejected"
                }
            }
            try apply(received, cursor: nil)
        } catch {
            context.rollback()
            throw error
        }
    }

    func applyChanges(_ page: SyncChanges) throws {
        guard page.libraryId == libraryID, let next = Int64(page.nextCursor), let previous = cursor.flatMap(Int64.init),
              next >= previous, !page.hasMore || next > previous,
              page.changes.allSatisfy({ $0.entity.revision == $0.revision && (Int64($0.revision) ?? -1) > previous && (Int64($0.revision) ?? -1) <= next }) else {
            throw SyncProblem.invalidResponse
        }
        try apply(page.changes.map(\.entity), cursor: page.nextCursor)
    }

    func applySnapshot(_ snapshot: SyncSnapshot) throws {
        guard snapshot.protocolVersion == 1, snapshot.libraryId == libraryID, snapshot.initialized,
              let revision = Int64(snapshot.cursor), revision >= 0,
              snapshot.entities.allSatisfy({ (Int64($0.revision) ?? -1) >= 0 && (Int64($0.revision) ?? -1) <= revision }) else {
            throw SyncProblem.invalidResponse
        }
        do {
            let pending = Set(try queue().map(\.entityID))
            let live = Set(snapshot.entities.filter { !$0.deleted }.map(\.id))
            let models: [any PersistentModel] = try context.fetch(FetchDescriptor<TaskFolder>()).map { $0 as any PersistentModel }
                + context.fetch(FetchDescriptor<PlannerTask>()).map { $0 as any PersistentModel }
                + context.fetch(FetchDescriptor<TaskChecklistItem>()).map { $0 as any PersistentModel }
            let obsolete = models.compactMap { model -> (any PersistentModel, SyncLocalEntity)? in
                guard let value = SyncLocalEntity(model), !live.contains(value.id), !pending.contains(value.id) else { return nil }
                return (model, value)
            }
            let removedTasks = Set(obsolete.compactMap { $0.1.kind == .task ? UUID(uuidString: $0.1.id) : nil })
            for (model, _) in obsolete { context.delete(model) }
            let incomingIDs = Set(snapshot.entities.map(\.id))
            for row in try context.fetch(FetchDescriptor<Replica>()) where !incomingIDs.contains(row.entityID) {
                context.delete(row)
            }
            context.processPendingChanges()
            let ordered = snapshot.entities.sorted { $0.type.order < $1.type.order }
            try apply(ordered, cursor: snapshot.cursor, removedTasks: removedTasks, rebase: true)
        } catch {
            context.rollback()
            throw error
        }
    }

    private func apply(_ incoming: [SyncEntity], cursor: String?, removedTasks: Set<UUID> = [], rebase: Bool = false) throws {
        do {
            var changedTasks = removedTasks
            context.processPendingChanges()
            let rows = try queue().filter { !$0.isDeleted }.map { (row: $0, edit: try mutation($0)) }
            for entity in incoming {
                guard UUID(uuidString: entity.id)?.syncID == entity.id, let revision = Int64(entity.revision), revision >= 0 else {
                    throw SyncProblem.invalidResponse
                }
                let old = try replica(entity.id)
                if let old, !old.isDeleted {
                    let stored = try decoder.decode(SyncEntity.self, from: old.payload)
                    if rebase || (Int64(stored.revision) ?? -1) < revision { old.payload = try encoder.encode(entity) }
                } else {
                    context.insert(Replica(entityID: entity.id, payload: try encoder.encode(entity)))
                }
                for stamp in entity.versions.values { observe(stamp) }
                if let remote = try authoritative(entity.id) {
                    for item in rows where item.row.entityID == entity.id && !item.row.isDeleted {
                        if remote.deleted || (item.edit.kind == .create && item.edit.entityType == remote.type) {
                            context.delete(item.row)
                        }
                    }
                }
                let pending = rows.filter { !$0.row.isDeleted }.map(\.edit)
                let projection = try project(id: entity.id, kind: entity.type, pending: pending)
                if let id = try materialize(projection) { changedTasks.insert(id) }
            }
            if let cursor { checkpoint.cursor = cursor }
            try context.save()
            didApplyTasks?(changedTasks)
        } catch {
            context.rollback()
            throw error
        }
    }

    private func observe(_ stamp: SyncStamp) {
        if (stamp.physicalMillis, stamp.logicalCounter) > (checkpoint.physicalMillis, checkpoint.logicalCounter) {
            checkpoint.physicalMillis = stamp.physicalMillis
            checkpoint.logicalCounter = stamp.logicalCounter
        }
    }

    private func materialize(_ entity: SyncEntity) throws -> UUID? {
        guard let id = UUID(uuidString: entity.id) else { throw SyncProblem.invalidResponse }
        let fields = entity.fields
        switch entity.type {
        case .folder:
            let old = try context.fetch(FetchDescriptor<TaskFolder>(predicate: #Predicate { $0.id == id })).first
            if entity.deleted {
                if let old {
                    for task in old.tasks ?? [] { task.folder = nil; task.systemFolderKind = "inbox" }
                    context.delete(old)
                }
                return nil
            }
            guard let name = fields["name"]?.string, let order = fields["sortOrder"]?.number else { throw SyncProblem.invalidResponse }
            let folder = old ?? TaskFolder(name: name, sortOrder: order)
            if old == nil { folder.id = id; context.insert(folder) }
            if folder.name != name { folder.name = name }
            if folder.sortOrder != order { folder.sortOrder = order }
        case .task:
            let old = try task(id)
            if entity.deleted {
                if let old { context.delete(old); return id }
                return nil
            }
            guard let title = fields["title"]?.string, let createdAt = fields["createdAt"]?.string.flatMap(SyncWire.date),
                  let placement = fields["placement"]?.fields, let kind = placement["kind"]?.string else {
                throw SyncProblem.invalidResponse
            }
            let item = old ?? PlannerTask(title: title, now: createdAt)
            if old == nil { item.id = id; context.insert(item) }
            if item.title != title { item.title = title }
            let description = fields["description"]?.string ?? ""
            if item.descriptionText != description { item.descriptionText = description }
            item.createdAt = createdAt
            item.completedAt = fields["completedAt"]?.string.flatMap(SyncWire.date)
            item.focusDay = fields["focusDay"]?.string
            let planning = fields["planning"]?.fields
            item.planningKind = planning?["kind"]?.string
            item.planningAnchor = planning?["anchor"]?.string.flatMap(SyncWire.date)
            item.systemFolderKind = ["inbox", "week", "month"].contains(kind) ? kind : "inbox"
            if kind == "folder", let folder = placement["folderId"]?.string.flatMap(UUID.init(uuidString:)) {
                item.folder = try context.fetch(FetchDescriptor<TaskFolder>(predicate: #Predicate { $0.id == folder })).first
            } else { item.folder = nil }
            let deadline = fields["deadline"]?.fields
            item.deadlineIncludesTime = deadline?["includesTime"]?.flag ?? false
            item.deadlineTimeZoneID = deadline?["timeZoneId"]?.string
            if item.deadlineIncludesTime {
                item.deadlineDate = deadline?["instant"]?.string.flatMap(SyncWire.date)
            } else if let date = deadline?["date"]?.string, let zone = item.deadlineTimeZoneID.flatMap(TimeZone.init(identifier:)) {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = zone
                let parts = date.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 3 else { throw SyncProblem.invalidResponse }
                item.deadlineDate = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
            } else { item.deadlineDate = nil }
            if let edited = entity.versions.values.max() {
                item.updatedAt = Date(timeIntervalSince1970: Double(edited.physicalMillis) / 1000)
            }
            return id
        case .checklistItem:
            let old = try context.fetch(FetchDescriptor<TaskChecklistItem>(predicate: #Predicate { $0.id == id })).first
            if entity.deleted { if let old { context.delete(old) }; return nil }
            guard let parentID = fields["taskId"]?.string.flatMap(UUID.init(uuidString:)),
                  let title = fields["title"]?.string, let order = fields["sortOrder"]?.number else {
                throw SyncProblem.invalidResponse
            }
            // Pending deletion of a parent already removed its local children.
            guard let parent = try task(parentID), !parent.isDeleted else { return nil }
            let item = old ?? TaskChecklistItem(task: parent, title: title, sortOrder: order)
            if old == nil { item.id = id; context.insert(item) }
            if item.title != title { item.title = title }
            item.sortOrder = order
            item.isCompleted = fields["isCompleted"]?.flag ?? false
        case .attachment:
            break
        }
        return nil
    }

    private func task(_ id: UUID) throws -> PlannerTask? {
        try context.fetch(FetchDescriptor<PlannerTask>(predicate: #Predicate { $0.id == id })).first
    }
}
