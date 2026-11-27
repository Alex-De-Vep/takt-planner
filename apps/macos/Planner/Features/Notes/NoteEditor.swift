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

final class NoteTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard isEditable else { return false }
        // NSTextView can pass legacy pasteboard names even when the source uses modern types.
        let format: NSPasteboard.PasteboardType = switch type.rawValue {
        case "NSStringPboardType": .string
        case "NeXT Rich Text Format v1.0 pasteboard type": .rtf
        case "NeXT RTFD pasteboard type": .rtfd
        case "Apple HTML pasteboard type": .html
        default: type
        }
        let content: NSAttributedString?
        switch format {
        case .rtfd, .rtf:
            content = pasteboard.data(forType: format).flatMap {
                NSAttributedString(pasteboardPropertyList: $0, ofType: format)
            }
        case .html:
            guard let data = pasteboard.data(forType: format) else {
                return super.readSelection(from: pasteboard, type: type)
            }
            // Browsers can supply UTF-8 fragments without a charset declaration.
            if String(data: data, encoding: .utf8) != nil {
                content = try? NSAttributedString(data: data,
                    options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                    documentAttributes: nil)
            } else {
                content = NSAttributedString(pasteboardPropertyList: data, ofType: format)
            }
        case .string:
            content = pasteboard.string(forType: format).map { NSAttributedString(string: $0) }
        default:
            // Let AppKit handle image-only pasteboards and other native formats.
            return super.readSelection(from: pasteboard, type: type)
        }
        guard let content else { return super.readSelection(from: pasteboard, type: type) }

        let bodyFont = NSFont.systemFont(ofSize: 16)
        let fonts = NSFontManager.shared
        let styled = NSMutableAttributedString(string: content.string)
        content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { original, range, _ in
            var font = bodyFont
            if let originalFont = original[.font] as? NSFont {
                let traits = fonts.traits(of: originalFont)
                if traits.contains(.boldFontMask) { font = fonts.convert(font, toHaveTrait: .boldFontMask) }
                if traits.contains(.italicFontMask) { font = fonts.convert(font, toHaveTrait: .italicFontMask) }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            attributes[.link] = original[.link]
            attributes[.attachment] = original[.attachment]
            if let underline = original[.underlineStyle] as? Int, underline & 0xFF != 0 {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            styled.setAttributes(attributes, range: range)
        }
        let range = rangeForUserTextChange
        guard range.location != NSNotFound else { return false }
        breakUndoCoalescing()
        guard performValidatedReplacement(in: range, with: styled) else { return false }
        let insertionPoint = NSRange(location: range.location + styled.length, length: 0)
        setSelectedRange(insertionPoint)
        scrollRangeToVisible(insertionPoint)
        return true
    }

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
    var transcriptStart: Int? { didSet { if transcriptStart != nil { needsLayout = true } } }

    override func tile() {
        super.tile()
        resizeDocument()
    }

    override func layout() {
        super.layout()
        resizeDocument()
        guard let start = transcriptStart, let window, contentSize.width > 0, contentSize.height > 0,
              let text = documentView as? NSTextView, let storage = text.textStorage else { return }
        transcriptStart = nil
        let insertion = NSRange(location: min(start, storage.length), length: 0)
        text.setSelectedRange(insertion)
        text.scrollRangeToVisible(insertion)
        let rect = text.firstRect(forCharacterRange: insertion, actualRange: nil)
        guard rect.height > 0 else { return }
        let line = text.convert(window.convertFromScreen(rect), from: nil)
        var visible = contentView.bounds
        visible.origin.y = line.minY - text.textContainerInset.height
        contentView.scroll(to: contentView.constrainBoundsRect(visible).origin)
        reflectScrolledClipView(contentView)
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
        if let start = store.takeTranscriptStart(for: note.id), let scroll = scroll as? NoteScrollView {
            scroll.transcriptStart = start
        }
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

private struct NoteTitleEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let editable: Bool
    let focusOnCreation: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Field {
        let field = Field(frame: .zero)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.font = .systemFont(ofSize: 28, weight: .bold)
        field.textColor = .labelColor
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("note-title")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.changed = { text = $0 }
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.isEditable = editable
        field.isSelectable = editable
        field.isEnabled = editable
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
        field.requestCreationFocus(focusOnCreation && editable)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: Field, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 300)
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let height = field.cell?.cellSize(forBounds: bounds).height ?? 0
        return CGSize(width: width, height: max(36, ceil(height)))
    }

    static func dismantleNSView(_ field: Field, coordinator: Coordinator) {
        field.requestCreationFocus(false)
        field.delegate = nil
        coordinator.changed = nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var changed: ((String) -> Void)?

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            field.invalidateIntrinsicContentSize()
            changed?(field.stringValue)
        }
    }

    final class Field: NSTextField {
        private var needsCreationFocus = false
        private var didFocusForCreation = false
        private var focusScheduled = false

        func requestCreationFocus(_ requested: Bool) {
            needsCreationFocus = requested
            scheduleCreationFocus()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleCreationFocus()
        }

        private func scheduleCreationFocus() {
            guard needsCreationFocus, !didFocusForCreation, !focusScheduled, window != nil else { return }
            focusScheduled = true
            // Окно сначала подключает новый редактор, затем AppKit назначает ему field editor.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusScheduled = false
                guard self.needsCreationFocus, !self.isHiddenOrHasHiddenAncestor, let window = self.window else { return }
                self.didFocusForCreation = window.makeFirstResponder(self)
            }
        }
    }
}

struct NoteDetailView: View {
    @Environment(\.translations) private var strings
    let note: PlannerNote
    let folders: [TaskFolder]
    let store: NoteStore
    let voice: NoteVoiceRecording
    let assistant: AssistantService
    let preferences: AppPreferences
    var focusTitle = false
    @State private var control = NoteEditorControl()

    private var currentFolder: TaskFilter? {
        if let folder = folders.first(where: { !$0.isDeleted && TaskFilter.folder($0.id).id == note.folder }) {
            return .folder(folder.id)
        }
        return TaskFilter.systemFolders.first { $0.id == note.folder }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                WorkspaceFolderMenu(kind: .note, current: currentFolder, folders: folders) {
                    store.move(note.id, to: $0)
                }
                .disabled(note.deletedAt != nil || store.unreadable)
                NoteTitleEditor(text: Binding(get: { note.title }, set: { title in store.update(note.id) { $0.title = title } }),
                                placeholder: strings["Название"], editable: note.deletedAt == nil && !store.unreadable,
                                focusOnCreation: focusTitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32).padding(.top, 28)
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

            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .padding(.horizontal, 32).padding(.vertical, 18)
            .disabled(note.deletedAt != nil || store.unreadable)
            Divider().padding(.horizontal, 28)
            if let error = store.saveError(for: note.id) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(strings["Не удалось сохранить заметку"]).fontWeight(.medium)
                    Text(strings[error]).font(.caption).textSelection(.enabled)
                    Button(strings["Повторить"]) { store.flush() }
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
                .accessibilityIdentifier("note-save-error")
            }
            NoteVoiceControls(note: note, store: store, voice: voice, assistant: assistant, preferences: preferences)
            NoteRichTextEditor(note: note, store: store, control: control).id(note.id)
            if note.deletedAt != nil {
                HStack {
                    Text(strings["Заметка в корзине"]).foregroundStyle(.secondary)
                    Spacer()
                    Button(strings["Восстановить"]) { store.restoreFromTrash(note.id) }
                }.padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
