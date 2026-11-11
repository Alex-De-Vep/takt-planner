import AppKit
import SwiftUI
import Observation

/// Содержимое списка меняется внутри постоянного SwiftUI-корня, а не через замену rootView.
/// Так нативный List получает транзакцию обновления и сохраняет переходы своих строк.
@MainActor @Observable
final class WorkspaceTaskContent {
    var view = AnyView(EmptyView())
    @ObservationIgnored private var key: TaskListAnimationKey?

    func update(_ view: AnyView, key: TaskListAnimationKey?, transaction: Transaction, host: NSView) {
        if let old = self.key, let key, old.filter == key.filter, old.search == key.search, old != key,
           !transaction.disablesAnimations, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            TaskListTransitions.prepare(in: host)
        }
        self.key = key
        withTransaction(transaction) { self.view = view }
    }
}

/// Только идентичность результатов: ввод и смена фокуса не запускают переход всего списка.
struct TaskListAnimationKey: Equatable {
    let filter: TaskFilter
    let search: String
    let active: [UUID]
    let completed: [UUID]
}

struct WorkspaceTaskRoot: View {
    let content: WorkspaceTaskContent
    var body: some View { content.view }
}

/// Нативная оболочка окна: один NSSplitViewController связывает стеклянную панель с NSToolbar.
struct NativeWorkspaceSplitView<Sidebar: View, Tasks: View, Detail: View, TaskActions: View, Deadline: View, CalendarContent: View>: NSViewControllerRepresentable {
    @Binding var isSidebarVisible: Bool
    @Binding var isFullScreen: Bool
    @Binding var isCalendarVisible: Bool
    @Binding var calendarWidth: Double
    @Binding var search: String
    let searchTitle: String
    let clearSearchTitle: String
    let calendarTitle: String
    let calendarHeadingTitle: String
    let assistantTitle: String
    let activeRightPanel: RightPanel?
    let toggleAssistant: () -> Void
    let toggleCalendarPanel: () -> Void
    let newFolderTitle: String
    let toggleSidebarTitle: String
    let folderTitle: String
    let taskCountTitle: String
    let newTaskTitle: String
    let newChecklistItemTitle: String
    let taskActionsTitle: String
    let deadlineTitle: String
    let hasSelectedTask: Bool
    let taskListKey: TaskListAnimationKey
    let newFolder: () -> Void
    let newTask: () -> Void
    let newChecklistItem: () -> Void
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let tasks: () -> Tasks
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let taskActions: () -> TaskActions
    @ViewBuilder let deadline: () -> Deadline
    @ViewBuilder let calendarContent: () -> CalendarContent

    func makeNSViewController(context: Context) -> WorkspaceContainerController {
        let controller = WorkspaceContainerController()
        updateNSViewController(controller, context: context)
        return controller
    }

    func updateNSViewController(_ container: WorkspaceContainerController, context: Context) {
        // Каждый NSHostingController получает окружение окна: язык, локаль, SwiftData и системные действия.
        let controller = container.workspace
        controller.fullScreenChanged = { isFullScreen = $0 }
        controller.updateRightPanelToolbar(active: activeRightPanel, calendarTitle: calendarTitle,
            assistantTitle: assistantTitle, headingTitle: calendarHeadingTitle,
            toggleCalendar: toggleCalendarPanel, toggleAssistant: toggleAssistant)
        container.update(calendar: AnyView(calendarContent().environment(\.self, context.environment)),
                         visible: isCalendarVisible, width: calendarWidth, sidebarVisible: isSidebarVisible, panel: activeRightPanel,
                         minimumWidth: activeRightPanel == .assistant ? 360 : CalendarPanelLayout.minimumWidth,
                         maximumWidth: activeRightPanel == .assistant ? 520 : CalendarPanelLayout.maximumWidth,
                         widthChanged: { calendarWidth = $0 }, visibilityChanged: { isCalendarVisible = $0 })
        controller.updateSearch(text: search, title: searchTitle, clearTitle: clearSearchTitle, changed: { search = $0 })
        controller.updateDeadline(AnyView(deadline().environment(\.self, context.environment)),
                                  title: deadlineTitle, visible: hasSelectedTask)
        controller.update(
            sidebar: AnyView(sidebar().environment(\.self, context.environment)),
            tasks: AnyView(tasks().environment(\.self, context.environment)),
            detail: AnyView(detail().environment(\.self, context.environment)),
            taskActions: AnyView(taskActions().environment(\.self, context.environment)),
            transaction: context.transaction, taskListKey: taskListKey,
            isSidebarVisible: isSidebarVisible,
            newFolderTitle: newFolderTitle,
            toggleSidebarTitle: toggleSidebarTitle,
            folderTitle: folderTitle,
            taskCountTitle: taskCountTitle,
            newTaskTitle: newTaskTitle,
            newChecklistItemTitle: newChecklistItemTitle,
            taskActionsTitle: taskActionsTitle,
            hasSelectedTask: hasSelectedTask,
            newFolder: newFolder,
            newTask: newTask,
            newChecklistItem: newChecklistItem,
            sidebarVisibilityChanged: { isSidebarVisible = $0 }
        )
    }

    static func dismantleNSViewController(_ controller: WorkspaceContainerController, coordinator: ()) {
        controller.detachWindow()
    }
}

