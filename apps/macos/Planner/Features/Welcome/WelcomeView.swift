import SwiftUI

struct WelcomeView: View {
    @Environment(\.translations) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismissWindow) private var dismissWindow
    let cloud: CloudWorkspace
    let service: TaskService?
    var openedFromHelp = false
    @State private var appeared = false
    @State private var showsAccount = false

    private struct Feature {
        let id: String
        let icon: Image
        let title: String
        let example: String
        let tint: AnyShapeStyle
    }

    private var features: [Feature] {
        [
            Feature(id: "tasks", icon: Image(systemName: "checklist"), title: "Задачи и напоминания",
                    example: "Поставьте задаче «Отправить отчёт» срок на 17:00 и получите напоминание.", tint: AnyShapeStyle(PlannerStyle.accent)),
            Feature(id: "notes", icon: Image(systemName: "note.text"), title: "Заметки",
                    example: "Откройте свою папку и выберите «Заметки», чтобы сохранить идеи и списки.", tint: AnyShapeStyle(PlannerStyle.noteControlAccent)),
            Feature(id: "calendar", icon: Image(systemName: "calendar.badge.plus"), title: "События календаря",
                    example: "Добавьте «Встречу с командой» на завтра с 11:00 до 11:30.", tint: AnyShapeStyle(PlannerStyle.calendarAccent)),
            Feature(id: "assistant", icon: Image(nsImage: WorkspaceAIChatSymbol.image()).resizable(),
                    title: "ИИ-помощник",
                    example: "Попросите помощника сократить описание задачи и проверьте правку перед сохранением.", tint: AnyShapeStyle(PlannerStyle.assistantGradient))
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 26) {
                    VStack(spacing: 7) {
                        Text(strings["Добро пожаловать в Takt"])
                            .font(.system(size: 33, weight: .bold, design: .rounded))
                            .accessibilityAddTraits(.isHeader)
                        Text(strings["Планируйте день в своём ритме"])
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
                        cards
                    }

                    Divider()
                    storageActions
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 28)
                .frame(maxWidth: 950)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .background {
                LinearGradient(colors: [.indigo.opacity(0.13), Color(nsColor: .windowBackgroundColor)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
            }
        }
        .frame(minWidth: 540, minHeight: 540)
        .onAppear { appeared = true }
        .sheet(isPresented: $showsAccount, onDismiss: { cloud.cancelSetup() }) {
            AccountForm(cloud: cloud, service: service, mode: .login)
        }
        .accessibilityIdentifier("planner-welcome")
    }

    private var cards: some View {
        ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
            VStack(alignment: .leading, spacing: 10) {
                Rectangle()
                    .fill(feature.tint)
                    .frame(width: 28, height: 28)
                    .mask {
                        feature.icon
                            .font(.system(size: 24, weight: .medium))
                    }
                    .frame(width: 46, height: 46)
                    .background(feature.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                Text(strings[feature.title])
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("welcome-feature-\(feature.id)")
                Text(strings[feature.example])
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 125, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .opacity(reduceMotion || appeared ? 1 : 0)
            .offset(y: reduceMotion || appeared ? 0 : 8)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.34).delay(Double(index) * 0.07), value: appeared)
        }
    }

    private var storageActions: some View {
        VStack(spacing: 12) {
            if let profile = cloud.profile {
                Text(strings["Синхронизация подключена"]).font(.headline)
                Text(profile.account.email).foregroundStyle(.secondary)
                Button(strings["Продолжить"]) { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("welcome-continue")
            } else {
                Text(strings["Где хранить задачи"]).font(.headline)
                Text(strings["Синхронизацию можно включить позже в настройках."])
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button(strings["Продолжить на этом Mac"]) { finish() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("welcome-local")
                    Button(strings["Подключить синхронизацию"]) { showsAccount = true }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("welcome-sync")
                }
            }
        }
    }

    private func finish() {
        cloud.welcomeCompleted = true
        if openedFromHelp { dismissWindow(id: "welcome") }
    }
}
