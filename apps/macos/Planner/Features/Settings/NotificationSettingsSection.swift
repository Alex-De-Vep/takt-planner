import SwiftUI

struct NotificationSettingsSection: View {
    @Environment(\.translations) private var strings
    @Bindable var preferences: AppPreferences
    @Bindable var notifications: PlannerNotifications
    @State private var testing = false

    var body: some View {
        Section {
            Toggle(strings["Уведомлять о сроках задач"], isOn: $preferences.deadlineNotificationsEnabled)
                .accessibilityIdentifier("deadline-notifications-toggle")
            if preferences.deadlineNotificationsEnabled {
                DatePicker(strings["Для сроков без времени"], selection: time($preferences.dateOnlyNotificationMinutes), displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("date-only-notification-time")
            }
            Toggle(strings["Напоминать проверить задачи"], isOn: $preferences.reviewNotificationsEnabled)
                .accessibilityIdentifier("review-notifications-toggle")
            if preferences.reviewNotificationsEnabled {
                DatePicker(strings["Время напоминания"], selection: time($preferences.reviewNotificationMinutes), displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("review-notification-time")
                Toggle(strings["Только по будням"], isOn: $preferences.reviewWeekdaysOnly)
                    .accessibilityIdentifier("review-weekdays-toggle")
            }
            if notifications.permission == .denied {
                Text(strings["Уведомления запрещены в macOS. Разрешите их для приложения «Задачи» в системных настройках."])
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if notifications.permission == .notDetermined {
                Button(strings["Разрешить уведомления"]) { notifications.synchronize(requestPermission: true) }
                    .accessibilityIdentifier("allow-notifications-button")
            }
            HStack {
                Button(strings["Открыть настройки уведомлений"]) { notifications.openSystemSettings() }
                Spacer()
                Button(strings["Проверить уведомление"]) {
                    testing = true
                    Task { await notifications.sendTest(); testing = false }
                }.disabled(testing)
                .accessibilityIdentifier("test-notification-button")
            }
            if notifications.deferredCount > 0 {
                Text(strings["Запланированы ближайшие сроки. Остальные добавятся при следующем открытии приложения."])
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = notifications.lastError {
                Text(strings["Не удалось настроить уведомления."] + " " + error)
                    .foregroundStyle(.red).textSelection(.enabled)
                Button(strings["Повторить"]) { notifications.synchronize() }
            }
        } header: { Label(strings["Уведомления"], systemImage: "bell") }
        footer: {
            Text(strings["О сроке с указанным временем напомним в этот момент. Ежедневное напоминание предлагает проверить планы; оно выключено по умолчанию. Тестовое уведомление появится через 5 секунд."])
        }
    }

    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60,
                                  second: 0, of: .now) ?? .now
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes.wrappedValue = (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
        })
    }
}
