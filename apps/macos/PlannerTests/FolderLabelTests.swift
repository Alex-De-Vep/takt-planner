import Foundation
import SwiftUI
import Testing
@testable import Planner

@MainActor
struct FolderLabelTests {
    @Test(arguments: [UInt32(0x00_00_00), 0xCA_FB_12, 0x6D_2F_D0, 0xFF_FF_FF])
    func openingTheColorWheelPreservesTheSavedColor(rgb: UInt32) {
        #expect(FolderLabelWheelColor(rgb: rgb).rgb == rgb)
    }

    @Test func colorWheelMapsThePointerToHueAndSaturation() {
        var color = FolderLabelWheelColor(rgb: 0xFF_00_00)
        color.select(at: CGPoint(x: 0, y: 50), radius: 50)
        #expect(color.rgb == 0x00_FF_FF)
        #expect(abs(color.marker(radius: 50).y - 50) < 0.01)
        #expect(abs(color.marker(radius: 50).x) < 0.01)

        color.select(at: CGPoint(x: 50, y: 50), radius: 50)
        #expect(color.rgb == 0xFF_FF_FF)
        color.select(at: CGPoint(x: 120, y: 50), radius: 50)
        color.brightness = 0.5
        #expect(color.rgb == 0x80_00_00)
    }

    @Test func labelsFollowTheCreateButtonInTheToolbar() {
        let controller = WorkspaceSplitController()
        let items = controller.toolbarDefaultItemIdentifiers(NSToolbar()).filter { $0 != .space }
        let create = NSToolbarItem.Identifier("Planner.NewTask")
        let labels = NSToolbarItem.Identifier("Planner.FolderLabels")
        #expect(items.drop(while: { $0 != create }).prefix(2) == [create, labels])
    }

    @Test func folderFilterIncludesLabelsBeforeTheyAreAssigned() throws {
        let store = FolderLabelStore()
        let folder = UUID()
        let otherFolder = UUID()
        let note = FolderLabelTarget.note(UUID())
        try store.save(name: "New label", rgb: 0x70_40_A0, in: folder)
        try store.save(name: "Carried label", rgb: 0x40_A0_70, in: otherFolder, assigningTo: note)

        #expect(store.labels(for: [], includingFrom: folder).map(\.name) == ["New label"])
        #expect(Set(store.labels(for: [note], includingFrom: folder).map(\.name)) == ["New label", "Carried label"])
        #expect(store.labels(for: note).map(\.name) == ["Carried label"])
    }

    @Test func detailLabelsWrapWhenTheColumnNarrows() {
        let folderID = UUID()
        let labels = ["In Review", "Waiting", "Reference"].map {
            FolderLabel(id: UUID(), folderID: folderID, name: $0, rgb: 0x70_40_A0)
        }
        func height(at width: CGFloat) -> CGFloat {
            NSHostingView(rootView: AssignedFolderLabels(labels: labels).frame(width: width, alignment: .leading)).fittingSize.height
        }
        #expect(height(at: 88) > height(at: 400))
    }

    @Test func assignmentsSurviveTaskAndNoteMovesAndReopeningTheLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TaktFolderLabels-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "Planner.store")
        let container = try PlannerPersistence.makeContainer(at: database)
        let service = TaskService(context: container.mainContext)
        service.notes = NoteStore(url: directory.appending(path: "Notes.json"))
        let source = try service.saveFolder(name: "Website")
        let destination = try service.saveFolder(name: "Archive")
        let folders = [source, destination]
        let task = try #require(service.createTask(in: .folder(source.id), folders: folders))
        let noteID = try #require(service.notes.create(folder: TaskFilter.folder(source.id).id))
        let taskTarget = FolderLabelTarget.task(task.id)
        let noteTarget = FolderLabelTarget.note(noteID)

        let labels = service.folderLabels
        try labels.save(name: "Waiting", rgb: 0x70_40_A0, in: source.id, assigningTo: taskTarget)
        let label = try #require(labels.labels(for: taskTarget).first)
        try labels.toggle(label.id, on: noteTarget, currentFolderID: source.id)

        #expect(service.move(task, to: .folder(destination.id), folders: folders))
        #expect(service.notes.move(noteID, to: .folder(destination.id)))
        let reopened = TaskService(context: container.mainContext).folderLabels
        #expect(reopened.labels(in: destination.id).isEmpty)
        #expect(reopened.labels(for: [taskTarget, noteTarget]) == [label])
        #expect(reopened.targets(with: label.id) == [taskTarget, noteTarget])
        #expect(throws: FolderLabelError.unavailable) {
            try reopened.toggle(label.id, on: .task(UUID()), currentFolderID: destination.id)
        }

        let defaultsName = "folder-labels-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let preferences = AppPreferences(defaults: defaults)
        let assistant = AssistantService(store: AssistantStore(url: directory.appending(path: "Chat.json")))
        let backup = try PlannerBackup.capture(from: service, assistant: assistant, preferences: preferences)
        let backupURL = directory.appending(path: "Backup.json")
        try backup.write(to: backupURL)
        do {
            let runtime = AppRuntime(defaults: defaults, loadOnInit: false)
            try runtime.restore(PlannerBackup.read(from: backupURL), preferences: preferences)
            #expect(runtime.service?.folderLabels.labels(for: taskTarget) == [label])
            #expect(runtime.service?.folderLabels.labels(for: noteTarget) == [label])
        }
        let restoredID = try #require(defaults.string(forKey: PlannerPersistence.restoredLibraryKey).flatMap(UUID.init(uuidString:)))
        defer { try? FileManager.default.removeItem(at: PlannerPersistence.restoredLibraryDirectory(restoredID)) }

        try reopened.save(name: "Reviewed", rgb: 0x40_A0_70, in: source.id, editing: label.id)
        #expect(reopened.labels(for: taskTarget).first?.name == "Reviewed")
        #expect(reopened.labels(for: noteTarget).first?.rgb == 0x40_A0_70)
        try reopened.toggle(label.id, on: taskTarget, currentFolderID: destination.id)
        #expect(reopened.labels(for: taskTarget).isEmpty)
        #expect(reopened.contains(label.id, on: noteTarget))
        try reopened.delete(label.id)
        #expect(reopened.labels(for: noteTarget).isEmpty)
        #expect(reopened.archive.assignments.isEmpty)
    }
}
