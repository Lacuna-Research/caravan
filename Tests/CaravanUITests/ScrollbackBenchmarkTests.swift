import AppKit
import Foundation
import Testing

@testable import CaravanUI

/// The 50,000-line benchmark that decides between TextKit 2 and TextKit 1.
///
/// Off unless `CARAVAN_BENCHMARKS` is set: it is a measurement, not an assertion, and
/// running it on every push would add seconds to CI to prove nothing that changed.
///
///     CARAVAN_BENCHMARKS=1 swift test --filter ScrollbackBenchmarkTests
///
/// Numbers land in `BUILD-LOG.md`. Run them one engine at a time — both in one process
/// share an allocator and a font cache, and the second one's memory figure is not its own.
@MainActor
@Suite(
    "Scrollback benchmark",
    .enabled(if: ProcessInfo.processInfo.environment["CARAVAN_BENCHMARKS"] != nil),
    .serialized
)
struct ScrollbackBenchmarkTests {
    private static let lineCount = 50_000
    private static let batchSize = 100
    private static let viewportHeight: CGFloat = 800

    @Test("TextKit 2, 50,000 lines")
    func textKit2() {
        report(run(usesTextKit2: true))
    }

    @Test("TextKit 1, 50,000 lines")
    func textKit1() {
        report(run(usesTextKit2: false))
    }

