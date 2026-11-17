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
        let probe = try #require(await fixture.waitForProbe(for: task.id))
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

    @Test func insertingNoteMovesExistingRowThroughIntermediatePositions() async throws {
        let fixture = try AnimationFixture()
        defer { fixture.close() }
        let store = NoteStore()
        let first = try #require(store.create(folder: "inbox"))
        _ = store.create(folder: "inbox")
        fixture.updateNotes(store)
        try await Task.sleep(for: .milliseconds(400))
        let probe = try #require(fixture.probe(for: first))
        let before = try #require(fixture.position(of: probe))

        let inserted = try #require(store.create(folder: "inbox"))
        fixture.updateNotes(store, selected: inserted)
        let samples = await fixture.samples(of: probe)
        let after = try #require(fixture.position(of: probe))
        #expect(after > before + 40)
        #expect(samples.contains { $0 > before + 1 && $0 < after - 1 })
        let selectedProbe = try #require(fixture.probe(for: inserted))
        let table = try #require(selectedProbe.nativeFocus?.table)
        #expect(table.selectedRow == table.row(for: selectedProbe))
    }

    @Test func syncedNoteIsFullyVisibleWhenListIsAtTop() async throws {
        let fixture = try AnimationFixture()
        defer { fixture.close() }
        let store = NoteStore()
        for _ in 0..<12 { _ = store.create(folder: "inbox") }
        let first = try #require(store.notes.first?.id)
        fixture.updateNotes(store, selected: first, sortByDate: true)
        let probe = try #require(await fixture.waitForProbe(for: first))
        try await Task.sleep(for: .milliseconds(250))
        let table = try #require(probe.nativeFocus?.table)
        try #require(table.visibleRect.minY <= table.rect(ofRow: 0).minY + 1)

        let incoming = PlannerNote(title: "Новая заметка с телефона")
        try store.applyRemote(incoming, revision: NoteStore.digest(NoteStore.wireData(incoming)))
        fixture.updateNotes(store, selected: first, sortByDate: true)
        try await Task.sleep(for: .milliseconds(500))

        let current = try #require(fixture.probe(for: incoming.id))
        let row = table.rect(ofRow: table.row(for: current))
        #expect(table.visibleRect.minY <= row.minY + 1)
        #expect(table.visibleRect.maxY >= row.maxY - 1)
    }

    @Test func syncedNoteDoesNotJumpToTopWhileReadingFurtherDown() async throws {
        let fixture = try AnimationFixture()
        defer { fixture.close() }
        let store = NoteStore()
        for _ in 0..<16 { _ = store.create(folder: "inbox") }
        let first = try #require(store.notes.first?.id)
        fixture.updateNotes(store, sortByDate: true)
        let probe = try #require(await fixture.waitForProbe(for: first))
        try await Task.sleep(for: .milliseconds(250))
        let table = try #require(probe.nativeFocus?.table)
        table.scrollRowToVisible(12)
        try await Task.sleep(for: .milliseconds(250))
        let offset = table.visibleRect.minY
        try #require(offset > 100)

        let incoming = PlannerNote(title: "Новая заметка с телефона")
        try store.applyRemote(incoming, revision: NoteStore.digest(NoteStore.wireData(incoming)))
        fixture.updateNotes(store, sortByDate: true)
        try await Task.sleep(for: .milliseconds(500))

        #expect(table.visibleRect.minY >= offset - 1)
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
        content.update(AnyView(list), key: WorkspaceListAnimationKey(scope: .tasks(.inbox, search: ""),
            active: snapshot.activeTasks.map(\.id), completed: []),
            transaction: Transaction(animation: animated ? .easeInOut(duration: 0.26) : nil), host: host.view)
    }
    func updateNotes(_ store: NoteStore, selected: UUID? = nil, sortByDate: Bool = false) {
        let notes = sortByDate ? store.notes.sorted { $0.updatedAt > $1.updatedAt } : store.notes
        let scope = WorkspaceListScope.notes(.folder, folder: .inbox, search: "")
        let list = NoteListView(store: store, notes: notes, folders: [], selection: .constant(selected),
            trash: false, createdNoteID: selected, scope: scope, create: {})
        content.update(AnyView(list), key: WorkspaceListAnimationKey(scope: scope,
            active: notes.map(\.id), completed: []),
            transaction: Transaction(animation: .easeInOut(duration: 0.26)), host: host.view)
    }
    func probe(for id: UUID) -> WorkspaceRowSelectionSync.Probe? {
        func find(_ view: NSView) -> WorkspaceRowSelectionSync.Probe? {
            if let probe = view as? WorkspaceRowSelectionSync.Probe, probe.rowID == id { return probe }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(host.view)
    }
    func waitForProbe(for id: UUID) async -> WorkspaceRowSelectionSync.Probe? {
        // На загруженной машине первая раскладка может начаться позже фиксированной задержки.
        for _ in 0..<120 {
            if let probe = probe(for: id) { return probe }
            try? await Task.sleep(for: .milliseconds(8))
        }
        return nil
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
    func close() {
        content.update(AnyView(EmptyView()), key: nil, transaction: Transaction(), host: host.view)
        window.close()
        window.contentViewController = nil
    }
}
