import Foundation

struct TodayWidgetSnapshot: Codable, Equatable {
    static let kind = "TaktToday"
    static let rowLimit = 5

    struct Row: Codable, Equatable, Identifiable {
        struct Deadline: Codable, Equatable {
            let date: Date
            let includesTime: Bool
            let timeZoneID: String
        }

        let id: UUID
        let title: String
        let deadline: Deadline?
    }

    let count: Int
    let rows: [Row]

    static let empty = Self(count: 0, rows: [])

    static var fileURL: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "TaktWidgetAppGroup") as? String,
              !group.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("TodayWidget-v1.json")
    }

    static func read(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    @discardableResult
    func write(to url: URL) throws -> Bool {
        guard (try? Self.read(from: url)) != self else { return false }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        return true
    }
}
