import AppKit
import SwiftUI

/// Правило Enter отделено от NSTextView, чтобы проверить списки без окна и личных данных.
enum PlainTextLists {
    static func newline(in text: String, selection: NSRange, shift: Bool) -> (range: NSRange, text: String) {
        guard !shift else { return (selection, "\n") }
        let source = text as NSString
        let line = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let value = source.substring(with: line).trimmingCharacters(in: .newlines)
        let pattern = #"^([\t ]*)([-*•] |([0-9]+)\. )"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)),
              selection.location >= line.location + match.range.length else { return (selection, "\n") }
        let rest = (value as NSString).substring(from: match.range.length)
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            return (NSRange(location: line.location, length: (value as NSString).length), "")
        }
        let indent = (value as NSString).substring(with: match.range(at: 1))
        if match.range(at: 3).location != NSNotFound,
           let number = Int((value as NSString).substring(with: match.range(at: 3))), number < Int.max {
            return (selection, "\n\(indent)\(number + 1). ")
        }
        return (selection, "\n" + (value as NSString).substring(with: match.range))
    }
}

/// Каждый документ сохраняет собственные редакторы, позиции ввода и UndoManager между переключениями.
@MainActor
final class TaskEditorStore {
    private var views: [String: TaskTextView] = [:]
    let textSelection = TaskTextSelection()

    func view(taskID: UUID, title: Bool) -> TaskTextView {
        let key = taskID.uuidString + (title ? ".title" : ".description")
        if let view = views[key] { return view }
        let view = makeView(taskID: taskID, title: title, identifier: title ? "task-title-field" : "task-description-field")
        views[key] = view
        return view
    }
    func checklistView(taskID: UUID, itemID: UUID) -> TaskTextView {
        let key = taskID.uuidString + ".checklist." + itemID.uuidString
        if let view = views[key] { return view }
        let view = makeView(taskID: taskID, title: false, identifier: "checklist-title-\(itemID)")
        view.isChecklist = true
        views[key] = view
        return view
    }
    private func makeView(taskID: UUID, title: Bool, identifier: String) -> TaskTextView {
        let view = TaskTextView(frame: .zero)
        view.editorStore = self
        view.taskID = taskID
        view.isEditable = true
        view.isSelectable = true
        view.isTitle = title
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isContinuousSpellCheckingEnabled = true
        view.isAutomaticTextReplacementEnabled = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false
        // Размером управляет SwiftUI: NSTextView не должен сам вырастать поверх следующего блока.
        view.isVerticallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.containerSize.height = .greatestFiniteMagnitude
        view.font = .systemFont(ofSize: title ? 22 : 14, weight: title ? .semibold : .regular)
        view.textColor = .labelColor
        view.setAccessibilityIdentifier(identifier)
        return view
    }
    func attachedEditors(for source: TaskTextView, in window: NSWindow) -> [TaskTextView] {
        views.values.filter { $0.taskID == source.taskID && $0.window === window && $0.editorHost?.ownsEditor == true }
    }

    func removeChecklistItem(taskID: UUID, itemID: UUID) {
        views[taskID.uuidString + ".checklist." + itemID.uuidString] = nil
    }
    func remove(taskID: UUID) {
        for key in views.keys.filter({ $0.hasPrefix(taskID.uuidString + ".") }) { views[key] = nil }
    }
}