/// Контроллеры колонок создаются один раз: обновление данных не пересоздаёт списки и их выделение.
@MainActor
final class WorkspaceSplitController: NSSplitViewController, NSToolbarDelegate {
    private let sidebarHost = NSHostingController(rootView: AnyView(EmptyView()))
    private let taskContent = WorkspaceTaskContent()
    private lazy var tasksHost = NSHostingController(rootView: WorkspaceTaskRoot(content: taskContent))
    private let detailHost = WorkspaceDocumentController()
    private(set) var sidebarItem: NSSplitViewItem!
    private var tasksItem: NSSplitViewItem!
    private let workspaceToolbar = NSToolbar(identifier: "Planner.WorkspaceToolbar")
    private let folderButton = NSButton()
    private let sidebarButton = NSButton()
    private let newTaskButton = NSButton()
    private let checklistButton = NSButton()
    private let assistantButton = WorkspacePanelToggleButton()
    private let outerRightPanelSlot = WorkspaceRightPanelSlot()
    private let trailingRightPanelSlot = WorkspaceRightPanelSlot()
    private var rightPanelButtonMotion: WorkspaceRightPanelButtonMotion!
    private let rightPanelSwitchItem = NSToolbarItem(itemIdentifier: .plannerRightPanelSwitch)
    private var assistantSurface: WorkspaceToolbarButtonSurface!
    private var toggleAssistantAction: (() -> Void)?
    private var activeRightPanel: RightPanel?
    private var rightPanelCalendarTitle = ""
    private var rightPanelAssistantTitle = ""
    private let aiChatImage = WorkspaceAIChatSymbol.image()
    private let calendarImage = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 17, weight: .regular, scale: .medium))
    private let calendarButton = WorkspacePanelToggleButton()
    private let rightPanelToggleItem = NSToolbarItem(itemIdentifier: .plannerRightPanelToggle)
    private let calendarHeadingItem = NSToolbarItem(itemIdentifier: .plannerCalendarHeading)
    private let calendarHeading = WorkspaceCalendarHeadingView()
    private let searchToolbarItem = NSToolbarItem(itemIdentifier: .plannerSearch)
    private let toolbarSearch = WorkspaceToolbarSearchView()
    private var searchChangedAction: ((String) -> Void)?
    private let calendarGapItem = NSToolbarItem(itemIdentifier: .plannerCalendarGap)
    private let calendarGap = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private var calendarGapWidth: NSLayoutConstraint!
    private var calendarToolbarLayout: WorkspaceHeaderLayout.CalendarPlacement = .closed
    private var calendarOverlayWidth = CalendarPanelLayout.defaultWidth
    private var rightPanelMinimumWidth = CalendarPanelLayout.minimumWidth
    private var rightPanelMaximumWidth = CalendarPanelLayout.maximumWidth
    private var calendarSidebarItem: NSSplitViewItem?
    private var calendarInsetItem: NSSplitViewItem?
    private var calendarCollapsedObservation: NSKeyValueObservation?
    private var updatingCalendarSidebar = false
    private var calendarTransitionGeneration = 0
    private var calendarTargetCollapsed = true
    private var calendarIsAnimating = false
    private var calendarHeaderIsTransitioning = false
    private var calendarHeaderGeneration = 0
    var calendarWidthChanged: ((CGFloat) -> Void)?
    var calendarVisibilityChanged: ((Bool) -> Void)?
    var columnFramesChanged: (() -> Void)?
    var headerConfigurationChanged: (() -> Void)?
    var sidebarVisibilityWillChange: ((Bool) -> Void)?
    private var toggleCalendarAction: (() -> Void)?
    private let folderHeading = WorkspaceToolbarHeadingView()
    private let taskActionsHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let deadlineHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let folderToolbarItem = NSToolbarItem(itemIdentifier: .plannerNewFolder)
    private let sidebarToolbarItem = NSToolbarItem(itemIdentifier: .plannerToggleSidebar)
    private let headingToolbarItem = NSToolbarItem(itemIdentifier: .plannerFolderHeading)
    private let newTaskToolbarItem = NSToolbarItem(itemIdentifier: .plannerNewTask)
    private let checklistToolbarItem = NSToolbarItem(itemIdentifier: .plannerChecklist)
    private let deadlineToolbarItem = NSToolbarItem(itemIdentifier: .plannerDeadline)
    private let taskActionsToolbarItem = NSToolbarItem(itemIdentifier: .plannerTaskActions)
    private lazy var sidebarTrackingItem = NSTrackingSeparatorToolbarItem(
        identifier: .sidebarTrackingSeparator, splitView: splitView, dividerIndex: 0)
    private lazy var detailTrackingItem = NSTrackingSeparatorToolbarItem(
        identifier: .plannerDetailTrackingSeparator, splitView: splitView, dividerIndex: 1)
    private let fullScreenDetailDivider = WorkspaceToolbarDivider()
    private let calendarHeaderShadow = WorkspaceCalendarHeaderShadow()
    private var folderSurface: WorkspaceToolbarButtonSurface!
    private var sidebarSurface: WorkspaceToolbarButtonSurface!
    private var calendarSurface: WorkspaceToolbarButtonSurface!
    private var toolbarAlignmentScheduled = false
    private var collapsedObservation: NSKeyValueObservation?
    private var newFolderAction: (() -> Void)?
    private var newTaskAction: (() -> Void)?
    private var newChecklistItemAction: (() -> Void)?
    private var sidebarVisibilityChanged: ((Bool) -> Void)?
    private var isUpdatingVisibility = false
    private var hasSetInitialWidths = false
    private weak var attachedWindow: NSWindow?
    private var previousAppearance: WindowAppearance?
    private var fullScreenObservers: [NSObjectProtocol] = []
    private var isFullScreen = false
    var fullScreenChanged: ((Bool) -> Void)?

    var headerLayout: WorkspaceHeaderLayout {
        WorkspaceHeaderLayout(sidebarVisible: !sidebarItem.isCollapsed, fullScreen: isFullScreen,
                              calendarPlacement: calendarToolbarLayout, preferredHeadingWidth: folderHeading.preferredWidth)
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 300
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.titlebarSeparatorStyle = .none
        sidebarItem.holdingPriority = .defaultLow + 2

        tasksItem = NSSplitViewItem(contentListWithViewController: tasksHost)
        tasksItem.minimumThickness = 260
        tasksItem.maximumThickness = 420
        tasksItem.holdingPriority = .defaultLow + 1
        tasksItem.titlebarSeparatorStyle = .none
        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.minimumThickness = 320
        detailItem.titlebarSeparatorStyle = .none
        // Бумага документа продолжается под календарём; редактор остаётся в безопасной области.
        // Настройка относится только к правой части, геометрия папок и списка не меняется.
        detailItem.automaticallyAdjustsSafeAreaInsets = true
        addSplitViewItem(sidebarItem)
        addSplitViewItem(tasksItem)
        addSplitViewItem(detailItem)

        configureButton(folderButton, symbol: "folder.badge.plus", identifier: "new-folder-button", action: #selector(createFolder))
        configureButton(sidebarButton, symbol: "sidebar.left", identifier: "toggle-sidebar-button", action: #selector(toggleFolders))
        configureButton(newTaskButton, symbol: "square.and.pencil", identifier: "new-task-button", action: #selector(createTask))
        configureButton(checklistButton, symbol: "checklist", identifier: "add-checklist-item-button", action: #selector(createChecklistItem))
        configureButton(assistantButton, symbol: "bubble.left", identifier: "toggle-assistant-button", action: #selector(toggleAssistantPanel))
        assistantButton.image = aiChatImage
        configureButton(calendarButton, symbol: "calendar", identifier: "toggle-calendar-button", action: #selector(toggleCalendarPanel))
        calendarButton.image = calendarImage
        assistantSurface = WorkspaceToolbarButtonSurface(content: assistantButton)
        calendarSurface = WorkspaceToolbarButtonSurface(content: calendarButton)
        rightPanelButtonMotion = WorkspaceRightPanelButtonMotion(outer: outerRightPanelSlot, trailing: trailingRightPanelSlot,
            assistant: assistantSurface, calendar: calendarSurface)
        rightPanelSwitchItem.view = outerRightPanelSlot
        rightPanelToggleItem.view = trailingRightPanelSlot
        for item in [rightPanelSwitchItem, rightPanelToggleItem] {
            item.isBordered = false
            item.visibilityPriority = .high
        }
        calendarHeadingItem.view = calendarHeading
        calendarHeadingItem.isBordered = false
        calendarHeadingItem.visibilityPriority = .high
        calendarHeading.alphaValue = 0
        // Обычный toolbar item не сворачивает поиск в кнопку и не меняет внутреннюю геометрию поля.
        let searchField = toolbarSearch.searchField
        searchField.target = self
        searchField.action = #selector(searchTasks(_:))
        searchToolbarItem.view = toolbarSearch
        // Поле ввода сохраняет системную стеклянную капсулу, а кнопки получают отдельные круги.
        searchToolbarItem.isBordered = true
        searchToolbarItem.visibilityPriority = .high
        calendarGap.translatesAutoresizingMaskIntoConstraints = false
        calendarGapWidth = calendarGap.widthAnchor.constraint(equalToConstant: 288)
        NSLayoutConstraint.activate([calendarGapWidth, calendarGap.heightAnchor.constraint(equalToConstant: 1)])
        calendarGapItem.view = calendarGap
        calendarGapItem.isBordered = false
        calendarGapItem.visibilityPriority = .low
        newTaskButton.contentTintColor = NSColor(named: "AccentColor")
        folderSurface = configureButtonSurface(for: folderToolbarItem, content: folderButton)
        sidebarSurface = configureButtonSurface(for: sidebarToolbarItem, content: sidebarButton)
        folderSurface.presentation = .sidebar
        sidebarSurface.presentation = .sidebar
        headingToolbarItem.view = folderHeading
        // Это подпись раздела: явно отключаем стеклянную подложку, которую NSToolbar добавляет по умолчанию.
        headingToolbarItem.isBordered = false
        configureButtonSurface(for: newTaskToolbarItem, content: newTaskButton)
        configureButtonSurface(for: checklistToolbarItem, content: checklistButton)
        checklistToolbarItem.isHidden = true
        checklistButton.isEnabled = false
        configureButtonSurface(for: deadlineToolbarItem, content: deadlineHost)
        deadlineToolbarItem.isHidden = true
        deadlineToolbarItem.visibilityPriority = .high
        // Меню остаётся SwiftUI-компонентом с теми же действиями и окружением, но живёт в шапке окна.
        configureButtonSurface(for: taskActionsToolbarItem, content: taskActionsHost)
        folderToolbarItem.visibilityPriority = .high
        sidebarToolbarItem.visibilityPriority = .high
        headingToolbarItem.visibilityPriority = .high
        newTaskToolbarItem.visibilityPriority = .high
        // В тесном окне подзадачи доступны через стандартное меню переполнения toolbar.
        checklistToolbarItem.visibilityPriority = .low
        taskActionsToolbarItem.visibilityPriority = .high
        workspaceToolbar.delegate = self
        workspaceToolbar.displayMode = .iconOnly
        workspaceToolbar.allowsUserCustomization = false
        workspaceToolbar.autosavesConfiguration = false

        // Учитываем также сворачивание перетаскиванием разделителя, а не только кнопкой.
        collapsedObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.folderToolbarItem.isHidden = self.sidebarItem.isCollapsed
                self.updateSidebarButtons()
                self.headerConfigurationChanged?()
                guard !self.isUpdatingVisibility else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.sidebarVisibilityChanged?(!self.sidebarItem.isCollapsed)
                }
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    func update(sidebar: AnyView, tasks: AnyView, detail: AnyView, taskActions: AnyView, transaction: Transaction = Transaction(), taskListKey: TaskListAnimationKey? = nil, isSidebarVisible: Bool,
                newFolderTitle: String, toggleSidebarTitle: String, folderTitle: String, taskCountTitle: String,
                newTaskTitle: String, newChecklistItemTitle: String, taskActionsTitle: String, hasSelectedTask: Bool,
                newFolder: @escaping () -> Void, newTask: @escaping () -> Void, newChecklistItem: @escaping () -> Void,
                sidebarVisibilityChanged: @escaping (Bool) -> Void) {
        sidebarHost.rootView = sidebar
        taskContent.update(tasks, key: taskListKey, transaction: transaction, host: tasksHost.view)
        detailHost.updateContent(detail)
        taskActionsHost.rootView = taskActions
        newFolderAction = newFolder
        newTaskAction = newTask
        newChecklistItemAction = newChecklistItem
        self.sidebarVisibilityChanged = sidebarVisibilityChanged
        updateLabel(newFolderTitle, item: folderToolbarItem, button: folderButton, shortcut: " · ⇧⌘N")
        updateLabel(toggleSidebarTitle, item: sidebarToolbarItem, button: sidebarButton)
        updateLabel(newTaskTitle, item: newTaskToolbarItem, button: newTaskButton, shortcut: " · ⌘N")
        updateLabel(newChecklistItemTitle, item: checklistToolbarItem, button: checklistButton)
        checklistToolbarItem.isHidden = !hasSelectedTask
        checklistButton.isEnabled = hasSelectedTask
        let previousHeadingWidth = folderHeading.preferredWidth
        folderHeading.update(title: folderTitle, subtitle: taskCountTitle)
        if isFullScreen, previousHeadingWidth != folderHeading.preferredWidth { headerConfigurationChanged?() }
        headingToolbarItem.label = folderTitle
        headingToolbarItem.paletteLabel = folderTitle
        taskActionsToolbarItem.label = taskActionsTitle
        taskActionsToolbarItem.paletteLabel = taskActionsTitle
        taskActionsToolbarItem.isHidden = !hasSelectedTask
        isUpdatingVisibility = true
        if sidebarItem.isCollapsed == isSidebarVisible { sidebarItem.isCollapsed = !isSidebarVisible }
        isUpdatingVisibility = false
        folderToolbarItem.isHidden = !isSidebarVisible
        updateSidebarButtons()
        scheduleToolbarAlignment()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        attachWindowIfNeeded()
        updateWindowChrome()
        if !hasSetInitialWidths, splitViewItems.count >= 3, splitView.bounds.width > 0 {
            hasSetInitialWidths = true
            if !sidebarItem.isCollapsed { splitView.setPosition(240, ofDividerAt: 0) }
            splitView.setPosition(sidebarItem.isCollapsed ? 300 : 540, ofDividerAt: 1)
        }
        updateHeadingWidth()
        updateOverlayToolbarGap()
        rightPanelButtonMotion?.layoutChanged()
        columnFramesChanged?()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        attachWindowIfNeeded()
        updateWindowChrome()
        updateHeadingWidth()
        updateOverlayToolbarGap()
        rightPanelButtonMotion?.layoutChanged()
        columnFramesChanged?()
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        updateHeadingWidth()
        updateOverlayToolbarGap()
        rightPanelButtonMotion?.layoutChanged()
        columnFramesChanged?()
        if let calendarSidebarItem, !calendarSidebarItem.isCollapsed, !updatingCalendarSidebar,
           view.window?.inLiveResize != true,
           NSApp.currentEvent?.type == .leftMouseDragged {
            // Сужение самого окна тоже приходит как mouseDragged; оно не меняет выбранную ширину календаря.
            let width = calendarSidebarItem.viewController.view.frame.width
            if (CalendarPanelLayout.minimumWidth...CalendarPanelLayout.maximumWidth).contains(width) { calendarWidthChanged?(width) }
        }
    }

    /// Под шапкой документа продолжается бумага; вокруг боковых панелей остаётся общий фон списка.
    func documentColumnFrame(in view: NSView) -> NSRect {
        detailHost.view.convert(detailHost.view.bounds, to: view)
    }

    func taskColumnFrame(in view: NSView) -> NSRect {
        tasksHost.view.convert(tasksHost.view.bounds, to: view)
    }

    func dividerPosition(at index: Int, in view: NSView) -> CGFloat {
        // Берём границу самой arrangedSubview: у боковых панелей внутри есть отступы стекла.
        let columns = splitView.arrangedSubviews
        guard columns.indices.contains(index) else { return view.bounds.maxX }
        return splitView.convert(NSPoint(x: columns[index].frame.maxX, y: 0), to: view).x
    }

    func updatePanelHeaderLayout() {
        // Как и у папок, стекло календаря продолжается под собственной секцией шапки в обоих режимах.
        for item in [sidebarItem, calendarSidebarItem].compactMap({ $0 }) {
            if !item.allowsFullHeightLayout { item.allowsFullHeightLayout = true }
        }
    }

    @discardableResult func updateFullScreenMode(_ fullScreen: Bool) -> Bool {
        let changed = isFullScreen != fullScreen
        isFullScreen = fullScreen
        updatePanelHeaderLayout()
        // Каждая секция задаёт нижнюю границу toolbar, в том числе секция над стеклом папок.
        let separator: NSTitlebarSeparatorStyle = fullScreen ? .line : .none
        for item in splitViewItems where item.titlebarSeparatorStyle != separator {
            item.titlebarSeparatorStyle = separator
        }
        // Один разделитель остаётся привязан к списку во всех режимах окна.
        return changed
    }

    func headerBottom(in view: NSView) -> CGFloat {
        guard let window = attachedWindow else { return view.bounds.maxY }
        let contentTop = view.convert(window.contentLayoutRect, from: nil).maxY
        if contentTop < view.bounds.maxY - 1 { return contentTop }
        // При переходе в полный экран contentLayoutRect обновляется не одновременно с toolbar.
        let button = sidebarSurface.convert(sidebarSurface.bounds, to: view)
        let topInset = max(0, view.bounds.maxY - button.maxY)
        return min(view.bounds.maxY, button.minY - topInset)
    }

    func updateTaskColumnMinimumWidth(sidebarVisible: Bool) {
        let requested = WorkspaceHeaderLayout(sidebarVisible: sidebarVisible, fullScreen: isFullScreen,
                                             calendarPlacement: calendarToolbarLayout, preferredHeadingWidth: folderHeading.preferredWidth)
        // При раскрытии заранее освобождаем место папкам; после сворачивания расширяем список.
        let minimum = min(headerLayout.minimumTaskWidth, requested.minimumTaskWidth)
        if tasksItem.minimumThickness != minimum { tasksItem.minimumThickness = minimum }
    }

    private func updateSidebarButtons() {
        guard folderSurface != nil, sidebarSurface != nil else { return }
        updateSidebarToolbarSection()
        folderSurface.presentation = .sidebar
        sidebarSurface.presentation = sidebarItem.isCollapsed ? .circle : .sidebar
        let firstSurface = sidebarItem.isCollapsed ? sidebarSurface! : folderSurface!
        let firstButton = sidebarItem.isCollapsed ? sidebarButton : folderButton
        if firstSurface !== folderSurface { folderSurface.leadingInset = 0 }
        if firstSurface !== sidebarSurface { sidebarSurface.leadingInset = 0 }
        guard isFullScreen, firstButton.window != nil else { firstSurface.leadingInset = 0; return }
        // Учитываем собственный отступ AppKit, а не прибавляем ещё 10 pt поверх него.
        let baseLeading = firstButton.convert(firstButton.bounds, to: nil).minX - firstSurface.leadingInset
        firstSurface.leadingInset = min(10, max(0, 10 - baseLeading))
    }

    private func updateSidebarToolbarSection() {
        let index = workspaceToolbar.items.firstIndex { $0.itemIdentifier == .sidebarTrackingSeparator }
        if sidebarItem.isCollapsed {
            // isHidden убирает только линию: AppKit всё равно оставляет минимальную ширину секции.
            // Удаляем её границу целиком, сохраняя экземпляры кнопки, заголовка и поиска.
            if let index { workspaceToolbar.removeItem(at: index) }
        } else if index == nil,
                  let toggleIndex = workspaceToolbar.items.firstIndex(where: { $0.itemIdentifier == .plannerToggleSidebar }) {
            workspaceToolbar.insertItem(withItemIdentifier: .sidebarTrackingSeparator, at: toggleIndex + 1)
        }
    }

    private func scheduleToolbarAlignment() {
        guard !toolbarAlignmentScheduled else { return }
        toolbarAlignmentScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.toolbarAlignmentScheduled = false
            self.updateHeadingWidth()
            self.updateOverlayToolbarGap()
            self.rightPanelButtonMotion?.layoutChanged()
        }
    }

    private func updateHeadingWidth() {
        updateFullScreenDetailDivider()
        guard let window = attachedWindow, tasksHost.view.window === window else { return }
        let columnFrame = tasksHost.view.convert(tasksHost.view.bounds, to: nil)
        updateSidebarButtons()
        headingToolbarItem.isHidden = false
        guard let headingWindow = folderHeading.window else { return }
        // Полноэкранные кнопки принадлежат отдельному окну toolbar; приводим координаты к основному окну.
        let headingFrame = window.convertFromScreen(headingWindow.convertToScreen(folderHeading.convert(folderHeading.bounds, to: nil)))
        // В полном экране ширина считается по секции списка, а не по временной позиции toolbar во время перехода.
        let available = isFullScreen && !sidebarItem.isCollapsed ? columnFrame.width - 36
            : columnFrame.maxX - headingFrame.minX - 24
        let widths = headerLayout.contentWidths(available: available)
        // Название занимает только нужную ему ширину. Оставшееся место перед поиском
        // забирает гибкий отступ, поэтому поле прижато к правой границе своей секции.
        let headingWidth = min(widths.heading, max(WorkspaceHeaderLayout.minimumHeadingWidth, folderHeading.preferredWidth))
        let headingChanged = folderHeading.setAvailableWidth(headingWidth)
        let searchChanged = toolbarSearch.setAvailableWidth(widths.search)
        // Сначала стабилизируем размеры двух полей, затем выравниваем начало кнопок задачи.
        if headingChanged || searchChanged { scheduleToolbarAlignment(); return }
    }

    private func attachWindowIfNeeded() {
        guard let window = view.window, attachedWindow !== window else { return }
        detachWindow()
        attachedWindow = window
        previousAppearance = WindowAppearance(window: window)
        // Нужна настоящая NSToolbar: один toolbarStyle без неё оставляет компактный заголовок и малые углы.
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        // Фон вне стекла совпадает с бумагой документа. Под папками собственную подложку рисует контейнер.
        window.backgroundColor = .textBackgroundColor
        window.toolbar = workspaceToolbar
        workspaceToolbar.isVisible = true
        // Слушаем только своё окно: полноэкранный режим не должен менять другие окна приложения.
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateWindowChrome() }
            }
            fullScreenObservers.append(token)
        }
        updateWindowChrome(notify: true)
    }

    private func updateWindowChrome(notify: Bool = false) {
        guard let window = attachedWindow else { return }
        let fullScreen = window.styleMask.contains(.fullScreen)
        let changed = updateFullScreenMode(fullScreen)

        // Обновление toolbar-предпочтений SwiftUI может повторно применить оформление окна после attach.
        // Закрепляем прежнюю геометрию перед расчётом ширины заголовка папки и поиска.
        if window.toolbarStyle != .unified { window.toolbarStyle = .unified }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        // Полноэкранный toolbar выводится AppKit отдельно от contentView: фон и линию рисует сама система.
        // Непрозрачная системная шапка также сохраняет штатный верхний отступ стеклянной панели.
        let transparent = !fullScreen
        let separator: NSTitlebarSeparatorStyle = fullScreen ? .line : .none
        if window.titlebarAppearsTransparent != transparent { window.titlebarAppearsTransparent = transparent }
        if window.titlebarSeparatorStyle != separator { window.titlebarSeparatorStyle = separator }
        updateSidebarButtons()
        guard changed || notify else { return }
        // Пересчёт колонки календаря происходит до увеличения минимальной ширины списка задач.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.attachedWindow === window,
                  window.styleMask.contains(.fullScreen) == fullScreen else { return }
            self.headerConfigurationChanged?()
            self.fullScreenChanged?(fullScreen)
            self.scheduleToolbarAlignment()
        }
    }

    func detachWindow() {
        rightPanelButtonMotion?.cancel()
        fullScreenDetailDivider.removeFromSuperview()
        calendarHeaderShadow.removeFromSuperview()
        fullScreenObservers.forEach { NotificationCenter.default.removeObserver($0) }
        fullScreenObservers.removeAll()
        guard let window = attachedWindow else { return }
        // Возвращаем оформление только своего окна, не затрагивая настройки и другие окна приложения.
        if window.toolbar === workspaceToolbar, let previousAppearance { previousAppearance.restore(window) }
        attachedWindow = nil
        previousAppearance = nil
    }

    private func updateFullScreenDetailDivider() {
        guard isFullScreen, let window = attachedWindow else {
            fullScreenDetailDivider.removeFromSuperview()
            calendarHeaderShadow.removeFromSuperview()
            return
        }
        // В полном экране toolbar переносится на отдельную системную поверхность.
        // Рисуем только тонкую линию в общем предке наших кнопок, не перекрывая фон и стекло панелей.
        var ancestor = newTaskButton.superview
        while let candidate = ancestor, !folderHeading.isDescendant(of: candidate) {
            ancestor = candidate.superview
        }
        guard let canvas = ancestor, let toolbarWindow = canvas.window else { return }
        if fullScreenDetailDivider.superview !== canvas {
            canvas.addSubview(fullScreenDetailDivider)
        }
        let splitPoint = NSPoint(x: dividerPosition(at: 1, in: splitView), y: 0)
        let screenPoint = window.convertPoint(toScreen: splitView.convert(splitPoint, to: nil))
        let localPoint = canvas.convert(toolbarWindow.convertPoint(fromScreen: screenPoint), from: nil)
        let scale = max(1, toolbarWindow.backingScaleFactor)
        // Продолжаем нативную границу с её цветом и толщиной. Один физический пиксель
        // был тоньше разделителя NSSplitView на Retina и создавал заметный стык.
        fullScreenDetailDivider.sourceSplitView = splitView
        fullScreenDetailDivider.frame = NSRect(x: (localPoint.x * scale).rounded() / scale,
            y: canvas.bounds.minY, width: splitView.dividerThickness, height: canvas.bounds.height)
        updateCalendarHeaderShadow(in: canvas, window: window, toolbarWindow: toolbarWindow)
    }

    private func updateCalendarHeaderShadow(in canvas: NSView, window: NSWindow, toolbarWindow: NSWindow) {
        // Во время раскрытия граница секции и рамка стекла обновляются не одновременно.
        // Коррекция тени нужна только неподвижной панели, иначе узкий промежуточный контур мелькает у кнопки.
        guard calendarToolbarLayout == .column, !calendarIsAnimating, !updatingCalendarSidebar,
              let item = calendarSidebarItem, !item.isCollapsed else {
            calendarHeaderShadow.removeFromSuperview()
            return
        }
        let boundary = splitView.convert(NSPoint(x: dividerPosition(at: 2, in: splitView), y: 0), to: nil)
        let leading = canvas.convert(toolbarWindow.convertPoint(fromScreen: window.convertPoint(toScreen: boundary)), from: nil).x
        let panel = item.viewController.view
        let panelOnScreen = window.convertToScreen(panel.convert(panel.bounds, to: nil))
        let panelInToolbar = canvas.convert(toolbarWindow.convertFromScreen(panelOnScreen), from: nil)
        if calendarHeaderShadow.superview !== canvas { canvas.addSubview(calendarHeaderShadow) }
        calendarHeaderShadow.frame = NSRect(x: leading - WorkspaceCalendarHeaderShadow.reach,
            y: canvas.bounds.minY, width: max(0, canvas.bounds.maxX - leading + WorkspaceCalendarHeaderShadow.reach),
            height: canvas.bounds.height)
        calendarHeaderShadow.panelFrame = calendarHeaderShadow.convert(panelInToolbar, from: canvas)
        let baselineY = canvas.isFlipped ? canvas.bounds.maxY - 1 : canvas.bounds.minY
        calendarHeaderShadow.baselineFrame = calendarHeaderShadow.convert(
            NSRect(x: leading - WorkspaceCalendarHeaderShadow.reach, y: baselineY,
                   width: calendarHeaderShadow.bounds.width, height: 1), from: canvas)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Нативные разделители продолжают границы колонок через шапку и удерживают кнопки над задачей.
        // Фиксированный отступ отделяет подзадачи от создания задачи: у кнопок разные системные подложки.
        [.plannerNewFolder, .plannerToggleSidebar]
        + (sidebarItem.isCollapsed ? [] : [.sidebarTrackingSeparator])
        + [.plannerFolderHeading, .flexibleSpace, .plannerSearch, .plannerDetailTrackingSeparator,
         .plannerNewTask, .space, .plannerChecklist, .space, .plannerDeadline, .space, .plannerTaskActions]
        + [.flexibleSpace, .plannerRightPanelSwitch] + calendarToolbarIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.sidebarTrackingSeparator, .plannerCalendarBoundary, .plannerCalendarTrailingBoundary, .plannerCalendarGap, .plannerCalendarHeading]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .plannerNewFolder: return folderToolbarItem
        case .plannerToggleSidebar: return sidebarToolbarItem
        case .plannerFolderHeading: return headingToolbarItem
        case .plannerNewTask: return newTaskToolbarItem
        case .plannerChecklist: return checklistToolbarItem
        case .plannerDeadline: return deadlineToolbarItem
        case .plannerTaskActions: return taskActionsToolbarItem
        case .plannerRightPanelSwitch: return rightPanelSwitchItem
        case .plannerRightPanelToggle: return rightPanelToggleItem
        case .plannerCalendarHeading: return calendarHeadingItem
        case .plannerSearch: return searchToolbarItem
        case .plannerCalendarGap: return calendarGapItem
        case .plannerCalendarBoundary:
            let boundary = NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitView, dividerIndex: 2)
            // Граница всё время участвует в геометрии: isHidden менял конечное положение
            // кнопок после анимации. Её движение ведёт сам NSSplitView вместе с панелью.
            return boundary
        case .plannerCalendarTrailingBoundary:
            let boundary = NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitView, dividerIndex: 3)
            // Скрываем только черту: AppKit продолжает учитывать границу при построении стеклянной шапки.
            boundary.isHidden = true
            return boundary
        case .sidebarTrackingSeparator:
            // Разделитель привязан к нашей колонке, поэтому обе кнопки располагаются внутри её области.
            return sidebarTrackingItem
        case .plannerDetailTrackingSeparator:
            return detailTrackingItem
        default: return nil
        }
    }

    @objc private func createChecklistItem() { newChecklistItemAction?() }

    func updateDeadline(_ content: AnyView, title: String, visible: Bool) {
        deadlineHost.rootView = content
        deadlineToolbarItem.label = title
        deadlineToolbarItem.paletteLabel = title
        deadlineToolbarItem.toolTip = title
        deadlineToolbarItem.isHidden = !visible
    }

    func updateSearch(text: String, title: String, clearTitle: String, changed: @escaping (String) -> Void) {
        searchChangedAction = changed
        searchToolbarItem.label = title
        searchToolbarItem.paletteLabel = title
        let searchField = toolbarSearch.searchField
        searchField.placeholderString = title
        searchField.setAccessibilityLabel(title)
        toolbarSearch.clearButton.toolTip = clearTitle
        toolbarSearch.clearButton.setAccessibilityLabel(clearTitle)
        toolbarSearch.setText(text)
    }

    @objc private func searchTasks(_ sender: NSTextField) { searchChangedAction?(sender.stringValue) }

    private func configureButton(_ button: NSButton, symbol: String, identifier: String, action: Selector) {
        // Явный medium не даёт toolbar у раскрытой панели наследовать увеличенный масштаб символов.
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular, scale: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfiguration)
        button.symbolConfiguration = symbolConfiguration
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.controlSize = .regular
        button.bezelStyle = .accessoryBarAction
        button.borderShape = .circle
        // Круглая подсветка при наведении совпадает с общей стеклянной поверхностью кнопки.
        button.isBordered = true
        button.showsBorderOnlyWhileMouseInside = true
        button.setButtonType(.momentaryPushIn)
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(identifier)
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    @discardableResult private func configureButtonSurface(for item: NSToolbarItem, content: NSView) -> WorkspaceToolbarButtonSurface {
        let surface = WorkspaceToolbarButtonSurface(content: content)
        item.view = surface
        // Отключаем автоматическую овальную подложку: стекло уже нарисовано ровно одним кругом.
        item.isBordered = false
        return surface
    }

    private func updateLabel(_ title: String, item: NSToolbarItem, button: NSButton, shortcut: String = "") {
        item.label = title
        item.paletteLabel = title
        item.toolTip = title + shortcut
        button.toolTip = title + shortcut
        button.setAccessibilityLabel(title)
        // Обёртка кнопки не имеет target/action: задаём рабочее действие и для меню переполнения.
        let menuItem = NSMenuItem(title: title, action: button.action, keyEquivalent: "")
        menuItem.target = button.target
        item.menuFormRepresentation = menuItem
    }

    func updateRightPanelToolbar(active: RightPanel?, calendarTitle: String, assistantTitle: String,
                                 headingTitle: String, toggleCalendar: @escaping () -> Void,
                                 toggleAssistant: @escaping () -> Void) {
        let changed = activeRightPanel != active
        // Кнопки забираются из старых мест до перестройки секций и раскрытия NSSplitView.
        rightPanelButtonMotion.update(active: active, animate: changed)
        activeRightPanel = active
        toggleCalendarAction = toggleCalendar; toggleAssistantAction = toggleAssistant
        rightPanelCalendarTitle = calendarTitle; rightPanelAssistantTitle = assistantTitle
        if let active {
            calendarHeading.update(title: headingTitle,
                accessibilityIdentifier: active == .assistant ? "assistant-panel-heading" : "calendar-panel-heading")
        }
        refreshRightPanelButtonLabels()
        scheduleToolbarAlignment()
    }

    private func refreshRightPanelButtonLabels() {
        // Значок, target/action и AX-идентификатор принадлежат панели и никогда не меняются местами.
        assistantButton.contentTintColor = .labelColor
        calendarButton.contentTintColor = .labelColor
        let roles = RightPanelToolbarRoles(active: activeRightPanel)
        let outerButton = roles.outer == .assistant ? assistantButton : calendarButton
        let trailingButton = roles.trailing == .assistant ? assistantButton : calendarButton
        updateLabel(roles.outer == .assistant ? rightPanelAssistantTitle : rightPanelCalendarTitle,
                    item: rightPanelSwitchItem, button: outerButton)
        updateLabel(roles.trailing == .assistant ? rightPanelAssistantTitle : rightPanelCalendarTitle,
                    item: rightPanelToggleItem, button: trailingButton)
    }

    @objc private func toggleAssistantPanel() { toggleAssistantAction?() }
    @objc private func toggleCalendarPanel() { toggleCalendarAction?() }

    private var calendarToolbarIdentifiers: [NSToolbarItem.Identifier] {
        // Свободное место находится после всех действий задачи во всех режимах календаря.
        switch calendarToolbarLayout {
        case .closed: [.space, .plannerRightPanelToggle]
        case .column: [.plannerCalendarBoundary, .plannerCalendarHeading, .flexibleSpace, .plannerRightPanelToggle, .plannerCalendarTrailingBoundary]
        case .overlay: [.plannerCalendarHeading, .plannerCalendarGap, .plannerRightPanelToggle]
        }
    }

    func updateCalendarHeading(title: String) {
        calendarHeading.update(title: title)
        scheduleToolbarAlignment()
    }

    func beginCalendarHeaderTransition() {
        calendarHeaderGeneration += 1
        calendarHeaderIsTransitioning = true
        updateCalendarHeadingVisibility()
    }

    func finishCalendarHeaderTransition(afterLayout: Bool) {
        let generation = calendarHeaderGeneration
        // Системная граница уже участвует в layout; показываем только подпись, не меняя геометрию.
        let reveal: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.calendarHeaderGeneration == generation else { return }
            // Полноэкранный toolbar находится в отдельном окне. Даём ему принять итоговую
            // геометрию, прежде чем показывать подпись; её место всё время остаётся занятым.
            self.calendarHeading.window?.contentView?.layoutSubtreeIfNeeded()
            guard self.calendarHeaderGeneration == generation else { return }
            self.calendarHeaderIsTransitioning = false
            self.updateCalendarHeadingVisibility()
        }
        if afterLayout { DispatchQueue.main.async(execute: reveal) }
        else { reveal() }
    }

    private func updateCalendarHeadingVisibility() {
        let visible = calendarToolbarLayout != .closed && !calendarHeaderIsTransitioning
        // Прозрачность сохраняет размеры toolbar item и положение кнопки; isHidden менял бы раскладку.
        calendarHeading.alphaValue = visible ? 1 : 0
        calendarHeading.setAccessibilityHidden(!visible)
    }

    /// Разделитель шапки следует за нативной границей календаря. Меню задачи всегда остаётся слева от него.
    func setCalendarToolbar(column: Bool, visible: Bool, overlayWidth: CGFloat = CalendarPanelLayout.defaultWidth) {
        calendarOverlayWidth = overlayWidth
        let layout: WorkspaceHeaderLayout.CalendarPlacement = !visible ? .closed : (column ? .column : .overlay)
        guard calendarToolbarLayout != layout else { updateOverlayToolbarGap(); return }
        calendarToolbarLayout = layout
        rightPanelButtonMotion?.layoutChanged()
        updateCalendarHeadingVisibility()
        // В накладном режиме сначала размещаем кнопки, затем занимаем только свободное место.
        // Широкий календарь не должен вытеснять кнопку закрытия в меню переполнения toolbar.
        calendarGapWidth.constant = 1
        if let index = workspaceToolbar.items.firstIndex(where: { $0.itemIdentifier == .plannerRightPanelSwitch }) {
            // Оба места кнопок остаются в toolbar: меняются только промежутки и границы секции.
            // Смена календаря на чат не удаляет кнопки и не создаёт новую стеклянную подложку.
            while workspaceToolbar.items.count > index + 1,
                  workspaceToolbar.items[index + 1].itemIdentifier != .plannerRightPanelToggle {
                workspaceToolbar.removeItem(at: index + 1)
            }
            for (offset, identifier) in calendarToolbarIdentifiers.prefix(while: { $0 != .plannerRightPanelToggle }).enumerated() {
                workspaceToolbar.insertItem(withItemIdentifier: identifier, at: index + 1 + offset)
            }
            if let calendarIndex = workspaceToolbar.items.firstIndex(where: { $0.itemIdentifier == .plannerRightPanelToggle }) {
                while workspaceToolbar.items.count > calendarIndex + 1 { workspaceToolbar.removeItem(at: calendarIndex + 1) }
                if layout == .column {
                    workspaceToolbar.insertItem(withItemIdentifier: .plannerCalendarTrailingBoundary, at: calendarIndex + 1)
                }
            }
        }
        scheduleToolbarAlignment()
        columnFramesChanged?()
    }

    private func updateOverlayToolbarGap() {
        guard calendarToolbarLayout == .overlay, let window = attachedWindow else { return }
        guard calendarHeading.window === window else { return }
        let heading = calendarHeading.convert(calendarHeading.bounds, to: nil)
        let trailingEdge = window.contentView?.bounds.maxX ?? window.frame.width
        // Выравниваем сам заголовок: действия задачи теперь собраны у левого края её колонки.
        let target = trailingEdge - calendarOverlayWidth + 12
        let difference = heading.minX - target
        // Учитываем кнопку, её контейнер, интервалы toolbar и внешний отступ окна.
        let availableGap = max(0, trailingEdge - heading.maxX - 96)
        let width = max(1, min(availableGap, calendarOverlayWidth, max(0, calendarGap.frame.width + difference)))
        if abs(width - calendarGapWidth.constant) >= 1 {
            calendarGapWidth.constant = width
            scheduleToolbarAlignment()
        }
    }

    func attachCalendarSidebar(_ host: NSViewController, width: CGFloat, animate: Bool, minimumWidth: CGFloat = CalendarPanelLayout.minimumWidth, maximumWidth: CGFloat = CalendarPanelLayout.maximumWidth) {
        updatingCalendarSidebar = true
        rightPanelMinimumWidth = minimumWidth; rightPanelMaximumWidth = maximumWidth
        if calendarSidebarItem == nil {
            // Тот же тип, что и у папок: macOS рисует цельную стеклянную панель с внешними отступами.
            let item = NSSplitViewItem(sidebarWithViewController: host)
            item.minimumThickness = CalendarPanelLayout.minimumWidth
            item.maximumThickness = CalendarPanelLayout.maximumWidth
            item.canCollapse = true
            item.canCollapseFromWindowResize = false
            item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
            item.allowsFullHeightLayout = true
            item.titlebarSeparatorStyle = isFullScreen ? .line : .none
            // Сохраняем выбранную ширину при входе в полный экран вместо стандартной доли sidebar.
            item.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
            item.holdingPriority = .defaultLow + 3
            item.isCollapsed = true
            calendarSidebarItem = item
            addSplitViewItem(item)
            // Отдельная прозрачная полоса оставляет бумагу справа от стекла, не сужая саму split view.
            let insetHost = NSViewController()
            insetHost.view = NSView()
            let inset = NSSplitViewItem(viewController: insetHost)
            inset.minimumThickness = CalendarPanelLayout.outerInset
            inset.maximumThickness = CalendarPanelLayout.outerInset
            // AppKit временно меняет приоритет при сворачивании; required здесь несовместим с анимацией.
            inset.holdingPriority = .defaultLow + 4
            inset.canCollapse = true
            inset.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
            inset.isCollapsed = true
            calendarInsetItem = inset
            addSplitViewItem(inset)
            calendarCollapsedObservation = item.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.updatingCalendarSidebar, !self.calendarIsAnimating,
                          let item = self.calendarSidebarItem else { return }
                    let visible = !item.isCollapsed
                    let identity = ObjectIdentifier(item)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let item = self.calendarSidebarItem, ObjectIdentifier(item) == identity,
                              visible == !item.isCollapsed else { return }
                        self.calendarVisibilityChanged?(visible)
                    }
                }
            }
        }
        guard let calendarSidebarItem else { updatingCalendarSidebar = false; return }
        calendarSidebarItem.minimumThickness = minimumWidth
        calendarSidebarItem.maximumThickness = maximumWidth
        updatingCalendarSidebar = false
        if calendarSidebarItem.isCollapsed || calendarTargetCollapsed {
            setCalendarCollapsed(false, width: width, animate: animate)
        } else {
            setCalendarToolbar(column: true, visible: true)
            if !calendarIsAnimating {
                // Обычное изменение ширины не должно перебивать анимацию раскрытия.
                splitView.setPosition(splitView.bounds.width - CalendarPanelLayout.outerInset - width - splitView.dividerThickness, ofDividerAt: 2)
            }
        }
    }

    func collapseCalendarSidebar(animate: Bool) {
        setCalendarCollapsed(true, animate: animate)
    }

    private func setCalendarCollapsed(_ collapsed: Bool, width: CGFloat? = nil, animate: Bool) {
        guard let item = calendarSidebarItem else { return }
        // Повторный layout и обновление SwiftUI не начинают тот же переход заново.
        if calendarIsAnimating, calendarTargetCollapsed == collapsed { return }
        if !calendarIsAnimating, item.isCollapsed == collapsed {
            calendarTargetCollapsed = collapsed
            // Синхронизируем внешний зазор также после сворачивания календаря перетаскиванием разделителя.
            calendarInsetItem?.isCollapsed = collapsed
            setCalendarToolbar(column: !collapsed, visible: !collapsed)
            return
        }
        calendarTransitionGeneration += 1
        let generation = calendarTransitionGeneration
        calendarTargetCollapsed = collapsed
        // Скрываем подпись до вставки секции при открытии и до сжатия колонки при закрытии.
        beginCalendarHeaderTransition()
        // Конечная геометрия шапки задаётся до движения. Настоящие кнопки в этот момент
        // находятся в общем слое и плавно едут к новым местам, а не прыгают в конце закрытия.
        setCalendarToolbar(column: !collapsed, visible: !collapsed)
        // Убираем декоративную коррекцию до изменения размеров и запуска системной анимации.
        calendarHeaderShadow.removeFromSuperview()
        calendarIsAnimating = animate && view.window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        updatingCalendarSidebar = true
        if !collapsed, let width {
            // Задаём конечную ширину до анимации. setPosition после animator обрывал плавный переход.
            let width = CalendarPanelLayout.panelWidth(width)
            item.minimumThickness = rightPanelMinimumWidth
            item.maximumThickness = width
            item.minimumThickness = width
        }
        if calendarIsAnimating {
            NSAnimationContext.runAnimationGroup { context in
                PlannerMotion.configure(context)
                calendarInsetItem?.animator().isCollapsed = collapsed
                item.animator().isCollapsed = collapsed
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.calendarTransitionGeneration == generation,
                          let item = self.calendarSidebarItem else { return }
                    self.finishCalendarTransition(item, collapsed: collapsed)
                }
            }
        } else {
            calendarInsetItem?.isCollapsed = collapsed
            item.isCollapsed = collapsed
            splitView.layoutSubtreeIfNeeded()
            finishCalendarTransition(item, collapsed: collapsed)
        }
        updatingCalendarSidebar = false
    }

    private func finishCalendarTransition(_ item: NSSplitViewItem, collapsed: Bool) {
        let wasAnimating = calendarIsAnimating
        calendarIsAnimating = false
        // После раскрытия пользователь снова может менять ширину в обычных пределах.
        item.minimumThickness = rightPanelMinimumWidth
        item.maximumThickness = rightPanelMaximumWidth
        // Подтверждаем конечную секцию после системной анимации.
        setCalendarToolbar(column: !collapsed, visible: !collapsed)
        scheduleToolbarAlignment()
        finishCalendarHeaderTransition(afterLayout: wasAnimating)
        headerConfigurationChanged?()
    }

    func detachCalendarSidebar() {
        guard let calendarSidebarItem else { return }
        // Завершение прежней анимации не должно затронуть календарь, уже перенесённый поверх содержимого.
        calendarTransitionGeneration += 1
        calendarIsAnimating = false
        calendarTargetCollapsed = true
        beginCalendarHeaderTransition()
        calendarHeaderShadow.removeFromSuperview()
        // Сначала убираем связанный toolbar-разделитель, затем саму четвёртую колонку.
        setCalendarToolbar(column: false, visible: false)
        finishCalendarHeaderTransition(afterLayout: false)
        calendarCollapsedObservation = nil
        if let calendarInsetItem { removeSplitViewItem(calendarInsetItem) }
        calendarInsetItem = nil
        removeSplitViewItem(calendarSidebarItem)
        self.calendarSidebarItem = nil
    }

    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let nativeRect = super.splitView(splitView, effectiveRect: proposedEffectiveRect,
                                         forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        // Скрытые панели и фиксированный внешний зазор не получают невидимых ручек.
        guard !nativeRect.isEmpty, dividerIndex >= 0, dividerIndex + 1 < splitViewItems.count,
              !splitViewItems[dividerIndex].isCollapsed, !splitViewItems[dividerIndex + 1].isCollapsed,
              splitViewItems[dividerIndex + 1] !== calendarInsetItem else { return .zero }
        return WorkspaceDividerInteraction.hitRect(at: drawnRect.midX, in: nativeRect)
    }

    override func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        // Внешний зазор не является колонкой с содержимым и не получает разделительную линию.
        if calendarInsetItem != nil, dividerIndex == 3 { return true }
        return super.splitView(splitView, shouldHideDividerAt: dividerIndex)
    }

    @objc private func createFolder() { newFolderAction?() }
    @objc private func createTask() { newTaskAction?() }

    @objc private func toggleFolders() {
        // Календарь должен уйти в накладной режим до раскрытия папок, если все колонки не помещаются.
        sidebarVisibilityWillChange?(sidebarItem.isCollapsed)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            sidebarItem.isCollapsed.toggle()
            return
        }
        // AppKit анимирует саму колонку; состояние SwiftUI получает итог через наблюдение за isCollapsed.
        NSAnimationContext.runAnimationGroup { context in
            PlannerMotion.configure(context)
            sidebarItem.animator().isCollapsed.toggle()
        }
    }

    @MainActor private struct WindowAppearance {
        let toolbar: NSToolbar?
        let toolbarStyle: NSWindow.ToolbarStyle
        let titleVisibility: NSWindow.TitleVisibility
        let transparentTitlebar: Bool
        let separatorStyle: NSTitlebarSeparatorStyle
        let hadFullSizeContent: Bool
        let backgroundColor: NSColor

        init(window: NSWindow) {
            toolbar = window.toolbar
            toolbarStyle = window.toolbarStyle
            titleVisibility = window.titleVisibility
            transparentTitlebar = window.titlebarAppearsTransparent
            separatorStyle = window.titlebarSeparatorStyle
            hadFullSizeContent = window.styleMask.contains(.fullSizeContentView)
            backgroundColor = window.backgroundColor
        }

        func restore(_ window: NSWindow) {
            window.toolbar = toolbar
            window.toolbarStyle = toolbarStyle
            window.titleVisibility = titleVisibility
            window.titlebarAppearsTransparent = transparentTitlebar
            window.titlebarSeparatorStyle = separatorStyle
            window.backgroundColor = backgroundColor
            if !hadFullSizeContent { window.styleMask.remove(.fullSizeContentView) }
        }
    }
}

