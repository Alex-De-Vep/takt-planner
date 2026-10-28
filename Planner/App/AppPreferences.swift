import SwiftUI
import Observation
import PlannerLocalization

/// Настройки интерфейса храним отдельно от библиотеки задач.
@MainActor @Observable
final class AppPreferences {
    private let defaults: UserDefaults
    var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: "appLanguage") }
    }
    var rightPanel: RightPanel? { didSet { defaults.set(rightPanel?.rawValue, forKey: "rightPanel") } }
    var calendarOpen: Bool {
        get { rightPanel == .calendar }
        set { if newValue { rightPanel = .calendar } else if rightPanel == .calendar { rightPanel = nil } }
    }
    var assistantWidth: Double { didSet { defaults.set(assistantWidth, forKey: "assistantWidth") } }
    var assistantDefaultFolder: String { didSet { defaults.set(assistantDefaultFolder, forKey: "assistantDefaultFolder") } }
    var assistantUseCurrentFolder: Bool { didSet { defaults.set(assistantUseCurrentFolder, forKey: "assistantUseCurrentFolder") } }
    var assistantDuration: Int { didSet { defaults.set(assistantDuration, forKey: "assistantDuration") } }
    var assistantReminder: Int { didSet { defaults.set(assistantReminder, forKey: "assistantReminder") } }
    var calendarWidth: Double { didSet { defaults.set(calendarWidth, forKey: "calendarWidth") } }
    var calendarAgendaMode: CalendarAgendaMode { didSet { defaults.set(calendarAgendaMode.rawValue, forKey: "calendarAgendaMode") } }
    var calendarAgendaLayout: CalendarAgendaLayout { didSet { defaults.set(calendarAgendaLayout.rawValue, forKey: "calendarAgendaLayout") } }
    // nil означает все календари, в том числе добавленные в системе позднее.
    var visibleCalendarIDs: Set<String>? { didSet { defaults.set(visibleCalendarIDs.map(Array.init), forKey: "visibleCalendarIDs") } }
    var creationCalendarID: String? { didSet { defaults.set(creationCalendarID, forKey: "creationCalendarID") } }

    var deadlineNotificationsEnabled: Bool { didSet { defaults.set(deadlineNotificationsEnabled, forKey: "deadlineNotificationsEnabled") } }
    var dateOnlyNotificationMinutes: Int { didSet { defaults.set(dateOnlyNotificationMinutes, forKey: "dateOnlyNotificationMinutes") } }
    var reviewNotificationsEnabled: Bool { didSet { defaults.set(reviewNotificationsEnabled, forKey: "reviewNotificationsEnabled") } }
    var reviewNotificationMinutes: Int { didSet { defaults.set(reviewNotificationMinutes, forKey: "reviewNotificationMinutes") } }
    var reviewWeekdaysOnly: Bool { didSet { defaults.set(reviewWeekdaysOnly, forKey: "reviewWeekdaysOnly") } }

    var notificationSchedule: NotificationSchedule {
        NotificationSchedule(deadlinesEnabled: deadlineNotificationsEnabled, dateOnlyMinutes: dateOnlyNotificationMinutes,
                             reviewEnabled: reviewNotificationsEnabled, reviewMinutes: reviewNotificationMinutes,
                             reviewWeekdaysOnly: reviewWeekdaysOnly)
    }

    init(defaults suppliedDefaults: UserDefaults? = nil) {
        // UI-тесты используют отдельные настройки и не меняют язык пользователя.
        #if SHOWCASE
        defaults = suppliedDefaults ?? ShowcaseData.makePreferences()
        #elseif DEBUG
        if let suppliedDefaults { defaults = suppliedDefaults }
        else if let testID = ProcessInfo.processInfo.environment["PLANNER_UI_TEST_LIBRARY"], UUID(uuidString: testID) != nil {
            defaults = UserDefaults(suiteName: "local.planner.tests.\(testID)")!
        } else { defaults = .standard }
        #else
        defaults = suppliedDefaults ?? .standard
        #endif
        deadlineNotificationsEnabled = defaults.object(forKey: "deadlineNotificationsEnabled") as? Bool ?? true
        dateOnlyNotificationMinutes = min(1439, max(0, defaults.object(forKey: "dateOnlyNotificationMinutes") as? Int ?? 540))
        reviewNotificationsEnabled = defaults.bool(forKey: "reviewNotificationsEnabled")
        reviewNotificationMinutes = min(1439, max(0, defaults.object(forKey: "reviewNotificationMinutes") as? Int ?? 540))
        reviewWeekdaysOnly = defaults.bool(forKey: "reviewWeekdaysOnly")
        language = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .russian
        rightPanel = defaults.string(forKey: "rightPanel").flatMap(RightPanel.init(rawValue:))
        assistantWidth = min(520, max(360, defaults.object(forKey: "assistantWidth") as? Double ?? 420))
        assistantDefaultFolder = defaults.string(forKey: "assistantDefaultFolder") ?? "inbox"
        assistantUseCurrentFolder = defaults.object(forKey: "assistantUseCurrentFolder") as? Bool ?? true
        assistantDuration = min(1440, max(5, defaults.object(forKey: "assistantDuration") as? Int ?? 60))
        assistantReminder = defaults.object(forKey: "assistantReminder") as? Int ?? -1
        let width = defaults.double(forKey: "calendarWidth")
        calendarWidth = Double(width == 0 ? CalendarPanelLayout.defaultWidth : CalendarPanelLayout.panelWidth(CGFloat(width)))
        calendarAgendaMode = CalendarAgendaMode(rawValue: defaults.string(forKey: "calendarAgendaMode") ?? "") ?? .day
        calendarAgendaLayout = CalendarAgendaLayout(rawValue: defaults.string(forKey: "calendarAgendaLayout") ?? "") ?? .vertical
        visibleCalendarIDs = defaults.stringArray(forKey: "visibleCalendarIDs").map(Set.init)
        creationCalendarID = defaults.string(forKey: "creationCalendarID")
    }

    var translations: Translations { Translations(language: language) }
}

private struct TranslationsKey: EnvironmentKey {
    static let defaultValue = Translations(language: .russian)
}

extension EnvironmentValues {
    /// Передаём переводы вниз по дереву SwiftUI, чтобы все колонки меняли язык одновременно.
    var translations: Translations {
        get { self[TranslationsKey.self] }
        set { self[TranslationsKey.self] = newValue }
    }
}