struct PlainTextTaskEditor: NSViewRepresentable {
    let taskID: UUID
    let isTitle: Bool
    let store: TaskEditorStore
    @Binding var text: String
    @Binding var requestFocus: Bool
    let placeholder: String
    var submit: () -> Void = {}
    let toggleCompleted: () -> Void
    var minimumHeight: CGFloat? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> TaskEditorHost {
        TaskEditorHost(editor: store.view(taskID: taskID, title: isTitle))
    }
    func updateNSView(_ host: TaskEditorHost, context: Context) {
        // Уходящий representable может обновиться после повторного открытия документа.
        // Только текущий контейнер вправе назначать делегат, данные и запрос фокуса.
        guard host.ownsEditor else { return }
        let view = host.editor
        context.coordinator.host = host
        context.coordinator.changed = { text = $0 }
        view.delegate = context.coordinator
        view.isEditable = true
        view.isSelectable = true
        view.submit = submit
        view.toggleCompleted = toggleCompleted
        view.placeholder = placeholder
        view.setAccessibilityLabel(placeholder)
        // Не присваиваем строку при каждом рендере: это сохраняет выделение, IME и историю отмены.
        if view.string != text, !view.hasMarkedText() {
            view.clearTaskSelection()
            let selection = view.selectedRange()
            view.string = text
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            view.invalidateIntrinsicContentSize()
            host.invalidateIntrinsicContentSize()
        }
        view.needsDisplay = true
        if requestFocus {
            view.focusRequested = true
            view.focusConsumed = { requestFocus = false }
            view.applyRequestedFocus()
        } else { view.cancelRequestedFocus() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView host: TaskEditorHost, context: Context) -> CGSize? {
        host.editor.fittingSize(width: max(1, proposal.width ?? 300),
                         minimumHeight: minimumHeight ?? (isTitle ? 30 : 160))
    }
    static func dismantleNSView(_ host: TaskEditorHost, coordinator: Coordinator) {
        host.detachEditor()
        coordinator.host = nil
        coordinator.changed = nil
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var host: TaskEditorHost?
        var changed: ((String) -> Void)?
        func textDidChange(_ notification: Notification) {
            guard let host, host.ownsEditor, let view = notification.object as? TaskTextView,
                  view === host.editor else { return }
            view.needsDisplay = true; view.invalidateIntrinsicContentSize()
            host.invalidateIntrinsicContentSize()
            changed?(view.string)
        }
    }
}

/// SwiftUI владеет новым контейнером на каждое подключение, а документ — текстом и историей отмены.
/// Закэшированный NSTextView никогда не возвращается системе как корневой representable повторно.
final class TaskEditorHost: NSView {
    let editor: TaskTextView
    private var editorConstraints: [NSLayoutConstraint] = []
    var ownsEditor: Bool { editor.editorHost === self && editor.superview === self }
    override var isFlipped: Bool { true }

    init(editor: TaskTextView) {
        self.editor = editor
        super.init(frame: .zero)
        setAccessibilityElement(false)
        // Переподключение того же документа не является уходом пользователя из поля.
        editor.editorHost?.detachEditor(preservingSelection: true)
        editor.editorHost = self
        editor.isEditable = true
        editor.isSelectable = true
        editor.translatesAutoresizingMaskIntoConstraints = false
        addSubview(editor)
        editorConstraints = [editor.leadingAnchor.constraint(equalTo: leadingAnchor),
                             editor.trailingAnchor.constraint(equalTo: trailingAnchor),
                             editor.topAnchor.constraint(equalTo: topAnchor),
                             editor.bottomAnchor.constraint(equalTo: bottomAnchor)]
        NSLayoutConstraint.activate(editorConstraints)
    }
    required init?(coder: NSCoder) { nil }

