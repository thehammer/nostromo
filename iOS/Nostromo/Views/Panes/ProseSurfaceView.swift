// Nostromo iOS — ProseSurfaceView.swift
//
// Renders `pr_conversation` and `ticket` for real (ios-curated-view-parity
// W9), replacing the honest stubs `PaneSurfaceView` showed for both since
// W2. One component renders both payloads (D7): it knows only `[ProseRow]`
// (NostromoKit's `Prose/ProseRow.swift`) plus an already-resolved
// `AnchorResolution`/`EmphasisResolution` — never a `PrConversationPayload`
// or a `TicketPayload` directly, and never a raw `PaneAddress`. Turning a
// payload into rows, and an anchor into a row-indexed resolution, is
// `ConversationPlan`/`TicketPlan`'s job (`Shared/NostromoKit/Sources/
// NostromoKit/Prose/`); `PaneSurfaceView` builds the right plan for the
// content kind it has and hands this view the result. A rendering
// improvement made here lands on both surfaces at once, which is the
// PRD's own reason threads/tickets share a renderer.
//
// Unlike macOS's `MarkdownBlockDocument`/`TicketBlockDocument`
// (`macOS/Nostromo/UI/MarkdownBlockDocument.swift`,
// `TicketBlockDocument.swift`), which flatten every comment into one
// `NSAttributedString` and drop `resolved`/`path`/`line`/`conversationError`
// entirely, this view renders `ThreadHeader`'s full fields (a `threadHeader`
// row) and a `notice` row for `conversationError` — see `ConversationPlan`.
//
// The scroll/restore/resolution machinery is the same discipline
// `CodeSurfaceView` established for `code` in W7: `ScrollDecision` decides
// whether a resolved anchor should move the viewport (never re-scrolling an
// anchor already on screen), `restoreScroll`/`saveScrollKey` restore a
// width-class rebuild's position (a plain tab switch never tears this view
// down — see `DynamicFocusView`'s ZStack), and every `AnchorResolution`/
// `EmphasisResolution` case is rendered or consulted, never silently
// dropped — the exact defect macOS's `TicketContentView`/
// `ConversationContentView` repeat for any anchor kind they don't handle
// (`macOS/Nostromo/UI/Views/TicketContentView.swift:115-125`,
// `ConversationContentView.swift:115-131`).
//
// D5 (this wedge) — emphasis is a `Set<Int>` of row ids, recomputed fresh
// from `emphasisResolution` on every render; there is no persisted
// document-wide formatting state for a second emphasis to have to clear
// before applying itself, so the `TicketContentView.clearEmphasis` defect
// (wiping inline-code/code-block tints along with the old emphasis) is
// structurally impossible here, not merely avoided by care.
//
// This file reads no width class (`WidthClass`/`nostromoWidthClass`
// appear nowhere below) — prose is the same prose at both widths, and
// `DiffSurfaceView.swift` remains the only renderer on W6's allowlist
// (memo B9).
import SwiftUI
import NostromoKit

struct ProseSurfaceView: View {
    let rows: [ProseRow]
    let anchorResolution: AnchorResolution
    let emphasisResolution: EmphasisResolution
    /// Save/restore this surface's single scroll-restore slot (W6, D5) —
    /// the same closures `PaneSurfaceView` hands `CodeSurfaceView`; a given
    /// pane only ever shows one content kind at a time, so one slot per
    /// pane is enough.
    let saveScrollKey: (Int) -> Void
    let restoreScroll: (ClosedRange<Int>?) -> ScrollRestore

    /// Which row ids are currently on screen. Transient, view-local — the
    /// same pattern `CodeSurfaceView.visibleRowIndices` uses.
    @State private var visibleRowIndices: Set<Int> = []

    // MARK: - Resolution -> plain view state

    /// The row `ScrollDecision` should be asked to honour, or `nil` both
    /// when no anchor was requested and when one was requested and could
    /// not be resolved — `ScrollDecision.decide` already treats `nil` as
    /// "don't move," and the two facts are told apart by `unresolvedNotice`
    /// instead, not by scrolling behaviour.
    private var anchorScrollTarget: Int? {
        switch anchorResolution {
        case .notRequested: return nil
        case .resolved(let target): return target
        case .unresolved: return nil
        }
    }

