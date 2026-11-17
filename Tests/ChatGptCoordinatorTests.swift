import Foundation
import ParakattCore
import SwiftUI
import XCTest
@testable import ParakattApp

private final class ChatGptAccountFixture: ChatGptAccountsProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var selected = "one"
    private var requests: [String] = []
    private var signedOut = false
    private var paused: Bool
    private let accountIDs: [String]
    let planEnabled: Bool
    init(planEnabled: Bool = true, paused: Bool = false, signedOut: Bool = false, accountIDs: [String] = ["one", "two"]) {
        self.planEnabled = planEnabled
        self.paused = paused
        self.signedOut = signedOut
        self.accountIDs = accountIDs
    }
    func list() throws -> [ChatGptAccount] {
        lock.withLock {
            accountIDs.map { id in
                ChatGptAccount(id: id, label: "same@example.test (\(id))", signedIn: !signedOut, planEnabled: planEnabled, paused: paused, active: id == selected)
            }
        }
    }
    func select(accountId: String) throws { lock.withLock { selected = accountId } }
    func models(accountId: String?) throws -> [ChatGptModelChoice] {
        let id = accountId ?? "one"
        lock.withLock { requests.append(id) }
        return [ChatGptModelChoice(slug: "model-\(id)", displayName: "Model \(id)")]
    }
    func modelRequests() -> [String] { lock.withLock { requests } }
    func retry(accountId: String?) throws { lock.withLock { paused = false } }
    func signOut(accountId: String?) throws -> ChatGptSignOut {
        lock.withLock { signedOut = true }
        return ChatGptSignOut(revoked: false, message: "Remote revocation was not confirmed.")
    }
    func beginSignIn(accountId: String?) throws -> ChatGptSignIn { throw CocoaError(.userCancelled) }
    func completeSignIn(attemptId: String) throws -> ChatGptAccount { throw CocoaError(.userCancelled) }
    func cancelSignIn(attemptId: String) {}
    func takePlanConfirmation(accountId: String) throws -> Bool { false }
}

final class ChatGptCoordinatorTests: XCTestCase {
    @MainActor
    private func waitUntilIdle(_ coordinator: ChatGptCoordinator) async throws {
        for _ in 0..<200 where coordinator.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(coordinator.busy)
    }
    @MainActor
    func testAccountSwitchReplacesCatalogAndKeepsDistinctRegistrations() async throws {
        let service = ChatGptAccountFixture()
        let coordinator = ChatGptCoordinator(service: service)
        coordinator.reload()
        try await waitUntilIdle(coordinator)
        XCTAssertEqual(coordinator.models.map(\.slug), ["model-one"])
        XCTAssertEqual(coordinator.accounts.count, 2)
        coordinator.select("two")
        XCTAssertTrue(coordinator.models.isEmpty)
        try await waitUntilIdle(coordinator)
        XCTAssertEqual(coordinator.selectedAccount, "two")
        XCTAssertEqual(coordinator.models.map(\.slug), ["model-two"])
        XCTAssertEqual(service.modelRequests(), ["one", "two"])
    }
    @MainActor
    func testMissingPlanConsentDoesNotFetchModels() async throws {
        let service = ChatGptAccountFixture(planEnabled: false)
        let coordinator = ChatGptCoordinator(service: service)
        coordinator.reload(preferredAccount: "two")
        try await waitUntilIdle(coordinator)
        XCTAssertEqual(coordinator.selectedAccount, "two")
        XCTAssertTrue(coordinator.models.isEmpty)
        XCTAssertTrue(service.modelRequests().isEmpty)
    }
    @MainActor
    func testSignOutClearsCatalogAndReportsUnconfirmedRevocation() async throws {
        let coordinator = ChatGptCoordinator(service: ChatGptAccountFixture())
        coordinator.reload()
        try await waitUntilIdle(coordinator)
        coordinator.signOut()
        XCTAssertTrue(coordinator.models.isEmpty)
        try await waitUntilIdle(coordinator)
        XCTAssertFalse(coordinator.accounts.first?.signedIn ?? true)
        XCTAssertTrue(coordinator.message.contains("not confirmed"))
    }
    @MainActor
    func testCancelledSignInDoesNotReplaceSavedAccount() async throws {
        let coordinator = ChatGptCoordinator(service: ChatGptAccountFixture())
        coordinator.reload()
        try await waitUntilIdle(coordinator)
        coordinator.signIn(addAccount: true)
        coordinator.cancelSignIn()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(coordinator.selectedAccount, "one")
        XCTAssertFalse(coordinator.signingIn)
        XCTAssertEqual(coordinator.message, "Sign-in cancelled.")
    }

    @MainActor
    func testRetryRefreshesPausedAccountStatus() async throws {
        let coordinator = ChatGptCoordinator(service: ChatGptAccountFixture(paused: true))
        coordinator.reload()
        try await waitUntilIdle(coordinator)
        XCTAssertTrue(coordinator.accounts.first?.paused ?? false)
        coordinator.fetchModels(retry: true)
        try await waitUntilIdle(coordinator)
        XCTAssertFalse(coordinator.accounts.first?.paused ?? true)
        XCTAssertEqual(coordinator.models.map(\.slug), ["model-one"])
    }

