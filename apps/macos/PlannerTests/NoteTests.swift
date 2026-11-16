import AppKit
import SwiftUI
import Testing
@testable import Planner

@MainActor struct NoteTests {
    @Test func conflictKeepsOfflineEditAfterRestartAndCloudTrashCanBeRestored() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TaktNotes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Notes.json")
        let store = NoteStore(url: url)
        let localID = try #require(store.create(folder: "inbox"))
        var first = try #require(store.notes.first)
        let initial = try NoteStore.digest(NoteStore.wireData(first))
        try store.acknowledge(localID, revision: initial, digest: initial)
        store.update(localID) { $0.title = "Написано офлайн" }
        #expect(store.flush())

        let reopened = NoteStore(url: url)
        first.deletedAt = Date()
        let trashed = try NoteStore.digest(NoteStore.wireData(first))
        try reopened.applyRemote(first, revision: trashed)
        #expect(reopened.notes.count == 2)
        #expect(reopened.notes.first { $0.id == localID }?.deletedAt != nil)
        #expect(reopened.notes.contains { $0.id != localID && $0.title == "Написано офлайн" && $0.syncVersion == nil })

        let synced = NoteStore(url: url)
        first.deletedAt = nil
        let restored = try NoteStore.digest(NoteStore.wireData(first))
        try synced.applyRemote(first, revision: restored)
        #expect(synced.notes.count == 2)
        #expect(synced.notes.first { $0.id == localID }?.deletedAt == nil)
    }

    @Test func richContentAndLatestEditsSurviveRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TaktNotes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Notes.json")
        let store = NoteStore(url: url)
        let id = try #require(store.create(folder: "week"))
        store.update(id) { $0.title = "Конспект"; $0.pinned = true }
        let content = NSMutableAttributedString(string: "Последние изменения\n☐ Проверить", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        let attachment = NSTextAttachment()
        attachment.fileWrapper = FileWrapper(regularFileWithContents: Data([1, 2, 3]))
        attachment.fileWrapper?.preferredFilename = "fixture.bin"
        content.append(NSAttributedString(attachment: attachment))
        store.edit(id, content: content)
        #expect(store.flush())
        let reopened = NoteStore(url: url)
        let note = try #require(reopened.notes.first)
        #expect(note.title == "Конспект" && note.folder == "week" && note.pinned)
        #expect(note.text == content.string)
        let restored = note.attributedText()
        let font = try #require(restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        #expect(restored.attribute(.attachment, at: restored.length - 1, effectiveRange: nil) != nil)
        reopened.update(id) { $0.deletedAt = .now }
        #expect(reopened.flush())
        let trash = NoteStore(url: url)
        #expect(trash.notes.first?.deletedAt != nil)
        trash.update(id) { $0.deletedAt = nil }
        #expect(trash.flush())
        #expect(NoteStore(url: url).notes.first?.text == content.string)
    }

    @Test func failedWriteKeepsDraftAndRetrySavesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TaktNotes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let obstruction = directory.appending(path: "blocked")
        try Data().write(to: obstruction)
        let store = NoteStore(url: obstruction.appending(path: "Notes.json"))
        let id = try #require(store.create(folder: "inbox"))
        store.edit(id, content: NSAttributedString(string: "Сохранить этот текст"))
        #expect(!store.flush())
        #expect(store.error != nil)
        try FileManager.default.removeItem(at: obstruction)
        #expect(store.flush())
        #expect(NoteStore(url: obstruction.appending(path: "Notes.json")).notes.first?.text == "Сохранить этот текст")
    }

    @Test func backupIncludesPendingNoteAndRestoresIt() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TaktNotesBackup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try PlannerPersistence.makeContainer(inMemory: true)
        let service = TaskService(context: container.mainContext)
        let id = try #require(service.notes.create(folder: "inbox"))
        service.notes.edit(id, content: NSAttributedString(string: "Правка перед экспортом"))
        let assistant = AssistantService(store: AssistantStore(url: directory.appending(path: "chat.json")))
        let suite = "notes.test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let backup = try PlannerBackup.capture(from: service, assistant: assistant, preferences: preferences)
        #expect(backup.version == 2)
        let url = directory.appending(path: "copy.json")
        try backup.write(to: url)
        let decoded = try PlannerBackup.read(from: url)
        let runtime = AppRuntime(defaults: defaults, loadOnInit: false)
        try runtime.restore(decoded, preferences: preferences)
        #expect(runtime.service?.notes.notes.first?.text == "Правка перед экспортом")
        let restoredID = try #require(defaults.string(forKey: PlannerPersistence.restoredLibraryKey).flatMap(UUID.init(uuidString:)))
        defer { try? FileManager.default.removeItem(at: PlannerPersistence.restoredLibraryDirectory(restoredID)) }
        #expect(AppRuntime(defaults: defaults).service?.notes.notes.first?.id == id)
    }

    @Test func corruptFileIsPreserved() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "TaktNotes-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("broken".utf8)
        try data.write(to: url)
        let store = NoteStore(url: url)
        #expect(store.unreadable)
        #expect(store.create(folder: "inbox") == nil)
        #expect(!store.flush())
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func editorRendersWithFormatting() async throws {
        let store = NoteStore()
        let id = try #require(store.create(folder: "inbox"))
        store.update(id) { $0.title = "Идеи для нового проекта"; $0.pinned = true }
        let text = NSMutableAttributedString(string: "С чего начать\n", attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: "\nСобрать мысли, примеры и полезные ссылки в одном месте.\n\n• Обсудить первые сценарии\n• Набросать структуру\n\n☐ Подготовить материалы\n☑ Выбрать направление",
            attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor]))
        store.edit(id, content: text)
        store.flush()
        let note = try #require(store.notes.first)
        let assistantURL = FileManager.default.temporaryDirectory.appending(path: "NotePreview-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: assistantURL) }
        let assistant = AssistantService(store: AssistantStore(url: assistantURL))
        let root = HStack(spacing: 0) {
            NoteListView(store: store, notes: store.notes, folders: [], selection: .constant(id), trash: false, create: {})
                .frame(width: 280)
            Divider()
            NoteDetailView(note: note, store: store, voice: NoteVoiceRecording(), assistant: assistant,
                           preferences: AppPreferences(), discuss: {}).frame(width: 650)
        }.frame(height: 600).background(Color(nsColor: .windowBackgroundColor)).tint(PlannerStyle.accent)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 931, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appending(path: "takt-notes-editor.png")
        try png.write(to: url)
        #expect(host.fittingSize.width <= 932)
        print("NOTES_PREVIEW " + url.path)
    }
}
