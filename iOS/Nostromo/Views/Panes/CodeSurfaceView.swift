// Nostromo iOS — CodeSurfaceView.swift
//
// Renders a `code` pane's content for real (ios-curated-view-parity W7):
// a gutter, scroll-to-anchor, and marked ranges, replacing the honest stub
// `PaneSurfaceView` showed before this wedge (W2 deleted the raw `payload.text`
// dump rather than keep the half-rendering it produced — no gutter, no
// scroll-to-anchor, no emphasis, discarding path/revision/first_line
// entirely).
//
// The line arithmetic here is exactly macOS's, ported into NostromoKit
// (`Shared/NostromoKit/Sources/NostromoKit/Code/`) rather than
// reimplemented, so `path:line` lands on the same line on both clients
// (memo B10): `CodeDocument` splits and measures in UTF-16 code units,
// `ScrollDecision` decides whether an anchor should move the viewport, and
// `CodeDocument.resolve(anchor:)`/`resolve(emphasis:)` return the three-state
// `AnchorResolution`/`EmphasisResolution` (memo B12) — "not requested",
// "resolved", and "requested but could not be resolved," each with an
// operator-facing reason for the last. Unlike macOS's `CodeContentView`
// (`resolveRows`, which silently drops any anchor that isn't `.line`), an
// anchor this surface cannot use is **stated**, never silent — see
// `AnchorResolutionTests` for the macOS behaviour this does not repeat.
//
// D3 — the gutter has no `NSTextView`/fragment-counting arithmetic behind
// it (contrast macOS's `LineNumberRulerView.drawHashMarksAndLabels`, which
// numbers only paragraph-starting line fragments and carries a long comment
// about the off-by-one that produces). Each logical line renders as one
// `HStack(alignment: .top)`: a fixed-width gutter cell beside a text column
// that wraps freely with no `lineLimit`. A soft-wrapped continuation lands
// in the same column with nothing beside it, because there is only ever one
// gutter label per row — the "blank continuation cell" convention falls out
// of the layout for free. This is the one place iOS's lack of a text-layout
// engine makes the job easier than macOS's; a future contributor reaching
// for fragment-counting here should know it was considered and rejected.
//
// D5 — this view's SwiftUI identity is `(payload.path, payload.revision)`
// implicitly (it is never re-`.id()`'d at all): `document` is rebuilt only
// when `payload` changes, and an address-only push re-resolves/re-marks/
// re-scrolls without touching `document`, the row views, or their scroll
// position. See `RegionContainerReusesTheSharedTabStripTests`-style L2
// coverage in `tests/ios_policy/test_ios_view_policy.py` for the guard that
// no `.id(` here ever references `address`/`anchor`/`emphasis`.
import SwiftUI
import NostromoKit

struct CodeSurfaceView: View {
    let payload:       CodePayload
    let address:       PaneAddress?
    /// Save this surface's scroll-restore key (W6, D5) — populated so a
    /// width-class rebuild (the only thing that ever tears this view down;
    /// a plain tab switch never does, see `DynamicFocusView`'s ZStack) can
    /// put the operator back where she was.
    let saveScrollKey: (Int) -> Void
    let restoreScroll: (ClosedRange<Int>?) -> ScrollRestore

    /// Rebuilt only when `payload` changes (D5). An address-only push must
    /// never touch this — that is what keeps a re-anchor/re-mark cheap and
    /// keeps the row views' identity (and therefore scroll position) intact.
    @State private var document: CodeDocument

    /// Which row indices are currently on screen. Transient, view-local —
    /// the same pattern `PaneSurfaceView`'s `pr_list` renderer uses for its
    /// own visible-range tracking. `LazyVStack` materialises slightly beyond
    /// the viewport, which makes this a conservative superset of what's
    /// actually visible — the right direction of error for "don't scroll
    /// when already visible" (D4).
    @State private var visibleRowIndices: Set<Int> = []

    init(
        payload: CodePayload,
        address: PaneAddress?,
        saveScrollKey: @escaping (Int) -> Void,
        restoreScroll: @escaping (ClosedRange<Int>?) -> ScrollRestore
    ) {
        self.payload = payload
        self.address = address
        self.saveScrollKey = saveScrollKey
        self.restoreScroll = restoreScroll
        _document = State(initialValue: CodeDocument(payload: payload))
    }

    // MARK: - Resolution (D2) — pure functions of `document` and `address`.
    // Recomputed on every render rather than cached: D5's identity rule is
    // about the ROW VIEWS' identity, not about avoiding a resolve that only
    // ever scans a handful of emphasis entries, never the whole document.

    private var anchorResolution: AnchorResolution {
        document.resolve(anchor: address?.anchor)
    }

    private var emphasisResolution: EmphasisResolution {
        document.resolve(emphasis: address?.emphasis ?? [])
    }

    /// The row `ScrollDecision` should be asked to honour, or `nil` when
    /// there is nothing to arrive at — which is true both when no anchor was
    /// requested and when one was requested and could not be resolved.
    /// `ScrollDecision.decide` already treats a `nil` anchor as "don't move,"
    /// so both of those distinct facts collapse to the same scrolling
    /// behaviour here, even though the notice below reports them
    /// differently.
    private var anchorScrollTarget: Int? {
        switch anchorResolution {
        case .notRequested:       return nil
        case .resolved(let row):  return row
        case .unresolved:         return nil
        }
    }