    /// Optional PNGs use isolated account fixtures, never a user's credentials.
    @MainActor
    func testSettingsLayoutInLightDarkAndRecoveryStates() async throws {
        for (name, service, appearance) in [
            ("connected-dark", ChatGptAccountFixture(accountIDs: ["one"]), NSAppearance.Name.darkAqua),
            ("accounts-light", ChatGptAccountFixture(), NSAppearance.Name.aqua),
            ("paused-dark", ChatGptAccountFixture(paused: true), NSAppearance.Name.darkAqua),
            ("consent-light", ChatGptAccountFixture(planEnabled: false), NSAppearance.Name.aqua),
            ("signed-out-dark", ChatGptAccountFixture(signedOut: true), NSAppearance.Name.darkAqua),
            ("none-light", ChatGptAccountFixture(accountIDs: []), NSAppearance.Name.aqua),
            ("ollama-dark", ChatGptAccountFixture(accountIDs: []), NSAppearance.Name.darkAqua),
            ("lmstudio-light", ChatGptAccountFixture(accountIDs: []), NSAppearance.Name.aqua),
            ("openai-light", ChatGptAccountFixture(accountIDs: []), NSAppearance.Name.aqua),
            ("anthropic-dark", ChatGptAccountFixture(accountIDs: []), NSAppearance.Name.darkAqua),
        ] {
            let coordinator = ChatGptCoordinator(service: service)
            coordinator.reload()
            try await waitUntilIdle(coordinator)
            let state = AppState()
            state.settings.readCredential = { _ in nil }
            state.settings.writeCredential = { _, _ in true }
            let provider = String(name.split(separator: "-").first ?? "")
            state.llmProvider = provider == "none" ? "" : (["ollama", "lmstudio", "openai", "anthropic"].contains(provider) ? provider : "chatgpt")
            state.llmBaseUrl = "http://localhost:11434"
            state.llmApiKey = "fixture-key"
            state.llmModel = "model-one"
            state.activeMode = "punctuation"
            let host = NSHostingView(rootView: LlmSettingsView(account: coordinator)
                .environmentObject(state)
                .padding(16)
                .frame(width: 560)
                .background(Color(nsColor: .windowBackgroundColor)))
            let size = NSSize(width: 560, height: 820)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, size.width, name)
            XCTAssertLessThanOrEqual(host.fittingSize.height, size.height, name)
            if let output = ProcessInfo.processInfo.environment["PARAKATT_CHATGPT_SETTINGS_SNAPSHOTS"] {
                let destination = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: destination.appendingPathComponent("\(name).png"))
            }
            window.close()
        }
    }
}

final class ChatGptSettingsPresentationTests: XCTestCase {
    private func account(id: String = "one", label: String? = nil, signedIn: Bool = true, planEnabled: Bool = true, paused: Bool = false) -> ChatGptAccount {
        ChatGptAccount(id: id, label: label ?? "person@example.test (\(id))", signedIn: signedIn, planEnabled: planEnabled, paused: paused, active: true)
    }

    func testAccountLabelHidesRegistrationID() {
        let saved = account()
        XCTAssertEqual(ChatGptSettingsPresentation.accountName(saved, among: [saved]), "person@example.test")
    }

    func testSameEmailRegistrationsRemainDistinguishableWithoutUUIDs() {
        let first = account()
        let second = account(id: "two")
        XCTAssertEqual(ChatGptSettingsPresentation.accountName(first, among: [first, second]), "person@example.test — Account 1")
        XCTAssertEqual(ChatGptSettingsPresentation.accountName(second, among: [first, second]), "person@example.test — Account 2")
    }

    func testCustomLabelIsNotTruncated() {
        let saved = account(label: "Work (Europe)")
        XCTAssertEqual(ChatGptSettingsPresentation.accountName(saved, among: [saved]), "Work (Europe)")
    }

    func testStatusRequiresSignInAndPlanPermission() {
        XCTAssertEqual(ChatGptSettingsPresentation.status(nil), "Not connected")
        XCTAssertEqual(ChatGptSettingsPresentation.status(account(signedIn: false)), "Not connected")
        XCTAssertEqual(ChatGptSettingsPresentation.status(account(planEnabled: false)), "Permission needed")
        XCTAssertEqual(ChatGptSettingsPresentation.status(account(paused: true)), "Usage paused")
        XCTAssertEqual(ChatGptSettingsPresentation.status(account()), "Connected")
    }

    func testDiagnosticSuccessRequiresTheExplicitSuccessPrefix() {
        XCTAssertTrue(ChatGptSettingsPresentation.testPassed("OK\nConnection: Passed\nCompletion: Passed"))
        XCTAssertFalse(ChatGptSettingsPresentation.testPassed("Connection: Passed\nCompletion: Failed"))
        XCTAssertFalse(ChatGptSettingsPresentation.testPassed("Request failed: expected OK"))
    }
}
