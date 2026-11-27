import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BackupSettingsSection: View {
    @Environment(\.translations) private var strings
    let preferences: AppPreferences
    let service: TaskService?
    let assistant: AssistantService?
    let restore: (PlannerBackup) throws -> Void

    @State private var working = false
    @State private var preview: PlannerBackup?
    @State private var showsPreview = false
    @State private var message: String?
    @State private var failure: String?

    var body: some View {
        Section {
            Button(strings["Создать резервную копию…"], action: exportBackup)
                .accessibilityIdentifier("export-backup")
                .disabled(service == nil || assistant == nil || working)
            Button(strings["Восстановить из файла…"], action: selectBackup)
                .accessibilityIdentifier("import-backup")
                .disabled(working)
            if working { ProgressView().controlSize(.small) }
            if let message { Text(strings[message]).foregroundStyle(.secondary) }
            if let failure { Text(strings[failure]).foregroundStyle(.red).textSelection(.enabled) }
        } header: {
            Label(strings["Резервная копия"], systemImage: "externaldrive")
        } footer: {
            Text(strings["Файл содержит задачи, папки, подзадачи, связи с календарём, историю чата, черновики и настройки. Для экспорта и восстановления интернет не нужен. Файл не зашифрован."])
        }
        .sheet(isPresented: $showsPreview, onDismiss: { preview = nil }) {
            if let preview {
                VStack(alignment: .leading, spacing: 16) {
                    Text(strings["Восстановить резервную копию?"]).font(.title2.bold())
                    Text(preview.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                    LabeledContent(strings["Задачи"], value: String(preview.tasks.count))
                    LabeledContent(strings["Заметки"], value: String(preview.notes?.count ?? 0))
                    LabeledContent(strings["Папки"], value: String(preview.folders.count))
                    LabeledContent(strings["Подзадачи"], value: String(preview.tasks.reduce(0) { $0 + $1.checklist.count }))
                    Text(strings["Копия откроется как отдельная библиотека на этом Mac. Текущая база останется на диске. Чтобы загрузить задачи в облако, войдите и выберите перенос."])
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button(strings["Отмена"]) { showsPreview = false }.keyboardShortcut(.cancelAction)
                        Button(strings["Восстановить на Mac"]) { restoreBackup(preview) }
                            .keyboardShortcut(.defaultAction)
                            .tint(PlannerStyle.settingsControlTint)
                            .accessibilityIdentifier("confirm-restore-backup")
                    }
                }
                .padding(24)
                .frame(width: 430)
                .environment(\.locale, preferences.language.locale)
            }
        }
    }

    private func exportBackup() {
        guard let service, let assistant else { return }
        failure = nil; message = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Takt-backup-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))).json"
        working = true
        panel.begin { result in
            guard result == .OK, let url = panel.url else { working = false; return }
            do {
                let backup = try PlannerBackup.capture(from: service, assistant: assistant, preferences: preferences)
                Task {
                    do {
                        try await Task.detached(priority: .userInitiated) { try backup.write(to: url) }.value
                        message = backup.conversations == nil
                            ? "Копия сохранена без истории чата: история недоступна."
                            : "Резервная копия сохранена."
                    } catch { failure = error.localizedDescription }
                    working = false
                }
            } catch { failure = error.localizedDescription; working = false }
        }
    }

    private func selectBackup() {
        failure = nil; message = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        working = true
        panel.begin { result in
            guard result == .OK, let url = panel.url else { working = false; return }
            Task {
                do {
                    preview = try await Task.detached(priority: .userInitiated) {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return try PlannerBackup.read(from: url)
                    }.value
                    showsPreview = true
                } catch { failure = error.localizedDescription }
                working = false
            }
        }
    }

    private func restoreBackup(_ backup: PlannerBackup) {
        showsPreview = false
        do {
            try restore(backup)
            message = "Резервная копия восстановлена на этом Mac."
        } catch { failure = error.localizedDescription }
    }
}
