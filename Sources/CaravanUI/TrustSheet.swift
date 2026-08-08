import SwiftUI

// The Connect sheet this file was named for is gone: stage 2 prompt 11 retired it for the
// Dashboard's server list, because connecting is a surface you keep servers on rather than
// a modal you fill in again every session (§13). The trust prompt survived it — a
// certificate question genuinely is modal, since the TLS handshake is held open waiting for
// the answer.

/// A certificate the system would not validate, and the question that follows.
///
/// Deliberately not an `alert`: a SHA-256 fingerprint is 95 characters and an alert body
/// is not where anyone can compare one. The fingerprint is selectable, because comparing it
/// against one published elsewhere means being able to copy it.
struct TrustSheet: View {
    let request: AppModel.TrustRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(headline, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(request.previousFingerprint == nil ? Color.primary : Color.red)

            Text(explanation)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    if let subject = request.certificate.subject {
                        row("Subject", subject)
                    }
                    row("SHA-256", request.certificate.sha256Fingerprint)
                    if let previous = request.previousFingerprint {
                        row("Previously", previous)
                    }
                }
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Don't Connect", role: .cancel) { request.answer(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Trust and Connect") { request.answer(true) }
                    // Never the default button. The safe answer is the one that happens
                    // when somebody hits Return without reading, and that is not this one.
                    .keyboardShortcut(.none)
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }

    private var headline: String {
        request.previousFingerprint == nil
            ? "Caravan cannot verify \(request.host)"
            : "The certificate for \(request.host) has changed"
    }

    private var symbol: String {
        request.previousFingerprint == nil
            ? "lock.trianglebadge.exclamationmark" : "exclamationmark.octagon"
    }

    private var explanation: String {
        request.previousFingerprint == nil
            ? """
            The server presented a certificate the system will not validate — usually a \
            self-signed one. Connect only if this fingerprint is the one the network \
            publishes.
            """
            : """
            This is not the certificate you accepted last time. That happens when a \
            server rotates its certificate, and it also happens when somebody is reading \
            the connection. Check the fingerprint before continuing.
            """
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
