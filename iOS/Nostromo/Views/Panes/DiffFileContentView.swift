// Nostromo iOS — DiffFileContentView.swift
//
// The file-content half of `pr_diff` (ios-curated-view-parity W8): one
// file's hunks and lines, rendered with the SAME gutter/wrap/marking
// mechanism `file` uses (`CodeRowView`, extracted from `CodeSurfaceView` in
// this wedge) rather than a second implementation that could drift from it
// (parity requirement, D5's "same gutter, same wrapping, same marking").
//
// D5 — kind is distinguishable by THREE signals, not colour alone: the
// restored diff marker (`+`/`-`/space, already in `DiffRow.text`), a
// background tint, and the gutter's new-or-old-number precedence
// (`gutterText(for:)` below — new number if present, else old, mirroring
// macOS's `CodeContentView` gutter and `DiffDocument.rowIndex`'s own
// documented new-side-wins rule). Hunk headers and the file's own header
// are structure, not content, and get their own row treatment; `.meta` rows
// render their raw text verbatim (already true of `DiffRow.text`, ported
// unmodified from `DiffDocument`).
//
// D6 — no truncation of any kind: no `.prefix(`, no numeric row cap, no
// `lineLimit(` on the content column (scoped to `row(_:_:)` below). Relies
// on `LazyVStack`'s own laziness, exactly like `CodeSurfaceView`.
//
// Line resolution (which row a `path:line` anchor lands on, which rows an
// emphasis range covers) is NEVER reimplemented here — this view reads
// `oldN`/`newN` only to DISPLAY the gutter number (`gutterText(for:)`,
// nil-coalescing, no comparison), never to decide which row an anchor
// means. That decision already happened in `DiffDocument`/`DiffAddressing`,
// one level up in `DiffSurfaceView`, which hands this view a plain resolved
// row index (`scrollTarget`) and a plain set of marked indices
// (`emphasisRows`) — both indices into `document.rows`, the SAME numbering
// space `DiffAddressing` resolved against, so this view never needs its own
// notion of "which row is line N".
//
// Takes identical parameters at both widths (D2) — this file never reads
// `WidthClass`.
import SwiftUI
import NostromoKit

struct DiffFileContentView: View {
    let document: DiffDocument
    let file: DiffFileModel
    /// A row index into `document.rows` to scroll to, or `nil` when this
    /// file has nothing to arrive at (resolved by `DiffSurfaceView`, never
    /// here).
    let scrollTarget: Int?
    /// Row indices (into `document.rows`) to mark — only ever indices that
    /// fall within THIS file's own rows actually render as marked, since
    /// the `ForEach` below only ever iterates this file's rows.
    let emphasisRows: Set<Int>
    /// The emphasis-resolution notice (`EmphasisResolution.matchedNothing`'s
    /// reason), or `nil` when there's nothing to say.
    let emphasisNotice: String?
    let saveScrollKey: (Int) -> Void
    let restoreScroll: (ClosedRange<Int>?) -> ScrollRestore

    @State private var visibleRowIndices: Set<Int> = []

