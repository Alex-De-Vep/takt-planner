import SwiftUI

struct CloudSettingsSection: View {
    @Environment(\.translations) private var strings
    @Bindable var cloud: CloudWorkspace
    let service: TaskService?
    @State private var mode: AccountForm.Mode?
    @State private var confirmsSignOut = false

    var body: some View {
        Section {
            LabeledContent(strings["Аккаунт"], value: cloud.profile?.account.email ?? strings["Вход не выполнен"])
                .accessibilityIdentifier("settings-account")
            if cloud.profile != nil {
                LabeledContent(strings["Синхронизация"], value: status)
                if let engine = cloud.engine, engine.pending > 0 {
                    LabeledContent(strings["Ожидают отправки"], value: String(engine.pending))
                }
                HStack {
                    Button(strings["Синхронизировать"]) { cloud.engine?.wake() }
                    if cloud.engine?.status == .signIn {
                        Button(strings["Войти повторно"]) { mode = .login }
                    }
                }
                Button(strings["Выйти из аккаунта"]) { confirmsSignOut = true }
                    .disabled(cloud.busy)
            } else {
                Text(strings["Задачи хранятся на этом Mac."])
                HStack {
                    Button(strings["Войти"]) { mode = .login }
                    Button(strings["Создать аккаунт"]) { mode = .register }
                }
            }
            if let error = cloud.error { Text(strings[error]).foregroundStyle(.red) }
        } header: {
            Label(strings["Хранение и синхронизация"], systemImage: "icloud")
        }
        .sheet(item: $mode, onDismiss: { cloud.cancelSetup() }) { mode in
            AccountForm(cloud: cloud, service: service, mode: mode)
        }
        .confirmationDialog(strings["Выйти из аккаунта?"], isPresented: $confirmsSignOut) {
            Button(strings["Выйти из аккаунта"]) { Task { await cloud.signOut() } }
        } message: {
            Text(strings["Задачи останутся на этом Mac. Синхронизация возобновится при следующем входе."])
        }
    }

    private var status: String {
        switch cloud.engine?.status {
        case .upToDate: strings["Синхронизировано"]
        case .syncing: strings["Синхронизация…"]
        case .signIn: strings["Требуется вход"]
        case .failed(let error): strings[error]
        default: strings["Сохранено на Mac · ожидание обмена"]
        }
    }
}

struct AccountForm: View {
    enum Mode: String, Identifiable {
        case login, register, verify, reset, resetCode
        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.translations) private var strings
    @Bindable var cloud: CloudWorkspace
    let service: TaskService?
    @State var mode: Mode
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var challengeID: String?
    @State private var error: String?
    @State private var working = false
    @State private var retryAt = Date.distantPast
    @State private var resendAt = Date.distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let setup = cloud.setup {
                Text(strings["Подключение синхронизации"]).font(.title2.bold())
                Text(setup.profile.account.email).foregroundStyle(.secondary)
                Text(strings["Перенести текущие задачи в этот аккаунт?"])
                Button(strings["Войти без переноса"]) { connect(importLocal: false) }
                    .buttonStyle(.borderedProminent)
                Button(strings["Перенести задачи и войти"]) { connect(importLocal: true) }
                if let error = cloud.error { Text(strings[error]).foregroundStyle(.red) }
            } else {
                Text(title).font(.title2.bold())
                TextField(strings["Почта"], text: $email).textContentType(.emailAddress)
                    .accessibilityIdentifier("sync-email")
                    .disabled(mode == .verify || mode == .resetCode)
                if mode == .verify || mode == .resetCode {
                    Text(strings["Введите восьмизначный код из письма."])
                        .foregroundStyle(.secondary)
                    TextField(strings["Код из письма"], text: $code).textContentType(.oneTimeCode)
                }
                if mode != .reset {
                    SecureField(strings[mode == .resetCode ? "Новый пароль" : "Пароль"], text: $password)
                        .textContentType(mode == .login ? .password : .newPassword)
                        .accessibilityIdentifier("sync-password")
                }
                if mode == .register || mode == .resetCode {
                    Text(strings["От 12 до 128 символов."]).font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(strings[error]).foregroundStyle(.red) }
                TimelineView(.periodic(from: .now, by: 1)) { time in
                    let remaining = max(0, Int(ceil(retryAt.timeIntervalSince(time.date))))
                    HStack {
                        Button(actionTitle) { submit() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!valid || remaining > 0)
                            .accessibilityIdentifier("sync-submit")
                        if mode == .verify {
                            Button(strings["Отправить код снова"]) { requestCode(resend: true) }
                                .disabled(remaining > 0 || time.date < resendAt)
                        }
                        if remaining > 0 { Text("\(remaining) s").font(.caption).monospacedDigit() }
                    }
                }
                HStack {
                    if mode == .login {
                        Button(strings["Создать аккаунт"]) { changeMode(.register) }
                        Button(strings["Забыли пароль?"]) { changeMode(.reset) }
                    } else {
                        Button(strings["Вернуться ко входу"]) { changeMode(.login) }
                    }
                }
                .buttonStyle(.borderless)
            }
            Divider()
            HStack {
                if working || cloud.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(strings["Отмена"]) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .disabled(working || cloud.busy)
        .interactiveDismissDisabled(working || cloud.busy)
        .padding(26)
        .frame(width: 440)
        .onAppear { if mode == .login { email = cloud.signInEmail ?? "" } }
    }