    func detachEditor(preservingSelection: Bool = false) {
        // Демонтаж старого контейнера не отключает редактор, уже переданный новому.
        guard ownsEditor else { return }
        editor.clearTaskSelection()
        editor.preservesSelectionDuringTransfer = preservingSelection
        defer { editor.preservesSelectionDuringTransfer = false }
        editor.cancelRequestedFocus()
        editor.delegate = nil
        editor.submit = {}
        editor.toggleCompleted = {}
        if window?.firstResponder === editor { window?.makeFirstResponder(nil) }
        NSLayoutConstraint.deactivate(editorConstraints)
        editorConstraints = []
        editor.removeFromSuperview()
        editor.editorHost = nil
    }
}

final class TaskTextView: NSTextView {
    weak var editorHost: TaskEditorHost?
    fileprivate weak var editorStore: TaskEditorStore?
    fileprivate var taskID: UUID?
    var isTitle = false
    var isChecklist = false
    var placeholder = ""
    var submit: () -> Void = {}
    var toggleCompleted: () -> Void = {}
    var focusRequested = false
    var focusConsumed: () -> Void = {}
    private var focusGeneration = 0
    fileprivate var preservesSelectionDuringTransfer = false
    private let documentUndo = UndoManager()
    override var undoManager: UndoManager? { documentUndo }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { clearTaskSelection() }
        if resigned, !isChecklist, !preservesSelectionDuringTransfer {
            collapseSelectionOnFocusLoss()
            needsDisplay = true
            // NSWindow назначает нового firstResponder после возврата из этого метода.
            // Обновляем мигающий курсор уже после перехода, если редактор не получил фокус снова.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.firstResponder !== self else { return }
                self.updateInsertionPointStateAndRestartTimer(false)
                self.needsDisplay = true
            }
        }
        return resigned
    }

    /// Снимаем подсветку, оставляя точку ввода у конца выделенного фрагмента, а не в конце документа.
    /// Обновление текста и передача редактора новому host не вызывают этот сброс.
    private func collapseSelectionOnFocusLoss() {
        guard !isChecklist, !preservesSelectionDuringTransfer else { return }
        let range = selectedRange()
        guard range.location != NSNotFound, range.length > 0 else { return }
        let location = min(NSMaxRange(range), (string as NSString).length)
        setSelectedRange(NSRange(location: location, length: 0), affinity: selectionAffinity, stillSelecting: false)
    }

    override func mouseDown(with event: NSEvent) {
        clearTaskSelection()
        // Пользовательский клик важнее ранее запланированного автоматического фокуса.
        let consumed = focusRequested ? focusConsumed : {}
        cancelRequestedFocus()
        consumed()
        window?.makeFirstResponder(self)
        if let editorStore, editorStore.textSelection.trackDrag(from: self, event: event, store: editorStore) { return }
        super.mouseDown(with: event)
    }

    func clearTaskSelection() {
        editorStore?.textSelection.clear(including: self)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        clearTaskSelection()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        clearTaskSelection()
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func copy(_ sender: Any?) {
        guard let text = editorStore?.textSelection.text(for: self) else { super.copy(sender); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)), editorStore?.textSelection.canCopy(from: self) == true { return true }
        return super.validateUserInterfaceItem(item)
    }

    /// Пробные ширины SwiftUI измеряем отдельно, не меняя контейнер живого редактора.
    /// Иначе widthTracksTextView может вернуть прежнюю ширину во время ensureLayout,
    /// и описание получит высоту от другого количества строк.
    func fittingSize(width: CGFloat, minimumHeight: CGFloat) -> CGSize {
        let storage = NSTextStorage(attributedString: textStorage ?? NSAttributedString(string: string))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: max(1, width - textContainerInset.width * 2), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = textContainer?.lineFragmentPadding ?? 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        // Последний пустой абзац тоже занимает строку и должен оставлять место для курсора.
        let bottom = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        return CGSize(width: width, height: max(minimumHeight, ceil(bottom + textContainerInset.height * 2) + 6))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if focusRequested { applyRequestedFocus() }
    }
    func applyRequestedFocus() {
        // Новый NSTextView может получить запрос ещё до присоединения к окну.
        focusGeneration += 1
        let generation = focusGeneration
        guard let host = editorHost else { return }
        DispatchQueue.main.async { [weak self, weak host] in
            guard let self, let host, host.ownsEditor, self.editorHost === host,
                  self.focusGeneration == generation, self.focusRequested,
                  let window = self.window else { return }
            if window.makeFirstResponder(self) { self.focusRequested = false; self.focusConsumed() }
        }
    }

    func cancelRequestedFocus() {
        focusGeneration += 1
        focusRequested = false
        focusConsumed = {}
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: .zero, withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor])
        }
    }
    override func insertNewline(_ sender: Any?) {
        if isChecklist {
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            if modifiers.contains(.shift) || modifiers.contains(.option) {
                insertText("\n", replacementRange: selectedRange())
            } else { submit() }
            return
        }
        if isTitle { submit(); return }
        let change = PlainTextLists.newline(in: string, selection: selectedRange(), shift: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
        // insertText использует штатный механизм выделения, уведомлений и отмены NSTextView.
        insertText(change.text, replacementRange: change.range)
    }
    override func insertTab(_ sender: Any?) {
        if isChecklist { window?.selectNextKeyView(sender) }
        else { super.insertTab(sender) }
    }
    override func insertBacktab(_ sender: Any?) {
        if isChecklist { window?.selectPreviousKeyView(sender) }
        else { super.insertBacktab(sender) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36, event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            toggleCompleted(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) {
            insertText(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"), replacementRange: selectedRange())
        } else { pasteAsPlainText(sender) }
    }
}
