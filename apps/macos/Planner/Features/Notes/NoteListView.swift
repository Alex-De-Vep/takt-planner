import AppKit
import SwiftUI

enum NoteScope: Hashable { case folder, all, trash }

struct NoteListView: View {
    @Environment(\.translations) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: NoteStore
    let notes: [PlannerNote]
    @Binding var selection: UUID?
    let trash: Bool
    var createdNoteID: UUID? = nil
    var scope: WorkspaceListScope = .notes(.all, folder: nil, search: "")
    var dragScopeID: UUID? = nil
    var folderDrag: FolderDragState? = nil
    let create: () -> Void

    @State private var dragSourceID = UUID()
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
            guard folderDrag?.context == nil, let id, rowIDs.contains(id) else { return }
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
            if let error = store.libraryError {
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
            .onDisappear {
                folderDrag?.finish(sourceViewID: dragSourceID)
                nativeFocus.transitions.detach()
            }
            Text(strings[trash ? "Заметки удаляются навсегда через 30 дней."
                         : store.syncEnabled ? "Заметки синхронизируются с аккаунтом" : "Заметки сохраняются на этом Mac"])
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: listSelection) {
                ForEach(notes) { note in
                    draggableRow(note)
                        .tag(note.id)
                        .id(note.id)
                        .listRowInsets(EdgeInsets())
                        .listItemTint(.fixed(.clear))
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selection == note.id ? PlannerStyle.noteAccent : Color.clear)
                        )
                        .listRowSeparator(.visible, edges: .bottom)
                        .background(WorkspaceRowSelectionSync(rowID: note.id, selectedID: $selection,
                            revision: selectionRevision, isEligible: {
                                store.notes.contains { $0.id == note.id && ($0.deletedAt != nil) == trash }
                            }, nativeFocus: nativeFocus))
                        .onTapGesture {
                            guard folderDrag?.context == nil else { return }
                            withImmediateNavigationUpdate {
                                selection = note.id
                                listFocused = true
                                selectionRevision &+= 1
                            }
                        }
                        .contextMenu {
                            if trash {
                                Button(strings["Восстановить"]) { store.restoreFromTrash(note.id) }
                            }
                        }
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

    @ViewBuilder private func draggableRow(_ note: PlannerNote) -> some View {
        let row = NoteListRow(note: note, isSelected: selection == note.id)
        if let dragScopeID, let folderDrag, !trash, !store.unreadable {
            row.onDrag {
                guard let current = store.notes.first(where: { $0.id == note.id && $0.deletedAt == nil && !$0.isPurged }) else {
                    return NSItemProvider()
                }
                let payload = FolderDragPayload(kind: .note, itemID: current.id, scopeID: dragScopeID)
                folderDrag.begin(payload: payload, sourceFolderID: current.folder, sourceViewID: dragSourceID)
                return payload.provider()
            } preview: {
                FolderDragPreview(kind: .note)
            }
        } else {
            row
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
    let note: PlannerNote
    let isSelected: Bool

    private var supportingText: Color { isSelected ? .white : .secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if note.pinned {
                    Image(systemName: "pin.fill").font(.caption)
                        .foregroundStyle(isSelected ? Color.white : PlannerStyle.noteAccentForeground)
                }
                Text(note.displayTitle.isEmpty ? strings["Новая заметка"] : note.displayTitle)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
            }
            Text(note.text.isEmpty ? strings["Пустая заметка"] : note.text.replacingOccurrences(of: "\n", with: " "))
                .lineLimit(2)
                .foregroundStyle(supportingText)
            Text(note.updatedAt, format: .dateTime.day().month(.twoDigits))
                .foregroundStyle(supportingText)
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .contentShape(Rectangle())
    }
}