    /// TextKit 2 for real.
    ///
    /// `NSTextView` drops back to TextKit 1 the moment anything touches `textStorage`,
    /// and the shipping append path does exactly that — so the "TextKit 2" case above is
    /// TextKit 1 wearing a different hat, as its own assertion shows. Reaching the new
    /// engine means going through `NSTextContentStorage` instead, which is what this
    /// measures: the cost of the append path we would have to write to use it.
    @Test("TextKit 2 native, 50,000 lines")
    func textKit2Native() throws {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 900, height: Self.viewportHeight)
        textView.isEditable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 900, height: Self.viewportHeight)
        )
        scrollView.documentView = textView
        scrollView.layoutSubtreeIfNeeded()

        let layoutManager = try #require(textView.textLayoutManager)
        let contentStorage = try #require(layoutManager.textContentManager as? NSTextContentStorage)
        let baseline = physicalFootprint()

        let appendStart = ContinuousClock.now
        var produced = 0
        while produced < Self.lineCount {
            let size = min(Self.batchSize, Self.lineCount - produced)
            let batch = NSMutableAttributedString()
            for offset in 0..<size {
                batch.append(NSAttributedString(string: Self.sampleLine(produced + offset) + "\n"))
            }
            contentStorage.performEditingTransaction {
                contentStorage.textStorage?.append(batch)
            }
            produced += size
        }
        let appendSeconds = (ContinuousClock.now - appendStart).seconds

        // Still on the new engine: if this is nil, the run silently fell back and the
        // numbers describe TextKit 1 again.
        #expect(textView.textLayoutManager != nil)

        let layoutStart = ContinuousClock.now
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let layoutSeconds = (ContinuousClock.now - layoutStart).seconds

        let scrollStart = ContinuousClock.now
        var slowest = 0.0
        var viewports = 0
        var offset: CGFloat = 0
        while offset < textView.frame.height {
            let stepStart = ContinuousClock.now
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            layoutManager.textViewportLayoutController.layoutViewport()
            slowest = max(slowest, (ContinuousClock.now - stepStart).seconds)
            viewports += 1
            offset += Self.viewportHeight
        }

        report(
            Result(
                engine: "TextKit 2 native",
                appendSeconds: appendSeconds,
                layoutSeconds: layoutSeconds,
                scrollSeconds: (ContinuousClock.now - scrollStart).seconds,
                viewportCount: viewports,
                slowestViewportMilliseconds: slowest * 1000,
                footprintDeltaBytes: physicalFootprint() - baseline,
                documentHeight: textView.frame.height
            )
        )
    }

    // MARK: - The measurement

    private struct Result {
        var engine: String
        var appendSeconds: Double
        var layoutSeconds: Double
        var scrollSeconds: Double
        var viewportCount: Int
        var slowestViewportMilliseconds: Double
        var footprintDeltaBytes: Int64
        var documentHeight: CGFloat
    }

    private func run(usesTextKit2: Bool) -> Result {
        let controller = MessageLogController(lineCap: 200_000, coalesceInterval: .seconds(3600))
        let textView = MessageLogView.makeTextView(usesTextKit2: usesTextKit2)
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 900, height: Self.viewportHeight)
        )
        scrollView.documentView = textView
        controller.attach(textView: textView, scrollView: scrollView)
        scrollView.layoutSubtreeIfNeeded()

        let baseline = physicalFootprint()
        // Records which engine is actually in play, since asking for `textStorage` at all
        // drops a TextKit 2 view back to TextKit 1.
        let engineInUse = textView.textLayoutManager != nil ? "TextKit 2" : "TextKit 1"

        // Append in bursts, the way a MOTD or a busy channel actually arrives, with an
        // explicit flush per burst rather than waiting on the coalescing timer.
        let appendStart = ContinuousClock.now
        var produced = 0
        while produced < Self.lineCount {
            let size = min(Self.batchSize, Self.lineCount - produced)
            controller.append((0..<size).map { AttributedString(Self.sampleLine(produced + $0)) })
            controller.flush()
            produced += size
        }
        let appendSeconds = (ContinuousClock.now - appendStart).seconds
        // Asked again *after* the appends: the shipping path goes through
        // `textView.textStorage`, and that is the access that silently drops a TextKit 2
        // view back to TextKit 1 — mid-run, having already paid for the new engine.
        let engineAfterAppends = textView.textLayoutManager != nil ? "TextKit 2" : "TextKit 1"

        // Force the whole document to be laid out. Without this the two engines are not
        // comparable: TextKit 1 defers layout so completely that the view never grows
        // past its initial frame, and a scroll test over an 800-point document measures
        // nothing. A real window pays this cost too — a scroll bar cannot be honest about
        // its thumb size until something knows how tall the document is.
        let layoutStart = ContinuousClock.now
        ensureFullLayout(of: textView, usesTextKit2: usesTextKit2)
        let layoutSeconds = (ContinuousClock.now - layoutStart).seconds

        // Scroll top to bottom, laying out each viewport as a display pass would. Lazy
        // layout means this, not the append, is where TextKit 2 does most of its work.
        let scrollStart = ContinuousClock.now
        var slowest = 0.0
        var viewports = 0
        var offset: CGFloat = 0
        let step = Self.viewportHeight
        while offset < textView.frame.height {
            let stepStart = ContinuousClock.now
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            layOutViewport(of: textView, usesTextKit2: usesTextKit2)
            slowest = max(slowest, (ContinuousClock.now - stepStart).seconds)
            viewports += 1
            offset += step
        }
        let scrollSeconds = (ContinuousClock.now - scrollStart).seconds

        return Result(
            engine: "requested \(usesTextKit2 ? "TextKit 2" : "TextKit 1"), "
                + "started as \(engineInUse), ended as \(engineAfterAppends)",
            appendSeconds: appendSeconds,
            layoutSeconds: layoutSeconds,
            scrollSeconds: scrollSeconds,
            viewportCount: viewports,
            slowestViewportMilliseconds: slowest * 1000,
            footprintDeltaBytes: physicalFootprint() - baseline,
            documentHeight: textView.frame.height
        )
    }

    /// Lays out the entire document, so its height is known and both engines have done
    /// the same work before the scroll phase starts.
    private func ensureFullLayout(of textView: NSTextView, usesTextKit2: Bool) {
        if usesTextKit2 {
            if let layoutManager = textView.textLayoutManager {
                layoutManager.ensureLayout(for: layoutManager.documentRange)
            }
        } else if let layoutManager = textView.layoutManager, let container = textView.textContainer
        {
            layoutManager.ensureLayout(for: container)
            // TextKit 1 sizes the view from the layout rather than the other way round.
            textView.setFrameSize(
                NSSize(
                    width: textView.frame.width,
                    height: layoutManager.usedRect(for: container).height
                )
            )
        }
    }

    /// Lays out just what is on screen, which is what a display pass costs.
    private func layOutViewport(of textView: NSTextView, usesTextKit2: Bool) {
        if usesTextKit2 {
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        } else if let layoutManager = textView.layoutManager, let container = textView.textContainer
        {
            layoutManager.ensureLayout(forBoundingRect: textView.visibleRect, in: container)
        }
    }

    private static func sampleLine(_ index: Int) -> String {
        "[12:04:22] <someuser\(index % 50)> a message of fairly ordinary length, number \(index)"
    }

    private func report(_ result: Result) {
        let lines = Double(Self.lineCount)
        let megabytes = Double(result.footprintDeltaBytes) / 1_048_576
        print(
            """

            ── \(result.engine), \(Self.lineCount) lines, batches of \(Self.batchSize) ──
              append      \(format(result.appendSeconds))s  \
            (\(Int(lines / result.appendSeconds)) lines/sec)
              full layout \(format(result.layoutSeconds))s
              scroll      \(format(result.scrollSeconds))s over \(result.viewportCount) viewports  \
            (slowest viewport \(format(result.slowestViewportMilliseconds))ms)
              memory      \(format(megabytes)) MB added
              document    \(Int(result.documentHeight)) points tall

            """
        )
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// Physical footprint, the figure Instruments and the memory gauge report.
    private func physicalFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}

extension Duration {
    fileprivate var seconds: Double {
        let (whole, attoseconds) = components
        return Double(whole) + Double(attoseconds) / 1e18
    }
}
