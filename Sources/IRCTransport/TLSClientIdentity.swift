import Security

/// A client certificate and its private key, for CertFP.
///
/// A thin wrapper rather than a bare `SecIdentity` so the transport's public surface says
/// what the thing is for, and so the `Sendable` justification lives in one place instead
/// of at every call site.
public struct TLSClientIdentity: @unchecked Sendable {
    // @unchecked: `SecIdentity` is an immutable CoreFoundation type. Security.framework
    // documents its objects as safe to use from multiple threads, and nothing here ever
    // mutates one — it is created once from the Keychain and handed to Network.framework.
    // Swift has no way to express that, and the alternative is passing an opaque token
    // and a lookup closure, which is more machinery for the same guarantee.
    public let identity: SecIdentity

    public init(_ identity: SecIdentity) {
        self.identity = identity
    }
}
