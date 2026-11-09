import Foundation
import Testing
@testable import PlannerLocalization

/// Проверяем полноту словарей, форматирование чисел и явный выбор языка независимо от macOS.
struct TranslationsTests {
    @Test func languageSelectionDoesNotDependOnSystemLanguage() {
        #expect(Translations(language: .russian)["Входящие"] == "Входящие")
        #expect(Translations(language: .english)["Входящие"] == "Inbox")
        #expect(Translations(language: .english)["Настройки"] == "Settings")
    }

    @Test func countersUseTheSelectedLanguage() {
        #expect(Translations(language: .english).format("Задач: %d", 12) == "Tasks: 12")
        #expect(Translations(language: .russian).format("Задач: %d", 12) == "Задач: 12")
    }

    @Test func helpGuidesLoadInBothInterfaceLanguages() throws {
        let russian = try #require(Translations(language: .russian).helpGuide)
        let english = try #require(Translations(language: .english).helpGuide)
        #expect(russian.contains("\n## Быстрый старт\n"))
        #expect(english.contains("\n## Getting started\n"))
        #expect(russian.components(separatedBy: "\n## ").count == english.components(separatedBy: "\n## ").count)
    }

    @Test func missingKeyFallsBackToReadableSourceText() {
        #expect(Translations(language: .english)["Будущая строка"] == "Будущая строка")
    }

    @Test func resourceKeysAndFormatSpecifiersMatch() throws {
        func dictionary(_ code: String) throws -> [String: String] {
            let url = try #require(Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: code))
            let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            return try #require(value as? [String: String])
        }
        let russian = try dictionary("ru")
        let english = try dictionary("en")
        #expect(!russian.isEmpty)
        #expect(Set(russian.keys) == Set(english.keys))
        for (key, value) in russian {
            let translated = try #require(english[key])
            #expect(!translated.isEmpty)
            #expect(value.components(separatedBy: "%d").count == translated.components(separatedBy: "%d").count)
        }
    }
}