    private var emphasisRows: Set<Int> {
        switch emphasisResolution {
        case .none:                return []
        case .rows(let rows):      return Set(rows)
        case .matchedNothing:      return []
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        unresolvedNotices
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(0..<document.lineCount, id: \.self) { row in
                                codeRow(row)
                                    .onAppear    { visibleRowIndices.insert(row) }
                                    .onDisappear { visibleRowIndices.remove(row) }
                            }
                        }
                    }
                }
                .onAppear { onFirstAppear(proxy: proxy) }
                .onChange(of: payload) { _, newPayload in
                    // Reset before rebuilding `document`, not after: rows
                    // report their own visibility via onAppear/onDisappear on
                    // SwiftUI's next diff pass, not synchronously with this
                    // assignment, so `applyScrollDecision` below would
                    // otherwise evaluate the new anchor against the
                    // *previous* document's visible row range. If the new
                    // anchor's row happened to fall inside that stale range,
                    // `ScrollDecision.decide` would wrongly return `.none`
                    // and silently fail to scroll to a freshly-requested
                    // anchor on brand-new content — exactly the case this
                    // indirection exists to get right (see the file header).
                    visibleRowIndices = []
                    document = CodeDocument(payload: newPayload)
                    applyScrollDecision(proxy: proxy)
                }
                .onChange(of: address) { _, _ in
                    applyScrollDecision(proxy: proxy)
                }
                .onDisappear {
                    // A width-class change gives no other warning that this
                    // hierarchy is about to be torn down and rebuilt.
                    if let topmost = visibleRowIndices.min() { saveScrollKey(topmost) }
                }
            }
        }
    }

    // MARK: - Header (D6)

    private var header: some View {
        HStack(spacing: 8) {
            // The path is the load-bearing half — truncate from the
            // LEADING end if it must be truncated, so the filename (the end
            // an operator actually reads to tell files apart) survives.
            Text(document.path)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            // `RevisionLabel.short` never puts a 40-character SHA on screen
            // inline; the full value is still readable via tap-and-hold
            // (D6) rather than only living in `document.revision` with no
            // way to see it.
            Text(RevisionLabel.short(document.revision))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .contextMenu {
                    Text(document.revision)
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Unresolved notices (D7)
    //
    // Rendered where the missing thing would have been — at the top of the
    // content, not a corner and not a toast — and dismissible only by the
    // next push, because this is a fact about what's on screen, not an
    // alert. `reason` (`PaneAddress.reason`) is W5's tab caption, not this
    // surface's job, and is never rendered here too.

    @ViewBuilder
    private var unresolvedNotices: some View {
        if case .unresolved(let reason) = anchorResolution {
            notice(reason)
        }
        if case .matchedNothing(let reason) = emphasisResolution {
            notice(reason)
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.orange.opacity(0.12))
    }

    // MARK: - Rows (D3)
    //
    // No `lineLimit`, no horizontal scroll, no truncation of any kind — a
    // long line wraps and stays fully readable, and a large file relies on
    // `LazyVStack`'s own laziness rather than a row cap (D8). This is not
    // `PerriView`'s deferred, separately-truncated raw diff.

    private func codeRow(_ row: Int) -> some View {
        let marked = emphasisRows.contains(row)
        return HStack(alignment: .top, spacing: 8) {
            Text("\(document.firstLine + row)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(marked ? Color.accentColor : .secondary)
                .frame(width: gutterWidth, alignment: .trailing)
            Text(document.lines[row])
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(marked ? Color.accentColor.opacity(0.15) : Color.clear)
        .id(row)
    }

    /// Sized from `gutterDigits` so it does not jitter as the operator
    /// scrolls into wider line numbers.
    private var gutterWidth: CGFloat {
        CGFloat(document.gutterDigits) * 8 + 4
    }

    // MARK: - Scrolling (D4)

    /// First layout: prefer a saved scroll-restore key (this is the width-
    /// class-rebuild/remount case — a plain tab switch never tears this view
    /// down at all, so `restoreScroll` has nothing to restore the first time
    /// a pane is ever shown). Only when there is no saved key does the
    /// freshly-arrived anchor get to decide where the view lands.
    private func onFirstAppear(proxy: ScrollViewProxy) {
        switch restoreScroll(visibleRowRange()) {
        case .scrollTo(let target):
            // No animation: this is putting the operator back where she
            // already was, not taking her somewhere new — same rule
            // `PaneSurfaceView`'s `pr_list` restore uses.
            proxy.scrollTo(target, anchor: .top)
        case .none:
            applyScrollDecision(proxy: proxy)
        }
    }

    /// The criterion this whole indirection exists for: an anchor already
    /// on screen must not move the viewport, and re-showing the same file
    /// with a new anchor (D5) re-anchors without rebuilding anything.
    private func applyScrollDecision(proxy: ScrollViewProxy) {
        switch ScrollDecision.decide(anchor: anchorScrollTarget, visibleRange: visibleRowRange()) {
        case .none:
            break
        case .scrollTo(let row):
            proxy.scrollTo(row, anchor: .center)
        }
    }

    /// The contiguous span of row indices currently on screen. `nil` before
    /// anything has been laid out, which both `ScrollDecision` and
    /// `ScrollRestore` read as a first paint that always honours its target.
    private func visibleRowRange() -> ClosedRange<Int>? {
        guard let low = visibleRowIndices.min(), let high = visibleRowIndices.max() else { return nil }
        return low...high
    }
}
