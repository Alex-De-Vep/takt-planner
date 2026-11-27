import AppKit
import SwiftUI

enum SidebarSelection: Hashable {
    case taskFilter(TaskFilter)
    case allNotes
    case deletedNotes
}

/// Системные разделы и пользовательские папки используют одинаковые строки и счётчики.
struct SidebarView: View {
    @Environment(\.translations) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: SidebarSelection?
    let folders: [TaskFolder]
    let tasks: [PlannerTask]
    let now: Date
    let renameFolder: (TaskFolder) -> Void
    let deleteFolder: (TaskFolder) -> Void
    let manageLabels: (TaskFolder) -> Void
    let receiveItem: (FolderDragPayload, TaskFilter) -> Void
    let dragScopeID: UUID
    let folderDrag: FolderDragState
    var notes: [PlannerNote] = []
    var syncEngine: SyncEngine? = nil
    var showsNotes = false
    private struct Hover {
        let folder: TaskFilter
        let token: UUID?
        let feedback: FolderDragState.Feedback
    }
    @State private var hover: Hover?

    // При переносе выбранной остаётся открытая папка: назначение не подменяет selection.
    private var listSelection: Binding<SidebarSelection?> {
        Binding(get: { selection }, set: { value in
            guard folderDrag.context == nil, hover == nil else { return }
            withImmediateNavigationUpdate { selection = value }
        })
    }

