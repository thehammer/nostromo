import Foundation

/// One rendered row of a diff view.
///
/// A diff renders as a flat list even though it arrives as a tree, because a
/// gutter and a scroll position are both indexed by row. Flattening once, here,
/// means the view never walks files-then-hunks-then-lines to answer "which row
/// is this?".
struct DiffRow: Equatable {
    enum Kind: Equatable {
        /// The `path` banner introducing a file's change.
        case fileHeader
        /// A verbatim `@@ ... @@` line.
        case hunkHeader
        case context
        case added
        case removed
        /// A non-content line the format carries anyway (`\ No newline …`).
        case meta
        /// A line this client generated to explain itself — currently only the
        /// "diff too large" statement.
        case notice
    }

    let kind: Kind
    /// Line number on the old side, where the line has one.
    let oldN: Int?
    /// Line number on the new side, where the line has one.
    let newN: Int?
    /// The file this row belongs to. `nil` only for a document-level notice.
    let path: String?
    /// The row's display text, with the diff marker character restored, so the
    /// concatenation of every row's text is itself a valid unified diff and can
    /// be coloured by `buildDiffAttributedString` without a second code path.
    let text: String
}

/// The flat, line-addressable rendering of a `diff` pane payload (W2 —
/// curated-agent-views).
///
/// `Foundation`-only and view-free for the same reason as `CodeDocument`: the
/// interesting behaviour is the arithmetic — which row is `path:line`? — and
/// the test bundle is host-less.
struct DiffDocument: Equatable {
    let rows: [DiffRow]
    /// True when the daemon's fetch hit its large-diff gate.
    let tooLarge: Bool
    /// How many files the PR changes.
    let changedFiles: Int

    // MARK: - Construction

    init(payload: DiffPayload) {
        self.tooLarge     = payload.tooLarge
        self.changedFiles = payload.changedFiles

        var rows: [DiffRow] = []

        // D4: a gated diff must SAY it was gated and name the file count. An
        // empty `files` list rendered without this line is indistinguishable
        // from a PR that changes nothing, which is the exact silent-truncation
        // failure this wedge exists to remove.
        if payload.tooLarge {
            let noun = payload.changedFiles == 1 ? "file" : "files"
            rows.append(DiffRow(
                kind: .notice,
                oldN: nil,
                newN: nil,
                path: nil,
                text: "diff too large to render — \(payload.changedFiles) \(noun) changed"
            ))
        }

        for file in payload.files {
            rows.append(DiffRow(
                kind: .fileHeader,
                oldN: nil,
                newN: nil,
                path: file.path,
                text: DiffDocument.headerText(for: file)
            ))
            for hunk in file.hunks {
                rows.append(DiffRow(
                    kind: .hunkHeader,
                    oldN: nil,
                    newN: nil,
                    path: file.path,
                    text: hunk.header
                ))
                for line in hunk.lines {
                    rows.append(DiffRow(
                        kind: DiffDocument.kind(of: line.kind),
                        oldN: line.oldN,
                        newN: line.newN,
                        path: file.path,
                        text: DiffDocument.text(of: line)
                    ))
                }
            }
        }

        self.rows = rows
    }

    private static func headerText(for file: DiffFileModel) -> String {
        let name: String
        if file.status == .renamed, let old = file.oldPath, old != file.path {
            name = "\(old) → \(file.path)"
        } else {
            name = file.path
        }
        return "\(name)  +\(file.additions) -\(file.deletions)"
    }

    private static func kind(of lineKind: DiffLineModel.Kind) -> DiffRow.Kind {
        switch lineKind {
        case .context: return .context
        case .added:   return .added
        case .removed: return .removed
        case .meta:    return .meta
        }
    }

    /// Restore the marker character the daemon stripped, so the row text is
    /// diff-shaped again.
    private static func text(of line: DiffLineModel) -> String {
        switch line.kind {
        case .context: return " " + line.text
        case .added:   return "+" + line.text
        case .removed: return "-" + line.text
        // A meta line keeps its raw text — the marker there IS the content.
        case .meta:    return line.text
        }
    }

    // MARK: - Rendering

    /// The exact text the view renders — the string the character ranges below
    /// are offsets into.
    var text: String { rows.map(\.text).joined(separator: "\n") }

    /// The character range of `rows[index]`, excluding its terminator.
    ///
    /// UTF-16 code units, matching `NSRange`/`NSTextView`.
    func characterRange(ofRow index: Int) -> NSRange? {
        guard index >= 0, index < rows.count else { return nil }
        var location = 0
        for i in 0..<index {
            location += rows[i].text.utf16.count + 1
        }
        return NSRange(location: location, length: rows[index].text.utf16.count)
    }

    /// The character range spanning rows `start...end` inclusive.
    func characterRange(fromRow start: Int, toRow end: Int) -> NSRange? {
        guard start <= end,
              let first = characterRange(ofRow: start),
              let last  = characterRange(ofRow: end)
        else { return nil }
        return NSRange(location: first.location,
                       length: last.location + last.length - first.location)
    }

    // MARK: - Addressing

    /// Resolve `Anchor.line(path:line:)` to exactly one row.
    ///
    /// New-side numbering wins: an agent saying "line 412 of session_manager.rs"
    /// while reviewing a PR means the file as the PR leaves it. A line that
    /// exists only on the old side — one this PR deletes — resolves to its
    /// removal row, which is the only place it appears at all.
    ///
    /// `path: nil` means "the pane's one file", so the search spans every row.
    func rowIndex(forPath path: String?, line: Int) -> Int? {
        let candidates = rows.indices.filter { path == nil || rows[$0].path == path }
        if let hit = candidates.first(where: { rows[$0].newN == line && rows[$0].kind != .removed }) {
            return hit
        }
        return candidates.first(where: { rows[$0].oldN == line && rows[$0].kind == .removed })
    }

    /// Every row index covered by an inclusive line range, for emphasis.
    ///
    /// Empty — not a clamped span — when nothing in the range is present in the
    /// diff, so a caller can tell "marked nothing" from "marked everything".
    func rowIndices(forPath path: String?, from start: Int, to end: Int) -> [Int] {
        guard start <= end else { return [] }
        return (start...end).compactMap { rowIndex(forPath: path, line: $0) }
    }
}
