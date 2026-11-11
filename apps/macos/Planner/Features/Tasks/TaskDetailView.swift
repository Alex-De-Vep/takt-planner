import SwiftUI

/// Заголовок и описание прокручиваются вместе; нативные редакторы принадлежат документам.
struct TaskDetailView: View {
    @Environment(\.translations) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: PlannerTask
    let service: TaskService
    let now: Date
    let focusTitle: Bool
    let toggleToday: () -> Void
    let editorStore: TaskEditorStore
    let calendar: CalendarService
    let openEvent: (TaskEventLink) -> Void
    let checklistFocusID: UUID?
    let addChecklistItem: (TaskChecklistItem?) -> Void
    @State private var titleFocused = false
    @State private var descriptionFocused = false
    @State private var unavailableLinks: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            // Название папки и меню вынесены в шапку окна: здесь начинаются действия самой задачи.
            HStack(spacing: 10) {
                TaskActionButton(title: strings["Выполнено"], symbol: task.isCompleted ? "checkmark.circle.fill" : "circle", active: task.isCompleted, isCompletion: true) {
                    service.toggleCompleted(task)
                }
                .help(task.isCompleted ? strings["Вернуть в работу · ⌘↩"] : strings["Отметить выполненной · ⌘↩"])
                .accessibilityIdentifier("complete-task-button")
                TaskActionButton(title: strings["На сегодня"], symbol: task.isFocused(on: now) ? "star.fill" : "star", active: task.isFocused(on: now)) {
                    toggleToday()
                }
                .help(task.isFocused(on: now) ? strings["Убрать из «Сегодня» · ⇧⌘S"] : strings["Поставить на сегодня · ⇧⌘S"])
                .accessibilityIdentifier("today-task-button")
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .background(PlannerStyle.paper)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(task.createdAt, format: .dateTime.day().month(.wide).year().hour().minute())
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                        PlainTextTaskEditor(taskID: task.id, isTitle: true, store: editorStore,
                            text: Binding(get: { service.titleDrafts[task.id] ?? task.title }, set: { service.rename(task, to: $0) }),
                            requestFocus: $titleFocused, placeholder: strings["Название задачи"],
                            submit: { descriptionFocused = true }, toggleCompleted: { service.toggleCompleted(task) })
                            .id(task.id.uuidString + ".title")
                        PlainTextTaskEditor(taskID: task.id, isTitle: false, store: editorStore,
                            text: Binding(get: { service.description(for: task) }, set: { service.updateDescription(task, text: $0) }),
                            requestFocus: $descriptionFocused, placeholder: strings["Описание задачи"],
                            toggleCompleted: { service.toggleCompleted(task) },
                            minimumHeight: task.orderedChecklistItems.isEmpty ? nil : 44)
                            .id(task.id.uuidString + ".description")
                        if service.descriptionDrafts[task.id] != nil || service.titleDrafts[task.id] != nil {
                            Button(strings["Повторить сохранение текста"]) {
                                if let title = service.titleDrafts[task.id] { service.rename(task, to: title) }
                                service.updateDescription(task, text: service.description(for: task))
                            }
                        }
                        if !task.orderedChecklistItems.isEmpty {
                            TaskChecklistView(task: task, service: service, editorStore: editorStore, focusItemID: checklistFocusID, addItem: addChecklistItem)
                                .id(task.id.uuidString + ".checklist")
                                .transition(.opacity)
                        }
                        if !(task.eventLinks ?? []).isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(strings["Запланировано"]).font(.headline)
                                ForEach((task.eventLinks ?? []).sorted { $0.lastStart < $1.lastStart }) { link in
                                    Button { openEvent(link) } label: {
                                        HStack {
                                            Image(systemName: "calendar")
                                            VStack(alignment: .leading) {
                                                Text(link.lastTitle).lineLimit(2)
                                                Text(link.lastStart, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                                if unavailableLinks.contains(link.id) {
                                                    Text(strings["Событие недоступно"]).font(.caption).foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right").font(.caption)
                                        }
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.vertical, 12)
                                .transition(.opacity)
                        }
                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 32)
                    .animation(PlannerMotion.animation(reduceMotion: reduceMotion), value: task.orderedChecklistItems.isEmpty)
                    .animation(PlannerMotion.animation(reduceMotion: reduceMotion), value: (task.eventLinks ?? []).map(\.id))
                }
                .task(id: checklistFocusID) {
                    guard let checklistFocusID, task.orderedChecklistItems.contains(where: { $0.id == checklistFocusID }) else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scroll.scrollTo(checklistFocusID, anchor: .center)
                }
            }
        }
        .background(PlannerStyle.paper.ignoresSafeArea(.container, edges: .top))
        .task(id: task.id) { descriptionFocused = false; titleFocused = focusTitle }
        .task(id: "\(task.id):\(calendar.revision):\((task.eventLinks ?? []).map(\.id))") {
            unavailableLinks = Set((task.eventLinks ?? []).filter {
                calendar.resolve(identifier: $0.eventIdentifier, externalIdentifier: $0.externalIdentifier) == nil
            }.map(\.id))
        }
    }
}
