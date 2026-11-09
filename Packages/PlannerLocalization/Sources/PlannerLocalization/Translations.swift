import Foundation

/// Поддерживаемые языки. Значения сохраняются в настройках и не зависят от перевода названий.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, russian = "ru", english = "en"
    public var id: String { rawValue }

    public var resolvedCode: String {
        switch self {
        case .system: Bundle.preferredLocalizations(from: ["ru", "en"]).first ?? "ru"
        case .russian, .english: rawValue
        }
    }

    public var locale: Locale { Locale(identifier: resolvedCode == "ru" ? "ru_RU" : "en_US") }
}

/// Неизменяемый набор переводов. Смена экземпляра обновляет интерфейс без перезапуска.
public struct Translations: Sendable {
    public let language: AppLanguage
    public init(language: AppLanguage) { self.language = language }

    public subscript(key: String) -> String {
        // Выбираем языковой bundle явно: системный язык приложения менять не требуется.
        guard let path = Bundle.module.path(forResource: language.resolvedCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    public func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: self[key], locale: language.locale, arguments: arguments)
    }

    public var helpGuide: String? {
        guard let url = Bundle.module.url(forResource: "Help", withExtension: "md",
                                         subdirectory: nil, localization: language.resolvedCode) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
