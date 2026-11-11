import Foundation
import SwiftData
import Testing
import UserNotifications
import PlannerLocalization
@testable import Planner

@MainActor
struct NotificationTests {
    private func preferences() -> AppPreferences {
        AppPreferences(defaults: UserDefaults(suiteName: "local.planner.notification-tests." + UUID().uuidString)!)
    }
    private func fixture(_ client: NotificationClientStub = NotificationClientStub()) throws
        -> (TaskService, AppPreferences, NotificationClientStub, PlannerNotifications) {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        client.container = container
        let service = TaskService(context: container.mainContext), prefs = preferences(), notifications = PlannerNotifications(client: client)
        notifications.configure(service: service, preferences: prefs)
        return (service, prefs, client, notifications)
    }
    private func task(_ service: TaskService, day: Int = 1) throws -> PlannerTask {
        let task = try #require(service.createTask(in: .inbox, folders: []))
        let date = Date(timeIntervalSince1970: 4_100_000_000 + Double(day) * 86400)
        #expect(service.setDeadline(task, to: TaskDeadline(date: date, includesTime: true)))
        return task
    }

    @Test func changingDeadlineReplacesTheSameRequestAndRenameUpdatesItsText() async throws {
        let (service, _, client, notifications) = try fixture()
        let task = try task(service)
        await notifications.waitUntilIdle()
        let id = PlannerNotification.deadlineID(task.id)
        let first = try #require(client.pending[id])
        client.delivered.insert(id)
        let later = TaskDeadline(date: task.deadline!.date.addingTimeInterval(86400), includesTime: true)
        #expect(service.setDeadline(task, to: later))
        service.rename(task, to: "Отправить отчёт")
        await notifications.waitUntilIdle()
        #expect(client.pending.count == 1 && client.pending[id]?.trigger == .once(later.date))
        #expect(client.pending[id]?.body == "Отправить отчёт" && client.pending[id] != first)
        #expect(!client.delivered.contains(id))
    }

    @Test func completionCancelsPendingAndDeliveredReopeningRestoresAndDeletionCancelsAgain() async throws {
        let (service, _, client, notifications) = try fixture()
        let task = try task(service), id = PlannerNotification.deadlineID(task.id)
        await notifications.waitUntilIdle()
        client.delivered.insert(id)
        service.toggleCompleted(task)
        await notifications.waitUntilIdle()
        #expect(client.pending[id] == nil && !client.delivered.contains(id))
        service.toggleCompleted(task)
        await notifications.waitUntilIdle()
        #expect(client.pending[id] != nil)
        #expect(service.delete(task))
        await notifications.waitUntilIdle()
        #expect(client.pending[id] == nil)
    }

    @Test func removingDeadlineAndTurningNotificationsOffRemoveRequests() async throws {
        let (service, prefs, client, notifications) = try fixture()
        let task = try task(service), id = PlannerNotification.deadlineID(task.id)
        await notifications.waitUntilIdle()
        #expect(service.setDeadline(task, to: nil))
        await notifications.waitUntilIdle()
        #expect(client.pending[id] == nil)
        _ = try self.task(service, day: 2)
        await notifications.waitUntilIdle()
        prefs.deadlineNotificationsEnabled = false
        notifications.synchronize()
        await notifications.waitUntilIdle()
        #expect(client.pending.isEmpty)
    }

