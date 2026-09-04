// Nostromo iOS — PaneSurfaceView.swift
//
// Renders a single non-repl pane's content, keyed by `PaneContentWire`.
//
// Moved out of DynamicFocusView.swift (W2 — ios-curated-view-parity) so the
// tab/region structure in that file and the content-kind switch in this one
// can evolve independently — W4/W5/W7/W8/W9 all touch the switch below.
// DynamicFocusView keeps the TabView/paneIds structure; this file owns the
// content kinds.
//
// Receives `DaemonStore` via `@EnvironmentObject` for `pr_list` action dispatch.
import SwiftUI
import NostromoKit

struct PaneSurfaceView: View {
    let paneId:    String
    let content:   PaneContentWire?
    let freshness: PaneFreshness?
    /// Where to look inside this pane's content, and why (W1/W5 —
    /// curated-agent-views). `pr_list` reads its `queue_row` anchor/emphasis
    /// to mark a row; the other kinds rendered here have no addressing yet.
    let address:   PaneAddress?
    /// Save this surface's scroll-restore key (W6 — ios-curated-view-parity,
    /// D5). Only the queue renderer has rows to be positioned among; the
    /// honest stubs and the generic text/JSON renderers store nothing,
    /// because there is nothing about their position worth restoring.
    let saveScrollKey: (Int) -> Void
    /// Decide whether to restore a saved position given what is currently
    /// visible — `.none` when the saved row is already on screen, so a
    /// width-class change that happened not to move this surface produces no
    /// visible jump.
    let restoreScroll: (ClosedRange<Int>?) -> ScrollRestore
    /// `pr_diff`'s per-file scroll-restore (ios-curated-view-parity W8) —
    /// `saveScrollKey`/`restoreScroll` above have exactly one slot per pane,
    /// which isn't enough for a pane that can show different files at
    /// different times. Only `DiffSurfaceView` calls these; every other
    /// content kind ignores them.
    let saveDiffFileScrollKey: (_ file: String, _ key: Int) -> Void
    let restoreDiffFileScrollKey: (_ file: String, _ visibleRange: ClosedRange<Int>?) -> ScrollRestore
    /// `pr_diff`'s selected-file slot (W8, D2) — which file the pane
    /// currently has open, scoped by an identity string
    /// (`"\(repo)#\(number)"`-shaped) `DiffSurfaceView` builds itself.
    let saveSelectedDiffFile: (_ path: String, _ identity: String) -> Void
    let restoreSelectedDiffFile: (_ identity: String) -> String?

    @EnvironmentObject var store: DaemonStore

    /// Which queue-row indices are on screen. View-local and transient: this
    /// is "what is in front of the operator right now", not durable state.
    /// The durable half is the single key handed to `saveScrollKey` on
    /// teardown.
    @State private var visibleRowIndices: Set<Int> = []
    /// Guards the one-shot restore so a later re-layout can't yank the
    /// viewport after the operator has started scrolling again.
    @State private var hasRestored = false

    /// Staged pending approval — set on first swipe tap; cleared on cancel or after
    /// the confirmation dialog fires. Mirrors the pattern in `PerriView`.
    @State private var pendingApproval: (repo: String, number: Int)?

    private let bucketOrder: [(label: String, key: String)] = [
        ("Requested",    "requested"),
        ("Needs Review", "needs_review"),
        ("Changes Req",  "changes_req"),
        ("Dependabot",   "dependabot"),
    ]