    private var title: String {
        let key = switch mode {
        case .login: "Вход в аккаунт"
        case .register: "Создание аккаунта"
        case .verify: "Подтверждение почты"
        case .reset, .resetCode: "Восстановление пароля"
        }
        return strings[key]
    }

    private var actionTitle: String {
        let key = switch mode {
        case .login: "Войти"
        case .register, .reset: "Получить код"
        case .verify: "Подтвердить и войти"
        case .resetCode: "Сохранить пароль"
        }
        return strings[key]
    }

    private var valid: Bool {
        let pass = (12...128).contains(password.unicodeScalars.count)
        let validCode = code.utf8.count == 8 && code.utf8.allSatisfy { (48...57).contains($0) }
        switch mode {
        case .login: return email.contains("@") && !password.isEmpty
        case .register: return email.contains("@") && pass
        case .reset: return email.contains("@")
        case .verify, .resetCode: return validCode && pass && challengeID != nil
        }
    }

    private func changeMode(_ next: Mode) {
        mode = next
        challengeID = nil
        password = ""
        code = ""
        error = nil
    }

    private func connect(importLocal: Bool) {
        Task {
            await cloud.connect(importLocal: importLocal, activeService: service)
            if cloud.profile != nil { dismiss() }
        }
    }

    private func requestCode(resend: Bool) {
        run {
            let reset = mode == .reset
            let path = reset ? "/v1/auth/password-reset/request" :
                (resend ? "/v1/auth/resend-verification" : "/v1/auth/register")
            challengeID = try await cloud.challenge(email: email, password: reset || resend ? nil : password, path: path)
            code = ""
            mode = reset ? .resetCode : .verify
            resendAt = .now.addingTimeInterval(60)
        }
    }

    private func submit() {
        switch mode {
        case .register, .reset: requestCode(resend: false)
        case .login:
            run {
                do { try await signIn() }
                catch let failure as SyncHTTPFailure where failure.problem.code == "email_not_verified" {
                    challengeID = try await cloud.challenge(email: email, password: nil, path: "/v1/auth/resend-verification")
                    mode = .verify
                    resendAt = .now.addingTimeInterval(60)
                }
            }
        case .verify, .resetCode:
            guard let challengeID else { return }
            run {
                let reset = mode == .resetCode
                try await cloud.confirm(challengeID: challengeID, code: code, password: password, reset: reset)
                if reset { changeMode(.login) }
                else {
                    mode = .login
                    try await signIn()
                }
            }
        }
    }

    private func signIn() async throws {
        try await cloud.signIn(email: email, password: password, activeService: service)
        password = ""
        if cloud.setup == nil { dismiss() }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do { try await operation() }
            catch let failure as SyncHTTPFailure {
                if let delay = failure.problem.retryAfterSeconds { retryAt = .now.addingTimeInterval(Double(delay)) }
                error = failure.problem.message
            } catch { self.error = error.localizedDescription }
        }
    }
}
