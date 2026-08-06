import AppKit
import IRCFormat
import SwiftUI

/// The colour picker Ctrl+K opens: mIRC's sixteen, in a strip.
///
/// **Sixteen, not ninety-nine.** The base palette is the one people choose from and the
/// one a grid can show at a readable size; the extended 16–98 range is typed as digits,
/// which is how it is reached in mIRC too. A ninety-nine swatch grid hanging off an input
/// box would be a colour dialog, and that is stage 3's Colors item.
///
/// The swatches come from `Palette`, not a second table — so a swatch is the colour the
/// buffer will actually draw, including whichever of the two base tables is in force.
struct ColourStrip: View {
    /// Called with the palette index the user picked.
    let choose: (Int) -> Void

    /// The two rows mIRC shows: 0–7 above, 8–15 below.
    private static let rows = [Array(0..<8), Array(8..<16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.rows, id: \.first) { row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { index in
                        swatch(index)
                    }
                }
            }
            Text("Or type the number — 16–98 are the extended palette.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private func swatch(_ index: Int) -> some View {
        Button {
            choose(index)
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(colour(index))
                .frame(width: 22, height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Colour \(index)")
        .accessibilityLabel("Colour \(index)")
    }

    /// The swatch's colour, taken through the same resolution the buffer uses.
    private func colour(_ index: Int) -> Color {
        let resolved = Palette().colours(foreground: .indexed(index), background: nil).foreground
        return Color(nsColor: resolved ?? .labelColor)
    }
}
