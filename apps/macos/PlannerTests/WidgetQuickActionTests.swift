import Foundation
import Testing
@testable import Planner

struct WidgetQuickActionTests {
    @Test func actionURLsMatchTheRegisteredAppScheme() throws {
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.map { $0.lowercased() }
        for action in WidgetQuickAction.allCases {
            let url = try #require(action.url)
            #expect(schemes.contains(url.scheme ?? ""))
            #expect(WidgetQuickAction(url: url) == action)
        }
        #expect(WidgetQuickAction.routes.count == 2)
    }

    @Test func unrelatedURLsAndUnrecognizedActionsAreIgnored() throws {
        let note = try #require(WidgetQuickAction.newNote.url)
        let extras = try #require(URL(string: note.absoluteString + "?title=Injected"))
        let unknown = try #require(URL(string: note.absoluteString.replacingOccurrences(of: "new-note", with: "unknown")))
        let foreign = try #require(URL(string: "https://widget/new-note"))
        #expect(WidgetQuickAction(url: extras) == nil)
        #expect(WidgetQuickAction(url: unknown) == nil)
        #expect(WidgetQuickAction(url: foreign) == nil)
    }
}
