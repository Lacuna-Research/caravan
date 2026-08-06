import Foundation

/// A colour a formatting code can ask for.
///
/// Two spellings, because IRC has two: `^C` names an index into a palette the client
/// chooses, and `^D` names an exact colour the sender chose. The difference matters at
/// render time — an index can be re-tuned for a dark background, a hex triple cannot be
/// second-guessed without overriding what the sender explicitly asked for.
public enum InlineColour: Sendable, Hashable {
    case indexed(Int)
    case hex(RGB)
}

/// A colour as the wire gives it: eight bits per channel, no colour space.
public struct RGB: Sendable, Hashable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses `RRGGBB`. Returns `nil` for anything else, including the shorter forms CSS
    /// allows — IRC's `^D` is exactly six hex digits.
    public init?(hex: some StringProtocol) {
        guard hex.count == 6 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        for _ in 0..<3 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes[0], bytes[1], bytes[2])
    }

    /// Relative luminance, per WCAG. Used to check a generated nick palette against both
    /// backgrounds rather than trusting a hue wheel to be readable.
    public var relativeLuminance: Double {
        func channel(_ value: UInt8) -> Double {
            let scaled = Double(value) / 255
            return scaled <= 0.039_28
                ? scaled / 12.92
                : pow((scaled + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG contrast ratio, 1...21.
    public func contrastRatio(against other: RGB) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// Everything a run of text can be wearing.
///
/// A set of independent switches rather than a stack, because that is what the wire
/// describes: `^B` toggles bold wherever it appears and `^O` clears the lot. There is no
/// nesting to get wrong, and no closing tag to go missing.
public struct InlineStyle: Sendable, Hashable {
    public var isBold = false
    public var isItalic = false
    public var isUnderlined = false
    public var isStruckThrough = false
    public var isMonospaced = false

    /// `^R`. Swaps foreground and background *at render time* rather than here, because
    /// what it swaps to when neither is set is the window's own colours — which this
    /// module deliberately knows nothing about.
    public var isReversed = false

    public var foreground: InlineColour?
    public var background: InlineColour?

    public init() {}

    /// Whether this run is unadorned, and so can be rendered as plain text.
    public var isPlain: Bool { self == InlineStyle() }

    /// `^O` — back to nothing at all.
    mutating func reset() { self = InlineStyle() }
}