    private var deleteSelectedFolder: (() -> Void)? {
        // Только пользовательская папка в списке может вызвать диалог удаления.
        guard folderDrag.context == nil, hover == nil, case .taskFilter(.folder(let id))? = selection,
              let folder = folders.first(where: { $0.id == id && !$0.isDeleted }) else { return nil }
        return { deleteFolder(folder) }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: listSelection) {
                Section(strings["Задачи"]) {
                    ForEach(TaskFilter.smartFilters) { filter in
                        row(filter).tag(SidebarSelection.taskFilter(filter))
                            .accessibilityIdentifier("sidebar-\(filter.id)")
                    }
                }
                Section(strings["Заметки"]) {
                    noteFilter(.allNotes, title: strings["Все заметки"], symbol: "note.text", identifier: "sidebar-all-notes")
                    noteFilter(.deletedNotes, title: strings["Недавно удалённые"], symbol: "trash", identifier: "sidebar-deleted-notes")
                }
                Section(strings["Мои папки"]) {
                    if folders.isEmpty {
                        Text(strings["Создайте свою первую папку"])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                    ForEach(folders) { folder in
                        row(.folder(folder.id)).tag(SidebarSelection.taskFilter(.folder(folder.id)))
                            .accessibilityIdentifier("folder-row-\(folder.name)")
                            .contextMenu {
                                Button(strings["Ярлыки…"]) { manageLabels(folder) }
                                Button(strings["Переименовать"]) { renameFolder(folder) }
                                Button(strings["Удалить папку…"], role: .destructive) { deleteFolder(folder) }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .tint(showsNotes ? PlannerStyle.noteSelectionAccent : PlannerStyle.accent)
            // Стекло рисует полноразмерный NSSplitViewItem, а не отдельная область внутри списка.
            .scrollContentBackground(.hidden)
            .animation(PlannerMotion.animation(reduceMotion: reduceMotion), value: folders.map(\.id))
            // Сначала сбрасываем анимацию внешней транзакции, затем List добавляет её только при смене папок.
            .transaction { $0.animation = nil }
            .onDeleteCommand(perform: deleteSelectedFolder)
            .accessibilityIdentifier("sidebar-list")
            if let syncEngine {
                SidebarSyncStatus(engine: syncEngine)
            }
        }
        .onChange(of: folderDrag.context?.token) { _, token in
            if hover?.token != token { hover = nil }
        }
        .onDisappear { hover = nil }
    }

    private func noteFilter(_ filter: SidebarSelection, title: String, symbol: String, identifier: String) -> some View {
        let count = filter == .allNotes ? notes.count(where: { $0.deletedAt == nil && !$0.isPurged }) : nil
        return SidebarFolderRow(title: title, symbol: symbol, countText: count?.formatted(),
                                countDescription: count.map { strings.format("Заметок: %d", $0) } ?? "",
                                selected: selection == filter, usesNoteAccent: true)
            .tag(filter)
            .accessibilityIdentifier(identifier)
    }

    private func row(_ filter: TaskFilter) -> some View {
        let count = tasks.filter { !$0.isDeleted && !$0.isCompleted && filter.matches($0, now: now) }.count
        let noteCount = filter.acceptsNotes ? notes.filter { $0.deletedAt == nil && $0.folder == filter.id }.count : nil
        let countText = noteCount.map { "\(count.formatted()) | \($0.formatted())" } ?? (count > 0 ? count.formatted() : nil)
        let countDescription = noteCount.map { strings.format("Задач: %d, заметок: %d", count, $0) }
            ?? strings.format("Задач: %d", count)
        return SidebarFolderRow(title: filter.title(in: folders, using: strings), symbol: filter.symbol,
                                countText: countText, countDescription: countDescription, selected: selection == .taskFilter(filter),
                                feedback: hover?.folder == filter && hover?.token == folderDrag.context?.token
                                    ? hover?.feedback ?? .none : .none,
                                usesNoteAccent: showsNotes && filter.acceptsNotes)
        .onDrop(of: FolderDragPayload.Kind.allCases.map(\.type), delegate: FolderDropDelegate(destination: filter,
            scopeID: dragScopeID, drag: folderDrag, setTargeted: { active in
                if active {
                    // AppKit может переиспользовать провайдер при повторном drag и не вызвать замыкание источника.
                    let feedback = folderDrag.feedback(for: filter)
                    hover = Hover(folder: filter, token: folderDrag.context?.token,
                                  feedback: feedback == .sameFolder ? .sameFolder : .destination)
                } else if hover?.folder == filter {
                    hover = nil
                }
            }, receive: receiveItem))
    }
}

struct SidebarSyncStatus: View {
    @Environment(\.translations) private var strings
    @State private var showsDetails = false
    let engine: SyncEngine

    private var issue: String? {
        switch engine.status {
        case .signIn: strings["Войдите в аккаунт повторно."]
        case .failed(let message): strings[message]
        default: nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 12)
            Group {
                if issue != nil {
                    Button { showsDetails.toggle() } label: {
                        Label(strings["Ошибка синхронизации"], systemImage: "exclamationmark.circle.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("sidebar-sync-error")
                } else {
                    statusLabel
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("sidebar-sync-status")
                }
            }
            .font(.caption)
            .frame(minHeight: 34)
            .padding(.horizontal, 16)
            .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(strings["Синхронизация"]).font(.headline)
                    if let issue {
                        Text(issue)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else {
                        statusLabel
                    }
                    if engine.pending > 0 {
                        LabeledContent(strings["Ожидают отправки"], value: engine.pending.formatted())
                            .foregroundStyle(.secondary)
                    }
                    switch engine.status {
                    case .signIn:
                        SettingsLink { Text(strings["Настройки"]) }
                    case .failed:
                        Button(strings["Синхронизировать"]) { engine.retry() }
                            .accessibilityIdentifier("sidebar-sync-retry")
                    default:
                        EmptyView()
                    }
                }
                .padding(16)
                .frame(width: 280, alignment: .leading)
                .accessibilityIdentifier("sidebar-sync-details")
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder private var statusLabel: some View {
        switch engine.status {
        case .syncing:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(strings["Синхронизация…"])
            }
        case .upToDate:
            Label {
                Text(strings["Синхронизировано"])
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        default:
            Label(strings["Ожидание синхронизации"], systemImage: "arrow.trianglehead.clockwise")
        }
    }
}

private struct SidebarFolderRow: View {
    let title: String
    let symbol: String
    var countText: String?
    var countDescription = ""
    let selected: Bool
    var feedback: FolderDragState.Feedback = .none
    var usesNoteAccent = false

    private static let selectionBackground = PlannerStyle.color(light: 0x7650B5, dark: 0x7759A6)

    private var hasAccentBackground: Bool { selected || feedback == .destination }

    private var foreground: Color {
        if hasAccentBackground { return .white }
        if feedback == .sameFolder { return PlannerStyle.accent }
        // The system foreground follows AppKit selection even before List updates its binding.
        return .primary
    }

    private var background: Color {
        if feedback == .destination { return PlannerStyle.accent }
        if selected { return usesNoteAccent ? PlannerStyle.noteSelectionAccent : Self.selectionBackground }
        if feedback == .sameFolder { return Color(nsColor: .unemphasizedSelectedContentBackgroundColor) }
        return .clear
    }

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: symbol)
                .labelStyle(SidebarRowLabelStyle())
                .lineLimit(1)
                .foregroundStyle(foreground)
            Spacer(minLength: 4)
            if let countText {
                Text(countText).font(.caption).monospacedDigit()
                    .fixedSize()
                    .help(countDescription)
                    .accessibilityLabel(countDescription)
                    .foregroundStyle(hasAccentBackground
                        ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        // List сохраняет выбор и клавиатурную навигацию; видимый фон меняется вместе с цветом текста.
        .background(SidebarSelectionAppearance())
        .listItemTint(.fixed(.clear))
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(background)
                .padding(.horizontal, 10)
                .transaction {
                    $0.animation = nil
                    $0.disablesAnimations = true
                }
        )
        .transaction { $0.animation = nil }
    }
}

/// Фон рисует SidebarFolderRow, чтобы нативная подсветка не вспыхивала при смене папки.
private struct SidebarSelectionAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) { view.hideNativeHighlight() }

    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            hideNativeHighlight()
        }

        func hideNativeHighlight() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    if table.selectionHighlightStyle != .none {
                        table.selectionHighlightStyle = .none
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

/// Одинаковый размер значков и компактный отступ до текста во всех строках левой панели.
private struct SidebarRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.system(size: 17, weight: .regular))
                .imageScale(.medium)
                .symbolRenderingMode(.monochrome)
                .frame(width: 20)
            configuration.title
        }
    }
}
