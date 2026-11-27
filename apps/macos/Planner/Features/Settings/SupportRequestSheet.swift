import AppKit
import SwiftUI

struct SupportRequestSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.translations) private var strings
    let cloud: CloudWorkspace
    let service: TaskService?
    @State private var showingLogin = false

    var body: some View {
        Group {
            if let profile = cloud.profile {
                SupportRequestForm(cloud: cloud, profile: profile) { showingLogin = true }
                    .id(profile.sessionID)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text(strings["Написать нам"]).font(.title2.bold())
                    Text(strings["Войдите в аккаунт, чтобы написать в поддержку."])
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button(strings["Отмена"]) { dismiss() }.keyboardShortcut(.cancelAction)
                        Button(strings["Войти"]) { showingLogin = true }
                            .keyboardShortcut(.defaultAction).tint(PlannerStyle.settingsControlTint)
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 500)
        .sheet(isPresented: $showingLogin, onDismiss: { cloud.cancelSetup() }) {
            AccountForm(cloud: cloud, service: service, mode: .login, primaryTint: PlannerStyle.settingsControlTint)
        }
    }
}

private struct SupportRequestForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.translations) private var strings
    let cloud: CloudWorkspace
    let profile: SyncProfile
    let signIn: () -> Void
    @State private var subject: String
    @State private var message: String
    @State private var replyEmail: String
    @State private var pending: SupportSubmission?
    @State private var code: String?
    @State private var copied = false
    @State private var needsSignIn = false
    @State private var error: String?
    @State private var sending: Task<Void, Never>?

    init(cloud: CloudWorkspace, profile: SyncProfile, signIn: @escaping () -> Void) {
        self.cloud = cloud
        self.profile = profile
        self.signIn = signIn
        let saved = cloud.pendingSupportSubmission(for: profile)
        _pending = State(initialValue: saved)
        _subject = State(initialValue: saved?.subject ?? "")
        _message = State(initialValue: saved?.message ?? "")
        _replyEmail = State(initialValue: saved?.replyEmail ?? profile.account.email)
    }

    private var normalizedSubject: String { SupportSubmission.normalized(subject) }
    private var normalizedMessage: String { SupportSubmission.normalized(message) }
    private var normalizedReplyEmail: String { SupportSubmission.normalized(replyEmail) }
    private var validSubject: Bool { SupportSubmission.isValidSubject(normalizedSubject) }
    private var validMessage: Bool { SupportSubmission.isValidMessage(normalizedMessage) }
    private var validReplyEmail: Bool { SupportSubmission.isValidReplyEmail(normalizedReplyEmail) }
    private var valid: Bool { validMessage && (legacyRetry != nil || (validSubject && validReplyEmail)) }
    private var requiresLogin: Bool { needsSignIn || cloud.engine?.status == .signIn }

    private var legacyRetry: SupportSubmission? {
        // Preserve the original payload when retrying an unchanged request from an older build.
        guard let pending, pending.subject == nil, pending.replyEmail == nil, normalizedSubject.isEmpty,
              pending.message == normalizedMessage, normalizedReplyEmail == SupportSubmission.normalized(profile.account.email)
        else { return nil }
        return pending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let code {
                Text(strings["Обращение принято"]).font(.title2.bold())
                Text(strings["Код обращения"]).foregroundStyle(.secondary)
                Text(code).font(.title.monospacedDigit()).textSelection(.enabled)
                    .accessibilityIdentifier("support-receipt-code")
                HStack {
                    Spacer()
                    Button(strings[copied ? "Код скопирован" : "Скопировать код"]) {
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(code, forType: .string)
                    }
                    Button(strings["Закрыть"]) { dismiss() }.keyboardShortcut(.defaultAction).tint(PlannerStyle.settingsControlTint)
                }
            } else {
                Text(strings["Написать нам"]).font(.title2.bold())
                fields.disabled(sending != nil)
                if requiresLogin {
                    Text(strings["Войдите в аккаунт, чтобы написать в поддержку."]).foregroundStyle(.secondary)
                } else if let error {
                    Text(strings[error]).foregroundStyle(.red)
                }
                HStack {
                    if sending != nil { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(strings["Отмена"]) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(sending != nil)
                    if requiresLogin {
                        Button(strings["Войти"], action: signIn)
                            .keyboardShortcut(.defaultAction).tint(PlannerStyle.settingsControlTint)
                            .disabled(cloud.busy || sending != nil)
                    } else {
                        Button(strings["Отправить"], action: send)
                            .keyboardShortcut(.defaultAction).tint(PlannerStyle.settingsControlTint)
                            .accessibilityIdentifier("support-send")
                            .disabled(!valid || sending != nil || cloud.busy)
                    }
                }
            }
        }
        .padding(24)
        .interactiveDismissDisabled(sending != nil)
        .onDisappear { sending?.cancel() }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(strings["Тема"]).fontWeight(.medium)
                TextField(strings["Тема"], text: $subject)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("support-subject")
                if !normalizedSubject.isEmpty && !validSubject {
                    Text(strings["Укажите тему до 120 символов в одну строку."])
                        .font(.callout).foregroundStyle(.red)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(strings["Опишите проблему"]).fontWeight(.medium)
                TextEditor(text: $message)
                    .font(.body)
                    .frame(height: 120)
                    .border(.quaternary)
                    .accessibilityLabel(strings["Опишите проблему"])
                    .accessibilityIdentifier("support-description")
                if !normalizedMessage.isEmpty && !validMessage {
                    Text(strings["Описание должно содержать от 1 до 4000 символов."])
                        .font(.callout).foregroundStyle(.red)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(strings["Почта для ответа"]).fontWeight(.medium)
                TextField("", text: $replyEmail, prompt: Text(strings["Почта"]))
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .accessibilityLabel(strings["Почта для ответа"])
                    .accessibilityIdentifier("support-reply-email")
                if !normalizedReplyEmail.isEmpty && !validReplyEmail && legacyRetry == nil {
                    Text(strings["Укажите корректный адрес почты."])
                        .font(.callout).foregroundStyle(.red)
                }
            }
        }
    }

    private func send() {
        guard valid, sending == nil, !requiresLogin else { return }
        let submission = legacyRetry ?? SupportSubmission.prepare(
            subject: normalizedSubject, message: normalizedMessage, replyEmail: normalizedReplyEmail, retrying: pending
        )
        pending = submission
        error = nil
        sending = Task {
            defer { sending = nil }
            do {
                code = try await cloud.sendSupport(submission, for: profile)
            } catch is CancellationError {
                return
            } catch SyncProblem.signInRequired {
                needsSignIn = true
            } catch let failure as SyncHTTPFailure {
                if failure.status == 429 {
                    error = "Слишком много обращений. Попробуйте позже."
                } else if failure.status == 404 || failure.problem.code == "support_unavailable" {
                    error = "Канал поддержки пока недоступен. Попробуйте позже."
                } else {
                    error = "Не удалось отправить обращение. Повторите попытку."
                }
            } catch {
                self.error = "Не удалось отправить обращение. Повторите попытку."
            }
        }
    }
}
