import Foundation

/// The rules that say "this transcript pane is blank (or stalled) and should not be".
///
/// Pure state machine: no views, no clock of its own (times are passed in, in milliseconds on any
/// monotonic scale), so each rule is tested by feeding it numbers. `PaneRenderWatch` is the part that
/// reads a real pane and calls it.
///
/// Detection only. Nothing here changes what the pane renders, scrolls or measures.
struct PaneBlankDetector {

    enum Rule: String {
        /// (a) The visible region holds no turn view although the pane has turns, for several
        /// evaluations in a row.
        case emptyViewport = "empty-viewport"
        /// (b) The document height fell by more than half, to less than the viewport, and came back.
        case heightCollapse = "height-collapse"
        /// (c) A draw pass painted no turn rows although the pane has turns and nothing is queued to fix it.
        case zeroRowDraw = "zero-row-draw"
        /// (d) The main thread stalled for longer than a quarter of a second while the pane was visible.
        case mainThreadStall = "main-thread-stall"
        /// A capture the operator asked for.
        case manual = "manual"

        /// The number recorded in a `detectorHit` event.
        var code: Double {
            switch self {
            case .emptyViewport:   return 1
            case .heightCollapse:  return 2
            case .zeroRowDraw:     return 3
            case .mainThreadStall: return 4
            case .manual:          return 5
            }
        }
    }

    /// A stall is a lower severity than a blank: it has its own capture rate limit, so a stall that
    /// came first cannot use up the capture of the blank it caused.
    enum Severity: String {
        case blank, stall, manual

        var code: Double {
            switch self {
            case .blank:  return 1
            case .stall:  return 2
            case .manual: return 3
            }
        }
    }

    /// One look at a pane.
    struct Sample {
        var nowMs: Double
        /// In a window, not hidden, window not occluded, with a usable size.
        var isVisible: Bool
        var retainedTurns: Int
        /// Materialized turn views whose frame intersects the visible region.
        var visibleTurnViews: Int
        /// The virtualizer's document height (the sum of every turn's height).
        var documentHeight: Double
        var viewportHeight: Double
        var transcriptClears: Int
        /// A deliberate shed released the views and its compaction has not landed yet.
        var shedInFlight: Bool = false
    }

    struct Hit {
        let rule: Rule
        let severity: Severity
        /// Numbers that explain the hit (all content-free).
        let detail: [String: Double]
    }

    /// Consecutive evaluations that must all see an empty visible region...
    static let emptyViewportEvaluations = 3
    /// ...over at least this long (a repair pass runs on the next run-loop turn; this is "not repaired").
    static let emptyViewportMinMs = 300.0
    /// While a deliberate shed (release every view, compact, rebuild) is in flight an empty viewport is
    /// expected; rule (a) then waits for the blank to outlast this long (counted from when the viewport
    /// went empty, through the compaction landing and until the rebuild fills it) before it calls it a blank.
    static let emptyViewportShedGraceMs = 2_000.0
    /// A drop to less than this fraction of the previous height, and below the viewport, is a collapse.
    static let heightDropFraction = 0.5
    /// A collapse that recovers within this long is the blank; one that stays is a real shrink.
    static let heightRecoveryWindowMs = 10_000.0
    static let stallThresholdMs = 250.0
    /// Rule (c) does not fire again this soon after it fired, unless a draw painted rows in between.
    static let zeroRowDrawRefractoryMs = 5_000.0

    // MARK: - State

    /// Rule (a): when the current run of empty evaluations began, and how many it has had.
    private var emptySinceMs: Double?
    private var emptyEvaluations = 0
    private var emptyFired = false
    /// A deliberate shed was in flight at some point during the current empty run: the run is the
    /// shed's, and stays under the grace period even after the compaction lands and before the rebuild pass.
    private var emptyRunHadShed = false

    /// Rule (b): the last stable document height, and the collapse being watched, if any.
    /// Rule (c): when it last fired. A blank that stays blank is drawn at display rate; one hit says so.
    private var lastZeroRowDrawMs: Double?

    private var baselineHeight: Double = 0
    private var collapse: (from: Double, to: Double, atMs: Double, clears: Int)?

    init() {}

    /// A rule has seen something suspicious and is waiting to see whether it resolves (an empty run
    /// has begun, or a height collapse is armed): the caller should keep looking often.
    var isWatching: Bool { emptySinceMs != nil || collapse != nil }

    // MARK: - Rules a and b

