import Foundation
import Testing
@testable import Planner

/// В тестах контекст переноса работает без мониторинга мыши и обращения к личной библиотеке.
@MainActor
struct FolderDragStateTests {
    @Test func sourceFolderIsInactiveAndOtherDestinationsAreHighlighted() throws {
        let state = FolderDragState(monitorInput: false)
        let folder = TaskFilter.folder(UUID())
        let payload = FolderDragPayload(kind: .task, itemID: UUID(), scopeID: UUID())
        #expect(state.feedback(for: .week) == .none)
        state.begin(payload: payload, sourceFolderID: folder.id, sourceViewID: UUID())
        let context = try #require(state.context)
        #expect(context.payload == payload && context.sourceFolderID == folder.id)
        #expect(state.feedback(for: folder) == .sameFolder)
        #expect(state.feedback(for: .inbox) == .destination)
        #expect(state.feedback(for: .week) == .destination)
        #expect(state.feedback(for: .today) == .destination)
        #expect(state.feedback(for: .all) == .none)
        state.finish()
        #expect(state.context == nil && state.feedback(for: folder) == .none)
    }

    @Test func noteDragOffersOnlyCustomFolders() throws {
        let drag = FolderDragState(monitorInput: false)
        let source = TaskFilter.folder(UUID())
        let note = FolderDragPayload(kind: .note, itemID: UUID(), scopeID: UUID())
        #expect(FolderDragPayload.decode(try JSONEncoder().encode(note)) == note)
        #expect(note.provider().hasItemConformingToTypeIdentifier("local.planner.note"))
        #expect(!note.provider().hasItemConformingToTypeIdentifier("local.planner.task"))
        drag.begin(payload: note, sourceFolderID: source.id, sourceViewID: UUID())
        #expect(drag.feedback(for: source) == .sameFolder)
        #expect(drag.feedback(for: .folder(UUID())) == .destination)
        for system in TaskFilter.smartFilters { #expect(drag.feedback(for: system) == .none) }
    }

    @Test func staleCleanupAndClosingAnotherWindowDoNotEndNewDrag() throws {
        let state = FolderDragState(monitorInput: false)
        let firstSource = UUID(), secondSource = UUID()
        state.begin(payload: .init(kind: .task, itemID: UUID(), scopeID: UUID()), sourceFolderID: TaskFilter.week.id, sourceViewID: firstSource)
        let old = try #require(state.context)
        state.begin(payload: .init(kind: .task, itemID: UUID(), scopeID: UUID()), sourceFolderID: TaskFilter.month.id, sourceViewID: secondSource)
        let current = try #require(state.context)
        state.finish(token: old.token)
        state.finish(sourceViewID: firstSource)
        state.mouseButtonsChanged(0, token: old.token)
        #expect(state.context == current)
        state.finish(sourceViewID: secondSource)
        #expect(state.context == nil)
    }

    @Test func mouseReleaseOutsideDestinationEndsDragButHoldingDoesNot() throws {
        let state = FolderDragState(monitorInput: false)
        state.begin(payload: .init(kind: .task, itemID: UUID(), scopeID: UUID()), sourceFolderID: TaskFilter.inbox.id, sourceViewID: UUID())
        let context = try #require(state.context)
        state.mouseButtonsChanged(1, token: context.token)
        state.mouseButtonsChanged(3, token: context.token)
        #expect(state.context == context)
        state.mouseButtonsChanged(0, token: context.token)
        #expect(state.context == nil && state.feedback(for: .week) == .none)
    }
}
