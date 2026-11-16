import SwiftUI

enum NoteScope { case folder, all, trash }

struct NoteListView: View {
    @Environment(\.translations) private var strings
    let store: NoteStore
    let notes: [PlannerNote]
    let folders: [TaskFolder]
    @Binding var selection: UUID?
    let trash: Bool
    let create: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.error {
                VStack(alignment: .leading) {
                    Text(strings["Не удалось сохранить заметки"]).fontWeight(.medium)
                    Text(error).font(.caption).textSelection(.enabled)
                    if !store.unreadable { Button(strings["Повторить"]) { store.flush() } }
                }.foregroundStyle(.red).padding(12)
            }
            if notes.isEmpty {
                ContentUnavailableView {
                    Label(strings[trash ? "Корзина пуста" : "Заметок пока нет"], systemImage: trash ? "trash" : "note.text")
                } actions: {
                    if !trash { Button(strings["Новая заметка"], action: create).disabled(store.unreadable) }
                }
            } else {
                List(selection: $selection) {
                    ForEach(notes) { note in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                if note.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(PlannerStyle.accent) }
                                Text(note.displayTitle.isEmpty ? strings["Новая заметка"] : note.displayTitle)
                                    .font(.body.weight(.semibold)).lineLimit(1)
                            }
                            Text(note.text.isEmpty ? strings["Пустая заметка"] : note.text.replacingOccurrences(of: "\n", with: " "))
                                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            Text(note.updatedAt, format: .dateTime.day().month(.abbreviated))
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                        .tag(note.id)
                        .onTapGesture { selection = note.id }
                        .onDrag { NSItemProvider(object: ("takt-note:" + note.id.uuidString) as NSString) }
                        .contextMenu {
                            if trash {
                                Button(strings["Восстановить"]) { store.update(note.id) { $0.deletedAt = nil }; store.flush() }
                            } else {
                                Button(strings[note.pinned ? "Открепить" : "Закрепить"]) {
                                    store.update(note.id) { $0.pinned.toggle() }; store.flush()
                                }
                                Menu(strings["Переместить в папку"]) {
                                    ForEach(folders) { folder in
                                        Button(folder.name) { move(note, to: TaskFilter.folder(folder.id).id) }
                                    }
                                }
                                Divider()
                                Button(strings["В корзину"], role: .destructive) {
                                    store.update(note.id) { $0.deletedAt = .now }; store.flush()
                                }
                            }
                        }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
            }
            Text(strings[store.syncEnabled ? "Заметки синхронизируются с аккаунтом" : "Заметки сохраняются на этом Mac"])
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func move(_ note: PlannerNote, to folder: String) {
        store.update(note.id) { $0.folder = folder }
        store.flush()
    }
}
