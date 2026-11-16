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
    @State private var showsNotes = false
    @State private var noteScope = NoteScope.folder
    @State private var selectedNoteID: UUID?
    @State private var noteSearch = ""
    @State private var showNoteFolderPicker = false
    @State private var createNoteAfterFolderCreation = false

    private var visibleNotes: [PlannerNote] {
        service.notes.notes.filter { note in
            let deleted = note.deletedAt != nil
            guard deleted == (noteScope == .trash) else { return false }
            guard noteScope != .folder || (filter.acceptsNotes && note.folder == filter.id) else { return false }
            return noteSearch.isEmpty || note.title.localizedStandardContains(noteSearch) || note.text.localizedStandardContains(noteSearch)
        }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.updatedAt > $1.updatedAt
        }
    }
    private var selectedNote: PlannerNote? { visibleNotes.first { $0.id == selectedNoteID } }
    private var noteHeading: String {
        if noteScope == .trash { return strings["Недавно удалённые"] }
        if noteScope == .all { return strings["Все заметки"] }
        return filter.title(in: folders, using: strings)
    }
    private var contentMode: Binding<Bool> {
        Binding(get: { showsNotes }, set: { value in
            service.flushEditorText()
            service.notes.flush()
            showsNotes = value && (noteScope != .folder || filter.acceptsNotes)
        })
    }
    private var noteSelection: Binding<UUID?> {
        Binding(get: { selectedNoteID }, set: { value in
            service.notes.flush()
            selectedNoteID = value
        })
    }
    private func createNote() {
        guard noteScope == .folder, filter.acceptsNotes else {
            showNoteFolderPicker = true
            return
        }
        noteScope = .folder
        noteSearch = ""
        selectedNoteID = service.notes.create(folder: filter.id)
    }


    private var filter: TaskFilter { state.filter ?? .inbox }
    private var taskList: TaskListSnapshot {
        TaskListSnapshot(tasks: tasks, filter: filter, search: state.search, now: now)
    }
    private var selectedTask: PlannerTask? { showsNotes ? nil : tasks.first { $0.id == state.selectedTaskID } }

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
            .onChange(of: state.selectedTaskID) { previous, _ in
                if let previous { service.flushEditorText(taskID: previous) }
                checklistFocusID = nil
            }
            // Прежние активные звёзды сохраняются и при открытии окна, и при загрузке задач из облака.
            .onChange(of: tasks.map(\.focusDay), initial: true) { service.preserveLegacyTodayMarks(in: tasks) }
            // Сроки отображаются относительно текущей даты и часового пояса.
            .onChange(of: scenePhase) { if scenePhase == .active { now = .now } }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)) { _ in now = .now }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: DispatchQueue.main)) { _ in now = .now }
            .onChange(of: notifications.openRevision) { openNotificationTask() }
            .onAppear { openNotificationTask() }
            .onChange(of: visibleNotes.map(\.id)) {
                if !visibleNotes.contains(where: { $0.id == selectedNoteID }) { selectedNoteID = nil }
            }
            .onChange(of: scenePhase) { if scenePhase != .active { service.notes.flush() } }
            .onDisappear {
                service.notes.flush()
                service.flushEditorText()
                _ = assistant.flushDrafts()
            }
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
            search: showsNotes ? $noteSearch : searchText,
            searchTitle: strings["Поиск"],
            clearSearchTitle: strings["Очистить поиск"],
            activeRightPanel: preferences.rightPanel,
            toggleAssistant: { preferences.rightPanel = preferences.rightPanel == .assistant ? nil : .assistant },
            toggleCalendarPanel: { preferences.rightPanel = preferences.rightPanel == .calendar ? nil : .calendar },
            newFolderTitle: strings["Новая папка"],
            toggleSidebarTitle: strings[isSidebarVisible ? "Скрыть папки" : "Показать папки"],
            folderTitle: showsNotes ? noteHeading : filter.title(in: folders, using: strings),
            taskCountTitle: showsNotes ? strings.format("Заметок: %d", visibleNotes.count) : strings.format("Задач: %d", taskList.activeCount),
            newTaskTitle: strings[showsNotes ? "Новая заметка" : "Новая задача"],
            newChecklistItemTitle: strings["Добавить подзадачу"],
            taskActionsTitle: strings["Действия с задачей"],
            deadlineTitle: strings["Срок задачи"],
            hasSelectedTask: selectedTask != nil,
            taskListKey: TaskListAnimationKey(filter: filter, search: state.search,
                active: taskList.activeTasks.map(\.id), completed: taskList.completedTasks.map(\.id)),
            newFolder: newFolder,
            newTask: showsNotes ? createNote : newTask,
            newChecklistItem: { addChecklistItem(after: nil) }
        ) {
            SidebarView(selection: filterSelection, folders: folders, tasks: tasks, now: now, renameFolder: { folder in
                editingFolder = folder; showFolderEditor = true
            }, deleteFolder: { deletingFolder = $0 }, receiveTask: receiveTask, taskDrag: taskDrag,
                notesActive: showsNotes, notes: service.notes.notes, showAllNotes: {
                    noteScope = .all; contentMode.wrappedValue = true; noteSearch = ""
                }, showDeletedNotes: {
                    noteScope = .trash; contentMode.wrappedValue = true; noteSearch = ""
                }, receiveNote: { id, destination in
                    guard destination.acceptsNotes else { return }
                    service.notes.update(id) { $0.folder = destination.id }
                    service.notes.flush()
                })
        } tasks: {
            workspaceList
        } detail: {
            if showsNotes {
                if let note = selectedNote {
                    NoteDetailView(note: note, store: service.notes).id(note.id)
                } else {
                    ContentUnavailableView(strings["Выберите заметку"], systemImage: "note.text",
                        description: Text(strings["Создайте заметку или откройте её из списка."]))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let task = selectedTask {
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
                    folders: folders, selectedTask: selectedTask, selectedNote: showsNotes ? selectedNote : nil, filter: filter,
                    openEvent: { event in preferences.rightPanel = .calendar; calendarState.show(event) })
                    .opacity(preferences.rightPanel == .assistant ? 1 : 0)
                    .allowsHitTesting(preferences.rightPanel == .assistant)
                    .accessibilityHidden(preferences.rightPanel != .assistant)
            }
        }
        // Корневая split view занимает всю высоту окна; safe area учитывается внутри нативных колонок.
        .ignoresSafeArea(.container, edges: .top)
        .tint(PlannerStyle.accent)
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .focusedSceneValue(\.plannerActions, PlannerActions(newTask: showsNotes ? createNote : newTask, newFolder: newFolder, toggleToday: {
            if let task = selectedTask { toggleToday(task) }
        }, toggleCompleted: {
            if let task = selectedTask { service.toggleCompleted(task) }
        }, hasSelection: selectedTask != nil, createsNote: showsNotes))
    }

    private var workspaceList: some View {
        VStack(spacing: 0) {
            if noteScope == .folder && filter.acceptsNotes {
                WorkspaceModeSwitch(showsNotes: contentMode)
                    .padding(EdgeInsets(top: 10, leading: 13, bottom: 10, trailing: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                GeometryReader { geometry in
                    let width = geometry.size.width
                    // Обе страницы остаются на месте относительно друг друга. Двигается вся лента.
                    HStack(spacing: 0) {
                        tasksPage
                            .frame(width: width, height: geometry.size.height)
                            .allowsHitTesting(!showsNotes)
                            .disabled(showsNotes)
                            .accessibilityHidden(showsNotes)
                        notesPage
                            .frame(width: width, height: geometry.size.height)
                            .allowsHitTesting(showsNotes)
                            .disabled(!showsNotes)
                            .accessibilityHidden(!showsNotes)
                    }
                    .offset(x: showsNotes ? -width : 0)
                    .animation(PlannerMotion.animation(.content, reduceMotion: reduceMotion), value: showsNotes)
                    .frame(width: width, height: geometry.size.height, alignment: .leading)
                    .clipped()
                }
            } else if showsNotes {
                notesPage
            } else {
                tasksPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notesPage: some View {
        NoteListView(store: service.notes, notes: visibleNotes, folders: folders,
                     selection: noteSelection, trash: noteScope == .trash, create: createNote)
            .background(PlannerStyle.listBackground)
    }

    private var tasksPage: some View {
        TaskListView(selectedID: taskSelection,
                     isCompletedExpanded: Binding(get: { state.completedTasksExpanded }, set: { state.setCompletedTasksExpanded($0) }),
                     createdTaskID: state.createdTaskID,
                     search: state.search, filter: filter, snapshot: taskList, now: now,
                     create: newTask, toggleToday: toggleToday, toggleCompleted: { service.toggleCompleted($0) },
                     delete: { deletingTask = $0 }, deleteImmediately: deleteTask,
                     folders: folders, dragScopeID: service.dragScopeID, move: moveTask, taskDrag: taskDrag)
    }

    /// Диалоги вынесены отдельно: основной экран остаётся читаемым и быстро компилируется.
    private var workspaceWithDialogs: some View {
        splitView
        .sheet(isPresented: $showFolderEditor) {
            FolderEditor(folder: editingFolder, service: service) { folder in
                selectFilter(.folder(folder.id))
                if createNoteAfterFolderCreation {
                    showsNotes = true
                    createNote()
                }
            }
            .onDisappear { createNoteAfterFolderCreation = false }
        }
        .confirmationDialog(strings["Выберите папку для заметки"], isPresented: $showNoteFolderPicker, titleVisibility: .visible) {
            ForEach(folders) { folder in
                Button(folder.name) {
                    selectFilter(.folder(folder.id))
                    showsNotes = true
                    createNote()
                }
            }
            Button(strings["Новая папка"]) {
                editingFolder = nil
                createNoteAfterFolderCreation = true
                showFolderEditor = true
            }
            Button(strings["Отмена"], role: .cancel) {}
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
        } message: { Text(strings["Задачи останутся во «Входящих», а заметки — в разделе «Все заметки»."]) }
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
        showsNotes = false
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
        service.notes.flush()
        noteScope = .folder
        noteSearch = ""
        selectedNoteID = nil
        if !filter.acceptsNotes { showsNotes = false }
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

private struct WorkspaceModeSwitch: View {
    @Environment(\.translations) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var showsNotes: Bool

    private var tasksTitle: String { strings["Задачи"] }
    private var notesTitle: String { strings["Заметки"] }

    var body: some View {
        HStack(spacing: 0) {
            option(tasksTitle, notes: false, identifier: "tasks-mode")
            option(notesTitle, notes: true, identifier: "notes-mode")
        }
        .frame(width: 158)
        .background {
            GeometryReader { geometry in
                selection(width: geometry.size.width)
                    .foregroundStyle(PlannerStyle.color(light: 0x714BB0, dark: 0x7954B7))
            }
        }
        .overlay {
            // Белый текст следует за выделением, включая момент, когда оно проходит по буквам.
            HStack(spacing: 0) {
                label(tasksTitle)
                label(notesTitle)
            }
            .foregroundStyle(.white)
            .mask(alignment: .leading) {
                GeometryReader { geometry in
                    selection(width: geometry.size.width)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .animation(PlannerMotion.animation(.content, reduceMotion: reduceMotion), value: showsNotes)
        .padding(3)
        .glassEffect(.regular, in: Capsule())
    }

    private func selection(width: CGFloat) -> some View {
        let segmentWidth = width / 2
        return Capsule()
            .frame(width: segmentWidth)
            .offset(x: showsNotes ? segmentWidth : 0)
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 24)
    }

    private func option(_ title: String, notes: Bool, identifier: String) -> some View {
        Button { showsNotes = notes } label: {
            label(title).contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(showsNotes == notes ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}
