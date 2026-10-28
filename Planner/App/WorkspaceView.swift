import SwiftUI
import SwiftData

struct WorkspaceView: View {
    @Environment(\.translations) private var strings
    @Query(sort: \TaskFolder.sortOrder) private var folders: [TaskFolder]
    // SwiftData доставляет результат save отдельным обновлением: анимация нужна самому запросу,
    // иначе withAnimation вокруг сохранения может не попасть в транзакцию нативного List.
    @Query(sort: \PlannerTask.createdAt, order: .reverse,
           animation: .easeInOut(duration: PlannerMotion.Kind.listChange.duration)) private var tasks: [PlannerTask]
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var service: TaskService
    let calendar: CalendarService
    @Bindable var preferences: AppPreferences
    @Bindable var notifications: PlannerNotifications
    let taskDrag: TaskDragState
    let assistant: AssistantService
    @Query private var eventLinks: [TaskEventLink]
    @State private var calendarState = CalendarPanelState()
    @State private var editorStore = TaskEditorStore()
    @State private var state = WorkspaceState()
    @State private var isSidebarVisible = true
    @State private var isFullScreen = false
    @State private var now = Date.now
    @State private var editingFolder: TaskFolder?
    @State private var showFolderEditor = false
    @State private var deletingFolder: TaskFolder?
    @State private var deletingTask: PlannerTask?
    @State private var checklistFocusID: UUID?

    private var filter: TaskFilter { state.filter ?? .inbox }
    private var taskList: TaskListSnapshot {
        TaskListSnapshot(tasks: tasks, filter: filter, search: state.search, now: now)
    }
    private var selectedTask: PlannerTask? { tasks.first { $0.id == state.selectedTaskID } }

    // Запись через эти привязки сразу обновляет все связанные значения, без цепочки onChange.
    private var filterSelection: Binding<TaskFilter?> {
        Binding(get: { state.filter }, set: { if let filter = $0 { selectFilter(filter) } })
    }

    private var taskSelection: Binding<UUID?> {
        Binding(get: { state.selectedTaskID }, set: { state.selectTask($0) })
    }

    private var searchText: Binding<String> {
        Binding(get: { state.search }, set: { search in
            let snapshot = TaskListSnapshot(tasks: tasks, filter: filter, search: search, now: now)
            state.updateSearch(search, visibleIDs: snapshot.taskIDs)
        })
    }

    var body: some View {
        workspaceWithDialogs
            .transaction { transaction in
                if reduceMotion {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
            // В полном экране AppKit рисует фон, верхний отступ панелей и нижнюю границу toolbar.
            .toolbarBackgroundVisibility(isFullScreen ? .visible : .hidden, for: .windowToolbar)
            // Учитываем внешние изменения библиотеки и смену дня, не сбрасывая существующий выбор.
            .onChange(of: taskList.taskIDs) { previousIDs, visibleIDs in
                state.reconcileSelection(previousIDs: previousIDs, visibleIDs: visibleIDs)
            }
            .onChange(of: folders.map(\.id)) {
                if case .folder(let id) = filter, !folders.contains(where: { $0.id == id }) { selectFilter(.inbox) }
            }
            .onChange(of: state.selectedTaskID) { checklistFocusID = nil }
            // «Сегодня» пересчитывается при полуночи, смене часового пояса и возврате в приложение.
            .onChange(of: scenePhase) { if scenePhase == .active { now = .now } }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = .now }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in now = .now }
            .onChange(of: notifications.openRevision) { openNotificationTask() }
            .onAppear { openNotificationTask() }
            .task(id: calendar.revision) {
                for link in eventLinks {
                    if let event = calendar.resolve(identifier: link.eventIdentifier, externalIdentifier: link.externalIdentifier) {
                        service.refreshLink(link, event: event)
                    }
                }
            }
    }

