import Foundation
import OSLog
import SwiftData
import WidgetKit

@MainActor
enum TodayWidgetPublisher {
    private static let logger = Logger(subsystem: "local.planner.Planner", category: "TodayWidget")

    static func publish(from context: ModelContext?) {
        #if !SHOWCASE
        guard PlannerPersistence.testID == nil, let url = TodayWidgetSnapshot.fileURL else { return }
        let snapshot: TodayWidgetSnapshot
        do {
            let tasks = try context?.fetch(FetchDescriptor<PlannerTask>()) ?? []
            snapshot = makeSnapshot(tasks: tasks)
        } catch {
            logger.error("Could not read Today tasks for the widget.")
            snapshot = .empty
        }
        do {
            if try snapshot.write(to: url) {
                WidgetCenter.shared.reloadTimelines(ofKind: TodayWidgetSnapshot.kind)
            }
        } catch {
            if (try? FileManager.default.removeItem(at: url)) != nil {
                WidgetCenter.shared.reloadTimelines(ofKind: TodayWidgetSnapshot.kind)
            }
            logger.error("Could not update the Today widget snapshot.")
        }
        #endif
    }

    static func makeSnapshot(tasks: [PlannerTask], now: Date = .now) -> TodayWidgetSnapshot {
        let active = TaskListSnapshot(tasks: tasks, filter: .today, now: now).activeTasks
        return TodayWidgetSnapshot(count: active.count, rows: active.prefix(TodayWidgetSnapshot.rowLimit).map { task in
            TodayWidgetSnapshot.Row(
                id: task.id,
                title: task.title,
                deadline: task.deadline.map { .init(date: $0.date, includesTime: $0.includesTime, timeZoneID: $0.timeZoneID) }
            )
        })
    }
}
