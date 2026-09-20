import Foundation

// The platform-neutral render plan for `pr_conversation` and `ticket`
// (ios-curated-view-parity W9, D1).
//
// macOS's `MarkdownBlockDocument`/`TicketBlockDocument`
// (`macOS/Nostromo/UI/MarkdownBlockDocument.swift`,
// `macOS/Nostromo/UI/TicketBlockDocument.swift`) are `import AppKit` — they
// produce `NSAttributedString` and reach for `NSFont`/`NSColor`, and porting
// them via `UIFont`/`UIColor` shims would produce a type whose whole output
// is a platform string. `ProseRow` is the alternative: an ordered list of
// rows, each row a semantic kind plus inline spans, that a SwiftUI view maps
// to rows however it likes.
//
// Rows are the addressing unit (not a character offset): macOS anchors by
// `NSRange` because `NSTextView` measures in character offsets; SwiftUI
// scrolls to a view identity, so a row index is both the natural unit and a
// far easier thing to test — see `Code/AnchorResolution.swift`'s
// `AnchorResolution.resolved(target:)`, whose `target` is already "a bare Int
// whose meaning is the surface's own" (`Code/ScrollDecision.swift`'s doc
// comment says exactly that).

/// A document-level header row's fields — flexible enough for both a PR's
/// (title, author, url) and a ticket's (key, summary, status, assignee,
/// url), so `ProseRowKind.documentHeader` needs only one case. Fields that
/// don't apply to a given payload are `nil`; the view joins only the
/// present ones for display, so there is no join-artifact bug to reproduce
/// (contrast `TicketBlockDocument`'s string-joined metadata line, which is
/// exactly where macOS's nil-assignee test guards against one).
public struct ProseHeader: Equatable {
    /// The ticket key (`"PROJ-123"`), or `nil` for a PR conversation.
    public let key: String?
    /// The PR title, or the ticket summary.
    public let title: String
    /// The PR author, or `nil` for a ticket.
    public let author: String?
    /// The ticket status, or `nil` for a PR.
    public let status: String?
    /// The ticket assignee, or `nil` for a PR or an unassigned ticket.
    public let assignee: String?
    /// The PR's or ticket's URL, or `nil` if absent.
    public let url: String?

    public init(
        key: String? = nil,
        title: String,
        author: String? = nil,
        status: String? = nil,
        assignee: String? = nil,
        url: String? = nil
    ) {
        self.key = key
        self.title = title
        self.author = author
        self.status = status
        self.assignee = assignee
        self.url = url
    }
}

/// A `pr_conversation` thread's header fields (D2) — what macOS's
/// `MarkdownBlockDocument` decodes from `ConversationThreadModel` and then
/// discards entirely (`kind`/`path`/`line`/`diffHunk`/`resolved` are read by
/// nothing there). This is the row that makes an inline review thread
/// distinguishable from a general PR comment "at a glance," the PRD's
/// criterion macOS fails.
public struct ThreadHeader: Equatable {
    public let threadId: String
    public let kind: ConversationThreadKind
    /// Inline threads only.
    public let path: String?
    /// Inline threads only, new-side line number.
    public let line: Int?
    /// Carried so a later wedge can add a disclosure without re-plumbing
    /// (D2) — deliberately never rendered by this wedge. A slab of diff
    /// text inside a prose surface would bury the comment it belongs to at
    /// phone width.
    public let diffHunk: String?
    public let resolved: Bool
    public let commentCount: Int

    public init(
        threadId: String,
        kind: ConversationThreadKind,
        path: String?,
        line: Int?,
        diffHunk: String?,
        resolved: Bool,
        commentCount: Int
    ) {
        self.threadId = threadId
        self.kind = kind
        self.path = path
        self.line = line
        self.diffHunk = diffHunk
        self.resolved = resolved
        self.commentCount = commentCount
    }
}

