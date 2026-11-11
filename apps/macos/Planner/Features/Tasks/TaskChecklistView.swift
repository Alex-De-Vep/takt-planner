import SwiftUI

/// Подзадачи редактируются в документе и сохраняют свой порядок после выполнения.
struct TaskChecklistView: View {
    @Environment(\.translations) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: PlannerTask
    let service: TaskService
    let editorStore: TaskEditorStore
    let focusItemID: UUID?
    let addItem: (TaskChecklistItem?) -> Void
    @State private var focusedItemID: UUID?
    @State private var requestedFocusID: UUID?

    private var items: [TaskChecklistItem] { task.orderedChecklistItems }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(strings["Подзадачи"]).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(strings.format("Выполнено: %d из %d", items.filter(\.isCompleted).count, items.count))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.bottom, 4)
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 8) {
                        Button { service.toggleChecklistItem(item) } label: {
                            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                .contentTransition(.opacity)
                                .font(.system(size: 17))
                                .foregroundStyle(item.isCompleted ? PlannerStyle.accent : .secondary)
                                .frame(width: 24, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help(strings[item.isCompleted ? "Вернуть подзадачу в работу" : "Выполнить подзадачу"])
                        .accessibilityLabel(strings["Подзадача"] + ": " + service.checklistTitle(for: item))
                        .accessibilityValue(strings[item.isCompleted ? "Выполнено" : "Не выполнено"])
                        .accessibilityIdentifier("complete-checklist-item-\(item.id)")
                        ChecklistTextEditor(taskID: task.id, itemID: item.id, store: editorStore, text: Binding(
                            get: { service.checklistTitle(for: item) },
                            set: { service.renameChecklistItem(item, to: $0) }
                        ), requestFocus: Binding(get: { requestedFocusID == item.id }, set: { requested in
                            if !requested, requestedFocusID == item.id { requestedFocusID = nil }
                        }), isCompleted: item.isCompleted, placeholder: strings["Название подзадачи"],
                            submit: { submit(item) }, toggleCompleted: { service.toggleCompleted(task) },
                            focusChanged: { focused in
                                if focused { focusedItemID = item.id }
                                else if focusedItemID == item.id { focusedItemID = nil }
                            })
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .help(service.checklistTitle(for: item))
                        .accessibilityIdentifier("checklist-title-\(item.id)")
                        Button { remove(item) } label: {
                            Image(systemName: "xmark").font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help(strings["Удалить подзадачу"])
                        .accessibilityLabel(strings["Удалить подзадачу"])
                        .accessibilityIdentifier("delete-checklist-item-\(item.id)")
                    }
                    if service.checklistDrafts[item.id] != nil {
                        Button(strings["Повторить сохранение текста"]) {
                            service.renameChecklistItem(item, to: service.checklistTitle(for: item))
                        }.font(.caption)
                    }
                }
                .animation(PlannerMotion.animation(.feedback, reduceMotion: reduceMotion), value: item.isCompleted)
                .transition(.opacity)
                .id(item.id)
            }
            Button { addItem(nil) } label: {
                Label(strings["Добавить подзадачу"], systemImage: "plus")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    // Вся строка, включая прозрачные отступы, принимает нажатие.
                    .contentShape(Rectangle())
            }
            // Штатная borderless-кнопка принимает клик и при активном поле подзадачи.
            .buttonStyle(.borderless).foregroundStyle(PlannerStyle.accent)
            .accessibilityIdentifier("append-checklist-item-button")
        }
        .animation(PlannerMotion.animation(reduceMotion: reduceMotion), value: items.map(\.id))
        .onChange(of: items.map(\.id)) { previous, current in
            for id in previous where !current.contains(id) {
                editorStore.removeChecklistItem(taskID: task.id, itemID: id)
            }
        }
        .task(id: focusItemID) {
            guard let focusItemID, items.contains(where: { $0.id == focusItemID }) else { return }
            // Сначала SwiftUI вставляет поле, затем можно передать ему клавиатурный фокус.
            await Task.yield()
            guard !Task.isCancelled else { return }
            requestedFocusID = focusItemID
        }
    }

    private func submit(_ item: TaskChecklistItem) {
        let title = service.checklistTitle(for: item)
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Enter на пустом пункте завершает ввод списка, не оставляя пустую подзадачу.
            if service.deleteChecklistItem(item) { focusedItemID = nil; requestedFocusID = nil }
        } else if service.renameChecklistItem(item, to: title) {
            addItem(item)
        }
    }

    private func remove(_ item: TaskChecklistItem) {
        let index = items.firstIndex { $0.id == item.id }
        let neighbor = index.flatMap { index in
            index + 1 < items.count ? items[index + 1].id : (index > 0 ? items[index - 1].id : nil)
        }
        let wasFocused = focusedItemID == item.id
        if service.deleteChecklistItem(item), wasFocused { requestedFocusID = neighbor }
    }
}