    /// Три системные колонки macOS: папки, список и открытая задача.
    private var splitView: some View {
        NativeWorkspaceSplitView(
            isSidebarVisible: $isSidebarVisible,
            isFullScreen: $isFullScreen,
            isCalendarVisible: Binding(get: { preferences.rightPanel != nil }, set: { if !$0 { preferences.rightPanel = nil } }),
            calendarWidth: Binding(get: { preferences.rightPanel == .assistant ? preferences.assistantWidth : preferences.calendarWidth }, set: {
                if preferences.rightPanel == .assistant { preferences.assistantWidth = min(520, max(360, $0)) } else { preferences.calendarWidth = $0 }
            }),
            search: searchText,
            searchTitle: strings["Поиск"],
            clearSearchTitle: strings["Очистить поиск"],
            calendarTitle: strings[preferences.calendarOpen ? "Закрыть календарь" : "Открыть календарь"],
            calendarHeadingTitle: strings[preferences.rightPanel == .assistant ? "Помощник" : "Календарь"],
            assistantTitle: strings[preferences.rightPanel == .assistant ? "Закрыть помощника" : "Открыть помощника"],
            assistantActive: preferences.rightPanel == .assistant,
            toggleAssistant: { preferences.rightPanel = preferences.rightPanel == .assistant ? nil : .assistant },
            toggleCalendarPanel: { preferences.rightPanel = preferences.rightPanel == .calendar ? nil : .calendar },
            newFolderTitle: strings["Новая папка"],
            toggleSidebarTitle: strings[isSidebarVisible ? "Скрыть папки" : "Показать папки"],
            folderTitle: filter.title(in: folders, using: strings),
            taskCountTitle: strings.format("Задач: %d", taskList.activeCount),
            newTaskTitle: strings["Новая задача"],
            newChecklistItemTitle: strings["Добавить подзадачу"],
            taskActionsTitle: strings["Действия с задачей"],
            deadlineTitle: strings["Срок задачи"],
            hasSelectedTask: selectedTask != nil,
            taskListKey: TaskListAnimationKey(filter: filter, search: state.search,
                active: taskList.activeTasks.map(\.id), completed: taskList.completedTasks.map(\.id)),
            newFolder: newFolder,
            newTask: newTask,
            newChecklistItem: { addChecklistItem(after: nil) }
        ) {
            SidebarView(selection: filterSelection, folders: folders, tasks: tasks, now: now, renameFolder: { folder in
                editingFolder = folder; showFolderEditor = true
            }, deleteFolder: { deletingFolder = $0 }, receiveTask: receiveTask, taskDrag: taskDrag)
        } tasks: {
            TaskListView(selectedID: taskSelection,
                         isCompletedExpanded: Binding(get: { state.completedTasksExpanded }, set: { state.setCompletedTasksExpanded($0) }),
                         createdTaskID: state.createdTaskID,
                         search: state.search, filter: filter, snapshot: taskList, now: now,
                         create: newTask, toggleToday: toggleToday, toggleCompleted: { service.toggleCompleted($0) },
                         delete: { deletingTask = $0 }, deleteImmediately: deleteTask,
                         folders: folders, dragScopeID: service.dragScopeID, move: moveTask, taskDrag: taskDrag)
        } detail: {
            if let task = selectedTask {
                TaskDetailView(task: task, service: service, now: now, focusTitle: task.id == state.createdTaskID,
                    toggleToday: { toggleToday(task) }, editorStore: editorStore, calendar: calendar, openEvent: openEvent,
                    checklistFocusID: checklistFocusID, addChecklistItem: addChecklistItem)
            } else {
                ContentUnavailableView(strings["Выберите задачу"], systemImage: "square.and.pencil", description: Text(strings["Откройте задачу из списка или создайте новую."]))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(PlannerStyle.paper)
            }
        } taskActions: {
            if let task = selectedTask {
                TaskActionsMenu(task: task, folders: folders, move: { moveTask(task, to: $0) }, delete: { deletingTask = task })
            }
        } deadline: {
            if let task = selectedTask {
                TaskDeadlineToolbarButton(task: task, service: service).id(task.id)
            }
        } calendarContent: {
            ZStack {
                CalendarPanel(state: calendarState, preferences: preferences, service: calendar, taskService: service,
                          selectedTask: selectedTask, tasks: tasks, links: eventLinks,
                          openTask: { state.openLinkedTask($0, visibleIDs: taskList.taskIDs) },
                          isVisible: preferences.calendarOpen)
                    .opacity(preferences.rightPanel == .calendar ? 1 : 0)
                    .allowsHitTesting(preferences.rightPanel == .calendar)
                    .accessibilityHidden(preferences.rightPanel != .calendar)
                AssistantPanel(service: assistant, preferences: preferences, taskService: service, calendar: calendar,
                    folders: folders, selectedTask: selectedTask, filter: filter,
                    openTask: { state.openLinkedTask($0, visibleIDs: taskList.taskIDs) }, openEvent: { event in preferences.rightPanel = .calendar; calendarState.show(event) })
                    .opacity(preferences.rightPanel == .assistant ? 1 : 0)
                    .allowsHitTesting(preferences.rightPanel == .assistant)
                    .accessibilityHidden(preferences.rightPanel != .assistant)
            }
        }
        // Корневая split view занимает всю высоту окна; safe area учитывается внутри нативных колонок.
        .ignoresSafeArea(.container, edges: .top)
        .tint(PlannerStyle.accent)
        .frame(minWidth: 900, minHeight: 560)
        .focusedSceneValue(\.plannerActions, PlannerActions(newTask: newTask, newFolder: newFolder, toggleToday: {
            if let task = selectedTask { toggleToday(task) }
        }, toggleCompleted: {
            if let task = selectedTask { service.toggleCompleted(task) }
        }, hasSelection: selectedTask != nil))
    }