    @Test func failedPersistenceLeavesPreviouslyScheduledDeadlineIntact() async throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        var fail = false
        let service = TaskService(context: context, saveContext: {
            if fail { throw CocoaError(.fileWriteUnknown) }; try $0.save()
        })
        let prefs = preferences(), client = NotificationClientStub(), notifications = PlannerNotifications(client: client)
        client.container = container
        notifications.configure(service: service, preferences: prefs)
        let task = try task(service), id = PlannerNotification.deadlineID(task.id)
        await notifications.waitUntilIdle()
        let original = client.pending[id]
        fail = true
        #expect(!service.setDeadline(task, to: TaskDeadline(date: task.deadline!.date.addingTimeInterval(86400), includesTime: true)))
        await notifications.waitUntilIdle()
        #expect(client.pending[id] == original)
        #expect(!service.delete(task))
        await notifications.waitUntilIdle()
        #expect(client.pending[id] == original)
    }

    @Test func launchReconcilesPersistedTasksAndCleansStaleManagedRequestsOnly() async throws {
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext), task = try task(service)
        let client = NotificationClientStub()
        client.container = container
        let stale = "planner.deadline.deleted"
        client.pending[stale] = PlannerNotification(id: stale, title: "", body: "", trigger: .once(.distantFuture))
        client.pending["external"] = PlannerNotification(id: "external", title: "", body: "", trigger: .once(.distantFuture))
        let notifications = PlannerNotifications(client: client)
        notifications.configure(service: service, preferences: preferences())
        await notifications.waitUntilIdle()
        #expect(client.pending[stale] == nil && client.pending["external"] != nil)
        #expect(client.pending[PlannerNotification.deadlineID(task.id)] != nil)
    }

    @Test func permissionIsRequestedOnlyAfterUserActionAndDeniedPermissionDoesNotSchedule() async throws {
        let client = NotificationClientStub(); client.access = .notDetermined; client.grants = false
        let (service, _, _, notifications) = try fixture(client)
        await notifications.waitUntilIdle()
        #expect(client.permissionRequests == 0)
        _ = try task(service)
        await notifications.waitUntilIdle()
        #expect(client.permissionRequests == 1 && notifications.permission == .denied && client.pending.isEmpty)
        client.access = .authorized
        notifications.synchronize()
        await notifications.waitUntilIdle()
        #expect(client.pending.count == 1 && client.permissionRequests == 1)
    }

    @Test func schedulerFailureIsVisibleAndCanBeRetried() async throws {
        let (service, _, client, notifications) = try fixture()
        client.fail = true
        let task = try task(service)
        await notifications.waitUntilIdle()
        #expect(notifications.lastError != nil)
        client.fail = false
        notifications.synchronize()
        await notifications.waitUntilIdle()
        #expect(notifications.lastError == nil && client.pending[PlannerNotification.deadlineID(task.id)] != nil)
    }

    @Test func latestEditWinsWhileAnOlderRequestIsInFlight() async throws {
        let (service, _, client, notifications) = try fixture()
        var continuation: CheckedContinuation<Void, Never>?
        client.beforeAdd = {
            client.beforeAdd = nil
            await withCheckedContinuation { continuation = $0 }
        }
        let task = try task(service)
        for _ in 0..<1000 where continuation == nil { await Task.yield() }
        let paused = try #require(continuation)
        let next = TaskDeadline(date: task.deadline!.date.addingTimeInterval(86400), includesTime: true)
        #expect(service.setDeadline(task, to: next))
        paused.resume()
        await notifications.waitUntilIdle()
        #expect(client.pending.count == 1)
        #expect(client.pending[PlannerNotification.deadlineID(task.id)]?.trigger == .once(next.date))
    }

    @Test func dailyReviewCanChangeTimeSwitchToWeekdaysAndBeDisabled() async throws {
        let (_, prefs, client, notifications) = try fixture()
        await notifications.waitUntilIdle()
        #expect(!prefs.reviewNotificationsEnabled && client.pending.isEmpty)
        prefs.reviewNotificationsEnabled = true; prefs.reviewNotificationMinutes = 18 * 60 + 30
        notifications.synchronize(requestPermission: true)
        await notifications.waitUntilIdle()
        #expect(client.pending["planner.review.daily"]?.trigger == .daily(hour: 18, minute: 30, weekday: nil))
        prefs.reviewWeekdaysOnly = true; prefs.reviewNotificationMinutes = 8 * 60
        notifications.synchronize()
        await notifications.waitUntilIdle()
        #expect(client.pending.count == 5 && client.pending["planner.review.daily"] == nil)
        for weekday in 2...6 {
            #expect(client.pending["planner.review.\(weekday)"]?.trigger == .daily(hour: 8, minute: 0, weekday: weekday))
        }
        prefs.reviewNotificationsEnabled = false
        notifications.synchronize()
        await notifications.waitUntilIdle()
        #expect(client.pending.isEmpty)
    }

    @Test func dateOnlyUsesChosenLocalTimeAndPastOrCompletedTasksDoNotSchedule() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let day = cal.date(from: DateComponents(year: 2099, month: 4, day: 3))!
        let task = PlannerTask(title: "День", now: day)
        task.deadlineDate = day; task.deadlineTimeZoneID = cal.timeZone.identifier
        let plan = PlannerNotification.deadlines(tasks: [task], schedule: NotificationSchedule(dateOnlyMinutes: 10 * 60 + 45),
            strings: .init(language: .russian), now: day, calendar: cal)
        #expect(plan.first?.trigger == .once(day.addingTimeInterval(10 * 3600 + 45 * 60)))
        #expect(plan.first?.usesLocalTime == true)
        #expect(PlannerNotification.deadlines(tasks: [task], schedule: .init(), strings: .init(language: .russian),
            now: day.addingTimeInterval(86400), calendar: cal).isEmpty)
        task.completedAt = day
        #expect(PlannerNotification.deadlines(tasks: [task], schedule: .init(), strings: .init(language: .russian), now: day, calendar: cal).isEmpty)
    }

    @Test func nativeTriggersPreserveInstantAndRepeatInLocalTime() throws {
        let id = UUID(), date = Date(timeIntervalSince1970: 4_100_000_000)
        let once = SystemNotificationClient.request(for: PlannerNotification(id: "deadline", title: "Срок", body: "Задача", trigger: .once(date), taskID: id))
        let trigger = try #require(once.trigger as? UNCalendarNotificationTrigger)
        #expect(!trigger.repeats && trigger.nextTriggerDate() == date)
        #expect(once.content.userInfo["taskID"] as? String == id.uuidString)
        let local = SystemNotificationClient.request(for: PlannerNotification(id: "local", title: "", body: "",
            trigger: .once(date), usesLocalTime: true))
        let localTrigger = try #require(local.trigger as? UNCalendarNotificationTrigger)
        #expect(!localTrigger.repeats && localTrigger.dateComponents.timeZone == nil)
        #expect(localTrigger.dateComponents.hour == Calendar.current.component(.hour, from: date))
        let daily = SystemNotificationClient.request(for: PlannerNotification(id: "review", title: "", body: "", trigger: .daily(hour: 9, minute: 15, weekday: 2)))
        let repeatTrigger = try #require(daily.trigger as? UNCalendarNotificationTrigger)
        #expect(repeatTrigger.repeats && repeatTrigger.dateComponents.timeZone == nil)
        #expect(repeatTrigger.dateComponents.hour == 9 && repeatTrigger.dateComponents.minute == 15 && repeatTrigger.dateComponents.weekday == 2)
    }

    @Test func queueKeepsNearestDeadlinesAndRefillsAfterCompletion() async throws {
        let (service, prefs, client, notifications) = try fixture()
        client.capacity = 60
        let tasks = try (0..<65).map { try task(service, day: $0) }
        prefs.reviewNotificationsEnabled = true; prefs.reviewWeekdaysOnly = true
        notifications.synchronize()
        await notifications.waitUntilIdle()
        #expect(client.pending.count == 60 && notifications.deferredCount == 10)
        #expect(client.pending[PlannerNotification.deadlineID(tasks[0].id)] != nil)
        #expect(client.pending[PlannerNotification.deadlineID(tasks[55].id)] == nil)
        service.toggleCompleted(tasks[0])
        await notifications.waitUntilIdle()
        #expect(client.pending[PlannerNotification.deadlineID(tasks[55].id)] != nil && notifications.deferredCount == 9)
    }

    @Test func schedulesEveryDeadlineWhenTheSystemHasRoom() async throws {
        let (service, prefs, client, notifications) = try fixture()
        _ = try (0..<75).map { try task(service, day: $0) }
        prefs.reviewNotificationsEnabled = true
        notifications.synchronize()
        await notifications.waitUntilIdle()
        #expect(client.pending.count == 76 && notifications.deferredCount == 0)
    }

    @Test func notificationPreferencesSurviveReload() {
        let defaults = UserDefaults(suiteName: "local.planner.notification-tests." + UUID().uuidString)!
        let prefs = AppPreferences(defaults: defaults)
        #expect(prefs.deadlineNotificationsEnabled && !prefs.reviewNotificationsEnabled)
        prefs.reviewNotificationsEnabled = true; prefs.reviewNotificationMinutes = 19 * 60
        prefs.reviewWeekdaysOnly = true; prefs.dateOnlyNotificationMinutes = 8 * 60 + 15
        let reopened = AppPreferences(defaults: defaults)
        #expect(reopened.reviewNotificationsEnabled && reopened.reviewWeekdaysOnly && reopened.reviewNotificationMinutes == 19 * 60)
        #expect(reopened.dateOnlyNotificationMinutes == 8 * 60 + 15)
    }
}

@MainActor private final class NotificationClientStub: NotificationClient {
    var container: ModelContainer?
    var access = NotificationPermission.authorized
    var grants = true
    var permissionRequests = 0
    var pending: [String: PlannerNotification] = [:]
    var delivered: Set<String> = []
    var fail = false
    var capacity: Int?
    var order: [String] = []
    var beforeAdd: (() async -> Void)?
    func permission() async -> NotificationPermission { access }
    func requestPermission() async throws -> Bool {
        permissionRequests += 1; access = grants ? .authorized : .denied; return grants
    }
    func pendingIDs() async -> [String] { Array(pending.keys) }
    func deliveredIDs() async -> [String] { Array(delivered) }
    func add(_ plan: PlannerNotification) async throws {
        await beforeAdd?()
        if fail { throw CocoaError(.fileWriteUnknown) }
        pending[plan.id] = plan
        order.removeAll { $0 == plan.id }; order.append(plan.id)
        if let capacity {
            while order.count > capacity { pending[order.removeFirst()] = nil }
        }
    }
    func removePending(_ ids: [String]) { ids.forEach { pending[$0] = nil }; order.removeAll { ids.contains($0) } }
    func removeDelivered(_ ids: [String]) { ids.forEach { delivered.remove($0) } }
}
