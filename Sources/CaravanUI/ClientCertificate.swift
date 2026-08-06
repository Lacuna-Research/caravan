import Diagnostics
import Foundation
import IRCTransport
import Security

/// Finds the client certificate CertFP needs, by the name it has in the Keychain.
///
/// **Caravan does not generate or import certificates.** Creating a keypair, getting its
/// fingerprint to `NickServ CERT ADD`, and keeping the private key safe are things Keychain
/// Access and `openssl` already do well, and a client that grew its own half-version of
/// them would be a worse place to keep a private key. What is needed here is the last
/// step: naming one that is already there.
public enum ClientCertificate {
    /// The identity stored under `label`, or `nil` when there is no such thing.
    ///
    /// The label is what Keychain Access shows in its Name column, which is what a user
    /// can actually read off the screen and type into the Connect sheet.
    public static func identity(labelled label: String) -> TLSClientIdentity? {
        guard !label.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item else {
            Log.ui.error(
                "no client certificate found in the keychain (status \(status, privacy: .public))"
            )
            return nil
        }
        // `SecItemCopyMatching` returns `CFTypeRef`, so the type is checked rather than
        // assumed. Past the check the reinterpretation is exactly what the API contract
        // says the value is.
        guard CFGetTypeID(item) == SecIdentityGetTypeID() else { return nil }
        return TLSClientIdentity(unsafeDowncast(item, to: SecIdentity.self))
    }
}
