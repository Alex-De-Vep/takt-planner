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
        let icon: String
        let title: String
        let example: String
        let tint: Color
    }

    private var features: [Feature] {
        #if canImport(MLXLLM)
        let assistant = Feature(id: "assistant", icon: "sparkles", title: "Локальный ИИ",
                                example: "Попросите помощника сократить описание задачи и проверьте правку перед сохранением.", tint: .purple)
        #else
        let assistant = Feature(id: "assistant", icon: "sparkles", title: "Локальный ИИ · Preview",
                                example: "В сборке Preview попросите помощника сократить описание задачи и проверьте правку перед сохранением.", tint: .purple)
        #endif
        return [
            Feature(id: "tasks", icon: "checklist", title: "Задачи и напоминания",
                    example: "Поставьте задаче «Отправить отчёт» срок на 17:00 и получите напоминание.", tint: .indigo),
            Feature(id: "calendar", icon: "calendar.badge.plus", title: "События календаря",
                    example: "Добавьте «Встречу с командой» на завтра с 11:00 до 11:30.", tint: .teal),
            assistant
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 26) {
                    VStack(spacing: 7) {
                        Text(strings["Добро пожаловать в «Задачи»"])
                            .font(.system(size: 33, weight: .bold, design: .rounded))
                            .accessibilityAddTraits(.isHeader)
                        Text(strings["Планируйте день в своём ритме"])
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) { cards(compact: false) }
                        VStack(spacing: 12) { cards(compact: true) }
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

    private func cards(compact: Bool) -> some View {
        ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: feature.icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(feature.tint)
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
            .frame(minWidth: compact ? 0 : 202, idealWidth: compact ? nil : 246, maxWidth: .infinity,
                   minHeight: compact ? nil : 170, alignment: .topLeading)
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
