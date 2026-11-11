import AppKit
import SwiftUI
import Testing
@testable import Planner

/// Проверяем настоящий NSTableView с отдельным тестовым окном, без библиотеки пользователя.
@MainActor
struct TaskSelectionSyncTests {
    @Test func creatingFirstTaskReleasesEmptyListsFocusBeforeInsertion() {
        let fixture = SelectionFixture()
        defer { fixture.close() }
        fixture.table.dataSource = nil
        fixture.table.reloadData()
        #expect(fixture.table.numberOfRows == 0)
        #expect(fixture.window.makeFirstResponder(fixture.table))
        let previous = TaskListNativeFocus.prepareForTaskCreation(in: fixture.window)
        #expect(previous === fixture.table)
        #expect(fixture.window.firstResponder !== fixture.table)
        #expect(fixture.selectedID == nil)
        // Возврат фокуса при ошибке создания также остаётся возможным.
        #expect(fixture.window.makeFirstResponder(previous))
    }

    @Test func preparingCreationDoesNotStealFocusFromAnExistingTextEditor() {
        let fixture = SelectionFixture()
        defer { fixture.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        fixture.window.contentView?.addSubview(editor)
        #expect(fixture.window.makeFirstResponder(editor))
        #expect(TaskListNativeFocus.prepareForTaskCreation(in: fixture.window) == nil)
        #expect(fixture.window.firstResponder === editor)
    }

    @Test func focusingDragSourceDoesNotChangeItsSelection() {
        let fixture = SelectionFixture()
        defer { fixture.close() }
        fixture.selectedID = fixture.ids[0]
        let focus = TaskListNativeFocus()
        fixture.probes[1].nativeFocus = focus
        fixture.probes[1].reconcileSelection()
        fixture.probes[0].reconcileSelection()
        #expect(focus.takeFocus())
        #expect(fixture.window.firstResponder === fixture.table)
        #expect(fixture.table.selectedRowIndexes == IndexSet(integer: 0))
        #expect(fixture.selectedID == fixture.ids[0])
    }

    @Test func openTaskRestoresNativeSelectionAfterClickingEmptySpace() throws {
        let fixture = SelectionFixture()
        defer { fixture.close() }
        fixture.selectedID = fixture.ids[0]
        fixture.probes[0].reconcileSelection()
        #expect(fixture.table.selectedRowIndexes == IndexSet(integer: 0))
        fixture.table.deselectAll(nil)
        #expect(fixture.table.selectedRowIndexes.isEmpty)
        fixture.probes[0].reconcileSelection()
        #expect(fixture.table.selectedRowIndexes == IndexSet(integer: 0))
        let row = try #require(fixture.table.rowView(atRow: 0, makeIfNecessary: false))
        row.isEmphasized = false
        fixture.probes[0].reconcileSelection()
        #expect(row.isSelected && !row.isEmphasized)
        #expect(fixture.selectedID == fixture.ids[0])
    }

    @Test func selectingAnotherTaskWinsOverAnOldRowsDeferredRepair() {
        let fixture = SelectionFixture()
        defer { fixture.close() }
        fixture.selectedID = fixture.ids[0]
        fixture.probes[0].reconcileSelection()
        fixture.probes[0].scheduleReconciliation()
        fixture.selectedID = fixture.ids[1]
        fixture.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        fixture.probes[0].reconcileSelection()
        fixture.probes[1].reconcileSelection()
        #expect(fixture.table.selectedRowIndexes == IndexSet(integer: 1))
        #expect(fixture.selectedID == fixture.ids[1])
    }

    @Test func clearedNavigationAndDetachedRowsDoNotReopenATask() {
        let fixture = SelectionFixture()
        defer { fixture.close() }
        fixture.selectedID = fixture.ids[0]
        fixture.probes[0].reconcileSelection()
        fixture.selectedID = nil
        // Имитируем автоматический выбор AppKit после удаления строки.
        fixture.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        for probe in fixture.probes { probe.reconcileSelection() }
        #expect(fixture.table.selectedRowIndexes.isEmpty && fixture.selectedID == nil)
        fixture.selectedID = fixture.ids[0]
        fixture.probes[0].detach()
        fixture.probes[0].reconcileSelection()
        #expect(fixture.table.selectedRowIndexes.isEmpty)
    }

    @Test func outgoingActiveRowCannotRestoreSelectionAfterCompletionOrFiltering() {
        let fixture = SelectionFixture()
        defer { fixture.close() }
        fixture.selectedID = fixture.ids[0]
        fixture.probes[0].reconcileSelection()
        // Карточка остаётся открытой, но задача уже перешла в другой список или ушла из поиска.
        fixture.probes[0].isEligible = { false }
        fixture.table.deselectAll(nil)
        fixture.probes[0].reconcileSelection()
        #expect(fixture.selectedID == fixture.ids[0] && fixture.table.selectedRowIndexes.isEmpty)
    }
}

@MainActor
private final class SelectionFixture: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let ids = [UUID(), UUID()]
    let probes = [TaskRowSelectionSync.Probe(), TaskRowSelectionSync.Probe()]
    let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 220))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                          styleMask: [.titled], backing: .buffered, defer: false)
    var selectedID: UUID?

    override init() {
        super.init()
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: table.frame)
        window.contentView = scroll
        scroll.documentView = table
        table.addTableColumn(NSTableColumn(identifier: .init("tasks")))
        table.tableColumns[0].width = 400
        table.headerView = nil
        table.rowHeight = 70
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        for index in probes.indices {
            probes[index].taskID = ids[index]
            probes[index].selectedID = Binding(get: { self.selectedID }, set: { self.selectedID = $0 })
        }
        table.reloadData()
        scroll.layoutSubtreeIfNeeded()
        for index in probes.indices {
            _ = table.rowView(atRow: index, makeIfNecessary: true)
            _ = table.view(atColumn: 0, row: index, makeIfNecessary: true)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { ids.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 400, height: 70))
        let probe = probes[row]
        probe.frame = cell.bounds
        probe.autoresizingMask = [.width, .height]
        cell.addSubview(probe)
        return cell
    }

    func close() {
        for probe in probes { probe.detach() }
        table.delegate = nil
        table.dataSource = nil
        window.close()
    }
}
