import Foundation

/// Whether an `Anchor` resolved against a `CodeDocument`, in three states
/// rather than two (ios-curated-view-parity W7, memo B12).
///
/// macOS's `CodeContentView.resolveRows` collapses this to `Int?`, and its
/// caller (`ScrollDecision.decide`) then treats `nil` as "nothing to arrive
/// at" — which is exactly right for "no anchor was requested" and exactly
/// wrong for "an anchor was requested and this view could not resolve it" (an
/// anchor naming a different file, an anchor kind this surface can't use, or
/// a line past the end of the document). Those two are different facts and
/// only the three-state type can say which one happened; a caller handed a
/// bare `Optional` has already lost the distinction the PRD requires be kept.
///
/// `.unresolved`'s `reason` is operator-facing, not a debug string — the view
/// is required to render it (D7), which is what makes forgetting a case
/// impossible rather than merely impolite: an added `Anchor`/`Emphasis`
/// variant that isn't handled here fails to compile (the switch in
/// `CodeDocument.resolve` is exhaustive with no `default:`), and an added
/// case that resolves to `.unresolved` with an empty reason is caught by
/// `AnchorResolutionTests`' assertions on the reason text.
public enum AnchorResolution: Equatable {
    /// No anchor was requested at all.
    case notRequested
    /// A scroll target, in the surface's own units — here, a 0-based row
    /// index into `CodeDocument.lines`.
    case resolved(target: Int)
    /// An anchor was requested and this document could not resolve it.
    /// `reason` names both what was asked for and what this document
    /// actually is, so the operator reads a fact rather than a code.
    case unresolved(reason: String)
}

/// Whether an `Emphasis` resolved against a `CodeDocument`, in three states
/// for the same reason `AnchorResolution` is three states.
///
/// `.matchedNothing` is deliberately distinct from `.none`: "the agent
/// emphasised nothing" and "the agent emphasised a range that isn't in this
/// document" are different facts, and only the second must be reported to the
/// operator (D7) — rendering it as `.none` would look exactly like a working
/// view that simply has nothing marked.
public enum EmphasisResolution: Equatable {
    /// No emphasis was requested at all.
    case none
    /// Every 0-based row this document's emphasis spans resolved to.
    /// Never empty — a resolution with nothing in it is `.matchedNothing`,
    /// not `.rows([])`.
    case rows([Int])
    /// Emphasis was requested and none of it resolved against this document.
    case matchedNothing(reason: String)
}

extension CodeDocument {

    /// Resolve `anchor` against this document.
    ///
    /// `path`, when the anchor carries one, is compared against this
    /// document's own `path`: an anchor for a different file must not scroll
    /// this document to `line` of the wrong file just because the line
    /// number happens to exist here too. This is the case macOS's
    /// `TicketContentView`/`CodeContentView` silently drop —
    /// `resolveRows` only ever matches on `line`, never on `path` — and it is
    /// the exact defect this type exists to make impossible to repeat: every
    /// non-`.line` anchor kind, and a `.line` anchor for another path, comes
    /// back `.unresolved` with a reason naming what happened, not silence.
    public func resolve(anchor: Anchor?) -> AnchorResolution {
        guard let anchor else { return .notRequested }

        switch anchor {
        case .line(let path, let line):
            if let path, path != self.path {
                return .unresolved(reason: "line \(line) was requested for \(path), not \(self.path)")
            }
            guard contains(line: line) else {
                return .unresolved(reason: describeLineOutOfRange(line))
            }
            return .resolved(target: line - firstLine)

        case .comment:
            return .unresolved(reason: "this is a file view; it has no comments to anchor to")

        case .section:
            return .unresolved(reason: "this is a file view; it has no named sections to anchor to")

        case .queueRow:
            return .unresolved(reason: "this is a file view; it has no queue rows to anchor to")
        }
    }

    /// Resolve every `Emphasis` in `emphases` against this document, unioning
    /// their rows without duplication.
    ///
    /// A `path` mismatch or an anchor kind this surface can't use is treated
    /// the same way `resolve(anchor:)` treats it: named, not silently
    /// dropped. Any entry that resolves contributes its rows; if every entry
    /// fails to resolve, the whole result is `.matchedNothing` with the first
    /// entry's reason — there is exactly one notice slot in the view (D7), so
    /// one representative reason is what gets shown.
    public func resolve(emphasis emphases: [Emphasis]) -> EmphasisResolution {
        guard !emphases.isEmpty else { return .none }

        var rows: Set<Int> = []
        var firstFailureReason: String?

        for emphasis in emphases {
            switch emphasis {
            case .lineRange(let path, let start, let end):
                if let path, path != self.path {
                    firstFailureReason = firstFailureReason ?? "lines \(start)–\(end) were requested for \(path), not \(self.path)"
                    continue
                }
                guard start <= end else {
                    firstFailureReason = firstFailureReason ?? "lines \(start)–\(end) is an inverted range"
                    continue
                }
                let clampedStart = max(start, firstLine)
                let clampedEnd = min(end, lastLine)
                guard clampedStart <= clampedEnd else {
                    firstFailureReason = firstFailureReason ?? describeRangeOutOfRange(start, end)
                    continue
                }
                for line in clampedStart...clampedEnd {
                    rows.insert(line - firstLine)
                }

            case .comment:
                firstFailureReason = firstFailureReason ?? "this is a file view; it has no comments to emphasise"

            case .section:
                firstFailureReason = firstFailureReason ?? "this is a file view; it has no named sections to emphasise"

            case .textRange:
                firstFailureReason = firstFailureReason ?? "this is a file view; it has no character-offset ranges to emphasise"

            case .queueRow:
                firstFailureReason = firstFailureReason ?? "this is a file view; it has no queue rows to emphasise"
            }
        }

        if !rows.isEmpty { return .rows(rows.sorted()) }
        return .matchedNothing(reason: firstFailureReason ?? "the requested emphasis did not match this document")
    }

    // MARK: - Reason wording

    private func describeLineOutOfRange(_ line: Int) -> String {
        "line \(line) is not in this file (it has \(lineCount) line\(lineCount == 1 ? "" : "s"), \(firstLine)–\(lastLine))"
    }

    private func describeRangeOutOfRange(_ start: Int, _ end: Int) -> String {
        "lines \(start)–\(end) aren't in this file (it has \(lineCount) line\(lineCount == 1 ? "" : "s"), \(firstLine)–\(lastLine))"
    }
}
