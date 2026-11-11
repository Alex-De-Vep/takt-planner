import AppKit
import SwiftUI

struct NotificationLifecycle: ViewModifier {
    let service: TaskService?
    @Bindable var preferences: AppPreferences
    @Bindable var notifications: PlannerNotifications
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .task(id: service.map(ObjectIdentifier.init)) {
                let open = openWindow
                // Сохраняем действие и после закрытия последнего окна: щелчок по уведомлению откроет рабочее окно.
                notifications.showWorkspace = {
                    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("workspace-") == true }) {
                        window.makeKeyAndOrderFront(nil)
                    } else { open(id: "workspace") }
                }
                notifications.configure(service: service, preferences: preferences)
            }
            .onChange(of: preferences.notificationSchedule) { old, new in
                notifications.synchronize(requestPermission: (!old.deadlinesEnabled && new.deadlinesEnabled)
                    || (!old.reviewEnabled && new.reviewEnabled))
            }
            .onChange(of: preferences.language) { notifications.synchronize() }
    }
}
