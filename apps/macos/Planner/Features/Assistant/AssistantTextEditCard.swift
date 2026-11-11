import SwiftUI

/// Сравнение и подтверждение живут в чате; библиотека не меняется от ввода в этих полях.
struct AssistantTextEditCard: View {
    @Environment(\.translations) private var strings
    let edit: AssistantTextEdit
    let busy: Bool
    let active: Bool
    var canRefine = true
    let update: (AssistantTextEdit) -> Void
    let refine: () -> Void
    let apply: () -> Void
    let cancel: () -> Void
    let refresh: () -> Void
    let open: () -> Void
    private var pending: Bool { edit.status == .pending }
    private var locked: Bool { busy || !pending || edit.committed != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(strings[edit.target == .savedTask ? "Изменения задачи" : "Доработка новой задачи"], systemImage: "wand.and.stars")
                .font(.callout.weight(.semibold))
            Text(edit.before.title.isEmpty ? strings["Новая задача"] : edit.before.title).font(.caption).foregroundStyle(.secondary)
            if let title = edit.change.title, title != edit.before.title {
                section("Название", included: binding(\.includeTitle)) {
                    before(edit.before.title)
                    Text(strings["Стало"]).font(.caption.weight(.semibold)).foregroundStyle(PlannerStyle.accent)
                    TextField(strings["Название"], text: Binding(get: { title }, set: { value in change { $0.change.title = value } }), axis: .vertical)
                        .textFieldStyle(.roundedBorder).disabled(locked).accessibilityIdentifier("assistant-text-title")
                }
            }
            if let description = edit.change.description, description != edit.before.description {
                section("Описание", included: binding(\.includeDescription)) {
                    before(edit.before.description)
                    Text(strings["Стало"]).font(.caption.weight(.semibold)).foregroundStyle(PlannerStyle.accent)
                    TextEditor(text: Binding(get: { description }, set: { value in change { $0.change.description = value } }))
                        .font(.system(size: 13)).frame(height: 160).disabled(locked)
                        .accessibilityLabel(strings["Новое описание"]).accessibilityIdentifier("assistant-text-description")
                }
            }
            if !edit.additions.isEmpty || (edit.target == .proposal && edit.change.checklist != nil) {
                Toggle(strings[edit.target == .savedTask ? "Добавятся подзадачи" : "Подзадачи"], isOn: binding(\.includeChecklist))
                    .toggleStyle(.checkbox).font(.callout.weight(.semibold)).disabled(locked)
                if !edit.before.checklist.isEmpty {
                    if edit.target == .savedTask {
                        Text(strings["Существующие подзадачи, их порядок и выполнение сохранятся."]).font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup(strings["Было"]) {
                        ForEach(edit.before.checklist) { item in
                            Label(item.title, systemImage: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if edit.additions.isEmpty { Text(strings["Пусто"]).font(.caption).foregroundStyle(.secondary) }
                ForEach(edit.additions) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("", isOn: Binding(get: { item.included }, set: { value in change { copy in
                            if let index = copy.additions.firstIndex(where: { $0.id == item.id }) { copy.additions[index].included = value }
                        } })).labelsHidden().toggleStyle(.checkbox).disabled(locked)
                            .accessibilityLabel(strings["Включить подзадачу"] + ": " + item.title)
                        TextField(strings["Название подзадачи"], text: Binding(get: { item.title }, set: { value in change { copy in
                            if let index = copy.additions.firstIndex(where: { $0.id == item.id }) { copy.additions[index].title = value }
                        } }), axis: .vertical).textFieldStyle(.roundedBorder).disabled(locked)
                    }
                }
            }
            if let error = edit.error { Text(strings[error]).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if pending {
                if canRefine, edit.error == AssistantTextEdit.conflict {
                    Button(strings["Обновить предложение по текущему тексту"], action: refresh).disabled(busy)
                }
                HStack {
                    Button(strings["Отмена"], action: cancel).disabled(locked)
                    Spacer(minLength: 0)
                    if canRefine {
                        Button(strings[active ? "Продолжить доработку" : "Доработать"], action: refine).disabled(locked)
                    }
                }
                Button(strings[edit.target == .savedTask ? "Применить к задаче" : "Принять правки"], action: apply)
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, alignment: .trailing)
                    .disabled(busy || !edit.hasSelection).accessibilityIdentifier("assistant-confirm-text")
            } else {
                Label(strings[edit.status == .applied ? "Изменения применены" : edit.status == .accepted ? "Правки приняты в предложение" : "Правки отменены"], systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if edit.target == .savedTask { Button(strings["Открыть задачу"], action: open).font(.caption).disabled(busy) }
        }
        .padding(12).background(PlannerStyle.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("assistant-text-review")
    }
    private func change(_ action: (inout AssistantTextEdit) -> Void) {
        var copy = edit; action(&copy); update(copy)
    }
    private func binding(_ path: WritableKeyPath<AssistantTextEdit, Bool>) -> Binding<Bool> {
        Binding(get: { edit[keyPath: path] }, set: { value in change { $0[keyPath: path] = value } })
    }
    private func before(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(strings["Было"]).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text.isEmpty ? strings["Пусто"] : text).font(.callout).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func section<Content: View>(_ title: String, included: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(strings[title], isOn: included).toggleStyle(.checkbox).font(.callout.weight(.semibold)).disabled(locked)
            content()
        }
    }
}
