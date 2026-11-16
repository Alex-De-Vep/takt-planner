import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class NoteEditorControl {
    @ObservationIgnored weak var view: NSTextView?

    func format(_ style: String) {
        guard let view else { return }
        view.window?.makeFirstResponder(view)
        let selection = view.selectedRange()
        switch style {
        case "bold": view.fontManager(.boldFontMask)
        case "italic": view.fontManager(.italicFontMask)
        case "heading":
            view.setFont(.systemFont(ofSize: 24, weight: .semibold), range: selection)
            view.typingAttributes[.font] = NSFont.systemFont(ofSize: 24, weight: .semibold)
            view.didChangeText()
        case "body":
            view.setFont(.systemFont(ofSize: 16), range: selection)
            view.typingAttributes[.font] = NSFont.systemFont(ofSize: 16)
            view.didChangeText()
        case "bullet": view.insertText("• ", replacementRange: selection)
        case "check": view.insertText("☐ ", replacementRange: selection)
        case "number": view.insertText("1. ", replacementRange: selection)
        default: break
        }
    }

    func insertLink() {
        guard let view else { return }
        let range = view.selectedRange()
        let alert = NSAlert()
        alert.messageText = "URL"
        let input = NSTextField(string: "https://")
        input.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "×")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn, let url = URL(string: input.stringValue),
              ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        let value = range.length == 0 ? NSMutableAttributedString(string: input.stringValue, attributes: view.typingAttributes)
            : NSMutableAttributedString(attributedString: view.attributedString().attributedSubstring(from: range))
        value.addAttribute(.link, value: url, range: NSRange(location: 0, length: value.length))
        view.window?.makeFirstResponder(view)
        view.insertText(value, replacementRange: range)
    }

    func insertImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let view = self?.view else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let image = NSImage(contentsOf: url) else { return }
            if image.size.width > 560 {
                image.size = NSSize(width: 560, height: image.size.height * 560 / image.size.width)
            }
            guard let data = image.tiffRepresentation else { return }
            let attachment = NSTextAttachment()
            let wrapper = FileWrapper(regularFileWithContents: data)
            wrapper.preferredFilename = "image.tiff"
            attachment.fileWrapper = wrapper
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
            view.window?.makeFirstResponder(view)
            view.insertText(NSAttributedString(attachment: attachment), replacementRange: view.selectedRange())
        }
    }
}

private extension NSTextView {
    func fontManager(_ trait: NSFontTraitMask) {
        let manager = NSFontManager.shared
        let range = selectedRange()
        let current = (range.length > 0 ? textStorage?.attribute(.font, at: range.location, effectiveRange: nil) : typingAttributes[.font]) as? NSFont ?? .systemFont(ofSize: 16)
        let font = manager.traits(of: current).contains(trait)
            ? manager.convert(current, toNotHaveTrait: trait) : manager.convert(current, toHaveTrait: trait)
        setFont(font, range: range)
        typingAttributes[.font] = font
        didChangeText()
    }
}

private final class NoteTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let selection = selectedRange()
        let paragraph = text.substring(with: text.paragraphRange(for: NSRange(location: selection.location, length: 0)))
            .trimmingCharacters(in: .newlines)
        var prefix = ""
        if paragraph.hasPrefix("• ") { prefix = "• " }
        else if paragraph.hasPrefix("☐ ") || paragraph.hasPrefix("☑ ") { prefix = "☐ " }
        else if let end = paragraph.range(of: ". "), let number = Int(paragraph[..<end.lowerBound]) {
            prefix = "\(number + 1). "
        }
        if !prefix.isEmpty, paragraph.trimmingCharacters(in: .whitespaces).count <= prefix.trimmingCharacters(in: .whitespaces).count {
            let range = text.paragraphRange(for: selection)
            insertText("", replacementRange: NSRange(location: range.location, length: paragraph.utf16.count))
            return
        }
        super.insertNewline(sender)
        typingAttributes[.font] = NSFont.systemFont(ofSize: 16)
        if !prefix.isEmpty { insertText(prefix, replacementRange: selectedRange()) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let text = string as NSString
        if isEditable, index < text.length, ["☐", "☑"].contains(text.substring(with: NSRange(location: index, length: 1))) {
            insertText(text.substring(with: NSRange(location: index, length: 1)) == "☐" ? "☑" : "☐",
                       replacementRange: NSRange(location: index, length: 1))
            return
        }
        super.mouseDown(with: event)
    }
}

private final class NoteScrollView: NSScrollView {
    override func tile() {
        super.tile()
        resizeDocument()
    }

    override func layout() {
        super.layout()
        resizeDocument()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeDocument()
    }

