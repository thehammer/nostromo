import Foundation

// NostromoKit — DiffAddressing.swift
//
// `Anchor`/`Emphasis` resolution for `DiffDocument` (ios-curated-view-parity
// W8, D3/D4) — the diff-flavoured counterpart to `CodeDocument`'s resolvers
// in `AnchorResolution.swift`. Kept in its own file, separate from
// `DiffDocument.swift`, so the ported file stays a byte-for-byte-comparable
// port of macOS's `DiffDocument.swift` (memo B10/B11) with no new behaviour
// mixed in.
//
// Returns the SAME three-state `AnchorResolution`/`EmphasisResolution` types
// `CodeDocument` uses (memo B12): "not requested", "resolved", and
// "requested but could not be resolved," each with an operator-facing
// reason for the last. `target`/`rows` here are indices into
// `DiffDocument.rows` — the flattened row array — rather than a document's
// own lines; the row at that index carries its own `path`, which is how a
// caller learns which FILE an anchor landed in without this type knowing
// anything about "which file is open" (that's the surface's job, D3).
//
// `tooLarge` gates everything, before any anchor/emphasis-specific rule: a
// gated diff has no rows to resolve against at all, so even an anchor kind
// this surface otherwise can't use, or a path naming no file, must still
// report the gate — not its own, more specific-sounding, reason. This is
// checked first in both `resolve(anchor:)` and `resolve(emphasis:)`.
extension DiffDocument {

    /// Resolve `anchor` against this diff.
    public func resolve(anchor: Anchor?) -> AnchorResolution {
        guard let anchor else { return .notRequested }
        if let gated = gatedReason() {
            return .unresolved(reason: gated)
        }

        switch anchor {
        case .line(let path, let line):
            if let path, !containsFile(path) {
                return .unresolved(reason: describeMissingPath(path))
            }
            guard let index = rowIndex(forPath: path, line: line) else {
                return .unresolved(reason: describeMissingLine(line, path: path))
            }
            return .resolved(target: index)

        case .comment:
            return .unresolved(reason: "this is a diff view; it has no comments to anchor to")

        case .section:
            return .unresolved(reason: "this is a diff view; it has no named sections to anchor to")

        case .queueRow:
            return .unresolved(reason: "this is a diff view; it has no queue rows to anchor to")
        }
    }

    /// Resolve every `Emphasis` in `emphases` against this diff, unioning
    /// their rows without duplication — the same union-with-one-reported-
    /// reason model `CodeDocument.resolve(emphasis:)` uses.
    public func resolve(emphasis emphases: [Emphasis]) -> EmphasisResolution {
        guard !emphases.isEmpty else { return .none }
        if let gated = gatedReason() {
            return .matchedNothing(reason: gated)
        }

        var rows: Set<Int> = []
        var firstFailureReason: String?

        for emphasis in emphases {
            switch emphasis {
            case .lineRange(let path, let start, let end):
                if let path, !containsFile(path) {
                    firstFailureReason = firstFailureReason ?? describeMissingPath(path)
                    continue
                }
                guard start <= end else {
                    firstFailureReason = firstFailureReason ?? "lines \(start)–\(end) is an inverted range"
                    continue
                }
                let indices = rowIndices(forPath: path, from: start, to: end)
                guard !indices.isEmpty else {
                    firstFailureReason = firstFailureReason ?? describeMissingRange(start, end, path: path)
                    continue
                }
                rows.formUnion(indices)

            case .comment:
                firstFailureReason = firstFailureReason ?? "this is a diff view; it has no comments to emphasise"

            case .section:
                firstFailureReason = firstFailureReason ?? "this is a diff view; it has no named sections to emphasise"

            case .textRange:
                firstFailureReason = firstFailureReason ?? "this is a diff view; it has no character-offset ranges to emphasise"

            case .queueRow:
                firstFailureReason = firstFailureReason ?? "this is a diff view; it has no queue rows to emphasise"
            }
        }

        if !rows.isEmpty { return .rows(rows.sorted()) }
        return .matchedNothing(reason: firstFailureReason ?? "the requested emphasis did not match this diff")
    }

    // MARK: - Gating (D4)

    /// `nil` unless this diff was gated by the daemon's large-diff limit, in
    /// which case there are no rows to resolve ANY anchor/emphasis against —
    /// checked before any anchor/emphasis-specific rule so the reason always
    /// names the gate rather than a more specific-sounding but misleading
    /// failure (a "kind this surface can't use" or "path not found" message
    /// on a diff that in truth has no files loaded at all).
    private func gatedReason() -> String? {
        guard tooLarge else { return nil }
        let noun = changedFiles == 1 ? "file" : "files"
        return "the diff is too large to render — \(changedFiles) \(noun) changed — there is nothing to resolve against"
    }

    // MARK: - File/line presence

    private func containsFile(_ path: String) -> Bool {
        rows.contains { $0.path == path }
    }

    /// How many distinct files this (non-gated) diff actually has rows for —
    /// the fact a "path not found" reason names, so the operator can tell at
    /// a glance whether the requested path is merely misspelled or genuinely
    /// outside a diff this small.
    private var fileCount: Int {
        rows.reduce(into: Set<String>()) { set, row in
            if row.kind == .fileHeader, let path = row.path { set.insert(path) }
        }.count
    }

    // MARK: - Reason wording
    //
    // "This file isn't in the diff" and "this line isn't in the diff" are
    // different facts (memo B12/PRD) — kept as two distinctly-worded
    // functions rather than one parameterised message, so accidentally
    // reusing one for the other's case is a visible diff in this file, not a
    // silent behavioural regression.

    private func describeMissingPath(_ path: String) -> String {
        let noun = fileCount == 1 ? "file" : "files"
        return "\(path) is not part of this diff (\(fileCount) \(noun) changed)"
    }

    private func describeMissingLine(_ line: Int, path: String?) -> String {
        if let path {
            return "line \(line) is not in \(path)'s diff"
        }
        return "line \(line) is not in this diff"
    }

    private func describeMissingRange(_ start: Int, _ end: Int, path: String?) -> String {
        if let path {
            return "lines \(start)–\(end) aren't in \(path)'s diff"
        }
        return "lines \(start)–\(end) aren't in this diff"
    }
}
