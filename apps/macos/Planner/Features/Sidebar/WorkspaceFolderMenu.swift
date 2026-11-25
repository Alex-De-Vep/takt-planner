import SwiftUI

/// Название текущей папки одновременно открывает список назначений.
struct WorkspaceFolderMenu: View {
    enum Kind: String { case task, note }

    @Environment(\.translations) private var strings
    let kind: Kind
    let current: TaskFilter?
    let folders: [TaskFolder]
    let move: (TaskFilter) -> Void

    var body: some View {
        let title = current?.title(in: folders, using: strings) ?? strings["Без папки"]
        let userFolders = folders.filter { !$0.isDeleted }
        Menu {
            if kind == .task {
                ForEach(TaskFilter.systemFolders) { destination in option(destination) }
                if !userFolders.isEmpty { Divider() }
            }
            ForEach(userFolders) { folder in option(.folder(folder.id)) }
        } label: {
            Label(title, systemImage: current?.symbol ?? "folder")
                .lineLimit(1)
                .frame(maxWidth: 205, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(kind == .note ? PlannerStyle.noteAccentForeground : Color.secondary)
        .help(strings["Переместить в папку"] + " · " + title)
        .accessibilityLabel(strings["Папка"])
        .accessibilityValue(title)
        .accessibilityIdentifier("\(kind.rawValue)-folder-picker")
        .disabled(kind == .note && userFolders.isEmpty)
    }

    private func option(_ destination: TaskFilter) -> some View {
        Button { move(destination) } label: {
            Label(destination.title(in: folders, using: strings),
                  systemImage: current == destination ? "checkmark" : destination.symbol)
        }
        .disabled(current == destination)
        .accessibilityIdentifier("move-\(kind.rawValue)-\(destination.id)")
    }
}
