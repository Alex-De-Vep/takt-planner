import AppKit
import SwiftUI
import Testing
@testable import Planner

@MainActor struct NoteTests {
    @Test func movingNotePreservesItsContentAndRejectsTrashAndSystemFolders() throws {
        let store = NoteStore()
        let source = TaskFilter.folder(UUID())
        let destination = TaskFilter.folder(UUID())
        let note = try #require(store.create(folder: source.id))
        store.update(note) { $0.title = "Meeting" }
        try store.applyText("Keep this text", to: note, append: false)
        #expect(!store.move(note, to: .today))
        #expect(store.move(note, to: destination))
        #expect(store.notes.first?.id == note)
        #expect(store.notes.first?.folder == destination.id)
        #expect(store.notes.first?.title == "Meeting")
        #expect(store.notes.first?.text == "Keep this text")
        #expect(store.moveToTrash(note))
        #expect(!store.move(note, to: source))
        #expect(store.notes.first?.folder == destination.id)
    }

    @Test func onlyNewCloudNotesUseSharedFormatEvenWhileLoadingServerConfig() throws {
        let store = NoteStore()
        let oldID = try #require(store.create(folder: "inbox"))
        store.edit(oldID, content: NSAttributedString(string: "Old document"))
        #expect(store.flush())

        store.awaitingCloudNoteFormat = true
        let newID = try #require(store.create(folder: "inbox"))
        #expect(store.notes.first?.richText?.version == SharedNoteText.currentVersion)
        store.sharedFormatLimit = 8 * 1024 * 1024
        store.awaitingCloudNoteFormat = false
        let value = NSMutableAttributedString(string: "🚀 Android link\n• Bullet",
            attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor])
        value.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 24), range: NSRange(location: 0, length: 2))
        value.addAttribute(.link, value: URL(string: "https://example.test")!, range: NSRange(location: 3, length: 12))
        store.edit(newID, content: value)
        store.edit(oldID, content: NSAttributedString(string: "Old document edited"))
        #expect(store.flush())

        let old = try #require(store.notes.first { $0.id == oldID })
        #expect(old.richText == nil)
        #expect(!old.document.isEmpty)
        let note = try #require(store.notes.first { $0.id == newID })
        #expect(note.document.isEmpty)
        let body = try #require(note.richText)
        #expect(body.spans.first?.end == 2)
        #expect(body.spans.first?.bold == true)
        let wire = try NoteStore.wireData(note)
        let restored = try JSONDecoder().decode(PlannerNote.self, from: wire)
        #expect(restored.attributedText().string == value.string)
        #expect(restored.attributedText().attribute(.link, at: 3, effectiveRange: nil) as? URL == URL(string: "https://example.test"))
    }

    @Test func sharedNoteSavesPastedRichTextWithSupportedStyles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Notes.json")
        let store = NoteStore(url: url)
        store.awaitingCloudNoteFormat = true
        let id = try #require(store.create(folder: "inbox"))

        let text = "Здравствуйте! 🚀\n\nСвязаться по почте"
        let link = try #require(URL(string: "mailto:author@example.test"))
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 12
        let font = try #require(NSFont(name: "Helvetica-Bold", size: 17.5))
        let value = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.blue, .backgroundColor: NSColor.yellow,
            .paragraphStyle: paragraph, .kern: 0.5,
        ])
        let linkRange = (text as NSString).range(of: "по почте")
        value.addAttributes([.link: link, .underlineStyle: NSUnderlineStyle.double.rawValue], range: linkRange)
        let rtf = try value.data(from: NSRange(location: 0, length: value.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let pasted = try #require(NSAttributedString(rtf: rtf, documentAttributes: nil))

        store.edit(id, content: pasted)
        #expect(store.flush())
        #expect(store.error == nil)

        let note = try #require(NoteStore(url: url).notes.first)
        #expect(note.text == text)
        #expect(note.document.isEmpty)
        let restored = note.attributedText()
        let restoredFont = try #require(restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: restoredFont).contains(.boldFontMask))
        #expect(restoredFont.pointSize == 18)
        #expect(restored.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
        #expect(restored.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL == link)
        #expect(restored.attribute(.underlineStyle, at: linkRange.location, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
    }

    @Test func editorMatchesPastedTextToNoteStyleBeforeSaving() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let text = "Привет 🙂 — почта"
        let link = try #require(URL(string: "mailto:author@example.test"))
        let originalFont = try #require(NSFont(name: "Helvetica-Bold", size: 32))
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 20
        let content = NSMutableAttributedString(string: text, attributes: [
            .font: originalFont, .foregroundColor: NSColor.red, .backgroundColor: NSColor.yellow,
            .paragraphStyle: paragraph,
        ])
        let linkRange = (text as NSString).range(of: "почта")
        content.addAttributes([.link: link, .underlineStyle: NSUnderlineStyle.single.rawValue], range: linkRange)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let wrapper = FileWrapper(regularFileWithContents: png)
        wrapper.preferredFilename = "image.png"
        content.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        let rtfd = try content.data(from: NSRange(location: 0, length: content.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        pasteboard.clearContents()
        #expect(pasteboard.setData(rtfd, forType: .rtfd))

        let editor = NoteTextView()
        editor.isRichText = true
        editor.importsGraphics = true
        editor.string = "До заменить после"
        let selection = (editor.string as NSString).range(of: "заменить")
        editor.setSelectedRange(selection)
        editor.typingAttributes[.font] = NSFont.systemFont(ofSize: 24)
        #expect(editor.readSelection(from: pasteboard))
        #expect(editor.selectedRange() == NSRange(location: selection.location + content.length, length: 0))

        let result = editor.attributedString()
        #expect(result.string == "До " + content.string + " после")
        let font = try #require(result.attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont)
        #expect(font.familyName == NSFont.systemFont(ofSize: 16).familyName)
        #expect(font.pointSize == 16)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        #expect(result.attribute(.foregroundColor, at: selection.location, effectiveRange: nil) as? NSColor == .labelColor)
        #expect(result.attribute(.backgroundColor, at: selection.location, effectiveRange: nil) == nil)
        #expect(result.attribute(.link, at: selection.location + linkRange.location, effectiveRange: nil) as? URL == link)
        #expect(result.attribute(.attachment, at: selection.location + content.length - 1, effectiveRange: nil) != nil)

        let store = NoteStore()
        store.awaitingCloudNoteFormat = true
        let id = try #require(store.create(folder: "inbox"))
        store.edit(id, content: result)
        #expect(store.flush())
        #expect(store.notes.first?.text == result.string)
    }

    @Test func editorPreservesCyrillicInHTMLPasteWithoutCharset() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let html = #"<p style="color: red"><a href="mailto:author@example.test">Связаться</a></p>"#
        pasteboard.clearContents()
        #expect(pasteboard.setData(Data(html.utf8), forType: .html))
        let editor = NoteTextView()
        editor.isRichText = true
        #expect(editor.readSelection(from: pasteboard))
        let result = editor.attributedString()
        #expect(result.string.trimmingCharacters(in: .newlines) == "Связаться")
        #expect(result.attribute(.link, at: 0, effectiveRange: nil) as? URL == URL(string: "mailto:author@example.test"))
    }

    @Test func bodySaveFailureIsScopedToItsNoteAndClearsAfterRetry() throws {
        let store = NoteStore()
        store.awaitingCloudNoteFormat = true
        let affected = try #require(store.create(folder: "inbox"))
        let other = try #require(store.create(folder: "inbox"))
        store.sharedFormatLimit = 1
        let content = NSAttributedString(string: "Unsaved draft")
        store.edit(affected, content: content)

        #expect(!store.flush())
        #expect(store.error == SharedNoteText.Failure.noteTooLarge.localizedDescription)
        #expect(store.saveError(for: affected) == store.error)
        #expect(store.saveError(for: other) == nil)
        #expect(store.libraryError == nil)
        let note = try #require(store.notes.first { $0.id == affected })
        #expect(store.content(note).string == content.string)
        #expect(note.text.isEmpty)

        store.sharedFormatLimit = nil
        #expect(store.flush())
        #expect(store.saveError(for: affected) == nil)
        #expect(store.notes.first { $0.id == affected }?.text == content.string)
    }

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

    @Test func trashExpiresAtThirtyDaysAndCannotBeRestored() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Notes.json")
        let store = NoteStore(url: url)
        let id = try #require(store.create(folder: "inbox"))
        let recent = try #require(store.create(folder: "inbox"))
        store.update(id) { $0.title = "Expired title"; $0.text = "Expired body" }
        #expect(store.moveToTrash(id))
        let deleted = try #require(store.notes.first { $0.id == id }?.deletedAt)
        store.update(recent) { $0.deletedAt = deleted.addingTimeInterval(60) }
        let deadline = deleted.addingTimeInterval(30 * 24 * 60 * 60)
        store.purgeExpiredTrash(now: deadline.addingTimeInterval(-1))
        #expect(store.notes.first { $0.id == id }?.text == "Expired body")
        store.purgeExpiredTrash(now: deadline)
        let reopened = NoteStore(url: url)
        let marker = try #require(reopened.notes.first { $0.id == id })
        #expect(marker.isPurged && marker.text.isEmpty && marker.title.isEmpty && marker.document.isEmpty)
        reopened.restoreFromTrash(id)
        #expect(reopened.notes.first { $0.id == id }?.deletedAt == deleted)
        #expect(reopened.notes.first { $0.id == recent }?.isPurged == false)
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

    @Test func legacyTextAndTranscriptionFollowAppearanceWithoutChangingExplicitColors() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TaktNotes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Notes.json")
        let store = NoteStore(url: url)
        let id = try #require(store.create(folder: "inbox"))

        let styledFont = NSFont.boldSystemFont(ofSize: 18)
        let explicitColor = NSColor.systemRed
        let legacy = NSMutableAttributedString(string: "Старый текст ", attributes: [.font: styledFont])
        let coloredIndex = legacy.length
        legacy.append(NSAttributedString(string: "цвет", attributes: [.foregroundColor: explicitColor]))
        let legacyDocument = try legacy.data(from: NSRange(location: 0, length: legacy.length),
                                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        store.update(id) { note in
            note.document = legacyDocument
            note.text = legacy.string
        }
        let original = try #require(store.notes.first)
        let adapted = original.attributedText()
        let adaptiveColor = try #require(adapted.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(adaptiveColor == .labelColor)
        let adaptedFont = try #require(adapted.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(adaptedFont.pointSize == styledFont.pointSize)
        #expect(NSFontManager.shared.traits(of: adaptedFont).contains(.boldFontMask))
        #expect(adapted.attribute(.foregroundColor, at: coloredIndex, effectiveRange: nil) as? NSColor == explicitColor)
        #expect(store.notes.first?.document == legacyDocument)

        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        var lightWhite: CGFloat?
        var darkWhite: CGFloat?
        light.performAsCurrentDrawingAppearance { lightWhite = adaptiveColor.usingColorSpace(.genericGray)?.whiteComponent }
        dark.performAsCurrentDrawingAppearance { darkWhite = adaptiveColor.usingColorSpace(.genericGray)?.whiteComponent }
        #expect(try #require(lightWhite) < 0.3)
        #expect(try #require(darkWhite) > 0.7)

        let transcript = "Новая расшифровка."
        try store.applyText(transcript, to: id, append: true, voiceTranscriptID: UUID())
        let reopened = NoteStore(url: url)
        let note = try #require(reopened.notes.first)
        let decoded = try #require(NSAttributedString(rtfd: note.document, documentAttributes: nil))
        let index = (decoded.string as NSString).range(of: transcript).location
        try #require(index != NSNotFound)
        #expect(decoded.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor == .labelColor)
        #expect(decoded.attribute(.foregroundColor, at: coloredIndex, effectiveRange: nil) as? NSColor == explicitColor)
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
            NoteListView(store: store, notes: store.notes, selection: .constant(id), trash: false, create: {})
                .frame(width: 280)
            Divider()
            NoteDetailView(note: note, folders: [], store: store, voice: NoteVoiceRecording(), assistant: assistant,
                           preferences: AppPreferences()).frame(width: 650)
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