    private var emphasisRows: Set<Int> {
        switch emphasisResolution {
        case .none: return []
        case .rows(let rows): return Set(rows)
        case .matchedNothing: return []
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    unresolvedNotices
                    ForEach(rows) { row in
                        rowView(row)
                            .id(row.id)
                            .onAppear    { visibleRowIndices.insert(row.id) }
                            .onDisappear { visibleRowIndices.remove(row.id) }
                    }
                }
            }
            .onAppear { onFirstAppear(proxy: proxy) }
            // `rows` changes only when the underlying payload changes (D5) —
            // an address-only push leaves `rows` unchanged, since
            // `ConversationPlan`/`TicketPlan` never consult the address at
            // all when producing rows, only when resolving one.
            .onChange(of: rows) { _, _ in applyScrollDecision(proxy: proxy) }
            .onChange(of: anchorResolution) { _, _ in applyScrollDecision(proxy: proxy) }
            .onDisappear {
                // A width-class change gives no other warning that this
                // hierarchy is about to be torn down and rebuilt.
                if let topmost = visibleRowIndices.min() { saveScrollKey(topmost) }
            }
        }
    }

    // MARK: - Unresolved notices (memo B12)
    //
    // Rendered at the very top, above even the document header — an anchor
    // or emphasis that could not be resolved is a fact about the WHOLE
    // request, not about any one row, and never dismissible (the next push
    // replaces it). `PaneAddress.reason` (W5's tab caption) is a different
    // surface's job and is never rendered here too.

    @ViewBuilder
    private var unresolvedNotices: some View {
        if case .unresolved(let reason) = anchorResolution {
            NoticeBanner(text: reason)
        }
        if case .matchedNothing(let reason) = emphasisResolution {
            NoticeBanner(text: reason)
        }
    }

    // MARK: - Rows (D1/D2/D3/D6)

    @ViewBuilder
    private func rowView(_ row: ProseRow) -> some View {
        Group {
            switch row.kind {
            case .heading:
                Text(attributedText(for: row.spans))
                    .font(headingFont(for: row))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .padding(.bottom, 2)

            case .paragraph:
                Text(attributedText(for: row.spans))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 3)

            case .codeBlock(let lang, let text):
                codeBlockView(lang: lang, text: text)

            case .listItem(_, let marker):
                Text(marker)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)

            case .quote:
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 3)
                    Spacer(minLength: 0)
                }
                .frame(height: 10)

            case .rule:
                Divider().padding(.vertical, 8)

            case .tableRow(let cells, let isHeader):
                tableRowView(cells: cells, isHeader: isHeader)

            case .documentHeader(let header):
                documentHeaderView(header)

            case .threadHeader(let thread):
                threadHeaderView(thread)

            case .commentHeader(let author, let date):
                commentHeaderView(author: author, date: date)

            case .sectionHeader(_, let display):
                Text(display)
                    .font(.headline)
                    .padding(.top, 10)
                    .padding(.bottom, 2)

            case .notice(let kind):
                noticeRowView(kind)
            }
        }
        .padding(.leading, CGFloat(row.indent) * 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .background(emphasisRows.contains(row.id) ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    private func headingFont(for row: ProseRow) -> Font {
        guard case .heading(let level) = row.kind else { return .headline }
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        default: return .headline
        }
    }

    // MARK: - Document header (D4: PR title/author/url, or ticket key/summary/status/assignee/url)

    private func documentHeaderView(_ header: ProseHeader) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let key = header.key {
                    Text(key)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(header.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            let metaLine = [header.author, header.status, header.assignee]
                .compactMap { $0 }
                .joined(separator: " · ")
            if !metaLine.isEmpty {
                Text(metaLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let url = header.url, !url.isEmpty, let destination = URL(string: url) {
                Link(url, destination: destination)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Thread header (D2) — the row that makes an inline review
    // thread distinguishable from a general PR comment "at a glance," and
    // a resolved thread visibly resolved by three signals (glyph + word +
    // de-emphasised header), per D2's greyscale-survival requirement.

    private func threadHeaderView(_ thread: ThreadHeader) -> some View {
        HStack(spacing: 8) {
            Image(systemName: thread.resolved ? "checkmark.circle.fill" : threadKindGlyph(thread.kind))
                .foregroundStyle(thread.resolved ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(threadKindLabel(thread))
                    .font(.caption.weight(.semibold))
                if let path = thread.path {
                    Text(thread.line.map { "\(path):\($0)" } ?? path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if thread.resolved {
                Text("Resolved")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(thread.resolved ? Color.secondary : Color.primary)
        .padding(.vertical, 8)
        .padding(.top, 6)
        .overlay(Divider(), alignment: .top)
    }

    private func threadKindGlyph(_ kind: ConversationThreadKind) -> String {
        switch kind {
        case .inline: return "text.line.first.and.arrowtriangle.forward"
        case .review: return "checkmark.seal"
        case .issue:  return "bubble.left"
        }
    }

    private func threadKindLabel(_ thread: ThreadHeader) -> String {
        let base: String
        switch thread.kind {
        case .inline: base = "Inline comment"
        case .review: base = "Review"
        case .issue:  base = "Comment"
        }
        return "\(base) · \(thread.commentCount) comment\(thread.commentCount == 1 ? "" : "s")"
    }

    // MARK: - Comment header (shared by pr_conversation and ticket)

    private func commentHeaderView(author: String, date: Date) -> some View {
        HStack(spacing: 6) {
            Text(author).font(.caption.weight(.semibold))
            Text(date, style: .date)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    // MARK: - conversationError notice (D3 — this PRD's forbidden state in
    // its purest form: a partial conversation must never be presented as a
    // complete one). Rendered inline, where `ConversationPlan` placed it —
    // above the threads it did get — and never dismissible: it clears only
    // when the next push carries no error.

    private func noticeRowView(_ kind: NoticeKind) -> some View {
        switch kind {
        case .conversationIncomplete(let reason):
            return NoticeBanner(text: "Conversation is incomplete: \(reason)")
        }
    }

    // MARK: - Code blocks (D6)
    //
    // No `lineLimit`, no `.prefix(`, no row cap — a long block wraps and
    // stays fully readable, following the same rule `CodeSurfaceView`/
    // `DiffFileContentView` apply to `file`/`pr_diff`.

    private func codeBlockView(lang: String?, text: String) -> some View {
        // `lang` is intentionally never rendered — no syntax highlighting on
        // either client (D6) — but it is threaded through to this call site
        // exactly like every other field, unlike macOS's `_ = lang`
        // (`MarkdownBlockDocument.swift:233`), which discards it before it
        // ever reaches a view. A future contributor adding highlighting
        // finds the language already here.
        Text(text)
            .font(.system(.footnote, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.vertical, 4)
    }

    // MARK: - Tables (D1/D7) — pipe-separated cells, never a real grid: "a
    // real grid is worse at phone width, not better. Same for both."

    private func tableRowView(cells: [[MdSpan]], isHeader: Bool) -> some View {
        Text(cells.map { plainSpanText($0) }.joined(separator: " | "))
            .font(isHeader ? .caption.weight(.semibold) : .caption)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
    }

    private func plainSpanText(_ spans: [MdSpan]) -> String {
        ProsePlan.plainText(of: spans)
    }

    // MARK: - Inline spans (D1) — every `MdSpan` kind survives onto the
    // rendered text. Built as one `AttributedString` per row (never via the
    // markdown-parsing `AttributedString(markdown:)` initializer — the
    // daemon has already parsed this content into `MdSpan`s; building this
    // client-side from the tree, span by span, is not a second parser) so a
    // `.link`'s visible text stays inline and tappable via `Text`'s own
    // built-in link handling, rather than breaking the flow into a
    // separate `Link` view.

    private func attributedText(for spans: [MdSpan]) -> AttributedString {
        var result = AttributedString()
        for span in spans { result.append(attributedText(for: span)) }
        return result
    }

    private func attributedText(for span: MdSpan) -> AttributedString {
        switch span {
        case .text(let text):
            return AttributedString(text)

        case .code(let text):
            var s = AttributedString(text)
            s.font = .system(.body, design: .monospaced)
            s.backgroundColor = Color.secondary.opacity(0.15)
            return s

        case .emph(let spans):
            var s = attributedText(for: spans)
            s.font = .body.italic()
            return s

        case .strong(let spans):
            var s = attributedText(for: spans)
            s.font = .body.bold()
            return s

        case .strike(let spans):
            var s = attributedText(for: spans)
            s.strikethroughStyle = .single
            return s

        case .link(let spans, let url):
            var s = attributedText(for: spans)
            if let destination = URL(string: url) { s.link = destination }
            s.underlineStyle = .single
            s.foregroundColor = .accentColor
            return s

        case .image(let alt, _):
            var s = AttributedString("[image: \(alt)]")
            s.foregroundColor = .secondary
            return s
        }
    }

    // MARK: - Scrolling (same discipline as `CodeSurfaceView`, D4/D5)

    /// First layout: prefer a saved scroll-restore key (the width-class-
    /// rebuild/remount case — a plain tab switch never tears this view down
    /// at all). Only when there is nothing saved does a freshly-arrived
    /// anchor get to decide where the view lands.
    private func onFirstAppear(proxy: ScrollViewProxy) {
        switch restoreScroll(visibleRowRange()) {
        case .scrollTo(let target):
            if rows.contains(where: { $0.id == target }) {
                // No animation: this is putting the operator back where she
                // already was, not taking her somewhere new.
                proxy.scrollTo(target, anchor: .top)
            }
        case .none:
            applyScrollDecision(proxy: proxy)
        }
    }

    /// An anchor already on screen must not move the viewport; a fresh
    /// payload or a fresh address re-anchors without rebuilding anything
    /// else (D5).
    private func applyScrollDecision(proxy: ScrollViewProxy) {
        switch ScrollDecision.decide(anchor: anchorScrollTarget, visibleRange: visibleRowRange()) {
        case .none:
            break
        case .scrollTo(let target):
            if rows.contains(where: { $0.id == target }) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }

    /// The contiguous span of row ids currently on screen. `nil` before
    /// anything has been laid out, which both `ScrollDecision` and
    /// `ScrollRestore` read as a first paint that always honours its target.
    private func visibleRowRange() -> ClosedRange<Int>? {
        guard let low = visibleRowIndices.min(), let high = visibleRowIndices.max() else { return nil }
        return low...high
    }
}
