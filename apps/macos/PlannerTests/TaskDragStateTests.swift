import Foundation
import Testing
@testable import Planner

/// В тестах контекст переноса работает без мониторинга мыши и обращения к личной библиотеке.
@MainActor
struct TaskDragStateTests {
    @Test func sourceFolderIsInactiveAndOtherDestinationsAreHighlighted() throws {
        let state = TaskDragState(monitorInput: false)
        let folder = TaskFilter.folder(UUID())
        let payload = TaskDragPayload(taskID: UUID(), scopeID: UUID())
        #expect(state.feedback(for: .week) == .none)
        state.begin(payload: payload, sourceFolder: folder, sourceViewID: UUID())
        let context = try #require(state.context)
        #expect(context.payload == payload && context.sourceFolder == folder)
        #expect(state.feedback(for: folder) == .sameFolder)
        #expect(state.feedback(for: .inbox) == .destination)
        #expect(state.feedback(for: .week) == .destination)
        #expect(state.feedback(for: .today) == .destination)
        #expect(state.feedback(for: .all) == .none)
        state.finish()
        #expect(state.context == nil && state.feedback(for: folder) == .none)
    }

    @Test func staleCleanupAndClosingAnotherWindowDoNotEndNewDrag() throws {
        let state = TaskDragState(monitorInput: false)
        let firstSource = UUID(), secondSource = UUID()
        state.begin(payload: .init(taskID: UUID(), scopeID: UUID()), sourceFolder: .week, sourceViewID: firstSource)
        let old = try #require(state.context)
        state.begin(payload: .init(taskID: UUID(), scopeID: UUID()), sourceFolder: .month, sourceViewID: secondSource)
        let current = try #require(state.context)
        state.finish(token: old.token)
        state.finish(sourceViewID: firstSource)
        state.mouseButtonsChanged(0, token: old.token)
        #expect(state.context == current)
        state.finish(sourceViewID: secondSource)
        #expect(state.context == nil)
    }

    @Test func mouseReleaseOutsideDestinationEndsDragButHoldingDoesNot() throws {
        let state = TaskDragState(monitorInput: false)
        state.begin(payload: .init(taskID: UUID(), scopeID: UUID()), sourceFolder: .inbox, sourceViewID: UUID())
        let context = try #require(state.context)
        state.mouseButtonsChanged(1, token: context.token)
        state.mouseButtonsChanged(3, token: context.token)
        #expect(state.context == context)
        state.mouseButtonsChanged(0, token: context.token)
        #expect(state.context == nil && state.feedback(for: .week) == .none)
    }
}
