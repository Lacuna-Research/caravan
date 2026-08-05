import Foundation

/// Turns framed bytes into a `String`, and a `String` into bytes for the wire.
public enum WireDecoding {
    /// Decodes one framed line.
    ///
    /// UTF-8 first, then Windows-1252, then Latin-1. IRC predates a mandatory encoding
    /// and networks still carry lines in whatever the sender's client used, so a strict
    /// decoder would drop real traffic. Mojibake is a bad line; a dropped line is a
    /// message the user never learns existed, which is worse.
    ///
    /// Latin-1 is the backstop because all 256 byte values map to a scalar under it, so
    /// this never fails and never returns a partially-replaced string.
    public static func line(from bytes: [UInt8]) -> String {
        if let utf8 = String(bytes: bytes, encoding: .utf8) { return utf8 }
        if let windows1252 = String(bytes: bytes, encoding: .windowsCP1252) { return windows1252 }
        return String(bytes: bytes, encoding: .isoLatin1) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// Encodes one line for the wire, terminator included. We always send UTF-8.
    public static func data(for line: String) -> Data {
        var data = Data(line.utf8)
        data.append(contentsOf: [UInt8(ascii: "\r"), UInt8(ascii: "\n")])
        return data
    }
}