    private func resizeDocument() {
        guard let text = documentView as? NSTextView else { return }
        text.minSize = NSSize(width: 0, height: contentSize.height)
        let size = NSSize(width: contentSize.width, height: max(contentSize.height, text.frame.height))
        if text.frame.size != size { text.setFrameSize(size) }
    }
}

struct NoteRichTextEditor: NSViewRepresentable {
    let note: PlannerNote
    let store: NoteStore
    let control: NoteEditorControl

    func makeCoordinator() -> Coordinator { Coordinator(id: note.id, store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NoteScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = NoteTextView()
        view.isRichText = true
        view.isSelectable = true
        view.importsGraphics = true
        view.allowsUndo = true
        view.isAutomaticLinkDetectionEnabled = true
        view.isAutomaticSpellingCorrectionEnabled = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 28, height: 16)
        view.drawsBackground = false
        view.textColor = .labelColor
        view.font = .systemFont(ofSize: 16)
        view.textStorage?.setAttributedString(store.content(note))
        view.delegate = context.coordinator
        context.coordinator.appliedRemoteEdit = store.remoteEdit(note.id)
        view.setAccessibilityIdentifier("note-body")
        scroll.documentView = view
        control.view = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let edit = store.remoteEdit(note.id)
        if edit != context.coordinator.appliedRemoteEdit {
            let replacement = store.content(note)
            let selection = view.selectedRange()
            let start = min(selection.location, replacement.length)
            view.textStorage?.setAttributedString(replacement)
            view.setSelectedRange(NSRange(location: start, length: min(selection.length, replacement.length - start)))
            context.coordinator.appliedRemoteEdit = edit
        }
        view.isEditable = note.deletedAt == nil && !store.unreadable
        control.view = view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 400)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        _ = coordinator.store.flush()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let id: UUID
        let store: NoteStore
        var appliedRemoteEdit: UUID?
        init(id: UUID, store: NoteStore) { self.id = id; self.store = store }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            store.edit(id, content: view.attributedString())
        }
        func textDidEndEditing(_ notification: Notification) { _ = store.flush() }
    }
}

struct NoteDetailView: View {
    @Environment(\.translations) private var strings
    let note: PlannerNote
    let store: NoteStore
    @State private var control = NoteEditorControl()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(strings["Название"], text: Binding(get: { note.title }, set: { title in store.update(note.id) { $0.title = title } }))
                .font(.system(size: 28, weight: .bold))
                .textFieldStyle(.plain)
                .padding(.horizontal, 32).padding(.top, 28)
                .accessibilityIdentifier("note-title")
                .disabled(note.deletedAt != nil || store.unreadable)
            HStack(spacing: 14) {
                Button { control.format("heading") } label: { Text("H").fontWeight(.bold) }.help(strings["Заголовок"])
                Button { control.format("body") } label: { Text("Aa") }.help(strings["Обычный текст"])
                Button { control.format("bold") } label: { Image(systemName: "bold") }.help(strings["Жирный"])
                Button { control.format("italic") } label: { Image(systemName: "italic") }.help(strings["Курсив"])
                Divider().frame(height: 16)
                Button { control.format("bullet") } label: { Image(systemName: "list.bullet") }.help(strings["Список"])
                Button { control.format("number") } label: { Image(systemName: "list.number") }.help(strings["Нумерованный список"])
                Button { control.format("check") } label: { Image(systemName: "checklist") }.help(strings["Чек-лист"])
                Button { control.insertLink() } label: { Image(systemName: "link") }.help(strings["Добавить ссылку"])
                Button { control.insertImage() } label: { Image(systemName: "photo") }.help(strings["Добавить изображение"])
                Spacer()
                Button(action: export) { Image(systemName: "square.and.arrow.up") }.help(strings["Экспорт заметки"])
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .padding(.horizontal, 32).padding(.vertical, 18)
            .disabled(note.deletedAt != nil || store.unreadable)
            Divider().padding(.horizontal, 28)
            NoteRichTextEditor(note: note, store: store, control: control).id(note.id)
            if note.deletedAt != nil {
                HStack {
                    Text(strings["Заметка в корзине"]).foregroundStyle(.secondary)
                    Spacer()
                    Button(strings["Восстановить"]) { store.update(note.id) { $0.deletedAt = nil }; store.flush() }
                }.padding()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func export() {
        guard store.flush(), let current = store.notes.first(where: { $0.id == note.id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.rtfd]
        panel.nameFieldStringValue = (current.displayTitle.isEmpty ? strings["Новая заметка"] : current.displayTitle) + ".rtfd"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let value = current.attributedText()
                let wrapper = try value.fileWrapper(from: NSRange(location: 0, length: value.length),
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
                try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }
}
