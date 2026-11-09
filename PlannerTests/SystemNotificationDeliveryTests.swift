import AppKit
import EventKit
import SwiftData
import Testing
@testable import Planner

@MainActor
struct SystemNotificationDeliveryTests {
    @Test(arguments: [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
                      .EKEventStoreChanged, NSApplication.didBecomeActiveNotification], [false, true])
    func calendarRefreshesAfterNotification(name: Notification.Name, background: Bool) async throws {
        let center = NotificationCenter(), store = FakeCalendarStore()
        let service = CalendarService(store: store, notificationCenter: center)
        let revision = service.revision
        store.calendarList = [CalendarInfo(id: "updated", title: "Updated", colorHex: "8050C0", writable: true)]

        await post(name, to: center, background: background)
        try await wait { service.revision > revision }

        #expect(service.revision == revision + 1)
        #expect(service.calendars == store.calendarList)
        #expect(store.requests == 0)
    }

    @Test(arguments: [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
                      NSApplication.didBecomeActiveNotification], [false, true])
    func remindersReconcileAfterNotification(name: Notification.Name, background: Bool) async throws {
        let center = NotificationCenter(), client = DeliveryNotificationClient()
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext)
        let suite = "local.planner.delivery-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let notifications = PlannerNotifications(client: client, notificationCenter: center)
        notifications.configure(service: service, preferences: preferences)
        await notifications.waitUntilIdle()
        let reads = client.permissionReads
        client.access = .denied

        await post(name, to: center, background: background)
        try await wait { client.permissionReads > reads }
        await notifications.waitUntilIdle()

        #expect(client.permissionReads == reads + 1)
        #expect(notifications.permission == .denied)
        #expect(client.permissionRequests == 0)
        #expect(notifications.lastError == nil)
    }

    private func post(_ name: Notification.Name, to center: NotificationCenter, background: Bool) async {
        if background {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInteractive).async {
                    dispatchPrecondition(condition: .notOnQueue(.main))
                    center.post(name: name, object: nil)
                    continuation.resume()
                }
            }
        } else {
            center.post(name: name, object: nil)
        }
    }

    private func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "Notification was not handled")
    }
}

@MainActor
private final class DeliveryNotificationClient: NotificationClient {
    var access = NotificationPermission.authorized
    var permissionReads = 0
    var permissionRequests = 0
    func permission() async -> NotificationPermission { permissionReads += 1; return access }
    func requestPermission() async throws -> Bool { permissionRequests += 1; return false }
    func pendingIDs() async -> [String] { [] }
    func deliveredIDs() async -> [String] { [] }
    func add(_ plan: PlannerNotification) async throws {}
    func removePending(_ ids: [String]) {}
    func removeDelivered(_ ids: [String]) {}
}
