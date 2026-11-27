import SwiftUI

private extension FolderLabel {
    var color: Color { FolderLabelPalette.color(for: rgb) }
}

private struct FolderLabelChip: View {
    let label: FolderLabel
    var compact = true
    var tooltip: String? = nil

    var body: some View {
        Text(label.name)
            .lineLimit(1)
            .foregroundStyle(Color.white)
            .font(.system(size: compact ? 10 : 12, weight: .medium))
            .padding(.horizontal, compact ? 6 : 8)
            .frame(height: compact ? 17 : 22)
            .background(label.color, in: Capsule())
            .help(tooltip ?? label.name)
    }
}

/// A single line keeps list rows compact even with many labels.
struct FolderLabelChips: View {
    let labels: [FolderLabel]

    var body: some View {
        if !labels.isEmpty {
            ViewThatFits(in: .horizontal) {
                chips(textLimit: 2)
                chips(textLimit: 1)
                chips(textLimit: 0)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(labels.map(\.name).joined(separator: ", "))
        }
    }

    private func chips(textLimit: Int) -> some View {
        let remaining = labels.dropFirst(textLimit)
        let dots = remaining.prefix(4)
        let hiddenCount = remaining.count - dots.count
        return HStack(spacing: 4) {
            ForEach(labels.prefix(textLimit)) { label in
                FolderLabelChip(label: label).frame(maxWidth: 92)
            }
            ForEach(dots) { label in
                Circle().fill(label.color).frame(width: 8, height: 8)
            }
            if hiddenCount > 0 {
                Text("+\(hiddenCount)")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .frame(height: 17)
        .fixedSize()
    }
}

struct FolderLabelFilter: View {
    @Environment(\.translations) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let labels: [FolderLabel]
    let folders: [TaskFolder]
    let selected: FolderLabel?
    let tint: Color
    let select: (UUID?) -> Void
    @State private var showingLabels = false

    var body: some View {
        Button {
            showingLabels.toggle()
        } label: {
            let symbol = selected == nil ? "tag" : "line.3.horizontal.decrease.circle.fill"
            HStack(spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    Label(selected?.name ?? strings["Ярлыки"], systemImage: symbol)
                        .lineLimit(1)
                        .fixedSize()
                    Image(systemName: symbol)
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(showingLabels ? 180 : 0))
                    .animation(PlannerMotion.animation(.feedback, reduceMotion: reduceMotion), value: showingLabels)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(tint)
        }
        .buttonStyle(.borderless)
        .tint(tint)
        .accessibilityLabel(strings["Фильтр по ярлыку"])
        .accessibilityValue(selected?.name ?? strings["Все карточки"])
        .accessibilityIdentifier("folder-label-filter")
        .popover(isPresented: $showingLabels, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                option(nil)
                if !labels.isEmpty {
                    Divider()
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(labels) { label in option(label) }
                        }
                    }
                    .frame(height: min(CGFloat(labels.count) * 30, 210))
                }
            }
            .padding(10)
            .frame(width: 230)
        }
    }

    private func option(_ label: FolderLabel?) -> some View {
        let active = selected?.id == label?.id
        let title = label?.name ?? strings["Все карточки"]
        let folder = label.flatMap { label in
            folders.first(where: { $0.id == label.folderID && !$0.isDeleted })?.name
        }
        let description = folder.map { "\(title) · \($0)" } ?? title
        return Button {
            showingLabels = false
            select(label?.id)
        } label: {
            HStack(spacing: 8) {
                if let label {
                    FolderLabelChip(label: label, compact: false, tooltip: description)
                } else {
                    Text(title).foregroundStyle(.primary)
                }
                Spacer(minLength: 4)
                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(description)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct AssignedFolderLabels: View {
    let labels: [FolderLabel]

    var body: some View {
        if !labels.isEmpty {
            FolderLabelWrapLayout {
                ForEach(labels) { label in FolderLabelChip(label: label) }
            }
        }
    }
}

private struct FolderLabelWrapLayout: Layout {
    private let spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrangement(subviews, width: bounds.width).frames
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), frames)
    }
}

struct FolderLabelsToolbarButton: View {
    @Environment(\.translations) private var strings
    let store: FolderLabelStore
    let target: FolderLabelTarget?
    let folder: TaskFolder?
    let folders: [TaskFolder]
    let showsNotes: Bool
    @State private var showingLabels = false

