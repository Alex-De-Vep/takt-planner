import AppKit
import Combine
import Observation
import SwiftData
import PlannerLocalization

@MainActor @Observable
final class PlannerNotifications {
    private let client: any NotificationClient
    private var context: ModelContext?
    private var preferences: AppPreferences?
    @ObservationIgnored private var observations: Set<AnyCancellable> = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    private var dirty = false
    private var needsPermission = false
    private var invalidated: Set<String> = []
    private var applied: [String: PlannerNotification] = [:]
    private var observedCapacity: Int?
    private(set) var permission = NotificationPermission.notDetermined
    private(set) var lastError: String?
    private(set) var deferredCount = 0
    @ObservationIgnored var showWorkspace: (() -> Void)?
    var taskToOpen: UUID?
    var openRevision = 0

    init(client: (any NotificationClient)? = nil, notificationCenter: NotificationCenter = .default) {
        #if SHOWCASE
        self.client = client ?? PreviewNotificationClient()
        #elseif DEBUG
        let testing = ProcessInfo.processInfo.environment["PLANNER_UI_TEST_LIBRARY"].flatMap(UUID.init(uuidString:)) != nil
        self.client = client ?? (testing ? PreviewNotificationClient() : SystemNotificationClient())
        #else
        self.client = client ?? SystemNotificationClient()
        #endif
        if let system = self.client as? SystemNotificationClient {
            system.delivered = { [weak self] in self?.synchronize() }
            system.open = { [weak self] id in
                self?.taskToOpen = id; self?.openRevision += 1
                NSApp.activate(ignoringOtherApps: true)
                self?.showWorkspace?()
            }
        }
        for name in [NSApplication.didBecomeActiveNotification, .NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            // Day/time-zone changes may arrive off-main, before the inner Task switches actors.
            notificationCenter.publisher(for: name).sink { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in self?.synchronize() }
            }.store(in: &observations)
        }
    }

    func configure(service: TaskService?, preferences: AppPreferences) {
        context = service?.context; self.preferences = preferences
        service?.notificationChanged = { [weak self] id, ask in
            self?.invalidated.insert(PlannerNotification.deadlineID(id))
            self?.synchronize(requestPermission: ask && preferences.deadlineNotificationsEnabled)
        }
        synchronize()
    }

    func synchronize(requestPermission: Bool = false) {
        dirty = true; needsPermission = needsPermission || requestPermission
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while self.dirty {
                self.dirty = false
                let ask = self.needsPermission; self.needsPermission = false
                await self.reconcile(requestPermission: ask)
            }
            self.worker = nil
        }
    }

    func waitUntilIdle() async { await worker?.value }

    private func reconcile(requestPermission: Bool) async {
        guard let context, let preferences else { return }
        do {
            permission = await client.permission()
            if requestPermission && permission == .notDetermined {
                _ = try await client.requestPermission()
                permission = await client.permission()
            }
            let tasks = try context.fetch(FetchDescriptor<PlannerTask>())
            let schedule = preferences.notificationSchedule
            let strings = preferences.translations
            let reviews = PlannerNotification.reviews(schedule: schedule, strings: strings)
            let deadlines = PlannerNotification.deadlines(tasks: tasks, schedule: schedule, strings: strings, now: .now)
            // Пробуем запланировать все сроки. Ограничиваем очередь только если сам системный центр
            // ранее не сохранил часть запросов; ближайшие сроки и повторения получают приоритет.
            let capacity = observedCapacity.map { max(0, $0 - reviews.count) } ?? deadlines.count
            let desired = permission == .authorized ? Array(deadlines.prefix(capacity)) + reviews : []
            deferredCount = permission == .authorized ? max(0, deadlines.count - capacity) : 0
            let desiredIDs = Set(desired.map(\.id))
            let pending = await client.pendingIDs()
            let delivered = await client.deliveredIDs()
            // Во время await могла измениться задача или настройка. Берём новый снимок до записи в центр.
            if dirty { return }
            client.removePending(pending.filter { Self.isScheduled($0) && !desiredIDs.contains($0) })
            let activeIDs = Set(tasks.filter { !$0.isDeleted && !$0.isCompleted && $0.deadline != nil }
                .map { PlannerNotification.deadlineID($0.id) })
            let changed = invalidated; invalidated.removeAll()
            client.removeDelivered(delivered.filter {
                if $0.hasPrefix(PlannerNotification.deadlinePrefix) {
                    return !schedule.deadlinesEnabled || !activeIDs.contains($0) || changed.contains($0)
                }
                return $0.hasPrefix(PlannerNotification.reviewPrefix) && !desiredIDs.contains($0)
            })
            let schedulingOrder = desired.filter { $0.id.hasPrefix(PlannerNotification.deadlinePrefix) }.reversed() + reviews
            for plan in schedulingOrder where desiredIDs.contains(plan.id) {
                if dirty { return }
                if applied[plan.id] != plan || !pending.contains(plan.id) { try await client.add(plan) }
            }
            let retained = Set(await client.pendingIDs())
            if dirty { return }
            let missing = desired.filter { !retained.contains($0.id) }
            if !missing.isEmpty {
                observedCapacity = desired.count - missing.count
                deferredCount += missing.count
            }
            applied = Dictionary(uniqueKeysWithValues: desired.filter { retained.contains($0.id) }.map { ($0.id, $0) })
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    private static func isScheduled(_ id: String) -> Bool {
        id.hasPrefix(PlannerNotification.deadlinePrefix) || id.hasPrefix(PlannerNotification.reviewPrefix)
    }

    func sendTest() async {
        guard let preferences else { return }
        synchronize(requestPermission: true)
        await waitUntilIdle()
        guard permission == .authorized else { return }
        do {
            try await client.add(PlannerNotification(id: "planner.test", title: preferences.translations["Уведомления работают"],
                body: preferences.translations["Так будут выглядеть напоминания приложения «Задачи»."], trigger: .once(.now.addingTimeInterval(5))))
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}

#if DEBUG || SHOWCASE
// Используется только при явно включённой изоляции UI-теста.
@MainActor private final class PreviewNotificationClient: NotificationClient {
    private var plans: [String: PlannerNotification] = [:]
    func permission() async -> NotificationPermission { .authorized }
    func requestPermission() async throws -> Bool { true }
    func pendingIDs() async -> [String] { Array(plans.keys) }
    func deliveredIDs() async -> [String] { [] }
    func add(_ plan: PlannerNotification) async throws { plans[plan.id] = plan }
    func removePending(_ ids: [String]) { ids.forEach { plans[$0] = nil } }
    func removeDelivered(_ ids: [String]) {}
}
#endif
