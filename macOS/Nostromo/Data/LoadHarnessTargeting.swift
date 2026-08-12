import Foundation

/// Which panes a load run should drive — decided in one pure, dependency-free
/// place so the decision is testable.
///
/// `TranscriptLoadHarness` used to poll for registered panes and, after ~30 s,
/// fall back to a hard-coded `["claudia"]`. Its own doc comment names that as the
/// failure mode: "guessing tags is how the first harness run measured nothing —
/// the traffic reached a `ChatSession` with no `ReplView` attached, so the view
/// layer, the expensive half and the half this work exists to bound, never was."
/// Worse, nothing marked such a run invalid, so the report printed PASS for
/// materialized views, hot payload, retained-turns-monotonic and
/// transcript-clears against a run that measured none of them.
///
/// So: never invent a tag. With nothing registered the only honest answer is a
/// failure. `TranscriptLoadHarness` itself reaches `AppStore.shared` and cannot
/// go in the logic test bundle; this can.
enum LoadHarnessTargeting {

    struct Plan: Equatable {
        /// The tags to drive. Always a subset of what was actually registered.
        let tags: [String]
        /// How many focuses the run asked for. Carried separately from
        /// `tags.count` precisely so a shortfall is reportable rather than
        /// invisible — a run that drove 1 of 8 must not read as a clean 1-focus
        /// run.
        let requested: Int
    }

    enum Failure: Error, Equatable {
        case noRegisteredPanes(waitedSeconds: Double)
    }

    static func resolve(registered: [String],
                        activeTag: String?,
                        requested: Int,
                        waitedSeconds: Double) -> Result<Plan, Failure> {
        guard !registered.isEmpty else {
            return .failure(.noRegisteredPanes(waitedSeconds: waitedSeconds))
        }
        var ordered = registered
        // Drive the *visible* pane first. A hidden pane has a zero-height
        // viewport, so it materializes almost nothing — the run would measure the
        // data path and skip the view path entirely.
        if let active = activeTag, let i = ordered.firstIndex(of: active) {
            ordered.swapAt(0, i)
        }
        return .success(Plan(tags: Array(ordered.prefix(max(0, requested))),
                             requested: requested))
    }
}
