import SwiftUI
import PlannerLocalization

struct TaskListView: View {
    @Environment(\.translations) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selectedID: UUID?
    @Binding var isCompletedExpanded: Bool
    let createdTaskID: UUID?
    let search: String
    let filter: TaskFilter
    let snapshot: TaskListSnapshot
    let now: Date
    let create: () -> Void
    let toggleToday: (PlannerTask) -> Void
    let toggleCompleted: (PlannerTask) -> Void
    let delete: (PlannerTask) -> Void
    let deleteImmediately: (PlannerTask) -> Void
    let folders: [TaskFolder]
    let dragScopeID: UUID
    let move: (PlannerTask, TaskFilter) -> Void
    let taskDrag: TaskDragState

    @State private var displayedScope: Scope?
    @State private var selectionRevision = 0
    @State private var activeListAtTop = true
    @State private var dragSourceID = UUID()
    @State private var activeNativeFocus = TaskListNativeFocus()
    @State private var completedNativeFocus = TaskListNativeFocus()
    @FocusState private var focusedList: ListArea?

    private enum ListArea: Hashable { case active, completed }
    private struct Scope: Hashable {
        let filter: TaskFilter
        let search: String
    }
    private struct Rows: Equatable {
        let active: [UUID]
        let completed: [UUID]
    }
    private var scope: Scope { Scope(filter: filter, search: search) }
    private var rowIDs: Rows {
        Rows(active: snapshot.activeTasks.map(\.id), completed: snapshot.completedTasks.map(\.id))
    }
    private var rowAnimation: Animation? {
        // Поиск и переход между папками не должны анимировать каждую строку как удалённую задачу.
        displayedScope == scope ? PlannerMotion.animation(.listChange, reduceMotion: reduceMotion) : nil
    }
    private var tasks: [PlannerTask] { snapshot.tasks }
    private var selectedActiveID: UUID? {
        snapshot.activeTasks.first { $0.id == selectedID }?.id
    }
    private var selectedCompletedID: UUID? {
        snapshot.completedTasks.first { $0.id == selectedID }?.id
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    // Внутри папки List сохраняет идентичность и анимирует даже удаление последней строки.
                    activeList.frame(maxHeight: .infinity)
                    if !snapshot.completedTasks.isEmpty {
                        completedPanel(availableHeight: geometry.size.height)
                            .transition(.opacity)
                    }
                }
                // Новая папка получает свою область прокрутки с начала, включая первый заголовок группы.
                // Изменения задач и звёздочек в открытой папке не пересоздают списки.
                .id(filter)
                if tasks.isEmpty { emptyState.transition(.opacity) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PlannerStyle.listBackground)
        .animation(rowAnimation, value: rowIDs)
        .onChange(of: scope, initial: true) { _, value in displayedScope = value }
        .onDisappear {
            taskDrag.finish(sourceViewID: dragSourceID)
            activeNativeFocus.transitions.detach()
            completedNativeFocus.transitions.detach()
        }
        .onChange(of: rowIDs.active, initial: true) { _, ids in
            activeNativeFocus.transitions.update(ids: ids, scope: scope, animated: rowAnimation != nil)
        }
        .onChange(of: rowIDs.completed, initial: true) { _, ids in
            completedNativeFocus.transitions.update(ids: ids, scope: scope, animated: rowAnimation != nil)
        }
        .onChange(of: rowIDs.completed.isEmpty) { _, isEmpty in
            // Исчезнувший пустой раздел при следующем появлении снова свёрнут.
            if isEmpty { isCompletedExpanded = false }
        }
        .onChange(of: scope) {
            activeNativeFocus.transitions.update(ids: rowIDs.active, scope: scope, animated: false)
            completedNativeFocus.transitions.update(ids: rowIDs.completed, scope: scope, animated: false)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(search.isEmpty ? strings["Пока нет задач"] : strings["Ничего не найдено"], systemImage: search.isEmpty ? filter.symbol : "magnifyingglass")
        } description: {
            Text(!search.isEmpty ? strings["Попробуйте другое название."] : filter == .today ? strings["Добавляйте задачи на сегодня с помощью звёздочки."] : strings["Создайте первую задачу в этом разделе."])
        } actions: {
            if search.isEmpty { Button(strings["Создать задачу"], action: create).accessibilityIdentifier("empty-create-task-button") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var activeList: some View {
        ScrollViewReader { proxy in
            List(selection: selection(in: snapshot.activeTasks, area: .active)) {
                ForEach(snapshot.activeSections) { section in
                    if let title = section.title(using: strings) {
                        Section {
                            rows(section.tasks, area: .active)
                        } header: {
                            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    } else {
                        rows(section.tasks, area: .active)
                    }
                }
            }
            .modifier(TaskListAppearance())
            // Анимация задаётся непосредственно List, который выполняет нативные вставки и удаления строк.
            .animation(rowAnimation, value: rowIDs.active)
            .focused($focusedList, equals: .active)
            // Delete и Forward Delete действуют только в списке с фокусом, а не в редакторе задачи.
            .onDeleteCommand(perform: deleteSelection(in: snapshot.activeTasks))
            .accessibilityIdentifier("task-list")
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y <= 1
            } action: { _, atTop in
                activeListAtTop = atTop
            }
            .onChange(of: selectedActiveID, initial: true) { previous, id in
                guard let id else { return }
                if id == createdTaskID {
                    // Не прокручиваем уже видимую первую строку во время анимированной вставки.
                    guard !activeListAtTop else { return }
                    withAnimation(rowAnimation) { proxy.scrollTo(id, anchor: .top) }
                } else {
                    // После удаления сосед занимает освобождённое место без принудительной прокрутки поверх анимации.
                    if displayedScope == scope, let previous, !rowIDs.active.contains(previous) { return }
                    proxy.scrollTo(id)
                }
            }
            // Стрелки переходят в выполненные только после ручного раскрытия раздела.
            .onKeyPress(.downArrow) {
                guard isCompletedExpanded,
                      selectedID == snapshot.activeTasks.last?.id,
                      let first = snapshot.completedTasks.first else { return .ignored }
                withImmediateNavigationUpdate {
                    selectedID = first.id
                    focusedList = .completed
                }
                return .handled
            }
        }
    }

    private func completedPanel(availableHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                // Сворачивание не закрывает задачу, уже открытую в правой колонке.
                isCompletedExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                        .rotationEffect(.degrees(isCompletedExpanded ? 90 : 0))
                    Text(strings["Выполнено"]).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(snapshot.completedTasks.count.formatted()).font(.system(size: 11)).monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18).frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(strings[isCompletedExpanded ? "Свернуть выполненные задачи" : "Показать выполненные задачи"])
            .accessibilityValue(strings[isCompletedExpanded ? "Развернуто" : "Свернуто"])
            .accessibilityIdentifier("completed-disclosure-button")

            if isCompletedExpanded {
                completedList.frame(height: completedListHeight(availableHeight: availableHeight))
                    .transition(.opacity)
            }
        }
        .clipped()
        .animation(PlannerMotion.animation(reduceMotion: reduceMotion), value: isCompletedExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("completed-tasks-panel")
    }

    private var completedList: some View {
        ScrollViewReader { proxy in
            // В список передаются все выполненные задачи текущего фильтра и поиска, без ограничения количества.
            List(selection: selection(in: snapshot.completedTasks, area: .completed)) {
                rows(snapshot.completedTasks, area: .completed)
            }
            .modifier(TaskListAppearance())
            .focused($focusedList, equals: .completed)
            .animation(rowAnimation, value: rowIDs.completed)
            .onDeleteCommand(perform: deleteSelection(in: snapshot.completedTasks))
            .accessibilityIdentifier("completed-task-list")
            .onDisappear { completedNativeFocus.transitions.detach() }
            .onChange(of: selectedCompletedID, initial: true) { previous, id in
                if displayedScope == scope, let previous, !rowIDs.completed.contains(previous) { return }
                if let id { proxy.scrollTo(id) }
            }
            .onKeyPress(.upArrow) {
                guard selectedID == snapshot.completedTasks.first?.id,
                      let last = snapshot.activeTasks.last else { return .ignored }
                selectedID = last.id
                focusedList = .active
                return .handled
            }
        }
    }

    @ViewBuilder
    private func rows(_ tasks: [PlannerTask], area: ListArea) -> some View {
        ForEach(tasks) { task in
            TaskRow(task: TaskRowContent(task, now: now, strings: strings), now: now, toggleToday: { toggleToday(task) },
                    toggleCompleted: { toggleCompleted(task) }, select: { selectRow(task.id, area: area) })
                .tag(task.id)
                .id(task.id)
                // Прежние отступы находятся внутри TaskRow и тоже принимают клик.
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.visible, edges: .bottom)
                .background(TaskRowSelectionSync(taskID: task.id, selectedID: $selectedID, revision: selectionRevision,
                    isEligible: {
                        // Уходящая анимированная строка не должна выбирать соседа вместо перемещённой задачи.
                        guard task.modelContext != nil, !task.isDeleted,
                              task.isCompleted == (area == .completed) else { return false }
                        return TaskListSnapshot(tasks: [task], filter: filter, search: search, now: now).taskIDs.contains(task.id)
                    }, nativeFocus: area == .active ? activeNativeFocus : completedNativeFocus))
                .onDrag {
                    // Удалённая модель ещё может участвовать в анимации ухода строки.
                    guard task.modelContext != nil, !task.isDeleted else { return NSItemProvider() }
                    let payload = TaskDragPayload(taskID: task.id, scopeID: dragScopeID)
                    withImmediateNavigationUpdate {
                        taskDrag.begin(payload: payload, sourceFolder: task.primaryFolder, sourceViewID: dragSourceID)
                        // Фокус уходит из папок сразу при начале drag, но открытая задача не меняется.
                        (area == .active ? activeNativeFocus : completedNativeFocus).takeFocus()
                        focusedList = area
                    }
                    return payload.provider()
                }
                .contextMenu {
                    TaskMoveMenu(task: task, folders: folders, move: { move(task, $0) })
                    Button(task.isFocused(on: now) ? strings["Убрать из «Сегодня»"] : strings["На сегодня"]) { toggleToday(task) }
                    Divider()
                    Button(strings["Удалить задачу…"], role: .destructive) { delete(task) }
                }
        }
    }

