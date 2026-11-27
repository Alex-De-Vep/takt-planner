import Foundation

struct SupportSubmission: Codable, Equatable, Sendable {
    let submissionId: String
    let message: String
    let platform: String
    let appVersion: String
    let appBuild: String
    let osVersion: String
    let deviceTime: String

    init(message: String = "", now: Date = .now, timeZone: TimeZone = .current) {
        submissionId = UUID().syncID
        self.message = message
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

    static func isValid(_ message: String) -> Bool {
        (1...4000).contains(message.unicodeScalars.count) && !message.utf8.contains(0)
    }

    static func prepare(message: String, retrying pending: Self?) -> Self {
        if let pending, pending.message == message { return pending }
        return Self(message: message)
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