    /// Диалоги вынесены отдельно: основной экран остаётся читаемым и быстро компилируется.
    private var workspaceWithDialogs: some View {
        splitView
        .sheet(isPresented: $showFolderEditor) {
            FolderEditor(folder: editingFolder, service: service) { folder in selectFilter(.folder(folder.id)) }
        }
        .alert(strings["Не удалось сохранить"], isPresented: Binding(get: { service.error != nil }, set: { if !$0 { service.error = nil } })) {
            Button(strings["Понятно"], role: .cancel) { service.error = nil }
        } message: { Text(service.error?.message ?? "") }
        .alert(strings["Удалить папку?"], isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } })) {
            Button(strings["Удалить папку"], role: .destructive) {
                if let folder = deletingFolder, service.deleteFolder(folder) { selectFilter(.inbox) }
                deletingFolder = nil
            }
            Button(strings["Отмена"], role: .cancel) { deletingFolder = nil }
        } message: { Text(strings["Задачи из этой папки останутся во «Входящих»."]) }
        .alert(strings["Удалить задачу?"], isPresented: Binding(get: { deletingTask != nil }, set: { if !$0 { deletingTask = nil } })) {
            Button(strings["Удалить"], role: .destructive) {
                if let task = deletingTask { deleteTask(task) }
                deletingTask = nil
            }
            Button(strings["Отмена"], role: .cancel) { deletingTask = nil }
        } message: { Text(strings["Задача будет удалена с этого Mac."]) }
    }

    private func openNotificationTask() {
        guard let id = notifications.taskToOpen, let task = tasks.first(where: { $0.id == id }) else { return }
        state.openLinkedTask(task, visibleIDs: taskList.taskIDs)
        notifications.taskToOpen = nil
    }

    private func deleteTask(_ task: PlannerTask) {
        let id = task.id
        let previousSelection = state.selectedTaskID
        // Снимаем выбор до save: SwiftData и AppKit могут предложить соседа прямо во время сохранения.
        state.selectAfterDeletingTask(id)
        let deleted = withAnimation(PlannerMotion.animation(.listChange, reduceMotion: reduceMotion)) {
            service.delete(task)
        }
        if deleted {
            withImmediateNavigationUpdate {
                editorStore.remove(taskID: id)
            }
        } else if previousSelection == id {
            // При ошибке модель и её черновик остаются открытыми для повторной попытки.
            state.selectTask(id)
        }
    }

    private func newTask() {
        let window = NSApp.keyWindow
        let previousList = TaskListNativeFocus.prepareForTaskCreation(in: window)
        let task = withAnimation(PlannerMotion.animation(.listChange, reduceMotion: reduceMotion)) {
            service.createTask(in: filter, folders: folders)
        }
        if let task { state.selectCreatedTask(task.id) }
        else if let window, let previousList, window.firstResponder === window {
            // При неудачном сохранении возвращаем прежний фокус, не меняя выбор.
            window.makeFirstResponder(previousList)
        }
    }

    private func selectFilter(_ filter: TaskFilter) {
        state.selectFilter(filter)
    }

    private func moveTask(_ task: PlannerTask, to destination: TaskFilter) {
        let previous = taskList
        withImmediateNavigationUpdate {
            if service.move(task, to: destination, folders: folders) {
                state.selectAfterMovingTask(task.id, previous: previous, current: taskList)
            }
        }
    }

    private func receiveTask(_ payload: TaskDragPayload, to destination: TaskFilter) {
        guard let id = payload.taskID(in: service.dragScopeID),
              let task = tasks.first(where: { $0.id == id && !$0.isDeleted }) else { return }
        if destination == .today { service.markToday(task) }
        else if destination.isPrimaryFolder { moveTask(task, to: destination) }
    }

    private func toggleToday(_ task: PlannerTask) {
        let previousIDs = taskList.taskIDs
        withImmediateNavigationUpdate {
            service.toggleToday(task)
            // Та же транзакция сохраняет выбор либо переводит его на соседа, если строка исчезла.
            state.reconcileSelection(previousIDs: previousIDs, visibleIDs: taskList.taskIDs)
        }
    }

    private func newFolder() {
        editingFolder = nil
        showFolderEditor = true
    }

    private func addChecklistItem(after previous: TaskChecklistItem?) {
        guard let task = selectedTask, let item = service.addChecklistItem(to: task, after: previous) else { return }
        checklistFocusID = item.id
    }

    private func openEvent(_ link: TaskEventLink) {
        preferences.calendarOpen = true
        calendarState.select(link.lastStart)
        if let event = calendar.resolve(identifier: link.eventIdentifier, externalIdentifier: link.externalIdentifier) {
            service.refreshLink(link, event: event)
            calendarState.show(event)
        } else {
            calendarState.message = calendar.access == .full
                ? "Событие больше недоступно. Возможно, оно удалено или перемещено."
                : "Нет доступа к календарям."
        }
    }
}