    private func selectRow(_ id: UUID, area: ListArea, focusList: Bool = true) {
        guard taskDrag.context == nil else { return }
        withImmediateNavigationUpdate {
            selectedID = id
            if focusList {
                focusedList = area
                // Повторный клик по уже открытой задаче тоже согласует нативное выделение списка.
                selectionRevision &+= 1
            }
        }
    }

    private func deleteSelection(in tasks: [PlannerTask]) -> (() -> Void)? {
        // Без выделения команда отключена. Клавиша удаляет сразу; меню запрашивает подтверждение отдельно.
        guard let task = tasks.first(where: { $0.id == selectedID }) else { return nil }
        return { deleteImmediately(task) }
    }

    private func selection(in tasks: [PlannerTask], area: ListArea) -> Binding<UUID?> {
        let ids = Set(tasks.map(\.id))
        return Binding(get: {
            selectedID.flatMap { ids.contains($0) ? $0 : nil }
        }, set: { id in
            // Две области используют один выбор. Снятие выделения старым List не сбрасывает новый выбор.
            // Исчезающий при сворачивании список также не должен повторно выбирать свою строку.
            guard area != .completed || isCompletedExpanded else { return }
            // Программное восстановление выбора не должно забирать курсор из редактора.
            if let id, ids.contains(id) {
                // AppKit после удаления сам предлагает соседнюю строку. Открываем её только явным кликом
                // (он приходит из TaskRow) или навигационной клавишей, а не обратной записью List.
                let event = NSApp.currentEvent
                let arrow = event?.type == .keyDown && [UInt16(123), 124, 125, 126].contains(event?.keyCode ?? 0)
                guard selectedID != nil || arrow else { return }
                selectRow(id, area: area, focusList: false)
            }
        })
    }

