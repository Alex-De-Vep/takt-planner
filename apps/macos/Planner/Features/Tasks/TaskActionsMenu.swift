import SwiftUI

/// Меню открытой задачи: выбор основной папки и удаление с подтверждением.
struct TaskActionsMenu: View {
    @Environment(\.translations) private var strings
    let task: PlannerTask
    let folders: [TaskFolder]
    let move: (TaskFilter) -> Void
    let delete: () -> Void

    var body: some View {
        Menu {
            TaskMoveMenu(task: task, folders: folders, move: move)
            Divider()
            Button(strings["Удалить задачу…"], role: .destructive, action: delete)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17))
                .foregroundStyle(.primary)
                .frame(width: WorkspaceToolbarButtonSurface.diameter, height: WorkspaceToolbarButtonSurface.diameter)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .tint(.primary)
        .buttonBorderShape(.circle)
        .frame(width: WorkspaceToolbarButtonSurface.diameter, height: WorkspaceToolbarButtonSurface.diameter)
        .contentShape(Circle())
        .help(strings["Действия с задачей"])
        .accessibilityLabel(strings["Действия с задачей"])
        .accessibilityIdentifier("task-actions-menu")
    }
}
