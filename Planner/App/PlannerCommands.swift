import SwiftUI
import PlannerLocalization

/// Меню получает действия активного окна, поэтому сочетания клавиш работают и с несколькими окнами.
struct PlannerActions {
    let newTask: () -> Void
    let newFolder: () -> Void
    let toggleToday: () -> Void
    let toggleCompleted: () -> Void
    let hasSelection: Bool
}

private struct PlannerActionsKey: FocusedValueKey {
    typealias Value = PlannerActions
}

extension FocusedValues {
    var plannerActions: PlannerActions? {
        get { self[PlannerActionsKey.self] }
        set { self[PlannerActionsKey.self] = newValue }
    }
}

struct PlannerCommands: Commands {
    let strings: Translations
    var canShowWelcome = false
    @FocusedValue(\.plannerActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            SettingsLink { Text(strings["Настройки…"]) }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button(strings["Новая задача"]) { actions?.newTask() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
            Button(strings["Новая папка"]) { actions?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
        CommandMenu(strings["Задача"]) {
            Button(strings["Отметить / снять «На сегодня»"]) { actions?.toggleToday() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(actions?.hasSelection != true)
            Button(strings["Отметить / снять «Выполнено»"]) { actions?.toggleCompleted() }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(actions?.hasSelection != true)
        }
        CommandGroup(replacing: .help) {
            Button(strings["Справка по приложению"]) { openWindow(id: PlannerHelpView.windowID) }
            #if !SHOWCASE
            Button(strings["Показать приветствие"]) { openWindow(id: "welcome") }
                .disabled(!canShowWelcome)
                .accessibilityIdentifier("show-welcome")
            #endif
        }
    }
}
