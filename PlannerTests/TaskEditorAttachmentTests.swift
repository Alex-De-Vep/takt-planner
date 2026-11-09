import AppKit
import Testing
@testable import Planner

/// Повторное подключение документа не меняет ввод, Undo и обработчики действующей карточки.
@MainActor
struct TaskEditorAttachmentTests {
    @Test func draggingAtTheEdgeSelectsAnInitiallyOffscreenSubtask() throws {
        let store = TaskEditorStore(), taskID = UUID()
        let viewport = NSRect(x: 0, y: 0, width: 320, height: 120)
        let window = NSWindow(contentRect: viewport, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scrollView = NSScrollView(frame: viewport)
        window.contentView = scrollView
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
        scrollView.documentView = document
        let title = store.view(taskID: taskID, title: true)
        let description = store.view(taskID: taskID, title: false)
        let subtask = store.checklistView(taskID: taskID, itemID: UUID())
        for (editor, text, y) in [(title, "Заголовок", 220.0), (description, "Описание", 165.0), (subtask, "Подзадача", 15.0)] {
            editor.string = text
            let host = TaskEditorHost(editor: editor)
            host.frame = NSRect(x: 0, y: y, width: 320, height: 30)
            document.addSubview(host)
            host.layoutSubtreeIfNeeded()
        }
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 140))
        try #require(clip.documentVisibleRect.minY > 45)