    private func completedListHeight(availableHeight: CGFloat) -> CGFloat {
        // Короткий список прилегает к низу; длинный прокручивается, оставляя место активным задачам.
        let available = max(0, availableHeight - 39)
        let limit = snapshot.activeTasks.isEmpty ? available : available * 0.45
        let rowsHeight = snapshot.completedTasks.reduce(CGFloat(0)) { $0 + ($1.deadline == nil ? 76 : 100) }
        return min(rowsHeight + 12, limit)
    }
}

/// Нативный inset-список даёт отступы и скруглённое выделение без дополнительной заливки строк.
private struct TaskListAppearance: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
            .scrollContentBackground(.hidden)
    }
}

/// Уходящая строка может оставаться на экране до конца перехода после удаления SwiftData-модели.
/// Для её отрисовки нужны только значения, а не доступ к уже удалённым связям модели.
struct TaskRowContent {
    let id: UUID
    let title: String
    let createdAt: Date
    let folderName: String
    let isCompleted: Bool
    let isFocused: Bool
    let deadline: TaskDeadline?

    init(_ task: PlannerTask, now: Date, strings: Translations) {
        id = task.id
        title = task.displayTitle(using: strings)
        createdAt = task.createdAt
        folderName = task.primaryFolder.title(in: task.folder.map { [$0] } ?? [], using: strings)
        isCompleted = task.isCompleted
        isFocused = task.isFocused(on: now)
        deadline = task.deadline
    }
}