    mutating func evaluate(_ s: Sample) -> [Hit] {
        var hits: [Hit] = []
        if let hit = evaluateEmptyViewport(s) { hits.append(hit) }
        if let hit = evaluateHeight(s) { hits.append(hit) }
        return hits
    }

    private mutating func evaluateEmptyViewport(_ s: Sample) -> Hit? {
        guard s.isVisible, s.retainedTurns > 0, s.visibleTurnViews == 0 else {
            emptySinceMs = nil
            emptyEvaluations = 0
            emptyFired = false
            emptyRunHadShed = false
            return nil
        }
        if emptySinceMs == nil { emptySinceMs = s.nowMs }
        if s.shedInFlight { emptyRunHadShed = true }
        emptyEvaluations += 1
        let span = s.nowMs - (emptySinceMs ?? s.nowMs)
        let minSpan = emptyRunHadShed ? max(Self.emptyViewportMinMs, Self.emptyViewportShedGraceMs) : Self.emptyViewportMinMs
        guard !emptyFired, emptyEvaluations >= Self.emptyViewportEvaluations, span >= minSpan
        else { return nil }
        emptyFired = true
        return Hit(rule: .emptyViewport, severity: .blank,
                   detail: ["evaluations": Double(emptyEvaluations), "emptyForMs": span,
                            "retainedTurns": Double(s.retainedTurns),
                            "documentHeight": s.documentHeight, "viewportHeight": s.viewportHeight])
    }

    private mutating func evaluateHeight(_ s: Sample) -> Hit? {
        guard s.retainedTurns > 0 else {
            baselineHeight = 0
            collapse = nil
            return nil
        }
        if let armed = collapse {
            if s.transcriptClears != armed.clears {
                // The session cleared its transcript: a real, deliberate collapse.
                collapse = nil
                baselineHeight = s.documentHeight
                return nil
            }
            if s.nowMs - armed.atMs > Self.heightRecoveryWindowMs {
                // It stayed collapsed: the transcript really got shorter.
                collapse = nil
                baselineHeight = s.documentHeight
                return nil
            }
            if s.documentHeight >= armed.from * Self.heightDropFraction {
                collapse = nil
                baselineHeight = s.documentHeight
                return Hit(rule: .heightCollapse, severity: .blank,
                           detail: ["heightBefore": armed.from, "heightCollapsedTo": armed.to,
                                    "heightAfter": s.documentHeight, "collapsedForMs": s.nowMs - armed.atMs,
                                    "viewportHeight": s.viewportHeight])
            }
            collapse = (armed.from, min(armed.to, s.documentHeight), armed.atMs, armed.clears)
            return nil
        }
        if baselineHeight > s.viewportHeight,
           s.documentHeight < baselineHeight * Self.heightDropFraction,
           s.documentHeight < s.viewportHeight {
            collapse = (baselineHeight, s.documentHeight, s.nowMs, s.transcriptClears)
            return nil
        }
        baselineHeight = s.documentHeight
        return nil
    }

    /// A reflow the operator caused (the pane was resized, a fold opened or closed): the height is
    /// allowed to move a lot, so forget the baseline and any collapse being watched.
    mutating func rebaselineHeight() {
        baselineHeight = 0
        collapse = nil
    }

    // MARK: - Rule c

    /// A draw pass painted `rowsPainted` turn rows. Blank only when the pane is on screen, has turns
    /// and no pass is queued to put them back (a pass queued for the next run-loop turn is the ordinary
    /// gap between "views released" and "views built").
    mutating func noteDraw(nowMs: Double, isVisible: Bool, retainedTurns: Int,
                           rowsPainted: Int, renderPending: Bool) -> Hit? {
        guard isVisible, retainedTurns > 0, rowsPainted == 0 else {
            lastZeroRowDrawMs = nil   // the pane painted (or has nothing to paint): the next blank is a new one
            return nil
        }
        guard !renderPending else { return nil }
        if let last = lastZeroRowDrawMs, nowMs - last < Self.zeroRowDrawRefractoryMs { return nil }
        lastZeroRowDrawMs = nowMs
        return Hit(rule: .zeroRowDraw, severity: .blank,
                   detail: ["retainedTurns": Double(retainedTurns), "atMs": nowMs])
    }

    // MARK: - Rule d

    mutating func noteStall(ms: Double, isVisible: Bool) -> Hit? {
        guard isVisible, ms > Self.stallThresholdMs else { return nil }
        return Hit(rule: .mainThreadStall, severity: .stall, detail: ["stallMs": ms])
    }
}