        let start = title.convert(NSPoint(x: 0, y: 8), to: nil)
        let viewportInWindow = clip.convert(clip.bounds, to: nil)
        let end = NSPoint(x: viewportInWindow.midX, y: viewportInWindow.minY + 3)
        func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: 1))
        }
        let down = try event(.leftMouseDown, at: start)
        window.postEvent(try event(.leftMouseDragged, at: end), atStart: true)
        let release = Timer(timeInterval: 0.7, repeats: false) { _ in
            MainActor.assumeIsolated {
                if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: end, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                               clickCount: 1, pressure: 0) {
                    window.postEvent(up, atStart: true)
                }
            }
        }
        RunLoop.main.add(release, forMode: .eventTracking)
        title.mouseDown(with: down)
        release.invalidate()

        #expect(clip.documentVisibleRect.minY < 15)
        #expect(store.textSelection.text(for: title) == "Заголовок\nОписание\nПодзадача")
    }

    @Test(arguments: [true, false])
    func leavingMainEditorCollapsesSelectionAndPreservesCaretAndUndo(isTitle: Bool) {
        let store = TaskEditorStore(), taskID = UUID()
        let editor = store.view(taskID: taskID, title: isTitle)
        let host = TaskEditorHost(editor: editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { host.detachEditor(); window.close() }
        host.frame = NSRect(x: 0, y: 100, width: 480, height: 120)
        window.contentView?.addSubview(host)
        let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 60))
        window.contentView?.addSubview(other)
        host.layoutSubtreeIfNeeded()
        #expect(window.makeFirstResponder(editor))
        editor.string = "Начало конец"
        let undo = editor.undoManager!
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.insertText("т", replacementRange: NSRange(location: 7, length: 0))
        undo.endUndoGrouping()
        editor.setSelectedRange(NSRange(location: 7, length: 1))

        #expect(window.makeFirstResponder(other))
        #expect(window.firstResponder === other)
        #expect(editor.selectedRange() == NSRange(location: 8, length: 0))
        #expect(editor.string == "Начало тконец" && editor.undoManager === undo && undo.canUndo)

        #expect(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(window.makeFirstResponder(other))
        #expect(editor.selectedRange() == NSRange(location: 3, length: 0))
        #expect(window.makeFirstResponder(editor))
        undo.undo()
        #expect(editor.string == "Начало конец")
        undo.redo()
        #expect(editor.string == "Начало тконец")
    }

    @Test(arguments: [true, false])
    func detachingFocusedMainEditorCollapsesSelectionThroughFocusLoss(isTitle: Bool) {
        let store = TaskEditorStore(), taskID = UUID()
        let editor = store.view(taskID: taskID, title: isTitle)
        let host = TaskEditorHost(editor: editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        #expect(window.makeFirstResponder(editor))
        editor.string = "Начало конец"
        editor.setSelectedRange(NSRange(location: 2, length: 5))
        let undo = editor.undoManager
        host.detachEditor()
        let reopened = TaskEditorHost(editor: store.view(taskID: taskID, title: isTitle))
        #expect(reopened.editor === editor && reopened.ownsEditor)
        #expect(editor.selectedRange() == NSRange(location: 7, length: 0))
        #expect(editor.string == "Начало конец" && editor.undoManager === undo)
    }

    @Test func detachingAnUnfocusedEditorDoesNotResetItsStoredSelection() {
        let store = TaskEditorStore(), taskID = UUID()
        let editor = store.view(taskID: taskID, title: false)
        let host = TaskEditorHost(editor: editor)
        editor.string = "Начало конец"
        editor.setSelectedRange(NSRange(location: 2, length: 5))
        host.detachEditor()
        #expect(editor.selectedRange() == NSRange(location: 2, length: 5))
    }

    @Test func checklistEditorsKeepTheirSelectionWhenReattached() {
        let store = TaskEditorStore(), taskID = UUID(), firstID = UUID(), secondID = UUID()
        let editor = store.checklistView(taskID: taskID, itemID: firstID)
        let first = TaskEditorHost(editor: editor)
        editor.string = "Начало конец"
        editor.setSelectedRange(NSRange(location: 7, length: 2))
        let other = store.checklistView(taskID: taskID, itemID: secondID)
        other.string = "Другой пункт"
        let second = TaskEditorHost(editor: store.checklistView(taskID: taskID, itemID: firstID))
        first.detachEditor()
        #expect(second.ownsEditor && second.editor === editor && editor.isChecklist)
        #expect(editor.selectedRange() == NSRange(location: 7, length: 2))
        #expect(other !== editor && other.string == "Другой пункт")
        #expect(editor.accessibilityIdentifier() == "checklist-title-\(firstID)")
    }

    @Test func removingCachedChecklistEditorsDoesNotAffectAnotherTask() {
        let store = TaskEditorStore(), taskID = UUID(), otherTaskID = UUID(), itemID = UUID()
        let editor = store.checklistView(taskID: taskID, itemID: itemID)
        let other = store.checklistView(taskID: otherTaskID, itemID: itemID)
        store.removeChecklistItem(taskID: taskID, itemID: itemID)
        let replacement = store.checklistView(taskID: taskID, itemID: itemID)
        #expect(replacement !== editor)
        store.remove(taskID: taskID)
        #expect(store.checklistView(taskID: taskID, itemID: itemID) !== replacement)
        #expect(store.checklistView(taskID: otherTaskID, itemID: itemID) === other)
    }

    @Test func checklistMeasurementWrapsWithoutChangingTextOrSelection() {
        let editor = TaskEditorStore().checklistView(taskID: UUID(), itemID: UUID())
        editor.string = String(repeating: "Длинная подзадача с переносом текста. ", count: 5)
        let text = editor.string
        let selected = NSRange(location: 12, length: 5)
        editor.setSelectedRange(selected)
        let narrow = editor.fittingSize(width: 140, minimumHeight: 20)
        let wide = editor.fittingSize(width: 450, minimumHeight: 20)
        #expect(narrow.height > wide.height && wide.height > 20)
        #expect(editor.string == text && editor.selectedRange() == selected)
    }

    @Test func cachedEditorMovesToOneHostAndOldTeardownCannotDisconnectIt() {
        let store = TaskEditorStore(), taskID = UUID()
        let editor = store.view(taskID: taskID, title: false)
        let first = TaskEditorHost(editor: editor)
        editor.string = "Сохранённое описание"
        editor.setSelectedRange(NSRange(location: 4, length: 5))
        editor.focusRequested = true
        var oldSubmits = 0, newSubmits = 0
        editor.submit = { oldSubmits += 1 }
        let firstCoordinator = PlainTextTaskEditor.Coordinator()
        firstCoordinator.host = first
        editor.delegate = firstCoordinator

        let second = TaskEditorHost(editor: store.view(taskID: taskID, title: false))
        let secondCoordinator = PlainTextTaskEditor.Coordinator()
        secondCoordinator.host = second
        editor.delegate = secondCoordinator
        editor.submit = { newSubmits += 1 }
        // SwiftUI может вызвать dismantle старой карточки уже после подключения новой.
        PlainTextTaskEditor.dismantleNSView(first, coordinator: firstCoordinator)
        #expect(!first.ownsEditor && first.subviews.isEmpty && second.ownsEditor)
        #expect(editor.superview === second && editor.delegate === secondCoordinator)
        #expect(editor.isEditable && editor.isSelectable && !editor.focusRequested)
        #expect(editor.string == "Сохранённое описание" && editor.selectedRange() == NSRange(location: 4, length: 5))
        editor.submit()
        #expect(oldSubmits == 0 && newSubmits == 1)
        PlainTextTaskEditor.dismantleNSView(second, coordinator: secondCoordinator)
        #expect(editor.superview == nil && editor.delegate == nil && editor.editorHost == nil)
    }

    @Test func onlyCurrentCoordinatorSavesEditsToItsTask() {
        let store = TaskEditorStore(), firstID = UUID(), secondID = UUID()
        let first = TaskEditorHost(editor: store.view(taskID: firstID, title: true))
        let other = TaskEditorHost(editor: store.view(taskID: secondID, title: true))
        let oldCoordinator = PlainTextTaskEditor.Coordinator()
        oldCoordinator.host = first
        var oldChanges: [String] = [], currentChanges: [String] = []
        oldCoordinator.changed = { oldChanges.append($0) }
        let current = TaskEditorHost(editor: store.view(taskID: firstID, title: true))
        let coordinator = PlainTextTaskEditor.Coordinator()
        coordinator.host = current
        coordinator.changed = { currentChanges.append($0) }
        current.editor.string = "Новое название"
        let notification = Notification(name: NSText.didChangeNotification, object: current.editor)
        oldCoordinator.textDidChange(notification)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: other.editor))
        coordinator.textDidChange(notification)
        #expect(oldChanges.isEmpty && currentChanges == ["Новое название"])
    }

    @Test func undoSelectionAndPlainTextSurviveDetachingAndReopening() {
        let store = TaskEditorStore(), taskID = UUID()
        let editor = store.view(taskID: taskID, title: false)
        let first = TaskEditorHost(editor: editor)
        editor.undoManager?.groupsByEvent = false
        editor.undoManager?.beginUndoGrouping()
        editor.insertText("Первая\nВторая", replacementRange: NSRange(location: 0, length: 0))
        editor.undoManager?.endUndoGrouping()
        let undo = editor.undoManager
        first.detachEditor()
        let second = TaskEditorHost(editor: store.view(taskID: taskID, title: false))
        #expect(second.ownsEditor && editor.undoManager === undo && editor.isEditable && !editor.isRichText)
        #expect(editor.acceptsFirstMouse(for: nil))
        editor.undoManager?.undo()
        #expect(editor.string.isEmpty)
        editor.undoManager?.redo()
        #expect(editor.string == "Первая\nВторая")
    }

    @Test func hostFillsTheVisibleEditorAndIncludesItsWholeSurfaceInHitTesting() {
        let editor = TaskEditorStore().view(taskID: UUID(), title: false)
        let host = TaskEditorHost(editor: editor)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 180)
        host.layoutSubtreeIfNeeded()
        #expect(editor.frame == host.bounds)
        // Проверяем и текстовую область, и пустую часть описания справа и снизу.
        for point in [NSPoint(x: 4, y: 4), NSPoint(x: 210, y: 40), NSPoint(x: 414, y: 174)] {
            #expect(host.hitTest(point) === editor)
        }
    }
}
