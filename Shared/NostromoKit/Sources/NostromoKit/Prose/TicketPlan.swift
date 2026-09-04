import Foundation

/// Turns a `ticket` payload into a platform-neutral `[ProseRow]` plan
/// (ios-curated-view-parity W9, D1/D4/D7).
///
/// Row order: the document header, then every section in payload order,
/// then every comment in order. A section with its own `heading` spans
/// renders as a plain `.heading` row carrying those spans verbatim; a
/// section with none renders a `.sectionHeader` row whose `display` is
/// derived from its canonical name (`displayName(_:)` below, ported
/// unchanged from `TicketBlockDocument.displayName(_:)`,
/// `macOS/Nostromo/UI/TicketBlockDocument.swift:111-116`).
///
/// `sectionOrCommentRowIndex` mirrors `TicketBlockDocument.ranges`
/// (`:20-24`): one lookup table keyed by either a section's canonical name
/// or `"comment:<index>"`, because `Anchor.section(name:)` addresses both
/// the same way. Kept exactly, so an agent's `section: "comment:3"` means
/// the same thing on both clients.
public struct TicketPlan: Equatable {
    public let rows: [ProseRow]
    public let sectionOrCommentRowIndex: [String: Int]
    public let commentCount: Int

    /// The row index a `.section(name:)` anchor that names no section this
    /// ticket has should fall back to (D4: "the top of the description")
    /// — the canonical `"description"` section's header row if present,
    /// else the first section's header row, else the document header row
    /// (row 0). Never absent: there is always at least the header row.
    public let descriptionFallbackRow: Int

    public init(payload: TicketPayload) {
        var rows: [ProseRow] = []
        var nextId = 0
        var index: [String: Int] = [:]
        var firstSectionRow: Int?

        let header = ProseHeader(
            key: payload.key,
            title: payload.summary,
            status: payload.status.isEmpty ? nil : payload.status,
            assignee: (payload.assignee?.isEmpty ?? true) ? nil : payload.assignee,
            url: payload.url.isEmpty ? nil : payload.url
        )
        rows.append(ProseRow(id: nextId, kind: .documentHeader(header)))
        nextId += 1

        for section in payload.sections {
            let headerRowId = nextId
            if let heading = section.heading, !heading.isEmpty {
                rows.append(ProseRow(id: nextId, kind: .heading(level: 2), indent: 0, spans: heading))
            } else {
                rows.append(ProseRow(id: nextId, kind: .sectionHeader(
                    name: section.name,
                    display: Self.displayName(section.name)
                )))
            }
            nextId += 1
            index[section.name] = headerRowId
            if firstSectionRow == nil { firstSectionRow = headerRowId }
            ProsePlan.appendRows(for: section.blocks, indent: 0, rows: &rows, nextId: &nextId)
        }

        for comment in payload.comments {
            let headerRowId = nextId
            rows.append(ProseRow(id: nextId, kind: .commentHeader(author: comment.author, date: comment.createdAt)))
            nextId += 1
            index["comment:\(comment.index)"] = headerRowId
            ProsePlan.appendRows(for: comment.blocks, indent: 0, rows: &rows, nextId: &nextId)
        }

        self.rows = rows
        self.sectionOrCommentRowIndex = index
        self.commentCount = payload.comments.count
        self.descriptionFallbackRow = index["description"] ?? firstSectionRow ?? 0
    }

    /// `"acceptance_criteria"` -> `"Acceptance Criteria"`. Ported unchanged
    /// from `TicketBlockDocument.displayName(_:)` so the two clients name
    /// the same section the same way.
    static func displayName(_ canonical: String) -> String {
        canonical
            .split(separator: "_")
            .map { $0.isEmpty ? "" : $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Case- and punctuation-insensitive canonical form of a *requested*
    /// section name, used only when resolving an `Anchor`/`Emphasis`
    /// against `sectionOrCommentRowIndex`'s keys (which are already
    /// canonical, since they come straight from the payload's own section
    /// names) — never used to change what's stored. The parent PRD
    /// requires near-variant matching ("Acceptance Criteria" vs
    /// "acceptance_criteria" vs "acceptance criteria:") without turning the
    /// anchor into a resolved offset or adding a smarter resolver (out of
    /// scope, D4/W9's own decision).
    static func canonicalize(_ name: String) -> String {
        var value = name.lowercased().trimmingCharacters(in: .whitespaces)
        if value.hasSuffix(":") { value.removeLast() }
        value = value.trimmingCharacters(in: .whitespaces)
        return value.replacingOccurrences(of: " ", with: "_")
    }

    /// Whether a (canonicalized) requested name is the `"comment:<n>"`
    /// addressing convention, and if so, what it parsed to.
    enum CommentAddress: Equatable {
        /// Not a `"comment:"`-shaped address at all — try section matching.
        case none
        case valid(Int)
        case malformed(raw: String)
    }

    static func parseCommentAddress(_ requested: String) -> CommentAddress {
        let canonical = canonicalize(requested)
        guard canonical.hasPrefix("comment:") else { return .none }
        let rest = canonical.dropFirst("comment:".count).trimmingCharacters(in: .whitespaces)
        if let n = Int(rest) { return .valid(n) }
        return .malformed(raw: rest)
    }
}