/// Две строки заголовка в NSToolbar; длинное имя сокращается, не вытесняя кнопки соседней колонки.
@MainActor
private final class WorkspaceToolbarHeadingView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private var headingWidth: NSLayoutConstraint!

    var preferredWidth: CGFloat {
        // Измеряем исходные строки, а не уже сокращённую подпись NSTextField.
        let titleWidth = (titleField.stringValue as NSString).size(withAttributes: [.font: titleField.font!]).width
        let subtitleWidth = (subtitleField.stringValue as NSString).size(withAttributes: [.font: subtitleField.font!]).width
        return ceil(max(titleWidth, subtitleWidth)) + 12
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.setAccessibilityIdentifier("task-folder-heading")
        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.setAccessibilityIdentifier("task-count-heading")
        for field in [titleField, subtitleField] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(field)
        }
        // Явная ширина не позволяет toolbar измерить заголовок по прежнему минимуму в 60 pt.
        headingWidth = widthAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            headingWidth,
            heightAnchor.constraint(equalToConstant: 34),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            subtitleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            subtitleField.trailingAnchor.constraint(equalTo: trailingAnchor),
            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1)
        ])
    }

    required init?(coder: NSCoder) { nil }

    @discardableResult func setAvailableWidth(_ availableWidth: CGFloat) -> Bool {
        let width = max(WorkspaceHeaderLayout.minimumHeadingWidth, floor(availableWidth))
        guard abs(headingWidth.constant - width) >= 1 else { return false }
        headingWidth.constant = width
        return true
    }

    func update(title: String, subtitle: String) {
        guard titleField.stringValue != title || subtitleField.stringValue != subtitle else { return }
        titleField.stringValue = title
        subtitleField.stringValue = subtitle
        // Полное название доступно и при сокращении текста в узком окне.
        toolTip = "\(title)\n\(subtitle)"
    }
}

