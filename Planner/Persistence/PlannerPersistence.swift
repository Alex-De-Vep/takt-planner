import Foundation
import SwiftData

/// Единственная точка настройки SwiftData: локальный файл, версия схемы и первый запуск.
enum PlannerPersistence {
    static let schema = Schema(versionedSchema: PlannerSchemaV6.self)

    static func makeContainer(at url: URL? = nil, inMemory: Bool = false) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            configuration = ModelConfiguration("Planner", schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration("Planner", schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: PlannerMigrationPlan.self, configurations: [configuration])
    }

    static func liveStoreURL() throws -> URL {
        var directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Planner", directoryHint: .isDirectory)
        #if DEBUG
        // У UI-тестов своя постоянная библиотека: данные пользователя не затрагиваются.
        if let testID = ProcessInfo.processInfo.environment["PLANNER_UI_TEST_LIBRARY"], UUID(uuidString: testID) != nil {
            directory = directory.appending(path: "UITests/\(testID)", directoryHint: .isDirectory)
        }
        #endif
        return directory.appending(path: "Planner.store")
    }

    @MainActor
    static func bootstrap(_ context: ModelContext) throws {
        // Новая библиотека остаётся пустой. Маркер есть только у версии со стартовыми папками.
        let legacyMarkers = try context.fetch(FetchDescriptor<LibraryState>())
        guard !legacyMarkers.isEmpty else { return }

        // Разовая уборка старых стартовых папок. Переименованные и пользовательские папки сохраняем.
        let legacyNames = [["Работа", "Work"], ["Личное", "Personal"], ["Идеи", "Ideas"]]
        let folders = try context.fetch(FetchDescriptor<TaskFolder>())
        for folder in folders {
            guard legacyNames.indices.contains(folder.sortOrder),
                  legacyNames[folder.sortOrder].contains(folder.name) else { continue }
            for task in folder.tasks ?? [] {
                task.folder = nil
            }
            context.delete(folder)
        }
        // Удаление маркера делает уборку однократной: новые папки с такими именами не затронутся.
        for marker in legacyMarkers { context.delete(marker) }
        try context.save()
    }
}