    var body: some View {
        Group {
            switch content {
            case nil:
                ScrollView { waitingView }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .text(let text):
                ScrollView { textView(text) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .jsonSnapshot(let value):
                ScrollView { jsonView(value) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .prList(let items):
                prListView(items)
            case .code(let payload):
                CodeSurfaceView(
                    payload: payload,
                    address: address,
                    saveScrollKey: saveScrollKey,
                    restoreScroll: restoreScroll
                )
            case .loading:
                ScrollView {
                    VStack(spacing: 8) {
                        Spacer(minLength: 60)
                        ProgressView()
                        Text("Refreshing…")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }.frame(maxWidth: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let msg):
                ScrollView {
                    VStack(spacing: 8) {
                        Spacer(minLength: 60)
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(msg)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                    }.frame(maxWidth: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unknown(let raw):
                ScrollView { jsonView(raw) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            // `.diff`/`.prConversation`/`.ticket` are honest deferrals, not
            // half-built renderings — the PRD's organizing rule is that a
            // surface may be absent or simplified but must never look
            // complete when it isn't. `.code` used to be a fourth member of
            // this set: a raw dump of the file's text with no gutter, no
            // scroll-to-anchor, no emphasis, discarding the path/revision/
            // first-line fields entirely — exactly the half-rendering that
            // rule forbids. W2 deleted that rendering; W7 replaces it with
            // `CodeSurfaceView`, a real renderer, above. Each remaining stub
            // names the specific addressing it cannot show, not just that
            // something is missing; `PaneSurfaceStub` (NostromoKit) is the
            // single source of that wording so W8/W9 delete a table entry
            // instead of hunting a string in a view.
            case .diff(let payload):
                DiffSurfaceView(
                    payload: payload,
                    address: address,
                    saveScrollKey: saveDiffFileScrollKey,
                    restoreScroll: restoreDiffFileScrollKey,
                    saveSelectedFile: saveSelectedDiffFile,
                    restoreSelectedFile: restoreSelectedDiffFile
                )
            case .prConversation, .ticket:
                if let content, let message = PaneSurfaceStub.message(for: content) {
                    stubView(headline: message.headline, detail: message.detail)
                }
            }
        }
        // D11: a quiet as-of footnote when this pane's data hasn't refreshed in
        // a while. Never shown for a normal transient miss — only `badlyStale`
        // (never `stale`) is rendered, and it disappears on the next push with
        // no agent action.
        .overlay(alignment: .bottomTrailing) {
            if let freshness, freshness.badlyStale {
                Text(staleLabelText(freshness))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 6)
                    .padding(.bottom, 4)
            }
        }
        // Confirmation gate — nothing reaches GitHub until the user taps "Approve" here.
        // This mirrors the existing PerriView swipe-to-approve + pendingApproval pattern.
        .confirmationDialog(
            pendingApproval.map { "Approve PR #\($0.number) in \($0.repo)?" } ?? "",
            isPresented: Binding(
                get:  { pendingApproval != nil },
                set:  { if !$0 { pendingApproval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let item = pendingApproval {
                Button("Approve") {
                    store.perriApprove(number: item.number, repo: item.repo)
                    pendingApproval = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingApproval = nil }
        } message: {
            Text("The approval will be posted to GitHub. The PR will leave the queue once the index catches up.")
        }
    }

    // MARK: - pr_list renderer

    @ViewBuilder
    private func prListView(_ items: [PrListItemModel]) -> some View {
        if items.isEmpty {
            ScrollView {
                VStack {
                    Spacer(minLength: 60)
                    Text("No PRs in queue")
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            let ordered = orderedRows(items)
            ScrollViewReader { proxy in
            List {
                ForEach(bucketOrder, id: \.key) { bucket in
                    let group = items.filter { $0.bucket == bucket.key }
                    if !group.isEmpty {
                        Section(bucket.label) {
                            ForEach(group) { item in
                                NostromoKit.PerriPRRow(
                                    model:  item.toRowModel(marked: address?.marks(repo: item.repo, number: item.number) ?? false),
                                    onLoad: { store.perriLoadPr(number: item.number, repo: item.repo) },
                                    onClear: {}
                                )
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        // First tap only stages the approval — confirmation
                                        // dialog fires before anything is sent to GitHub.
                                        pendingApproval = (repo: item.repo, number: item.number)
                                    } label: {
                                        Label("Approve", systemImage: "checkmark.seal.fill")
                                    }
                                    .tint(.green)
                                }
                                .onAppear    { noteRowVisible(item, in: ordered, visible: true) }
                                .onDisappear { noteRowVisible(item, in: ordered, visible: false) }
                            }
                        }
                    }
                }
                // Overflow — items with unrecognised bucket strings
                let knownBuckets = Set(bucketOrder.map(\.key))
                let overflow = items.filter { !knownBuckets.contains($0.bucket) }
                if !overflow.isEmpty {
                    Section("Other") {
                        ForEach(overflow) { item in
                            NostromoKit.PerriPRRow(
                                model:  item.toRowModel(marked: address?.marks(repo: item.repo, number: item.number) ?? false),
                                onLoad: { store.perriLoadPr(number: item.number, repo: item.repo) },
                                onClear: {}
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    pendingApproval = (repo: item.repo, number: item.number)
                                } label: {
                                    Label("Approve", systemImage: "checkmark.seal.fill")
                                }
                                .tint(.green)
                            }
                            .onAppear    { noteRowVisible(item, in: ordered, visible: true) }
                            .onDisappear { noteRowVisible(item, in: ordered, visible: false) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            // The restore half of D5. Fires on the first layout that knows
            // what it is showing, not in `onAppear` where nothing is
            // measured yet and a saved key could only be obeyed blindly.
            .onChange(of: visibleRowIndices) { _, indices in
                guard !hasRestored, !indices.isEmpty else { return }
                hasRestored = true
                guard case .scrollTo(let target) = restoreScroll(visibleRowRange(indices)),
                      ordered.indices.contains(target) else { return }
                // No animation: this is putting the operator back where she
                // already was, not taking her somewhere new.
                proxy.scrollTo(ordered[target].id, anchor: .top)
            }
            .onDisappear {
                // A width-class change gives no other warning that this
                // hierarchy is about to be torn down and rebuilt.
                if let topmost = visibleRowIndices.min() { saveScrollKey(topmost) }
            }
            }
        }
    }

    /// The queue's rows in the exact order they are rendered — the bucket
    /// order above, then the "Other" overflow — so a saved row index means
    /// the same thing on the way back in. A scroll key is an opaque `Int`
    /// whose meaning belongs to the surface that saved it; this is that
    /// meaning for the queue.
    private func orderedRows(_ items: [PrListItemModel]) -> [PrListItemModel] {
        let knownBuckets = Set(bucketOrder.map(\.key))
        return bucketOrder.flatMap { bucket in items.filter { $0.bucket == bucket.key } }
             + items.filter { !knownBuckets.contains($0.bucket) }
    }

    /// Record whether `item`'s row is on screen, by its position in the
    /// rendered order. Transient bookkeeping only — nothing here reaches the
    /// store until teardown.
    private func noteRowVisible(_ item: PrListItemModel, in ordered: [PrListItemModel], visible: Bool) {
        guard let index = ordered.firstIndex(where: { $0.id == item.id }) else { return }
        if visible { visibleRowIndices.insert(index) } else { visibleRowIndices.remove(index) }
    }

    /// The contiguous span of row indices currently on screen. `nil` before
    /// anything has been laid out, which `ScrollRestore` reads as a first
    /// paint.
    private func visibleRowRange(_ indices: Set<Int>) -> ClosedRange<Int>? {
        guard let low = indices.min(), let high = indices.max() else { return nil }
        return low...high
    }

    // MARK: - Staleness footnote

    private func staleLabelText(_ freshness: PaneFreshness) -> String {
        guard let asOf = freshness.asOf else { return "stale" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "stale · as of \(formatter.string(from: asOf))"
    }

    // MARK: - Stub renderer (deferred content kinds)

    /// Honest-deferral rendering for a content kind iOS doesn't have a real
    /// renderer for yet. `detail` is required, not optional — a stub that
    /// says only "isn't available" is an absence; naming the missing
    /// addressing is what makes the deferral legible (see `PaneSurfaceStub`).
    private func stubView(headline: String, detail: String) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                Spacer(minLength: 60)
                Text(headline)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                Spacer()
            }.frame(maxWidth: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Text / JSON renderers

    private var waitingView: some View {
        VStack {
            Spacer(minLength: 60)
            Text("waiting for content…")
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func textView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .regular, design: .monospaced))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .textSelection(.enabled)
    }

    private func jsonView(_ value: Any) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(jsonRows(from: value)) { row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.key)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 80, alignment: .trailing)
                    Text(row.value)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 12)
            }
        }
    }

    // MARK: - JSON helpers

    private struct JsonRow: Identifiable {
        let key: String
        let value: String
        var id: String { key }
    }

    private func jsonRows(from value: Any) -> [JsonRow] {
        if let dict = value as? [String: Any] {
            return dict.map { k, v in JsonRow(key: k, value: jsonString(v)) }
                       .sorted { $0.key < $1.key }
        }
        if let arr = value as? [Any] {
            return arr.enumerated().map { i, v in JsonRow(key: "\(i)", value: jsonString(v)) }
        }
        return [JsonRow(key: "value", value: jsonString(value))]
    }

    private func jsonString(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let b = value as? Bool   { return b ? "true" : "false" }
        if let i = value as? Int    { return "\(i)" }
        if let d = value as? Double { return "\(d)" }
        if let arr = value as? [Any] {
            return "[\(arr.map { jsonString($0) }.joined(separator: ", "))]"
        }
        if let dict = value as? [String: Any] {
            let pairs = dict.map { "\($0.key): \(jsonString($0.value))" }.joined(separator: ", ")
            return "{\(pairs)}"
        }
        return "\(value)"
    }
}
