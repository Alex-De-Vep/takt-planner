import SwiftUI

/// Состояние всплывающего окна принадлежит выбранной задаче, а не общей панели инструментов.
struct TaskDeadlineToolbarButton: View {
    @Environment(\.translations) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: PlannerTask
    let service: TaskService
    @State private var isEditing = false

    var body: some View {
        Button { isEditing.toggle() } label: {
            Image(systemName: "clock")
                .font(.system(size: 17))
                .foregroundStyle(task.deadline == nil ? Color.primary : PlannerStyle.accent)
                .frame(width: WorkspaceToolbarButtonSurface.diameter, height: WorkspaceToolbarButtonSurface.diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(PlannerMotion.animation(.feedback, reduceMotion: reduceMotion), value: task.deadline != nil)
        .help(strings["Срок задачи"])
        .accessibilityLabel(strings["Срок задачи"])
        .accessibilityIdentifier("task-deadline-button")
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            TaskDeadlineEditor(deadline: task.deadline, save: { deadline in
                guard service.setDeadline(task, to: deadline) else { return false }
                isEditing = false
                return true
            }, cancel: { isEditing = false })
        }
        .onDisappear { isEditing = false }
    }
}

struct TaskDeadlineEditor: View {
    @Environment(\.translations) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let deadline: TaskDeadline?
    let save: (TaskDeadline?) -> Bool
    let cancel: () -> Void
    @State private var draft: TaskDeadlineDraft
    @State private var saveFailed = false
    private let calendarScale: CGFloat = 1.2

    init(deadline: TaskDeadline?, save: @escaping (TaskDeadline?) -> Bool, cancel: @escaping () -> Void) {
        self.deadline = deadline
        self.save = save
        self.cancel = cancel
        _draft = State(initialValue: TaskDeadlineDraft(deadline: deadline))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(strings["Срок задачи"]).font(.headline)
            CalendarPickerZoomLayout(scale: calendarScale) {
                DatePicker(strings["Дата срока"], selection: Binding(get: { draft.selection }, set: { draft.chooseDay($0) }),
                           displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .fixedSize()
                    .scaleEffect(calendarScale, anchor: .topLeading)
                    .accessibilityIdentifier("task-deadline-date")
            }
            .frame(maxWidth: .infinity)
            HStack {
                Button(strings["Сегодня"]) { draft.chooseDay(.now) }
                    .accessibilityIdentifier("task-deadline-today")
                Button(strings["Завтра"]) {
                    if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) { draft.chooseDay(tomorrow) }
                }
                .accessibilityIdentifier("task-deadline-tomorrow")
            }
            Divider()
            Toggle(strings["Указать время"], isOn: $draft.includesTime)
                .toggleStyle(.switch)
                .accessibilityIdentifier("task-deadline-has-time")
            if draft.includesTime {
                DatePicker(strings["Время срока"], selection: $draft.selection, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.stepperField)
                    .accessibilityIdentifier("task-deadline-time")
                    .transition(.opacity)
            }
            if saveFailed {
                Text(strings["Не удалось сохранить срок. Попробуйте ещё раз."])
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            if deadline != nil {
                Button(strings["Убрать срок"]) { saveFailed = !save(nil) }
                    .accessibilityIdentifier("task-deadline-remove")
            }
            HStack {
                Spacer()
                Button(strings["Отмена"], action: cancel).keyboardShortcut(.cancelAction)
                Button(strings["Сохранить"]) { saveFailed = !save(draft.value()) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("task-deadline-save")
            }
        }
        .padding(18)
        .frame(width: 280)
        .animation(PlannerMotion.animation(reduceMotion: reduceMotion), value: draft.includesTime)
        .animation(PlannerMotion.animation(reduceMotion: reduceMotion), value: saveFailed)
    }
}

struct TaskDeadlineTag: View {
    @Environment(\.translations) private var strings
    @Environment(\.locale) private var locale
    let deadline: TaskDeadline
    let now: Date
    let isCompleted: Bool

    var body: some View {
        let title = deadline.label(now: now, strings: strings, locale: locale)
        Label(title, systemImage: "clock")
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(isCompleted ? .secondary : .primary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.primary.opacity(0.07), in: Capsule())
            .help(strings["Срок задачи"] + ": " + title)
            .accessibilityLabel(strings["Срок задачи"] + ": " + title)
            .accessibilityIdentifier("task-deadline-tag")
    }
}
