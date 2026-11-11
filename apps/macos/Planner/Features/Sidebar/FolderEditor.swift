import SwiftUI

/// Одна форма для создания и переименования папки, с локальной проверкой названия.
struct FolderEditor: View {
    @Environment(\.translations) private var strings
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name: String
    @State private var validationError: String?
    let folder: TaskFolder?
    let service: TaskService
    let onSave: (TaskFolder) -> Void

    init(folder: TaskFolder?, service: TaskService, onSave: @escaping (TaskFolder) -> Void) {
        self.folder = folder
        self.service = service
        self.onSave = onSave
        _name = State(initialValue: folder?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(folder == nil ? strings["Новая папка"] : strings["Название папки"], systemImage: "folder")
                .font(.headline)
            TextField(strings["Название папки"], text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .accessibilityIdentifier("folder-name-field")
                .onSubmit(save)
            if let validationError {
                Text(validationError).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(strings["Отмена"]) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(folder == nil ? strings["Создать"] : strings["Сохранить"], action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save-folder-button")
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear { nameFocused = true }
    }

    private func save() {
        do {
            let result = try service.saveFolder(name: name, editing: folder)
            onSave(result)
            dismiss()
        } catch {
            // Наши ошибки валидации переводим, системные сообщения показываем как получены.
            validationError = strings[error.localizedDescription]
        }
    }
}
