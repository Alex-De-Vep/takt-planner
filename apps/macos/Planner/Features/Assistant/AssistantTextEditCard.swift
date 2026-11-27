import SwiftUI

/// Показывает итоговый снимок. Применение проверяет исходную версию задачи отдельно.
struct AssistantTextEditCard: View {
    @Environment(\.translations) private var strings
    @Environment(\.colorScheme) private var colorScheme
    let edit: AssistantTextEdit
    let busy: Bool
    let apply: () -> Void
    let refresh: () -> Void

    var body: some View {
        let task = edit.committed ?? edit.selected
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title.isEmpty ? strings["Новая задача"] : task.title)
                .fontWeight(.semibold)
            if !task.description.isEmpty { Text(task.description).textSelection(.enabled) }
            ForEach(task.checklist) { item in
                Label(item.title, systemImage: item.isCompleted ? "checkmark.circle.fill" : "circle")
            }
            if let error = edit.error { Text(strings[error]).foregroundStyle(.red).textSelection(.enabled) }
            if edit.status == .pending {
                if edit.error == AssistantTextEdit.conflict {
                    Button(strings["Обновить предложение по текущему тексту"], action: refresh).disabled(busy)
                } else {
                    Button(strings[edit.target == .savedTask ? "Применить" : "Принять правки"], action: apply)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || !edit.hasSelection)
                        .accessibilityIdentifier("assistant-confirm-text")
                }
            } else if edit.status == .applied || edit.status == .accepted {
                Label(strings[edit.status == .applied ? "Изменения применены" : "Правки приняты в предложение"],
                      systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(PlannerStyle.assistantCardBackground(PlannerStyle.accent, in: colorScheme),
                    in: RoundedRectangle(cornerRadius: 12))
        .tint(PlannerStyle.accent)
        .accessibilityIdentifier("assistant-text-review")
    }
}
