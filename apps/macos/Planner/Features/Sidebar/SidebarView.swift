import AppKit
import SwiftUI

/// Системные разделы и пользовательские папки используют одинаковые строки и счётчики.
struct SidebarView: View {
    @Environment(\.translations) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: TaskFilter?
    let folders: [TaskFolder]
    let tasks: [PlannerTask]
    let now: Date
    let renameFolder: (TaskFolder) -> Void
    let deleteFolder: (TaskFolder) -> Void
    let receiveTask: (TaskDragPayload, TaskFilter) -> Void
    let taskDrag: TaskDragState
    @State private var targetedFolder: TaskFilter?

    // При переносе выбранной остаётся открытая папка: назначение не подменяет selection.
    private var folderSelection: Binding<TaskFilter?> {
        Binding(get: { selection }, set: { value in
            guard taskDrag.context == nil, targetedFolder == nil else { return }
            withImmediateNavigationUpdate { selection = value }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: folderSelection) {
                Section(strings["Задачи"]) {
                    ForEach(TaskFilter.smartFilters) { filter in
                        row(filter).tag(filter)
                            .accessibilityIdentifier("sidebar-\(filter.id)")
                    }
                }
                Section(strings["Мои папки"]) {
                    if folders.isEmpty {
                        Text(strings["Создайте свою первую папку"])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                    ForEach(folders) { folder in
                        row(.folder(folder.id)).tag(TaskFilter.folder(folder.id))
                            .accessibilityIdentifier("folder-row-\(folder.name)")
                            .contextMenu {
                                Button(strings["Переименовать"]) { renameFolder(folder) }
                                Button(strings["Удалить папку…"], role: .destructive) { deleteFolder(folder) }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            // Стекло рисует полноразмерный NSSplitViewItem, а не отдельная область внутри списка.
            .scrollContentBackground(.hidden)
            .listItemTint(.monochrome)
            .animation(PlannerMotion.animation(reduceMotion: reduceMotion), value: folders.map(\.id))
            .accessibilityIdentifier("sidebar-list")
            HStack {
                SettingsLink { Label(strings["Настройки"], systemImage: "gearshape") }
                    .labelStyle(SidebarRowLabelStyle())
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(strings["Настройки"])
                    .accessibilityLabel(strings["Настройки"])
                    .accessibilityIdentifier("settings-button")
                Spacer()
            }
            .padding(16)
        }
        .onChange(of: taskDrag.context?.token) {
            withImmediateNavigationUpdate { targetedFolder = nil }
        }
        .onDisappear { targetedFolder = nil }
    }

    private func row(_ filter: TaskFilter) -> some View {
        let count = tasks.filter { !$0.isCompleted && filter.matches($0, now: now) }.count
        return SidebarFolderRow(title: filter.title(in: folders, using: strings), symbol: filter.symbol,
                                count: count, selected: selection == filter,
                                feedback: targetedFolder == filter ? taskDrag.feedback(for: filter) : .none)
        .onDrop(of: [.plannerTask], delegate: TaskFolderDropDelegate(destination: filter,
            targeted: Binding(get: { targetedFolder == filter }, set: { active in
                if active { targetedFolder = filter }
                else if targetedFolder == filter { targetedFolder = nil }
            }), receive: receiveTask, taskDrag: taskDrag))
    }
}

/// Оформление читается внутри строки List, где backgroundProminence соответствует её нативному фону.
private struct SidebarFolderRow: View {
    let title: String
    let symbol: String
    let count: Int
    let selected: Bool
    let feedback: TaskDragState.Feedback

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: symbol)
                .labelStyle(SidebarRowLabelStyle())
                .lineLimit(1)
                .foregroundStyle(SidebarFolderForeground(selected: selected, feedback: feedback))
            Spacer(minLength: 4)
            if count > 0 {
                Text(count.formatted()).font(.caption).monospacedDigit()
                    .foregroundStyle(feedback == .destination
                        ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            }
        }
        .padding(.vertical, 3)
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        // listRowBackground занимает всю строку; повторяем боковые отступы нативного выделения sidebar.
        .listRowBackground(dropBackground.padding(.horizontal, 10))
        // Фон и содержимое меняют состояние одной транзакцией, без отдельного перехода цвета.
        .transaction { $0.animation = nil }
    }

    @ViewBuilder private var dropBackground: some View {
        if feedback == .destination {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(PlannerStyle.accent)
        } else if feedback == .sameFolder, !selected {
            // Из «Сегодня» и «Всех задач» можно навести на владельца, который сейчас не открыт.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
        }
    }
}

private struct SidebarFolderForeground: ShapeStyle {
    let selected: Bool
    let feedback: TaskDragState.Feedback

    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        if feedback == .destination { return AnyShapeStyle(Color.white) }
        // Не подменяем системный цвет на ещё акцентном фоне уходящей строки.
        // primary переключается вместе с backgroundProminence, а не с общим фокусом панели.
        if environment.backgroundProminence == .increased { return AnyShapeStyle(HierarchicalShapeStyle.primary) }
        return selected || feedback == .sameFolder
            ? AnyShapeStyle(PlannerStyle.accent) : AnyShapeStyle(HierarchicalShapeStyle.primary)
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
