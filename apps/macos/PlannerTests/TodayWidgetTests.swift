import Foundation
import Testing
@testable import Planner

@MainActor
struct TodayWidgetTests {
    @Test func snapshotMatchesActiveTodayAndLimitsTheNumberOfRows() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tasks = (0..<7).map { index in
            let task = PlannerTask(title: "Task \(index)", now: now.addingTimeInterval(Double(index)))
            task.focusDay = PlannerTask.persistentTodayMark
            return task
        }
        let completed = PlannerTask(title: "Completed", now: now)
        completed.focusDay = PlannerTask.persistentTodayMark
        completed.completedAt = now
        let unstarred = PlannerTask(title: "Inbox", now: now)
        let expired = PlannerTask(title: "Yesterday", now: now)
        expired.focusDay = LocalDay.key(for: now.addingTimeInterval(-86400))
        tasks[6].deadlineDate = now
        tasks[6].deadlineIncludesTime = true
        tasks[6].deadlineTimeZoneID = "UTC"

        let snapshot = TodayWidgetPublisher.makeSnapshot(tasks: tasks + [completed, unstarred, expired], now: now)
        #expect(snapshot.count == 7)
        #expect(snapshot.rows.map(\.id) == tasks.reversed().prefix(5).map(\.id))
        #expect(snapshot.rows.first?.deadline == .init(date: now, includesTime: true, timeZoneID: "UTC"))
    }

    @Test func snapshotRoundTripsAndCanReplaceAnOldLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        let snapshot = TodayWidgetSnapshot(count: 1, rows: [.init(id: UUID(), title: "Example", deadline: nil)])
        #expect(try snapshot.write(to: url))
        #expect(try !snapshot.write(to: url))
        #expect(try TodayWidgetSnapshot.read(from: url) == snapshot)
        #expect(try TodayWidgetSnapshot.empty.write(to: url))
        #expect(try TodayWidgetSnapshot.read(from: url) == .empty)
    }
}
