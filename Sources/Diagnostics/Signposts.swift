import OSLog

/// Signposters for performance intervals, for use with Instruments.
///
/// Kept here rather than at each call site so intervals from different subsystems land
/// under one recognisable subsystem when profiling.
public enum Signposts {
    /// Scrollback append and layout timing. Prompt 7 uses this for the 50,000-line
    /// benchmark that decides between TextKit 2 and TextKit 1.
    public static let scrollback = OSSignposter(
        subsystem: Log.subsystem,
        category: "scrollback"
    )
}
