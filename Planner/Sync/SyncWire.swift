import Foundation

enum SyncValue: Codable, Equatable, Sendable {
    case null, bool(Bool), integer(Int64), text(String), object([String: SyncValue])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result = try? value.decode(Bool.self) { self = .bool(result) }
        else if let result = try? value.decode(Int64.self) { self = .integer(result) }
        else if let result = try? value.decode(String.self) { self = .text(result) }
        else { self = .object(try value.decode([String: SyncValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .integer(let item): try value.encode(item)
        case .text(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }

    var string: String? { if case .text(let value) = self { value } else { nil } }
    var number: Int? { if case .integer(let value) = self { Int(exactly: value) } else { nil } }
    var flag: Bool? { if case .bool(let value) = self { value } else { nil } }
    var fields: [String: SyncValue]? { if case .object(let value) = self { value } else { nil } }
    static func optional(_ value: String?) -> Self { value.map(Self.text) ?? .null }
}

enum SyncEntityKind: String, Codable, Sendable {
    case folder, task, checklistItem, attachment
    var order: Int {
        switch self { case .folder: 0; case .task: 1; case .checklistItem: 2; case .attachment: 3 }
    }
}

struct SyncStamp: Codable, Comparable, Sendable {
    let physicalMillis: Int64
    let logicalCounter: Int
    let deviceId: String
    let operationId: String
    static func < (a: Self, b: Self) -> Bool {
        (a.physicalMillis, a.logicalCounter, a.deviceId, a.operationId)
            < (b.physicalMillis, b.logicalCounter, b.deviceId, b.operationId)
    }
}

struct SyncField: Codable, Sendable {
    let value: SyncValue
    let version: SyncStamp
}

struct SyncMutation: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case create, update, delete }
    let operationId: String
    let libraryId: String
    let deviceId: String
    let entityId: String
    let entityType: SyncEntityKind
    let kind: Kind
    let changes: [String: SyncField]?
    let deleteVersion: SyncStamp?
}

struct SyncEntity: Codable, Sendable {
    let id: String
    let type: SyncEntityKind
    var fields: [String: SyncValue]
    var versions: [String: SyncStamp]
    var deleted: Bool
    var revision: String
    var fileReady: Bool? = nil
}

struct SyncSnapshot: Codable, Sendable {
    let protocolVersion: Int
    let libraryId: String
    let cursor: String
    let initialized: Bool
    let entities: [SyncEntity]
}

struct SyncChanges: Codable, Sendable {
    struct Change: Codable, Sendable { let revision: String; let entity: SyncEntity }
    let libraryId: String
    let changes: [Change]
    let nextCursor: String
    let hasMore: Bool
}

struct SyncAPIError: Codable, LocalizedError, Sendable {
    let code: String
    let message: String
    let requestId: String?
    let retryAfterSeconds: Int?
    var errorDescription: String? { message }
}

struct SyncMutationResults: Codable, Sendable {
    struct Result: Codable, Sendable {
        enum Status: String, Codable, Sendable { case applied, deleted, rejected }
        let operationId: String?
        let status: Status
        let entity: SyncEntity?
        let error: SyncAPIError?
    }
    let results: [Result]
}

struct SyncConfig: Codable, Sendable {
    struct Limits: Codable, Sendable { let maxBatchOperations: Int; let maxRequestBytes: Int }
    let protocolVersion: Int
    let serverTime: String
    let limits: Limits
}

struct SyncAccount: Codable, Equatable, Sendable {
    let id: String
    let email: String
    let libraryId: String
}

struct SyncLibrary: Codable, Sendable {
    let id: String
    let initialized: Bool
    let revision: String
}

enum SyncProblem: LocalizedError {
    case invalidResponse, incompatibleProtocol, signInRequired, oversizedMutation, accountMismatch
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Сервер вернул неожиданные данные."
        case .incompatibleProtocol: "Эта версия приложения несовместима с сервером."
        case .signInRequired: "Войдите в аккаунт повторно."
        case .oversizedMutation: "Правка превышает допустимый размер запроса."
        case .accountMismatch: "Ответ относится к другой библиотеке."
        }
    }
}

enum SyncWire {
    static func date(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    static func date(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    static func batches(_ operations: [SyncMutation], limits: SyncConfig.Limits) throws -> [[SyncMutation]] {
        let encoder = JSONEncoder()
        let wrapperBytes = #"{"mutations":[]}"#.utf8.count
        let maxOperations = min(limits.maxBatchOperations, 100)
        let maxBytes = min(limits.maxRequestBytes, 4 * 1024 * 1024)
        guard maxOperations > 0, maxBytes > wrapperBytes else { throw SyncProblem.invalidResponse }
        var result: [[SyncMutation]] = []
        var batch: [SyncMutation] = []
        var size = wrapperBytes
        for operation in operations {
            let count = try encoder.encode(operation).count
            guard count + wrapperBytes <= maxBytes else { throw SyncProblem.oversizedMutation }
            if batch.count == maxOperations || size + count + (batch.isEmpty ? 0 : 1) > maxBytes {
                result.append(batch)
                batch = []
                size = wrapperBytes
            }
            size += count + (batch.isEmpty ? 0 : 1)
            batch.append(operation)
        }
        if !batch.isEmpty { result.append(batch) }
        return result
    }
}

extension UUID {
    var syncID: String { uuidString.lowercased() }
}
