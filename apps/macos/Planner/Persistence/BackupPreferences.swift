import Foundation
import PlannerLocalization

/// Explicit allowlist. Account state, secrets, and system permissions stay on this Mac.
struct BackupPreferences: Codable, Sendable {
    let language: String
    let rightPanel: String?
    let calendarWidth: Double
    let calendarAgendaMode: String
    let calendarAgendaLayout: String
    let visibleCalendarIDs: Set<String>?
    let creationCalendarID: String?
    let assistantWidth: Double
    let assistantDefaultFolder: String
    let assistantUseCurrentFolder: Bool
    let assistantDuration: Int
    let assistantReminder: Int
    let deadlinesEnabled: Bool
    let dateOnlyMinutes: Int
    let reviewEnabled: Bool
    let reviewMinutes: Int
    let reviewWeekdaysOnly: Bool

    @MainActor init(_ preferences: AppPreferences) {
        language = preferences.language.rawValue
        rightPanel = preferences.rightPanel?.rawValue
        calendarWidth = preferences.calendarWidth
        calendarAgendaMode = preferences.calendarAgendaMode.rawValue
        calendarAgendaLayout = preferences.calendarAgendaLayout.rawValue
        visibleCalendarIDs = preferences.visibleCalendarIDs
        creationCalendarID = preferences.creationCalendarID
        assistantWidth = preferences.assistantWidth
        assistantDefaultFolder = preferences.assistantDefaultFolder
        assistantUseCurrentFolder = preferences.assistantUseCurrentFolder
        assistantDuration = preferences.assistantDuration
        assistantReminder = preferences.assistantReminder
        deadlinesEnabled = preferences.deadlineNotificationsEnabled
        dateOnlyMinutes = preferences.dateOnlyNotificationMinutes
        reviewEnabled = preferences.reviewNotificationsEnabled
        reviewMinutes = preferences.reviewNotificationMinutes
        reviewWeekdaysOnly = preferences.reviewWeekdaysOnly
    }

    @MainActor func apply(to preferences: AppPreferences) {
        preferences.language = AppLanguage(rawValue: language) ?? .system
        preferences.rightPanel = rightPanel.flatMap(RightPanel.init(rawValue:))
        preferences.calendarWidth = Double(CalendarPanelLayout.panelWidth(CGFloat(calendarWidth)))
        preferences.calendarAgendaMode = CalendarAgendaMode(rawValue: calendarAgendaMode) ?? .day
        preferences.calendarAgendaLayout = CalendarAgendaLayout(rawValue: calendarAgendaLayout) ?? .vertical
        preferences.visibleCalendarIDs = visibleCalendarIDs
        preferences.creationCalendarID = creationCalendarID
        preferences.assistantWidth = min(520, max(360, assistantWidth))
        preferences.assistantDefaultFolder = assistantDefaultFolder
        preferences.assistantUseCurrentFolder = assistantUseCurrentFolder
        preferences.assistantDuration = min(1440, max(5, assistantDuration))
        preferences.assistantReminder = assistantReminder
        preferences.deadlineNotificationsEnabled = deadlinesEnabled
        preferences.dateOnlyNotificationMinutes = min(1439, max(0, dateOnlyMinutes))
        preferences.reviewNotificationsEnabled = reviewEnabled
        preferences.reviewNotificationMinutes = min(1439, max(0, reviewMinutes))
        preferences.reviewWeekdaysOnly = reviewWeekdaysOnly
    }
}
