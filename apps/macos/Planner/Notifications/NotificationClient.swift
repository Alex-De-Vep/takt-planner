import AppKit
import UserNotifications

// Системный центр отделён от планировщика: тесты не запрашивают разрешений и не отправляют уведомлений.
enum NotificationPermission { case notDetermined, denied, authorized }

@MainActor
protocol NotificationClient: AnyObject {
    func permission() async -> NotificationPermission
    func requestPermission() async throws -> Bool
    func pendingIDs() async -> [String]
    func deliveredIDs() async -> [String]
    func add(_ plan: PlannerNotification) async throws
    func removePending(_ ids: [String])
    func removeDelivered(_ ids: [String])
}

@MainActor
final class SystemNotificationClient: NSObject, NotificationClient, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var open: ((UUID?) -> Void)?
    var delivered: (() -> Void)?

    override init() { super.init(); center.delegate = self }
    func permission() async -> NotificationPermission {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
    func requestPermission() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    func pendingIDs() async -> [String] { await center.pendingNotificationRequests().map(\.identifier) }
    func deliveredIDs() async -> [String] { await center.deliveredNotifications().map { $0.request.identifier } }
    func removePending(_ ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids) }
    func removeDelivered(_ ids: [String]) { center.removeDeliveredNotifications(withIdentifiers: ids) }
    func add(_ plan: PlannerNotification) async throws { try await center.add(Self.request(for: plan)) }

    static func request(for plan: PlannerNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = plan.title; content.body = plan.body; content.sound = .default
        if let id = plan.taskID { content.userInfo["taskID"] = id.uuidString }
        let components: DateComponents
        let repeats: Bool
        switch plan.trigger {
        case .once(let date) where plan.usesLocalTime:
            // Срок без времени сохраняет свой день и выбранный местный час даже при закрытом приложении.
            components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            repeats = false
        case .once(let date):
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
            var value = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            value.calendar = utc; value.timeZone = utc.timeZone
            components = value; repeats = false
        case .daily(let hour, let minute, let weekday):
            // Без фиксированного пояса: повтор следует за местным временем, в том числе при поездке.
            var value = DateComponents(); value.hour = hour; value.minute = minute; value.weekday = weekday
            components = value; repeats = true
        }
        return UNNotificationRequest(identifier: plan.id, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
        Task { @MainActor [weak self] in self?.delivered?() }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["taskID"] as? String).flatMap(UUID.init(uuidString:))
        let shouldOpen = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor [weak self] in
            if shouldOpen { self?.open?(id) }
        }
        completionHandler()
    }
}
