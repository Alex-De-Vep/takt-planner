import Foundation
import SwiftData

/// Сохраняем прежние сущности и добавляем состояние обмена в ту же базу.
enum PlannerSchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(6, 0, 0) }
    static var models: [any PersistentModel.Type] {
        PlannerSchemaV5.models + [SyncCheckpoint.self, SyncReplica.self, SyncQueueItem.self]
    }

    @Model final class SyncCheckpoint {
        var libraryID: String
        var cursor: String?
        var physicalMillis: Int64 = 0
        var logicalCounter: Int = 0
        var sequence: Int64 = 0

        init(libraryID: String) { self.libraryID = libraryID }
    }

    @Model final class SyncReplica {
        @Attribute(.unique) var entityID: String
        var payload: Data

        init(entityID: String, payload: Data) {
            self.entityID = entityID
            self.payload = payload
        }
    }

    @Model final class SyncQueueItem {
        @Attribute(.unique) var operationID: String
        var entityID: String
        var sequence: Int64
        var payload: Data
        var failure: String?

        init(operationID: String, entityID: String, sequence: Int64, payload: Data) {
            self.operationID = operationID
            self.entityID = entityID
            self.sequence = sequence
            self.payload = payload
        }
    }
}
