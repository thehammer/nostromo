import Foundation

/// The three-state `Anchor`/`Emphasis` resolvers for `ConversationPlan` and
/// `TicketPlan` (ios-curated-view-parity W9, D4/D5), following exactly the
/// discipline `Code/AnchorResolution.swift` established for `CodeDocument`
/// (memo B12): every anchor kind this surface cannot use resolves to
/// `.unresolved` with an operator-facing reason, never to silence — the
/// case macOS's `TicketContentView`/`ConversationContentView` drop on the
/// floor (`macOS/Nostromo/UI/Views/TicketContentView.swift:115-125`,
/// `ConversationContentView.swift:128-131`).
///
/// A **port of the pattern**, not a shared implementation with
/// `CodeDocument`'s resolvers — the row-vs-line addressing spaces are
/// different units, and each surface's reason wording names what IT is
/// ("this is a conversation view…" / "this is a ticket view…"), the same
/// way `CodeDocument`'s own reasons name what a file view is.
extension ConversationPlan {

    /// Resolve `anchor` against this conversation. Only `.comment(id:)`
    /// applies; every other kind is a fact about this surface, not a bug —
    /// stated, not silently dropped (the defect macOS repeats).
    public func resolve(anchor: Anchor?) -> AnchorResolution {
        guard let anchor else { return .notRequested }

        switch anchor {
        case .comment(let id):
            if let row = commentRowIndex[id] { return .resolved(target: row) }
            return .unresolved(reason: describeMissingComment(id))

        case .line(let path, let line):
            return .unresolved(reason: "line \(line)\(path.map { " of \($0)" } ?? "") was requested but this is a conversation view; it has no lines to anchor to")

        case .section(let name):
            return .unresolved(reason: "section \"\(name)\" was requested but this is a conversation view; it has no named sections to anchor to")

        case .queueRow(let repo, let number):
            return .unresolved(reason: "queue row \(repo)#\(number) was requested but this is a conversation view; it has no queue rows to anchor to")
        }
    }

    /// Resolve every `Emphasis` in `emphases`, unioning rows without
    /// duplication — mirrors `CodeDocument.resolve(emphasis:)` exactly.
    public func resolve(emphasis emphases: [Emphasis]) -> EmphasisResolution {
        guard !emphases.isEmpty else { return .none }

        var rows: Set<Int> = []
        var firstFailureReason: String?

        for emphasis in emphases {
            switch emphasis {
            case .comment(let id):
                if let row = commentRowIndex[id] {
                    rows.insert(row)
                } else {
                    firstFailureReason = firstFailureReason ?? describeMissingComment(id)
                }

            case .textRange(let start, let end):
                if let overlapping = ProseAddressing.rowsOverlapping(start: start, end: end, in: self.rows), !overlapping.isEmpty {
                    rows.formUnion(overlapping)
                } else {
                    firstFailureReason = firstFailureReason ?? ProseAddressing.textRangeFailureReason(start: start, end: end)
                }

            case .lineRange(let path, let start, let end):
                firstFailureReason = firstFailureReason ?? "lines \(start)–\(end)\(path.map { " of \($0)" } ?? "") were requested but this is a conversation view; it has no line ranges to emphasise"

            case .section(let name):
                firstFailureReason = firstFailureReason ?? "section \"\(name)\" was requested but this is a conversation view; it has no named sections to emphasise"

            case .queueRow(let repo, let number):
                firstFailureReason = firstFailureReason ?? "queue row \(repo)#\(number) was requested but this is a conversation view; it has no queue rows to emphasise"
            }
        }

        if !rows.isEmpty { return .rows(rows.sorted()) }
        return .matchedNothing(reason: firstFailureReason ?? "the requested emphasis did not match this conversation")
    }

    private func describeMissingComment(_ id: String) -> String {
        "comment \"\(id)\" was requested but this conversation has \(commentOrder.count) comment\(commentOrder.count == 1 ? "" : "s"), none with that id"
    }
}

extension TicketPlan {

    /// Resolve `anchor` against this ticket. `.section(name:)` addresses
    /// both a named section (matched case/punctuation-insensitively, per
    /// the parent PRD's near-variant-matching requirement) and, via the
    /// shared `"comment:<index>"` convention, a comment. Every other kind
    /// is stated as inapplicable, never silent.
    public func resolve(anchor: Anchor?) -> AnchorResolution {
        guard let anchor else { return .notRequested }

        switch anchor {
        case .section(let name):
            return resolveSectionOrComment(name)

        case .line(let path, let line):
            return .unresolved(reason: "line \(line)\(path.map { " of \($0)" } ?? "") was requested but this is a ticket view; it has no lines to anchor to")

        case .comment:
            return .unresolved(reason: "an id-addressed comment was requested but this is a ticket view; its comments are addressed by index via \"comment:<n>\", not by id")

        case .queueRow(let repo, let number):
            return .unresolved(reason: "queue row \(repo)#\(number) was requested but this is a ticket view; it has no queue rows to anchor to")
        }
    }

