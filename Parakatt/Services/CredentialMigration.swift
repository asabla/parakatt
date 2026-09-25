import Foundation

/// The source can be removed only after a provider-specific Keychain write succeeds.
enum CredentialMigration {
    static func migrate(value: String, account: String,
                        read: (String) -> String? = KeychainService.get,
                        write: (String, String) -> Bool = { KeychainService.set($0, forKey: $1) },
                        acknowledge: () throws -> Void) rethrows -> Bool {
        guard read(account) == value || write(value, account) else { return false }
        try acknowledge()
        return true
    }
}
