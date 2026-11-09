import AppKit
import SwiftUI

/// Редактор принадлежит пункту, а не очередному обновлению SwiftData: курсор и Undo остаются на месте.
struct ChecklistTextEditor: NSViewRepresentable {
    let taskID: UUID
    let itemID: UUID
    let store: TaskEditorStore
    @Binding var text: String
    @Binding var requestFocus: Bool
    let isCompleted: Bool
    let placeholder: String
    let submit: () -> Void
    let toggleCompleted: () -> Void
    let focusChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TaskEditorHost {
        TaskEditorHost(editor: store.checklistView(taskID: taskID, itemID: itemID))
    }

    func updateNSView(_ host: TaskEditorHost, context: Context) {
        guard host.ownsEditor else { return }
        let editor = host.editor
        let coordinator = context.coordinator
        coordinator.host = host
        coordinator.changed = { text = $0 }
        coordinator.focusChanged = focusChanged
        editor.delegate = coordinator
        editor.submit = submit
        editor.toggleCompleted = toggleCompleted
        editor.placeholder = placeholder
        editor.setAccessibilityLabel(placeholder)

        // Локальный ввод уже находится в NSTextView. Повторное присваивание строки сбрасывало бы курсор.
        let replacesText = editor.string != text && !editor.hasMarkedText()
        if replacesText {
            editor.clearTaskSelection()
            let selected = editor.selectedRange()
            editor.string = text
            let length = (text as NSString).length
            let location = min(selected.location, length)
            editor.setSelectedRange(NSRange(location: location, length: min(selected.length, length - location)))
            editor.invalidateIntrinsicContentSize()
            host.invalidateIntrinsicContentSize()
        }
        if coordinator.completed != isCompleted || replacesText {
            coordinator.completed = isCompleted
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: isCompleted ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .strikethroughStyle: isCompleted ? NSUnderlineStyle.single.rawValue : 0
            ]
            editor.textStorage?.addAttributes(attributes, range: NSRange(location: 0, length: (editor.string as NSString).length))
            editor.typingAttributes = attributes
        }
        editor.needsDisplay = true
        if requestFocus {
            editor.focusRequested = true
            editor.focusConsumed = { requestFocus = false }
            editor.applyRequestedFocus()
        } else { editor.cancelRequestedFocus() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView host: TaskEditorHost, context: Context) -> CGSize? {
        host.editor.fittingSize(width: max(1, proposal.width ?? 300), minimumHeight: 20)
    }

    static func dismantleNSView(_ host: TaskEditorHost, coordinator: Coordinator) {
        host.detachEditor()
        coordinator.host = nil
        coordinator.changed = nil
        coordinator.focusChanged = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var host: TaskEditorHost?
        var changed: ((String) -> Void)?
        var focusChanged: ((Bool) -> Void)?
        var completed: Bool?

        func textDidChange(_ notification: Notification) {
            guard let host, host.ownsEditor, notification.object as? NSTextView === host.editor else { return }
            host.editor.invalidateIntrinsicContentSize()
            host.invalidateIntrinsicContentSize()
            host.editor.needsDisplay = true
            changed?(host.editor.string)
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let host, host.ownsEditor, notification.object as? NSTextView === host.editor else { return }
            focusChanged?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let host, host.ownsEditor, notification.object as? NSTextView === host.editor else { return }
            focusChanged?(false)
        }
    }
}
