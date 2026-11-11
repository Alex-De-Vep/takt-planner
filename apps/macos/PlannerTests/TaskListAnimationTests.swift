import AppKit
import SwiftUI
import SwiftData
import Testing
@testable import Planner

/// Проверяем промежуточные кадры настоящего списка, а не только наличие withAnimation в коде.
@Suite(.serialized) @MainActor
struct TaskListAnimationTests {
    @Test func firstRowInEmptyListDoesNotDisappearAfterItsInitialDisplay() async throws {
        let fixture = try AnimationFixture()
        defer { fixture.close() }
        fixture.tasks.removeAll()
        fixture.update()
        try await Task.sleep(for: .milliseconds(250))
        let task = PlannerTask(title: "Первая задача")
        fixture.container.mainContext.insert(task)
        fixture.tasks = [task]
        fixture.update(animated: true)
        try await Task.sleep(for: .milliseconds(40))
        let probe = try #require(fixture.probe(for: task.id))
        for _ in 0..<40 {
            var ancestor: NSView? = probe
            while let view = ancestor, !(view is NSTableRowView) { ancestor = view.superview }
            let row = try #require(ancestor as? NSTableRowView)
            #expect((row.layer?.presentation()?.opacity ?? 1) > 0.98)
            try await Task.sleep(for: .milliseconds(8))
        }
    }

    @Test func insertionAndDeletionMoveRowsThroughIntermediatePositions() async throws {
        let fixture = try AnimationFixture()
        defer { fixture.close() }
        fixture.update()
        try await Task.sleep(for: .milliseconds(500))
        fixture.host.view.layoutSubtreeIfNeeded()

        let probe = try #require(fixture.probe(for: fixture.tasks[0].id))
        let before = try #require(fixture.position(of: probe))
        let task = PlannerTask(title: "Новая строка", now: .now.addingTimeInterval(60))
        fixture.container.mainContext.insert(task)
        fixture.tasks.insert(task, at: 0)
        fixture.update(animated: true)
        let insertion = await fixture.samples(of: probe)
        let after = try #require(fixture.position(of: probe))
        #expect(after > before + 40)
        #expect(insertion.contains { $0 > before + 1 && $0 < after - 1 })

        fixture.tasks.removeFirst()
        fixture.update(animated: true)
        let deletion = await fixture.samples(of: probe)
        #expect(deletion.contains { $0 > before + 1 && $0 < after - 1 })
        #expect(abs((fixture.position(of: probe) ?? -100) - before) < 1)
    }

    @Test func rapidInsertionsFinishAtTheCorrectPosition() async throws {
        let fixture = try AnimationFixture()
        defer { fixture.close() }
        fixture.update()
        try await Task.sleep(for: .milliseconds(500))
        let probe = try #require(fixture.probe(for: fixture.tasks[0].id))
        let before = try #require(fixture.position(of: probe))
        for index in 1...2 {
            let task = PlannerTask(title: "Быстрая вставка \(index)", now: .now.addingTimeInterval(Double(index) * 60))
            fixture.container.mainContext.insert(task)
            fixture.tasks.insert(task, at: 0)
            fixture.update(animated: true)
            try await Task.sleep(for: .milliseconds(45))
        }
        let samples = await fixture.samples(of: probe)
        let after = try #require(fixture.position(of: probe))
        #expect(abs(after - before - 140) < 1)
        #expect(samples.contains { $0 > before + 1 && $0 < after - 1 })
    }
}

@MainActor private final class AnimationFixture {
    let container: ModelContainer
    var tasks: [PlannerTask]
    let content = WorkspaceTaskContent()
    let host: NSHostingController<WorkspaceTaskRoot>
    let window: NSWindow
    let drag = TaskDragState()
    init() throws {
        container = try PlannerPersistence.makeContainer(inMemory: true)
        tasks = (0..<3).map { PlannerTask(title: "Строка \($0)", now: .now.addingTimeInterval(-Double($0) * 60)) }
        for task in tasks { container.mainContext.insert(task) }
        host = NSHostingController(rootView: WorkspaceTaskRoot(content: content))
        host.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 360, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Animation regression — тестовые задачи"
        window.contentViewController = host
        host.view.frame = NSRect(x: 0, y: 0, width: 360, height: 600)
        window.setContentSize(NSSize(width: 360, height: 600))
        window.orderFront(nil)
    }
    func update(animated: Bool = false) {
        let snapshot = TaskListSnapshot(tasks: tasks, filter: .inbox, now: .now)
        let list = TaskListView(selectedID: .constant(nil), isCompletedExpanded: .constant(false),
            createdTaskID: nil, search: "", filter: .inbox, snapshot: snapshot, now: .now,
            create: {}, toggleToday: { _ in }, toggleCompleted: { _ in }, delete: { _ in },
            deleteImmediately: { _ in }, folders: [], dragScopeID: UUID(), move: { _, _ in }, taskDrag: drag)
        content.update(AnyView(list), key: TaskListAnimationKey(filter: .inbox, search: "",
            active: snapshot.activeTasks.map(\.id), completed: []),
            transaction: Transaction(animation: animated ? .easeInOut(duration: 0.26) : nil), host: host.view)
    }
    func probe(for id: UUID) -> TaskRowSelectionSync.Probe? {
        func find(_ view: NSView) -> TaskRowSelectionSync.Probe? {
            if let probe = view as? TaskRowSelectionSync.Probe, probe.taskID == id { return probe }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(host.view)
    }
    func position(of probe: NSView) -> CGFloat? {
        var ancestor: NSView? = probe
        while let view = ancestor {
            if let row = view as? NSTableRowView {
                return row.layer?.presentation()?.frame.minY ?? row.frame.minY
            }
            ancestor = view.superview
        }
        return nil
    }
    func samples(of probe: NSView) async -> [CGFloat] {
        var result: [CGFloat] = []
        for _ in 0..<60 {
            if let position = position(of: probe) { result.append(position) }
            try? await Task.sleep(for: .milliseconds(8))
        }
        return result
    }
    func close() { window.close() }
}
