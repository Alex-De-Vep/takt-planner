import Foundation

struct SupportSubmission: Codable, Equatable, Sendable {
    let submissionId: String
    let subject: String?
    let message: String
    let replyEmail: String?
    let platform: String
    let appVersion: String
    let appBuild: String
    let osVersion: String
    let deviceTime: String

    init(subject: String? = nil, message: String, replyEmail: String? = nil,
         now: Date = .now, timeZone: TimeZone = .current) {
        submissionId = UUID().syncID
        self.subject = subject
        self.message = message
        self.replyEmail = replyEmail
        platform = "macos"
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = [os.majorVersion, os.minorVersion, os.patchVersion].map(String.init).joined(separator: ".")
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        deviceTime = formatter.string(from: now)
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValidSubject(_ subject: String) -> Bool {
        (1...120).contains(subject.unicodeScalars.count)
            && !subject.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    static func isValidMessage(_ message: String) -> Bool {
        (1...4000).contains(message.unicodeScalars.count) && !message.utf8.contains(0)
    }

    static func isValidReplyEmail(_ email: String) -> Bool {
        let pattern = #"\A[^\s@,;<>"\x00-\x1f\x7f]+@[^\s@,;<>"\x00-\x1f\x7f]+\.[^\s@,;<>"\x00-\x1f\x7f]+\z"#
        return email.unicodeScalars.count <= 254 && email.range(of: pattern, options: .regularExpression) != nil
    }

    var isValid: Bool {
        Self.isValidMessage(message)
            && (subject.map(Self.isValidSubject) ?? true)
            && (replyEmail.map(Self.isValidReplyEmail) ?? true)
    }

    static func prepare(subject: String? = nil, message: String, replyEmail: String? = nil, retrying pending: Self?) -> Self {
        if let pending, pending.subject == subject, pending.message == message, pending.replyEmail == replyEmail {
            return pending
        }
        return Self(subject: subject, message: message, replyEmail: replyEmail)
    }
}

struct SupportReceipt: Decodable, Sendable {
    let code: String
    let receivedAt: String

    var isValid: Bool {
        guard code.hasPrefix("TAKT-") else { return false }
        let digits = code.utf8.dropFirst(5)
        return (6...19).contains(digits.count) && digits.allSatisfy { (48...57).contains($0) }
            && SyncWire.date(receivedAt) != nil
    }
}
