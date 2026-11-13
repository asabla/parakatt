import AppKit
import Combine
import Foundation
import ParakattCore

/// Account work runs off the main thread. Tokens never cross the Swift boundary.
@MainActor
final class ChatGptCoordinator: ObservableObject {
    @Published private(set) var accounts: [ChatGptAccount] = []
    @Published private(set) var models: [ChatGptModelChoice] = []
    @Published private(set) var selectedAccount = ""
    @Published private(set) var busy = false
    @Published private(set) var signingIn = false
    @Published var message = ""
    @Published var showPlanConfirmation = false
    private let service: (any ChatGptAccountsProtocol)?
    private var attemptID: String?
    private var revision = 0
    static let usageURL = URL(string: "https://chatgpt.com/settings/usage")

    init(service: (any ChatGptAccountsProtocol)? = try? ChatGptAccounts()) {
        self.service = service
    }

    func reload(preferredAccount: String? = nil) {
        guard let service, !busy else { return }
        busy = true
        revision += 1
        let requestRevision = revision
        Task {
            do {
                let saved = try await Task.detached { try service.list() }.value
                guard requestRevision == revision else { return }
                accounts = saved
                let preferred = preferredAccount ?? selectedAccount
                selectedAccount = saved.first(where: { $0.id == preferred })?.id ?? saved.first(where: \.active)?.id ?? ""
                models = []
                busy = false
                fetchModels()
            } catch { busy = false; message = String(describing: error) }
        }
    }

    func select(_ id: String) {
        guard let service, !busy else { return }
        revision += 1
        models = []
        busy = true
        Task {
            do {
                try await Task.detached { try service.select(accountId: id) }.value
                selectedAccount = id
                busy = false
                reload(preferredAccount: id)
            } catch { busy = false; message = String(describing: error) }
        }
    }

    func signIn(addAccount: Bool = false) {
        guard let service, !busy else { return }
        busy = true
        signingIn = true
        message = "Complete sign-in in your browser."
        let accountID = addAccount || selectedAccount.isEmpty ? nil : selectedAccount
        revision += 1
        let requestRevision = revision
        Task {
            do {
                let attempt = try await Task.detached { try service.beginSignIn(accountId: accountID) }.value
                guard requestRevision == revision else { service.cancelSignIn(attemptId: attempt.id); return }
                attemptID = attempt.id
                guard let url = URL(string: attempt.authorizationUrl), NSWorkspace.shared.open(url) else {
                    service.cancelSignIn(attemptId: attempt.id)
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                let account = try await Task.detached { try service.completeSignIn(attemptId: attempt.id) }.value
                guard requestRevision == revision else { return }
                attemptID = nil
                selectedAccount = account.id
                showPlanConfirmation = try await Task.detached { try service.takePlanConfirmation(accountId: account.id) }.value
                busy = false
                signingIn = false
                message = account.planEnabled ? "ChatGPT plan connected." : "Plan access is disabled. Continue with ChatGPT to grant permission."
                reload(preferredAccount: account.id)
            } catch {
                guard requestRevision == revision else { return }
                attemptID = nil
                busy = false
                signingIn = false
                message = String(describing: error)
            }
        }
    }

    func cancelSignIn() {
        revision += 1
        if let attemptID { service?.cancelSignIn(attemptId: attemptID) }
        attemptID = nil
        busy = false
        signingIn = false
        message = "Sign-in cancelled."
    }

    func signOut() {
        guard let service, !busy, !selectedAccount.isEmpty else { return }
        let accountID = selectedAccount
        revision += 1
        models = []
        busy = true
        Task {
            do {
                let result = try await Task.detached { try service.signOut(accountId: accountID) }.value
                message = result.message
                busy = false
                reload(preferredAccount: accountID)
            } catch { busy = false; message = String(describing: error) }
        }
    }

    func fetchModels(retry: Bool = false) {
        guard let service, !busy, !selectedAccount.isEmpty else { return }
        guard accounts.contains(where: { $0.id == selectedAccount && $0.signedIn && $0.planEnabled }) else { return }
        let accountID = selectedAccount
        let requestRevision = revision
        busy = true
        Task {
            do {
                let (choices, saved) = try await Task.detached {
                    if retry { try service.retry(accountId: accountID) }
                    return (try service.models(accountId: accountID), try service.list())
                }.value
                guard requestRevision == revision, accountID == selectedAccount else { return }
                models = choices
                accounts = saved
                busy = false
                message = choices.isEmpty ? "No models are available for this account." : ""
            } catch {
                guard requestRevision == revision else { return }
                busy = false
                message = String(describing: error)
            }
        }
    }
}
