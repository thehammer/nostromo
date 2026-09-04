import Foundation

/// Turns a `pr_conversation` payload into a platform-neutral `[ProseRow]`
/// plan (ios-curated-view-parity W9, D1/D2/D3/D7).
///
/// The row order is: the document header, the PR's own description (if
/// any), the `conversationError` notice (if set — D3, sitting where the
/// missing threads would have been), then every thread in payload order,
/// each as one `threadHeader` row followed by its comments' rows in order
/// (D2). `diffHunk` is carried on `ThreadHeader` and produces no row of its
/// own.
///
/// Unlike macOS's `MarkdownBlockDocument`
/// (`macOS/Nostromo/UI/MarkdownBlockDocument.swift:29-58`), which flattens
/// every comment from every thread into one linear run, threads here are
/// genuine groups: `commentOrder`/`commentRowIndex` still let an id resolve
/// to a row directly, but the row list itself never interleaves one
/// thread's comments with another's.
public struct ConversationPlan: Equatable {
    public let rows: [ProseRow]
    /// Comment id -> the row index of that comment's `commentHeader` row.
    public let commentRowIndex: [String: Int]
    /// Comment ids in rendered order: thread order, then comment order
    /// within each thread.
    public let commentOrder: [String]

    public init(payload: PrConversationPayload) {
        var rows: [ProseRow] = []
        var nextId = 0
        var commentRowIndex: [String: Int] = [:]
        var commentOrder: [String] = []

        let header = ProseHeader(
            title: payload.title,
            author: payload.author.isEmpty ? nil : payload.author,
            url: payload.url.isEmpty ? nil : payload.url
        )
        rows.append(ProseRow(id: nextId, kind: .documentHeader(header)))
        nextId += 1

        if !payload.body.isEmpty {
            ProsePlan.appendRows(for: payload.body, indent: 0, rows: &rows, nextId: &nextId)
        }

        if let conversationError = payload.conversationError, !conversationError.isEmpty {
            rows.append(ProseRow(id: nextId, kind: .notice(.conversationIncomplete(reason: conversationError))))
            nextId += 1
        }

        for thread in payload.threads {
            rows.append(ProseRow(id: nextId, kind: .threadHeader(ThreadHeader(
                threadId: thread.id,
                kind: thread.kind,
                path: thread.path,
                line: thread.line,
                diffHunk: thread.diffHunk,
                resolved: thread.resolved,
                commentCount: thread.comments.count
            ))))
            nextId += 1

            for comment in thread.comments {
                let commentRowId = nextId
                rows.append(ProseRow(id: nextId, kind: .commentHeader(author: comment.author, date: comment.createdAt)))
                nextId += 1
                commentRowIndex[comment.id] = commentRowId
                commentOrder.append(comment.id)
                ProsePlan.appendRows(for: comment.body, indent: 0, rows: &rows, nextId: &nextId)
            }
        }

        self.rows = rows
        self.commentRowIndex = commentRowIndex
        self.commentOrder = commentOrder
    }
}