    public func resolve(emphasis emphases: [Emphasis]) -> EmphasisResolution {
        guard !emphases.isEmpty else { return .none }

        var rows: Set<Int> = []
        var firstFailureReason: String?

        for emphasis in emphases {
            switch emphasis {
            case .section(let name):
                switch resolveSectionOrComment(name) {
                case .resolved(let row):
                    rows.insert(row)
                case .unresolved(let reason):
                    firstFailureReason = firstFailureReason ?? reason
                case .notRequested:
                    break
                }

            case .textRange(let start, let end):
                if let overlapping = ProseAddressing.rowsOverlapping(start: start, end: end, in: self.rows), !overlapping.isEmpty {
                    rows.formUnion(overlapping)
                } else {
                    firstFailureReason = firstFailureReason ?? ProseAddressing.textRangeFailureReason(start: start, end: end)
                }

            case .lineRange(let path, let start, let end):
                firstFailureReason = firstFailureReason ?? "lines \(start)–\(end)\(path.map { " of \($0)" } ?? "") were requested but this is a ticket view; it has no line ranges to emphasise"

            case .comment:
                firstFailureReason = firstFailureReason ?? "an id-addressed comment was requested but this is a ticket view; its comments are addressed by index via \"comment:<n>\", not by id"

            case .queueRow(let repo, let number):
                firstFailureReason = firstFailureReason ?? "queue row \(repo)#\(number) was requested but this is a ticket view; it has no queue rows to emphasise"
            }
        }

        if !rows.isEmpty { return .rows(rows.sorted()) }
        return .matchedNothing(reason: firstFailureReason ?? "the requested emphasis did not match this ticket")
    }

    /// `Anchor.section(name:)`/`Emphasis.section(name:)` both address either
    /// a canonical section name or the shared `"comment:<index>"`
    /// convention (D4) — one resolution path for both callers above.
    private func resolveSectionOrComment(_ requested: String) -> AnchorResolution {
        switch TicketPlan.parseCommentAddress(requested) {
        case .valid(let n):
            if let row = sectionOrCommentRowIndex["comment:\(n)"] {
                return .resolved(target: row)
            }
            return .unresolved(reason: "comment \(n) was requested but this ticket has \(commentCount) comment\(commentCount == 1 ? "" : "s") (comment \(n) of \(commentCount))")

        case .malformed(let raw):
            return .unresolved(reason: "comment address \"\(raw)\" is not a valid comment index")

        case .none:
            let canonical = TicketPlan.canonicalize(requested)
            if let row = sectionOrCommentRowIndex[canonical] {
                return .resolved(target: row)
            }
            return .unresolved(reason: "section \"\(requested)\" was requested but no section with that name exists in this ticket")
        }
    }
}

/// Shared `.textRange(start:end:)` resolution over a plan's plain-text
/// projection (D5) — used by both `ConversationPlan` and `TicketPlan`
/// above, so the offset arithmetic exists exactly once.
enum ProseAddressing {

    /// Every row index whose own plain-text span overlaps `start..<end` in
    /// the projection `ProsePlan.plainText(for:)` produces. `nil` when the
    /// range is empty or inverted (`start >= end`); an empty (but non-nil)
    /// array when the range is well-formed but falls entirely outside the
    /// document.
    static func rowsOverlapping(start: Int, end: Int, in rows: [ProseRow]) -> [Int]? {
        guard start < end else { return nil }
        var matches: [Int] = []
        var offset = 0
        for row in rows {
            let length = ProsePlan.plainText(of: row).utf16.count
            let rowStart = offset
            let rowEnd = offset + length
            if max(start, rowStart) < min(end, rowEnd) {
                matches.append(row.id)
            }
            offset = rowEnd + 1 // +1 for the "\n" joining rows in the projection
        }
        return matches
    }

    /// The single row `start..<end` falls into, plus the UTF-16 range
    /// within THAT row's own plain text — the finer precision D5 asks for
    /// beyond `EmphasisResolution.rows([Int])`'s row-only granularity. Only
    /// the first overlapping row is reported (a range spanning multiple
    /// rows is `rowsOverlapping`'s job); `nil` under the same conditions as
    /// `rowsOverlapping` (inverted/empty range, or no overlap at all).
    static func textRangeMatch(start: Int, end: Int, in rows: [ProseRow]) -> (row: Int, range: Range<Int>)? {
        guard start < end else { return nil }
        var offset = 0
        for row in rows {
            let length = ProsePlan.plainText(of: row).utf16.count
            let rowStart = offset
            let rowEnd = offset + length
            let overlapStart = max(start, rowStart)
            let overlapEnd = min(end, rowEnd)
            if overlapStart < overlapEnd {
                return (row.id, (overlapStart - rowStart)..<(overlapEnd - rowStart))
            }
            offset = rowEnd + 1
        }
        return nil
    }

    static func textRangeFailureReason(start: Int, end: Int) -> String {
        guard start < end else {
            return "text range \(start)–\(end) is an inverted or empty range"
        }
        return "text range \(start)–\(end) is not within this document"
    }
}