    private var tint: Color { showsNotes ? PlannerStyle.noteActionTint : PlannerStyle.accent }

    var body: some View {
        let hasLabels = target.map { !store.labels(for: $0).isEmpty } ?? false
        Button { showingLabels.toggle() } label: {
            Image(systemName: "tag")
                .font(.system(size: 17))
                .foregroundStyle(hasLabels ? tint : Color.primary)
                .frame(width: WorkspaceToolbarButtonSurface.diameter, height: WorkspaceToolbarButtonSurface.diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(strings["Ярлыки"])
        .accessibilityLabel(strings["Ярлыки"])
        .accessibilityIdentifier("folder-label-toolbar-button")
        .popover(isPresented: $showingLabels, arrowEdge: .bottom) {
            FolderLabelPicker(store: store, target: target, folder: folder, folders: folders, tint: tint)
                .tint(tint)
        }
        .onDisappear { showingLabels = false }
    }
}

private struct FolderLabelPicker: View {
    @Environment(\.translations) private var strings
    let store: FolderLabelStore
    let target: FolderLabelTarget?
    let folder: TaskFolder?
    let folders: [TaskFolder]
    let tint: Color
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        let current = folder.flatMap { $0.isDeleted ? nil : $0 }
        let available = current.map { store.labels(in: $0.id) } ?? []
        let assigned = target.map { store.labels(for: $0) } ?? []
        let carried = assigned.filter { $0.folderID != current?.id }
        let labels = available + carried
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(strings["Ярлыки"]).font(.headline)
                Spacer()
                if let current {
                    Text(current.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if store.unreadable {
                Text(strings["Не удалось открыть локальные ярлыки."]).foregroundStyle(.red).font(.callout)
            } else if !labels.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(labels) { label in option(label, currentFolderID: current?.id) }
                    }
                }
                .frame(height: min(CGFloat(labels.count) * 34, 204))
            }
            if let current, !store.unreadable {
                if !labels.isEmpty { Divider() }
                if creating {
                    FolderLabelForm(label: nil, inline: true, save: { name, rgb in
                        guard !current.isDeleted else { throw FolderLabelError.unavailable }
                        try store.save(name: name, rgb: rgb, in: current.id, assigningTo: target)
                    }, close: { creating = false })
                } else {
                    Button {
                        creating = true
                    } label: {
                        Label(strings["Новый ярлык…"], systemImage: "plus")
                    }.accessibilityIdentifier("new-folder-label")
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .padding(14)
        .frame(width: 300)
        .accessibilityIdentifier("folder-label-picker")
        .onAppear { creating = current != nil && labels.isEmpty && !store.unreadable }
    }

    @ViewBuilder private func option(_ label: FolderLabel, currentFolderID: UUID?) -> some View {
        let source = folders.first(where: { $0.id == label.folderID && !$0.isDeleted })?.name ?? strings["Удалённая папка"]
        let title = label.folderID == currentFolderID ? label.name : "\(label.name) · \(source)"
        if let target {
            let assigned = store.contains(label.id, on: target)
            Button {
                do {
                    try store.toggle(label.id, on: target, currentFolderID: currentFolderID)
                    error = nil
                } catch { self.error = strings[error.localizedDescription] }
            } label: {
                labelRow(label, title: title, assigned: assigned)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(assigned ? .isSelected : [])
            .accessibilityIdentifier("folder-label-\(label.id)")
        } else {
            labelRow(label, title: title, assigned: false)
        }
    }

    private func labelRow(_ label: FolderLabel, title: String, assigned: Bool) -> some View {
        HStack(spacing: 8) {
            Circle().fill(label.color).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(title).foregroundStyle(.primary).lineLimit(1)
            Spacer()
            if assigned {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 34)
        .contentShape(Rectangle())
    }
}

struct FolderLabelsPanel: View {
    @Environment(\.translations) private var strings
    @Environment(\.dismiss) private var dismiss
    let store: FolderLabelStore
    let folder: TaskFolder
    @State private var editing: FolderLabel?
    @State private var showingForm = false
    @State private var deleting: FolderLabel?
    @State private var error: String?

    var body: some View {
        if showingForm {
            FolderLabelForm(label: editing, save: { name, rgb in
                guard !folder.isDeleted else { throw FolderLabelError.unavailable }
                try store.save(name: name, rgb: rgb, in: folder.id, editing: editing?.id)
            }, close: { showingForm = false })
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text(strings["Ярлыки"]).font(.title2.weight(.semibold))
                Text(folder.name).font(.callout).foregroundStyle(.secondary)
                if store.unreadable {
                    Text(strings["Не удалось открыть локальные ярлыки."]).foregroundStyle(.red)
                } else {
                    let labels = store.labels(in: folder.id)
                    if !labels.isEmpty {
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(labels) { label in
                                    HStack {
                                        FolderLabelChip(label: label)
                                        Spacer()
                                        Button(strings["Изменить…"]) { edit(label) }
                                        Button(role: .destructive) { deleting = label } label: {
                                            Image(systemName: "trash")
                                        }.accessibilityLabel(strings["Удалить ярлык"])
                                    }
                                }
                            }.frame(maxWidth: .infinity)
                        }.frame(maxHeight: 200)
                    }
                }
                HStack {
                    Button(strings["Новый ярлык…"]) { edit(nil) }.disabled(store.unreadable || folder.isDeleted)
                    Spacer()
                    Button(strings["Готово"]) { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(22).frame(width: 360)
            .confirmationDialog(strings["Удалить ярлык?"], isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { label in
                Button(strings["Удалить ярлык"], role: .destructive) {
                    do { try store.delete(label.id) }
                    catch { self.error = strings[error.localizedDescription] }
                }
            } message: { label in
                Text(strings.format("Ярлык «%@» будет снят со всех задач и заметок.", label.name))
            }
            .alert(strings["Не удалось сохранить"], isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(strings["Понятно"], role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func edit(_ label: FolderLabel?) {
        editing = label
        showingForm = true
    }
}

private struct FolderLabelForm: View {
    @Environment(\.translations) private var strings
    let label: FolderLabel?
    let inline: Bool
    let save: (String, UInt32) throws -> Void
    let close: () -> Void
    @State private var name: String
    @State private var rgb: UInt32
    @State private var showsPalette = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(label: FolderLabel?, inline: Bool = false, save: @escaping (String, UInt32) throws -> Void, close: @escaping () -> Void) {
        self.label = label
        self.inline = inline
        self.save = save
        self.close = close
        _name = State(initialValue: label?.name ?? "")
        _rgb = State(initialValue: label?.rgb ?? FolderLabelPalette.defaultRGB)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: inline ? 8 : 14) {
            if !inline {
                Text(strings[label == nil ? "Новый ярлык" : "Изменить ярлык"]).font(.title2.weight(.semibold))
            }
            HStack(spacing: 10) {
                TextField(strings["Название ярлыка"], text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .accessibilityIdentifier("folder-label-name")
                Button { showsPalette.toggle() } label: {
                    HStack(spacing: 4) {
                        Circle().fill(FolderLabelPalette.color(for: rgb)).frame(width: 15, height: 15)
                        Image(systemName: showsPalette ? "chevron.up" : "chevron.down").font(.caption2)
                    }
                }
                .help(strings["Цвет ярлыка"])
                .accessibilityLabel(strings["Цвет ярлыка"])
                .accessibilityIdentifier("folder-label-color")
            }
            if showsPalette {
                FolderLabelPalette(rgb: $rgb)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button(strings["Отмена"], action: close).keyboardShortcut(.cancelAction)
                Button(strings["Сохранить"], action: submit).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save-folder-label")
            }
        }
        .padding(inline ? 0 : 22)
        .frame(width: inline ? nil : 360)
        .onAppear { nameFocused = true }
    }

    private func submit() {
        do {
            try save(name, rgb)
            close()
        } catch { self.error = strings[error.localizedDescription] }
    }
}
