import ParakattCore
import SwiftUI

/// Presentation only: account IDs remain the selection keys, never the primary labels.
enum ChatGptSettingsPresentation {
    static func accountName(_ account: ChatGptAccount, among accounts: [ChatGptAccount]) -> String {
        let name = displayName(account)
        let matches = accounts.filter { displayName($0) == name }
        guard matches.count > 1, let index = matches.firstIndex(where: { $0.id == account.id }) else { return name }
        return "\(name) — Account \(index + 1)"
    }

    private static func displayName(_ account: ChatGptAccount) -> String {
        let suffix = " (\(account.id))"
        return account.label.hasSuffix(suffix) ? String(account.label.dropLast(suffix.count)) : account.label
    }

    static func status(_ account: ChatGptAccount?) -> String {
        guard let account, account.signedIn else { return "Not connected" }
        if !account.planEnabled { return "Permission needed" }
        return account.paused ? "Usage paused" : "Connected"
    }

    static func testPassed(_ result: String) -> Bool { result.hasPrefix("OK\n") }
}

struct ChatGptSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var account: ChatGptCoordinator
    var disabled = false

    private var selectedAccount: ChatGptAccount? { account.accounts.first { $0.id == account.selectedAccount } }
    private var planEnabled: Bool { selectedAccount.map { $0.signedIn && $0.planEnabled } ?? false }
    private var usagePaused: Bool {
        selectedAccount?.paused == true
    }
    private var busy: Bool { account.busy || disabled }
    private var statusColor: Color { usagePaused ? .orange : (planEnabled ? .green : .secondary) }

    var body: some View {
        accountSection
        .onAppear { account.reload(preferredAccount: appState.chatGptAccount()) }
        .onChange(of: account.selectedAccount) { _, id in
            if let saved = appState.chatGptAccount(), saved != id { appState.settings.llmModel = "" }
            do { try appState.setChatGptAccount(id.isEmpty ? nil : id) }
            catch { account.message = String(describing: error) }
        }
        .alert("You’re using your ChatGPT plan", isPresented: $account.showPlanConfirmation) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("Eligible usage in Parakatt uses your ChatGPT plan. Manage usage in your ChatGPT settings.")
        }
    }

    private var accountSection: some View {
        LlmSettingsSection(title: "Connection", icon: "person.crop.circle") {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(planEnabled ? .green : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    if account.accounts.count > 1 {
                        Picker("Account", selection: Binding(get: { account.selectedAccount }, set: { account.select($0) })) {
                            ForEach(account.accounts, id: \.id) { saved in
                                Text(ChatGptSettingsPresentation.accountName(saved, among: account.accounts)).tag(saved.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(busy)
                    } else {
                        Text(selectedAccount.map { ChatGptSettingsPresentation.accountName($0, among: account.accounts) } ?? "Sign in to ChatGPT")
                            .font(.system(.body, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Text(planEnabled ? "Use your ChatGPT plan or available credits." : "Connect your account to enable text processing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(usagePaused ? "Usage paused" : ChatGptSettingsPresentation.status(selectedAccount))
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(statusColor)
                    .background(statusColor.opacity(0.12), in: Capsule())
                    .fixedSize()
                if !account.accounts.isEmpty {
                    Menu {
                        Button("Add account…") { account.signIn(addAccount: true) }
                        if selectedAccount?.signedIn == true {
                            Button("Sign in again…") { account.signIn() }
                            Divider()
                            Button("Sign out", role: .destructive) { account.signOut() }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Manage ChatGPT accounts")
                    .accessibilityLabel("Manage ChatGPT accounts")
                    .disabled(busy)
                }
            }

            if !planEnabled || account.signingIn {
                HStack(spacing: 8) {
                    if account.signingIn {
                        ProgressView().controlSize(.small)
                        Text("Complete sign-in in your browser.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { account.cancelSignIn() }
                    } else {
                        Button("Continue with ChatGPT") { account.signIn() }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy)
                    }
                }
            }
            if !account.message.isEmpty && !account.signingIn {
                Text(account.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if usagePaused {
                Label("Usage is paused. Review your usage, then retry.", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.orange)
                Button("Retry ChatGPT plan") { account.fetchModels(retry: true) }
                    .disabled(busy || !planEnabled)
            }
            if let usageURL = ChatGptCoordinator.usageURL {
                Link(destination: usageURL) {
                    Label("Manage usage", systemImage: "arrow.up.right")
                        .font(.caption)
                }
            }
        }
    }

}
