import Foundation

enum WidgetQuickAction: String, CaseIterable {
    case newNote = "new-note"
    case newEvent = "new-event"

    var kind: String {
        switch self {
        case .newNote: "TaktCreateNote"
        case .newEvent: "TaktCreateEvent"
        }
    }

    private static let scheme = (Bundle.main.object(forInfoDictionaryKey: "TaktWidgetURLScheme") as? String)?.lowercased()

    var url: URL? {
        guard let scheme = Self.scheme else { return nil }
        return URL(string: "\(scheme)://widget/\(rawValue)")
    }

    static var routes: Set<String> {
        Set(allCases.compactMap { $0.url?.absoluteString })
    }

    init?(url: URL) {
        guard let action = Self.allCases.first(where: { $0.url?.absoluteString == url.absoluteString }) else { return nil }
        self = action
    }
}
