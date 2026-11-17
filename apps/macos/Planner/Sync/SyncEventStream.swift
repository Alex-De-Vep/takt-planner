enum SyncStreamEvent: String, Sendable {
    case ready
    case notesChanged = "notes.changed"
    case tasksChanged = "tasks.changed"
}

struct SyncStreamParser {
    private var line: [UInt8] = []
    private var event: SyncStreamEvent?
    private var hasData = false

    mutating func append(_ byte: UInt8) throws -> SyncStreamEvent? {
        guard byte == 10 else {
            guard line.count < 1024 else { throw SyncProblem.invalidResponse }
            line.append(byte)
            return nil
        }

        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            defer {
                event = nil
                hasData = false
            }
            return hasData ? event : nil
        }

        let field = String(decoding: line, as: UTF8.self).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        switch field.first {
        case "event" where field.count == 2:
            let value = field[1]
            event = SyncStreamEvent(rawValue: String(value.first == " " ? value.dropFirst() : value))
        case "data":
            hasData = true
        default:
            break
        }
        return nil
    }
}