private struct TaskRow: View {
    @Environment(\.translations) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: TaskRowContent
    let now: Date
    let toggleToday: () -> Void
    let toggleCompleted: () -> Void
    let select: () -> Void

    private var completionTitle: String {
        strings[task.isCompleted ? "Вернуть в работу" : "Отметить выполненной"]
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                HStack(spacing: 5) {
                    if task.isCompleted { Label(strings["Выполнено"], systemImage: "checkmark") }
                    else {
                        Text(task.createdAt, format: .dateTime.day().month(.twoDigits))
                        Text(task.folderName).lineLimit(1)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                if let deadline = task.deadline {
                    TaskDeadlineTag(deadline: deadline, now: now, isCompleted: task.isCompleted)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Текст и прозрачное пространство до кнопок имеют одну сплошную область открытия.
            .frame(minHeight: 54, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            Button(action: toggleCompleted) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "checkmark.circle")
                    .contentTransition(.opacity)
                    .font(.system(size: 15))
                    .foregroundStyle(task.isCompleted ? Color.green : Color.primary)
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(completionTitle)
            .accessibilityLabel(completionTitle + ": " + task.title)
            .accessibilityValue(strings[task.isCompleted ? "Выполнено" : "Не выполнено"])
            .accessibilityIdentifier("task-complete-\(task.id)")
            Button(action: toggleToday) {
                Image(systemName: task.isFocused ? "star.fill" : "star")
                    .contentTransition(.opacity)
                    .font(.system(size: 15))
                    // Отметка «Сегодня» всегда жёлтая; пустая звезда следует системному цвету выделения строки.
                    .foregroundStyle(task.isFocused ? Color.yellow : Color.primary)
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(task.isFocused ? strings["Убрать из «Сегодня»"] : strings["На сегодня"])
            .accessibilityLabel(strings["На сегодня"] + ": " + task.title)
            .accessibilityValue(strings[task.isFocused ? "Включено" : "Выключено"])
            .accessibilityIdentifier("task-star-\(task.id)")
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.vertical, 4)
        .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .contentShape(Rectangle())
        // Подложка принимает клики в отступах и промежутках. Она находится под кнопками
        // и не добавляет им родительский жест, который одновременно открывал бы задачу.
        .background {
            Color.clear.contentShape(Rectangle()).onTapGesture(perform: select)
        }
        .animation(PlannerMotion.animation(.feedback, reduceMotion: reduceMotion), value: task.isFocused)
        .animation(PlannerMotion.animation(.feedback, reduceMotion: reduceMotion), value: task.isCompleted)
        .animation(PlannerMotion.animation(reduceMotion: reduceMotion), value: task.deadline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-row-\(task.id)")
    }
}
