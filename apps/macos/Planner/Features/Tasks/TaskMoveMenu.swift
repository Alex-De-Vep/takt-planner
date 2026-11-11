import SwiftUI

/// Один список назначений используется и в контекстном меню строки, и в меню открытой задачи.
struct TaskMoveMenu: View {
    @Environment(\.translations) private var strings
    let task: PlannerTask
    let folders: [TaskFolder]
    let move: (TaskFilter) -> Void

    var body: some View {
        Menu(strings["Переместить в папку"]) {
            ForEach(TaskFilter.systemFolders) { destination in option(destination) }
            if !folders.isEmpty { Divider() }
            ForEach(folders) { folder in option(.folder(folder.id)) }
        }
    }

    private func option(_ destination: TaskFilter) -> some View {
        Button { move(destination) } label: {
            Label(destination.title(in: folders, using: strings),
                  systemImage: task.primaryFolder == destination ? "checkmark" : destination.symbol)
        }
        .disabled(task.primaryFolder == destination)
        .accessibilityIdentifier("move-task-\(destination.id)")
    }
}
