import Diagnostics
import Foundation
import Security

/// What a stored secret is *for*.
///
/// Two credentials for one host are routine: a bouncer wants a `PASS` and the network
/// behind it wants a SASL password.
public enum CredentialKind: String, Sendable, CaseIterable {
    /// The `PASS` sent before registration.
    case serverPassword = "server-password"
    /// The SASL or NickServ password.
    case account = "account"
}

/// Somewhere to keep credentials.
///
/// A protocol for one production implementation, for the same reason `ConfigFile` takes a
/// URL: a test must not write into the login keychain of whoever is running the suite, and
/// "remember to delete it afterwards" is not a mechanism.
@MainActor
public protocol CredentialStore {
    func password(_ kind: CredentialKind, host: String) -> String?
    /// Stores a password. `nil` or empty **removes** the item rather than storing an empty
    /// string, so clearing the field in the sheet actually forgets.
    func setPassword(_ password: String?, _ kind: CredentialKind, host: String)
}

/// Where credentials live. **The only place they live.**
///
/// `caravan.conf` is plain text, world-readable, meant to be opened in an editor and
/// checked into a dotfiles repository. A password in it is a password in someone's git
/// history. The Keychain is encrypted at rest, unlocked with the login session, and
/// auditable in Keychain Access — so that is where every secret goes, and the config file
/// keeps only the *shape* of the credential: which host, which account, which mechanism.
///
/// Reasoning in `BUILD-LOG.md`; the rule is in `CLAUDE.md`.
@MainActor
public final class Keychain: CredentialStore {
    /// The one the app uses.
    public static let shared = Keychain()

    /// One service string for the app, with the kind and host in the account.
    ///
    /// A user opening Keychain Access sees one Caravan group rather than an entry per
    /// host scattered through the list, and a password is identifiable by its account
    /// line — `account@irc.libera.chat` — without having to inspect it.
    public let service: String

    public init(service: String = "Caravan (IRC)") {
        self.service = service
    }

    /// The account string for one credential.
    public static func account(_ kind: CredentialKind, host: String) -> String {
        "\(kind.rawValue)@\(host.lowercased())"
    }

    /// Reads a password, or `nil` when there is none — or when the Keychain is
    /// unavailable, which is what an unsigned test bundle can look like.
    public func password(_ kind: CredentialKind, host: String) -> String? {
        var query = baseQuery(kind, host: host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                Log.ui.error("keychain read failed: \(status, privacy: .public)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String?, _ kind: CredentialKind, host: String) {
        let query = baseQuery(kind, host: host)
        guard let password, !password.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(password.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            Log.ui.error("keychain update failed: \(status, privacy: .public)")
            return
        }
        var item = query
        item[kSecValueData as String] = data
        // `WhenUnlocked` rather than `Always`: a credential a locked Mac will hand out is a
        // credential that survives the lock screen.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let added = SecItemAdd(item as CFDictionary, nil)
        if added != errSecSuccess {
            Log.ui.error("keychain write failed: \(added, privacy: .public)")
        }
    }

    private func baseQuery(_ kind: CredentialKind, host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(kind, host: host),
        ]
    }
}

/// A credential store that forgets when the process does.
///
/// What a test injects, and the reason ``CredentialStore`` is a protocol at all. Also what
/// a SwiftUI preview gets, so rendering the Connect sheet in Xcode does not go looking for
/// a keychain that is not there.
@MainActor
public final class EphemeralCredentialStore: CredentialStore {
    private var storage: [String: String] = [:]

    public init() {}

    public func password(_ kind: CredentialKind, host: String) -> String? {
        storage[Keychain.account(kind, host: host)]
    }

    public func setPassword(_ password: String?, _ kind: CredentialKind, host: String) {
        let key = Keychain.account(kind, host: host)
        guard let password, !password.isEmpty else {
            storage.removeValue(forKey: key)
            return
        }
        storage[key] = password
    }
}
