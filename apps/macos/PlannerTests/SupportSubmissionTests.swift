import Foundation
import PlannerLocalization
import SwiftData
import Testing
@testable import Planner

@MainActor
struct SupportSubmissionTests {
    @Test func unchangedRetryKeepsAllFieldsAndAnEditGetsANewID() throws {
        let subject = "Sync issue"
        let message = SupportSubmission.normalized("  Первая строка\nSecond line  ")
        let replyEmail = "support+reply@example.test"
        let original = SupportSubmission(subject: subject, message: message, replyEmail: replyEmail,
            now: Date(timeIntervalSince1970: 1_800_000_000),
            timeZone: try #require(TimeZone(secondsFromGMT: 10_800)))
        #expect(message == "Первая строка\nSecond line")
        #expect(original.platform == "macos")
        #expect(original.isValid)
        #expect(original.deviceTime.hasSuffix("+03:00"))
        #expect(original.submissionId == original.submissionId.lowercased())
        #expect(SupportSubmission.prepare(subject: subject, message: message, replyEmail: replyEmail, retrying: original) == original)
        for edit in [
            SupportSubmission.prepare(subject: "New subject", message: message, replyEmail: replyEmail, retrying: original),
            SupportSubmission.prepare(subject: subject, message: "Different issue", replyEmail: replyEmail, retrying: original),
            SupportSubmission.prepare(subject: subject, message: message, replyEmail: "other@example.test", retrying: original),
        ] {
            #expect(edit.submissionId != original.submissionId)
        }
        let payload = try #require(JSONSerialization.jsonObject(with: SyncHTTP.payload(original)) as? [String: String])
        #expect(payload["subject"] == subject)
        #expect(payload["replyEmail"] == replyEmail)
    }

    @Test func validatesEditableFields() {
        #expect(SupportSubmission.isValidSubject(String(repeating: "😀", count: 120)))
        #expect(!SupportSubmission.isValidSubject(String(repeating: "😀", count: 121)))
        #expect(!SupportSubmission.isValidSubject("First line\nSecond line"))
        #expect(SupportSubmission.isValidMessage(String(repeating: "😀", count: 4000)))
        #expect(!SupportSubmission.isValidMessage(String(repeating: "😀", count: 4001)))
        #expect(!SupportSubmission.isValidMessage(SupportSubmission.normalized(" \n ")))
        #expect(SupportSubmission.isValidReplyEmail("support+reply@example.test"))
        #expect(!SupportSubmission.isValidReplyEmail("reply@example.test,other@example.test"))
        #expect(!SupportSubmission.isValidReplyEmail("reply@example"))
        #expect(!SupportSubmission.isValidReplyEmail("reply@example.test\n"))
    }

    @Test func retriesAnOlderDraftWithTheOriginalPayload() throws {
        let legacyPayload = """
        {
          "submissionId": "8ecd5999-b7b9-46ea-9114-ef8ef8b1fa46",
          "message": "Draft that previously failed",
          "platform": "macos",
          "appVersion": "0.3.49",
          "appBuild": "133",
          "osVersion": "26.1.0",
          "deviceTime": "2026-11-27T11:00:00+03:00"
        }
        """
        let bytes = Data(legacyPayload.utf8)
        let draft = try JSONDecoder().decode(SupportSubmission.self, from: bytes)
        #expect(draft.isValid)
        let retry = SupportSubmission.prepare(message: draft.message, retrying: draft)
        #expect(retry == draft)
        let original = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: String])
        let encoded = try #require(JSONSerialization.jsonObject(with: SyncHTTP.payload(retry)) as? [String: String])
        #expect(encoded == original)
    }

    @Test func formLabelsAreAvailableInBothLanguages() {
        let russian = Translations(language: .russian)
        let english = Translations(language: .english)
        #expect(russian["Написать нам"] == "Написать нам")
        #expect(russian["Тема"] == "Тема")
        #expect(russian["Почта для ответа"] == "Почта для ответа")
        #expect(english["Написать нам"] == "Contact us")
        #expect(english["Тема"] == "Subject")
        #expect(english["Опишите проблему"] == "Describe the issue")
        #expect(english["Почта для ответа"] == "Reply email")
        #expect(english["Скопировать код"] == "Copy code")
    }

    @Test func signedOutAccountCannotReadOrSendItsPreviousDraft() async throws {
        let name = "SupportSubmission-" + UUID().syncID
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let account = SyncAccount(id: UUID().syncID, email: "a@example.test", libraryId: UUID().syncID)
        let profile = SyncProfile(account: account, sessionID: UUID().syncID)
        let sample = SupportSubmission(message: "Draft that previously failed")
        defaults.set(try JSONEncoder().encode(profile), forKey: "planner.cloud.profile")
        defaults.set(try JSONEncoder().encode(sample), forKey: "planner.support.pending." + account.id)
        let cloud = CloudWorkspace(defaults: defaults)
        #expect(cloud.pendingSupportSubmission(for: profile) == sample)
        await cloud.signOut()
        #expect(cloud.profile == nil)
        #expect(cloud.pendingSupportSubmission(for: profile) == nil)
        await #expect(throws: SyncProblem.signInRequired) {
            _ = try await cloud.sendSupport(sample, for: profile)
        }
        let next = SyncProfile(account: account, sessionID: UUID().syncID)
        defaults.set(try JSONEncoder().encode(next), forKey: "planner.cloud.profile")
        #expect(CloudWorkspace(defaults: defaults).pendingSupportSubmission(for: next) == sample)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PLANNER_SUPPORT_TEST_ORIGIN"] != nil))
    func recoversTheServerReceiptAfterALostReplyAndSignIn() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["PLANNER_SUPPORT_TEST_ORIGIN"])
        let origin = try #require(URL(string: address))
        try #require(origin.scheme == "http" && origin.host == "127.0.0.1")

        let name = "SupportPilot-" + UUID().syncID
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appending(path: name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let storage = root.appending(path: "Planner.store")
        let cloud = CloudWorkspace(defaults: defaults, origin: origin, storeURL: storage) { _ in
            TestCredential(url: root.appending(path: "test-credential"))
        }
        let local = try PlannerPersistence.makeContainer(inMemory: true)
        var active = CloudLibrary(container: local, service: TaskService(context: local.mainContext))
        cloud.didOpen = { active = $0 }
        try await cloud.signIn(email: "mac@example.test", password: "Support-fixture-only-2026", activeService: active.service)
        defer { cloud.engine?.stop() }
        let before = try #require(cloud.profile)
        let submission = SupportSubmission(subject: "Sync issue", message: "Mac fixture: receipt lost",
            replyEmail: "support+mac@example.test")
        do {
            _ = try await cloud.sendSupport(submission, for: before)
            Issue.record("The test server should withhold the first receipt")
        } catch let failure as SyncHTTPFailure {
            #expect(failure.problem.code == "fixture_lost_response")
        }
        #expect(cloud.pendingSupportSubmission(for: before) == submission)
        await cloud.signOut()
        #expect(cloud.pendingSupportSubmission(for: before) == nil)
        try await cloud.signIn(email: "mac@example.test", password: "Support-fixture-only-2026", activeService: active.service)
        let after = try #require(cloud.profile)
        #expect(after.sessionID != before.sessionID)
        let saved = try #require(cloud.pendingSupportSubmission(for: after))
        let receipt = try await cloud.sendSupport(saved, for: after)
        #expect(receipt.hasPrefix("TAKT-"))
        #expect(cloud.pendingSupportSubmission(for: after) == nil)
    }

    private struct TestCredential: SyncCredentialStore {
        let url: URL
        func load() throws -> SyncRefreshCredential? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try JSONDecoder().decode(SyncRefreshCredential.self, from: Data(contentsOf: url))
        }
        func save(_ value: SyncRefreshCredential) throws {
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        }
        func remove() throws {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}
