import Foundation
import PlannerLocalization
import SwiftData
import Testing
@testable import Planner

@MainActor
struct SupportSubmissionTests {
    @Test func unchangedRetryKeepsAllFieldsAndAnEditGetsANewID() throws {
        let message = SupportSubmission.normalized("  Первая строка\nSecond line  ")
        let original = SupportSubmission(message: message, now: Date(timeIntervalSince1970: 1_800_000_000),
            timeZone: try #require(TimeZone(secondsFromGMT: 10_800)))
        #expect(message == "Первая строка\nSecond line")
        #expect(original.platform == "macos")
        #expect(original.deviceTime.hasSuffix("+03:00"))
        #expect(original.submissionId == original.submissionId.lowercased())
        #expect(SupportSubmission.prepare(message: message, retrying: original) == original)
        #expect(SupportSubmission.prepare(message: "Different issue", retrying: original).submissionId != original.submissionId)
        #expect(SupportSubmission.isValid(String(repeating: "😀", count: 4000)))
        #expect(!SupportSubmission.isValid(String(repeating: "😀", count: 4001)))
        #expect(!SupportSubmission.isValid(SupportSubmission.normalized(" \n ")))
    }

    @Test func formLabelsAreAvailableInBothLanguages() {
        let russian = Translations(language: .russian)
        let english = Translations(language: .english)
        #expect(russian["Написать нам"] == "Написать нам")
        #expect(english["Написать нам"] == "Contact us")
        #expect(english["Опишите проблему"] == "Describe the issue")
        #expect(english["Скопировать код"] == "Copy code")
        #expect(english.format("%@ (сборка %@)", "0.3.49", "133") == "0.3.49 (build 133)")
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
        let submission = SupportSubmission(message: "Mac fixture: receipt lost")
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