private extension NSToolbarItem.Identifier {
    static let plannerCalendarHeading = NSToolbarItem.Identifier("Planner.CalendarHeading")
    static let plannerCalendarTrailingBoundary = NSToolbarItem.Identifier("Planner.CalendarTrailingBoundary")
    static let plannerCalendarBoundary = NSToolbarItem.Identifier("Planner.CalendarBoundary")
    static let plannerCalendarGap = NSToolbarItem.Identifier("Planner.CalendarGap")
    static let plannerRightPanelSwitch = NSToolbarItem.Identifier("Planner.RightPanelSwitch")
    static let plannerRightPanelToggle = NSToolbarItem.Identifier("Planner.RightPanelToggle")
    static let plannerSearch = NSToolbarItem.Identifier("Planner.Search")
    static let plannerNewFolder = NSToolbarItem.Identifier("Planner.NewFolder")
    static let plannerToggleSidebar = NSToolbarItem.Identifier("Planner.ToggleSidebar")
    static let plannerFolderHeading = NSToolbarItem.Identifier("Planner.FolderHeading")
    static let plannerDetailTrackingSeparator = NSToolbarItem.Identifier("Planner.DetailTrackingSeparator")
    static let plannerNewTask = NSToolbarItem.Identifier("Planner.NewTask")
    static let plannerChecklist = NSToolbarItem.Identifier("Planner.Checklist")
    static let plannerDeadline = NSToolbarItem.Identifier("Planner.Deadline")
    static let plannerTaskActions = NSToolbarItem.Identifier("Planner.TaskActions")
}
