import AppKit

/// Turns a `ticket` payload into one attributed string plus the
/// character-range arithmetic section/comment anchoring needs (W4 —
/// curated-agent-views).
///
/// `AppKit`-only logic — no `NSTextView`, no window — so the host-less
/// `NostromoTests` bundle can compile and test it directly (dual-membership
/// in `project.pbxproj`), the same discipline `MarkdownBlockDocument`
/// established in W3. Every block is delegated to
/// `MarkdownBlockDocument`'s own rendering helpers (`render(blocks:indent:)`,
/// `render(block:indent:)`, `headingRun`, `blockBreak`) — this file adds only
/// the header/section/comment framing around them. `TicketContentView`
/// (a separate file, AppKit-shell-only, not dual-membership) is the thin
/// `NSView` that renders what this produces and does nothing else.
struct TicketBlockDocument: Equatable {
    /// The full attributed ticket: a header (key/summary/status/assignee/
    /// url), then every section in order, then every comment in order.
    let attributedString: NSAttributedString
    /// Character range for a section (keyed by its canonical name, e.g.
    /// `"description"`, `"acceptance_criteria"`) or a comment (keyed by
    /// `"comment:<index>"`) — one lookup table, because the daemon addresses
    /// both the same way: `Anchor.section(name:)` with either a section name
    /// or a `comment:<n>` name (D4 of the W4 plan).
    let ranges: [String: NSRange]

    init(payload: TicketPayload) {
        let result = NSMutableAttributedString()
        var ranges: [String: NSRange] = [:]

        result.append(Self.headerBlock(payload))
        result.append(MarkdownBlockDocument.blockBreak())

        for section in payload.sections {
            let start = result.length
            if let heading = section.heading {
                result.append(MarkdownBlockDocument.render(block: .heading(level: 2, spans: heading), indent: 0))
            } else {
                result.append(MarkdownBlockDocument.headingRun(Self.displayName(section.name), level: 2))
                result.append(NSAttributedString(string: "\n\n", attributes: MarkdownBlockDocument.textAttrs()))
            }
            result.append(MarkdownBlockDocument.render(blocks: section.blocks, indent: 0))
            ranges[section.name] = NSRange(location: start, length: result.length - start)
            result.append(MarkdownBlockDocument.blockBreak())
        }

        for comment in payload.comments {
            let start = result.length
            result.append(Self.commentHeader(index: comment.index, author: comment.author, date: comment.createdAt))
            result.append(MarkdownBlockDocument.render(blocks: comment.blocks, indent: 0))
            ranges["comment:\(comment.index)"] = NSRange(location: start, length: result.length - start)
            result.append(MarkdownBlockDocument.blockBreak())
        }

        attributedString = result
        self.ranges = ranges
    }

    /// The character range addressed by `name` — a section's canonical name
    /// or `"comment:<index>"` — if this document has one.
    func range(forSectionOrComment name: String) -> NSRange? {
        ranges[name]
    }

    static func == (lhs: TicketBlockDocument, rhs: TicketBlockDocument) -> Bool {
        lhs.attributedString.isEqual(to: rhs.attributedString) && lhs.ranges == rhs.ranges
    }

    // MARK: - Header / section / comment framing

    private static func headerBlock(_ payload: TicketPayload) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "\(payload.key)  ", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Theme.fgMuted,
        ]))
        out.append(MarkdownBlockDocument.headingRun(payload.summary, level: 1))
        out.append(NSAttributedString(string: "\n", attributes: MarkdownBlockDocument.textAttrs()))

        var metaParts: [String] = []
        if !payload.status.isEmpty {
            metaParts.append(payload.status)
        }
        if let assignee = payload.assignee, !assignee.isEmpty {
            metaParts.append(assignee)
        }
        if !payload.url.isEmpty {
            metaParts.append(payload.url)
        }
        out.append(NSAttributedString(
            string: metaParts.joined(separator: "  ·  ") + "\n",
            attributes: MarkdownBlockDocument.mutedAttrs()
        ))
        return out
    }

    private static func commentHeader(index: Int, author: String, date: Date) -> NSAttributedString {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let text = "Comment #\(index) · \(author) · \(formatter.string(from: date))\n"
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Theme.fgMuted,
        ])
    }

    /// `"acceptance_criteria"` -> `"Acceptance Criteria"` — used only for the
    /// leading `description` section, which has no heading of its own to
    /// render.
    private static func displayName(_ canonical: String) -> String {
        canonical
            .split(separator: "_")
            .map { $0.isEmpty ? "" : $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