    /// This file's rows, paired with their GLOBAL index into
    /// `document.rows` — the same index space `scrollTarget`/
    /// `emphasisRows` use, so no translation is ever needed between "this
    /// view's row" and "the row `DiffAddressing` resolved". The file's own
    /// header row is excluded — `header` below renders that information as
    /// this view's own header, not as a row among the hunks.
    private var rows: [(index: Int, row: DiffRow)] {
        document.rows.enumerated()
            .filter { $0.element.path == file.path && $0.element.kind != .fileHeader }
            .map { (index: $0.offset, row: $0.element) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let emphasisNotice {
                            NoticeBanner(text: emphasisNotice)
                        }
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows, id: \.index) { entry in
                                row(entry.index, entry.row)
                                    .onAppear    { visibleRowIndices.insert(entry.index) }
                                    .onDisappear { visibleRowIndices.remove(entry.index) }
                            }
                        }
                    }
                }
                .onAppear { onFirstAppear(proxy: proxy) }
                .onChange(of: scrollTarget) { _, _ in applyScrollDecision(proxy: proxy) }
                .onDisappear {
                    // A width-class change (or a switch to a different
                    // file — this view is `.id(path)`'d by its container)
                    // gives no other warning that this hierarchy is about
                    // to be torn down.
                    if let topmost = visibleRowIndices.min() { saveScrollKey(topmost) }
                }
            }
        }
    }

    // MARK: - Header (D7's counts, restated for the open file)

    private var header: some View {
        HStack(spacing: 8) {
            Text(headerPath)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Text("+\(file.additions)").foregroundStyle(.green)
                Text("-\(file.deletions)").foregroundStyle(.red)
            }
            .font(.system(size: 12, design: .monospaced).monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var headerPath: String { file.displayPath }

    // MARK: - Rows (D5, D6)

    /// Hunk headers are structure, not content, and get their own treatment
    /// — no gutter, no marking. Every other kind renders through the SAME
    /// `CodeRowView` `CodeSurfaceView` uses for `file`, with a per-kind
    /// marker colour/tint (D5) and no `lineLimit` anywhere in this function
    /// (D6).
    private func row(_ index: Int, _ diffRow: DiffRow) -> some View {
        Group {
            if diffRow.kind == .hunkHeader {
                Text(diffRow.text)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12))
            } else {
                CodeRowView(
                    gutterText: gutterText(for: diffRow),
                    text: diffRow.text,
                    marked: emphasisRows.contains(index),
                    gutterWidth: gutterWidth,
                    textColor: textColor(for: diffRow.kind),
                    background: rowBackground(for: diffRow.kind)
                )
            }
        }
        .id(index)
    }

    /// New number if present, else old — the same precedence
    /// `DiffDocument.rowIndex`'s new-side-wins rule uses to decide which
    /// row a line lands on, restated here purely for DISPLAY. A plain
    /// nil-coalescing read, never a comparison: deciding which row a line
    /// means is `DiffAddressing`'s job, not this view's (see this file's
    /// header comment).
    private func gutterText(for diffRow: DiffRow) -> String {
        if let newN = diffRow.newN { return "\(newN)" }
        if let oldN = diffRow.oldN { return "\(oldN)" }
        return ""
    }

    private func textColor(for kind: DiffRow.Kind) -> Color {
        switch kind {
        case .added:  return .green
        case .removed: return .red
        case .meta:   return .secondary
        case .context, .fileHeader, .hunkHeader, .notice:
            return .primary
        }
    }

    private func rowBackground(for kind: DiffRow.Kind) -> Color {
        switch kind {
        case .added:   return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        case .context, .meta, .fileHeader, .hunkHeader, .notice:
            return .clear
        }
    }

    /// Sized from the widest line number this file actually shows, so the
    /// gutter does not jitter as the operator scrolls into wider numbers —
    /// same rationale as `CodeSurfaceView.gutterWidth`.
    private var gutterWidth: CGFloat {
        let widest = rows.reduce(into: 0) { widest, entry in
            widest = max(widest, entry.row.newN ?? 0, entry.row.oldN ?? 0)
        }
        return CodeRowView.gutterWidth(forDigits: String(widest).count)
    }

    // MARK: - Scrolling (mirrors CodeSurfaceView exactly)

    private func onFirstAppear(proxy: ScrollViewProxy) {
        switch restoreScroll(visibleRowRange()) {
        case .scrollTo(let target):
            proxy.scrollTo(target, anchor: .top)
        case .none:
            applyScrollDecision(proxy: proxy)
        }
    }

    private func applyScrollDecision(proxy: ScrollViewProxy) {
        switch ScrollDecision.decide(anchor: scrollTarget, visibleRange: visibleRowRange()) {
        case .none:
            break
        case .scrollTo(let target):
            proxy.scrollTo(target, anchor: .center)
        }
    }

    private func visibleRowRange() -> ClosedRange<Int>? {
        guard let low = visibleRowIndices.min(), let high = visibleRowIndices.max() else { return nil }
        return low...high
    }
}
