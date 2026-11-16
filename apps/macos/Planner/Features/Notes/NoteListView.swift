import AppKit
import SwiftUI

enum NoteScope: Hashable { case folder, all, trash }

struct NoteListView: View {
    @Environment(\.translations) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: NoteStore
    let notes: [PlannerNote]
    let folders: [TaskFolder]
    @Binding var selection: UUID?
    let trash: Bool
    var createdNoteID: UUID? = nil
    var scope: WorkspaceListScope = .notes(.all, folder: nil, search: "")
    let create: () -> Void

    @State private var nativeFocus = WorkspaceListNativeFocus()
    @State private var displayedScope: WorkspaceListScope?
    @State private var selectionRevision = 0
    @FocusState private var listFocused: Bool

    private var rowIDs: [UUID] { notes.map(\.id) }

    private var rowAnimation: Animation? {
        displayedScope == scope ? PlannerMotion.animation(.listChange, reduceMotion: reduceMotion) : nil
    }

    private var listSelection: Binding<UUID?> {
        Binding(get: { selection.flatMap { rowIDs.contains($0) ? $0 : nil } }, set: { id in
            // List может сбросить подсветку при уходе фокуса. Открытая заметка при этом остаётся выбранной.
            guard let id, rowIDs.contains(id) else { return }
            // При удалении AppKit может предложить соседнюю строку. Без выбора принимаем только явную навигацию.
            let event = NSApp.currentEvent
            let arrow = event?.type == .keyDown && [UInt16(123), 124, 125, 126].contains(event?.keyCode ?? 0)
            guard selection != nil || arrow else { return }
            withImmediateNavigationUpdate { selection = id }
        })
    }

    private var deleteSelection: (() -> Void)? {
        guard !trash, !store.unreadable, let selection, rowIDs.contains(selection) else { return nil }
        return { moveToTrash(selection) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.error {
                VStack(alignment: .leading) {
                    Text(strings["Не удалось сохранить заметки"]).fontWeight(.medium)
                    Text(error).font(.caption).textSelection(.enabled)
                    if !store.unreadable { Button(strings["Повторить"]) { store.flush() } }
                }.foregroundStyle(.red).padding(12)
            }
            ZStack {
                list
                if notes.isEmpty {
                    ContentUnavailableView {
                        Label(strings[trash ? "Корзина пуста" : "Заметок пока нет"], systemImage: trash ? "trash" : "note.text")
                    } actions: {
                        if !trash { Button(strings["Новая заметка"], action: create).disabled(store.unreadable) }
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(rowAnimation, value: rowIDs)
            .onChange(of: scope, initial: true) { _, value in displayedScope = value }
            .onChange(of: rowIDs, initial: true) { _, ids in
                nativeFocus.transitions.update(ids: ids, scope: scope, animated: rowAnimation != nil)
            }
            .onChange(of: scope) {
                nativeFocus.transitions.update(ids: rowIDs, scope: scope, animated: false)
            }
            .onDisappear { nativeFocus.transitions.detach() }
            Text(strings[store.syncEnabled ? "Заметки синхронизируются с аккаунтом" : "Заметки сохраняются на этом Mac"])
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: listSelection) {
                ForEach(notes) { note in
                    NoteListRow(note: note)
                        .tag(note.id)
                        .id(note.id)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.visible, edges: .bottom)
                        .background(WorkspaceRowSelectionSync(rowID: note.id, selectedID: $selection,
                            revision: selectionRevision, isEligible: {
                                store.notes.contains { $0.id == note.id && ($0.deletedAt != nil) == trash }
                            }, nativeFocus: nativeFocus))
                        .onTapGesture {
                            withImmediateNavigationUpdate {
                                selection = note.id
                                listFocused = true
                                selectionRevision &+= 1
                            }
                        }
                        .onDrag { NSItemProvider(object: ("takt-note:" + note.id.uuidString) as NSString) }
                        .contextMenu { menu(for: note) }
                }
            }
            .modifier(WorkspaceListAppearance())
            .animation(rowAnimation, value: rowIDs)
            .focused($listFocused)
            .onDeleteCommand(perform: deleteSelection)
            .accessibilityIdentifier("note-list")
            .accessibilityHidden(notes.isEmpty)
            .onChange(of: createdNoteID, initial: true) { _, id in
                // Выделение List может оставить край новой строки за пределами видимой области.
                if let id { withAnimation(rowAnimation) { proxy.scrollTo(id) } }
            }
        }
    }

    @ViewBuilder private func menu(for note: PlannerNote) -> some View {
        if trash {
            Button(strings["Восстановить"]) { store.update(note.id) { $0.deletedAt = nil }; store.flush() }
        } else {
            Button(strings[note.pinned ? "Открепить" : "Закрепить"]) {
                store.update(note.id) { $0.pinned.toggle() }; store.flush()
            }
            Menu(strings["Переместить в папку"]) {
                ForEach(folders) { folder in
                    Button(folder.name) {
                        store.update(note.id) { $0.folder = TaskFilter.folder(folder.id).id }
                        store.flush()
                    }
                }
            }
            Divider()
            Button(strings["В корзину"], role: .destructive) { moveToTrash(note.id) }
                .disabled(store.unreadable)
        }
    }

    private func moveToTrash(_ id: UUID) {
        let wasSelected = selection == id
        // Закрываем открытую заметку до обновления списка, чтобы не выделился её сосед.
        if wasSelected { withImmediateNavigationUpdate { selection = nil } }
        let moved = withAnimation(rowAnimation) { store.moveToTrash(id) }
        if !moved, wasSelected { withImmediateNavigationUpdate { selection = id } }
    }
}

private struct NoteListRow: View {
    @Environment(\.translations) private var strings
    @Environment(\.backgroundProminence) private var backgroundProminence
    let note: PlannerNote

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if note.pinned {
                    Image(systemName: "pin.fill").font(.caption)
                        .foregroundStyle(backgroundProminence == .increased ? Color.primary : PlannerStyle.accent)
                }
                Text(note.displayTitle.isEmpty ? strings["Новая заметка"] : note.displayTitle)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(2)
            }
            Text(note.text.isEmpty ? strings["Пустая заметка"] : note.text.replacingOccurrences(of: "\n", with: " "))
                .lineLimit(2)
                .foregroundStyle(.secondary)
            Text(note.updatedAt, format: .dateTime.day().month(.twoDigits))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .contentShape(Rectangle())
    }
}