/// What a `notice` row is telling the reader. One case today —
/// `conversationError`, D3's "this PRD's forbidden state in its purest
/// form" — but a named enum rather than a bare string so a second notice
/// kind (should one ever be needed) can't be confused with this one by a
/// reader scanning for `.conversationIncomplete`.
public enum NoticeKind: Equatable {
    /// `PrConversationPayload.conversationError` was set: the threads on
    /// screen are known to be incomplete. `reason` is the daemon's own
    /// error string.
    case conversationIncomplete(reason: String)
}

/// One row's semantic kind. `spans` on `ProseRow` carries the row's inline
/// content for the cases that have any (`.heading`/`.paragraph`/
/// `.tableRow`'s cells are carried inside the case itself, since a table row
/// is multiple cells, not one span run) — every other case's `spans` is
/// empty, per `ProseRow.spans`'s own doc comment.
public enum ProseRowKind: Equatable {
    case heading(level: Int)
    case paragraph
    /// A fenced or indented code block. `lang` is retained even though
    /// syntax highlighting is out of scope on both clients (D6) — the
    /// assertion macOS's `_ = lang` fails.
    case codeBlock(lang: String?, text: String)
    /// One list item's marker line. The item's own block content (usually
    /// one `.paragraph`) follows as separate rows nested one indent level
    /// deeper — the same structural convention `.quote` uses, so nested
    /// lists and nested quotes both just mean "increasing indent," never a
    /// flattening special case.
    case listItem(ordered: Bool, marker: String)
    /// A blockquote's marker line; its content follows nested one indent
    /// level deeper (see `.listItem`).
    case quote
    case rule
    /// One row of a markdown table, rendered as pipe-separated cells per
    /// the PRD ("a real grid is worse at phone width, not better").
    /// `isHeader` distinguishes the header row so a view can weight it.
    case tableRow(cells: [[MdSpan]], isHeader: Bool)
    /// The document's own header — PR title/author/url, or ticket
    /// key/summary/status/assignee/url.
    case documentHeader(ProseHeader)
    /// A `pr_conversation` thread's header (D2).
    case threadHeader(ThreadHeader)
    /// A comment's header — shared by `pr_conversation` (keyed by comment
    /// id elsewhere) and `ticket` (keyed by `"comment:<index>"` elsewhere).
    case commentHeader(author: String, date: Date)
    /// A ticket section's header when the payload supplied no `heading`
    /// spans of its own. `name` is the canonical name (`"acceptance_criteria"`);
    /// `display` is the title-cased display form (D4, ported from
    /// `TicketBlockDocument.displayName(_:)`). A section WITH its own
    /// `heading` spans renders as a plain `.heading` row instead, carrying
    /// those spans verbatim (macOS's same rule).
    case sectionHeader(name: String, display: String)
    /// D3: `conversationError`, rendered where the missing threads would
    /// have been. Not dismissible — there is no affordance to clear it,
    /// because it's a fact about what's on screen, not an alert.
    case notice(NoticeKind)
}

/// One row of a rendered `pr_conversation`/`ticket` document (D1).
///
/// `id` is a stable, ascending index into the plan that produced this row
/// — the addressing unit `AnchorResolution`/`EmphasisResolution` resolve to
/// (a bare `Int`, per `Code/ScrollDecision.swift`'s doc comment: "every call
/// site already has its own way of resolving an `Anchor` to an integer
/// position... this type's whole job is the same for either").
public struct ProseRow: Equatable, Identifiable {
    public let id: Int
    public let kind: ProseRowKind
    /// Nesting depth — 0 at the top level, incremented under a list item or
    /// a blockquote (see `ProseRowKind.listItem`/`.quote`).
    public let indent: Int
    /// This row's inline content, for the kinds that have any
    /// (`.heading`/`.paragraph`). Empty for every structural row
    /// (`.listItem`, `.quote`, `.rule`, `.tableRow` — whose cells carry
    /// their own spans inside the case — `.documentHeader`,
    /// `.threadHeader`, `.commentHeader`, `.sectionHeader`, `.notice`).
    public let spans: [MdSpan]

    public init(id: Int, kind: ProseRowKind, indent: Int = 0, spans: [MdSpan] = []) {
        self.id = id
        self.kind = kind
        self.indent = indent
        self.spans = spans
    }
}
